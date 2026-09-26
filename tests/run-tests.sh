#!/usr/bin/env bash
#
# run-tests.sh: syntax check, every test file, then shellcheck.
#
#   tests/run-tests.sh                  all tests, PARALLEL at a time
#   PARALLEL=1 tests/run-tests.sh       one after another
#   SHARD=2/3 tests/run-tests.sh        only the second third (CI matrix)
#   tests/run-tests.sh test-doctor ...  only the named tests
#
# PARALLEL defaults to the number of CPUs. Every test builds its own HOME
# and mock state under mktemp, so they run side by side; each test's output
# is buffered and printed whole, in list order, once it finishes. A failing
# test does not stop the others: the run reports every failure at the end
# and exits 1. shellcheck runs in the pool as one more job when it is
# installed (in shard 1 only when sharded).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SCRIPTS=("$ROOT"/benchbar "$ROOT"/00-mac-system-deps.sh "$ROOT"/01-install-bench-and-site.sh "$ROOT"/02-background-service.sh "$ROOT"/lib/frappe-local/*.sh)

bash -n "${SCRIPTS[@]}"

# Longest first (measured), so the pool never waits on a slow test that
# started last. Shards take every Nth test of this list, which balances
# them. A new test file must be added here; the check below enforces it.
ALL_TESTS="test-phases test-multi-bench test-doctor test-install-sh test-sites test-apps test-ports test-doctor-hardening
test-profiles test-pull test-lock test-repair-json test-mcp
test-process test-adopt test-repair test-service test-cli test-migrate test-json test-report test-runner
test-profile-v16 test-run test-bench-flow test-version-policy test-templates test-shellrc test-ui test-platform test-docs"

for f in "$ROOT"/tests/test-*.sh; do
  n="$(basename "$f" .sh)"
  case " $(printf '%s' "$ALL_TESTS" | tr '\n' ' ') " in
    *" $n "*) ;;
    *) printf 'FAIL: %s is not in the test list of tests/run-tests.sh\n' "$n" >&2; exit 1 ;;
  esac
done

ncpu() { sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2; }
PARALLEL="${PARALLEL:-$(ncpu)}"
[[ "$PARALLEL" =~ ^[1-9][0-9]*$ ]] || { printf 'PARALLEL must be a positive number, got %s\n' "$PARALLEL" >&2; exit 1; }

SHARD="${SHARD:-1/1}"
[[ "$SHARD" =~ ^([1-9][0-9]*)/([1-9][0-9]*)$ ]] || { printf 'SHARD must look like 2/3, got %s\n' "$SHARD" >&2; exit 1; }
SHARD_I="${BASH_REMATCH[1]}"; SHARD_N="${BASH_REMATCH[2]}"
[[ "$SHARD_I" -le "$SHARD_N" ]] || { printf 'SHARD %s: the index is larger than the count\n' "$SHARD" >&2; exit 1; }

# Each test gets TEST_TIMEOUT seconds (default 600). A test that overruns is
# killed with its process tree printed first, so a hang on one machine (CI
# runners have no TTY and ignore SIGPIPE) names the stuck command instead
# of eating the job's whole time budget. No GNU timeout needed: macOS.
TEST_TIMEOUT="${TEST_TIMEOUT:-600}"

# descendants PID: PID and every process below it, one per line
descendants() {
  ps -eo pid=,ppid= 2>/dev/null | awk -v root="$1" '
    { parent[$1] = $2 }
    END { for (p in parent) { q = p; while (q != "" && q != 0 && q != 1) { if (q == root) { print p; break } q = parent[q] } } }'
}

run_test_with_deadline() {
  local script="$1" pid ticks=0 limit code=0 tree
  limit=$((TEST_TIMEOUT * 5))
  bash "$script" </dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$ticks" -ge "$limit" ]]; then
      printf '\nFAIL: %s still running after %ss; processes:\n' "$(basename "$script")" "$TEST_TIMEOUT" >&2
      tree="$(descendants "$pid" | tr '\n' ',' | sed 's/,$//')"
      [[ -n "$tree" ]] && ps -o pid,ppid,stat,etime,command -p "$tree" >&2 2>/dev/null || true
      # the whole tree, collected before anything dies: a killed parent
      # would reparent its grandchildren out of reach of pkill -P
      # shellcheck disable=SC2086  # the pids are words
      kill ${tree//,/ } 2>/dev/null || true
      sleep 1
      # shellcheck disable=SC2086
      kill -9 ${tree//,/ } "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.2
    ticks=$((ticks + 1))
  done
  wait "$pid" || code=$?
  return "$code"
}

run_shellcheck() {
  local extra=()
  [[ -f "$ROOT/install.sh" ]] && extra+=("$ROOT/install.sh")
  shellcheck -x "${SCRIPTS[@]}" ${extra[@]+"${extra[@]}"} "$ROOT"/tests/*.sh "$ROOT"/tests/lib/*.sh \
    "$ROOT"/tests/mocks/bin/* "$ROOT"/scripts/*.sh
  printf 'shellcheck: ok\n'
}

# ---------------------------------------------------------------- the jobs

JOBS=()
if [[ "$#" -gt 0 ]]; then
  for t in "$@"; do
    t="$(basename "$t" .sh)"
    [[ -f "$ROOT/tests/$t.sh" ]] || { printf 'no such test: %s\n' "$t" >&2; exit 1; }
    JOBS+=("$t")
  done
else
  i=0
  for t in $ALL_TESTS; do
    [[ $((i % SHARD_N + 1)) -eq "$SHARD_I" ]] && JOBS+=("$t")
    i=$((i + 1))
  done
fi
if [[ "$#" -eq 0 && "$SHARD_I" -eq 1 ]]; then
  if command -v shellcheck >/dev/null 2>&1; then JOBS+=(shellcheck); else
    printf 'shellcheck not installed; skipped lint (brew install shellcheck)\n'
  fi
fi

OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/benchbar-run-tests.XXXXXX")"
PIDS=()
cleanup() {
  local p
  for p in ${PIDS[@]+"${PIDS[@]}"}; do
    [[ -n "$p" ]] || continue
    pkill -P "$p" 2>/dev/null || true
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$OUT_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# start_job INDEX: runs job INDEX in the background, output to $OUT_DIR/INDEX.log,
# exit code to $OUT_DIR/INDEX.rc, seconds to $OUT_DIR/INDEX.secs
start_job() {
  local idx="$1" name="${JOBS[$1]}"
  (
    started="$SECONDS"
    if [[ "$name" == "shellcheck" ]]; then
      if run_shellcheck >"$OUT_DIR/$idx.log" 2>&1; then c=0; else c=$?; fi
    else
      if run_test_with_deadline "$ROOT/tests/$name.sh" >"$OUT_DIR/$idx.log" 2>&1; then c=0; else c=$?; fi
    fi
    printf '%s\n' "$((SECONDS - started))" >"$OUT_DIR/$idx.secs"
    # written aside and moved: the main loop polls for the .rc file
    printf '%s\n' "$c" >"$OUT_DIR/$idx.rc.tmp" && mv "$OUT_DIR/$idx.rc.tmp" "$OUT_DIR/$idx.rc"
  ) &
  PIDS[idx]=$!
}

TOTAL="${#JOBS[@]}"
printf 'running %s jobs, %s at a time (shard %s)\n' "$TOTAL" "$PARALLEL" "$SHARD"
started_all="$SECONDS"
next_start=0; next_print=0; running=0; FAILED=()
while [[ "$next_print" -lt "$TOTAL" ]]; do
  while [[ "$running" -lt "$PARALLEL" && "$next_start" -lt "$TOTAL" ]]; do
    start_job "$next_start"
    next_start=$((next_start + 1)); running=$((running + 1))
  done
  # reap finished jobs (bash 3.2 has no "wait -n")
  j=0
  while [[ "$j" -lt "$next_start" ]]; do
    if [[ -n "${PIDS[j]:-}" && -f "$OUT_DIR/$j.rc" ]]; then
      wait "${PIDS[j]}" 2>/dev/null || true
      PIDS[j]=""; running=$((running - 1))
    fi
    j=$((j + 1))
  done
  # print finished jobs in list order
  while [[ "$next_print" -lt "$TOTAL" && -f "$OUT_DIR/$next_print.rc" && -z "${PIDS[next_print]:-}" ]]; do
    name="${JOBS[$next_print]}"; rc="$(cat "$OUT_DIR/$next_print.rc")"; secs="$(cat "$OUT_DIR/$next_print.secs")"
    cat "$OUT_DIR/$next_print.log"
    if [[ "$rc" == "0" ]]; then
      printf -- '--- ok: %s (%ss)\n' "$name" "$secs"
    else
      printf -- '--- FAIL: %s (exit %s, %ss)\n' "$name" "$rc" "$secs"
      FAILED+=("$name")
    fi
    next_print=$((next_print + 1))
  done
  [[ "$next_print" -lt "$TOTAL" ]] && sleep 0.2
done

printf '\n%s jobs in %ss, %s failed\n' "$TOTAL" "$((SECONDS - started_all))" "${#FAILED[@]}"
if [[ "${#FAILED[@]}" -gt 0 ]]; then
  printf 'FAILED: %s\n' "${FAILED[*]}" >&2
  exit 1
fi
