#!/bin/bash
#
# release-ci-gate.sh: has CI passed for the commit a release is built from?
#
#   scripts/release-ci-gate.sh [SHA]       default: HEAD
#
# The release job does not run the CLI tests again: the push run of CI on
# next-release (and on main) already ran the whole suite on this tree, and
# "CI result" is its one verdict. This asks GitHub for the check runs of SHA
# and passes when "CI result" concluded success. A release is the merge commit
# of next-release into main, and CI may still be running on that new commit
# when the tag is made, so a parent with the same tree (git rev-parse
# COMMIT^{tree}) counts: it is the commit CI ran, byte for byte.
#
# Needs gh with GH_TOKEN (checks: read) and GITHUB_REPOSITORY. GH_GATE_REPO
# and the PATH let the tests name a repository and a fake gh.
# Exit: 0 green, 1 red, missing or still running (the reason on stderr).

set -euo pipefail

SHA="$(git rev-parse "${1:-HEAD}^{commit}")"
REPO="${GH_GATE_REPO:-${GITHUB_REPOSITORY:-}}"
[[ -n "$REPO" ]] || { printf '[FAIL] no repository: set GITHUB_REPOSITORY\n' >&2; exit 1; }
CHECK_NAME="${CI_CHECK_NAME:-CI result}"

# verdict COMMIT: success | <other conclusion> | running | none
verdict() {
  local out
  out="$(gh api --paginate "repos/${REPO}/commits/$1/check-runs?per_page=100" \
    --jq ".check_runs[] | select(.name == \"${CHECK_NAME}\") | (.status + \" \" + (.conclusion // \"\"))" 2>/dev/null || true)"
  # the last run of the name wins (a re-run comes after the first)
  out="$(printf '%s\n' "$out" | tail -n 1)"
  case "$out" in
    "") echo none ;;
    "completed success") echo success ;;
    completed\ *) echo "${out#completed }" ;;
    *) echo running ;;
  esac
}

tree="$(git rev-parse "${SHA}^{tree}")"
candidates="$SHA"
for p in $(git rev-list --parents -n 1 "$SHA" | cut -d' ' -f2-); do
  [[ "$(git rev-parse "${p}^{tree}")" == "$tree" ]] && candidates="$candidates $p"
done

seen=""
for c in $candidates; do
  v="$(verdict "$c")"
  seen="${seen}${seen:+, }${c:0:9}: ${v}"
  case "$v" in
    success) printf '[OK] CI result passed on %s%s\n' "${c:0:9}" "$([[ "$c" == "$SHA" ]] || printf ' (same tree as %s)' "${SHA:0:9}")"; exit 0 ;;
    none|running) ;;
    *) printf '[FAIL] CI result is %s on %s. A release is not built from a commit CI did not pass.\n' "$v" "${c:0:9}" >&2; exit 1 ;;
  esac
done
printf '[FAIL] no passed "%s" for %s (%s). Wait for CI on the commit, or re-run it, then run this again.\n' "$CHECK_NAME" "${SHA:0:9}" "$seen" >&2
exit 1
