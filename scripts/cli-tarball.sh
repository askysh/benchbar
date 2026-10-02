#!/usr/bin/env bash
#
# cli-tarball.sh: the CLI's source tarball, the file the Homebrew formula
# installs: benchbar-cli-<version>.tar.gz, made with git archive.
#
#   scripts/cli-tarball.sh 0.7.0              into dist/, from HEAD
#   scripts/cli-tarball.sh 0.7.0 DIR          into DIR
#   scripts/cli-tarball.sh 0.7.0 DIR REF      from another commit (CI)
#
# It holds only what the CLI runs: benchbar, frappe-mac, the phase scripts,
# lib/, templates/, config/, LICENSE and README.md, under
# benchbar-<version>/. Committed files only, so a build folder or an
# untracked file never ships. git archive gives every file the commit's
# time and gzip -n leaves the name and time out, so one commit always
# makes the same bytes and the same sha256.
#
# It refuses a version that differs from FL_VERSION in the benchbar of
# that commit: brew test checks `benchbar --version` against the formula.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { printf '[FAIL] %s\n' "$1" >&2; [[ -n "${2:-}" ]] && printf '  fix: %s\n' "$2" >&2; exit 1; }

case "${1:-}" in
  -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
  "") sed -n '2,19p' "$0" >&2; exit 1 ;;
esac
VERSION="$1"
OUT="${2:-${ROOT}/dist}"
REF="${3:-HEAD}"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version '${VERSION}' is not X.Y.Z"
cli_version="$(git -C "$ROOT" show "${REF}:benchbar" | sed -n 's/^FL_VERSION="\([^"]*\)"$/\1/p' | head -n 1)"
[[ "$cli_version" == "$VERSION" ]] || die "benchbar at ${REF} says FL_VERSION=\"${cli_version}\", not ${VERSION}" \
  "set FL_VERSION=\"${VERSION}\" in benchbar, the same as MARKETING_VERSION in macos/project.yml"

mkdir -p "$OUT"
TARBALL="${OUT}/benchbar-cli-${VERSION}.tar.gz"
git -C "$ROOT" archive --format=tar --prefix="benchbar-${VERSION}/" "$REF" -- \
  benchbar frappe-mac 00-mac-system-deps.sh 01-install-bench-and-site.sh 02-background-service.sh \
  lib templates config LICENSE README.md | gzip -n -9 >"$TARBALL"
printf '  [OK] %s (sha256 %s)\n' "$(basename "$TARBALL")" "$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
