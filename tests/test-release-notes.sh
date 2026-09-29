#!/usr/bin/env bash
# scripts/release-notes.sh: the Update section with the command comes
# first, then the version's CHANGELOG section, then install and checksums;
# signed and ad hoc wording; a version without a section fails.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

NOTES="$ROOT/scripts/release-notes.sh"
cat >"$TMP_DIR/CHANGELOG.md" <<'MD'
# Changelog

## Unreleased

- not yet

## 9.1.0 - 2026-10-01

The summary line.

### Added

- a thing

## 9.0.0 - 2026-09-01

- older
MD
notes() { set +e; OUT="$(CHANGELOG="$TMP_DIR/CHANGELOG.md" bash "$NOTES" "$@" 2>&1)"; CODE=$?; set -e; }

notes 9.1.0
assert_eq "0" "$CODE" "$OUT"
assert_eq "## Update" "$(printf '%s\n' "$OUT" | head -n 1)" "(the Update section comes first)"
assert_contains "$OUT" "curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash -s -- --yes"
assert_contains "$OUT" "**Update Now**"
assert_contains "$OUT" "benchbar self-update"
assert_contains "$OUT" "--app-only"
assert_contains "$OUT" "The summary line."
assert_contains "$OUT" "- a thing"
assert_not_contains "$OUT" "older"
assert_not_contains "$OUT" "not yet"
assert_not_contains "$OUT" "## 9.1.0"
assert_contains "$OUT" "not signed with an Apple Developer ID"
assert_contains "$OUT" "Checksums are in \`SHA256SUMS\`."
# the Update command comes before the changes
upd="$(printf '%s\n' "$OUT" | grep -n -- '--yes$' | head -n 1 | cut -d: -f1)"
chg="$(printf '%s\n' "$OUT" | grep -n 'The summary line' | cut -d: -f1)"
[[ "$upd" -lt "$chg" ]] || fail "the update command must come before the changes"

notes 9.1.0 --signed
assert_contains "$OUT" "Signed with a Developer ID and notarized"
assert_not_contains "$OUT" "not signed"

notes 1.2.3
assert_eq "1" "$CODE"; assert_contains "$OUT" 'no "## 1.2.3 " section'
notes
assert_eq "1" "$CODE"; assert_contains "$OUT" "Usage:"

printf 'test-release-notes: ok\n'
