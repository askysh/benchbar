#!/bin/bash
#
# docs-only.sh: does a range of commits change only documentation?
#
#   scripts/docs-only.sh FROM TO     the files changed between two commits
#   scripts/docs-only.sh --commit C  the files C changed (against its first parent)
#
# "Only documentation" is the rule CI uses to skip the tests on a push
# (docs_paths in scripts/ci-plan.sh): docs/, site/, any *.md and LICENSE.
# tests/test-release-workflows.sh keeps the two patterns equal. auto-tag.yml
# asks it whether a push to main that keeps its version is a docs fix, and
# scripts/release-ci-gate.sh walks back over such commits to the one that
# ran the tests.
#
# Prints the files that are not documentation, one per line.
# Exit: 0 only documentation (or nothing changed), 1 something else changed,
# 2 a commit could not be read.

set -euo pipefail

DOCS_RE='^(docs/.*|site/.*|.*\.md|LICENSE)$'

if [[ "${1:-}" == "--commit" ]]; then
  c="${2:-}"
  if [[ -z "$c" ]] || ! git rev-parse -q --verify "${c}^{commit}" >/dev/null 2>&1; then
    printf 'docs-only: no commit %s\n' "$c" >&2; exit 2
  fi
  if git rev-parse -q --verify "${c}^1^{commit}" >/dev/null 2>&1; then
    from="${c}^1"
  else
    from="$(git hash-object -t tree /dev/null)"   # a root commit: against the empty tree
  fi
  to="$c"
else
  from="${1:-}" to="${2:-}"
  [[ -n "$from" && -n "$to" ]] || { printf 'usage: docs-only.sh FROM TO | --commit C\n' >&2; exit 2; }
fi

files="$(git diff --name-only "$from" "$to")" || { printf 'docs-only: cannot compare %s and %s\n' "$from" "$to" >&2; exit 2; }
rc=0
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  [[ "$f" =~ $DOCS_RE ]] || { printf '%s\n' "$f"; rc=1; }
done <<<"$files"
exit "$rc"
