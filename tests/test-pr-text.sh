#!/usr/bin/env bash
# scripts/check-pr-text.sh: a pull request title or commit message with a tool
# trailer ("Co-Authored-By" naming a tool or bot, a "Generated with" line) or a
# title with an em or en dash fails, and the message points at CONTRIBUTING.md.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

CHECK="$ROOT/scripts/check-pr-text.sh"
EM=$'\xe2\x80\x94'
EN=$'\xe2\x80\x93'
check() { set +e; OUT="$(cd "${CHECK_DIR:-$ROOT}" && bash "$CHECK" "$@" 2>&1)"; CODE=$?; set -e; }

assert_file "$CHECK" "(the script exists)"

check "Fix the port check for a stopped bench (#123)"
assert_eq 0 "$CODE" "(a plain title passes)"$'\n'"$OUT"

check "Fix the port check ${EM} for a stopped bench"
assert_eq 1 "$CODE" "(an em dash in the title fails)"
assert_contains "$OUT" "CONTRIBUTING.md" "(the message points at CONTRIBUTING.md)"
assert_contains "$OUT" "dash" "(the message says dash)"

check "Fix the port check ${EN} for a stopped bench"
assert_eq 1 "$CODE" "(an en dash in the title fails)"

# commit messages through git
REPO="$TMP_DIR/repo"
CHECK_DIR="$REPO"
mkdir -p "$REPO"
(
  cd "$REPO"
  git init -q -b main
  git config user.name T; git config user.email t@example.com
  git commit -q --allow-empty -m "Start"
  git checkout -q -b topic
  git commit -q --allow-empty -m "Add a thing" -m "Why it is needed ${EM} an em dash in a body is allowed here."
) >/dev/null
check "Add a thing (#1)" "main..topic"
assert_eq 0 "$CODE" "(a clean commit passes; a dash in a body is not checked)"$'\n'"$OUT"

for trailer in \
  "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" \
  "Co-authored-by: Copilot <copilot@github.com>" \
  "Co-Authored-By: ChatGPT <x@openai.com>" \
  "Co-authored-by: Codex <x@example.com>" \
  "Co-authored-by: Cursor Agent <cursoragent@cursor.com>" \
  "Co-authored-by: some-tool[bot] <1+some-tool[bot]@users.noreply.github.com>" \
  "Generated with Claude Code" \
  "🤖 Generated with [Claude Code](https://claude.com/claude-code)"; do
  (cd "$REPO" && git commit -q --allow-empty -m "Add another" -m "Body." -m "$trailer") >/dev/null
  check "Add a thing (#1)" "main..topic"
  assert_eq 1 "$CODE" "(a commit with '$trailer' fails)"
  assert_contains "$OUT" "CONTRIBUTING.md" "(the message points at CONTRIBUTING.md)"
  (cd "$REPO" && git reset -q --hard HEAD~1)
done

(cd "$REPO" && git commit -q --allow-empty -m "Add a pair" -m "Body." -m "Co-authored-by: Sumanth Udupi <s@example.com>") >/dev/null
check "Add a thing (#1)" "main..topic"
assert_eq 0 "$CODE" "(a human co-author passes)"$'\n'"$OUT"

# a title that carries a trailer
check "Add a thing
Co-Authored-By: Claude <noreply@anthropic.com>"
assert_eq 1 "$CODE" "(a trailer in the title text fails)"

check
assert_eq 2 "$CODE" "(no title is a usage error)"
check "x" "nosuch..range"
assert_eq 2 "$CODE" "(an unreadable range is an error, not a pass)"

printf 'test-pr-text: ok\n'
