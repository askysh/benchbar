#!/usr/bin/env bash
#
# release-local.sh: build the unsigned (ad hoc signed) release files locally,
# the same ones .github/workflows/release.yml uploads when no Developer ID
# is configured. Needs full Xcode and XcodeGen, nothing else.
#
#   scripts/release-local.sh                  version from macos/project.yml
#   scripts/release-local.sh 0.3.0            explicit version (a tag build)
#   scripts/release-local.sh --skip-tests     do not run the Swift tests first
#
# Output in dist/:
#   BenchBar-<version>.zip     ditto -c -k --keepParent of the app
#   BenchBar-<version>.dmg     hdiutil image with an Applications shortcut
#   SHA256SUMS                 shasum -a 256 of both
#
# The app is ad hoc signed (by macos-build.sh), so Gatekeeper shows "Apple could
# not verify" on the first open of a DMG download. README explains the
# "Open Anyway" steps; install.sh downloads with curl, which sets no
# quarantine flag, so the app opens directly.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="${ROOT}/dist"
APP="${ROOT}/macos/build/BenchBar.app"
RUN_TESTS=1
VERSION=""

die() { printf '[FAIL] %s\n' "$1" >&2; [[ -n "${2:-}" ]] && printf '  fix: %s\n' "$2" >&2; exit 1; }
step() { printf '\n==> %s\n' "$1"; }
ok() { printf '  [OK] %s\n' "$1"; }

for arg in "$@"; do
  case "$arg" in
    --skip-tests) RUN_TESTS=0 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) die "Unknown option: $arg" ;;
    *) VERSION="$arg" ;;
  esac
done

project_version() {
  sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "${ROOT}/macos/project.yml" | head -n 1
}

step "check tools"
for tool in xcodegen xcodebuild hdiutil ditto codesign shasum; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found" "install Xcode and: brew install xcodegen"
done
ok "tools present"

[[ -n "$VERSION" ]] || VERSION="$(project_version)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || die "version '${VERSION}' does not look like X.Y.Z"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || printf '1')"
ok "version ${VERSION}, build ${BUILD_NUMBER}"

step "build and ad hoc sign"
build_args=()
[[ "$RUN_TESTS" == "1" ]] && build_args+=(--test)
BENCHBAR_VERSION="$VERSION" BENCHBAR_BUILD="$BUILD_NUMBER" "${ROOT}/scripts/macos-build.sh" ${build_args[@]+"${build_args[@]}"}
[[ -d "$APP" ]] || die "no app at ${APP}"
# macos-build.sh already signed ad hoc with the Hardened Runtime and the
# entitlements; signing again here would drop both. Only verify.
codesign --verify --deep --strict "$APP"
# captured first: grep -q stops reading at the match, and codesign's
# SIGPIPE would fail the pipeline under pipefail
signature="$(codesign -dv --verbose=2 "$APP" 2>&1 || true)"
[[ "$signature" == *"flags="*"runtime"* ]] || die "the app lost its Hardened Runtime flag"
got="$(defaults read "${APP}/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
[[ "$got" == "$VERSION" ]] || die "Info.plist says ${got:-nothing}, expected ${VERSION}"
ok "BenchBar.app ${VERSION} (${BUILD_NUMBER}), ad hoc signed"

rm -rf "$DIST"
mkdir -p "$DIST"
ZIP="${DIST}/BenchBar-${VERSION}.zip"
DMG="${DIST}/BenchBar-${VERSION}.dmg"

step "zip"
ditto -c -k --keepParent "$APP" "$ZIP"
ok "$(basename "$ZIP")"

step "disk image"
stage="$(mktemp -d "${TMPDIR:-/tmp}/benchbar-dmg.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto "$APP" "${stage}/BenchBar.app"
ln -s /Applications "${stage}/Applications"
hdiutil create -volname "BenchBar ${VERSION}" -srcfolder "$stage" -ov -format UDZO -quiet "$DMG"
ok "$(basename "$DMG")"

step "checksums"
(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" >SHA256SUMS)
cat "${DIST}/SHA256SUMS"

printf '\n[OK] unsigned release %s in %s\n' "$VERSION" "$DIST"
ls -1 "$DIST"
