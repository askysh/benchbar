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
#   1. main is an ancestor of next-release. A docs only pull request may
#      target main (so the site shows it at once), which leaves main with a
#      commit that next-release has not. When every such commit changes only
#      docs (scripts/docs-only.sh), the script offers a sync: ONE real merge
#      commit of origin/main into origin/next-release (first parent
#      next-release, built with git merge-tree, so the working tree and the
#      branches are not touched; a conflict stops it with nothing pushed),
#      shown and pushed after a yes (--yes) with
#        git push origin <merge>:refs/heads/next-release
#      a fast forward of next-release, which the admin may push past the
#      ruleset. When any of them changes more than docs, it refuses and names
#      it. It never forces, never rewrites history, and never merges the
#      other way;
#   2. next-release has something main has not;
#   3. the version in benchbar at that commit (the merge, after a sync) is a
#      final one (X.Y.Z, not a release candidate) and every place agrees, with
#      no changelog fragment left (scripts/check-version.sh --folded, run on
#      the files of that commit, not of your working tree);
#   4. the tag vX.Y.Z does not exist yet (otherwise auto-tag.yml would build
#      nothing: a release without a new version);
#   5. "CI result" is green for that commit, and for the nearest commit that
#      changed code (scripts/release-ci-gate.sh; needs gh signed in). The
#      merge of a sync changes only docs, so CI ran no tests on it: the gate
#      walks back to the code commit, as for any docs only head. It also
#      needs a finished "CI result" on the merge, which does not exist the
#      moment it is pushed: the run then stops, tells you to wait for CI on
#      next-release and run it again, and the second run is a plain fast
#      forward. Before the sync, the gate is checked on the current head.
# Then it shows the plan, and pushes only after you answer yes (--yes skips
# the questions; --dry-run stops after the plan and pushes nothing):
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

# 1. main must be an ancestor: a fast forward, never a force. When main has only
#    docs commits that next-release lacks, a sync merge brings them in first.
TARGET="$SHA" SYNC=0 MERGE="" extra_n=0
if ! git merge-base --is-ancestor "$OLD" "$SHA"; then
  extra="$(git rev-list --reverse "${SHA}..${OLD}")"
  extra_n="$(printf '%s\n' "$extra" | grep -c .)"
  code_commits=""
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    files="$("$HERE/docs-only.sh" --commit "$c")" && continue
    code_commits+="$(git log -1 --oneline "$c")"$'\n'"$(printf '%s\n' "$files" | head -n 3 | sed 's/^/      changes /')"$'\n'
  done <<<"$extra"
  if [[ -n "$code_commits" ]]; then
    refuse "main (${OLD:0:9}) has commits that next-release (${SHA:0:9}) has not, and not only docs, so main cannot be fast forwarded and this script will not merge or force it. Commits only main has that change more than docs:
${code_commits%$'\n'}
Bring their change to next-release by pull request and ask the maintainer how to put main right (docs/releasing.md)."
  fi
  # only docs: one merge commit of main into next-release, built without a checkout
  merge_tree="$(git merge-tree --write-tree --no-messages "$SHA" "$OLD" 2>&1)" || {
    refuse "main has ${extra_n} docs commit(s) that next-release has not, but merging them conflicts, so nothing was merged or pushed. Bring the docs change to next-release by pull request (docs/releasing.md). ${merge_tree:+Detail: $(printf '%s' "$merge_tree" | head -n 1)}"
  }
  tree="$(printf '%s\n' "$merge_tree" | head -n 1)"
  MERGE="$(git commit-tree "$tree" -p "$SHA" -p "$OLD" \
    -m "Merge main into next-release (docs fixes)" \
    -m "$(git log --oneline "${SHA}..${OLD}")")" \
    || refuse "could not create the merge commit (is git user.name and user.email set?)"
  "$HERE/docs-only.sh" "$SHA" "$MERGE" >/dev/null \
    || refuse "the merge of main into next-release would change more than docs (${MERGE:0:9}); nothing was pushed"
  SYNC=1 TARGET="$MERGE"
fi

# 2. something to release
[[ "$OLD" != "$TARGET" ]] || refuse "main and next-release are the same commit (${TARGET:0:9}): nothing to release"

# 3. the version, read from the files of that commit
tmp="$(mktemp -d "${TMPDIR:-/tmp}/release-promote.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
git archive "$TARGET" | tar -x -C "$tmp"
VERSION="$(sed -n 's/^FL_VERSION="\([^"]*\)"$/\1/p' "$tmp/benchbar" | head -n 1)"
[[ -n "$VERSION" ]] || refuse "no FL_VERSION in benchbar at ${TARGET:0:9}"
"$HERE/check-version.sh" --valid "$VERSION" || exit 1
[[ "$("$HERE/check-version.sh" --kind "$VERSION")" == final ]] \
  || refuse "benchbar at ${TARGET:0:9} says ${VERSION}, a release candidate. A candidate is tagged by hand on next-release and never goes to main: run scripts/bump-version.sh X.Y.Z first."
if ! out="$(VERSION_ROOT="$tmp" "$HERE/check-version.sh" --folded "$VERSION" 2>&1)"; then
  printf '%s\n' "$out" >&2
  refuse "the places that carry the version disagree at ${TARGET:0:9} (above)"
fi

# 4. a new version
if git ls-remote --exit-code --tags "$REMOTE" "refs/tags/v${VERSION}" >/dev/null 2>&1; then
  refuse "v${VERSION} is tagged already: this release has no new version, and auto-tag.yml would build nothing. Run scripts/bump-version.sh on next-release first."
fi

# 5. CI. After a sync the merge has no result yet, so the commit it merges into
#    (next-release now) is checked here and the merge after it is pushed.
gate_out="$("$HERE/release-ci-gate.sh" "$SHA" 2>&1)" || { printf '%s\n' "$gate_out" >&2; exit 1; }

n="$(git rev-list --count "${OLD}..${TARGET}")"
printf 'Release plan\n'
printf '  version  %s (a final release)\n' "$VERSION"
if [[ "$SYNC" == 1 ]]; then
  printf '  sync     main has %s docs commit(s) next-release has not; one merge commit %s (parents %s next-release, %s main)\n' "$extra_n" "${MERGE:0:9}" "${SHA:0:9}" "${OLD:0:9}"
  git log --oneline "${SHA}..${OLD}" | sed 's/^/    /'
  printf '  push     git push %s %s:refs/heads/next-release   (a fast forward of next-release; needs its ruleset bypass)\n' "$REMOTE" "${MERGE:0:9}"
  printf '  wait     then CI runs on the merge; run this again when "CI result" is green on it\n'
fi
printf '  main     %s to %s, %s commit(s), a fast forward\n' "${OLD:0:9}" "${TARGET:0:9}" "$n"
printf '%s\n' "$gate_out" | sed 's/^/  CI       /'
git log --oneline -n 20 "${OLD}..${TARGET}" | sed 's/^/    /'
[[ "$n" -le 20 ]] || printf '    ... and %s more\n' "$((n - 20))"
printf '  push     git push %s %s:refs/heads/main   (no force; needs the main ruleset bypass)\n' "$REMOTE" "${TARGET:0:9}"
printf '  then     auto-tag.yml tags v%s and starts the release builds\n' "$VERSION"

if [[ "$DRY" == 1 ]]; then
  printf 'Dry run: nothing was pushed.\n'
  exit 0
fi
confirm() {
  [[ "$YES" == 1 ]] && return 0
  printf '%s [y/N] ' "$1"
  local ans=""
  read -r ans || true
  case "$ans" in y|Y|yes|YES) return 0 ;; esac
  printf '\nCancelled. Nothing more was pushed.\n'
  return 1
}

if [[ "$SYNC" == 1 ]]; then
  confirm "Merge main into next-release (push ${MERGE:0:9} to next-release) now?" || exit 1
  git push "$REMOTE" "${MERGE}:refs/heads/next-release" \
    || refuse "the push to next-release was refused. Either next-release moved since this run (run it again) or you cannot bypass its ruleset (a repository admin must run this). Nothing was forced."
  printf '[OK] next-release is at %s (it has main now).\n' "${MERGE:0:9}"
  # the merge is a new commit: its own result must be green before it is released
  if ! gate_out="$("$HERE/release-ci-gate.sh" "$MERGE" 2>&1)"; then
    printf '%s\n' "$gate_out" >&2
    printf '[FAIL] Wait for "CI result" on next-release (%s), then run this again: main is behind next-release now, so it is a plain fast forward. Nothing was pushed to main.\n' "${MERGE:0:9}" >&2
    exit 1
  fi
  printf '%s\n' "$gate_out" | sed 's/^/  CI       /'
fi

confirm "Fast forward main to ${TARGET:0:9} now?" || exit 1
git push "$REMOTE" "${TARGET}:refs/heads/main" \
  || refuse "the push was refused. Either main moved since this run (run it again) or you cannot bypass the main ruleset (a repository admin must run this). Nothing was forced."
printf '[OK] main is at %s. auto-tag.yml tags v%s next; watch the Auto tag run on main.\n' "${TARGET:0:9}" "$VERSION"
