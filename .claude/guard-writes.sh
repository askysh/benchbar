#!/bin/bash
# PreToolUse hook for Bash: blocks GitHub API writes and Task Scheduler
# creates that permission rules cannot express, because deny rules win over
# allow rules and cannot say "except". Pure bash, no python3, so it works in
# Git Bash on Windows; runs on macOS /bin/bash 3.2 too. Exit 2 blocks.
#
# gh api: reads pass. A write (a method other than GET, a -f/-F/--field/
# --raw-field/--input body, or a GraphQL mutation) is blocked unless the
# whole command is the review thread resolve route:
#   gh api -X POST repos/OWNER/REPO/pulls/N/ccr/comments/ID/resolve
# schtasks: /Create is blocked unless the task name is "BenchBar Keepalive".
input="$(cat)"
# The command string, still JSON escaped; enough for these checks.
cmd="${input#*\"command\":\"}"
cmd="${cmd%%\",\"*}"
cmd="${cmd%\"\}*}"

gh_api='(^|[^A-Za-z0-9_.-])gh[[:space:]]+api([[:space:]]|$)'
if [[ $input =~ $gh_api ]]; then
  write=0
  # Any method but GET anywhere in the call is a write.
  if printf '%s' "$input" | grep -Eiq -- '(-X|--method)[[:space:]=]*(POST|PUT|PATCH|DELETE)'; then write=1; fi
  explicit_get=0
  if printf '%s' "$input" | grep -Eiq -- '(-X|--method)[[:space:]=]*GET([^A-Za-z]|$)'; then explicit_get=1; fi
  body='[[:space:]](-f|-F|--field|--raw-field|--input)([[:space:]=]|$)'
  if [[ $input =~ $body ]] && [ "$explicit_get" = 0 ]; then write=1; fi
  case "$input" in *graphql*mutation*|*mutation*graphql*) write=1 ;; esac
  if [ "$write" = 1 ]; then
    resolve='^gh api (-X|--method) POST repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pulls/[0-9]+/ccr/comments/[A-Za-z0-9_-]+/resolve$'
    if ! [[ $cmd =~ $resolve ]]; then
      echo "Blocked: gh api writes are not allowed here, except resolving a review thread (gh api -X POST repos/O/R/pulls/N/ccr/comments/ID/resolve)." >&2
      exit 2
    fi
  fi
fi

create='schtasks(\.exe)?[[:space:]].*/[Cc][Rr][Ee][Aa][Tt][Ee]'
if [[ $input =~ $create ]]; then
  name='/[Tt][Nn][[:space:]]+(\\"|'"'"')BenchBar Keepalive(\\"|'"'"')([[:space:]]|$)'
  if ! [[ $cmd =~ $name ]]; then
    echo "Blocked: schtasks /Create is only allowed for the task named \"BenchBar Keepalive\"." >&2
    exit 2
  fi
fi
exit 0
