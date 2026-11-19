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
#   ONLY_TESTS="test-a test-b" ...      only those, sharded like the full list (CI: affected tests)
#   LIST_ONLY=1 SHARD=2/4 ...           print the chosen tests, run nothing
#   SECS_ONLY=1 ...                     print the weight (table seconds) of the chosen tests, run nothing
#   SHELLCHECK_FILES="a.sh b.sh" ...    the lint checks only those files; SC_JOBS=4 runs 4 shellcheck at once
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

# (the plan only wants a weight: SECS_ONLY skips the syntax check)
[[ -n "${SECS_ONLY:-}" ]] || bash -n "${SCRIPTS[@]}"

# Every test file. Shards are filled from TEST_SECS below, not from this
# order. A new test file must be added here; the check below enforces it.
ALL_TESTS="test-doctor test-phases test-install-json test-install-json-2 test-lock test-apps test-app-recovery test-app-recovery-2 test-app-recovery-3 test-app-batch test-pull test-repair test-install-linux test-port-management
test-profiles test-profiles-2 test-profiles-3 test-service test-homebrew test-multi-bench test-ports test-sites test-input-hygiene test-doctor-hardening
test-cli test-open-as test-freshness test-hygiene test-mcp test-mcp-2 test-site-backups test-app-cli test-process test-process-match test-doctor-linux test-install-sh test-install-sh-linux
test-adopt test-systemd test-migrate test-repair-json test-json test-report test-profile-v16 test-state-migrate test-run-lock
test-runner test-redact test-docs-command test-status-cost test-command-cost test-bench-flow test-run test-platform-linux test-self-update
test-site-restore test-site-restore-2 test-services-served test-templates test-discovery test-shellrc test-docs test-platform test-packaging test-ui test-release-notes test-version-policy test-affected
test-agent-contracts test-agent-contracts-2 test-agent-contracts-3 test-pipelines test-sudo-env test-prerequisites-linux test-windows-commands test-share-gateway test-share test-share-preflight test-share-run test-share-admin test-lan-guard test-labs test-labs-share test-wsl-preflight test-ci-plan test-fresh-install test-tray-fixtures test-backup-safety test-changelog test-lean-load test-linux-parity test-facts test-guards test-release-workflows test-neutralise test-listen test-macos-appcast test-apps-speed test-notices"

ALL_TESTS_WORDS=" $(printf '%s' "$ALL_TESTS" | tr '\n' ' ') "
for f in "$ROOT"/tests/test-*.sh; do
  n="${f##*/}"; n="${n%.sh}"
  case "$ALL_TESTS_WORDS" in
    *" $n "*) ;;
    *) printf 'FAIL: %s is not in the test list of tests/run-tests.sh\n' "$n" >&2; exit 1 ;;
  esac
done

# Seconds each test takes in a CI shard, as the CI log reports them
# ("--- ok: test-x (Ns)"): TEST_SECS_MAC on the macOS shards (3 CPUs), TEST_SECS_LINUX
# on the Linux and bash 3.2 container shards (4 CPUs; the average of both). A test
# not named counts as 10 (one new test is a rounding error; a table that is a month
# old is not). Only the proportions matter. Shards are filled from these tables (see
# "the jobs"), and CI-ready plans size the matrix from them (scripts/ci-plan.sh).
# Refresh both from the log of a green full run (a push to next-release or the
# nightly): scripts/ci-timings.sh RUN_ID prints the two blocks below, from run
# 44055044922 (2026-11-17).
TEST_SECS_MAC="test-services-served=297 test-doctor=270 test-port-management=232 test-share-run=232 test-repair=223 test-share=222
test-install-json=220 test-site-restore=219 test-pull=216 test-lock=200 test-windows-commands=197 test-site-restore-2=194
test-sudo-env=193 test-app-recovery-2=181 test-doctor-hardening=179 test-wsl-preflight=176 test-share-preflight=174 test-apps=165
test-mcp=161 test-agent-contracts-3=159 test-app-batch=156 test-app-recovery-3=149 test-phases=137 test-agent-contracts-2=134
test-app-recovery=128 test-install-json-2=128 test-agent-contracts=123 test-profiles-2=121 test-homebrew=116 test-freshness=115
test-service=109 test-ports=108 test-share-admin=108 test-app-cli=104 test-input-hygiene=104 test-multi-bench=101
test-sites=81 test-hygiene=80 test-cli=76 test-open-as=65 test-site-backups=61 test-install-sh=57
test-pipelines=57 test-profiles-3=57 test-lan-guard=50 test-report=49 test-migrate=48 test-json=47
test-profiles=45 test-process=43 test-adopt=42 test-profile-v16=38 test-run-lock=36 test-state-migrate=36
test-command-cost=35 test-redact=35 test-repair-json=34 test-share-gateway=33 test-bench-flow=20 test-docs-command=20
test-labs=20 test-prerequisites-linux=20 test-labs-share=19 test-runner=19 test-status-cost=14 test-run=13
test-install-sh-linux=10 test-discovery=5 test-self-update=5 test-affected=4 test-shellrc=4 test-templates=4
test-packaging=2 test-macos-appcast=2 test-docs=1 test-platform=0 test-release-notes=0 test-changelog=0 test-ui=0 test-version-policy=0 test-ci-plan=25 test-apps-speed=20"

TEST_SECS_LINUX="test-doctor=184 test-apps=176 test-pull=175 test-sudo-env=172 test-windows-commands=165 test-install-json-2=164
test-site-restore=159 test-repair=157 test-site-restore-2=153 test-app-batch=148 test-lock=148 test-mcp=145
test-phases=139 test-port-management=138 test-wsl-preflight=137 test-install-linux=136 test-install-json=135 test-app-recovery-2=130
test-app-recovery-3=122 test-agent-contracts-3=119 test-doctor-hardening=118 test-services-served=115 test-app-recovery=114 test-homebrew=106
test-agent-contracts-2=103 test-agent-contracts=99 test-service=99 test-profiles-2=97 test-sites=96 test-input-hygiene=94
test-freshness=92 test-multi-bench=89 test-ports=89 test-app-cli=84 test-pipelines=84 test-doctor-linux=74
test-open-as=72 test-hygiene=69 test-site-backups=69 test-profiles-3=57 test-cli=56 test-systemd=48
test-adopt=45 test-process=41 test-install-sh=40 test-migrate=39 test-profile-v16=37 test-json=35
test-profiles=33 test-report=32 test-repair-json=29 test-run-lock=27 test-state-migrate=25 test-labs=24
test-redact=22 test-command-cost=20 test-docs-command=18 test-bench-flow=17 test-runner=17 test-share-gateway=17
test-labs-share=14 test-prerequisites-linux=12 test-run=12 test-status-cost=10 test-install-sh-linux=7 test-self-update=7
test-discovery=4 test-templates=4 test-affected=3 test-platform-linux=3 test-docs=2 test-shellrc=2
test-packaging=1 test-macos-appcast=1 test-release-notes=1 test-changelog=0 test-platform=0 test-ui=0 test-version-policy=0 test-ci-plan=25 test-apps-speed=20"
# TEST_PLATFORM=mac or linux picks the table (default: this machine)
case "${TEST_PLATFORM:-$(uname -s)}" in
  mac|Darwin) TEST_SECS="$TEST_SECS_MAC" ;;
  *) TEST_SECS="$TEST_SECS_LINUX" ;;
esac
TEST_SECS_WORDS=" $(printf '%s' "$TEST_SECS" | tr '\n' ' ') "
# test_secs NAME: sets SECS (no subshell: this runs once per test, and a fork
# costs milliseconds on a busy machine)
test_secs() {
  local w="$TEST_SECS_WORDS"
  case "$w" in
    *" $1="*) w="${w#*" $1="}"; SECS="${w%% *}" ;;
    *) SECS=10 ;;
  esac
}

# weighted_tests: "SECS NAME" for every test that SKIP_TESTS leaves in (and, when
# ONLY_TESTS is set, that it names)
weighted_tests() {
  local t
  for t in $ALL_TESTS; do
    case " ${SKIP_TESTS:-} " in *" $t "*) continue ;; esac
    if [[ -n "${ONLY_TESTS:-}" ]]; then case " $ONLY_TESTS " in *" $t "*) ;; *) continue ;; esac; fi
    test_secs "$t"
    printf '%s %s\n' "$SECS" "$t"
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

# run_shellcheck: shellcheck -x over every shell file, or over SHELLCHECK_FILES
# when set (the files a pull request changed). The files go to SC_JOBS shellcheck
# processes at a time, 12 files each (one process over all 200 takes minutes: it
# parses harness.sh and the libraries again for every test file). SC_JOBS is 1
# unless set; a run of "shellcheck" alone uses every CPU.
run_shellcheck() {
  local files=() jobs="${SC_JOBS:-1}"
  if [[ -n "${SHELLCHECK_FILES:-}" ]]; then
    # shellcheck disable=SC2206  # one word per path, none has a space
    files=(${SHELLCHECK_FILES})
  else
    files=("${SCRIPTS[@]}")
    [[ -f "$ROOT/install.sh" ]] && files+=("$ROOT/install.sh")
    files+=("$ROOT"/tests/*.sh "$ROOT"/tests/lib/*.sh "$ROOT"/tests/mocks/bin/* "$ROOT"/scripts/*.sh)
  fi
  [[ "${#files[@]}" -gt 0 ]] || { printf 'shellcheck: no files\n'; return 0; }
  printf '%s\0' "${files[@]}" | xargs -0 -n 12 -P "$jobs" shellcheck -x || return 1
  printf 'shellcheck: ok (%s files)\n' "${#files[@]}"
}

# ---------------------------------------------------------------- the jobs

for t in ${ONLY_TESTS:-}; do
  case "$ALL_TESTS_WORDS" in
    *" $t "*) ;;
    *) printf 'ONLY_TESTS: no such test: %s\n' "$t" >&2; exit 1 ;;
  esac
done

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
if [[ -n "${SECS_ONLY:-}" ]]; then
  total=0
  for t in ${JOBS[@]+"${JOBS[@]}"}; do [[ "$t" == shellcheck ]] || { test_secs "$t"; total=$((total + SECS)); }; done
  printf '%s\n' "$total"; exit 0
fi
# a run of the lint alone has the machine to itself
if [[ "${#JOBS[@]}" -eq 1 && "${JOBS[0]}" == shellcheck && -z "${SC_JOBS:-}" ]]; then SC_JOBS="$PARALLEL"; fi

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
      # a share or lan-guard test passes only with its own "NAME: ok" line as well: under bash 3.2 a set -u
      # abort inside a function exits 0 when an EXIT trap is set, so the code alone can count a test that
      # stopped halfway (a skip says why after the ok, in parentheses: "NAME: ok (SKIPPED ...)")
      if [[ "$c" == 0 && ( "$name" == test-share* || "$name" == test-lan-guard ) ]] && ! grep -qE "^${name}: ok( \(.*\))?\$" "$OUT_DIR/$idx.log"; then
        printf 'FAIL: %s exited 0 without its "%s: ok" line\n' "$name" "$name" >>"$OUT_DIR/$idx.log"
        c=1
      fi
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
