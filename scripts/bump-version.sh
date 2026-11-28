#!/bin/bash
#
# bump-version.sh: set the version in every place that carries it.
#
#   scripts/bump-version.sh 0.9.0          a release
#   scripts/bump-version.sh 0.9.0-rc.1     a release candidate
#   scripts/bump-version.sh 0.9.0 --no-fixtures
#
# It sets FL_VERSION in benchbar, MARKETING_VERSION in macos/project.yml and
# the version placeholder of the two bug report forms. For a release it also
# folds the changelog fragments (scripts/changelog-fold.sh) and turns
# "## Unreleased" into "## X.Y.Z - DATE" with a new empty "## Unreleased"
# above it. Then it records the tray's CLI fixtures again (they hold
# cli_version), unless --no-fixtures. It ends with scripts/check-version.sh
# and names what only a person can write: the release paragraph of README.md
# and ROADMAP.md, which that check requires for a release.
#
# VERSION_ROOT is the folder to change (the tests use it); BUMP_DATE the date.
# Exit: 0 done, 1 refused or a check failed, 2 usage.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${VERSION_ROOT:-$(cd "$HERE/.." && pwd)}"

version="" fixtures=1
for arg in "$@"; do
  case "$arg" in
    --no-fixtures) fixtures=0 ;;
    -h|--help) sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) printf 'bump-version: unknown option %s\n' "$arg" >&2; exit 2 ;;
    *) [[ -z "$version" ]] || { printf 'bump-version: one version only\n' >&2; exit 2; }; version="$arg" ;;
  esac
done
[[ -n "$version" ]] || { printf 'Usage: scripts/bump-version.sh X.Y.Z[-rc.N] [--no-fixtures]\n' >&2; exit 2; }
"$HERE/check-version.sh" --valid "$version" || exit 1
kind="$("$HERE/check-version.sh" --kind "$version")"

# replace FILE: stdin is the new content, written only when it is not empty
replace() { local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/bump.XXXXXX")"; cat >"$tmp"; [[ -s "$tmp" ]] && cat "$tmp" >"$1"; rm -f "$tmp"; }

sed -E "s/^FL_VERSION=\"[^\"]*\"\$/FL_VERSION=\"${version}\"/" "$ROOT/benchbar" | replace "$ROOT/benchbar"
sed -E "s/^( *MARKETING_VERSION: *)\"?[^\" ]*\"?( *)\$/\\1\"${version}\"\\2/" "$ROOT/macos/project.yml" | replace "$ROOT/macos/project.yml"
for f in bug_report.yml bug_report_windows.yml; do
  sed -E "/placeholder: benchbar/ s/[0-9]+\\.[0-9]+\\.[0-9]+(-rc\\.[0-9]+)?/${version}/g" "$ROOT/.github/ISSUE_TEMPLATE/$f" | replace "$ROOT/.github/ISSUE_TEMPLATE/$f"
done

if [[ "$kind" == final ]]; then
  CHANGELOG="$ROOT/CHANGELOG.md" CHANGELOG_DIR="$ROOT/changelog.d" "$HERE/changelog-fold.sh"
  if ! grep -q "^## ${version}\( \|\$\)" "$ROOT/CHANGELOG.md"; then
    awk -v h="## ${version} - ${BUMP_DATE:-$(date +%Y-%m-%d)}" \
      '/^## Unreleased[ \t]*$/ && !done { print; print ""; print h; done = 1; next } { print }' \
      "$ROOT/CHANGELOG.md" | replace "$ROOT/CHANGELOG.md"
  fi
fi

if [[ "$fixtures" == 1 && -z "${VERSION_ROOT:-}" ]]; then
  bash "$ROOT/tests/record-tray-fixtures.sh"
fi

printf 'Version set to %s (%s).\n' "$version" "$kind"
if [[ "$kind" == final ]]; then
  printf 'Still yours to write: the %s paragraph in README.md and in ROADMAP.md, then the screenshots (maintainers/releasing.md).\n' "$version"
fi
VERSION_ROOT="$ROOT" "$HERE/check-version.sh" "$version" || [[ "$kind" == final ]]
