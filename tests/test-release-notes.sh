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
assert_eq "## Update" "${OUT%%$'\n'*}" "(the Update section comes first)"
assert_contains "$OUT" "curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash -s -- --yes"
assert_contains "$OUT" "**Update Now**"
assert_contains "$OUT" "benchbar self-update"
# the cask updates itself, so plain "brew upgrade" skips it: the notes name the cask
assert_contains "$OUT" 'brew upgrade --cask askysh/tap/benchbar-app'
# shellcheck disable=SC2016 # the backticks are Markdown, not a command
assert_contains "$OUT" 'a plain `brew upgrade` skips a cask that updates itself'
assert_contains "$OUT" "--app-only"
assert_contains "$OUT" "The summary line."
assert_contains "$OUT" "- a thing"
assert_contains "$OUT" "https://benchbar.akashmishra.com/whats-new/"
assert_not_contains "$OUT" "older"
assert_not_contains "$OUT" "not yet"
assert_not_contains "$OUT" "## 9.1.0"
assert_contains "$OUT" "not signed with an Apple Developer ID"
assert_contains "$OUT" "Checksums are in \`SHA256SUMS\`."
# the Update command comes before the changes
upd="$(grep -m1 -n -- '--yes$' <<<"$OUT" | cut -d: -f1)"
chg="$(printf '%s\n' "$OUT" | grep -n 'The summary line' | cut -d: -f1)"
[[ "$upd" -lt "$chg" ]] || fail "the update command must come before the changes"

notes 9.1.0 --signed
assert_contains "$OUT" "Signed with a Developer ID and notarized"
assert_not_contains "$OUT" "not signed"

notes 1.2.3
assert_eq "1" "$CODE"; assert_contains "$OUT" 'no "## 1.2.3 " section'

# a release candidate: no Update section, no Homebrew line, the pinned install
# line, and its changes from "## Unreleased" plus the fragments
mkdir -p "$TMP_DIR/frags"
printf '### Docs\n\n- A waiting fragment.\n' >"$TMP_DIR/frags/7-waiting.md"
export CHANGELOG_DIR="$TMP_DIR/frags"
notes 9.2.0-rc.1 --signed
assert_eq "0" "$CODE" "$OUT"
assert_eq "## Release candidate" "${OUT%%$'\n'*}"
assert_contains "$OUT" "pre-release** of BenchBar 9.2.0"
assert_contains "$OUT" "askysh/benchbar/v9.2.0-rc.1/install.sh | bash -s -- --version v9.2.0-rc.1"
assert_contains "$OUT" "- not yet"
assert_contains "$OUT" "Homebrew and \`benchbar self-update\` cannot install a candidate"
assert_contains "$OUT" "(add \`--no-app\` for the tool alone)"
assert_contains "$OUT" "A waiting fragment."
assert_contains "$OUT" "Signed with a Developer ID and notarized"
assert_not_contains "$OUT" "## Update"
assert_not_contains "$OUT" "brew install"
assert_not_contains "$OUT" "self-update --yes"
# its own section wins when CHANGELOG.md has one
printf '\n## 9.3.0-rc.2 - 2026-11-01\n\n- own section\n' >>"$TMP_DIR/CHANGELOG.md"
notes 9.3.0-rc.2
assert_contains "$OUT" "- own section"; assert_not_contains "$OUT" "A waiting fragment."
assert_contains "$OUT" "not signed with an Apple Developer ID"
unset CHANGELOG_DIR
# only the strict form is a version
notes "1.2.3 --draft"; assert_eq "1" "$CODE"; assert_contains "$OUT" "is not a version"
notes 9.1.0-beta.1; assert_eq "1" "$CODE"
notes
assert_eq "1" "$CODE"; assert_contains "$OUT" "Usage:"

printf 'test-release-notes: ok\n'
