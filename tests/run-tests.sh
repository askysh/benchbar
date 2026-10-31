#!/usr/bin/env bash
#
# run-tests.sh: syntax check, every test file, then shellcheck.
#
#   tests/run-tests.sh                  all tests, PARALLEL at a time
#   PARALLEL=1 tests/run-tests.sh       one after another
#   SHARD=2/3 tests/run-tests.sh        only the second third, balanced by TEST_SECS (CI matrix)
#   tests/run-tests.sh test-doctor ...  only the named tests
#   tests/run-tests.sh shellcheck       only the lint
#   SHELLCHECK=0 tests/run-tests.sh     the tests without the lint
#   SKIP_TESTS="test-a test-b" ...      all but those (before sharding)
#   LIST_ONLY=1 SHARD=2/4 ...           print the chosen tests, run nothing
#
# PARALLEL defaults to the number of CPUs. Every test builds its own HOME
# and mock state under mktemp, so they run side by side; each test's output
# is buffered and printed whole, in list order, once it finishes. A failing
# test does not stop the others: the run reports every failure at the end
# and exits 1. shellcheck runs in the pool as one more job when it is
# installed (in shard 1 only when sharded) unless SHELLCHECK=0.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SCRIPTS=("$ROOT"/benchbar "$ROOT"/00-mac-system-deps.sh "$ROOT"/00-linux-system-deps.sh "$ROOT"/01-install-bench-and-site.sh "$ROOT"/02-background-service.sh "$ROOT"/lib/frappe-local/*.sh)

bash -n "${SCRIPTS[@]}"

# Every test file. Shards are filled from TEST_SECS below, not from this
# order. A new test file must be added here; the check below enforces it.
ALL_TESTS="test-doctor test-phases test-install-json test-install-json-2 test-lock test-apps test-app-recovery test-app-recovery-2 test-app-recovery-3 test-app-batch test-pull test-repair test-install-linux test-port-management
test-profiles test-profiles-2 test-profiles-3 test-service test-homebrew test-multi-bench test-ports test-sites test-input-hygiene test-doctor-hardening
test-cli test-open-as test-freshness test-hygiene test-mcp test-site-backups test-app-cli test-process test-doctor-linux test-install-sh test-install-sh-linux
test-adopt test-systemd test-migrate test-repair-json test-json test-report test-profile-v16 test-state-migrate test-run-lock
test-runner test-redact test-docs-command test-status-cost test-command-cost test-bench-flow test-run test-platform-linux test-self-update
test-site-restore test-site-restore-2 test-services-served test-templates test-discovery test-shellrc test-docs test-platform test-packaging test-ui test-release-notes test-version-policy test-affected
test-agent-contracts test-agent-contracts-2 test-agent-contracts-3 test-pipelines test-sudo-env test-prerequisites-linux test-windows-commands"

for f in "$ROOT"/tests/test-*.sh; do
  n="$(basename "$f" .sh)"
  case " $(printf '%s' "$ALL_TESTS" | tr '\n' ' ') " in
    *" $n "*) ;;
    *) printf 'FAIL: %s is not in the test list of tests/run-tests.sh\n' "$n" >&2; exit 1 ;;
  esac
done

# Seconds each test takes in a macOS CI shard (3 at a time), from CI runs and
# local runs; a test not named here counts as 10. Only the proportions matter.
# Shards are filled from this table (see "the jobs"): after a test is added,
# split or sped up, put its new time here.
TEST_SECS="test-app-recovery-2=135 test-app-recovery-3=120 test-app-recovery=70
test-services-served=260 test-port-management=205 test-install-json-2=198 test-pull=189 test-install-json=181 test-doctor=181
test-site-restore=165 test-site-restore-2=123 test-apps=164 test-app-batch=158 test-sudo-env=157 test-lock=153
test-profiles-2=114 test-profiles-3=74 test-profiles=42
test-agent-contracts=83 test-agent-contracts-2=80 test-agent-contracts-3=89
test-repair=100 test-phases=100 test-homebrew=90 test-freshness=80 test-app-cli=75 test-windows-commands=65 test-service=65
test-input-hygiene=60 test-sites=50 test-site-backups=40 test-adopt=35 test-command-cost=30 test-report=28 test-open-as=25 test-json=20
test-run-lock=15 test-runner=14 test-pipelines=20"
test_secs() {
  local w
  w=" $(printf '%s' "$TEST_SECS" | tr '\n' ' ') "
  case "$w" in
    *" $1="*) w="${w#*" $1="}"; printf '%s' "${w%% *}" ;;
    *) printf '10' ;;
  esac
}

# weighted_tests: "SECS NAME" for every test that SKIP_TESTS leaves in
weighted_tests() {
  local t
  for t in $ALL_TESTS; do
    case " ${SKIP_TESTS:-} " in *" $t "*) continue ;; esac
    printf '%s %s\n' "$(test_secs "$t")" "$t"
  done
}

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
    "$ROOT"/tests/mocks/bin/* "$ROOT"/scripts/*.sh || return 1
  printf 'shellcheck: ok\n'
}

# ---------------------------------------------------------------- the jobs

JOBS=()
if [[ "$#" -gt 0 ]]; then
  for t in "$@"; do
    t="$(basename "$t" .sh)"
    if [[ "$t" == "shellcheck" ]]; then
      command -v shellcheck >/dev/null 2>&1 || { printf 'shellcheck not installed\n' >&2; exit 1; }
    else
      [[ -f "$ROOT/tests/$t.sh" ]] || { printf 'no such test: %s\n' "$t" >&2; exit 1; }
    fi
    JOBS+=("$t")
  done
else
  # Shards are balanced by weight: the tests, heaviest first, each go to the
  # shard with the least work so far (ties to the lowest number). Every shard
  # runs the same arithmetic on the same list, so together they cover each
  # test once; a shard runs its tests heaviest first.
  SHARD_LOAD=()
  k=0
  while [[ "$k" -lt "$SHARD_N" ]]; do SHARD_LOAD[k]=0; k=$((k + 1)); done
  while read -r secs t; do
    best=0; k=1
    while [[ "$k" -lt "$SHARD_N" ]]; do
      if [[ "${SHARD_LOAD[k]}" -lt "${SHARD_LOAD[best]}" ]]; then best="$k"; fi
      k=$((k + 1))
    done
    SHARD_LOAD[best]=$((SHARD_LOAD[best] + secs))
    if [[ $((best + 1)) -eq "$SHARD_I" ]]; then JOBS+=("$t"); fi
  done < <(weighted_tests | sort -k1,1nr -k2,2)
fi
if [[ "$#" -eq 0 && "$SHARD_I" -eq 1 && "${SHELLCHECK:-1}" != "0" ]]; then
  if command -v shellcheck >/dev/null 2>&1; then JOBS+=(shellcheck); else
    printf 'shellcheck not installed; skipped lint (brew install shellcheck)\n'
  fi
fi

if [[ -n "${LIST_ONLY:-}" ]]; then printf '%s\n' ${JOBS[@]+"${JOBS[@]}"}; exit 0; fi

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
