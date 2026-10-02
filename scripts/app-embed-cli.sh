#!/usr/bin/env bash
#
# app-embed-cli.sh: put the benchbar CLI inside BenchBar.app, in
# Contents/Resources/cli, so Sparkle and brew upgrade update the CLI with
# the app (lib/frappe-local/install-kind.sh, install kind "app").
#
#   scripts/app-embed-cli.sh path/to/BenchBar.app
#
# The same files as the Homebrew formula's tarball (scripts/cli-tarball.sh),
# taken from the working tree but only where git tracks them, so a local
# build carries the CLI it was built with and never an untracked file or a
# __pycache__. macos-build.sh runs it before it signs the app: the files are
# sealed with the bundle, and nothing may write into them later.
#
# It refuses an app whose CFBundleShortVersionString differs from FL_VERSION
# in benchbar: the app and its CLI are one version.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { printf '[FAIL] %s\n' "$1" >&2; [[ -n "${2:-}" ]] && printf '  fix: %s\n' "$2" >&2; exit 1; }

case "${1:-}" in
  -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
  "") sed -n '2,16p' "$0" >&2; exit 1 ;;
esac
APP="$1"
PLIST="${APP}/Contents/Info.plist"
[[ -f "$PLIST" ]] || die "no app at ${APP} (no Contents/Info.plist)"

app_version="$(/usr/bin/awk '/<key>CFBundleShortVersionString<\/key>/ { getline l; sub(/.*<string>/, "", l); sub(/<\/string>.*/, "", l); print l; exit }' "$PLIST")"
cli_version="$(sed -n 's/^FL_VERSION="\([^"]*\)"$/\1/p' "${ROOT}/benchbar" | head -n 1)"
[[ "$app_version" == "$cli_version" ]] || die "the app is ${app_version:-unknown} but benchbar says FL_VERSION=\"${cli_version}\"" \
  "set FL_VERSION in benchbar and MARKETING_VERSION in macos/project.yml to the same version"

DEST="${APP}/Contents/Resources/cli"
rm -rf "$DEST"
mkdir -p "$DEST"
# tar keeps the modes and the frappe-mac link; git ls-files skips what git does not track
(cd "$ROOT" && git ls-files -z -- benchbar frappe-mac 00-mac-system-deps.sh 01-install-bench-and-site.sh \
  02-background-service.sh lib templates config LICENSE | xargs -0 tar -cf -) | tar -xf - -C "$DEST"
[[ -x "${DEST}/benchbar" ]] || die "benchbar did not make it into ${DEST}"
printf '  [OK] benchbar %s in %s\n' "$cli_version" "$DEST"
