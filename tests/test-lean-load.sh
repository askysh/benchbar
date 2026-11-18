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

# same NAME ARGS...: the output of the lean start and of the full load match
same() {
  local lean full lean_code full_code
  set +e
  lean="$("$FM" "$@" 2>&1)"; lean_code="$?"
  full="$(BENCHBAR_LOAD_ALL=1 "$FM" "$@" 2>&1)"; full_code="$?"
  set -e
  assert_eq "$full" "$lean" "(output of: $*)"
  assert_eq "$full_code" "$lean_code" "(exit code of: $*)"
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

echo "test-lean-load: ok"
