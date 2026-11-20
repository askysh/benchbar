#!/usr/bin/env bash
# tests/affected.sh picks tests from a change. It runs here against a fake
# repository under mktemp with the real git (the harness would put the git
# mock first on PATH, so this test does not source it).
set -euo pipefail

ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
TMP_DIR="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/benchbar-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected [$1], got [$2] ${3:-}"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "expected output to contain [$2] ${3:-}"$'\n'"--- output ---"$'\n'"$1" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "expected output NOT to contain [$2] ${3:-}"$'\n'"--- output ---"$'\n'"$1" ;; esac; }

export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export HOME="$TMP_DIR/home"
mkdir -p "$HOME"
REPO="$TMP_DIR/repo"
mkdir -p "$REPO/tests/lib" "$REPO/tests/mocks/bin" "$REPO/lib/frappe-local/share" "$REPO/docs" "$REPO/templates" "$REPO/macos/BenchBarTests/Fixtures" "$REPO/scripts" "$REPO/site"
cp "$ROOT/tests/affected.sh" "$REPO/tests/affected.sh"
# run-tests.sh stand in: says what it was asked to run
printf '#!/usr/bin/env bash\nprintf "RUN:%%s\\n" "$*"\n' >"$REPO/tests/run-tests.sh"
cat >"$REPO/lib/frappe-local/sites.sh" <<'EOF'
fl_site_one() {
  echo one
}

fl_site_two() {
  echo two
}
EOF
printf 'fl_ports_x() { :; }\n' >"$REPO/lib/frappe-local/ports.sh"
for t in sites cli agent-contracts mentions-two ports other affected docs docs-command doctor doctor-hardening repair repair-json json share share-gateway release-notes changelog install-json lock; do printf '# test\n' >"$REPO/tests/test-$t.sh"; done
printf 'run fl_site_two here\n' >"$REPO/tests/test-mentions-two.sh"
printf 'page\n' >"$REPO/docs/a.md"
printf 'harness\n' >"$REPO/tests/lib/harness.sh"
printf 'mock\n' >"$REPO/tests/mocks/bin/git"
for d in lib/frappe-local/share macos/BenchBarTests/Fixtures scripts site; do printf 'keep\n' >"$REPO/$d/.keep"; done
printf 'entry\n' >"$REPO/benchbar"
printf 'web: x\n' >"$REPO/templates/Procfile.lean"
git -C "$REPO" init -q -b main
git -C "$REPO" add -A
git -C "$REPO" commit -q -m base
git -C "$REPO" checkout -q -b work

# aff ARGS...: run affected.sh in the fake repository
aff() { OUT="$(cd "$REPO" && bash tests/affected.sh "$@" 2>&1)" && CODE=0 || CODE=$?; }
# reset: back to the base commit, nothing uncommitted
reset() { git -C "$REPO" reset -q --hard main; git -C "$REPO" clean -q -fd; }

# ---- nothing changed: nothing selected, exit 0, one line
aff --base main
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "nothing to test"
assert_eq "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"

# ---- docs (committed): the two tests that read docs/, no shellcheck
printf 'more\n' >>"$REPO/docs/a.md"
git -C "$REPO" commit -q -am docs
aff --base main --list
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "affected: test-docs test-docs-command"
assert_not_contains "$OUT" "shellcheck"
reset
# app, site and tray files only: no tests at all
printf 'x\n' >"$REPO/macos/a.swift"
printf 'x\n' >"$REPO/site/index.md"
aff --base main
assert_contains "$OUT" "nothing to test"
aff --base main --machine
assert_contains "$OUT" "mode=none"
reset

# ---- CI-8: files whose tests the function match alone misses
# the doctor check library: the doctor and repair tests run the command, never name chk_runner
printf '\nchk_runner() {\n  :\n}\n' >"$REPO/lib/frappe-local/checks.sh"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m checks
aff --base main --list
for t in test-doctor test-doctor-hardening test-repair test-repair-json test-json test-cli; do assert_contains "$OUT" " $t" "(checks.sh)"; done
reset
# the LAN gateway's JavaScript and Python
printf 'x\n' >"$REPO/lib/frappe-local/share/gateway.js"
aff --base main --list
for t in test-share test-share-gateway; do assert_contains "$OUT" " $t" "(share/gateway.js)"; done
reset
# the LAN gateway's own JavaScript tests and their helpers
mkdir -p "$REPO/tests/share"
for f in tests/share/join.test.js tests/share/gateway_harness.js; do
  printf 'x\n' >"$REPO/$f"
  aff --base main --list
  assert_contains "$OUT" "test-share-gateway" "($f)"; assert_not_contains "$OUT" "every test" "($f)"
  reset
  mkdir -p "$REPO/tests/share"
done
# a file no test is known to cover runs everything; the files another job covers run nothing
for f in scripts/unknown-tool.py .shellcheckrc .gitignore tests/data.json; do
  printf 'x\n' >"$REPO/$f"
  aff --base main --machine
  assert_contains "$OUT" "mode=full" "($f)"
  reset
done
for f in install.ps1 scripts/app-icon.py windows/tray/a.cs macos/a.swift examples/x.json CHANGELOG.md .github/CODEOWNERS; do
  case "$f" in */*) mkdir -p "$REPO/${f%/*}" ;; esac
  printf 'x\n' >"$REPO/$f"
  aff --base main --machine
  assert_contains "$OUT" "mode=none" "($f)"
  reset
done
# a workflow, Dependabot's file and the pinned Swift packages: the supply chain test
for f in .github/workflows/other.yml .github/dependabot.yml macos/Package.resolved windows/shim/go.mod; do
  case "$f" in */*) mkdir -p "$REPO/${f%/*}" ;; esac
  printf 'x\n' >"$REPO/$f"
  aff --base main --list
  assert_contains "$OUT" "affected: test-supply-chain" "($f)"
  reset
done
# the fixtures the macOS app tests share with the CLI tests
printf '{}\n' >"$REPO/macos/BenchBarTests/Fixtures/x.json"
aff --base main --list
assert_contains "$OUT" "affected: test-json test-install-json test-lock" "(Fixtures)"
reset
# the tray's recorded CLI output: its own test, not the app's
mkdir -p "$REPO/windows/tray/fixtures/cli"
printf '{}\n' >"$REPO/windows/tray/fixtures/cli/x.json"
aff --base main --list
assert_contains "$OUT" "affected: test-tray-fixtures" "(windows/tray/fixtures)"
reset
# scripts: the tests that run them
printf '#!/bin/sh\n' >"$REPO/scripts/release-notes.sh"
printf '#!/bin/sh\n' >"$REPO/scripts/other.sh"
aff --base main --list
assert_contains "$OUT" "affected: test-release-notes shellcheck" "(scripts/)"
reset
printf '#!/bin/sh\n' >"$REPO/scripts/changelog-fold.sh"
aff --base main --list
assert_contains "$OUT" "affected: test-changelog test-release-notes shellcheck" "(scripts/changelog-fold.sh)"
reset
mkdir -p "$REPO/changelog.d"
printf '### Docs\n' >"$REPO/changelog.d/1-x.md"
aff --base main --list
assert_contains "$OUT" "affected: test-changelog" "(changelog.d)"
reset
# the harness, the mocks, run-tests.sh, the entry point, templates and the selector itself run everything
printf '# x\n' >>"$REPO/tests/affected.sh"
aff --base main --list
assert_contains "$OUT" "every test" "(affected.sh)"
reset

# ---- --machine and --files: what CI reads
aff --base main --machine
assert_eq "mode=none
tests=
shellcheck=false
shellcheck_files=" "$OUT"
printf '\n# touched\n' >>"$REPO/lib/frappe-local/sites.sh"
printf '# x\n' >>"$REPO/tests/test-ports.sh"
aff --base main --machine
assert_contains "$OUT" "mode=affected"
assert_contains "$OUT" "tests=test-sites"; assert_contains "$OUT" " test-ports "; assert_contains "$OUT" "shellcheck=true"
assert_contains "$OUT" "shellcheck_files=lib/frappe-local/sites.sh tests/test-ports.sh"
reset
aff --machine --files "lib/frappe-local/sites.sh docs/a.md"
assert_contains "$OUT" "mode=affected"
assert_contains "$OUT" " test-docs" "(--files)"; assert_contains "$OUT" "test-sites"; assert_contains "$OUT" "test-mentions-two" "(--files counts every function as touched)"
aff --machine --files "tests/lib/harness.sh"
assert_contains "$OUT" "mode=full"
aff --machine --files "macos/a.swift windows/x.cs"
assert_contains "$OUT" "mode=none"
aff --files
assert_eq "1" "$CODE"; assert_contains "$OUT" "--files needs a list"

# ---- a lib file, edited inside one function and not committed: its test, the
# test that names the function, test-cli, test-agent-contracts, shellcheck
sed 's/echo two/echo TWO/' "$REPO/lib/frappe-local/sites.sh" >"$TMP_DIR/s" && mv "$TMP_DIR/s" "$REPO/lib/frappe-local/sites.sh"
aff --base main --list
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "affected: test-sites test-install-json test-mentions-two test-cli test-agent-contracts shellcheck"
assert_contains "$OUT" "functions touched: fl_site_two"
assert_not_contains "$OUT" "test-ports"; assert_not_contains "$OUT" "test-other"
# without --list it hands the names to run-tests.sh
aff --base main
assert_contains "$OUT" "RUN:test-sites test-install-json test-mentions-two test-cli test-agent-contracts shellcheck"
reset

# ---- a new function in a committed change, a new untracked lib file without a test
printf '\nfl_site_three() {\n  :\n}\n' >>"$REPO/lib/frappe-local/sites.sh"
git -C "$REPO" commit -q -am three
printf 'fl_new_thing() { :; }\n' >"$REPO/lib/frappe-local/newthing.sh"
printf 'fl_new_thing\n' >"$REPO/tests/test-other.sh"
aff --base main --list
assert_contains "$OUT" "test-sites"; assert_contains "$OUT" "test-other"
assert_contains "$OUT" "fl_new_thing"; assert_contains "$OUT" "fl_site_three"
# code added after fl_site_two sits in a hunk git labels fl_site_two: one test
# too many is the safe side. A lib file with no test of its name and no family
# (newthing.sh here) selects the end to end core set
assert_contains "$OUT" "test-doctor"; assert_contains "$OUT" "test-ports"
reset

# ---- a test split into parts: a change to its lib file picks every part
for t in sites-2 sites-3 agent-contracts-2; do printf '# test\n' >"$REPO/tests/test-$t.sh"; done
printf '\n# touched\n' >>"$REPO/lib/frappe-local/sites.sh"
aff --base main --list
assert_eq "0" "$CODE" "$OUT"
for t in test-sites test-sites-2 test-sites-3 test-agent-contracts test-agent-contracts-2 test-cli; do assert_contains "$OUT" " $t"; done
assert_not_contains "$OUT" "test-ports"
reset

# ---- a test file alone: that test and shellcheck
printf '# changed\n' >>"$REPO/tests/test-ports.sh"
aff --base main --list
assert_contains "$OUT" "affected: test-ports shellcheck"
reset

# ---- the agent hooks and the project settings: test-guards and shellcheck
mkdir -p "$REPO/.claude"
printf '# hook\n' >"$REPO/.claude/guard-rm.sh"
aff --base main --list
assert_contains "$OUT" "affected: test-guards shellcheck"
reset
mkdir -p "$REPO/.claude"
printf '{}\n' >"$REPO/.claude/settings.json"
aff --base main --list
assert_contains "$OUT" "affected: test-guards shellcheck"
reset

# ---- the full suite: the harness, the mocks, run-tests.sh, the entry point, templates
for f in tests/lib/harness.sh tests/mocks/bin/git tests/run-tests.sh benchbar templates/Procfile.lean; do
  printf '# x\n' >>"$REPO/$f"
  aff --base main
  assert_eq "0" "$CODE" "$OUT"
  assert_contains "$OUT" "every test" "($f)"
  assert_contains "$OUT" "RUN:" "($f)"
  assert_not_contains "$OUT" "RUN:test-" "($f)"
  reset
done

# ---- --all, an unknown base, an unknown argument
aff --all --list
assert_eq "0" "$CODE"; assert_contains "$OUT" "every test"
aff --base no-such-ref
assert_eq "1" "$CODE"; assert_contains "$OUT" "no such ref no-such-ref"
aff --sideways
assert_eq "1" "$CODE"; assert_contains "$OUT" "unknown argument --sideways"

# ---- the real repository: every lib file has a test of its own name or a family (--lib-coverage)
OUT="$(cd "$ROOT" && bash tests/affected.sh --lib-coverage 2>&1)" && CODE=0 || CODE=$?
assert_eq "0" "$CODE" "$OUT"
# and the selector's families name real tests (a typo would silently select nothing)
while IFS= read -r t; do
  [[ -f "$ROOT/tests/$t.sh" ]] || fail "tests/affected.sh names $t, which is not a test file"
done < <(sed -n '/^lib_family()/,/^}/p;/^script_tests()/,/^}/p' "$ROOT/tests/affected.sh" | grep -oE 'test-[a-z0-9-]+' | sort -u)
# the examples of CI-8, on the real tree
OUT="$(cd "$ROOT" && bash tests/affected.sh --files "lib/frappe-local/checks.sh" --machine)"
for t in test-doctor test-doctor-hardening test-repair; do assert_contains "$OUT" " $t" "(real checks.sh)"; done
OUT="$(cd "$ROOT" && bash tests/affected.sh --files "lib/frappe-local/share/gateway.js macos/BenchBarTests/Fixtures/app-list.json docs/index.md scripts/homebrew-render.sh" --machine)"
for t in test-share-gateway test-share test-share-run test-share-admin test-json test-install-json test-lock test-docs test-docs-command test-packaging test-homebrew; do
  assert_contains "$OUT" "$t" "(real tree)"
done

# ---- run-tests.sh: a share test passes only with its own ok line. Under bash 3.2 a set -u abort inside a
# function, with an EXIT trap, exits 0; the exit code alone would count it as passed. Other tests keep
# exit-code judging (some upstream ones print no ok line). The real run-tests.sh runs here, in a copy of
# the repository whose tests are stand-ins under real names, so the suite never picks them up.
RT="$TMP_DIR/rt"
mkdir -p "$RT/tests" "$RT/lib/frappe-local"
cp "$ROOT/tests/run-tests.sh" "$RT/tests/run-tests.sh"
for f in benchbar 00-mac-system-deps.sh 00-linux-system-deps.sh 01-install-bench-and-site.sh 02-background-service.sh lib/frappe-local/x.sh; do
  printf '#!/usr/bin/env bash\n' >"$RT/$f"
done
# stops halfway with exit 0 and no ok line (what a bash 3.2 set -u abort does), on any bash
printf 'printf "test-share: half\\n"\nexit 0\n' >"$RT/tests/test-share.sh"
printf 'printf "test-share-run: ok (SKIPPED: no node)\\n"\n' >"$RT/tests/test-share-run.sh"
printf 'printf "SKIP: node not found\\n"\n' >"$RT/tests/test-share-gateway.sh"
printf 'printf "test-share-preflight: okay\\n"\n' >"$RT/tests/test-share-preflight.sh"
printf 'printf "test-lan-guard: half\\n"\nexit 0\n' >"$RT/tests/test-lan-guard.sh"
printf 'exit 0\n' >"$RT/tests/test-cli.sh"
jobs="test-share test-share-run test-share-gateway test-share-preflight test-lan-guard test-cli"
set +e
# shellcheck disable=SC2086  # the job names are words
OUT="$(PARALLEL=2 bash "$RT/tests/run-tests.sh" $jobs 2>&1)"; CODE=$?
set -e
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "--- FAIL: test-share (exit 1,"
assert_contains "$OUT" 'test-share exited 0 without its "test-share: ok" line'
assert_contains "$OUT" "--- FAIL: test-share-gateway (exit 1,"
assert_contains "$OUT" "--- FAIL: test-share-preflight (exit 1," "(okay is not ok)"
assert_contains "$OUT" "--- ok: test-share-run" "(an ok line with a note in parentheses, as a skip prints it)"
assert_contains "$OUT" "--- ok: test-cli" "(a test of another name keeps exit-code judging)"
assert_contains "$OUT" "--- FAIL: test-lan-guard (exit 1," "(the lan-guard test is judged by its ok line too)"
assert_contains "$OUT" 'test-lan-guard exited 0 without its "test-lan-guard: ok" line'
assert_contains "$OUT" "FAILED: test-share test-share-gateway test-share-preflight test-lan-guard"
# the real abort, where it exits 0 (bash 3.2: a set -u abort inside a function, with an EXIT trap): failed
if [[ "$(bash -c 'printf %s "${BASH_VERSINFO[0]}"')" -lt 4 ]]; then
  cat >"$RT/tests/test-share.sh" <<'SH'
set -euo pipefail
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
f() { printf '%s\n' "${BENCHBAR_TEST_NEVER_SET}"; }
f
printf 'test-share: ok\n'
SH
  set +e; OUT="$(bash "$RT/tests/run-tests.sh" test-share 2>&1)"; CODE=$?; set -e
  assert_eq "1" "$CODE" "$OUT"
  assert_contains "$OUT" 'test-share exited 0 without its "test-share: ok" line'
fi

printf 'test-affected: ok\n'
