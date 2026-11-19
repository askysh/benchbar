#!/usr/bin/env bash
# One version source: scripts/check-version.sh knows what a version is and
# whether every place agrees (benchbar, macos/project.yml, the bug report
# forms; for a release also CHANGELOG.md, README.md and ROADMAP.md), the
# checkout itself passes it, scripts/bump-version.sh sets every place so the
# check passes, a release candidate (X.Y.Z-rc.N) needs no changelog section,
# and the strict version pattern is the same in all three release workflows.
# shellcheck disable=SC2016  # the patterns hold literal $ on purpose
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

CHECK="$ROOT/scripts/check-version.sh"
BUMP="$ROOT/scripts/bump-version.sh"
run() { set +e; OUT="$("$@" 2>&1)"; CODE=$?; set -e; }

# ---- this checkout: every place agrees, with the version benchbar says
run bash "$CHECK"
assert_eq 0 "$CODE" "(the checkout's own version places disagree)"$'\n'"$OUT"

# ---- the form
for v in 0.9.0 0.10.2 1.0.0 10.20.30 0.9.0-rc.1 1.2.3-rc.12; do
  run bash "$CHECK" --valid "$v"; assert_eq 0 "$CODE" "$v should be a version: $OUT"
done
for v in "" 1 1.2 1.2.3.4 01.2.3 1.02.3 1.2.3-rc 1.2.3-rc.0 1.2.3-rc.01 1.2.3-beta.1 1.2.3-rc.1-x "1.2.3 --draft" '1.2.3$(id)' v1.2.3 1.2.3- 1.2.x; do
  run bash "$CHECK" --valid "$v"; assert_eq 1 "$CODE" "'$v' should be refused"
done
assert_eq final "$(bash "$CHECK" --kind 0.9.0)"
assert_eq rc "$(bash "$CHECK" --kind 0.9.0-rc.2)"

# ---- the same strict pattern in each release workflow
ERE="$(sed -n "s/^VERSION_RE='\(.*\)'\$/\1/p" "$CHECK")"
[[ -n "$ERE" ]] || fail "no VERSION_RE in check-version.sh"
for wf in release.yml homebrew-tap.yml release-windows.yml; do
  grep -qF -- "$ERE" "$ROOT/.github/workflows/$wf" || fail "$wf does not carry the version pattern of check-version.sh: $ERE"
done

# ---- a scratch checkout to bump
R="$TMP_DIR/root"
mkdir -p "$R/macos" "$R/.github/ISSUE_TEMPLATE" "$R/changelog.d"
cp "$ROOT/benchbar" "$R/benchbar"
cp "$ROOT/macos/project.yml" "$R/macos/project.yml"
cp "$ROOT/.github/ISSUE_TEMPLATE/bug_report.yml" "$ROOT/.github/ISSUE_TEMPLATE/bug_report_windows.yml" "$R/.github/ISSUE_TEMPLATE/"
cp "$ROOT/CHANGELOG.md" "$ROOT/README.md" "$ROOT/ROADMAP.md" "$R/"
printf '### Docs\n\n- A fragment waiting for the release.\n' >"$R/changelog.d/1-waiting.md"
export VERSION_ROOT="$R"

run bash "$CHECK"; assert_eq 0 "$CODE" "(the scratch copy starts consistent) $OUT"

# a place that differs is named
sed 's/^\( *MARKETING_VERSION: *\)"[^"]*"/\1"0.0.1"/' "$R/macos/project.yml" >"$R/p.yml" && mv "$R/p.yml" "$R/macos/project.yml"
run bash "$CHECK"; assert_eq 1 "$CODE"; assert_contains "$OUT" "MARKETING_VERSION in macos/project.yml is '0.0.1'"
cp "$ROOT/macos/project.yml" "$R/macos/project.yml"

# a release: every place is set, the fragment is folded, the heading has a date
export BUMP_DATE=2031-01-02; run bash "$BUMP" 9.9.9 --no-fixtures
assert_eq 0 "$CODE" "$OUT"
assert_contains "$(cat "$R/benchbar")" 'FL_VERSION="9.9.9"'
assert_contains "$(cat "$R/macos/project.yml")" 'MARKETING_VERSION: "9.9.9"'
assert_contains "$(grep placeholder "$R/.github/ISSUE_TEMPLATE/bug_report.yml")" "benchbar 9.9.9"
assert_contains "$(grep -c '9.9.9' "$R/.github/ISSUE_TEMPLATE/bug_report_windows.yml")" 1
assert_contains "$(grep placeholder "$R/.github/ISSUE_TEMPLATE/bug_report_windows.yml")" "benchbar.exe 9.9.9, tray 9.9.9, CLI 9.9.9"
changelog_top="$(sed -n '1,/^## 0\.[0-9]/p' "$R/CHANGELOG.md")"
assert_contains "$changelog_top" $'## Unreleased\n\n## 9.9.9 - 2031-01-02'
assert_contains "$changelog_top" "A fragment waiting for the release."
assert_no_file "$R/changelog.d/1-waiting.md" "(the fragment is folded and removed)"
# README and ROADMAP are prose: the check names them until they say the version
assert_contains "$OUT" "README.md does not mention 9.9.9"
run bash "$CHECK"; assert_eq 1 "$CODE"; assert_contains "$OUT" "ROADMAP.md does not mention 9.9.9"
printf '\n9.9.9 is a test.\n' >>"$R/README.md"; printf '\n**9.9.9, a test.**\n' >>"$R/ROADMAP.md"
run bash "$CHECK"; assert_eq 0 "$CODE" "$OUT"
run bash "$CHECK" --folded; assert_eq 0 "$CODE" "$OUT"
# a second run changes nothing more
cp "$R/CHANGELOG.md" "$TMP_DIR/changelog.once"
BUMP_DATE=2031-01-03; run bash "$BUMP" 9.9.9 --no-fixtures; assert_eq 0 "$CODE" "$OUT"
cmp -s "$R/CHANGELOG.md" "$TMP_DIR/changelog.once" || fail "a second bump changed CHANGELOG.md"

# a left fragment fails --folded only
printf '### Docs\n\n- Late.\n' >"$R/changelog.d/2-late.md"
run bash "$CHECK"; assert_eq 0 "$CODE" "$OUT"
run bash "$CHECK" --folded; assert_eq 1 "$CODE"; assert_contains "$OUT" "changelog fragments are left: 2-late.md"
rm -f "$R/changelog.d/2-late.md"

# the old greps: a bare '## 9.9.9' heading counts, a different one does not
sed 's/^## 9\.9\.9 - .*/## 9.9.9/' "$R/CHANGELOG.md" >"$R/c.md" && mv "$R/c.md" "$R/CHANGELOG.md"
run bash "$CHECK"; assert_eq 0 "$CODE" "(a heading with no date) $OUT"
sed 's/^## 9\.9\.9$/## 9.9.90/' "$R/CHANGELOG.md" >"$R/c.md" && mv "$R/c.md" "$R/CHANGELOG.md"
run bash "$CHECK"; assert_eq 1 "$CODE"; assert_contains "$OUT" "CHANGELOG.md has no '## 9.9.9' heading"

# a release candidate: no changelog section, README or ROADMAP needed
printf '### Docs\n\n- Newer.\n' >"$R/changelog.d/3-newer.md"
run bash "$BUMP" 9.9.10-rc.1 --no-fixtures; assert_eq 0 "$CODE" "$OUT"
assert_contains "$(cat "$R/benchbar")" 'FL_VERSION="9.9.10-rc.1"'
assert_contains "$(cat "$R/macos/project.yml")" 'MARKETING_VERSION: "9.9.10-rc.1"'
assert_file "$R/changelog.d/3-newer.md" "(a candidate leaves the fragments for the release)"
assert_not_contains "$(cat "$R/CHANGELOG.md")" "9.9.10-rc.1"
run bash "$CHECK"; assert_eq 0 "$CODE" "$OUT"
run bash "$CHECK" 9.9.10; assert_eq 1 "$CODE"; assert_contains "$OUT" "FL_VERSION in benchbar is '9.9.10-rc.1', not 9.9.10"

# a bad version changes nothing
before="$(cat "$R/benchbar")"
run bash "$BUMP" "9.9.10 --draft" --no-fixtures; assert_eq 1 "$CODE"; assert_contains "$OUT" "is not a version"
assert_eq "$before" "$(cat "$R/benchbar")"
run bash "$BUMP"; assert_eq 2 "$CODE"

printf 'test-version-sources: ok\n'
