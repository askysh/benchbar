#!/usr/bin/env bash
#
# pin.sh: pin what a command prints, byte for byte, as a golden file.
#
# A refactor that must not change behaviour (the steps of a long function, issue 146) is held by
# a file that holds, for each scenario, the exit code, stdout, stderr and what the mocks were
# asked to run. The same scenarios run before and after the change and the file does not move.
#
#   pin_run NAME ARGS...     run benchbar with the streams kept apart and add its result under NAME
#   pin_state LABEL TEXT     add a line about the disk (a record, a commit)
#   pin_check GOLDEN         compare with tests/golden/GOLDEN, or write it when PIN_UPDATE=1
#   pin_full                 true when every scenario runs (see below)
#   pin_smoke_end GOLDEN     the end of the smoke scenarios
#   pin_date, pin_commit     commits with fixed dates and content, so a sha is the same on every machine
#
# Full and smoke. The golden file always holds every scenario, and a pin test runs all of them unless PIN_SMOKE says
# otherwise: PIN_SMOKE=1 runs the smoke scenarios of every pin test, PIN_SMOKE="test-a-pin test-b-pin" those of the
# tests named (their names without .sh), and nothing, 0 or PIN_UPDATE=1 all scenarios. CI sets PIN_SMOKE only on a
# pull request whose plan says so (scripts/ci-plan.sh); every other caller (a push, the nightly run, a release build,
# a person) gets the full set without knowing about it. The smoke scenarios are the ones outside an
# "if pin_full; then ... fi" block; pin_check compares each of them with its own block of the golden file, by name.
# What a skipped scenario leaves behind (a commit, a moved head, a record) must still be there for the next one, or
# that one differs from the golden file: do the cheap setup outside the block, or put back by hand what the skipped
# run would have left. PIN_UPDATE=1 always runs everything and writes the whole file. PIN_GOLDEN_DIR (default
# tests/golden) is where the golden files are.
#
# What changes from run to run or from machine to machine is replaced first: the test's folder, then the rules of
# tests/lib/pin.sed (time stamps, durations, ids, plan tokens, the widths of boxes and tables, the line number of an ERR
# trap message: the lines of a file move, the function and the command stay).
# shellcheck shell=bash

PIN_FILE="$TMP_DIR/pin.out"
: >"$PIN_FILE"

# pin_date: the next fixed commit date
PIN_N=0
pin_date() {
  local d
  PIN_N=$((PIN_N + 1))
  d="2026-01-01T00:00:$(printf '%02d' "$PIN_N")Z"
  export GIT_AUTHOR_DATE="$d" GIT_COMMITTER_DATE="$d"
}
# pin_commit DIR NAME N: N commits on main of the work folder DIR, pushed
pin_commit() {
  local i
  for i in $(seq 1 "$3"); do
    pin_date
    (
      cd "$1" || exit 1
      git checkout -q main
      printf 'change %s\n' "$PIN_N" >>"$2/changes.txt"
      git add -A && git commit -q -m "${2}: change ${PIN_N}"
      git push -q origin main
    )
  done
}
pin_date

# pin_run NAME ARGS...: stdout and stderr apart (stdin is not a terminal), then the mock calls
pin_run() {
  local name="$1" code
  shift
  reset_calls
  set +e
  "$FM" "$@" >"$MOCK_STATE/pin.stdout" 2>"$MOCK_STATE/pin.stderr" </dev/null
  code="$?"
  set -e
  {
    printf '=== %s\n' "$name"
    printf 'exit: %s\n' "$code"
    printf -- '--- stdout\n'; cat "$MOCK_STATE/pin.stdout"
    printf -- '--- stderr\n'; cat "$MOCK_STATE/pin.stderr"
    printf -- '--- calls\n'; cat "$MOCK_LOG"
  } >>"$PIN_FILE"
  PIN_CODE="$code"
  PIN_STDOUT="$(cat "$MOCK_STATE/pin.stdout")"
}

# pin_full: every scenario runs. Not with PIN_SMOKE=1, nor when PIN_SMOKE names this test; PIN_UPDATE=1 always does
pin_full() {
  [[ "${PIN_UPDATE:-0}" == "1" ]] && return 0
  local me="${0##*/}"
  case "${PIN_SMOKE:-}" in "" | 0) return 0 ;; 1) return 1 ;; esac
  case " ${PIN_SMOKE} " in *" ${me%.sh} "*) return 1 ;; esac
  return 0
}

pin_state() { printf '[state] %s: %s\n' "$1" "$2" >>"$PIN_FILE"; }

# pin_scenarios FILE: the scenario names of a pin file, one per line
pin_scenarios() { sed -n 's/^=== //p' "$1"; }

pin_check() {
  local golden="${PIN_GOLDEN_DIR:-$ROOT/tests/golden}/$1" norm="$TMP_DIR/pin.norm" want="$TMP_DIR/pin.want" names="$TMP_DIR/pin.names" dup total n
  sed -E -e "s#${TMP_DIR}#<TMP>#g" -e "s#${ROOT}#<ROOT>#g" -f "$ROOT/tests/lib/pin.sed" "$PIN_FILE" >"$norm"
  pin_scenarios "$norm" >"$names"
  dup="$(sort "$names" | uniq -d | sed -n '1p')"
  [[ -z "$dup" ]] || fail "two scenarios are called '${dup}': the name is how a smoke run finds its part of the golden file"
  if [[ "${PIN_UPDATE:-0}" == "1" ]]; then
    cp "$norm" "$golden"
    printf 'pin: wrote %s\n' "$golden"
    return 0
  fi
  [[ -f "$golden" ]] || fail "no golden file ${golden} (run with PIN_UPDATE=1 on a tree you trust)"
  if pin_full; then
    cp "$golden" "$want"
  else
    # smoke: the blocks of the golden file ("=== NAME" up to the next one) of the scenarios that ran, in the file's order
    dup="$(pin_scenarios "$golden" | sort | uniq -d | sed -n '1p')"
    [[ -z "$dup" ]] || fail "the golden file ${1} has two blocks called '${dup}': a smoke run cannot tell which one is its own. Write the file again (PIN_UPDATE=1 bash tests/${0##*/})."
    awk 'NR == FNR { keep["=== " $0] = 1; next } /^=== / { on = ($0 in keep) } on' "$names" "$golden" >"$want"
    n="$(awk 'END { print NR }' "$names")"
    total="$(pin_scenarios "$golden" | awk 'END { print NR }')"
    [[ "$n" -gt 0 ]] || fail "a smoke run with no scenario in it: ${1}"
    printf 'pin: smoke, %s of %s scenarios of %s (bash tests/%s runs all of them)\n' "$n" "$total" "$1" "${0##*/}"
  fi
  if ! cmp -s "$norm" "$want"; then
    diff -u "$want" "$norm" | sed -n "1,80p" >&2 || true
    fail "the output of the pinned scenarios changed: ${1}. If the change is meant, write the golden again on a tree you trust: PIN_UPDATE=1 bash tests/${0##*/} (then read the diff of tests/golden/ before you commit it)."
  fi
}

# pin_smoke_end GOLDEN: the end of the smoke scenarios. A smoke run compares what it ran with the golden file and stops
# here; a full run goes on with the scenarios below. What the lines below do is not needed by anything above.
pin_smoke_end() {
  pin_full && return 0
  pin_check "$1"
  printf '%s: ok (smoke)\n' "${0##*/}"
  exit 0
}
