#!/usr/bin/env bash
#
# macos-release.sh: build, sign, notarize and package a BenchBar release.
# Written for the day there is an Apple Developer account; docs/releasing.md
# explains every step and how to get each secret.
#
#   scripts/macos-release.sh 0.3.0            full release into dist/
#   scripts/macos-release.sh --check          only check tools and settings
#
# Needs these environment variables:
#   BENCHBAR_SIGN_IDENTITY      "Developer ID Application: Your Name (TEAMID)"
#   BENCHBAR_TEAM_ID            the 10 character team id
#   NOTARY_KEY_PATH             App Store Connect API key (.p8 file), or
#   NOTARY_KEY_BASE64           its content in base64 (CI: no file until it is used)
#   NOTARY_KEY_ID               its key id
#   NOTARY_ISSUER_ID            its issuer id
#   BENCHBAR_KEY_DIR            optional: the folder a key given as content is written into
#                               (default $TMPDIR); the caller removes it
#   SPARKLE_ED_KEY_PATH         Sparkle EdDSA private key file (generate_keys -x), or
#   SPARKLE_ED_KEY              its content (CI)
#   BENCHBAR_SPARKLE_PUBLIC_KEY the matching public key (goes into Info.plist)
#
# A key given as content never reaches the build or its tests: it is read into
# a shell variable that is not exported, and written to a 0600 file only for
# the one command that needs it (notarytool, generate_appcast), then deleted.
#
# Output in dist/:
#   BenchBar-<version>.dmg      signed, notarized, stapled: for people and Homebrew
#   BenchBar-<version>.zip      the stapled app: for Sparkle updates
#   appcast.xml                 the Sparkle feed, signed with the EdDSA key
#   benchbar-cli-<version>.tar.gz  the CLI for the Homebrew formula
#   SHA256SUMS
#
# The tap's formula and cask are written after the release is published,
# from these files (.github/workflows/homebrew-tap.yml).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="${ROOT}/dist"
APP="${ROOT}/macos/build/BenchBar.app"
REPO_URL="https://github.com/askysh/benchbar"

die() { printf '[FAIL] %s\n' "$1" >&2; [[ -n "${2:-}" ]] && printf '  fix: %s\n' "$2" >&2; exit 1; }
step() { printf '\n==> %s\n' "$1"; }
ok() { printf '  [OK] %s\n' "$1"; }

CHECK_ONLY=0
VERSION=""
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
    -*) die "Unknown option: $arg" ;;
    *) VERSION="$arg" ;;
  esac
done

# Keys given as content: keep them out of the environment of everything below.
NOTARY_KEY_B64="${NOTARY_KEY_BASE64:-}"
SPARKLE_KEY_CONTENT="${SPARKLE_ED_KEY:-}"
unset NOTARY_KEY_BASE64 SPARKLE_ED_KEY
NOTARY_KEY_TMP=""
SPARKLE_KEY_TMP=""
STAGE_DIR=""
cleanup() {
  [[ -z "$NOTARY_KEY_TMP" ]] || rm -f "$NOTARY_KEY_TMP"
  [[ -z "$SPARKLE_KEY_TMP" ]] || rm -f "$SPARKLE_KEY_TMP"
  [[ -z "$STAGE_DIR" ]] || rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

# use_notary_key / drop_notary_key: when the key came as content, write it to a
# 0600 file for one notarytool call and delete it again.
use_notary_key() {
  [[ -z "$NOTARY_KEY_B64" ]] && return 0
  NOTARY_KEY_TMP="$(umask 077; mktemp "${BENCHBAR_KEY_DIR:-${TMPDIR:-/tmp}}/benchbar-notary.XXXXXX")"
  printf '%s' "$NOTARY_KEY_B64" | base64 --decode >"$NOTARY_KEY_TMP"
  NOTARY_KEY_PATH="$NOTARY_KEY_TMP"
}
drop_notary_key() {
  [[ -z "$NOTARY_KEY_TMP" ]] && return 0
  rm -f "$NOTARY_KEY_TMP"
  NOTARY_KEY_TMP=""
  NOTARY_KEY_PATH=""
}
use_sparkle_key() {
  [[ -z "$SPARKLE_KEY_CONTENT" ]] && return 0
  SPARKLE_KEY_TMP="$(umask 077; mktemp "${BENCHBAR_KEY_DIR:-${TMPDIR:-/tmp}}/benchbar-sparkle.XXXXXX")"
  printf '%s' "$SPARKLE_KEY_CONTENT" >"$SPARKLE_KEY_TMP"
  SPARKLE_ED_KEY_PATH="$SPARKLE_KEY_TMP"
}
drop_sparkle_key() {
  [[ -z "$SPARKLE_KEY_TMP" ]] && return 0
  rm -f "$SPARKLE_KEY_TMP"
  SPARKLE_KEY_TMP=""
  SPARKLE_ED_KEY_PATH=""
}

project_version() {
  sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "${ROOT}/macos/project.yml" | head -n 1
}

# ------------------------------------------------------------------ checks
step "check tools and settings"
for tool in xcodegen xcodebuild xcrun hdiutil ditto codesign shasum; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found" "install Xcode and: brew install xcodegen"
done
ok "tools present"
"${ROOT}/scripts/check-profile-formulae.sh" || die "a release profile names a formula Homebrew is about to disable" "move the profile in config/release-profiles.tsv (see docs/DECISIONS.md, 0.7.3)"
missing=()
for var in BENCHBAR_SIGN_IDENTITY BENCHBAR_TEAM_ID NOTARY_KEY_ID NOTARY_ISSUER_ID BENCHBAR_SPARKLE_PUBLIC_KEY; do
  [[ -n "${!var:-}" ]] || missing+=("$var")
done
[[ -n "${NOTARY_KEY_PATH:-}" || -n "$NOTARY_KEY_B64" ]] || missing+=("NOTARY_KEY_PATH or NOTARY_KEY_BASE64")
[[ -n "${SPARKLE_ED_KEY_PATH:-}" || -n "$SPARKLE_KEY_CONTENT" ]] || missing+=("SPARKLE_ED_KEY_PATH or SPARKLE_ED_KEY")
[[ "${#missing[@]}" == "0" ]] || die "missing settings: ${missing[*]}" "see docs/releasing.md, Secrets"
[[ -z "${NOTARY_KEY_PATH:-}" || -f "$NOTARY_KEY_PATH" ]] || die "no API key at $NOTARY_KEY_PATH"
[[ -z "${SPARKLE_ED_KEY_PATH:-}" || -f "$SPARKLE_ED_KEY_PATH" ]] || die "no Sparkle key at $SPARKLE_ED_KEY_PATH"
security find-identity -v -p codesigning | grep -qF "$BENCHBAR_SIGN_IDENTITY" \
  || die "signing identity not in the keychain: $BENCHBAR_SIGN_IDENTITY" "import the Developer ID .p12 (docs/releasing.md)"
ok "settings and signing identity present"

want="$(project_version)"
[[ -n "$VERSION" ]] || VERSION="$want"
[[ "$VERSION" == "$want" ]] || die "version $VERSION does not match MARKETING_VERSION $want in macos/project.yml" \
  "bump MARKETING_VERSION (and CURRENT_PROJECT_VERSION), commit, tag v${want}"
# CFBundleVersion is what Sparkle compares to decide an update is newer:
# the commit count, as release-local.sh uses, so it only grows (CI checks
# out the full history). project.yml's constant 1 would make every
# release look the same to Sparkle.
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null)" \
  || die "cannot count the commits for the build number" "run from a full git checkout (fetch-depth 0)"
ok "version ${VERSION}, build ${BUILD_NUMBER}"
[[ "$CHECK_ONLY" == "1" ]] && { printf '\n[OK] ready to release %s\n' "$VERSION"; exit 0; }

# notarytool exits 0 when Apple answers Invalid: the status decides, and
# the log says why. Its progress shows as it waits. Apple's first
# submissions for a team can take well over the usual minutes:
# NOTARY_TIMEOUT sets the wait (a submission that outlasts it goes on at
# Apple: `xcrun notarytool wait ID`).
notarize() {
  local out id
  use_notary_key
  out="$(xcrun notarytool submit "$1" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" --wait --timeout "${NOTARY_TIMEOUT:-50m}" 2>&1 | tee /dev/stderr)" \
    || die "notarytool failed for $1" "if it timed out, xcrun notarytool wait ID, then run this again"
  if ! grep -q '^[[:space:]]*status: Accepted' <<<"$out"; then
    id="$(sed -n 's/^[[:space:]]*id: //p' <<<"$out" | head -n 1)"
    [[ -n "$id" ]] && xcrun notarytool log "$id" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" || true
    die "Apple did not accept $1" "read the log above; the issues name each binary"
  fi
  drop_notary_key
}

# ------------------------------------------------------------------- build
step "build with Developer ID and Sparkle"
export BENCHBAR_SPARKLE=YES
# BENCHBAR_SKIP_TESTS=1: the release workflow checked that CI passed on this tree,
# Swift tests included, so they are not run twice
test_flag=(--test)
[[ "${BENCHBAR_SKIP_TESTS:-}" != "1" ]] || test_flag=()
BENCHBAR_VERSION="$VERSION" BENCHBAR_BUILD="$BUILD_NUMBER" "${ROOT}/scripts/macos-build.sh" ${test_flag[@]+"${test_flag[@]}"} --sparkle
built="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "${APP}/Contents/Info.plist")"
[[ "$built" == "$BUILD_NUMBER" ]] || die "the app says build ${built}, expected ${BUILD_NUMBER}"

rm -rf "$DIST"
mkdir -p "$DIST"
ZIP="${DIST}/BenchBar-${VERSION}.zip"
DMG="${DIST}/BenchBar-${VERSION}.dmg"

# ------------------------------------------------------ notarize the app
step "notarize the app"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
xcrun stapler staple "$APP"
# zip again so the Sparkle download carries the stapled ticket
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose=2 "$APP"
ok "app notarized and stapled"

# ------------------------------------------------------------------- DMG
step "disk image"
stage="$(mktemp -d)"
STAGE_DIR="$stage"
ditto "$APP" "${stage}/BenchBar.app"
ln -s /Applications "${stage}/Applications"
hdiutil create -volname "BenchBar ${VERSION}" -srcfolder "$stage" -ov -format UDZO "$DMG" >/dev/null
codesign --sign "$BENCHBAR_SIGN_IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
ok "dmg signed, notarized and stapled"

# ---------------------------------------------------------------- Sparkle
step "Sparkle appcast"
# scripts/macos-appcast.sh signs it, links the release notes and checks the result.
# The key is written to its file only around this one call (the variable is not
# exported, so it is given to the script on its command line).
use_sparkle_key
SPARKLE_ED_KEY_PATH="${SPARKLE_ED_KEY_PATH:-}" "${ROOT}/scripts/macos-appcast.sh" \
  --url-prefix "${REPO_URL}/releases/download/v${VERSION}/" \
  --notes-url "${REPO_URL}/releases/tag/v${VERSION}" "$DIST" "${DIST}/appcast.xml" || die "no signed appcast"
drop_sparkle_key
[[ -f "${DIST}/appcast.xml" ]] || die "no appcast.xml: the release has no Mac zip" "build the app first"
ok "appcast.xml signed and checked"

# --------------------------------------------------------------- CLI tarball
step "CLI tarball"
"${ROOT}/scripts/cli-tarball.sh" "$VERSION" "$DIST"
(cd "$DIST" && shasum -a 256 ./*.dmg ./*.zip ./*.tar.gz >SHA256SUMS)
ok "SHA256SUMS"

printf '\n[OK] release %s in %s\n' "$VERSION" "$DIST"
ls -1 "$DIST"
printf '\nNext: gh release create v%s dist/* --draft --title "BenchBar %s" --generate-notes\n' "$VERSION" "$VERSION"
