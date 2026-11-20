#!/usr/bin/env bash
#
# macos-packages.sh: build the app with the Swift packages that macos/Package.resolved
# names, and with no others.
#
#   scripts/macos-packages.sh [DERIVED_DATA_DIR]     after "xcodegen generate"
#   scripts/macos-packages.sh --check                after the build
#
# XcodeGen makes the Xcode project from project.yml and sparkle.yml, and the
# project is not committed, so Xcode has no pin file of its own. This copies
# the committed macos/Package.resolved into the generated project, where Xcode
# reads it, and fetches those exact revisions (-onlyUsePackageVersionsFromResolvedFile).
# Callers then build with -disableAutomaticPackageResolution, so a build never
# picks a newer Sparkle or swift-subprocess than the one in the file. --check
# fails when Xcode moved a pin anyway.
#
# A new version is a change to macos/Package.resolved (Dependabot proposes it
# from macos/Package.swift), reviewed like code. macos/DECISIONS.md, "Swift
# package pins", has the rest.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACOS="${ROOT}/macos"
SOURCE="${MACOS}/Package.resolved"
PROJECT="${MACOS}/BenchBar.xcodeproj"
INSTALLED="${PROJECT}/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

die() { printf '[FAIL] %s\n' "$1" >&2; [[ -n "${2:-}" ]] && printf '  fix: %s\n' "$2" >&2; exit 1; }

[[ -f "$SOURCE" ]] || die "macos/Package.resolved is missing" "git checkout macos/Package.resolved"

# every pin in the installed file is the pin of the committed file (Xcode may
# drop a pin the generated project does not use, e.g. Sparkle in a build
# without it, but it may not add one or move one)
check() {
  [[ -f "$INSTALLED" ]] || die "the generated project has no Package.resolved" "run scripts/macos-packages.sh after xcodegen generate"
  python3 -I - "$SOURCE" "$INSTALLED" <<'PY' || exit 1
import json, sys
def pins(path):
    return {p["identity"]: (p["location"], p["state"].get("revision"), p["state"].get("version")) for p in json.load(open(path))["pins"]}
want, got = pins(sys.argv[1]), pins(sys.argv[2])
bad = [f"{i}: the build resolved {got[i]}, macos/Package.resolved says {want.get(i)}" for i in sorted(got) if want.get(i) != got[i]]
if bad:
    print("[FAIL] the Swift packages moved during the build:\n  " + "\n  ".join(bad), file=sys.stderr)
    print("  fix: update macos/Package.resolved on purpose (swift package --package-path macos update), commit it, and build again", file=sys.stderr)
    sys.exit(1)
PY
}

if [[ "${1:-}" == "--check" ]]; then
  check
  printf 'Swift packages: exactly the pins of macos/Package.resolved\n'
  exit 0
fi

[[ -d "$PROJECT" ]] || die "macos/BenchBar.xcodeproj is missing" "cd macos && xcodegen generate"
DERIVED="${1:-${MACOS}/build/DerivedData}"
mkdir -p "$(dirname "$INSTALLED")" "$DERIVED"
cp "$SOURCE" "$INSTALLED"
xcodebuild -project "$PROJECT" -scheme BenchBar -resolvePackageDependencies -onlyUsePackageVersionsFromResolvedFile \
  -derivedDataPath "$DERIVED" >/dev/null 2>"${DERIVED}/resolve-packages.log" \
  || { cat "${DERIVED}/resolve-packages.log" >&2; die "xcodebuild could not fetch the packages of macos/Package.resolved"; }
check
