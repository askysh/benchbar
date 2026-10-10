#!/bin/bash
# PreToolUse hook for Bash: blocks GitHub API writes and Task Scheduler
# changes that permission rules cannot express, because deny rules win over
# allow rules and cannot say "except". Pure bash plus grep and sed, no
# python3, so it works in Git Bash on Windows; runs on macOS /bin/bash 3.2
# too. Exit 2 blocks.
#
# gh api: reads pass. A write (a method other than GET, a -f/-F/--field/
# --raw-field/--input body without an explicit GET, or a GraphQL mutation) is
# blocked unless the whole command is the review thread resolve route:
#   gh api -X POST repos/OWNER/REPO/pulls/N/ccr/comments/ID/resolve
# schtasks: /Create only for the task "BenchBar Keepalive" (one /TN in that
# call), /Delete and /Change never. Switches count with / or - in any case.
#
# Each call is checked on its own text: from "gh api" (or "schtasks") to the
# next one. Whatever follows in the same command line is part of that text,
# so a chained command can only make the check stricter.
input="$(cat)"
# The command string, still JSON escaped. The key with unescaped quotes can
# only be the real key; the description is never looked at.
cmd="$(printf '%s' "$input" | sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' | head -n 1)"
[ -n "$cmd" ] || exit 0

# Prints each chunk that starts with the pattern, up to the next match, one
# per line (newlines inside the command are JSON escaped, so none are real).
# Lowercased: Windows finds SCHTASKS and Schtasks.exe as well, so the
# patterns and every check below are lowercase or case-insensitive.
chunks() {
  printf '%s' "$cmd" | awk -v pat="$1" '{
    s = tolower($0)
    while ((i = match(s, pat)) > 0) {
      rest = substr(s, i + RLENGTH)
      j = match(rest, pat)
      if (j > 0) { print substr(s, i, RLENGTH + j - 1); s = substr(rest, j) }
      else { print substr(s, i); s = "" }
    }
  }'
}

matches() { printf '%s' "$1" | grep -Eiq -- "$2"; }

while IFS= read -r call; do
  [ -n "$call" ] || continue
  write=0
  # -X POST, -XPOST, -iX DELETE, --method=PUT ...
  matches "$call" '(^|[[:space:]])(-[A-Za-z]*X[[:space:]=]*|--method[[:space:]=]+)(POST|PUT|PATCH|DELETE)' && write=1
  # An explicit GET counts only in this call itself, before any ; && || |
  # or newline: a GET in a chained command must not excuse a body flag.
  own="$(printf '%s' "$call" | sed -E 's/(;|&|\||\\n).*//')"
  explicit_get=0
  matches "$own" '(^|[[:space:]])(-[A-Za-z]*X[[:space:]=]*|--method[[:space:]=]+)GET([^A-Za-z]|$)' && explicit_get=1
  # -f x=y, -fx=y, -iF x=y, --field, --raw-field, --input
  if matches "$call" '(^|[[:space:]])(-[A-Za-z]*[fF]|--field|--raw-field|--input)' && [ "$explicit_get" = 0 ]; then
    write=1
  fi
  matches "$call" 'graphql' && matches "$call" 'mutation' && write=1
  if [ "$write" = 1 ]; then
    resolve='^gh api (-X|--method) POST repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pulls/[0-9]+/ccr/comments/[A-Za-z0-9_-]+/resolve$'
    if ! [[ $cmd =~ $resolve ]]; then
      echo "Blocked: gh api writes are not allowed here, except resolving a review thread (gh api -X POST repos/O/R/pulls/N/ccr/comments/ID/resolve)." >&2
      exit 2
    fi
  fi
done <<EOF
$(chunks '(^|[^A-Za-z0-9_.-])gh[[:space:]]+api([[:space:]]|$)')
EOF

while IFS= read -r call; do
  [ -n "$call" ] || continue
  if matches "$call" '[[:space:]][-/]+(delete|change)([[:space:]]|$)'; then
    echo "Blocked: schtasks /Delete and /Change are not allowed here; run them yourself." >&2
    exit 2
  fi
  if matches "$call" '[[:space:]][-/]+create([[:space:]]|$)'; then
    names="$(printf '%s' "$call" | grep -Eio -- '[[:space:]][-/]+tn([[:space:]]|$)' | wc -l | tr -d ' ')"
    keepalive='[[:space:]][-/]+tn[[:space:]]+(\\"|'"'"')benchbar keepalive(\\"|'"'"')([[:space:]]|$)'
    if [ "$names" != 1 ] || ! [[ $call =~ $keepalive ]]; then
      echo "Blocked: schtasks /Create is only allowed for the task named \"BenchBar Keepalive\"." >&2
      exit 2
    fi
  fi
done <<EOF
$(chunks '(^|[^A-Za-z0-9_.-])schtasks(\.exe)?([[:space:]]|$)')
EOF
exit 0
