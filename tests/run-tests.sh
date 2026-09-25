#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SCRIPTS=("$ROOT"/benchbar "$ROOT"/00-mac-system-deps.sh "$ROOT"/01-install-bench-and-site.sh "$ROOT"/02-background-service.sh "$ROOT"/lib/frappe-local/*.sh)

bash -n "${SCRIPTS[@]}"

# Each test gets TEST_TIMEOUT seconds (default 600). A test that overruns is
# killed with its process tree printed first, so a hang on one machine (CI
# runners have no TTY and ignore SIGPIPE) names the stuck command instead
# of eating the job's whole time budget. No GNU timeout needed: macOS.
TEST_TIMEOUT="${TEST_TIMEOUT:-600}"

run_test_with_deadline() {
  local script="$1" pid waited=0 code=0
  bash "$script" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$waited" -ge "$TEST_TIMEOUT" ]]; then
      printf '\nFAIL: %s still running after %ss; processes:\n' "$(basename "$script")" "$TEST_TIMEOUT" >&2
      # shellcheck disable=SC2009  # pgrep is mocked in the suite; ps is the real tool here
      ps -eo pid,ppid,stat,etime,command 2>/dev/null | grep -v -E 'grep|ps -eo' | grep -E "tests/|benchbar|lib/frappe-local|sleep|read|mariadb|security|sudo|curl|tr |head" >&2 || true
      pkill -P "$pid" 2>/dev/null || true
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid" || code=$?
  return "$code"
}

for t in test-ui test-templates test-shellrc test-platform test-run test-version-policy test-bench-flow test-runner test-process test-multi-bench test-ports test-sites test-service test-migrate test-json test-doctor test-doctor-hardening test-repair test-cli test-phases test-report test-adopt test-install-sh test-profile-v16; do
  [[ -f "$ROOT/tests/$t.sh" ]] || continue
  run_test_with_deadline "$ROOT/tests/$t.sh"
done

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "${SCRIPTS[@]}" "$ROOT"/tests/*.sh "$ROOT"/tests/lib/*.sh "$ROOT"/tests/mocks/bin/*
  printf 'shellcheck: ok\n'
else
  printf 'shellcheck not installed; skipped lint (brew install shellcheck)\n'
fi
