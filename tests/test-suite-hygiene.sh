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
if git -c safe.directory="*" -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  modes="$(git -c safe.directory="*" -C "$ROOT" ls-files -s tests/mocks/bin)"
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
# a sleep that names itself, to see whether one outlives the session
mkdir -p "$TMP_DIR/shim"
printf '#!/usr/bin/env bash\nexec -a "benchbar-suite-nap-%s" /bin/sleep "$@"\n' "$$" >"$TMP_DIR/shim/sleep"
chmod +x "$TMP_DIR/shim/sleep"
took="$(PATH="$TMP_DIR/shim:$ROOT/tests/mocks/bin:$PATH" bash -c '
  set -euo pipefail
  . "$1"
  fl_log() { :; }
  FL_SUDO_KEEPALIVE_PID=""
  fl__sudo_keepalive
  kid="$FL_SUDO_KEEPALIVE_PID"
  # the loop is in its first sleep by now
  /bin/sleep 0.5
  start="$SECONDS"
  fl_sudo_end
  printf "%s" "$((SECONDS - start))"
  if kill -0 "$kid" 2>/dev/null; then printf " alive"; fi' _ "$ROOT/lib/frappe-local/sudo.sh")"
# whole seconds, so a second boundary can add one: the old wait was 4 or 5
case "$took" in 0|1|2) ;; *) fail "fl_sudo_end took [$took] seconds to stop the keepalive; it must not wait for its sleep 5" ;; esac
/bin/sleep 0.3
orphans="$(/usr/bin/pgrep -f "benchbar-suite-nap-$$" | wc -l | tr -d ' ' || true)"
assert_eq "0" "$orphans" "(a keepalive sleep outlived the session)"

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
# The stand in runs below must not take the switches of the run this test is part of. On a push to
# next-release CI sets STRICT_FLAKY=1 for every job, and the inner runs that expect a flake to pass
# then failed: the branch was red after every merge while the same tree was green on its pull request.
# Each inner run sets what it tests itself.
unset STRICT_FLAKY NO_SKIP ONLY_TESTS SKIP_TESTS SHARD LIST_ONLY SECS_ONLY SHELLCHECK_FILES
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
# a flake is visible: the end of the run lists it, GitHub gets an annotation and a summary row
assert_contains "$OUT" "flaky: 1 (t-flaky)"
rm -f "$TMP_DIR/mark" "$TMP_DIR/summary"
OUT="$(env -u RERUN_FAILED CI=true GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$TMP_DIR/summary" FLAKY_MARK="$TMP_DIR/mark" PARALLEL=1 SHELLCHECK=0 bash "$FAKE/tests/run-tests.sh" t-fine t-flaky 2>&1)" && CODE=0 || CODE=$?
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "::warning title=FLAKY::t-flaky first failure: FAIL: the first run"
assert_contains "$(cat "$TMP_DIR/summary")" "### Flaky tests"
# shellcheck disable=SC2016  # the backticks are Markdown in the summary row

assert_contains "$(cat "$TMP_DIR/summary")" '| t-flaky | `FAIL: the first run` |'
# STRICT_FLAKY=1: the rerun still runs and the other tests still report, and the run fails at its end
rm -f "$TMP_DIR/mark"
OUT="$(env -u RERUN_FAILED CI=true STRICT_FLAKY=1 FLAKY_MARK="$TMP_DIR/mark" PARALLEL=1 SHELLCHECK=0 bash "$FAKE/tests/run-tests.sh" t-flaky t-fine 2>&1)" && CODE=0 || CODE=$?
assert_eq "1" "$CODE" "(a flake passed a strict run: $OUT)"
assert_contains "$OUT" "--- ok: t-flaky"
assert_contains "$OUT" "--- ok: t-fine"
assert_contains "$OUT" "FAILED: flaky tests (STRICT_FLAKY=1): t-flaky"
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

# ---- the test list is the files: a new tests/test-*.sh runs with no entry anywhere, and its time comes
# from tests/timings.tsv (10 without a row)
printf '#!/usr/bin/env bash\nprintf "test-new-one: ok\\n"\n' >"$FAKE/tests/test-new-one.sh"
OUT="$(env -u CI -u SHARD -u ONLY_TESTS -u SKIP_TESTS LIST_ONLY=1 SHELLCHECK=0 bash "$FAKE/tests/run-tests.sh" 2>&1)" && CODE=0 || CODE=$?
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "test-new-one"
assert_contains "$OUT" "test-docs"
OUT="$(env -u CI -u SHARD -u ONLY_TESTS -u SKIP_TESTS SECS_ONLY=1 SHELLCHECK=0 bash "$FAKE/tests/run-tests.sh" 2>&1)"
assert_eq "20" "$OUT" "(two tests with no table weigh 10 each)"
printf '# a header\ntest-new-one\t70\t30\ntest-docs\t-\t5\n' >"$FAKE/tests/timings.tsv"
OUT="$(env -u CI -u SHARD -u ONLY_TESTS -u SKIP_TESTS TEST_PLATFORM=mac SECS_ONLY=1 SHELLCHECK=0 bash "$FAKE/tests/run-tests.sh" 2>&1)"
assert_eq "80" "$OUT" "(macOS column, a dash counts as 10)"
OUT="$(env -u CI -u SHARD -u ONLY_TESTS -u SKIP_TESTS TEST_PLATFORM=linux SECS_ONLY=1 SHELLCHECK=0 bash "$FAKE/tests/run-tests.sh" 2>&1)"
assert_eq "35" "$OUT" "(Linux column)"
# the runner holds no list and no table of its own any more. A merge of a branch from before this
# change can put its ALL_TESTS words and TEST_SECS tables back next to the new code (a union of
# both sides does): every test is then listed twice and weighed from the wrong place. Take the
# next-release side of that section, and move a time to a row of tests/timings.tsv.
assert_eq "" "$(grep -nE '^(ALL_TESTS="test-|TEST_SECS(_MAC|_LINUX)?=)' "$ROOT/tests/run-tests.sh" || true)" "(tests/run-tests.sh has a test list or a timing table again: drop it, the files are the list and tests/timings.tsv has the seconds)"
# the real table: every row is NAME, two columns of seconds or a dash, and names a test that exists
# (a row for a test that was renamed or removed would sit there for ever)
bad="$(awk -F'\t' '
  /^#/ || /^$/ { next }
  NF != 3 || $1 !~ /^test-[a-z0-9-]+$/ || $2 !~ /^([0-9]+|-)$/ || $3 !~ /^([0-9]+|-)$/ { print "bad row: " $0 }
' "$ROOT/tests/timings.tsv")"
assert_eq "" "$bad" "(tests/timings.tsv)"
while IFS="$(printf '\t')" read -r name _; do
  case "$name" in ''|'#'*) continue ;; esac
  [[ -f "$ROOT/tests/$name.sh" ]] || fail "tests/timings.tsv has a row for $name, and tests/$name.sh does not exist"
done <"$ROOT/tests/timings.tsv"

if [[ -n "$SKIPPED" ]]; then printf 'test-suite-hygiene: ok (SKIPPED%s)\n' "$SKIPPED"; else printf 'test-suite-hygiene: ok\n'; fi
