#!/usr/bin/env bash
# The refusal of the bench guess gate carries what to run in the JSON, as next_actions[] (#401, after #403).
#
# An agent (BENCHBAR_NONINTERACTIVE=1, --for-agent) that runs a command that changes things, names no bench and has
# more than one known is refused: "More than one bench is possible and none was chosen: A, B." and the hint "Choose
# one: benchbar LINE --bench-dir PATH". The hint is on stderr; an agent that reads only stdout saw `error` and no fix.
# The result envelope has a field for it: next_actions[], {"command", "why"}. Rules (maintainers/DECISIONS.md):
#   - one action for each bench the refusal names (the first five): the line that was typed, with --bench-dir and the
#     real path of that bench, shell quoted as the hint quotes its words ("quoted": true, so it runs as an argv array)
#   - then `benchbar list --json`, "see the known benches"
#   - a hint with a "..." (a secret, free text or an unknown word was left out) is no command: no action has the line
#     (the three dots would be taken for a word), only the list action, whose reason says that a word was left out and
#     that the command is to be run again with the words that were typed and --bench-dir with the path of a bench
#   - which modes print a JSON object does not change: --for-agent and --jsonl print one, plain --json prints nothing
#     for the refusal of a read (docs/json-schema.md) and stays that way; stderr is the text it was
#   - a refusal that is not this gate has no such actions
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/frappe-bench"
OTHER="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH" macdev
make_fake_bench "$OTHER" other
: >"$FL_HOSTS_FILE"
SECRET=s3cr3t
# what the preflight of a run nobody can ask asks for (it comes before the gate): fake values
export MARIADB_ROOT_PASSWORD=test-root-pw ADMIN_PASSWORD=test-admin-pw

fresh() { rm -f "$FL_STATE_FILE" "$FL_STATE_DIR/registered-benches.txt"; rm -rf "$FL_STATE_DIR/benches"; }
state_sum() { (cd "$FL_STATE_DIR" && find . -type f -print | LC_ALL=C sort | while IFS= read -r f; do printf '%s\n' "$f"; cat "$f"; done) | cksum; }

# check_actions NAME KIND: the JSON on stdout (OUT) and the text on stderr (ERR) of one refusal. KIND is runnable (every
# bench has an action with the typed line) or dropped (the hint has a "..."). The actions are checked against the
# hint on stderr, which is what a person reads: the same line, read by shlex, with each bench path for PATH.
check_actions() {
  local name="$1" kind="$2"
  printf '%s' "$OUT" | python3 -I -c '
import json, shlex, sys
name, kind, err = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.loads(sys.stdin.read())
assert d["exit"] == 1, (name, d)
assert d["error"].startswith("More than one bench is possible and none was chosen: "), (name, d)
benches = d["error"].split(": ", 1)[1].rstrip(".").split(", ")
hint = [l for l in err.splitlines() if "Choose one: " in l]
assert len(hint) == 1, (name, "the hint is not on stderr", err)
line = hint[0].split("Choose one: ", 1)[1].split(" (or set BENCH_DIR)", 1)[0]
words = shlex.split(line)
assert words[0] == "benchbar" and words[-2:] == ["--bench-dir", "PATH"], (name, words)
typed = words[1:-2]
acts = d["next_actions"]
assert acts and acts[-1]["command"] == "benchbar list --json", (name, "the last action is the list", acts)
assert acts[-1]["why"], (name, acts)
for a in acts:
    assert set(a) <= {"command", "why", "quoted"} and a["why"], (name, a)
rest = acts[:-1]
if kind == "dropped":
    assert "..." in typed, (name, typed)
    assert rest == [], (name, "a hint with ... is no command, so no action has the line", acts)
    why = acts[-1]["why"]
    # what to do instead: run the command again, with the words that were typed, --bench-dir and a bench of the list
    assert "left out" in why and "--bench-dir" in why and "typed" in why, (name, acts[-1])
else:
    assert "..." not in typed, (name, typed)
    shown = benches[:5]
    assert len(rest) == len(shown), (name, rest, shown)
    for a, b in zip(rest, shown):
        assert a["quoted"] is True, (name, a)
        w = shlex.split(a["command"])
        assert w == ["benchbar"] + typed + ["--bench-dir", b], (name, w, typed, b)
        assert a["why"] == "Run it on this bench", (name, a)
    assert "left out" not in acts[-1]["why"], (name, acts[-1])
assert all("..." not in a["command"] for a in acts), (name, "a command with ... in it", acts)
assert len(acts) <= 6, (name, len(acts))
' "$name" "$kind" "$ERR" || fail "($name) the next_actions are not the hint: $OUT"
}

# refused NAME KIND ARGS...: ARGS as an agent with two benches and no --bench-dir, under --for-agent: the JSON is the
# refusal with its actions, the text of stderr is the hint (and no JSON), nothing was written
refused() {
  local name="$1" kind="$2" before w args=() put=0
  shift 2
  # --for-agent goes where the line ends, or before a "--" (a word after it is not read as a flag)
  for w in "$@"; do
    if [[ "$w" == "--" && "$put" == 0 ]]; then args+=(--for-agent); put=1; fi
    args+=("$w")
  done
  [[ "$put" == 1 ]] || args+=(--for-agent)
  fresh
  before="$(state_sum)"
  BENCHBAR_NONINTERACTIVE=1 run_fm_split "${args[@]}"
  assert_eq "1" "$CODE" "($name) $OUT $ERR"
  assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c .)" "($name: one line on stdout) $OUT"
  assert_contains "$ERR" "More than one bench is possible and none was chosen: ${BENCH}, ${OTHER}." "($name: the refusal is on stderr)"
  assert_contains "$ERR" "Choose one: benchbar " "($name: the hint is on stderr)"
  assert_not_contains "$ERR" "next_actions" "($name: stderr has no JSON)"
  assert_not_contains "$ERR" "Run it on this bench" "($name: stderr has no actions)"
  check_actions "$name" "$kind"
  assert_not_contains "$OUT$ERR" "$SECRET" "($name: a word that was left out is not in any output)"
  assert_eq "$before" "$(state_sum)" "($name: the state is as it was)"
}

# accepted NAME ARGS...: each runnable action of the last refusal passes the gate when it is run as it is: with
# --dry-run where the typed line has one (so nothing is changed), and then it is not refused for the bench.
# These are real runs of the CLI of this checkout, and some change things (app unfocus writes the bench's state):
# they write only under the temp HOME of the harness (the fake benches and FL_STATE_DIR are inside it), never
# to a bench or a state folder of the machine.
accepted() {
  local name="$1" cmds c n=0 run=() sep=$'\x1f'
  # the words of each command, split as a shell splits them (shlex: quotes and escapes) and never run through
  # eval: a command from a JSON document is data. One command per line, its words joined by a unit separator.
  cmds="$(printf '%s' "$OUT" | python3 -I -c '
import json, shlex, sys
for a in json.loads(sys.stdin.read())["next_actions"][:-1]:
    print("\x1f".join(shlex.split(a["command"])))
')"
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    n=$((n + 1))
    IFS="$sep" read -r -a run <<<"$c"
    c="${run[*]}"
    [[ "${run[0]}" == benchbar ]] || fail "($name) an action does not start with benchbar: $c"
    BENCHBAR_NONINTERACTIVE=1 run_fm_split "${run[@]:1}"
    assert_not_contains "$OUT$ERR" "More than one bench is possible" "($name: action $n is accepted by the gate: $c)"
    assert_not_contains "$OUT$ERR" "acting on" "($name: action $n names its bench: $c)"
  done <<<"$cmds"
  [[ "$n" -ge 1 ]] || fail "($name) no runnable action to run"
}

# the actions of the list: benchbar list --json is a command that exists and runs
run_fm_split list --json
assert_eq "0" "$CODE" "(list --json) $OUT $ERR"

# --- a command that changes things, with an argument
refused "app unfocus NAME" runnable app unfocus frappe
assert_contains "$OUT" "\"command\":\"benchbar app unfocus frappe --for-agent --bench-dir ${BENCH}\"" "(app unfocus NAME: the typed line, --for-agent where it was typed, the first bench)"
assert_contains "$OUT" "\"command\":\"benchbar app unfocus frappe --for-agent --bench-dir ${OTHER}\"" "(app unfocus NAME: the second bench)"
accepted "app unfocus NAME"

# a command with a dry run: the actions are run with it
refused "site add" runnable site add dev2.localhost --bundle minimal --dry-run
accepted "site add"

# a name that needs quoting, a path that needs it too
refused "a name with a space" runnable app unfocus 'my app'
assert_contains "$OUT" 'benchbar app unfocus my\\ app --for-agent --bench-dir' "(a name with a space is quoted as the hint quotes it)"

# --- a word that was left out: the hint has "...", so no action has the line
BENCHBAR_LENIENT_FLAGS=1 refused "an unknown flag with a secret" dropped site default dev2.localhost --token "$SECRET"
BENCHBAR_LENIENT_FLAGS=1 refused "an unknown flag with a secret, =" dropped site default dev2.localhost "--token=$SECRET"
refused "a second word" dropped app unfocus frappe "$SECRET"
refused "a secret flag the command knows" dropped site restore dev2.localhost --apply "$SECRET" --yes
refused "free text" dropped lease take --site dev2.localhost --for 30 --note "for me"
refused "a word after --" dropped app update erpnext --dry-run -- "$SECRET" --x

# --- the three forms that write while their command reads (#400): their refusal is the read envelope
refused "app focus NAME" runnable app focus frappe
accepted "app focus NAME"
refused "doctor --ack" runnable doctor --ack hosts
accepted "doctor --ack"
refused "doctor --unack" runnable doctor --unack hosts
accepted "doctor --unack"
refused "app focus NAME, a second word" dropped app focus frappe "$SECRET"

# --- the other modes print what they printed: --jsonl a JSON object with the same actions, plain --json nothing
fresh
BENCHBAR_NONINTERACTIVE=1 run_fm_split app unfocus frappe --jsonl
assert_eq "1" "$CODE" "(app unfocus --jsonl) $OUT $ERR"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c .)" "(app unfocus --jsonl: one line) $OUT"
check_actions "app unfocus --jsonl" runnable
BENCHBAR_NONINTERACTIVE=1 run_fm_split app focus frappe --jsonl
assert_eq "1" "$CODE" "(app focus --jsonl) $OUT $ERR"
check_actions "app focus --jsonl" runnable
BENCHBAR_NONINTERACTIVE=1 run_fm_split app unfocus frappe --json
assert_eq "1" "$CODE" "(app unfocus --json) $OUT $ERR"
assert_eq "" "$OUT" "(app unfocus --json: a refused run prints nothing on stdout, as before)"
assert_contains "$ERR" "Choose one: benchbar app unfocus frappe --json --bench-dir PATH (or set BENCH_DIR). benchbar list shows them." "(app unfocus --json: the hint on stderr)"
BENCHBAR_NONINTERACTIVE=1 run_fm_split doctor --ack hosts --json
assert_eq "" "$OUT" "(doctor --ack --json: nothing on stdout, as before)"
# a person: the text is as it was, no JSON anywhere
fresh
BENCHBAR_NONINTERACTIVE=1 run_fm app unfocus frappe
assert_eq "1" "$CODE" "(plain) $OUT"
assert_not_contains "$OUT" "next_actions" "(plain: no JSON)"
assert_not_contains "$OUT" "Run it on this bench" "(plain: no actions)"

# --- a bench whose path has a space: its action holds the path as one word (read as a shell reads it), and the
#     action, run as it is, reaches that bench
fresh
SPACED="$HOME/my benches/bench one"
make_fake_bench "$SPACED" spaced
printf '%s\n' "$SPACED" >"$FL_STATE_DIR/registered-benches.txt"
BENCHBAR_NONINTERACTIVE=1 run_fm_split app unfocus frappe --for-agent
assert_eq "1" "$CODE" "(a bench path with a space) $OUT $ERR"
paths="$(printf '%s' "$OUT" | python3 -I -c '
import json, shlex, sys
for a in json.loads(sys.stdin.read())["next_actions"][:-1]:
    w = shlex.split(a["command"])
    i = w.index("--bench-dir")
    assert i == len(w) - 2, w
    print(w[i + 1])
')"
assert_eq "1" "$(printf '%s\n' "$paths" | grep -c -F -x -- "$SPACED" || true)" "(a bench path with a space is one word after --bench-dir) $paths"
assert_eq "3" "$(printf '%s\n' "$paths" | grep -c . || true)" "(one action per known bench: three) $paths"
accepted "a bench path with a space"
rm -f "$FL_STATE_DIR/registered-benches.txt"

# --- more than five benches: the first five, then the list
fresh
extra=()
for i in 3 4 5 6 7; do
  d="$HOME/more/bench$i"
  make_fake_bench "$d" "site$i"
  extra+=("$d")
done
printf '%s\n' "${extra[@]}" >"$FL_STATE_DIR/registered-benches.txt"
BENCHBAR_NONINTERACTIVE=1 run_fm_split app unfocus frappe --for-agent
assert_eq "1" "$CODE" "(seven benches) $OUT $ERR"
n="$(printf '%s' "$OUT" | python3 -I -c 'import json,sys; d=json.loads(sys.stdin.read()); print(len(d["next_actions"]), d["error"].count(", ") + 1, d["next_actions"][-1]["why"])')"
assert_eq "6 7 See all 7 known benches (the first five are listed above)" "$n" "(seven benches: five actions and the list, the list says how many)"
check_actions "seven benches" runnable
rm -f "$FL_STATE_DIR/registered-benches.txt"

# --- repair and pull: the stream is their own, and it opens in the command, after the gate (#405)
# Their refusal had no stream to end: stdout was empty in every mode, with the hint on stderr only. It is a done line now,
# the one their own early stops end with (repair: exit_code and exit, pull: exit and site), and the rest is as it was:
# the text on stderr byte for byte, and nothing written (no log, no lock, no operation, no history: the whole state folder,
# its empty folders too, is compared).
state_tree() {
  (cd "$FL_STATE_DIR" && find . -print | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s\n' "$f"
    if [[ -f "$f" ]]; then cat "$f"; fi
  done) | cksum
}
# own_refused NAME MODE ARGS...: ARGS and MODE as an agent types them, two benches, no --bench-dir
own_refused() {
  local name="$1" mode="$2" before want kind
  shift 2
  fresh
  before="$(state_tree)"
  BENCHBAR_NONINTERACTIVE=1 run_fm_split "$@" "$mode"
  assert_eq "1" "$CODE" "($name $mode) $OUT $ERR"
  assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c .)" "($name $mode: one JSON line on stdout) $OUT"
  check_actions "$name $mode" runnable
  # the done line of the command's own stream
  kind="$(printf '%s' "$OUT" | python3 -I -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["event"] == "done" and d["exit"] == 1 and d["schema_version"] == 1 and d["error"], d
assert d["changed"] == [] and d["warnings"] == [] and d["state_after"] is None, d
print("repair" if "exit_code" in d else "pull" if "site" in d else "other", d.get("exit_code", "-"))
')"
  case "$1" in repair) assert_eq "repair 1" "$kind" "($name $mode: repair keeps exit_code beside exit)" ;; pull) assert_eq "pull -" "$kind" "($name $mode: pull's done has exit and site)" ;; esac
  # stderr is what it was: the refusal, then the hint with the line that was typed
  want="  [FAIL] More than one bench is possible and none was chosen: ${BENCH}, ${OTHER}."$'\n\n'"Aborting. Choose one: benchbar $* ${mode} --bench-dir PATH (or set BENCH_DIR). benchbar list shows them."
  assert_eq "$want" "$ERR" "($name $mode: stderr is byte for byte what it was)"
  assert_eq "$before" "$(state_tree)" "($name $mode: nothing was written, not even a folder)"
}
for mode in --for-agent --jsonl --json; do
  own_refused "repair" "$mode" repair
  own_refused "repair --dry-run" "$mode" repair --dry-run
  own_refused "repair --yes" "$mode" repair --yes
  own_refused "pull" "$mode" pull build.example.com:mysite --dry-run
done
# the actions of the line that was typed, run as they are, are not refused for the bench (a dry run, as typed)
fresh
BENCHBAR_NONINTERACTIVE=1 run_fm_split repair --dry-run --for-agent
accepted "repair --dry-run"
# a hint with a word left out has the list action only, for these commands too
fresh
BENCHBAR_NONINTERACTIVE=1 run_fm_split pull build.example.com:mysite --dry-run --apply "$SECRET" --yes --for-agent
assert_eq "1" "$CODE" "(pull --apply) $OUT $ERR"
check_actions "pull --apply" dropped
assert_not_contains "$OUT$ERR" "$SECRET" "(pull --apply: the secret is in no output)"
# a bench that was named: the run goes on as it did, the stream is the command's own
BENCHBAR_NONINTERACTIVE=1 run_fm_split repair --dry-run --for-agent --bench-dir "$BENCH"
assert_eq "0" "$CODE" "(repair --bench-dir) $OUT $ERR"
assert_eq "plan done" "$(printf '%s\n' "$OUT" | python3 -I -c 'import json,sys; print(" ".join(json.loads(l)["event"] for l in sys.stdin if l.strip()))')" "(repair --dry-run --for-agent --bench-dir: plan, done)"
assert_not_contains "$OUT$ERR" "More than one bench" "(repair --bench-dir: no refusal)"
BENCHBAR_NONINTERACTIVE=1 run_fm_split repair --dry-run --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "(repair --dry-run --json --bench-dir) $OUT $ERR"
assert_eq "plan" "$(printf '%s\n' "$OUT" | python3 -I -c 'import json,sys; print(" ".join(json.loads(l)["event"] for l in sys.stdin if l.strip()))')" "(repair --dry-run --json: the plan alone, as before)"
BENCHBAR_NONINTERACTIVE=1 run_fm_split pull build.example.com:mysite --dry-run --for-agent --bench-dir "$BENCH"
assert_eq "1" "$CODE" "(pull --bench-dir) $OUT $ERR"
assert_contains "$OUT" '"error":"No SSH connection to build.example.com."' "(pull --bench-dir: its own early stop, as before)"
assert_not_contains "$OUT$ERR" "More than one bench" "(pull --bench-dir: no refusal)"
# one bench known: the starts print what they printed (a person's text, the plan alone, the plan and the done line)
mkdir -p "$TMP_DIR/off-bench"
mv "$OTHER" "$TMP_DIR/off-bench/frappe-bench"
fresh
BENCHBAR_NONINTERACTIVE=1 run_fm_split repair --dry-run --json
assert_eq "0" "$CODE" "(one bench, repair --dry-run --json) $OUT $ERR"
assert_eq "plan" "$(printf '%s\n' "$OUT" | python3 -I -c 'import json,sys; print(" ".join(json.loads(l)["event"] for l in sys.stdin if l.strip()))')" "(one bench, repair --dry-run --json: the plan alone)"
BENCHBAR_NONINTERACTIVE=1 run_fm_split repair --dry-run --for-agent
assert_eq "plan done 0" "$(printf '%s\n' "$OUT" | python3 -I -c 'import json,sys; e = [json.loads(l) for l in sys.stdin if l.strip()]; print(" ".join(x["event"] for x in e), e[-1]["exit_code"])')" "(one bench, repair --dry-run --for-agent: plan, done, exit 0)"
assert_not_contains "$OUT" "Run it on this bench" "(one bench: no gate action)"
BENCHBAR_NONINTERACTIVE=1 run_fm_split repair --yes --json
assert_eq "done $CODE" "$(printf '%s\n' "$OUT" | python3 -I -c 'import json,sys; e = [json.loads(l) for l in sys.stdin if l.strip()]; print(e[-1]["event"], e[-1]["exit_code"])')" "(one bench, repair --yes --json: ends with its done line, as before) $OUT $ERR"
assert_not_contains "$OUT$ERR" "More than one bench" "(one bench, repair --yes --json: no refusal)"
BENCHBAR_NONINTERACTIVE=1 run_fm_split repair --dry-run
assert_eq "0" "$CODE" "(one bench, repair --dry-run, plain) $OUT $ERR"
assert_not_contains "$OUT" '"event"' "(one bench, plain: text, no JSON)"
mv "$TMP_DIR/off-bench/frappe-bench" "$OTHER"

# --- the stream opens in the dispatch, before the gates (#405, review): a refusal of the gates that come before the
# guess gate (the lab gate, the lease gate) is a done line for repair and pull too, and a run that goes on prints what it did
# the lease gate: a lease of another caller on the bench. The lease is the only thing the refusals leave in the state
# folder (state_tree is compared after it was taken), so no log, run lock, operation record or history was made before it.
export FL_NOW=1800000000
fresh
BENCHBAR_NONINTERACTIVE=1 BENCHBAR_CALLER=agent-a run_fm_split lease take --bench "$BENCH" --for 20 --bench-dir "$BENCH"
assert_eq "0" "$CODE" "(lease take) $OUT $ERR"
before="$(state_tree)"
for mode in --for-agent --jsonl --json; do
  for cmd in "repair --yes" "pull build.example.com:mysite --yes"; do
    # shellcheck disable=SC2086
    BENCHBAR_NONINTERACTIVE=1 BENCHBAR_CALLER=agent-b run_fm_split $cmd $mode --bench-dir "$BENCH"
    assert_eq "1" "$CODE" "($cmd $mode, lease) $OUT $ERR"
    assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c .)" "($cmd $mode, lease: one JSON line on stdout) $OUT"
    kind="$(printf '%s' "$OUT" | python3 -I -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["event"] == "done" and d["exit"] == 1, d
# the done lines of repair and pull both carry the stable id of the refusal (#410)
assert d.get("error_id") == "lease_held", d
assert d["error"] == sys.argv[1] + " is leased by agent-a until 2027-01-15T08:20:00Z. Nothing was changed.", d
assert d["next_actions"] == [] and d["changed"] == [] and d["state_after"] is None, d
print("repair" if "exit_code" in d else "pull")
' "The bench ${BENCH}")"
    assert_eq "${cmd%% *}" "$kind" "($cmd $mode, lease: the command's own done line)"
    want="  [FAIL] The bench ${BENCH} is leased by agent-a until 2027-01-15T08:20:00Z. Nothing was changed."$'\n\n'"Aborting. Wait until it ends or ask the holder to release it; the holder passes --lease ID. A person at a terminal can pass --break-lease."
    assert_eq "$want" "$ERR" "($cmd $mode, lease: stderr is byte for byte what it was)"
    assert_eq "$before" "$(state_tree)" "($cmd $mode, lease: nothing written but the lease)"
  done
done
rm -f "$FL_STATE_DIR/leases.tsv"
unset FL_NOW
# the lab gate: repair and pull are behind no Lab (a Lab gates share and lan-guard), so the early open has nothing to
# do for one; a Lab that is off still refuses another command as it did, with its own done line and its own text
assert_eq "" "$(grep '^lab~' "$ROOT/lib/frappe-local/labs.sh" | awk -F'~' '{print $7}' | tr ',' '\n' | grep -x -e repair -e pull || true)" "(no Lab gates repair or pull)"
for mode in --for-agent --jsonl --json; do
  BENCHBAR_NONINTERACTIVE=1 run_fm_split share start --dry-run "$mode" --bench-dir "$BENCH"
  assert_eq "2" "$CODE" "(share start $mode, lab off) $OUT $ERR"
  assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c .)" "(share start $mode, lab off: one line) $OUT"
  assert_not_contains "$OUT" "exit_code" "(share start $mode, lab off: not a repair line)"
  assert_eq "  [FAIL] benchbar share is an experiment and it is off."$'\n\n'"Aborting. Turn it on: benchbar labs on lan-rooms" "$ERR" "(share start $mode, lab off: stderr as it was)"
done
# a run that goes on: one plan, one done, in this order, and a command with no stream of its own is not touched
events() { printf '%s\n' "$OUT" | python3 -I -c 'import json,sys; print(" ".join(json.loads(l)["event"] for l in sys.stdin if l.strip()))'; }
BENCHBAR_NONINTERACTIVE=1 run_fm_split repair --yes --json --bench-dir "$BENCH"
assert_eq "plan" "$(events | cut -d' ' -f1)" "(repair --yes --json: the plan comes first) $OUT"
assert_eq "1" "$(events | tr ' ' '\n' | grep -c -x 'plan')" "(repair --yes --json: one plan line)"
assert_eq "1" "$(events | tr ' ' '\n' | grep -c -x 'done')" "(repair --yes --json: one done line)"
assert_eq "done" "$(events | awk '{print $NF}')" "(repair --yes --json: the done line is last)"
assert_eq "" "$ERR" "(repair --yes --json: nothing on stderr)"
BENCHBAR_NONINTERACTIVE=1 run_fm_split repair --for-agent --bench-dir "$BENCH"
assert_eq "1" "$(events | tr ' ' '\n' | grep -c -x 'plan')" "(repair --for-agent: one plan line) $OUT"
assert_eq "done" "$(events | awk '{print $NF}')" "(repair --for-agent: the done line is last)"
BENCHBAR_NONINTERACTIVE=1 run_fm_split pull build.example.com:mysite --dry-run --json --bench-dir "$BENCH"
assert_eq "done" "$(events)" "(pull --dry-run --json: its own early stop, one done line) $OUT"
BENCHBAR_NONINTERACTIVE=1 run_fm_split site add dev2.localhost --dry-run --for-agent --bench-dir "$BENCH"
assert_eq "plan done" "$(events)" "(site add --dry-run --for-agent: as before) $OUT"
assert_not_contains "$OUT" "exit_code" "(site add: no repair field)"
BENCHBAR_NONINTERACTIVE=1 run_fm_split status --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "(status --json) $OUT $ERR"
assert_not_contains "$OUT" '"event"' "(status --json: one document, no stream)"

# --- the run lock is busy: another run holds it (#410 pins what #405 gave: since the stream is open before the lock is
# asked for, the refusal is a done line too). repair and pull make their run log and their operation record before the
# lock, so a refusal is recorded as an operation that failed, as it was before #405: the log, the record (failed, exit 1)
# and one history line. It takes no lock of ours, and the lock stays the other run's. This passes on the base of #410.
fresh
mkdir -p "$FL_STATE_DIR/lock"
sleep 600 &
LIVEPID=$!
on_exit "kill $LIVEPID 2>/dev/null"
printf '%s\n' "$LIVEPID" >"$FL_STATE_DIR/lock/pid"
files_now() { (cd "$FL_STATE_DIR" && find . -type f | LC_ALL=C sort); }
before_files="$(files_now)"
hist_before="$(wc -l <"$FL_STATE_DIR/history.jsonl" 2>/dev/null || echo 0)"
hist_before="${hist_before//[[:space:]]/}"
for mode in --for-agent --jsonl --json; do
  for cmd in "repair --yes" "pull build.example.com:mysite --yes"; do
    # shellcheck disable=SC2086
    BENCHBAR_NONINTERACTIVE=1 run_fm_split $cmd $mode --bench-dir "$BENCH"
    assert_eq "1" "$CODE" "($cmd $mode, run lock busy) $OUT $ERR"
    assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c .)" "($cmd $mode, run lock busy: one JSON line on stdout) $OUT"
    kind="$(printf '%s' "$OUT" | python3 -I -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["event"] == "done" and d["exit"] == 1, d
assert d["error"] == "Another benchbar run is active (pid " + sys.argv[1] + ").", d
assert d["changed"] == [] and d["warnings"] == [] and d["next_actions"] == [], d
assert d["op_id"].startswith("op-"), d
print("repair" if "exit_code" in d else "pull")
' "$LIVEPID")"
    assert_eq "${cmd%% *}" "$kind" "($cmd $mode, run lock busy: the command's own done line)"
    want="  [FAIL] Another benchbar run is active (pid ${LIVEPID})."$'\n\n'"Aborting. Wait for it to finish, or remove ${FL_STATE_DIR}/lock if you are sure it is dead."
    assert_eq "$want" "$ERR" "($cmd $mode, run lock busy: stderr is what it was)"
    assert_eq "$LIVEPID" "$(cat "$FL_STATE_DIR/lock/pid")" "($cmd $mode, run lock busy: the lock is the other run's)"
  done
done
new_files="$(comm -13 <(printf '%s\n' "$before_files") <(files_now))"
assert_eq "6" "$(printf '%s\n' "$new_files" | grep -c '^\./logs/' || true)" "(run lock busy: six refusals, six run logs)"
assert_eq "6" "$(printf '%s\n' "$new_files" | grep -c '^\./ops/op-.*\.json$' || true)" "(run lock busy: six operation records)"
assert_eq "0" "$(printf '%s\n' "$new_files" | grep -vc -e '^\./logs/' -e '^\./ops/op-.*\.json$' || true)" "(run lock busy: nothing else is new)"
assert_eq "6" "$(( $(wc -l <"$FL_STATE_DIR/history.jsonl") - hist_before ))" "(run lock busy: six history lines)"
failed=0
for f in $(printf '%s\n' "$new_files" | grep '^\./ops/'); do
  if grep -q '"state":"failed".*"exit":1' "$FL_STATE_DIR/$f"; then failed=$((failed + 1)); fi
done
assert_eq "6" "$failed" "(run lock busy: every record says failed, exit 1)"
assert_eq "6" "$(tail -n 6 "$FL_STATE_DIR/history.jsonl" | grep -c '"exit":1' || true)" "(run lock busy: every history line says exit 1)"
# the lock is still the other run's, and goes with it
rm -f "$FL_STATE_DIR/lock/pid"; rmdir "$FL_STATE_DIR/lock"

# --- pull's done line carries what repair's carries (#410): the stable id of the refusal and the inputs that were missing.
# A lease refused it above (error_id lease_held). The preflight is the other refusal that has such a field: pull asks for
# the MariaDB root password, and a run nobody can ask is refused with `missing`. It is ONE done line, in every mode: the
# preflight printed its own refusal document when the stream was not its own, and the stream of pull is its own.
fresh
for mode in --for-agent --jsonl --json; do
  BENCHBAR_NONINTERACTIVE=1 MARIADB_ROOT_PASSWORD="" run_fm_split pull build.example.com:mysite --yes "$mode" --bench-dir "$BENCH"
  assert_eq "2" "$CODE" "(pull, no root password $mode) $OUT $ERR"
  assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c .)" "(pull, no root password $mode: one JSON line on stdout) $OUT"
  printf '%s' "$OUT" | python3 -I -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["event"] == "done" and d["exit"] == 2, d
assert d["missing"] == ["MARIADB_ROOT_PASSWORD"], d
assert d["error"].startswith("Cannot start, missing: MARIADB_ROOT_PASSWORD"), d
' || fail "(pull, no root password $mode) not the done line with what is missing: $OUT"
  assert_contains "$ERR" "Cannot start, missing: MARIADB_ROOT_PASSWORD" "(pull, no root password $mode: the text is on stderr)"
done

# --- a refusal that is not this gate has no such actions
fresh
BENCHBAR_NONINTERACTIVE=1 run_fm_split app unfocus frappe --nosuchflag --for-agent
assert_eq "64" "$CODE" "(an unknown flag) $OUT $ERR"
assert_eq "[]" "$(printf '%s' "$OUT" | python3 -I -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read())["next_actions"]))')" "(an unknown flag: no next_actions)"
assert_not_contains "$OUT" "bench-dir" "(an unknown flag: no bench action)"
# the gate that does not refuse (one bench is known, or a bench was named) adds nothing
BENCHBAR_NONINTERACTIVE=1 run_fm_split app unfocus frappe --for-agent --bench-dir "$BENCH"
assert_eq "0" "$CODE" "(--bench-dir) $OUT $ERR"
assert_not_contains "$OUT" "Run it on this bench" "(--bench-dir: no gate actions)"

printf 'test-gate-next-actions: ok\n'
