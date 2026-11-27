#!/usr/bin/env bash
# A --background run that is refused before it starts ends with one JSON result under an agent mode (#410).
#
# The dispatch opened the stream of a command after its --background branch, so a refusal of that branch (the lab gate,
# the lease gate, the non interactive preflight, fl_op_background) had no stream to end and stdout stayed empty. #405
# fixed the same gap for the gates of repair and pull in front. The rule, for --for-agent, --jsonl and --json:
#   - a command with a stream: one `done` line, `exit` 1 (2 for a lab that is off), the refusal as `error`
#   - a command that prints a document: under --jsonl and --for-agent the same done line (a command that changes things
#     streams); under plain --json nothing, as for a read (docs/json-schema.md)
#   - stderr is what it was, and nothing is written: no operation record, no log, no history line, no lock
#   - an ACCEPTED run is not touched: the parent prints the one op_id line (and not a done line), and the detached run
#     does not hold the parent's stdout open
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/dev/frappe-bench"
OTHER="$HOME/frappe-bench"
make_fake_bench "$BENCH" macdev
printf 'port 11000\n' >"$BENCH/config/redis_queue.conf"; printf 'port 13000\n' >"$BENCH/config/redis_cache.conf"
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
export MARIADB_ROOT_PASSWORD=rootpw
mkdir -p "$BENCH/sites/bbtest.localhost"; printf '{}\n' >"$BENCH/sites/bbtest.localhost/site_config.json"
OPS="$FL_STATE_DIR/ops"
export FL_OP_WAIT_POLL=0.1 FL_OP_LAUNCH_WAIT=3
# a fixed clock for the text of a lease
export FL_NOW=1800000000
sleep 900 & LIVE=$!
on_exit "kill $LIVE 2>/dev/null"

# the whole state folder, its empty folders too: a refusal leaves no record, log, lock or history line
state_tree() {
  (cd "$FL_STATE_DIR" && find . -print | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s\n' "$f"
    if [[ -f "$f" ]]; then cat "$f"; fi
  done) | cksum
}
nlines() { printf '%s\n' "$1" | grep -c . || true; }

# bg_run MODE ARGS...: ARGS with --background and MODE, as an agent runs them; OUT, ERR and CODE, and BEFORE (the state)
bg_run() {
  local mode="$1"; shift
  BEFORE="$(state_tree)"
  BENCHBAR_NONINTERACTIVE=1 run_fm_split "$@" "$mode" --background
}

# bg_done NAME KIND CODE TEXT: the run printed one done line: exit CODE, TEXT in `error`, no op_id (no operation exists),
# KIND repair (exit_code beside exit), install (url), pull (site), or other
bg_done() {
  local name="$1" kind="$2" code="$3" text="$4" got
  assert_eq "$code" "$CODE" "($name) $OUT $ERR"
  assert_eq "1" "$(nlines "$OUT")" "($name: one line on stdout) $OUT"
  got="$(printf '%s' "$OUT" | python3 -I -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["event"] == "done" and d["schema_version"] == 1, d
assert d["exit"] == int(sys.argv[1]), d
assert sys.argv[2] in d["error"], d
assert "op_id" not in d and "state" not in d, d
print("repair" if "exit_code" in d else "install" if "url" in d else "pull" if "site" in d else "other")
' "$code" "$text")" || fail "($name) not a done line with the refusal: $OUT"
  assert_eq "$kind" "$got" "($name: the done line of the command's own stream)"
  assert_contains "$ERR" "$text" "($name: the refusal is on stderr)"
  assert_contains "$ERR" "Aborting." "($name: the hint is on stderr)"
  assert_not_contains "$ERR" '"event"' "($name: stderr has no JSON)"
}
# bg_silent NAME CODE TEXT: nothing on stdout (a document under plain --json: the contract of a read stays), the text on stderr
bg_silent() {
  assert_eq "$2" "$CODE" "($1) $OUT $ERR"
  assert_eq "" "$OUT" "($1: nothing on stdout, as for a read under --json)"
  assert_contains "$ERR" "$3" "($1: the refusal is on stderr)"
}
unchanged() { assert_eq "$BEFORE" "$(state_tree)" "($1: nothing was written, not even a folder)"; }
OPS0="$(find "$OPS" -name 'op-*.json' 2>/dev/null | wc -l | tr -d ' ')"
no_ops() { assert_eq "$OPS0" "$(find "$OPS" -name 'op-*.json' 2>/dev/null | wc -l | tr -d ' ')" "($1: a refusal is not an operation: no record beyond the ${OPS0} of the set up)"; }

# --- the issue: fl_op_background refuses a dry run
bg_run --for-agent repair --dry-run --bench-dir "$BENCH"
bg_done "repair --background --dry-run --for-agent" repair 1 "--background starts a change; a dry run prints its plan at once."
assert_eq "  [FAIL] --background starts a change; a dry run prints its plan at once."$'\n\n'"Aborting. Run the plan without --background, then apply it with --background." "$ERR" "(stderr is byte for byte what it was)"
unchanged "repair dry run"; no_ops "repair dry run"

DRY="--background starts a change; a dry run prints its plan at once."
for mode in --for-agent --jsonl --json; do
  bg_run "$mode" repair --dry-run --bench-dir "$BENCH"
  bg_done "repair dry run $mode" repair 1 "$DRY"; unchanged "repair dry run $mode"
  bg_run "$mode" pull build.example.com:mysite --dry-run --bench-dir "$BENCH"
  bg_done "pull dry run $mode" pull 1 "$DRY"; unchanged "pull dry run $mode"
  bg_run "$mode" install --dry-run --bench-dir "$BENCH"
  bg_done "install dry run $mode" install 1 "$DRY"; unchanged "install dry run $mode"
done
# the commands that print a document: a done line under --jsonl and --for-agent, nothing under --json (a plan is a read)
for mode in --for-agent --jsonl; do
  for c in "site add dev2.localhost --bundle minimal" "app update erpnext" "site backup bbtest.localhost" "site snapshot bbtest.localhost" \
    "site restore bbtest.localhost --from 20260929_100001" "site rollback bbtest.localhost --to latest" "app add erpnext"; do
    # shellcheck disable=SC2086
    bg_run "$mode" $c --dry-run --bench-dir "$BENCH"
    bg_done "$c dry run $mode" other 1 "$DRY"; unchanged "$c dry run $mode"
  done
done
for c in "site add dev2.localhost --bundle minimal" "site backup bbtest.localhost" "app add erpnext"; do
  # shellcheck disable=SC2086
  bg_run --json $c --dry-run --bench-dir "$BENCH"
  bg_silent "$c dry run --json" 1 "$DRY"; unchanged "$c dry run --json"
done
no_ops "dry runs"

# --- fl_op_background: a command that may not run in the background, and the sudo password it cannot carry
for mode in --for-agent --jsonl --json; do
  bg_run "$mode" up --bench-dir "$BENCH"
  bg_done "up $mode" other 1 "benchbar up cannot run with --background."; unchanged "up $mode"
done
for mode in --for-agent --jsonl --json; do
  BENCHBAR_SUDO=env BENCHBAR_SUDO_PASSWORD=x bg_run "$mode" repair --yes --bench-dir "$BENCH"
  bg_done "repair, sudo password $mode" repair 1 "--background cannot carry BENCHBAR_SUDO_PASSWORD"; unchanged "repair, sudo password $mode"
  assert_not_contains "$OUT$ERR" "BENCHBAR_SUDO_PASSWORD=x" "(the password is in no output)"
done

# --- the lab gate and the non interactive preflight answer by themselves, with a refusal document (exit, error, missing: no
# `event`), as they did when a --background run had no stream: byte for byte what they printed, on stdout and on stderr.
# The lab gate comes first: a command of a lab that is off is exit 2, not "cannot run with --background".
# bg_doc NAME CODE TEXT: one line of JSON with `exit` CODE and TEXT in `error`, and no `event`
bg_doc() {
  local name="$1" code="$2" text="$3"
  assert_eq "$code" "$CODE" "($name) $OUT $ERR"
  assert_eq "1" "$(nlines "$OUT")" "($name: one line on stdout) $OUT"
  printf '%s' "$OUT" | python3 -I -c '
import json, sys
d = json.loads(sys.stdin.read())
assert "event" not in d and d["exit"] == int(sys.argv[1]) and sys.argv[2] in d["error"], d
' "$code" "$text" || fail "($name) not the refusal document: $OUT"
  assert_not_contains "$ERR" '"exit"' "($name: stderr has no JSON)"
}
for mode in --for-agent --jsonl --json; do
  bg_run "$mode" share setup --bench-dir "$BENCH"
  bg_doc "share setup $mode, lab off" 2 "benchbar share is an experiment and it is off."
  assert_eq "benchbar share is an experiment and it is off. Turn it on: benchbar labs on lan-rooms" "$ERR" "(share setup $mode: stderr as it was)"
  unchanged "share setup $mode"
done

# --- the non interactive preflight (a run nobody watches cannot be asked)
unset ADMIN_PASSWORD
for mode in --for-agent --jsonl --json; do
  bg_run "$mode" site add dev2.localhost --bundle minimal --bench-dir "$BENCH"
  bg_doc "site add, ADMIN_PASSWORD $mode" 1 "Cannot start, missing: ADMIN_PASSWORD"
  assert_contains "$OUT" '"missing":["ADMIN_PASSWORD"' "(site add $mode: the document says what is missing)"
  assert_contains "$ERR" "BENCHBAR_NONINTERACTIVE=1: nothing can be asked; pass them and run the command again. Nothing was changed." "(site add $mode: stderr as it was)"
  unchanged "site add preflight $mode"
  bg_run "$mode" install --bench-dir "$BENCH"
  bg_doc "install, --yes $mode" 1 "Cannot start, missing: --yes"
  assert_contains "$OUT" '"missing":["--yes"]' "(install $mode: the document says what is missing)"
  unchanged "install preflight $mode"
done
bg_run --for-agent site restore bbtest.localhost --from 20260929_100001 --bench-dir "$BENCH"
bg_doc "site restore, --yes --for-agent" 1 "Cannot start, missing: --yes"
bg_run --json site restore bbtest.localhost --from 20260929_100001 --bench-dir "$BENCH"
bg_doc "site restore, --yes --json" 1 "Cannot start, missing: --yes"
no_ops "preflight"

# --- the lease gate
BENCHBAR_NONINTERACTIVE=1 BENCHBAR_CALLER=agent-a run_fm_split lease take --bench "$BENCH" --for 20 --bench-dir "$BENCH"
assert_eq "0" "$CODE" "(lease take) $OUT $ERR"
LEASE="The bench ${BENCH} is leased by agent-a until 2027-01-15T08:20:00Z. Nothing was changed."
for mode in --for-agent --jsonl --json; do
  BENCHBAR_CALLER=agent-b bg_run "$mode" repair --yes --bench-dir "$BENCH"
  bg_done "repair, lease $mode" repair 1 "$LEASE"
  assert_contains "$OUT" '"error_id":"lease_held"' "(repair, lease $mode: the stable id)"
  unchanged "repair lease $mode"
  BENCHBAR_CALLER=agent-b bg_run "$mode" pull build.example.com:mysite --yes --bench-dir "$BENCH"
  bg_done "pull, lease $mode" pull 1 "$LEASE"; unchanged "pull lease $mode"
done
for mode in --for-agent --jsonl --json; do
  BENCHBAR_CALLER=agent-b bg_run "$mode" site add dev2.localhost --bundle minimal --yes --bench-dir "$BENCH"
  bg_done "site add, lease $mode" other 1 "is leased by agent-a"; unchanged "site add lease $mode"
done
BENCHBAR_CALLER=agent-b bg_run --json app add erpnext --yes --bench-dir "$BENCH"
bg_silent "app add, lease --json" 1 "is leased by agent-a"; unchanged "app add lease --json"
rm -f "$FL_STATE_DIR/leases.tsv"
unset FL_NOW
no_ops "lease"

# --- a refusal after the launch: the detached run was refused (the run lock is held, or the bench guess gate): the
# launcher says so with the run's message and exit code. This one IS an operation (its attempt is recorded, as before):
# one record, and the launcher's done line
mkdir -p "$FL_STATE_DIR/lock"; printf '%s\n' "$LIVE" >"$FL_STATE_DIR/lock/pid"
for mode in --for-agent --jsonl; do
  bg_run "$mode" site backup bbtest.localhost --yes --bench-dir "$BENCH"
  bg_done "site backup, lock busy $mode" other 1 "Another benchbar run is active"
  assert_contains "$ERR" "Nothing was started; the attempt is recorded as op-" "($mode: the attempt is recorded, as before)"
done
bg_run --json repair --yes --bench-dir "$BENCH"
bg_done "repair, lock busy --json" repair 1 "Another benchbar run is active"
assert_eq "$((OPS0 + 3))" "$(find "$OPS" -name 'op-*.json' | wc -l | tr -d ' ')" "(three attempts, three records: the done line adds none)"
rm -f "$FL_STATE_DIR/lock/pid"; rmdir "$FL_STATE_DIR/lock"
# two benches and none chosen: the guess gate is the detached run's, so the launcher has no refusal: it prints its op_id line
# (state starting: the run never held the lock), exit 0, as before; the refusal is the done line in the run's own file
rm -f "$FL_STATE_FILE" "$FL_STATE_DIR/registered-benches.txt"; rm -rf "$FL_STATE_DIR/benches"
make_fake_bench "$OTHER" other
bg_run --for-agent repair --yes
assert_eq "0" "$CODE" "(repair, two benches) $OUT $ERR"
assert_eq "1" "$(nlines "$OUT")" "(repair, two benches: one line) $OUT"
assert_contains "$OUT" '"state":"starting"' "(repair, two benches: the launcher's line, as before)"
assert_not_contains "$OUT" '"event"' "(repair, two benches: not a done line)"
ID="$(printf '%s' "$OUT" | python3 -I -c 'import json,sys; print(json.loads(sys.stdin.read())["op_id"])')"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do grep -q '"event":"done"' "$OPS/$ID.jsonl" 2>/dev/null && break; sleep 0.5; done
assert_contains "$(cat "$OPS/$ID.jsonl")" "More than one bench is possible and none was chosen" "(repair, two benches: the detached run's own done line has the refusal)"

# --- a refusal that already printed JSON is as it was: an unknown flag (exit 64) with --background
for mode in --for-agent --jsonl --json; do
  bg_run "$mode" repair --yes --nosuchflag --bench-dir "$BENCH"
  assert_eq "64" "$CODE" "(unknown flag $mode) $OUT $ERR"
  assert_eq "1" "$(nlines "$OUT")" "(unknown flag $mode: one line) $OUT"
  assert_contains "$OUT" '"error_id":"unknown_flag"' "(unknown flag $mode: its own refusal)"
done
rm -rf "$OTHER"

# --- an accepted run is not touched. The parent prints the one op_id line, in every mode, and no done line; the detached
# run writes its own stream to its file.
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
for mode in --for-agent --jsonl --json; do
  MOCK_BENCH_BACKUP_SLEEP=2 bg_run "$mode" site backup bbtest.localhost --yes --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "(accepted $mode) $OUT $ERR"
  assert_eq "1" "$(nlines "$OUT")" "(accepted $mode: one line) $OUT"
  assert_eq "site backup running True 0 True" "$(printf '%s' "$OUT" | python3 -I -c '
import json, sys
d = json.loads(sys.stdin.read())
assert "event" not in d, d
print(d["command"], d["state"], d["background"], d["exit"], d["output"].endswith(d["op_id"] + ".jsonl"))')" "(accepted $mode: the op_id line) $OUT"
  assert_eq "" "$ERR" "(accepted $mode: nothing on stderr)"
  ID="$(printf '%s' "$OUT" | python3 -I -c 'import json,sys; print(json.loads(sys.stdin.read())["op_id"])')"
  run_fm_split op wait "$ID" --timeout 60 --json
  assert_eq "0" "$CODE" "$OUT$ERR"
  # its own stream is in its file: the stream of --jsonl, which ends with its done line, which has the op_id
  assert_eq "done $ID" "$(tail -n 1 "$OPS/$ID.jsonl" | python3 -I -c 'import json,sys; d = json.loads(sys.stdin.read()); print(d["event"], d["op_id"])')" "(accepted $mode: the detached run's own done line)"
  assert_eq "1" "$(grep -c '"event":"done"' "$OPS/$ID.jsonl" || true)" "(accepted $mode: one done line in the file)"
done

printf 'test-background-refusal-json: ok\n'
