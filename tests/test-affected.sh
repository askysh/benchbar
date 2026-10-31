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
mkdir -p "$REPO/tests/lib" "$REPO/tests/mocks/bin" "$REPO/lib/frappe-local" "$REPO/docs" "$REPO/templates" "$REPO/macos"
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
for t in sites cli agent-contracts mentions-two ports other affected; do printf '# test\n' >"$REPO/tests/test-$t.sh"; done
printf 'run fl_site_two here\n' >"$REPO/tests/test-mentions-two.sh"
printf 'page\n' >"$REPO/docs/a.md"
printf 'harness\n' >"$REPO/tests/lib/harness.sh"
printf 'mock\n' >"$REPO/tests/mocks/bin/git"
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

# ---- docs only (committed): no tests
printf 'more\n' >>"$REPO/docs/a.md"
git -C "$REPO" commit -q -am docs
aff --base main
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "nothing to test"
# app files only: no shell tests either
printf 'x\n' >"$REPO/macos/a.swift"
aff --base main
assert_contains "$OUT" "nothing to test"
reset

# ---- a lib file, edited inside one function and not committed: its test, the
# test that names the function, test-cli, test-agent-contracts, shellcheck
sed 's/echo two/echo TWO/' "$REPO/lib/frappe-local/sites.sh" >"$TMP_DIR/s" && mv "$TMP_DIR/s" "$REPO/lib/frappe-local/sites.sh"
aff --base main --list
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "affected: test-sites test-mentions-two test-cli test-agent-contracts shellcheck"
assert_contains "$OUT" "functions touched: fl_site_two"
assert_not_contains "$OUT" "test-ports"; assert_not_contains "$OUT" "test-other"
# without --list it hands the names to run-tests.sh
aff --base main
assert_contains "$OUT" "RUN:test-sites test-mentions-two test-cli test-agent-contracts shellcheck"
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
# too many is the safe side
assert_not_contains "$OUT" "test-ports"
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

printf 'test-affected: ok\n'
