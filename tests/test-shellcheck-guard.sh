#!/usr/bin/env bash
# The shellcheck step must not hang without a log (#137, CI-3):
#   - tests/lib/shellcheck-file.sh stops a shellcheck that overruns its deadline, names the file,
#     and exits 124; a crash or memory stop is named and fails; findings pass through;
#   - run-tests.sh runs one shellcheck process per file through it, with a pool no wider than
#     SC_JOBS_MAX, and no batch of files per process;
#   - the CI job sets a per-file deadline below the job's timeout.
# A fake shellcheck stands in, so this needs no real one.
set -euo pipefail

ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
TMP_DIR="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/benchbar-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected [$1], got [$2] ${3:-}"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "expected output to contain [$2] ${3:-}"$'\n'"--- output ---"$'\n'"$1" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "expected output NOT to contain [$2] ${3:-}"$'\n'"--- output ---"$'\n'"$1" ;; esac; }

ONE="$ROOT/tests/lib/shellcheck-file.sh"
FAKE="$TMP_DIR/fake-shellcheck"
cat >"$FAKE" <<'FAKE_EOF'
#!/usr/bin/env bash
case "${1:-}" in --version) echo "ShellCheck fake"; exit 0 ;; esac
case "${FAKE_MODE:-ok}" in
  ok) exit 0 ;;
  findings) printf '%s: SC2086 fake finding\n' "$2"; exit 1 ;;
  crash) exit 251 ;;
  hang) printf '%s\n' "$$" >"$FAKE_PIDFILE"; exec /bin/sleep 60 ;;
  limit) printf 'vmem=%s\n' "$(ulimit -v)"; exit 0 ;;
  args) printf 'args=%s\n' "$*"; exit 0 ;;
esac
FAKE_EOF
chmod +x "$FAKE"
# run_one MODE [SECONDS]: the wrapper on a file named x.sh; output in OUT, status in RC
run_one() {
  RC=0
  OUT="$(FAKE_MODE="$1" FAKE_PIDFILE="$TMP_DIR/pid" SHELLCHECK_CMD="$FAKE" SC_FILE_TIMEOUT="${2:-5}" bash "$ONE" x.sh 2>&1)" || RC=$?
}

# ---- a clean file, a file with findings
run_one ok; assert_eq "0" "$RC" "(clean file)"
run_one findings; assert_eq "1" "$RC" "(findings)"; assert_contains "$OUT" "x.sh: SC2086"

# ---- a crash (out of memory, a kill) is named, and is a failure
run_one crash; assert_eq "1" "$RC" "(crash)"; assert_contains "$OUT" "x.sh ended with status 251"

# ---- a hang is stopped at the deadline and names the file
start="$(date +%s)"
run_one hang 1
took=$(( $(date +%s) - start ))
assert_eq "124" "$RC" "(hang)"
assert_contains "$OUT" "shellcheck: x.sh still running after 1s; stopped"
[[ "$took" -le 8 ]] || fail "the deadline of 1s took ${took}s to act"
pid="$(cat "$TMP_DIR/pid")"
if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null || true; fail "the hung shellcheck (pid $pid) was left running"; fi

# ---- a wrapper that is stopped (a cancelled job, xargs giving up) stops its shellcheck too
rm -f "$TMP_DIR/pid3"
FAKE_MODE=hang FAKE_PIDFILE="$TMP_DIR/pid3" SHELLCHECK_CMD="$FAKE" SC_FILE_TIMEOUT=60 bash "$ONE" x.sh >/dev/null 2>&1 &
wrapper=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [[ -s "$TMP_DIR/pid3" ]] && break; sleep 0.25; done
[[ -s "$TMP_DIR/pid3" ]] || { kill -9 "$wrapper" 2>/dev/null || true; fail "the fake shellcheck did not start"; }
kill -TERM "$wrapper"
wait "$wrapper" 2>/dev/null || true
pid="$(cat "$TMP_DIR/pid3")"
for _ in 1 2 3 4 5 6 7 8; do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null || true; fail "the shellcheck of a stopped wrapper (pid $pid) was left running"; fi

# ---- benchbar, the entry point, is checked without dataflow analysis: with it, its -x graph (every
# library) took 15 GB on a 16 GB runner and stopped it (#396). Its libraries are checked one by one
# with the analysis; every other file keeps it too.
RC=0; OUT="$(FAKE_MODE=args SHELLCHECK_CMD="$FAKE" bash "$ONE" "$TMP_DIR/benchbar" 2>&1)" || RC=$?
assert_eq "0" "$RC" "(benchbar)"
assert_contains "$OUT" "--extended-analysis=false" "(benchbar without dataflow analysis)"
RC=0; OUT="$(FAKE_MODE=args SHELLCHECK_CMD="$FAKE" bash "$ONE" "$TMP_DIR/benchbar.sh" 2>&1)" || RC=$?
assert_not_contains "$OUT" "--extended-analysis" "(another file keeps the analysis)"
run_one args; assert_not_contains "$OUT" "--extended-analysis" "(x.sh keeps the analysis)"

# ---- a deadline that is no number is refused, not dropped without a word
RC=0
OUT="$(SC_FILE_TIMEOUT=2m SHELLCHECK_CMD="$FAKE" bash "$ONE" x.sh 2>&1)" || RC=$?
assert_eq "2" "$RC" "(SC_FILE_TIMEOUT=2m)"
assert_contains "$OUT" "SC_FILE_TIMEOUT must be a number of seconds, got 2m"

# ---- no virtual memory cap: the runtime of shellcheck maps far more than it keeps resident, and
# an 8 GB cap stopped benchbar on a hosted runner (#396); the pool in run-tests.sh bounds memory
run_one limit; assert_eq "0" "$RC" "(limit)"
assert_eq "vmem=$(ulimit -v)" "$OUT" "(the wrapper sets no ulimit -v of its own)"

# ---- run-tests.sh: one file per process, through the wrapper, with a bounded pool
runner="$(cat "$ROOT/tests/run-tests.sh")"
# shellcheck disable=SC2016  # the text to find has literal $ signs
assert_contains "$runner" 'xargs -0 -n 1 -P "$jobs" bash "$ROOT/tests/lib/shellcheck-file.sh"'
assert_not_contains "$runner" "xargs -0 -n 12" "(a batch of files per process: one hang then hides which file)"
assert_contains "$runner" 'SC_JOBS_MAX:-3'
# a pass over two files through the pool, with the fake
mkdir -p "$TMP_DIR/bin"
printf '#!/bin/sh\ntrue\n' >"$TMP_DIR/a.sh"; cp "$TMP_DIR/a.sh" "$TMP_DIR/b.sh"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$FAKE" >"$TMP_DIR/bin/shellcheck"; chmod +x "$TMP_DIR/bin/shellcheck"
OUT="$(PATH="$TMP_DIR/bin:$PATH" SHELLCHECK_FILES="$TMP_DIR/a.sh $TMP_DIR/b.sh" SC_JOBS=2 bash "$ROOT/tests/run-tests.sh" shellcheck 2>&1)" || fail "the pool run failed: $OUT"
assert_contains "$OUT" "shellcheck: ok (2 files)"
# a hang in the pool fails the run and names the file
RC=0
OUT="$(PATH="$TMP_DIR/bin:$PATH" FAKE_MODE=hang FAKE_PIDFILE="$TMP_DIR/pid2" SC_FILE_TIMEOUT=1 SHELLCHECK_FILES="$TMP_DIR/a.sh" SC_JOBS=1 bash "$ROOT/tests/run-tests.sh" shellcheck 2>&1)" || RC=$?
[[ "$RC" != 0 ]] || fail "a hung shellcheck did not fail the pool run"
assert_contains "$OUT" "a.sh still running after 1s"

# ---- the pool width: CPUs, at most SC_JOBS_MAX, and what the memory holds (4500 MB per process)
pool() { # SC_MEM_MB PARALLEL [SC_JOBS]: the "N at a time" the lint reports
  PATH="$TMP_DIR/bin:$PATH" SHELLCHECK_FILES="$TMP_DIR/a.sh" SC_MEM_MB="$1" PARALLEL="$2" SC_JOBS="${3:-}" \
    bash "$ROOT/tests/run-tests.sh" shellcheck >"$TMP_DIR/pool.raw" 2>&1 || true
  sed -n 's/^shellcheck: 1 files, \([0-9]*\) at a time$/\1/p' "$TMP_DIR/pool.raw"
}
assert_eq "3" "$(pool 64000 16)" "(plenty of memory and CPUs: the cap)"
assert_eq "2" "$(pool 64000 2)" "(two CPUs)"
assert_eq "1" "$(pool 7500 16)" "(a 7.5 GB machine holds one 4 GB process)"
assert_eq "2" "$(pool 10000 16)" "(10 GB holds two)"
assert_eq "5" "$(pool 7500 16 5)" "(an explicit SC_JOBS is the caller word)$(cat "$TMP_DIR/pool.raw")"

# ---- the CI job: a per-file deadline, and a job timeout above it
wf="$(cat "$ROOT/.github/workflows/ci.yml")"
job="$(printf '%s\n' "$wf" | awk '/^  shellcheck:/{f=1;next} f&&/^  [a-z]/{exit} f')"
assert_contains "$job" "timeout-minutes: 10"
assert_contains "$job" "SC_FILE_TIMEOUT: 180"
assert_contains "$job" "SC_MB_PER_JOB: 6500" "(two at a time on a 16 GB runner: three stopped the runner twice, #396)"

printf 'test-shellcheck-guard: ok\n'
