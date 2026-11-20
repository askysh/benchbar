#!/usr/bin/env bash
#
# check-apps-branches.sh: every repo and branch that config/apps.tsv names
# must exist upstream, for both profile columns.
#
#   scripts/check-apps-branches.sh [FILE]   FILE defaults to config/apps.tsv
#
# A row with no repo is an official app that bench resolves by name: its repo
# is github.com/frappe/APP and ${frappe_branch} / ${erpnext_branch} come from
# config/release-profiles.tsv. Read only (git ls-remote); exits 1 and names
# each miss. Run weekly by .github/workflows/apps-branches.yml.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="${1:-${ROOT}/config/apps.tsv}"
PROFILES="${ROOT}/config/release-profiles.tsv"
fail=0

# profile_branch PROFILE COLUMN: the frappe (3) or erpnext (4) branch of a profile
profile_branch() { awk -F '\t' -v p="$1" -v c="$2" '$1 == p {print $c}' "$PROFILES"; }

# fields are joined with spaces ("-" for an empty repo): read would drop an empty tab field
while read -r app repo v15 v16; do
  [[ -n "$app" ]] || continue
  [[ "$repo" != "-" ]] || repo="https://github.com/frappe/${app}"
  for col in v15-lts v16-lts; do
    if [[ "$col" == "v15-lts" ]]; then branch="$v15"; else branch="$v16"; fi
    # shellcheck disable=SC2016  # the literal placeholders of apps.tsv
    case "$branch" in
      '${frappe_branch}') branch="$(profile_branch "$col" 3)" ;;
      '${erpnext_branch}') branch="$(profile_branch "$col" 4)" ;;
    esac
    out="$(GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code --heads --tags -- "$repo" "refs/heads/${branch}" "refs/tags/${branch}" 2>&1)" && continue || code=$?
    if [[ "$code" == "2" ]]; then
      printf '%s: branch %s (%s) not found in %s\n' "$app" "$branch" "$col" "$repo" >&2
    else
      printf '%s: cannot read %s (%s): %s\n' "$app" "$repo" "$col" "$(printf '%s' "$out" | awk 'NR==1')" >&2
    fi
    fail=1
  done
done < <(awk -F '\t' 'NR > 1 && $1 != "" {print $1, ($2 == "" ? "-" : $2), $3, $4}' "$FILE")

[[ "$fail" == "0" ]] && printf 'every repo and branch of %s exists\n' "$(basename "$FILE")"
exit "$fail"
