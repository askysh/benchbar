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
