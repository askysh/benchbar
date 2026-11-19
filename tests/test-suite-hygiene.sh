#!/usr/bin/env bash
# The test suite's own hygiene (#138):
#   - every mock in tests/mocks/bin is executable in git (a commit made on
#     Windows loses the bit, and the mock then answers "permission denied");
#   - ending a sudo session does not wait for the keepalive's sleep (CI-4);
#   - run-tests.sh fails a test that printed "unbound variable" even when it
#     exited 0 (bash 3.2 does that after a set -u abort in a function, CI-10),
#     and, on CI, runs a failed test once more and says FLAKY when it passes.
# Not the harness: it puts a git mock first on PATH, and this test needs the real git.
set -euo pipefail

ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
TMP_DIR="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/benchbar-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected [$1], got [$2] ${3:-}"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "expected output to contain [$2] ${3:-}"$'\n'"--- output ---"$'\n'"$1" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "expected output NOT to contain [$2] ${3:-}"$'\n'"--- output ---"$'\n'"$1" ;; esac; }
SKIPPED=""

# ---- the mocks are executable, in git and in this checkout
for f in "$ROOT"/tests/mocks/bin/*; do
  [[ -x "$f" ]] || fail "${f#"$ROOT"/} is not executable in this checkout"
done
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  modes="$(git -C "$ROOT" ls-files -s tests/mocks/bin)"
  [[ -n "$modes" ]] || fail "git lists no file under tests/mocks/bin"
  notexec="$(printf '%s\n' "$modes" | awk '$1 != "100755" { print $4 " (" $1 ")" }')"
  assert_eq "" "$notexec" "(not mode 100755 in git: fix with git update-index --chmod=+x FILE)"
else
  SKIPPED="${SKIPPED} the git file modes (not a git checkout)"
fi

# ---- fl_sudo_end does not wait for the keepalive's 5 second sleep
export MOCK_STATE="$TMP_DIR/mock" MOCK_LOG="$TMP_DIR/mock/calls.log" FL_TESTING=1
mkdir -p "$MOCK_STATE"
: >"$MOCK_STATE/sudo_cred"
took="$(PATH="$ROOT/tests/mocks/bin:$PATH" bash -c '
  set -euo pipefail
  . "$1"
  fl_log() { :; }
  FL_SUDO_KEEPALIVE_PID=""
  fl__sudo_keepalive
  kid="$FL_SUDO_KEEPALIVE_PID"
  # the loop is in its first sleep by now
  sleep 0.5
  start="$SECONDS"
  fl_sudo_end
  printf "%s" "$((SECONDS - start))"
  if kill -0 "$kid" 2>/dev/null; then printf " alive"; fi' _ "$ROOT/lib/frappe-local/sudo.sh")"
assert_eq "0" "$took" "(seconds fl_sudo_end took to stop the keepalive; it must not wait for its sleep 5)"

# ---- run-tests.sh: a copy over a root of its own with two stand in tests
FAKE="$TMP_DIR/fake"
mkdir -p "$FAKE/tests" "$FAKE/lib/frappe-local"
cp "$ROOT/tests/run-tests.sh" "$FAKE/tests/run-tests.sh"
for f in benchbar 00-mac-system-deps.sh 00-linux-system-deps.sh 01-install-bench-and-site.sh 02-background-service.sh lib/frappe-local/x.sh; do : >"$FAKE/$f"; done
# the list check wants one real name per file called test-*.sh
printf '#!/usr/bin/env bash\nprintf "test-docs: ok\\n"\n' >"$FAKE/tests/test-docs.sh"
# t-unbound: the bash 3.2 case, a set -u abort in a function under an EXIT trap
cat >"$FAKE/tests/t-unbound.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
trap 'printf "bye\n"' EXIT
f() { printf '%s\n' "$UNSET_VARIABLE_FOR_THE_TEST"; printf 'after\n'; }
f
printf 't-unbound: ok\n'
EOF
# t-flaky: fails on its first run, passes on the next
cat >"$FAKE/tests/t-flaky.sh" <<'EOF'
#!/usr/bin/env bash
m="${FLAKY_MARK:?}"
if [[ ! -e "$m" ]]; then : >"$m"; printf 'FAIL: the first run\n' >&2; exit 1; fi
printf 't-flaky: ok\n'
EOF
cat >"$FAKE/tests/t-fine.sh" <<'EOF'
#!/usr/bin/env bash
printf 't-fine: ok\n'
EOF
run_rt() { OUT="$(env -u CI -u RERUN_FAILED PARALLEL=1 SHELLCHECK=0 bash "$FAKE/tests/run-tests.sh" "$@" 2>&1)" && CODE=0 || CODE=$?; }

run_rt t-fine
assert_eq "0" "$CODE" "$OUT"
run_rt t-unbound
assert_eq "1" "$CODE" "(a set -u abort passed: $OUT)"
assert_contains "$OUT" "unbound variable"
# a test that mentions the words in its own checks is not a set -u abort
printf '#!/usr/bin/env bash\nprintf "the CLI never says: unbound variable\\n"\nprintf "t-words: ok\\n"\n' >"$FAKE/tests/t-words.sh"
run_rt t-words
assert_eq "0" "$CODE" "$OUT"

rm -f "$TMP_DIR/mark"
FLAKY_MARK="$TMP_DIR/mark" run_rt t-flaky
assert_eq "1" "$CODE" "(a failed test is not run again off CI: $OUT)"
assert_not_contains "$OUT" "FLAKY"
rm -f "$TMP_DIR/mark"
OUT="$(env -u RERUN_FAILED CI=true FLAKY_MARK="$TMP_DIR/mark" PARALLEL=1 SHELLCHECK=0 bash "$FAKE/tests/run-tests.sh" t-flaky 2>&1)" && CODE=0 || CODE=$?
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "FLAKY: t-flaky failed once and passed on the rerun"
assert_contains "$OUT" "the first run"
# a test that fails twice still fails, with the first failure in the log
OUT="$(env CI=true PARALLEL=1 SHELLCHECK=0 bash "$FAKE/tests/run-tests.sh" t-unbound 2>&1)" && CODE=0 || CODE=$?
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "FAILED TWICE: t-unbound"

# a test that skips itself is listed, and fails where NO_SKIP names it
printf '#!/usr/bin/env bash\nprintf "t-skip: ok (SKIPPED: no node)\\n"\n' >"$FAKE/tests/t-skip.sh"
run_rt t-skip
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "skipped: 1 (t-skip)"
OUT="$(env -u CI -u RERUN_FAILED NO_SKIP="t-skip" PARALLEL=1 SHELLCHECK=0 bash "$FAKE/tests/run-tests.sh" t-skip 2>&1)" && CODE=0 || CODE=$?
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "t-skip skipped itself"

if [[ -n "$SKIPPED" ]]; then printf 'test-suite-hygiene: ok (SKIPPED%s)\n' "$SKIPPED"; else printf 'test-suite-hygiene: ok\n'; fi
