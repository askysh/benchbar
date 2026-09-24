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
#   NOTARY_KEY_PATH             App Store Connect API key (.p8 file)
#   NOTARY_KEY_ID               its key id
#   NOTARY_ISSUER_ID            its issuer id
#   SPARKLE_ED_KEY_PATH         Sparkle EdDSA private key file (generate_keys -x)
#   BENCHBAR_SPARKLE_PUBLIC_KEY the matching public key (goes into Info.plist)
#
# Output in dist/:
#   BenchBar-<version>.dmg      signed, notarized, stapled: for people and Homebrew
#   BenchBar-<version>.zip      the stapled app: for Sparkle updates
#   appcast.xml                 the Sparkle feed, signed with the EdDSA key
#   benchbar.rb                 the Homebrew cask with the DMG's sha256
#   SHA256SUMS

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
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    -*) die "Unknown option: $arg" ;;
    *) VERSION="$arg" ;;
  esac
done

project_version() {
  sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "${ROOT}/macos/project.yml" | head -n 1
}

# ------------------------------------------------------------------ checks
step "check tools and settings"
for tool in xcodegen xcodebuild xcrun hdiutil ditto codesign shasum; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found" "install Xcode and: brew install xcodegen"
done
ok "tools present"
missing=()
for var in BENCHBAR_SIGN_IDENTITY BENCHBAR_TEAM_ID NOTARY_KEY_PATH NOTARY_KEY_ID NOTARY_ISSUER_ID \
           SPARKLE_ED_KEY_PATH BENCHBAR_SPARKLE_PUBLIC_KEY; do
  [[ -n "${!var:-}" ]] || missing+=("$var")
done
[[ "${#missing[@]}" == "0" ]] || die "missing settings: ${missing[*]}" "see docs/releasing.md, Secrets"
[[ -f "$NOTARY_KEY_PATH" ]] || die "no API key at $NOTARY_KEY_PATH"
[[ -f "$SPARKLE_ED_KEY_PATH" ]] || die "no Sparkle key at $SPARKLE_ED_KEY_PATH"
security find-identity -v -p codesigning | grep -qF "$BENCHBAR_SIGN_IDENTITY" \
  || die "signing identity not in the keychain: $BENCHBAR_SIGN_IDENTITY" "import the Developer ID .p12 (docs/releasing.md)"
ok "settings and signing identity present"

want="$(project_version)"
[[ -n "$VERSION" ]] || VERSION="$want"
[[ "$VERSION" == "$want" ]] || die "version $VERSION does not match MARKETING_VERSION $want in macos/project.yml" \
  "bump MARKETING_VERSION (and CURRENT_PROJECT_VERSION), commit, tag v${want}"
ok "version ${VERSION}"
[[ "$CHECK_ONLY" == "1" ]] && { printf '\n[OK] ready to release %s\n' "$VERSION"; exit 0; }

notarize() {
  xcrun notarytool submit "$1" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" --wait --timeout 30m
}

# ------------------------------------------------------------------- build
step "build with Developer ID and Sparkle"
export BENCHBAR_SPARKLE=YES
"${ROOT}/scripts/macos-build.sh" --test --sparkle

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
trap 'rm -rf "$stage"' EXIT
ditto "$APP" "${stage}/BenchBar.app"
ln -s /Applications "${stage}/Applications"
hdiutil create -volname "BenchBar ${VERSION}" -srcfolder "$stage" -ov -format UDZO "$DMG" >/dev/null
codesign --sign "$BENCHBAR_SIGN_IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
ok "dmg signed, notarized and stapled"

# ---------------------------------------------------------------- Sparkle
step "Sparkle appcast"
tools="$(find "${ROOT}/macos/build/DerivedData/SourcePackages/artifacts" -type f -name generate_appcast -path '*Sparkle*' 2>/dev/null | head -n 1)"
[[ -x "$tools" ]] || die "generate_appcast not found in the Sparkle package" "run scripts/macos-build.sh --sparkle once"
feed="$(mktemp -d)"
cp "$ZIP" "$feed/"
"$tools" --ed-key-file "$SPARKLE_ED_KEY_PATH" \
  --download-url-prefix "${REPO_URL}/releases/download/v${VERSION}/" \
  --link "$REPO_URL" "$feed"
cp "${feed}/appcast.xml" "${DIST}/appcast.xml"
rm -rf "$feed"
ok "appcast.xml signed"

# ---------------------------------------------------------------- Homebrew
step "Homebrew cask"
sha="$(shasum -a 256 "$DMG" | awk '{print $1}')"
sed -e "s/{{VERSION}}/${VERSION}/g" -e "s/{{SHA256}}/${sha}/g" \
  "${ROOT}/packaging/homebrew/benchbar.rb.tmpl" >"${DIST}/benchbar.rb"
(cd "$DIST" && shasum -a 256 ./*.dmg ./*.zip >SHA256SUMS)
ok "benchbar.rb (sha256 ${sha})"

printf '\n[OK] release %s in %s\n' "$VERSION" "$DIST"
ls -1 "$DIST"
printf '\nNext: gh release create v%s dist/* --title "BenchBar %s" --generate-notes\n' "$VERSION" "$VERSION"
