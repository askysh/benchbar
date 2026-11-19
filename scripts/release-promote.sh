#!/bin/bash
#
# release-promote.sh: cut a release by fast forwarding main to next-release.
#
#   scripts/release-promote.sh [--dry-run] [--yes]
#
# A release moves main to the head of next-release and adds no commit: main
# then holds the very commits that were reviewed and that CI ran, and
# auto-tag.yml tags it (docs/releasing.md). Run it from a checkout, as a
# repository admin: the push needs the bypass of the main ruleset.
#
# It checks, in this order, and stops at the first that fails:
#   1. main is an ancestor of next-release. If main has a commit that
#      next-release has not, it refuses and says so. It never merges and
#      never forces: how to put main right is a person's decision;
#   2. next-release has something main has not;
#   3. the version in benchbar at that commit is a final one (X.Y.Z, not a
#      release candidate) and every place agrees, with no changelog fragment
#      left (scripts/check-version.sh --folded, run on the files of that
#      commit, not of your working tree);
#   4. the tag vX.Y.Z does not exist yet (otherwise auto-tag.yml would build
#      nothing: a release without a new version);
#   5. "CI result" is green for that commit, and for the nearest commit that
#      changed code (scripts/release-ci-gate.sh; needs gh signed in).
# Then it shows the plan, and pushes only after you answer yes (--yes skips
# the question; --dry-run stops after the plan):
#   git push origin <sha>:refs/heads/main
#
# The names can be changed for a test: RELEASE_REMOTE (origin),
# GH_GATE_REPO (OWNER/REPO; default: read from the remote's URL).
# Exit: 0 pushed (or a dry run that passes), 1 refused or cancelled.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE="${RELEASE_REMOTE:-origin}"
DRY=0 YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --yes) YES=1 ;;
    -h|--help) sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'release-promote: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

refuse() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

git rev-parse --git-dir >/dev/null 2>&1 || refuse "run this inside a checkout of the repository"
command -v gh >/dev/null 2>&1 || refuse "gh is not installed: the CI check of the commit needs it (brew install gh, gh auth login)"

if [[ -z "${GH_GATE_REPO:-}" ]]; then
  url="$(git remote get-url "$REMOTE" 2>/dev/null)" || refuse "no remote named ${REMOTE}"
  GH_GATE_REPO="$(printf '%s\n' "$url" | sed -n 's#^.*github\.com[:/]\(.*[^/]\)/*$#\1#p' | sed 's#\.git$##')"
  [[ -n "$GH_GATE_REPO" ]] || refuse "cannot read OWNER/REPO from the URL of ${REMOTE} (${url}); set GH_GATE_REPO"
fi
export GH_GATE_REPO

git fetch --quiet "$REMOTE" "+refs/heads/main:refs/remotes/${REMOTE}/main" "+refs/heads/next-release:refs/remotes/${REMOTE}/next-release" \
  || refuse "could not fetch main and next-release from ${REMOTE}"
OLD="$(git rev-parse "refs/remotes/${REMOTE}/main^{commit}")"
SHA="$(git rev-parse "refs/remotes/${REMOTE}/next-release^{commit}")"

# 1. main must be an ancestor: a fast forward, never a merge
if ! git merge-base --is-ancestor "$OLD" "$SHA"; then
  ahead="$(git log --oneline -n 5 "${SHA}..${OLD}")"
  refuse "main (${OLD:0:9}) has commits that next-release (${SHA:0:9}) has not, so main cannot be fast forwarded and this script will not merge or force it. Commits only main has:
${ahead}
Bring their change to next-release by pull request and ask the maintainer how to put main right (docs/releasing.md)."
fi

# 2. something to release
[[ "$OLD" != "$SHA" ]] || refuse "main and next-release are the same commit (${SHA:0:9}): nothing to release"

# 3. the version, read from the files of that commit
tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-promote.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
git archive "$SHA" | tar -x -C "$tmp"
VERSION="$(sed -n 's/^FL_VERSION="\([^"]*\)"$/\1/p' "$tmp/benchbar" | head -n 1)"
[[ -n "$VERSION" ]] || refuse "no FL_VERSION in benchbar at ${SHA:0:9}"
"$HERE/check-version.sh" --valid "$VERSION" || exit 1
[[ "$("$HERE/check-version.sh" --kind "$VERSION")" == final ]] \
  || refuse "benchbar at ${SHA:0:9} says ${VERSION}, a release candidate. A candidate is tagged by hand on next-release and never goes to main: run scripts/bump-version.sh X.Y.Z first."
if ! out="$(VERSION_ROOT="$tmp" "$HERE/check-version.sh" --folded "$VERSION" 2>&1)"; then
  printf '%s\n' "$out" >&2
  refuse "the places that carry the version disagree at ${SHA:0:9} (above)"
fi

# 4. a new version
if git ls-remote --exit-code --tags "$REMOTE" "refs/tags/v${VERSION}" >/dev/null 2>&1; then
  refuse "v${VERSION} is tagged already: this release has no new version, and auto-tag.yml would build nothing. Run scripts/bump-version.sh on next-release first."
fi

# 5. CI
gate_out="$("$HERE/release-ci-gate.sh" "$SHA" 2>&1)" || { printf '%s\n' "$gate_out" >&2; exit 1; }

n="$(git rev-list --count "${OLD}..${SHA}")"
printf 'Release plan\n'
printf '  version  %s (a final release)\n' "$VERSION"
printf '  main     %s to %s, %s commit(s), a fast forward\n' "${OLD:0:9}" "${SHA:0:9}" "$n"
printf '%s\n' "$gate_out" | sed 's/^/  CI       /'
git log --oneline -n 20 "${OLD}..${SHA}" | sed 's/^/    /'
[[ "$n" -le 20 ]] || printf '    ... and %s more\n' "$((n - 20))"
printf '  push     git push %s %s:refs/heads/main   (no force; needs the main ruleset bypass)\n' "$REMOTE" "${SHA:0:9}"
printf '  then     auto-tag.yml tags v%s and starts the release builds\n' "$VERSION"

if [[ "$DRY" == 1 ]]; then
  printf 'Dry run: nothing was pushed.\n'
  exit 0
fi
if [[ "$YES" != 1 ]]; then
  printf 'Fast forward main to %s now? [y/N] ' "${SHA:0:9}"
  ans=""
  read -r ans || true
  case "$ans" in y|Y|yes|YES) ;; *) printf '\nCancelled. Nothing was pushed.\n'; exit 1 ;; esac
fi

git push "$REMOTE" "${SHA}:refs/heads/main" \
  || refuse "the push was refused. Either main moved since this run (run it again) or you cannot bypass the main ruleset (a repository admin must run this). Nothing was forced."
printf '[OK] main is at %s. auto-tag.yml tags v%s next; watch the Auto tag run on main.\n' "${SHA:0:9}" "$VERSION"
