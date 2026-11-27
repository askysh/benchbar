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

# bg_done NAME KIND CODE TEXT [STDERR]: the run printed one done line: exit CODE, TEXT in `error`, no op_id (no operation
# exists), KIND repair (exit_code beside exit), install (url), pull (site), or other. With STDERR, stderr is that text, byte
# for byte (ids normalised, nrm), else it holds TEXT and the hint.
bg_done() {
  local name="$1" kind="$2" code="$3" text="$4" want="${5:-}" got
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
  if [[ -n "$want" ]]; then
    assert_eq "$want" "$(printf '%s' "$ERR" | nrm)" "($name: stderr is byte for byte what it was)"
  else
    assert_contains "$ERR" "$text" "($name: the refusal is on stderr)"
    assert_contains "$ERR" "Aborting." "($name: the hint is on stderr)"
  fi
  assert_not_contains "$ERR" '"event"' "($name: stderr has no JSON)"
}
# bg_silent NAME CODE TEXT: nothing on stdout (a document under plain --json: the contract of a read stays), the text on stderr
bg_silent() {
  assert_eq "$2" "$CODE" "($1) $OUT $ERR"
  assert_eq "" "$OUT" "($1: nothing on stdout, as for a read under --json)"
  assert_contains "$ERR" "$3" "($1: the refusal is on stderr)"
}
unchanged() { assert_eq "$BEFORE" "$(state_tree)" "($1: nothing was written, not even a folder)"; }
# nrm: ids, stamps, paths, pids and times of a text made the same, so that two runs compare
nrm() {
  sed -E -e "s#$TMP_DIR#TMP#g" -e "s#$ROOT#ROOT#g" -e 's#op-[0-9]{8}-[0-9]{6}-[0-9]+(-[0-9]+)?#OPID#g' -e 's#[0-9]{8}-[0-9]{6}-[0-9]+#STAMP#g' \
    -e 's#"pid":[0-9]+#"pid":N#g' -e 's#[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z#TS#g' -e 's#"elapsed":[0-9]+#"elapsed":N#g' \
    -e 's#"duration[a-z_]*":[0-9.]+#"duration":N#g' -e 's#[0-9a-f]{8,}#H#g'
}

# --- the accepted run of repair and pull (the commands with a stream of their own, so with a writer that could send a
# second done line): the parent prints exactly one line, the op_id line, and the detached run's own output (its stream file
# and its stderr file) is what it was before #410. The expected text is tests/golden/background-accepted.txt: the same
# runs, in this order, on next-release at c3db5f05, normalised (nrm). The runs go in every mode, and with the stream
# variables in the caller's environment (an outer benchbar exports them): the detached run starts without the parent's
# stream. The runs share one bench, so a later repair finds less to do than the first: the order is part of the text.
# >>> accepted runs
ACC_FILE="$TMP_DIR/accepted-runs.txt"
: >"$ACC_FILE"
# golden_add HEADING: the text on stdin joins what the runs wrote (a file: the runs are in pipelines)
golden_add() { { printf '=== %s
' "$1"; cat; } >>"$ACC_FILE"; }
# golden_check: what the runs wrote is the golden file
golden_check() {
  local f="$ROOT/tests/golden/background-accepted.txt"
  [[ -f "$f" ]] || fail "(no golden file $f) $(cat "$ACC_FILE")"
  assert_eq "$(cat "$f")" "$(cat "$ACC_FILE")" "(accepted runs: the detached run's output is what it was before #410)"
}
# accepted_run NAME MODE OUTER ARGS...: OUTER is none, or env: the stream variables in the caller's environment
accepted_run() {
  local name="$1" mode="$2" outer="$3" id st; shift 3
  if [[ "$outer" == env ]]; then
    FL_JSONL=0 FL_JSON_EVENTS=0 FL_PULL_ACTIVE=0 bg_run "$mode" "$@"
  else
    bg_run "$mode" "$@"
  fi
  assert_eq "0" "$CODE" "(accepted $name $mode $outer) $OUT $ERR"
  assert_eq "1" "$(nlines "$OUT")" "(accepted $name $mode $outer: the parent prints one line) $OUT"
  st="$(printf '%s' "$OUT" | python3 -I -c '
import json, sys
d = json.loads(sys.stdin.read())
assert "event" not in d and d["background"] is True and d["exit"] == 0 and d["output"].endswith(d["op_id"] + ".jsonl"), d
print(d["state"])')" || fail "(accepted $name $mode $outer) not the op_id line: $OUT"
  assert_eq "running" "$st" "(accepted $name $mode $outer: the launcher's line says running)"
  assert_eq "" "$ERR" "(accepted $name $mode $outer: nothing on stderr)"
  id="$(printf '%s' "$OUT" | python3 -I -c 'import json,sys; print(json.loads(sys.stdin.read())["op_id"])')"
  # wait for the end of the detached run with a deadline (op wait --timeout), never with a sleep
  run_fm_split op wait "$id" --timeout 120 --json
  case "$OUT" in *'"state":"done"'*|*'"state":"failed"'*) ;; *) fail "(accepted $name $mode $outer: the detached run did not end in the deadline) $OUT $ERR" ;; esac
  { nrm <"$OPS/$id.jsonl"; printf -- '--- stderr\n'; nrm <"$OPS/$id.err"; } | golden_add "$name $mode $outer"
}
for mode in --for-agent --jsonl --json; do
  accepted_run repair "$mode" none repair --yes --bench-dir "$BENCH"
  accepted_run pull "$mode" none pull build.example.com:mysite --yes --bench-dir "$BENCH"
done
accepted_run repair --for-agent env repair --yes --bench-dir "$BENCH"
accepted_run pull --for-agent env pull build.example.com:mysite --yes --bench-dir "$BENCH"
golden_check
# <<< accepted runs

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

# the lab gate on a start that has loaded little: the help of a command of a lab that is off is that refusal (exit 2), not
# its help, and the gate runs before the stream code is there. What it prints is what next-release prints (c3db5f05, the text
# is recorded from it), and no run ends with "command not found" (exit 127), which an unguarded call to the stream code made.
for mode in "" --for-agent --jsonl --json; do
  for c in "share setup" "share" "lan-guard install"; do
    # shellcheck disable=SC2086
    BENCHBAR_NONINTERACTIVE=1 run_fm_split $c --help $mode
    assert_eq "2" "$CODE" "($c --help $mode, lab off) $OUT $ERR"
    assert_not_contains "$OUT$ERR" "command not found" "($c --help $mode: the gate runs without the stream code)"
    case "$mode" in
      ""|--for-agent)
        assert_eq "  [FAIL] benchbar ${c%% *} is an experiment and it is off."$'\n\n'"Aborting. Turn it on: benchbar labs on lan-rooms" "$OUT" "($c --help $mode: the refusal, on stdout, as before)"
        assert_eq "" "$ERR" "($c --help $mode: nothing on stderr)" ;;
      *)
        assert_eq "benchbar ${c%% *} is an experiment and it is off. Turn it on: benchbar labs on lan-rooms" "$ERR" "($c --help $mode: stderr as before)"
        assert_contains "$OUT" "\"exit\":2" "($c --help $mode: the refusal document)"
        assert_contains "$OUT" "\"error\":\"benchbar ${c%% *} is an experiment and it is off.\"" "($c --help $mode: the refusal document says why)" ;;
    esac
  done
done
BENCHBAR_NONINTERACTIVE=1 run_fm_split commands --for-agent
assert_eq "0" "$CODE" "(commands --for-agent) $OUT $ERR"
assert_not_contains "$OUT$ERR" "command not found" "(commands --for-agent)"

# --- the non interactive preflight (a run nobody watches cannot be asked)
unset ADMIN_PASSWORD
for mode in --for-agent --jsonl --json; do
  bg_run "$mode" site add dev2.localhost --bundle minimal --bench-dir "$BENCH"
  bg_doc "site add, ADMIN_PASSWORD $mode" 1 "Cannot start, missing: ADMIN_PASSWORD"
  assert_contains "$OUT" '"missing":["ADMIN_PASSWORD"' "(site add $mode: the document says what is missing)"
  assert_eq "Cannot start, missing: ADMIN_PASSWORD (the Administrator password of the new site dev2.localhost); --yes (to add dev2.localhost to ${FL_HOSTS_FILE} with sudo). BENCHBAR_NONINTERACTIVE=1: nothing can be asked; pass them and run the command again. Nothing was changed." "$ERR" "(site add $mode: stderr is byte for byte what it was)"
  unchanged "site add preflight $mode"
  bg_run "$mode" install --bench-dir "$BENCH"
  bg_doc "install, --yes $mode" 1 "Cannot start, missing: --yes"
  assert_contains "$OUT" '"missing":["--yes"]' "(install $mode: the document says what is missing)"
  assert_eq "Cannot start, missing: --yes (to confirm the install plan). BENCHBAR_NONINTERACTIVE=1: nothing can be asked; pass them and run the command again. Nothing was changed." "$ERR" "(install $mode: stderr is byte for byte what it was)"
  unchanged "install preflight $mode"
done
bg_run --for-agent site restore bbtest.localhost --from 20260929_100001 --bench-dir "$BENCH"
bg_doc "site restore, --yes --for-agent" 1 "Cannot start, missing: --yes"
RESTORE_ERR="Cannot start, missing: --yes (to confirm the restore plan (or --apply TOKEN --yes)). BENCHBAR_NONINTERACTIVE=1: nothing can be asked; pass them and run the command again. Nothing was changed."
assert_eq "$RESTORE_ERR" "$ERR" "(site restore --for-agent: stderr is byte for byte what it was)"
bg_run --json site restore bbtest.localhost --from 20260929_100001 --bench-dir "$BENCH"
bg_doc "site restore, --yes --json" 1 "Cannot start, missing: --yes"
assert_eq "$RESTORE_ERR" "$ERR" "(site restore --json: stderr is byte for byte what it was)"
no_ops "preflight"

# --- the lease gate
BENCHBAR_NONINTERACTIVE=1 BENCHBAR_CALLER=agent-a run_fm_split lease take --bench "$BENCH" --for 20 --bench-dir "$BENCH"
assert_eq "0" "$CODE" "(lease take) $OUT $ERR"
LEASE="The bench ${BENCH} is leased by agent-a until 2027-01-15T08:20:00Z. Nothing was changed."
LEASE_ERR="  [FAIL] ${LEASE}"$'\n\n'"Aborting. Wait until it ends or ask the holder to release it; the holder passes --lease ID. A person at a terminal can pass --break-lease."
for mode in --for-agent --jsonl --json; do
  BENCHBAR_CALLER=agent-b bg_run "$mode" repair --yes --bench-dir "$BENCH"
  bg_done "repair, lease $mode" repair 1 "$LEASE" "$LEASE_ERR"
  assert_contains "$OUT" '"error_id":"lease_held"' "(repair, lease $mode: the stable id)"
  unchanged "repair lease $mode"
  BENCHBAR_CALLER=agent-b bg_run "$mode" pull build.example.com:mysite --yes --bench-dir "$BENCH"
  bg_done "pull, lease $mode" pull 1 "$LEASE" "$LEASE_ERR"; unchanged "pull lease $mode"
done
for mode in --for-agent --jsonl --json; do
  BENCHBAR_CALLER=agent-b bg_run "$mode" site add dev2.localhost --bundle minimal --yes --bench-dir "$BENCH"
  bg_done "site add, lease $mode" other 1 "is leased by agent-a" "$LEASE_ERR"; unchanged "site add lease $mode"
done
BENCHBAR_CALLER=agent-b bg_run --json app add erpnext --yes --bench-dir "$BENCH"
bg_silent "app add, lease --json" 1 "is leased by agent-a"; assert_eq "$LEASE_ERR" "$ERR" "(app add, lease --json: stderr is byte for byte what it was)"; unchanged "app add lease --json"
rm -f "$FL_STATE_DIR/leases.tsv"
unset FL_NOW
no_ops "lease"

# --- a refusal after the launch: the detached run was refused (the run lock is held, or the bench guess gate): the
# launcher says so with the run's message and exit code. This one IS an operation (its attempt is recorded, as before):
# one record, and the launcher's done line
mkdir -p "$FL_STATE_DIR/lock"; printf '%s\n' "$LIVE" >"$FL_STATE_DIR/lock/pid"
BUSY_ERR="  [FAIL] Another benchbar run is active (pid ${LIVE})."$'\n\n'"Aborting. See benchbar op status OPID and its log. Nothing was started; the attempt is recorded as OPID."
for mode in --for-agent --jsonl; do
  bg_run "$mode" site backup bbtest.localhost --yes --bench-dir "$BENCH"
  bg_done "site backup, lock busy $mode" other 1 "Another benchbar run is active" "$BUSY_ERR"
done
bg_run --json repair --yes --bench-dir "$BENCH"
bg_done "repair, lock busy --json" repair 1 "Another benchbar run is active" "$BUSY_ERR"
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
