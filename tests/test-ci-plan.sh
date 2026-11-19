#!/usr/bin/env bash
# scripts/ci-plan.sh decides what a CI run does, and scripts/ci-timings.sh
# turns a CI log into the shard weight tables. Both run here on the real
# repository with the files of a change given in FILES, so no git history and
# no mock is involved (the harness would put the git mock first on PATH).
set -euo pipefail

ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
cd "$ROOT"
TMP_DIR="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/benchbar-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected [$1], got [$2] ${3:-}"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "expected [$2] in [$1] ${3:-}" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "expected no [$2] in [$1] ${3:-}" ;; esac; }

# plan KEY=VALUE...: run the planner with a clean environment; OUT holds its lines
plan() { OUT="$(env -i PATH="$PATH" HOME="$HOME" "$@" bash scripts/ci-plan.sh 2>&1)" && CODE=0 || CODE=$?; }
# val KEY: the value of a line of OUT
val() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p"; }
# at_least_one KEY: the shard count of a leg is one or more
at_least_one() { [[ "$(val "$1")" -ge 1 ]] || fail "$1 should be 1 or more: $OUT"; }

# ---- a pull request that changes shell code and its test: Linux and the container, no macOS, no app
plan EVENT=pull_request FILES="lib/frappe-local/ports.sh tests/test-ports.sh CHANGELOG.md"
assert_eq "0" "$CODE" "$OUT"
assert_eq "false" "$(val full)"
assert_contains "$(val tests)" "test-ports"; assert_contains "$(val tests)" "test-cli"
assert_eq "true" "$(val shellcheck)"
assert_eq "lib/frappe-local/ports.sh tests/test-ports.sh" "$(val shellcheck_files)"
at_least_one linux_n; at_least_one bash32_n
assert_eq "0" "$(val macos_n)"; assert_eq "[]" "$(val macos_shards)"
assert_eq "false" "$(val app)"; assert_eq "false" "$(val shim)"; assert_eq "false" "$(val real)"

# ---- docs only: the two tests that read docs/, one shard each, nothing else
plan EVENT=pull_request FILES="docs/guides/x.md CHANGELOG.md"
assert_eq "test-docs test-docs-command" "$(val tests)"
assert_eq "[1]" "$(val linux_shards)"; assert_eq "[1]" "$(val bash32_shards)"; assert_eq "[]" "$(val macos_shards)"
assert_eq "false" "$(val shellcheck)"; assert_eq "false" "$(val app)"

# ---- a Swift only pull request: no CLI test at all, the app job
plan EVENT=pull_request FILES="macos/BenchBar/A.swift"
assert_eq "" "$(val tests)"
assert_eq "[]" "$(val linux_shards)"; assert_eq "[]" "$(val bash32_shards)"; assert_eq "[]" "$(val macos_shards)"
assert_eq "true" "$(val app)"; assert_eq "false" "$(val shellcheck)"
# the fixtures are read by the CLI tests too
plan EVENT=pull_request FILES="macos/BenchBarTests/Fixtures/app-list.json"
assert_contains "$(val tests)" "test-json"; assert_eq "true" "$(val app)"

# ---- the Windows shim and the tray's own files
plan EVENT=pull_request FILES="windows/shim/main.go"
assert_eq "true" "$(val shim)"; assert_eq "true" "$(val wsl)"; assert_eq "[]" "$(val linux_shards)"
plan EVENT=pull_request FILES="windows/tray/App.xaml.cs"
assert_eq "false" "$(val shim)"; assert_eq "[]" "$(val linux_shards)"
# the CLI's env records: the shim must forward or exclude every name they document
plan EVENT=pull_request FILES="lib/frappe-local/commands.sh"
assert_eq "true" "$(val shim)"; assert_eq "true" "$(val wsl)"

# ---- a path that needs macOS adds the macOS leg, with the Linux layer left out
plan EVENT=pull_request FILES="lib/frappe-local/platform.sh"
at_least_one macos_n
assert_contains "$(val macos_skip)" "test-wsl-preflight"; assert_contains "$(val macos_skip)" "test-platform-linux"
assert_contains "$(val bash32_skip)" "test-share"; assert_contains "$(val linux_skip)" "test-lan-guard"
plan EVENT=pull_request FILES="lib/frappe-local/launchd.sh"
at_least_one macos_n
# a label asks for macOS on any change, with its tests
plan EVENT=pull_request FILES="lib/frappe-local/ports.sh" LABELS="bug test-macos"
at_least_one macos_n
plan EVENT=pull_request FILES="lib/frappe-local/ports.sh" LABELS="bug"
assert_eq "0" "$(val macos_n)"
# the real install runs on the label test-linux
plan EVENT=pull_request FILES="lib/frappe-local/ports.sh" LABELS="test-linux"
assert_eq "true" "$(val real)"

# ---- a selected test that every planned leg skips turns macOS on (never a green run that ran nothing)
# fl_same_path lives in state.sh, which macos_paths does not match; test-share-run names it
plan EVENT=pull_request FILES="lib/frappe-local/state.sh"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$(val tests)" "test-share-run"
at_least_one macos_n
# a macOS only test picked by name is the other way in
plan EVENT=pull_request FILES="tests/test-share-admin.sh"
at_least_one macos_n
# a change whose tests all run on Linux keeps macOS off
plan EVENT=pull_request FILES="lib/frappe-local/ports.sh tests/test-ports.sh"
assert_eq "0" "$(val macos_n)"
# every selected test is on some leg, for each file of the real tree that selects a test
for f in lib/frappe-local/state.sh lib/frappe-local/service.sh lib/frappe-local/doctor.sh lib/frappe-local/share/gateway.js tests/share/join.test.js; do
  plan EVENT=pull_request FILES="$f"
  assert_eq "0" "$CODE" "($f) $OUT"
  for t in $(val tests); do
    ran=0
    for leg in linux bash32 macos; do
      [[ "$(val ${leg}_n)" -ge 1 ]] || continue
      case " $(val ${leg}_skip) " in *" $t "*) ;; *) ran=1 ;; esac
    done
    [[ "$ran" == 1 ]] || fail "($f) $t is selected and no planned leg runs it: $OUT"
  done
done
# a dispatch that names its legs and leaves out the only leg that can run the test is refused;
# with no legs named it turns macOS on
plan EVENT=workflow_dispatch INPUT_TESTS="test-share" INPUT_LEGS="linux bash32"
assert_eq "1" "$CODE"; assert_contains "$OUT" "test-share would run on no leg"
plan EVENT=workflow_dispatch INPUT_TESTS="test-share"
assert_eq "0" "$CODE" "$OUT"; at_least_one macos_n

# ---- install.ps1 has no CLI test: the Windows installer job of release-windows.yml covers it on its own
# pull request trigger, so ci.yml plans nothing for it. Guard that trigger.
plan EVENT=pull_request FILES="install.ps1"
assert_eq "0" "$CODE" "$OUT"; assert_eq "false" "$(val full)"; assert_eq "[]" "$(val linux_shards)"
sed -n '/^  pull_request:/,/^permissions:/p' .github/workflows/release-windows.yml | grep -q '"install.ps1"' \
  || fail "release-windows.yml no longer runs on a pull request that changes install.ps1, and ci.yml plans nothing for it"
# the app icon script is the app job's
plan EVENT=pull_request FILES="scripts/app-icon.py"
assert_eq "true" "$(val app)"; assert_eq "[]" "$(val linux_shards)"; assert_eq "false" "$(val full)"
# a file nothing maps to runs everything
plan EVENT=pull_request FILES="scripts/unknown-tool.py"
assert_eq "true" "$(val full)"; assert_eq "[1,2,3,4,5,6,7,8]" "$(val linux_shards)"

# ---- the harness, a mock, run-tests.sh, the selector, the entry point: everything everywhere, no app
for f in tests/lib/harness.sh tests/mocks/bin/git tests/run-tests.sh tests/affected.sh benchbar templates/Procfile.lean.tmpl; do
  plan EVENT=pull_request FILES="$f"
  assert_eq "true" "$(val full)" "($f)"
  assert_eq "" "$(val tests)" "($f)"
  assert_eq "[1,2,3,4,5,6,7,8]" "$(val linux_shards)" "($f)"
  assert_eq "[1,2,3,4,5,6,7,8]" "$(val bash32_shards)" "($f)"
  assert_eq "[1,2,3,4]" "$(val macos_shards)" "($f)"
  assert_eq "true" "$(val shellcheck)" "($f)"; assert_eq "" "$(val shellcheck_files)" "($f)"
  assert_eq "false" "$(val app)" "($f)"
done
# the CI files themselves run every leg, the app and the shim included
for f in .github/workflows/ci.yml scripts/ci-plan.sh; do
  plan EVENT=pull_request FILES="$f"
  assert_eq "true" "$(val full)" "($f)"; assert_eq "true" "$(val app)" "($f)"; assert_eq "true" "$(val shim)" "($f)"
done
# no base to diff against: everything
plan EVENT=pull_request
assert_eq "true" "$(val full)" "(unknown base)"

# ---- a push to next-release or main: everything, unless only docs, site or markdown changed
plan EVENT=push FILES="lib/frappe-local/ports.sh"
assert_eq "true" "$(val full)"; assert_eq "[1,2,3,4]" "$(val macos_shards)"; assert_eq "true" "$(val app)"; assert_eq "true" "$(val real)"
plan EVENT=push FILES="docs/a.md site/src/x.astro CHANGELOG.md"
assert_eq "false" "$(val code)"; assert_eq "false" "$(val full)"
for k in linux_shards bash32_shards macos_shards; do assert_eq "[]" "$(val $k)" "($k, docs push)"; done
assert_eq "false" "$(val app)"; assert_eq "false" "$(val real)"; assert_eq "false" "$(val shellcheck)"
plan EVENT=push BASE_SHA=0000000000000000000000000000000000000000
assert_eq "true" "$(val full)" "(a new branch: no before)"
# the nightly: everything, whatever the files
plan EVENT=schedule
assert_eq "true" "$(val full)"; assert_eq "true" "$(val real)"; assert_eq "[1,2,3,4]" "$(val macos_shards)"

# ---- workflow_dispatch: a subset of the tests, a subset of the legs
plan EVENT=workflow_dispatch
assert_eq "true" "$(val full)"; assert_eq "[1,2,3,4]" "$(val macos_shards)"; assert_eq "true" "$(val real)"
plan EVENT=workflow_dispatch INPUT_TESTS="test-run-lock test-lock"
assert_eq "false" "$(val full)"; assert_eq "test-run-lock test-lock" "$(val tests)"
assert_eq "[1]" "$(val linux_shards)"; assert_eq "[1]" "$(val bash32_shards)"; assert_eq "[]" "$(val macos_shards)"
assert_eq "false" "$(val real)"; assert_eq "false" "$(val app)"; assert_eq "false" "$(val shellcheck)"
plan EVENT=workflow_dispatch INPUT_TESTS="test-run-lock" INPUT_LEGS="macos"
assert_eq "[]" "$(val linux_shards)"; assert_eq "[1]" "$(val macos_shards)"
plan EVENT=workflow_dispatch INPUT_LEGS="shellcheck shim"
assert_eq "true" "$(val shellcheck)"; assert_eq "true" "$(val shim)"; assert_eq "false" "$(val app)"
# a name that is not a test name is dropped; a list with none is refused
# shellcheck disable=SC2016  # the shell syntax in the names must stay literal
plan EVENT=workflow_dispatch INPUT_TESTS='test-lock x;y $(y)'
assert_eq "test-lock" "$(val tests)"
# shellcheck disable=SC2016
plan EVENT=workflow_dispatch INPUT_TESTS='$(y);'
assert_eq "1" "$CODE"; assert_contains "$OUT" "no valid test name"
# a leg whose platform leaves every named test out has nothing to run
plan EVENT=workflow_dispatch INPUT_TESTS="test-share" INPUT_LEGS="linux bash32 macos"
assert_eq "[]" "$(val linux_shards)"; assert_eq "[]" "$(val bash32_shards)"; assert_eq "[1]" "$(val macos_shards)"

# ---- the job summary
plan EVENT=pull_request FILES="docs/a.md" PLAN_SUMMARY="$TMP_DIR/summary.md"
assert_contains "$(cat "$TMP_DIR/summary.md")" "### CI plan"; assert_contains "$(cat "$TMP_DIR/summary.md")" "test-docs"

# ---- the shard tables in run-tests.sh size the matrix
# The CI job that runs this test sets SHARD, ONLY_TESTS and SKIP_TESTS for its own leg: the
# calls below must see the whole table, not that leg's part of it.
unset SHARD ONLY_TESTS SKIP_TESTS
w="$(TEST_PLATFORM=linux SECS_ONLY=1 SHELLCHECK=0 bash tests/run-tests.sh)"
[[ "$w" -gt 1000 ]] || fail "the Linux table weighs $w"
OUT="$(TEST_PLATFORM=linux ONLY_TESTS="test-cli test-doctor" SECS_ONLY=1 bash tests/run-tests.sh)"
[[ "$OUT" -gt 0 && "$OUT" -lt "$w" ]] || fail "ONLY_TESTS weighs $OUT of $w"
# the two tables differ (a macOS and a Linux time of the same test)
a="$(TEST_PLATFORM=mac ONLY_TESTS=test-services-served SECS_ONLY=1 bash tests/run-tests.sh)"
b="$(TEST_PLATFORM=linux ONLY_TESTS=test-services-served SECS_ONLY=1 bash tests/run-tests.sh)"
[[ "$a" != "$b" ]] || fail "one table for both platforms"
# the sharded lists, with ONLY_TESTS, cover each test once
got="$( (for i in 1 2 3; do ONLY_TESTS="test-cli test-doctor test-lock test-apps test-pull" SHARD=$i/3 SHELLCHECK=0 LIST_ONLY=1 bash tests/run-tests.sh; done) | sort | tr '\n' ' ')"
assert_eq "test-apps test-cli test-doctor test-lock test-pull " "$got"
OUT="$(ONLY_TESTS="test-nope" bash tests/run-tests.sh 2>&1)" && CODE=0 || CODE=$?
assert_eq "1" "$CODE"; assert_contains "$OUT" "no such test: test-nope"

# ---- ci-timings.sh: the two tables from a log, the Linux one averaging the bash 5 and the container legs
LOG="$TMP_DIR/run.log"
t='2026-11-17T09:26:32.3938790Z'
{
  printf 'CLI tests (macOS, shard 1/4)\tCLI tests\t%s --- ok: test-a (100s)\n' "$t"
  printf 'CLI tests (macOS, shard 2/4)\tCLI tests\t%s --- ok: test-b (50s)\n' "$t"
  printf 'CLI tests (Linux, shard 1/8)\tCLI tests\t%s --- ok: test-a (20s)\n' "$t"
  printf 'CLI tests (bash 3.2, shard 1/4)\tCLI tests\t%s --- ok: test-a (40s)\n' "$t"
  printf 'shellcheck\tshellcheck\t%s --- ok: shellcheck (150s)\n' "$t"
} >"$LOG"
OUT="$(bash scripts/ci-timings.sh "$LOG")"
assert_contains "$OUT" 'TEST_SECS_MAC="test-a=100 test-b=50"'
assert_contains "$OUT" 'TEST_SECS_LINUX="test-a=30"'
assert_not_contains "$OUT" "shellcheck="
printf 'nothing\n' >"$LOG"
OUT="$(bash scripts/ci-timings.sh "$LOG" 2>&1)" && CODE=0 || CODE=$?
assert_eq "1" "$CODE"; assert_contains "$OUT" '"--- ok'

printf 'test-ci-plan: ok\n'
