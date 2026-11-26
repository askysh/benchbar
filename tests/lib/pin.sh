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
#   pin_date, pin_commit     commits with fixed dates and content, so a sha is the same on every machine
#
# What changes from run to run is replaced first: the test's folder, time stamps, durations, ids,
# the token of a plan (it holds the bench's folder, which is new on every run), process ids, the user id in a launchctl call, the wording of mkdir when a folder exists, and the line number of an ERR trap
# message or a bash error (the lines of a file move; the function and the command stay).
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

pin_state() { printf '[state] %s: %s\n' "$1" "$2" >>"$PIN_FILE"; }

pin_check() {
  local golden="$ROOT/tests/golden/$1" norm="$TMP_DIR/pin.norm"
  sed -E -e 's#"token":"[0-9a-f]{64}"#"token":"<TOKEN>"#g' -e 's#"secs":[0-9]+#"secs":<N>#g' -e "s#${TMP_DIR}#<TMP>#g" -e "s#${ROOT}#<ROOT>#g" \
    -e 's#[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z#<TS>#g' \
    -e 's#([ (])[0-9]+s([ ),".]|$)#\1<N>s\2#g' \
    -e 's#/benches/frappe-bench-[^/ ]*#/benches/frappe-bench-<H>#g' \
    -e 's#op-[0-9]{8}-[0-9]{6}-[0-9]+(-[0-9]+)?#op-<ID>#g' \
    -e 's#/logs/[0-9]{8}-[0-9]{6}-[0-9]+#/logs/<LOG>#g' \
    -e 's#/tmp/benchbar-[a-z]+\.[A-Za-z0-9]+#/tmp/benchbar-X.<R>#g' \
    -e 's#gui/[0-9]+/#gui/<UID>/#g' \
    -e "s#mkdir: cannot create directory .*: File exists#mkdir: <EEXIST>#" -e 's#mkdir: Already exists#mkdir: <EEXIST>#' \
    -e 's#near line [0-9]+#near line N#g' -e 's#: line [0-9]+: #: line N: #g' -e 's#\.tmp\.[0-9]+#.tmp.<PID>#g' \
    "$PIN_FILE" >"$norm"
  if [[ "${PIN_UPDATE:-0}" == "1" ]]; then
    cp "$norm" "$golden"
    printf 'pin: wrote %s\n' "$golden"
    return 0
  fi
  [[ -f "$golden" ]] || fail "no golden file ${golden} (run with PIN_UPDATE=1 on a tree you trust)"
  if ! cmp -s "$norm" "$golden"; then
    diff -u "$golden" "$norm" | sed -n "1,80p" >&2 || true
    fail "the output of the pinned scenarios changed: ${1}"
  fi
}
