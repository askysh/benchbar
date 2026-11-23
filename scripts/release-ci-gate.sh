#!/bin/bash
#
# release-ci-gate.sh: has CI passed for the commit a release is built from?
#
#   scripts/release-ci-gate.sh [SHA]       default: HEAD
#
# The release job does not run the CLI tests again: the push run of CI on
# next-release already ran the whole suite on this tree, and "CI result" is
# its one verdict. This asks GitHub for the check runs of SHA and passes when
# "CI result" concluded success. A release is a fast forward of main to a
# next-release commit, so SHA is the very commit CI ran there; the push to main
# starts a second run of CI on it, which may still be going when the tag is
# made, so a finished run decides and a run in progress does not undo it.
#
# "CI result" is also green on a push that changed only docs, site or *.md
# (scripts/docs-only.sh, the rule of scripts/ci-plan.sh): CI skips every test
# job then and a skipped job passes. So a green result on SHA alone proves
# nothing when SHA is such a commit. The gate walks back the first parent line
# over the commits that changed only docs, and also needs a green "CI result"
# on the nearest commit that changed code: the one whose push ran the tests.
#
# The real installs on macOS (real-install.yml: a real `benchbar install` and
# the upgrade from the last release, on a hosted Mac) are not part of "CI
# result": the repository gets five macOS jobs at a time, so no push starts
# them. A release needs them all the same, so the gate also needs a passed
# "Real install result (macOS)" on SHA, or on one of the docs only commits
# under it down to the nearest commit that changed code (the code they ran is
# the code of SHA). Start it by hand on the branch whose head is the commit:
#   gh workflow run real-install.yml --ref next-release
#
# Needs gh with GH_TOKEN (checks: read) and GITHUB_REPOSITORY. GH_GATE_REPO
# and the PATH let the tests name a repository and a fake gh.
# Exit: 0 green, 1 red, missing or still running (the reason on stderr).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHA="$(git rev-parse "${1:-HEAD}^{commit}")"
REPO="${GH_GATE_REPO:-${GITHUB_REPOSITORY:-}}"
[[ -n "$REPO" ]] || { printf '[FAIL] no repository: set GITHUB_REPOSITORY\n' >&2; exit 1; }
CHECK_NAME="${CI_CHECK_NAME:-CI result}"
REAL_NAME="Real install result (macOS)"

# verdict COMMIT [NAME]: success | <other conclusion> | running | none
# The last finished run of the name decides (a re-run comes after the first);
# a run in progress counts only when no run of it has finished.
verdict() {
  local out fin name="${2:-$CHECK_NAME}"
  out="$(gh api --paginate "repos/${REPO}/commits/$1/check-runs?per_page=100" \
    --jq ".check_runs[] | select(.name == \"${name}\") | (.status + \" \" + (.conclusion // \"\"))" 2>/dev/null || true)"
  fin="$(printf '%s\n' "$out" | grep '^completed ' | tail -n 1 || true)"
  if [[ -n "$fin" ]]; then
    if [[ "$fin" == "completed success" ]]; then echo success; else echo "${fin#completed }"; fi
  elif [[ -n "${out//[$'\n ']/}" ]]; then
    echo running
  else
    echo none
  fi
}

# need COMMIT LABEL: exit 1 unless "CI result" passed on COMMIT
need() {
  local c="$1" label="$2" v
  v="$(verdict "$c")"
  case "$v" in
    success) printf '[OK] CI result passed on %s%s\n' "${c:0:9}" "$label" ;;
    none|running)
      printf '[FAIL] no passed "%s" on %s%s (%s). Wait for CI on the commit, or re-run it, then run this again.\n' "$CHECK_NAME" "${c:0:9}" "$label" "$v" >&2
      exit 1 ;;
    *) printf '[FAIL] CI result is %s on %s%s. A release is not built from a commit CI did not pass.\n' "$v" "${c:0:9}" "$label" >&2; exit 1 ;;
  esac
}

need "$SHA" ""

# the nearest commit that is not docs only, along the first parent line
c="$SHA"
walked=("$SHA")
while true; do
  rc=0
  bash "$HERE/docs-only.sh" --commit "$c" >/dev/null || rc=$?
  [[ "$rc" != 2 ]] || { printf '[FAIL] cannot read the changes of %s\n' "${c:0:9}" >&2; exit 1; }
  [[ "$rc" == 1 ]] && break
  c="$(git rev-parse -q --verify "${c}^1" 2>/dev/null)" || {
    printf '[FAIL] every commit up to the first one changes only docs: no commit ran the tests\n' >&2; exit 1; }
  walked+=("$c")
done
[[ "$c" == "$SHA" ]] || need "$c" " (the nearest commit that ran the tests; ${SHA:0:9} and the commits after it change only docs)"

# the real installs on macOS: the newest of those commits that has a finished
# run decides
seen=""
for x in "${walked[@]}"; do
  v="$(verdict "$x" "$REAL_NAME")"
  case "$v" in
    success) printf '[OK] %s passed on %s\n' "$REAL_NAME" "${x:0:9}"; exit 0 ;;
    none) ;;
    running) seen="running on ${x:0:9}" ;;
    *) printf '[FAIL] %s is %s on %s. A release is not built from a commit whose real install on macOS failed.\n' "$REAL_NAME" "$v" "${x:0:9}" >&2; exit 1 ;;
  esac
done
printf '[FAIL] no passed "%s" on %s (%s). Start it on the branch whose head is this commit and wait for it: gh workflow run real-install.yml --ref next-release\n' \
  "$REAL_NAME" "${SHA:0:9}" "${seen:-none}" >&2
exit 1
