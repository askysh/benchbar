#!/bin/bash
# PreToolUse hook for Bash: blocks GitHub API writes and Task Scheduler
# changes that permission rules cannot express, because deny rules win over
# allow rules and cannot say "except". Pure bash plus grep and sed, no
# python3, so it works in Git Bash on Windows; runs on macOS /bin/bash 3.2
# too. Exit 2 blocks.
#
# gh api: reads pass. REST writes to repos/askysh/benchbar and
# repos/askysh/homebrew-tap pass (see own_repo_write). Any other write (a
# method other than GET, a -f/-F/--field/--raw-field/--input body without an
# explicit GET, or a GraphQL mutation) is blocked unless the whole command is
# the review thread resolve route:
#   gh api -X POST repos/OWNER/REPO/pulls/N/ccr/comments/ID/resolve
# Other gh verbs that write (pr, issue, release, workflow, run, secret,
# variable, label, cache, repo) pass when they name no repository (the
# checkout's own) or one of the two above, and are blocked when -R/--repo, a
# github.com URL or "gh repo VERB NAME" names another one. Whether a risky verb
# on our own repos runs without a question is settings.json's "ask" list.
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
# JSON escapes for whitespace are what the shell sees: a tab or CR is a
# space, a newline ends a command
cmd="$(printf '%s' "$cmd" | sed -e 's/\\[tr]/ /g' -e 's/\\n/ ; /g')"
# Quotes and backslashes join word fragments in the shell (g''h is gh), so
# calls are found and checked with them dropped. Only the task name check
# below reads the quoted original.
flat="$(printf '%s' "$cmd" | tr -d "'\"\\\\")"

# Prints each chunk that starts with the pattern, up to the next match, one
# per line (newlines inside the command are JSON escaped, so none are real).
# Lowercased: Windows finds SCHTASKS and Schtasks.exe as well, so the
# patterns and every check below are lowercase or case-insensitive.
chunks() {
  printf '%s' "$flat" | awk -v pat="$1" '{
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

# The writes allowed anyway, each only as the whole command. Text comes from
# a file (-F field=@FILE), so no free text on the command line can chain
# another command, and FILE may not hold whitespace or ; & | < > $ `.
#   review thread resolve:  gh api -X POST repos/O/R/pulls/N/ccr/comments/ID/resolve
#   review thread reply:    gh api -X POST repos/askysh/benchbar/pulls/N/comments/ID/replies -F body=@FILE
#   GraphQL from a file:    gh api graphql -F query=@FILE, a read, or a mutation
#                           whose one operation is resolveReviewThread
allowed_write() {
  local resolve reply gql q
  resolve='^gh api (-X|--method) POST repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pulls/[0-9]+/ccr/comments/[A-Za-z0-9_-]+/resolve$'
  reply='^gh api (-X|--method) POST repos/askysh/benchbar/pulls/[0-9]+/comments/[0-9]+/replies -F body=@[^[:space:];&|<>$`'"'"'"]+( --silent)?$'
  gql='^gh api graphql -F query=@([^[:space:];&|<>$`'"'"'"]+)$'
  [[ $cmd =~ $resolve ]] && return 0
  [[ $cmd =~ $reply ]] && return 0
  [[ $cmd =~ $gql ]] || return 1
  [ -f "${BASH_REMATCH[1]}" ] || return 1
  q="$(tr '[:upper:]' '[:lower:]' <"${BASH_REMATCH[1]}")"
  case "$q" in *mutation*) ;; *) return 0 ;; esac
  # a mutation: one operation, resolveReviewThread (every GitHub mutation
  # takes input:, so a second operation or an alias adds a second input:)
  [ "$(printf '%s' "$q" | grep -o 'mutation' | wc -l | tr -d ' ')" = 1 ] || return 1
  [ "$(printf '%s' "$q" | grep -Eo 'input[[:space:]]*:' | wc -l | tr -d ' ')" = 1 ] || return 1
  printf '%s' "$q" | grep -Eq 'resolvereviewthread[[:space:]]*\([[:space:]]*input[[:space:]]*:'
}

# REST writes to the project's own repositories pass: askysh/benchbar and
# askysh/homebrew-tap (rulesets, environments, issues, releases). The call,
# up to the first ; & | or newline, must name exactly one endpoint, and it
# must be one of those two. GraphQL stays limited to allowed_write.
own_repo_write() {
  local n
  matches "$1" 'graphql' && return 1
  n="$(printf '%s' "$1" | grep -Eo '(^|[[:space:]=/])(repos|orgs|users|user|gists|enterprises|app|applications|installation|notifications|teams)/' | wc -l | tr -d ' ')"
  [ "$n" = 1 ] || return 1
  matches "$1" '(^|[[:space:]])/?repos/askysh/(benchbar|homebrew-tap)([/?[:space:]]|$)'
}

# gh verbs that write, other than gh api. A write that names a repository
# other than askysh/benchbar or askysh/homebrew-tap (-R, --repo, a github.com
# URL, or the name after "gh repo VERB") is blocked; one that names none
# works on the checkout's own repository.
gh_write_verbs='^gh([.]exe)?[[:space:]]+((pr|issue)[[:space:]]+(merge|close|reopen|comment|review|edit|create|ready|lock|unlock|update-branch|delete|transfer|pin|unpin|develop)|release[[:space:]]+(create|delete|edit|upload|delete-asset)|workflow[[:space:]]+(run|enable|disable)|run[[:space:]]+(rerun|cancel|delete)|(secret|variable)[[:space:]]+(set|delete|remove)|label[[:space:]]+(create|edit|delete|clone)|cache[[:space:]]+delete|repo[[:space:]]+(create|delete|edit|rename|archive|unarchive|fork|deploy-key|sync))([[:space:]]|$)'
# the word after "gh repo VERB", when it is not a flag
repo_operand() {
  printf '%s' "$1" | sed -E 's/^gh([.]exe)?[[:space:]]+repo[[:space:]]+[a-z-]+[[:space:]]*//; s/[[:space:]].*//; s/^-.*//; s#.*github[.]com/##; s/[.]git$//'
}
# Returns 0 when the call is a gh write to a repository that is not ours.
other_repo_write() {
  local call named r
  # chunks() keeps the character before "gh"
  call="$(printf '%s' "$1" | sed -E 's/^[^a-z]+//; s/(;|&|\|).*//')"
  matches "$call" "$gh_write_verbs" || return 1
  named="$(printf '%s' "$call" | grep -Eo '(^|[[:space:]])(-r[[:space:]=]*|--repo[[:space:]=]+)[^[:space:]]+|github[.]com/[^[:space:]/]+/[^[:space:]/]+' | sed -E 's/^[[:space:]]*(-r[[:space:]=]*|--repo[[:space:]=]+)//; s#.*github[.]com/##; s/[.]git$//')"
  if matches "$call" '^gh([.]exe)?[[:space:]]+repo[[:space:]]+(create|fork)([[:space:]]|$)'; then
    # these name the new repository, or the one to fork: none named is not ours
    named="$named"$'\n'"$(repo_operand "$call")"
    [ -n "$(printf '%s' "$named" | tr -d '[:space:]')" ] || return 0
  elif matches "$call" '^gh([.]exe)?[[:space:]]+repo[[:space:]]+(delete|edit|rename|archive|unarchive|deploy-key|sync)([[:space:]]|$)'; then
    named="$named"$'\n'"$(repo_operand "$call")"
  fi
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    matches "$r" '^askysh/(benchbar|homebrew-tap)$' || return 0
  done <<EOF2
$named
EOF2
  return 1
}

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
  # Body flags count only in this call itself: a -F after a pipe belongs
  # to awk or cut, not to gh.
  if matches "$own" '(^|[[:space:]])(-[A-Za-z]*[fF]|--field|--raw-field|--input)' && [ "$explicit_get" = 0 ]; then
    write=1
  fi
  matches "$call" 'graphql' && matches "$call" 'mutation' && write=1
  if [ "$write" = 1 ] && ! allowed_write && ! own_repo_write "$own"; then
    echo "Blocked: gh api writes are not allowed here, except: gh api -X POST repos/O/R/pulls/N/ccr/comments/ID/resolve; gh api -X POST repos/askysh/benchbar/pulls/N/comments/ID/replies -F body=@FILE; gh api graphql -F query=@FILE that only reads or resolves review threads." >&2
    exit 2
  fi
done <<EOF
$(chunks '(^|[^A-Za-z0-9_.-])gh([.]exe)?[[:space:]]+api([[:space:]]|$)')
EOF

while IFS= read -r call; do
  [ -n "$call" ] || continue
  if other_repo_write "$call"; then
    echo "Blocked: gh writes to a repository other than askysh/benchbar and askysh/homebrew-tap are not allowed here; run them yourself." >&2
    exit 2
  fi
done <<EOF
$(chunks '(^|[^A-Za-z0-9_.-])gh([.]exe)?[[:space:]]+(pr|issue|release|workflow|run|secret|variable|label|cache|repo)([[:space:]]|$)')
EOF

tasks="$(chunks '(^|[^A-Za-z0-9_.-])schtasks([.]exe)?([[:space:]]|$)')"
calls="$(printf '%s\n' "$tasks" | grep -c .)"
while IFS= read -r call; do
  [ -n "$call" ] || continue
  if matches "$call" '[[:space:]][-/]+(delete|change)([[:space:]]|$)'; then
    echo "Blocked: schtasks /Delete and /Change are not allowed here; run them yourself." >&2
    exit 2
  fi
  if matches "$call" '[[:space:]][-/]+create([[:space:]]|$)'; then
    # The name needs its quotes to end where it ends, so it is read from the
    # original command, which must then hold this one schtasks call only.
    names="$(printf '%s' "$call" | grep -Eio -- '[[:space:]][-/]+tn([[:space:]]|$)' | wc -l | tr -d ' ')"
    keepalive='schtasks(\.exe)?[[:space:]][^;&|]*[[:space:]][-/]+tn[[:space:]]+(\\"|'"'"')benchbar keepalive(\\"|'"'"')([[:space:]]|$)'
    original="$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')"
    if [ "$calls" != 1 ] || [ "$names" != 1 ] || ! [[ $original =~ $keepalive ]]; then
      echo "Blocked: schtasks /Create is only allowed for the task named \"BenchBar Keepalive\"." >&2
      exit 2
    fi
  fi
done <<EOF
$tasks
EOF
exit 0
