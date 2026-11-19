#!/usr/bin/env bash
#
# macos-appcast.sh: make or check the Sparkle appcast of a release.
#
#   scripts/macos-appcast.sh [--unsigned] [--url-prefix URL] [--notes-url URL] DIR OUT
#   scripts/macos-appcast.sh --check [--require-signature] APPCAST
#
# DIR holds the release's Mac files: BenchBar-<version>.zip, the stapled app
# Sparkle downloads. A DIR with no such file is a release without Mac files
# (the Windows or CLI only kind): nothing is written, the exit is 0 and the
# message says so, so a release step that runs on every release cannot fail or
# publish an empty feed because of it.
#
# Signed (the default, a release): generate_appcast from the Sparkle package
# signs each zip with the EdDSA key in SPARKLE_ED_KEY_PATH and links the
# release notes with --full-release-notes-url. Needs the Sparkle build
# (scripts/macos-build.sh --sparkle) for the tool, or GENERATE_APPCAST.
#
# --unsigned (pull request CI): the same document without the signature,
# written from the zip's own Info.plist, so a test build proves the feed
# format and the keys Sparkle reads (SUFeedURL, SUPublicEDKey) without a secret.
#
# --check validates a feed: every item has an https download, a length, a
# build and a version, and with --require-signature an EdDSA signature too.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNSIGNED=0
CHECK=0
REQUIRE_SIGNATURE=0
PREFIX="https://github.com/askysh/benchbar/releases/latest/download/"
NOTES_URL=""
ARGS=()

die() { printf '[FAIL] %s\n' "$1" >&2; [[ -n "${2:-}" ]] && printf '  fix: %s\n' "$2" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --unsigned) UNSIGNED=1 ;;
    --check) CHECK=1 ;;
    --require-signature) REQUIRE_SIGNATURE=1 ;;
    --url-prefix) PREFIX="${2:?--url-prefix needs a value}"; shift ;;
    --notes-url) NOTES_URL="${2:?--notes-url needs a value}"; shift ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    -*) die "Unknown option: $1" ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done

# the writer of the unsigned feed and the checker: python, no dependency
PY_UNSIGNED='
import plistlib, sys, zipfile, os
from xml.sax.saxutils import escape, quoteattr
out, prefix, notes = sys.argv[1], sys.argv[2], sys.argv[3]
items = []
for z in sys.argv[4:]:
    with zipfile.ZipFile(z) as f:
        names = [n for n in f.namelist() if n.endswith(".app/Contents/Info.plist") and n.count("/") == 2]
        if not names:
            sys.exit("no Info.plist at the top of %s" % z)
        info = plistlib.loads(f.read(names[0]))
    for key in ("CFBundleShortVersionString", "CFBundleVersion", "SUFeedURL", "SUPublicEDKey"):
        if not info.get(key):
            sys.exit("%s: Info.plist has no %s (was the app built with --sparkle?)" % (os.path.basename(z), key))
    if not str(info["SUFeedURL"]).startswith("https://"):
        sys.exit("SUFeedURL is not https: %s" % info["SUFeedURL"])
    link = ("<sparkle:fullReleaseNotesLink>%s</sparkle:fullReleaseNotesLink>" % escape(notes)) if notes else ""
    items.append(
        "    <item>\n      <title>Version %s</title>\n      <sparkle:version>%s</sparkle:version>\n"
        "      <sparkle:shortVersionString>%s</sparkle:shortVersionString>\n"
        "      <sparkle:minimumSystemVersion>%s</sparkle:minimumSystemVersion>\n"
        "      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>\n      %s\n"
        "      <enclosure url=%s length=\"%d\" type=\"application/octet-stream\"/>\n    </item>\n"
        % (escape(info["CFBundleShortVersionString"]), escape(str(info["CFBundleVersion"])), escape(info["CFBundleShortVersionString"]),
           escape(str(info.get("LSMinimumSystemVersion", "14.0"))), link,
           quoteattr(prefix + os.path.basename(z)), os.path.getsize(z)))
with open(out, "w") as f:
    f.write("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<rss version=\"2.0\" xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\">\n"
            "  <channel>\n    <title>BenchBar</title>\n" + "".join(items) + "  </channel>\n</rss>\n")
'
PY_CHECK='
import sys, xml.etree.ElementTree as ET
ns = {"s": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
path, need_sig = sys.argv[1], sys.argv[2] == "1"
items = ET.parse(path).getroot().findall("./channel/item")
if not items:
    sys.exit("%s has no item" % path)
def field(item, enc, tag):
    return item.findtext("s:" + tag, namespaces=ns) or enc.get("{%s}%s" % (ns["s"], tag))
for item in items:
    enc = item.find("enclosure")
    where = item.findtext("title") or "an item"
    if enc is None or not enc.get("url", "").startswith("https://"):
        sys.exit("%s: no https download" % where)
    if not enc.get("length", "").isdigit() or int(enc.get("length")) <= 0:
        sys.exit("%s: no length" % where)
    for tag in ("version", "shortVersionString", "minimumSystemVersion"):
        if not field(item, enc, tag):
            sys.exit("%s: no sparkle:%s" % (where, tag))
    if not field(item, enc, "version").isdigit():
        sys.exit("%s: sparkle:version is not a build number" % where)
    if need_sig and not enc.get("{%s}edSignature" % ns["s"]):
        sys.exit("%s: no sparkle:edSignature" % where)
print("%d item(s) ok" % len(items))
'

if [[ "$CHECK" == "1" ]]; then
  [[ ${#ARGS[@]} -eq 1 ]] || die "--check takes one appcast file"
  [[ -f "${ARGS[0]}" ]] || die "no appcast at ${ARGS[0]}"
  python3 -I -c "$PY_CHECK" "${ARGS[0]}" "$REQUIRE_SIGNATURE" || die "the appcast ${ARGS[0]} is not valid"
  exit 0
fi

[[ ${#ARGS[@]} -eq 2 ]] || die "usage: macos-appcast.sh [--unsigned] DIR OUT"
DIR="${ARGS[0]}"
OUT="${ARGS[1]}"
[[ -d "$DIR" ]] || die "no folder $DIR"
ZIPS=()
for z in "$DIR"/BenchBar-*.zip; do
  if [[ -f "$z" ]]; then ZIPS+=("$z"); fi
done
if [[ ${#ZIPS[@]} -eq 0 ]]; then
  printf '[SKIP] no Mac files (BenchBar-*.zip) in %s: no appcast written\n' "$DIR"
  exit 0
fi

if [[ "$UNSIGNED" == "1" ]]; then
  python3 -I -c "$PY_UNSIGNED" "$OUT" "$PREFIX" "$NOTES_URL" "${ZIPS[@]}" || die "could not make the unsigned appcast"
  bash "$0" --check "$OUT"
else
  tool="${GENERATE_APPCAST:-$(find "${ROOT}/macos/build/DerivedData/SourcePackages/artifacts" -type f -name generate_appcast -path '*Sparkle*' 2>/dev/null | head -n 1)}"
  [[ -x "$tool" ]] || die "generate_appcast not found in the Sparkle package" "run scripts/macos-build.sh --sparkle once"
  [[ -n "${SPARKLE_ED_KEY_PATH:-}" && -f "${SPARKLE_ED_KEY_PATH}" ]] || die "SPARKLE_ED_KEY_PATH does not name a key file"
  feed="$(mktemp -d)"
  cp "${ZIPS[@]}" "$feed/"
  notes_args=()
  if [[ -n "$NOTES_URL" ]]; then notes_args=(--full-release-notes-url "$NOTES_URL"); fi
  "$tool" --ed-key-file "$SPARKLE_ED_KEY_PATH" --download-url-prefix "$PREFIX" --link "https://github.com/askysh/benchbar" \
    ${notes_args[@]+"${notes_args[@]}"} "$feed"
  cp "${feed}/appcast.xml" "$OUT"
  # the copy of the notarized zip is not needed any more
  rm -rf "$feed"
  bash "$0" --check --require-signature "$OUT"
fi
printf '[OK] %s\n' "$OUT"
