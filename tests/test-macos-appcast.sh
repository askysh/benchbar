#!/usr/bin/env bash
# The Sparkle appcast (scripts/macos-appcast.sh): an unsigned feed made from a
# test build's zip passes the check, a feed without a signature fails the
# signed check, and a release with no Mac files writes nothing and exits 0
# (so the feed of the latest release never turns into an empty one).
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

APPCAST_SH="$ROOT/scripts/macos-appcast.sh"
REAL_PATH="${PATH#"$ROOT/tests/mocks/bin:"}"

# a zip shaped like `ditto -c -k --keepParent BenchBar.app`, with the Info.plist keys of a Sparkle build
make_zip() { # DIR VERSION BUILD [feed-url]
  python3 -I - "$1" "$2" "$3" "${4-https://github.com/askysh/benchbar/releases/latest/download/appcast.xml}" <<'PY'
import plistlib, sys, zipfile
folder, version, build, feed = sys.argv[1:5]
info = {"CFBundleShortVersionString": version, "CFBundleVersion": build, "LSMinimumSystemVersion": "14.0",
        "SUPublicEDKey": "test-key", "SUEnableAutomaticChecks": True}
if feed:
    info["SUFeedURL"] = feed
with zipfile.ZipFile("%s/BenchBar-%s.zip" % (folder, version), "w") as z:
    z.writestr("BenchBar.app/Contents/Info.plist", plistlib.dumps(info))
    z.writestr("BenchBar.app/Contents/MacOS/BenchBar", "binary")
PY
}

run_appcast() { PATH="$REAL_PATH" bash "$APPCAST_SH" "$@"; }

# ---- a release with no Mac files is skipped, not an error, and writes nothing
mkdir -p "$TMP_DIR/empty" "$TMP_DIR/windows-only"
: >"$TMP_DIR/windows-only/BenchBar-0.9.0-windows.msix"
for dir in empty windows-only; do
  set +e; OUT="$(run_appcast --unsigned "$TMP_DIR/$dir" "$TMP_DIR/$dir.xml" 2>&1)"; CODE=$?; set -e
  assert_eq 0 "$CODE" "(no Mac files in $dir)"
  assert_contains "$OUT" "[SKIP] no Mac files"
  assert_no_file "$TMP_DIR/$dir.xml" "(nothing written for $dir)"
done

# ---- an unsigned appcast from a test build's zip
mkdir -p "$TMP_DIR/feed"
make_zip "$TMP_DIR/feed" 0.9.0 412
OUT="$(run_appcast --unsigned --notes-url https://github.com/askysh/benchbar/releases/tag/v0.9.0 "$TMP_DIR/feed" "$TMP_DIR/feed/appcast.xml" 2>&1)"
assert_contains "$OUT" "1 item(s) ok"
XML="$(cat "$TMP_DIR/feed/appcast.xml")"
assert_contains "$XML" "<sparkle:version>412</sparkle:version>"
assert_contains "$XML" "<sparkle:shortVersionString>0.9.0</sparkle:shortVersionString>"
assert_contains "$XML" "<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>"
assert_contains "$XML" "<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>"
assert_contains "$XML" 'enclosure url="https://github.com/askysh/benchbar/releases/latest/download/BenchBar-0.9.0.zip"'
assert_contains "$XML" "<sparkle:fullReleaseNotesLink>https://github.com/askysh/benchbar/releases/tag/v0.9.0</sparkle:fullReleaseNotesLink>"

# ---- the checks: an unsigned feed is fine unsigned and refused as a release
run_appcast --check "$TMP_DIR/feed/appcast.xml" >/dev/null
set +e; OUT="$(run_appcast --check --require-signature "$TMP_DIR/feed/appcast.xml" 2>&1)"; CODE=$?; set -e
assert_eq 1 "$CODE" "(a release feed must be signed)"
assert_contains "$OUT" "no sparkle:edSignature"

# a feed with a signature passes the signed check
python3 -I - "$TMP_DIR/feed/appcast.xml" "$TMP_DIR/signed.xml" <<'PY'
import sys
s = open(sys.argv[1]).read().replace('type="application/octet-stream"', 'type="application/octet-stream" sparkle:edSignature="abc"')
open(sys.argv[2], "w").write(s)
PY
run_appcast --check --require-signature "$TMP_DIR/signed.xml" >/dev/null

# broken feeds
printf '<rss version="2.0"><channel><title>BenchBar</title></channel></rss>\n' >"$TMP_DIR/noitem.xml"
set +e; OUT="$(run_appcast --check "$TMP_DIR/noitem.xml" 2>&1)"; CODE=$?; set -e
assert_eq 1 "$CODE" "(no item)"
assert_contains "$OUT" "has no item"
sed 's#https://github.com/askysh/benchbar/releases/latest/download/BenchBar-0.9.0.zip#http://example.com/BenchBar.zip#' "$TMP_DIR/feed/appcast.xml" >"$TMP_DIR/http.xml"
set +e; OUT="$(run_appcast --check "$TMP_DIR/http.xml" 2>&1)"; CODE=$?; set -e
assert_eq 1 "$CODE" "(a download over http)"
assert_contains "$OUT" "no https download"

# ---- a build without Sparkle's keys (a plain build) cannot make a feed
mkdir -p "$TMP_DIR/plain"
make_zip "$TMP_DIR/plain" 0.9.0 412 ""
set +e; OUT="$(run_appcast --unsigned "$TMP_DIR/plain" "$TMP_DIR/plain.xml" 2>&1)"; CODE=$?; set -e
assert_eq 1 "$CODE" "(no SUFeedURL: not a Sparkle build)"
assert_contains "$OUT" "has no SUFeedURL"
assert_no_file "$TMP_DIR/plain.xml"

# two releases in one folder are both in the feed
make_zip "$TMP_DIR/feed" 0.9.1 413
run_appcast --unsigned "$TMP_DIR/feed" "$TMP_DIR/two.xml" >/dev/null
assert_contains "$(cat "$TMP_DIR/two.xml")" "BenchBar-0.9.1.zip"
assert_contains "$(cat "$TMP_DIR/two.xml")" "BenchBar-0.9.0.zip"

# the signed path needs its tool and key, and says which is missing
set +e; OUT="$(GENERATE_APPCAST=/nonexistent run_appcast "$TMP_DIR/feed" "$TMP_DIR/signed-out.xml" 2>&1)"; CODE=$?; set -e
assert_eq 1 "$CODE" "(no generate_appcast)"
assert_contains "$OUT" "generate_appcast not found"

printf 'test-macos-appcast: ok\n'
