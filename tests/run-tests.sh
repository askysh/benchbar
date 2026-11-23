#!/usr/bin/env bash
#
# run-tests.sh: syntax check, every test file, then shellcheck.
#
#   tests/run-tests.sh                  all tests, PARALLEL at a time
#   PARALLEL=1 tests/run-tests.sh       one after another
#   SHARD=2/3 tests/run-tests.sh        only the second third, balanced by tests/timings.tsv (CI matrix)
#   tests/run-tests.sh test-doctor ...  only the named tests
#   tests/run-tests.sh shellcheck       only the lint
#   SHELLCHECK=0 tests/run-tests.sh     the tests without the lint
#   SKIP_TESTS="test-a test-b" ...      all but those (before sharding)
#   ONLY_TESTS="test-a test-b" ...      only those, sharded like the full list (CI: affected tests)
#   LIST_ONLY=1 SHARD=2/4 ...           print the chosen tests, run nothing
#   SECS_ONLY=1 ...                     print the weight (table seconds) of the chosen tests, run nothing
#   NO_SKIP="test-a test-b" ...         those tests fail when they skip themselves ("NAME: ok (SKIPPED ...)")
#   RERUN_FAILED=1 ...                  a failed test runs once more, and FLAKY says it passed then (on by default when CI is set)
#   STRICT_FLAKY=1 ...                  a test that was FLAKY (failed, then passed on the rerun) fails the run at its end
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

# Every test file: each tests/test-*.sh is a test. A new test needs no entry here or
# anywhere else. Shards are filled from the seconds in tests/timings.tsv, not from
# this order.
ALL_TESTS=""
for f in "$ROOT"/tests/test-*.sh; do
  [[ -f "$f" ]] || continue
  n="${f##*/}"; ALL_TESTS="$ALL_TESTS ${n%.sh}"
done
ALL_TESTS="${ALL_TESTS# }"
ALL_TESTS_WORDS=" $ALL_TESTS "

# Seconds each test takes in a CI shard: tests/timings.tsv, one row per test, NAME,
# the macOS seconds and the Linux seconds (the file's header says how they are
# measured and how to refresh them: scripts/ci-timings.sh --write RUN_ID). A test with
# no row, or with a dash, counts as 10 (one new test is a rounding error; a table that
# is a month old is not). Only the proportions matter. Shards are filled from this
# table (see "the jobs"), and CI plans size the matrix from it (scripts/ci-plan.sh).
# The table is a data file so that a new test or a new time is not a change to this
# harness: tests/affected.sh runs the whole suite for a change here, and two branches
# that both add a row merge without a conflict.
# TEST_PLATFORM=mac or linux picks the column (default: this machine)
case "${TEST_PLATFORM:-$(uname -s)}" in
  mac|Darwin) SECS_COL=mac ;;
  *) SECS_COL=linux ;;
esac
TEST_SECS_WORDS=" "
if [[ -f "$ROOT/tests/timings.tsv" ]]; then
  while IFS=$'\t' read -r n mac linux _; do
    case "$n" in ''|'#'*) continue ;; esac
    if [[ "$SECS_COL" == mac ]]; then v="$mac"; else v="$linux"; fi
    [[ "$v" =~ ^[0-9]+$ ]] || continue
    TEST_SECS_WORDS="$TEST_SECS_WORDS$n=$v "
  done <"$ROOT/tests/timings.tsv"
fi
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

# run_one_test NAME LOG: one run of a test file, its output in LOG; 0 only when it passed in full.
# Two checks beyond the exit code, because bash 3.2 (the macOS /bin/bash and the container legs) exits 0
# after a "set -u" abort inside a function when an EXIT trap is set, so a test that stopped halfway
# counts as a pass: the log may not hold an "unbound variable" error (stderr is in it), and a share or
# lan-guard test must print its own "NAME: ok" line (a skip says why after the ok, in parentheses:
# "NAME: ok (SKIPPED ...)").
run_one_test() {
  local name="$1" log="$2" c=0
  if run_test_with_deadline "$ROOT/tests/$name.sh" >"$log" 2>&1; then c=0; else c=$?; fi
  if [[ "$c" == 0 && ( "$name" == test-share* || "$name" == test-lan-guard ) ]] && ! grep -qE "^${name}: ok( \(.*\))?\$" "$log"; then
    printf 'FAIL: %s exited 0 without its "%s: ok" line\n' "$name" "$name" >>"$log"
    c=1
  fi
  if [[ "$c" == 0 ]] && grep -qE ': [A-Za-z_][A-Za-z_0-9]*: unbound variable' "$log"; then
    printf 'FAIL: %s printed an "unbound variable" error: a set -u abort the shell did not turn into an exit code\n' "$name" >>"$log"
    c=1
  fi
  return "$c"
}

# start_job INDEX: runs job INDEX in the background, output to $OUT_DIR/INDEX.log,
# exit code to $OUT_DIR/INDEX.rc, seconds to $OUT_DIR/INDEX.secs
start_job() {
  local idx="$1" name="${JOBS[$1]}"
  (
    started="$SECONDS"
    if [[ "$name" == "shellcheck" ]]; then
      if run_shellcheck >"$OUT_DIR/$idx.log" 2>&1; then c=0; else c=$?; fi
    else
      if run_one_test "$name" "$OUT_DIR/$idx.log"; then c=0; else c=$?; fi
      # a failed test runs once more on CI (RERUN_FAILED=1 anywhere else): one that then passes is a
      # flake, and the log says so with the first failure, so it is fixed and not hidden
      if [[ "$c" != 0 && "$c" != 124 && "${RERUN_FAILED:-${CI:+1}}" == 1 ]]; then
        mv "$OUT_DIR/$idx.log" "$OUT_DIR/$idx.first"
        # how the first run ended: a test that a signal killed prints nothing, and then the exit
        # code is all there is to go on (above 128 it is 128 plus the signal: 143 is TERM, 137 KILL)
        first="exit ${c}"; [[ "$c" -le 128 ]] || first="${first}, signal $((c - 128))"
        first="${first}, after $((SECONDS - started))s"
        if run_one_test "$name" "$OUT_DIR/$idx.log"; then c=0; else c=$?; fi
        if [[ "$c" == 0 ]]; then
          { printf 'FLAKY: %s failed once and passed on the rerun (the first run: %s). The first failure:\n' "$name" "$first"; sed 's/^/  | /' "$OUT_DIR/$idx.first"; } >>"$OUT_DIR/$idx.log"
          # the line the run's summary and the GitHub annotation show (the main loop reads it)
          { sed -n '/^FAIL/{p;q;}' "$OUT_DIR/$idx.first"; sed -n 1p "$OUT_DIR/$idx.first"; } 2>/dev/null | sed -n 1p >"$OUT_DIR/$idx.flaky"
          [[ -s "$OUT_DIR/$idx.flaky" ]] || printf 'no output (%s)\n' "$first" >"$OUT_DIR/$idx.flaky"
        else
          { printf 'FAILED TWICE: %s (the first run: %s). The first failure:\n' "$name" "$first"; sed 's/^/  | /' "$OUT_DIR/$idx.first"; } >>"$OUT_DIR/$idx.log"
        fi
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
next_start=0; next_print=0; running=0; FAILED=(); SKIPPED_TESTS=(); FLAKY_TESTS=()
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
    # a test that skipped itself says so after its ok ("NAME: ok (SKIPPED: why)"): counted and listed at the
    # end, and a failure for a test in NO_SKIP (the legs that are meant to have what it needs, node for the gateway)
    if [[ "$rc" == "0" && "$name" != shellcheck ]] && grep -qE "^${name}: ok \(SKIPPED" "$OUT_DIR/$next_print.log"; then
      SKIPPED_TESTS+=("$name")
      case " ${NO_SKIP:-} " in
        *" $name "*) printf 'FAIL: %s skipped itself, and this run lists it in NO_SKIP (it must run here)\n' "$name"; rc=1 ;;
      esac
    fi
    if [[ -f "$OUT_DIR/$next_print.flaky" ]]; then
      flaky_line="$(cat "$OUT_DIR/$next_print.flaky")"
      FLAKY_TESTS+=("$name")
      # a flake must not hide in a log block nobody opens: an annotation on the run, a row in the job summary
      if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        flaky_msg="${flaky_line//'%'/%25}"; flaky_msg="${flaky_msg//$'\r'/%0D}"
        printf '::warning title=FLAKY::%s first failure: %s\n' "$name" "$flaky_msg"
        if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
          [[ -s "$GITHUB_STEP_SUMMARY" ]] && grep -q '^### Flaky tests' "$GITHUB_STEP_SUMMARY" 2>/dev/null || printf '### Flaky tests\n\n| test | first failure |\n| --- | --- |\n' >>"$GITHUB_STEP_SUMMARY"
          # shellcheck disable=SC2016  # the backticks are Markdown, not a command substitution
          printf '| %s | `%s` |\n' "$name" "${flaky_line//|/\\|}" >>"$GITHUB_STEP_SUMMARY"
        fi
      fi
    fi
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
[[ "${#SKIPPED_TESTS[@]}" -eq 0 ]] || printf 'skipped: %s (%s)\n' "${#SKIPPED_TESTS[@]}" "${SKIPPED_TESTS[*]}"
[[ "${#FLAKY_TESTS[@]}" -eq 0 ]] || printf 'flaky: %s (%s)\n' "${#FLAKY_TESTS[@]}" "${FLAKY_TESTS[*]}"
if [[ "${#FAILED[@]}" -gt 0 ]]; then
  printf 'FAILED: %s\n' "${FAILED[*]}" >&2
  exit 1
fi
# STRICT_FLAKY=1 (CI, on a push to next-release and the nightly): the rerun still runs, so every other test
# still reports, but a flake is a failure of the run: "green N times in a row" cannot include one
if [[ "${STRICT_FLAKY:-}" == 1 && "${#FLAKY_TESTS[@]}" -gt 0 ]]; then
  printf 'FAILED: flaky tests (STRICT_FLAKY=1): %s\n' "${FLAKY_TESTS[*]}" >&2
  exit 1
fi
