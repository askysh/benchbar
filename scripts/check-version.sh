#!/bin/bash
#
# check-version.sh: what a BenchBar version is, and whether every place that
# carries it says the same.
#
#   scripts/check-version.sh --valid VERSION   VERSION has the right form, nothing else
#   scripts/check-version.sh --kind VERSION    print "final" (X.Y.Z) or "rc" (X.Y.Z-rc.N)
#   scripts/check-version.sh [VERSION]         every place agrees with VERSION
#                                              (default: FL_VERSION of benchbar)
#   scripts/check-version.sh --folded [VERSION]
#                                              the same, and no changelog fragment is left
#
# The form is X.Y.Z for a release and X.Y.Z-rc.N for a release candidate (a
# pre-release that updaters do not offer: docs/releasing.md). Numbers have no
# leading zero. The same pattern is written in release.yml, homebrew-tap.yml
# and release-windows.yml; tests/test-version-sources.sh keeps the copies equal.
#
# The places: FL_VERSION in benchbar, MARKETING_VERSION in macos/project.yml
# and the placeholder of the two bug report forms. For a release also a
# "## X.Y.Z" heading in CHANGELOG.md and a mention of X.Y.Z in the release
# paragraph of README.md and of ROADMAP.md (a release candidate needs none of
# these). scripts/bump-version.sh sets them. auto-tag.yml, release.yml and
# tests/test-version-sources.sh all call this one script, so they never
# disagree about what a good version is.
#
# VERSION_ROOT is the folder to check (the tests use it).
# Exit: 0 all agree, 1 something differs (one line each, on stderr), 2 usage.

set -euo pipefail

ROOT="${VERSION_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc\.[1-9][0-9]*)?$'

valid() { [[ "$1" =~ $VERSION_RE ]]; }

usage() { sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; }

folded=0
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --valid)
      valid "${2:-}" || { printf "'%s' is not a version (expected X.Y.Z or X.Y.Z-rc.N)\n" "${2:-}" >&2; exit 1; }
      exit 0 ;;
    --kind)
      valid "${2:-}" || { printf "'%s' is not a version (expected X.Y.Z or X.Y.Z-rc.N)\n" "${2:-}" >&2; exit 1; }
      case "$2" in *-rc.*) echo rc ;; *) echo final ;; esac
      exit 0 ;;
    --folded) folded=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'check-version: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done

cli="$(sed -n 's/^FL_VERSION="\([^"]*\)"$/\1/p' "$ROOT/benchbar" | head -n 1)"
app="$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "$ROOT/macos/project.yml" | head -n 1)"
version="${1:-$cli}"

errors=0
bad() { printf '[FAIL] %s\n' "$1" >&2; errors=$((errors + 1)); }

valid "$version" || { printf "[FAIL] '%s' is not a version (expected X.Y.Z or X.Y.Z-rc.N)\n" "$version" >&2; exit 1; }
[[ "$cli" == "$version" ]] || bad "FL_VERSION in benchbar is '${cli}', not ${version}"
[[ "$app" == "$version" ]] || bad "MARKETING_VERSION in macos/project.yml is '${app}', not ${version}"

# a version number as a whole word: 0.9.0 is not in 10.9.0 or 0.9.01
mentions() { grep -Eq "(^|[^0-9.])${version//./\\.}([^0-9]|\$)" "$1" 2>/dev/null; }

for f in .github/ISSUE_TEMPLATE/bug_report.yml .github/ISSUE_TEMPLATE/bug_report_windows.yml; do
  line="$(grep -m 1 'placeholder: benchbar' "$ROOT/$f" 2>/dev/null || true)"
  case "$line" in
    *"$version"*) ;;
    *) bad "$f: the version placeholder does not say ${version} (scripts/bump-version.sh sets it)" ;;
  esac
done

if [[ "$version" != *-rc.* ]]; then
  grep -q "^## ${version}\( \|\$\)" "$ROOT/CHANGELOG.md" \
    || bad "CHANGELOG.md has no '## ${version}' heading (scripts/bump-version.sh writes it)"
  for f in README.md ROADMAP.md; do
    mentions "$ROOT/$f" || bad "$f does not mention ${version}: add it to the release paragraph"
  done
fi

if [[ "$folded" == 1 ]]; then
  left=""
  for f in "$ROOT"/changelog.d/*.md; do
    [[ -f "$f" && "${f##*/}" != README.md ]] && left="$left ${f##*/}"
  done
  [[ -z "$left" ]] || bad "changelog fragments are left:${left}. Run scripts/changelog-fold.sh"
fi

[[ "$errors" == 0 ]] || exit 1
printf '[OK] version %s: benchbar, macos/project.yml, the bug report forms%s agree\n' "$version" \
  "$([[ "$version" == *-rc.* ]] || printf ', CHANGELOG.md, README.md and ROADMAP.md')"
