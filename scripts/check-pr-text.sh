#!/usr/bin/env bash
# check-pr-text.sh: the pull request text rules of CONTRIBUTING.md.
#
#   scripts/check-pr-text.sh TITLE [RANGE]
#
# Fails (exit 1) when
#   - TITLE has an em dash (U+2014) or an en dash (U+2013),
#   - TITLE or the message of a commit in RANGE (a git range such as
#     origin/next-release..HEAD) has a tool trailer: a "Co-Authored-By" line
#     that names a tool or a bot (Claude, Copilot, ChatGPT, Codex, Cursor, ...)
#     or a "Generated with" line.
# A human co-author passes. Exit 2 is a usage error. Run by the "PR text"
# workflow (.github/workflows/pr-text.yml); tests/test-pr-text.sh tests it.
set -euo pipefail

[[ "$#" -ge 1 && "$#" -le 2 ]] || { printf 'usage: check-pr-text.sh TITLE [RANGE]\n' >&2; exit 2; }
title="$1"
range="${2:-}"

fail=0
rule='see "Commits" in CONTRIBUTING.md ("What a pull request needs")'
problem() { printf 'PR text: %s\n' "$1" >&2; fail=1; }

em=$'\xe2\x80\x94'
en=$'\xe2\x80\x93'
case "$title" in
  *"$em"* | *"$en"*) problem "the title has an em dash or an en dash: use a colon, a comma or a new sentence" ;;
esac

# a Co-Authored-By line that names a tool or a bot, or a "Generated with" line
tools='claude|anthropic|copilot|chatgpt|openai|codex|cursor|gemini|aider|devin|windsurf|codeium|\[bot\]'
tool_line() {
  LC_ALL=C grep -i -E -e "^[[:space:]]*co-authored-by:.*($tools)" -e 'generated with' || true
}

found="$(printf '%s\n' "$title" | tool_line)"
[[ -z "$found" ]] || problem "the title has a tool trailer: $found"

if [[ -n "$range" ]]; then
  # a range git cannot read is an error, never a pass
  shas="$(git log --format=%H --no-merges "$range")" || { printf 'check-pr-text: cannot read the range %s
' "$range" >&2; exit 2; }
  for sha in $shas; do
    while IFS= read -r l; do
      [[ -n "$l" ]] || continue
      problem "commit ${sha:0:8} has a tool trailer: $l"
    done <<<"$(git show -s --format=%B "$sha" | tool_line)"
  done
fi

if [[ "$fail" == 1 ]]; then
  printf 'Rule: a plain imperative title that ends in the pull request number, no em or en dash in the title, no tool trailer (no Co-Authored-By for a tool, no "Generated with" line) in the title or any commit; %s.\n' "$rule" >&2
  printf 'Fix: rename the pull request, and reword the commits (git rebase, then force push with lease).\n' >&2
  exit 1
fi
printf 'PR text: ok\n'
