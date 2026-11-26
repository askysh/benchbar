#!/usr/bin/env bash
# The forms that write benchbar's state while the command reads (#371): app focus NAME, doctor --ack ID and
# doctor --unack ID. The table keeps `doctor` and `app focus` at "mutating no" (flipping it would make
# plain `doctor --json` refuse for an agent when two benches are known), so the bench guess gate of the
# commands that change things (CORE-4, benchbar: "acting on ...") is applied where these forms write:
#   - with two benches known and no --bench-dir, an agent (BENCHBAR_NONINTERACTIVE=1) is refused before
#     anything is written, with the words of the other commands
#   - a person is told which bench was picked, and the write goes on
#   - with --bench-dir (or a remembered bench) nothing is said and the write goes on
#   - the forms that only read behave as they did
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/frappe-bench"
OTHER="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH" macdev
make_fake_bench "$OTHER" other
# a hosts file without the site: doctor warns about "hosts", so there is something to acknowledge
: >"$FL_HOSTS_FILE"

# fresh: no remembered bench and no bench state: both benches are only known, so one is guessed
fresh() { rm -f "$FL_STATE_FILE"; rm -rf "$FL_STATE_DIR/benches"; }
state_has() { grep -rq -- "$1" "$FL_STATE_DIR" 2>/dev/null; }
# expect_state KEY present|absent LABEL
expect_state() {
  if [[ "$2" == present ]]; then state_has "$1" || fail "$3: the state has no $1"
  elif state_has "$1"; then fail "$3: the state has $1"; fi
}

# gate_cases NAME KEY START-ARGS... -- ARGS...: the form ARGS, in four situations
#   KEY is what its write leaves in the state of the bench (looked for with grep)
#   START-ARGS (before --) writes the starting state with --bench-dir, or is empty
check_form() {
  local name="$1" key="$2" want="$3" before start=() form=()
  # what the state holds before the form runs: the opposite of what it leaves
  if [[ "$want" == present ]]; then before=absent; else before=present; fi
  shift 3
  while [[ "$1" != "--" ]]; do start+=("$1"); shift; done
  shift
  form=("$@")

  # an agent, no --bench-dir, two benches: refused, nothing written
  fresh
  if [[ "${#start[@]}" -gt 0 ]]; then run_fm "${start[@]}" --bench-dir "$BENCH"; assert_eq "0" "$CODE" "(${name}: the starting state) $OUT"; fi
  BENCHBAR_NONINTERACTIVE=1 run_fm "${form[@]}"
  assert_eq "1" "$CODE" "(${name}, an agent) $OUT"
  assert_contains "$OUT" "More than one bench is possible" "(${name}, an agent)"
  assert_contains "$OUT" "$BENCH" "(${name}: both benches are named)"
  assert_contains "$OUT" "$OTHER" "(${name}: both benches are named)"
  assert_contains "$OUT" "--bench-dir" "(${name}: says how to choose)"
  expect_state "$key" "$before" "${name}, an agent that named no bench (nothing is written)"

  # a person: told which bench, and the write goes on
  run_fm "${form[@]}"
  assert_eq "0" "$CODE" "(${name}, a person) $OUT"
  assert_contains "$OUT" "acting on" "(${name}, a person: the notice)"
  assert_contains "$OUT" "2 benches are known" "(${name}, a person: the notice says how many)"
  expect_state "$key" "$want" "${name}, a person"

  # --bench-dir: nothing guessed, nothing said, the write goes on
  fresh
  if [[ "${#start[@]}" -gt 0 ]]; then run_fm "${start[@]}" --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"; fi
  BENCHBAR_NONINTERACTIVE=1 run_fm "${form[@]}" --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "(${name} with --bench-dir) $OUT"
  assert_not_contains "$OUT" "acting on" "(${name} with --bench-dir)"
  assert_not_contains "$OUT" "More than one bench" "(${name} with --bench-dir)"
  expect_state "$key" "$want" "${name} with --bench-dir"
}

check_form "app focus NAME" APP_FOCUS present -- app focus frappe
check_form "doctor --ack" ACK_hosts present -- doctor --ack hosts
check_form "doctor --unack" ACK_hosts absent doctor --ack hosts -- doctor --unack hosts

# app unfocus NAME is a different case: its table record says "mutating yes" (it only writes, it has no reading
# form), so the dispatch gates it and the write does not (part 1 leaves it out of the write gates). Pin that:
# the same four situations as above, then the refusal in every output mode, for it and for the three forms above.
check_form "app unfocus NAME" APP_FOCUS present -- app unfocus frappe

# the whole state folder (the state file, each bench's own file, the plan key the plan tokens are signed with, and
# anything else a run leaves there) as one number: a refused run must leave it byte for byte as it was
state_sum() { (cd "$FL_STATE_DIR" && find . -type f -print | LC_ALL=C sort | while IFS= read -r f; do printf '%s\n' "$f"; cat "$f"; done) | cksum; }
# count_lines TEXT PATTERN: the lines of TEXT that match PATTERN (a basic regular expression)
count_lines() { printf '%s\n' "$1" | grep -c -- "$2" || true; }

# refusal_checks NAME HINT START-ARGS... -- ARGS...: the refusal of a form that writes, for an agent, in every output mode
#   HINT is the command the refusal tells the agent to run instead ("" when it is not asserted)
#   START-ARGS (before --) writes the starting state with --bench-dir, or is empty
refusal_checks() {
  local name="$1" hint="$2" start=() form=() before
  shift 2
  while [[ "$1" != "--" ]]; do start+=("$1"); shift; done
  shift
  form=("$@")
  fresh
  if [[ "${#start[@]}" -gt 0 ]]; then run_fm "${start[@]}" --bench-dir "$BENCH"; assert_eq "0" "$CODE" "(${name}: the starting state) $OUT"; fi
  before="$(state_sum)"

  # plain text: refused, one [FAIL] line (the refusal), no check ran, the state is as it was
  BENCHBAR_NONINTERACTIVE=1 run_fm "${form[@]}"
  assert_eq "1" "$CODE" "(${name}, an agent) $OUT"
  assert_eq "1" "$(count_lines "$OUT" '\[FAIL\]')" "(${name}, an agent: the refusal is the only [FAIL] line) $OUT"
  assert_not_contains "$OUT" "[OK]" "(${name}, an agent: no check ran)"
  assert_not_contains "$OUT" "[WARN]" "(${name}, an agent: no check ran)"
  assert_eq "$before" "$(state_sum)" "(${name}, an agent: the state is as it was)"
  [[ -z "$hint" ]] || assert_contains "$OUT" "$hint" "(${name}: the hint is the form that was typed, with the bench)"

  # --json: a read that is refused prints nothing on stdout (docs/json-schema.md, the result envelope); the
  # refusal is text on stderr, the exit code is 1. The document the doctor forms open first must not leak.
  BENCHBAR_NONINTERACTIVE=1 run_fm_split "${form[@]}" --json
  assert_eq "1" "$CODE" "(${name} --json) $OUT $ERR"
  assert_eq "" "$OUT" "(${name} --json: nothing on stdout)"
  assert_contains "$ERR" "More than one bench is possible" "(${name} --json: the refusal is on stderr)"
  assert_eq "1" "$(count_lines "$ERR" '\[FAIL\]')" "(${name} --json: one refusal) $ERR"
  assert_not_contains "$ERR" "[OK]" "(${name} --json: no check ran)"
  assert_not_contains "$ERR" "[WARN]" "(${name} --json: no check ran)"
  assert_eq "$before" "$(state_sum)" "(${name} --json: the state is as it was)"

  # --for-agent: stdout is one line, one JSON object that ends the run with exit 1 and the refusal as its error
  BENCHBAR_NONINTERACTIVE=1 run_fm_split "${form[@]}" --for-agent
  assert_eq "1" "$CODE" "(${name} --for-agent) $OUT $ERR"
  assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c .)" "(${name} --for-agent: one line on stdout) $OUT"
  assert_eq "1 True True" "$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["exit"], "More than one bench is possible" in d["error"], "checks" not in d)')" "(${name} --for-agent: one error object, no checks) $OUT"
  assert_eq "$before" "$(state_sum)" "(${name} --for-agent: the state is as it was)"

  # --bench-dir with --json: the write goes on and stdout is one JSON document
  run_fm_split "${form[@]}" --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "(${name} --json --bench-dir) $OUT $ERR"
  assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c .)" "(${name} --json --bench-dir: one line on stdout) $OUT"
  assert_eq "ok" "$(printf '%s' "$OUT" | python3 -c 'import json,sys; json.loads(sys.stdin.read()); print("ok")')" "(${name} --json --bench-dir: a JSON document) $OUT"
}

refusal_checks "app focus NAME" "benchbar app focus frappe --bench-dir PATH" -- app focus frappe
refusal_checks "doctor --ack" "benchbar doctor --ack hosts --bench-dir PATH" -- doctor --ack hosts
refusal_checks "doctor --unack" "benchbar doctor --unack hosts --bench-dir PATH" doctor --ack hosts -- doctor --unack hosts
# app unfocus: gated by the dispatch, so its refusal is the one of every command that changes things: under
# --for-agent a stream that ends with one done line. (Its hint names `benchbar app unfocus --bench-dir PATH`, without
# NAME, as that of every command that goes through the dispatch gate does: not asserted here.)
refusal_checks "app unfocus NAME" "" -- app unfocus frappe

# a person gets the notice once
fresh
run_fm app unfocus frappe
assert_eq "0" "$CODE" "(app unfocus, a person) $OUT"
assert_eq "1" "$(count_lines "$OUT" 'acting on')" "(app unfocus, a person: one notice, not two)"
run_fm app focus frappe
assert_eq "1" "$(count_lines "$OUT" 'acting on')" "(app focus NAME, a person: one notice)"

# app unfocus --for-agent: the stream ends with one done line, with a bench and with the refusal
fresh
run_fm_split app unfocus frappe --for-agent --bench-dir "$BENCH"
assert_eq "0" "$CODE" "(app unfocus --for-agent --bench-dir) $OUT $ERR"
assert_eq "1" "$(count_lines "$OUT" '"event":"done"')" "(app unfocus --for-agent: one done line)"
assert_not_contains "$OUT$ERR" "acting on" "(app unfocus --for-agent --bench-dir)"
BENCHBAR_NONINTERACTIVE=1 run_fm_split app unfocus frappe --for-agent
assert_eq "1" "$CODE" "(app unfocus --for-agent, refused) $OUT"
assert_eq "1" "$(count_lines "$OUT" '"event":"done"')" "(app unfocus --for-agent, refused: one done line) $OUT"

# the forms that only read: no notice, no refusal, for an agent and for a person
fresh
for form in "doctor" "doctor --json" "doctor --fix-hints" "app focus" "app focus --list" "app focus --json"; do
  # shellcheck disable=SC2086
  BENCHBAR_NONINTERACTIVE=1 run_fm $form
  assert_not_contains "$OUT" "More than one bench is possible" "(${form}, an agent)"
  assert_not_contains "$OUT" "acting on" "(${form}, an agent)"
  # shellcheck disable=SC2086
  run_fm $form
  assert_not_contains "$OUT" "acting on" "(${form}, a person)"
done

printf 'test-write-forms-gate: ok\n'
