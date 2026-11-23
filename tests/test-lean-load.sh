#!/usr/bin/env bash
# The lean start (benchbar, "Lean start"): path, commands, --version, --help
# and the other read only commands the app and the shell helpers run all day
# load only the libraries they use. Parsing the other libraries was most of
# their cost. This test holds two things:
#   1. the lean start prints exactly what the full load prints (stdout,
#      stderr and exit code), and never reaches a function that was not loaded
#   2. the lean start does not source the libraries of the heavy commands
# BENCHBAR_LOAD_ALL=1 forces the full load.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/work/a/frappe-bench"
make_fake_bench "$BENCH" macdev
printf '127.0.0.1 macdev\n' >>"$FL_HOSTS_FILE"
run_fm register "$BENCH"
assert_eq 0 "$CODE" "(register a fake bench: $OUT)"
run_fm service --yes --bench-dir "$BENCH"
assert_eq 0 "$CODE" "(a service for it: $OUT)"
printf '3306 111 mariadbd 127.0.0.1\n' >"$MOCK_LISTEN"

# same ARGS...: the output of the lean start and of the full load match, with
# the variables of ENVSET (NAME=VALUE words) set for both
ENVSET=()
same() {
  local lean full lean_code full_code
  set +e
  lean="$(env ${ENVSET[@]+"${ENVSET[@]}"} "$FM" "$@" 2>&1)"; lean_code="$?"
  full="$(env ${ENVSET[@]+"${ENVSET[@]}"} BENCHBAR_LOAD_ALL=1 "$FM" "$@" 2>&1)"; full_code="$?"
  set -e
  LAST_LEAN="$lean"
  assert_eq "$full" "$lean" "(output of: ${ENVSET[*]:-} $*)"
  assert_eq "$full_code" "$lean_code" "(exit code of: ${ENVSET[*]:-} $*)"
  assert_not_contains "$lean" "command not found" "(a library the lean start did not load: $*)"
  assert_not_contains "$lean" "unbound variable" "(a variable of a library the lean start did not load: $*)"
}

same --version
same --help
same up --help
same status --help
same commands
same commands --json
same commands --json --for-agent
same path --bench-dir "$BENCH"
same path --bench-dir "$HOME/nowhere"
same path
same where
same where --json
same status --bench-dir "$BENCH"
same status --json --bench-dir "$BENCH"
same status --json --ping --bench-dir "$BENCH"
same list
same list --json
same bogus
BENCHBAR_LABS=lan-rooms same commands --json

# where, run by a copy that handed off (BENCHBAR_HANDOFF_FROM): it names the
# version of that copy, which needs functions that live outside checks.sh
mkdir -p "$HOME/.local/share/benchbar"
printf '#!/bin/sh\nFL_VERSION="0.0.1"\n' >"$HOME/.local/share/benchbar/benchbar"
ENVSET=("BENCHBAR_HANDOFF_FROM=$HOME/.local/share/benchbar/benchbar")
for form in "where" "where --json" "where --for-agent" "where --jsonl"; do
  # shellcheck disable=SC2086
  same $form
  assert_not_contains "$LAST_LEAN" "command not found" "(where after a hand off: $form)"
done
same where --json
assert_contains "$LAST_LEAN" '"handoff_from_version":"0.0.1"' "(where --json names the version of the copy that handed off)"
ENVSET=()

# list --json shows the lockfile of a bench that has a benchbar.toml
BENCH2="$HOME/work/b/frappe-bench"
make_fake_bench "$BENCH2" locked
printf '127.0.0.1 locked\n' >>"$FL_HOSTS_FILE"
printf 'schema = 1\n' >"$BENCH2/benchbar.toml"
run_fm register "$BENCH2"
assert_eq 0 "$CODE" "(register a bench with a benchbar.toml: $OUT)"
same list --json
assert_contains "$LAST_LEAN" "\"lock_file\":\"${BENCH2}/benchbar.toml\"" "(list --json names the benchbar.toml of a bench)"

# a profile name is still checked
same path --profile nope --bench-dir "$BENCH"
assert_contains "$LAST_LEAN" "Unknown release profile" "(path --profile nope)"
run_fm path --profile nope --bench-dir "$BENCH"
assert_eq 1 "$CODE" "(path --profile nope exits 1)"
same path --profile v15-lts --bench-dir "$BENCH"

# the general guard: every lean command under several environments prints
# what the full load prints, so a function a lean library calls from a
# skipped library is found here (a missing one prints "command not found")
LEAN_CMDS=("--version" "--help" "path --bench-dir $BENCH" "where" "where --json" "where --for-agent" "list" "list --json"
  "list --for-agent" "status --bench-dir $BENCH" "status --json --bench-dir $BENCH" "status --for-agent --bench-dir $BENCH"
  "commands --json" "commands --for-agent")
ENV_SETS=(
  "BENCHBAR_TEST_NOP=1"
  "BENCHBAR_HANDOFF_FROM=$HOME/.local/share/benchbar/benchbar"
  "BENCHBAR_HANDOFF_FROM=/opt/homebrew/opt/benchbar/bin/benchbar"
  "NO_COLOR=1 BENCHBAR_NONINTERACTIVE=1"
  "BENCHBAR_LABS=lan-rooms"
  "BENCHBAR_LOCK=$BENCH2/benchbar.toml"
  "LC_ALL=C TERM=dumb"
)
for set in "${ENV_SETS[@]}"; do
  # shellcheck disable=SC2206
  ENVSET=($set)
  for c in "${LEAN_CMDS[@]}"; do
    # shellcheck disable=SC2086
    same $c
  done
done
ENVSET=()

# colors: a terminal whose terminfo has no colors gets no codes, as it did
# when every terminal asked tput; the color terminals get the fixed codes
red_on() {
  # shellcheck disable=SC2016  # the program is Python; the bash inside is for the child
  python3 -I -c '
import os, pty, subprocess, sys
m, s = pty.openpty()
env = dict(os.environ, TERM=sys.argv[1]); env.pop("NO_COLOR", None)
subprocess.run(["bash", "-c", "SCRIPT_DIR=$1; . \"$1/lib/frappe-local/ui.sh\"; printf \"[%s]\" \"$FL_RED\"", "_", sys.argv[2]], stdin=s, stdout=s, env=env)
sys.stdout.write(repr(os.read(m, 200)))' "$1" "$ROOT"
}
assert_eq "b'[\\x1b[31m]'" "$(red_on xterm-256color)" "(xterm-256color gets red)"
assert_eq "b'[]'" "$(red_on xterm-mono)" "(xterm-mono gets no color)"
assert_eq "b'[]'" "$(red_on vt100)" "(vt100 gets no color)"

# the heavy libraries stay unread for the lean commands, and are read for the others
sourced() { /bin/bash -x "$FM" "$@" 2>&1 | grep -c -E '^\++ \. .*/lib/frappe-local/'"$LIB"'\.sh' || true; }
LIB=repair
assert_eq 0 "$(sourced path --bench-dir "$BENCH")" "(path does not source repair.sh)"
assert_eq 0 "$(sourced commands --json)" "(commands does not source repair.sh)"
assert_eq 0 "$(sourced status --json --bench-dir "$BENCH")" "(status does not source repair.sh)"
assert_eq 1 "$(sourced doctor --bench-dir "$BENCH")" "(doctor sources repair.sh)"
assert_eq 1 "$(BENCHBAR_LOAD_ALL=1 sourced path --bench-dir "$BENCH")" "(BENCHBAR_LOAD_ALL=1 sources repair.sh)"

# commands --json builds its records without a subshell per value
n="$(PS4='+ ' /bin/bash -x "$FM" commands --json 2>&1 >/dev/null | grep -c -E '^\+ (fl_json_str|fl_json_bool) ' || true)"
assert_eq 0 "$n" "(commands --json calls fl_json_str or fl_json_bool in a subshell)"

# path finds the folder and does no work for the site, ports or templates
reset_calls
run_fm path --bench-dir "$BENCH"
assert_eq "$BENCH" "$OUT"
assert_calls_not_contain '^(brew|pipx|uname) ' "(path starts no brew, pipx or uname)"

# The harness exports FL_HOSTS_FILE, which hid that the lean start never set
# it: on a Mac status --json and list --json stopped at "FL_HOSTS_FILE: unbound
# variable" (issue 139). Without the harness's value both print their document.
for cmd in "status --json --bench-dir $BENCH" "list --json"; do
  set +e
  # shellcheck disable=SC2086  # the words of the command
  LEAN_OUT="$(env -u FL_HOSTS_FILE "$FM" $cmd 2>&1)"; LEAN_CODE="$?"
  set -e
  assert_eq 0 "$LEAN_CODE" "($cmd without FL_HOSTS_FILE: $LEAN_OUT)"
  assert_not_contains "$LEAN_OUT" "unbound variable" "($cmd without FL_HOSTS_FILE)"
  assert_contains "$LEAN_OUT" '"schema_version":1' "($cmd without FL_HOSTS_FILE prints its document)"
done

echo "test-lean-load: ok"
