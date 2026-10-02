#!/usr/bin/env bash
#
# homebrew-render.sh: the tap's formula and cask for a release, from the
# templates in packaging/homebrew and the sha256 of the files themselves.
#
#   scripts/homebrew-render.sh --version 0.7.0 --cli FILE [--dmg FILE] [--url URL] OUT
#
#   --cli FILE   benchbar-cli-<version>.tar.gz (scripts/cli-tarball.sh)
#   --dmg FILE   BenchBar-<version>.dmg; without it no cask is written, as
#                for an ad hoc release, which brew should not install
#   --url URL    where the formula downloads the tarball; the release asset
#                on GitHub by default, a file:// url for a local test
#
# Writes OUT/Formula/benchbar.rb and, with --dmg, OUT/Casks/benchbar-app.rb:
# the same layout as github.com/askysh/homebrew-tap.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATES="${ROOT}/packaging/homebrew"

die() { printf '[FAIL] %s\n' "$1" >&2; [[ -n "${2:-}" ]] && printf '  fix: %s\n' "$2" >&2; exit 1; }
usage() { sed -n '2,15p' "$0"; }
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

VERSION="" CLI="" DMG="" URL="" OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --cli) CLI="${2:-}"; shift 2 ;;
    --dmg) DMG="${2:-}"; shift 2 ;;
    --url) URL="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "Unknown option: $1" ;;
    *) [[ -z "$OUT" ]] || die "Unexpected argument: $1"; OUT="$1"; shift ;;
  esac
done
[[ -n "$VERSION" && -n "$CLI" && -n "$OUT" ]] || { usage >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version '${VERSION}' is not X.Y.Z"
[[ -f "$CLI" ]] || die "no CLI tarball at ${CLI}" "scripts/cli-tarball.sh ${VERSION}"
[[ -z "$DMG" || -f "$DMG" ]] || die "no DMG at ${DMG}"
[[ -n "$URL" ]] || URL="https://github.com/askysh/benchbar/releases/download/v${VERSION}/benchbar-cli-${VERSION}.tar.gz"
# the url goes into a sed replacement and a Ruby string
[[ "$URL" != *[\"\|\\\&]* ]] || die "the url has a character the formula cannot hold: ${URL}"

mkdir -p "${OUT}/Formula"
sed -e "s|{{URL}}|${URL}|g" -e "s|{{SHA256}}|$(sha256 "$CLI")|g" \
  "${TEMPLATES}/Formula/benchbar.rb.tmpl" >"${OUT}/Formula/benchbar.rb"
printf '  [OK] Formula/benchbar.rb\n'

if [[ -n "$DMG" ]]; then
  mkdir -p "${OUT}/Casks"
  sed -e "s|{{VERSION}}|${VERSION}|g" -e "s|{{SHA256}}|$(sha256 "$DMG")|g" \
    "${TEMPLATES}/Casks/benchbar-app.rb.tmpl" >"${OUT}/Casks/benchbar-app.rb"
  printf '  [OK] Casks/benchbar-app.rb\n'
fi
