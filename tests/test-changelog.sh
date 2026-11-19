#!/usr/bin/env bash
# scripts/changelog-fold.sh: folds changelog.d fragments into "## Unreleased"
# (same name sections merged, fixed section order, one blank line between,
# fragments removed), --check refuses a bad fragment, --print writes nothing,
# a second run is a no-op, scripts/release-notes.sh still reads the folded
# file, and the fragments in this repository are valid.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

FOLD="$ROOT/scripts/changelog-fold.sh"
CL="$TMP_DIR/CHANGELOG.md"
FD="$TMP_DIR/changelog.d"
mkdir -p "$FD"
fold() { set +e; OUT="$(CHANGELOG="$CL" CHANGELOG_DIR="$FD" bash "$FOLD" "$@" 2>&1)"; CODE=$?; set -e; }
fresh() {
  cat >"$CL" <<'MD'
# Changelog

All notable changes to this project are documented here.

## Unreleased

### Mac app

- Existing app line.

### Hand written section

- Kept after the known ones.

### Docs

- Existing docs line.

## 9.1.0 - 2026-10-01

The summary line.

### Added

- a thing

## 9.0.0 - 2026-09-01

- older
MD
  local f
  for f in "$FD"/*; do
    [[ -e "$f" ]] && rm -f -- "$f"
  done
  return 0
}
frag() { printf '%b' "$2" >"$FD/$1"; }

# ---- the README is not a fragment; no fragments: nothing changes
fresh
printf 'the format\n' >"$FD/README.md"
cp "$CL" "$TMP_DIR/before.md"
fold; assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "unchanged: no fragments"
cmp -s "$CL" "$TMP_DIR/before.md" || fail "a fold without fragments changed CHANGELOG.md"
fold --check; assert_eq "0" "$CODE" "$OUT"

# ---- fold: sections merged, in the fixed order, one blank line between
frag 12-second.md '### Docs\n\n- Docs from 12.\n\n### Command line\n\n- Command from 12.\n'
frag 11-first.md '### Mac app\n- App from 11, line one\n  continued here.\n- App line two.\n\n### Agents and MCP\n\n- MCP from 11.\n'
fold --print; assert_eq "0" "$CODE" "$OUT"
printed="$OUT"
assert_file "$FD/11-first.md" "(--print removes nothing)"
cmp -s "$CL" "$TMP_DIR/before.md" || fail "--print wrote CHANGELOG.md"
fold; assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "folded 2 fragment"
assert_no_file "$FD/11-first.md"; assert_no_file "$FD/12-second.md"; assert_file "$FD/README.md" "(README.md stays)"
got="$(cat "$CL")"
want='# Changelog

All notable changes to this project are documented here.

## Unreleased

### Command line

- Command from 12.

### Mac app

- Existing app line.
- App from 11, line one
  continued here.
- App line two.

### Agents and MCP

- MCP from 11.

### Docs

- Existing docs line.
- Docs from 12.

### Hand written section

- Kept after the known ones.

## 9.1.0 - 2026-10-01'
assert_contains "$got" "$want"
# the printed section is the Unreleased block that was written
block="$(printf '%s\n' "$got" | sed -n '/^## Unreleased$/,/^## 9.1.0/p' | sed '$d' | sed '$d')"
assert_eq "$printed" "$block" "(--print equals the written block)"
# the released sections after Unreleased are untouched
assert_eq "$(sed -n '/^## 9.1.0/,$p' "$TMP_DIR/before.md")" "$(sed -n '/^## 9.1.0/,$p' "$CL")" "(older sections)"

# ---- a second run is a no-op
cp "$CL" "$TMP_DIR/folded.md"
fold; assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "unchanged"
cmp -s "$CL" "$TMP_DIR/folded.md" || fail "the second fold changed CHANGELOG.md"

# ---- release-notes.sh reads a folded file once the heading carries the version
sed 's/^## Unreleased$/## 9.2.0 - 2026-12-01/' "$CL" >"$TMP_DIR/released.md"
set +e; NOTES="$(CHANGELOG="$TMP_DIR/released.md" bash "$ROOT/scripts/release-notes.sh" 9.2.0 2>&1)"; code=$?; set -e
assert_eq "0" "$code" "$NOTES"
assert_contains "$NOTES" "### Command line"
assert_contains "$NOTES" "- Docs from 12."
assert_contains "$NOTES" "- Kept after the known ones."
assert_not_contains "$NOTES" "The summary line."

# ---- an Unreleased block with a summary line, and one at the end of the file
cat >"$CL" <<'MD'
# Changelog

## Unreleased

A line of text before any section.

### Install

- Old install line.
MD
frag 7-tail.md '### Install\n- New install line.\n\n### For contributors\n- Contributor line.\n'
fold; assert_eq "0" "$CODE" "$OUT"
assert_eq "# Changelog

## Unreleased

A line of text before any section.

### Install

- Old install line.
- New install line.

### For contributors

- Contributor line." "$(cat "$CL")" "(Unreleased at the end of the file)"

# ---- --check refuses what does not parse, and fold then changes nothing
fresh
cp "$CL" "$TMP_DIR/before.md"
check_bad() { # NAME CONTENT EXPECTED-TEXT
  fresh
  frag "$1" "$2"
  fold --check; assert_eq "1" "$CODE" "$1: $OUT"; assert_contains "$OUT" "$3" "($1)"
  fold; assert_eq "1" "$CODE" "$1 fold: $OUT"
  cmp -s "$CL" "$TMP_DIR/before.md" || fail "$1: a refused fold changed CHANGELOG.md"
  assert_file "$FD/$1" "($1 stays when refused)"
}
check_bad 5-unknown.md '### Not a section\n- x\n' 'unknown section "Not a section"'
check_bad 5-empty.md '### Docs\n\n' 'has no bullet line'
check_bad 5-nothing.md '' 'no ### section heading'
check_bad 5-text.md '### Docs\n- ok\nloose text\n' 'a line must be a bullet'
check_bad 5-first.md '- bullet first\n### Docs\n- x\n' 'a bullet before the first ### heading'
check_bad 5-level.md '## Docs\n- x\n' 'only ### section headings'
check_bad 5-em.md "### Docs\n- one \xe2\x80\x94 two\n" 'em dash or en dash'
check_bad 5-en.md "### Docs\n- one \xe2\x80\x93 two\n" 'em dash or en dash'
check_bad Notes.md '### Docs\n- x\n' 'the name must be <issue number>-<short-slug>.md'
check_bad 5-CAPS.md '### Docs\n- x\n' 'the name must be'
check_bad 5-crlf.md '### Docs\r\n- x\r\n' 'carriage return'
# one bad fragment among good ones: the good ones are not folded either
fresh
frag 1-good.md '### Docs\n- fine\n'
frag 2-bad.md '### Nope\n- x\n'
fold; assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "2-bad.md:1:"
assert_file "$FD/1-good.md"
cmp -s "$CL" "$TMP_DIR/before.md" || fail "a refused fold changed CHANGELOG.md"
# no Unreleased heading to fold into
printf '# Changelog\n\n## 1.0.0 - 2026-01-01\n\n- x\n' >"$CL"
fold --check; assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" 'no "## Unreleased" heading'
fold --bogus; assert_eq "2" "$CODE" "$OUT"

# ---- the fragments in this repository are valid
set +e; OUT="$(bash "$FOLD" --check 2>&1)"; CODE=$?; set -e
assert_eq "0" "$CODE" "$OUT"

printf 'test-changelog: ok\n'
