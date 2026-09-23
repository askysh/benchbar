#!/usr/bin/env bash
#
# macos-build.sh: build BenchBar.app from the command line, no Xcode clicks.
#
#   1. xcodegen generates macos/BenchBar.xcodeproj from macos/project.yml
#   2. xcodebuild builds the Release configuration
#   3. codesign signs the app ad hoc ("-") with the Hardened Runtime
#
# Output: macos/build/BenchBar.app
#
# Options:
#   --test      run the Swift tests before building
#   --debug     build the Debug configuration instead of Release
#   --sparkle   include Sparkle (BENCHBAR_SPARKLE=YES, see docs/releasing.md)
#
# Needs full Xcode 26 or newer (not only the Command Line Tools) and
# XcodeGen (brew install xcodegen).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACOS="${ROOT}/macos"
BUILD="${MACOS}/build"
DERIVED="${BUILD}/DerivedData"
CONFIG=Release
RUN_TESTS=0
export BENCHBAR_SPARKLE="${BENCHBAR_SPARKLE:-NO}"

for arg in "$@"; do
  case "$arg" in
    --test) RUN_TESTS=1 ;;
    --debug) CONFIG=Debug ;;
    --sparkle) BENCHBAR_SPARKLE=YES ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$arg" >&2; exit 1 ;;
  esac
done

die() { printf '[FAIL] %s\n' "$1" >&2; [[ -n "${2:-}" ]] && printf '  fix: %s\n' "$2" >&2; exit 1; }
step() { printf '\n==> %s\n' "$1"; }

command -v xcodegen >/dev/null 2>&1 || die "xcodegen not found" "brew install xcodegen"
xcodebuild -version >/dev/null 2>&1 || die "xcodebuild needs full Xcode, not only the Command Line Tools" \
  "install Xcode, then: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"

# xcbeautify makes the log readable when it is installed; plain output otherwise
pretty() { if command -v xcbeautify >/dev/null 2>&1; then xcbeautify --quiet; else cat; fi; }

step "xcodegen generate (Sparkle: ${BENCHBAR_SPARKLE})"
(cd "$MACOS" && xcodegen generate --quiet)

if [[ "$RUN_TESTS" == "1" ]]; then
  step "xcodebuild test"
  # show the Swift Testing result lines and errors; the full log stays in build/test.log
  mkdir -p "$BUILD"
  set +e
  xcodebuild -project "${MACOS}/BenchBar.xcodeproj" -scheme BenchBar -configuration Debug \
    -derivedDataPath "$DERIVED" -destination "platform=macOS,arch=arm64" test >"${BUILD}/test.log" 2>&1
  code=$?
  set -e
  grep -E '^(✔|✘)|Test run with|\.swift:[0-9]+:[0-9]+: error:|\*\* TEST' "${BUILD}/test.log" | grep -v 'started\.$' || true
  [[ "$code" == "0" ]] || die "Swift tests failed (exit ${code})" "less ${BUILD}/test.log"
fi

step "xcodebuild ${CONFIG}"
xcodebuild -project "${MACOS}/BenchBar.xcodeproj" -scheme BenchBar -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO -quiet build 2>&1 | pretty

APP="${DERIVED}/Build/Products/${CONFIG}/BenchBar.app"
[[ -d "$APP" ]] || die "build finished but ${APP} is missing"

step "copy to macos/build/BenchBar.app"
rm -rf "${BUILD}/BenchBar.app"
ditto "$APP" "${BUILD}/BenchBar.app"

step "codesign ad hoc with the Hardened Runtime"
codesign --force --deep --options runtime --timestamp=none \
  --entitlements "${MACOS}/BenchBar/Resources/BenchBar.entitlements" \
  --sign - "${BUILD}/BenchBar.app"
codesign --verify --strict --verbose=1 "${BUILD}/BenchBar.app"

printf '\n[OK] %s\n' "${BUILD}/BenchBar.app"
printf '  install: %s/scripts/macos-install-local.sh\n' "$ROOT"
