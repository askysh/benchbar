#!/bin/bash
# shellcheck disable=SC2016  # the backticks are Markdown, not commands
#
# release-notes.sh: the GitHub release notes for one version, on stdout.
#
#   scripts/release-notes.sh 0.6.0            ad hoc signed build
#   scripts/release-notes.sh 0.6.0 --signed   Developer ID and notarized
#
# An "Update" section first (the command people on an older version copy,
# and the app's Update Now), then the version's CHANGELOG.md section, then
# how to install and the checksums. CHANGELOG defaults to CHANGELOG.md in
# the repository; the release workflow runs this.

set -euo pipefail

VERSION="${1:-}"
SIGNED=0
[[ "${2:-}" == "--signed" ]] && SIGNED=1
[[ -n "$VERSION" ]] || { printf 'Usage: scripts/release-notes.sh VERSION [--signed]\n' >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHANGELOG="${CHANGELOG:-$ROOT/CHANGELOG.md}"
INSTALLER="https://raw.githubusercontent.com/askysh/benchbar/main/install.sh"

section="$(awk -v v="$VERSION" '/^## /{p = ($2 == v)} p' "$CHANGELOG" | tail -n +2)"
[[ -n "$section" ]] || { printf 'CHANGELOG has no "## %s " section\n' "$VERSION" >&2; exit 1; }

printf '## Update\n\n'
printf 'Already using BenchBar? In the app, click **Update Now** in the update banner or the menu bar menu (BenchBar 0.6 and later check once a day). On 0.5.x, run this in Terminal:\n\n'
printf '```bash\ncurl -fsSL %s | bash -s -- --yes\n```\n\n' "$INSTALLER"
printf 'It updates the benchbar CLI in `~/.local/share/benchbar` and the app in `~/Applications`, quits a running BenchBar first and never touches a bench. From 0.6 on, `benchbar self-update` runs the same. If your benchbar is a git checkout of your own, `git pull` there and add `--app-only`.\n\n'
printf 'Installed with Homebrew? Run `brew upgrade askysh/tap/benchbar` (or `benchbar self-update`, which runs it); the app updates itself. The tap gets a release a few minutes after it is published.\n\n'
printf '## Changes\n'
printf '%s\n' "$section"
printf '\n---\n\n'
if [[ "$SIGNED" == "1" ]]; then
  printf 'Signed with a Developer ID and notarized by Apple. Install with Homebrew:\n\n'
  printf '```bash\nbrew install askysh/tap/benchbar askysh/tap/benchbar-app\n```\n\n'
  printf 'or with the DMG, or with the one line installer:\n\n'
else
  printf 'This build is **not signed with an Apple Developer ID** (ad hoc signature). macOS shows "Apple could not verify" on first open of the DMG: use System Settings > Privacy & Security > Open Anyway, or install with the one liner, which downloads with curl and opens without that prompt:\n\n'
fi
printf '```bash\ncurl -fsSL %s | bash\n```\n\n' "$INSTALLER"
printf 'Checksums are in `SHA256SUMS`.\n'
