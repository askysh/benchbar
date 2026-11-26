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

# ---- run-tests.sh: one file per process, through the wrapper, with a bounded pool
runner="$(cat "$ROOT/tests/run-tests.sh")"
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

# ---- the CI job: a per-file deadline, and a job timeout above it
wf="$(cat "$ROOT/.github/workflows/ci.yml")"
job="$(printf '%s\n' "$wf" | awk '/^  shellcheck:/{f=1;next} f&&/^  [a-z]/{exit} f')"
assert_contains "$job" "timeout-minutes: 10"
assert_contains "$job" "SC_FILE_TIMEOUT: 120"

printf 'test-shellcheck-guard: ok\n'
