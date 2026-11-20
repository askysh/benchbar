#!/bin/bash
# shellcheck disable=SC2016  # the backticks are Markdown, not commands
#
# release-notes.sh: the GitHub release notes for one version, on stdout.
#
#   scripts/release-notes.sh 0.6.0            ad hoc signed build
#   scripts/release-notes.sh 0.6.0 --signed   Developer ID and notarized
#   scripts/release-notes.sh 0.9.0-rc.1 --signed   a release candidate
#
# An "Update" section first (the command people on an older version copy,
# and the app's Update Now), then the version's CHANGELOG.md section, then
# how to install and the checksums. CHANGELOG defaults to CHANGELOG.md in
# the repository; the release workflow runs this.
#
# A release candidate (X.Y.Z-rc.N) is a pre-release that no updater offers,
# so it gets no Update section and no Homebrew line: it says what it is and
# gives the command that names its version. Its changes are the section of
# its own version when CHANGELOG.md has one, else "## Unreleased" with the
# fragments in changelog.d folded in (scripts/changelog-fold.sh --print).

set -euo pipefail

VERSION="${1:-}"
SIGNED=0
[[ "${2:-}" == "--signed" ]] && SIGNED=1
[[ -n "$VERSION" ]] || { printf 'Usage: scripts/release-notes.sh VERSION [--signed]\n' >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHANGELOG="${CHANGELOG:-$ROOT/CHANGELOG.md}"
INSTALLER="https://raw.githubusercontent.com/askysh/benchbar/main/install.sh"

"$ROOT/scripts/check-version.sh" --valid "$VERSION" || exit 1
RC=0
[[ "$VERSION" == *-rc.* ]] && RC=1

section="$(awk -v v="$VERSION" '/^## /{p = ($2 == v)} p' "$CHANGELOG" | tail -n +2)"
if [[ -z "$section" && "$RC" == "1" ]]; then
  section="$(CHANGELOG="$CHANGELOG" bash "$ROOT/scripts/changelog-fold.sh" --print | tail -n +2)"
fi
[[ -n "$section" ]] || { printf 'CHANGELOG has no "## %s " section\n' "$VERSION" >&2; exit 1; }

if [[ "$RC" == "1" ]]; then
  printf '## Release candidate\n\n'
  printf 'This is a **pre-release** of BenchBar %s, for testing before the release. It is not offered as an update: Sparkle, the app'"'"'s update banner, `benchbar self-update`, the one line installers and Homebrew all stay on the last release. To try it, name the version:\n\n' "${VERSION%%-*}"
  printf '```bash\ncurl -fsSL https://raw.githubusercontent.com/askysh/benchbar/v%s/install.sh | bash -s -- --version v%s\n```\n\n' "$VERSION" "$VERSION"
  printf 'On Windows, the notes below give the PowerShell line. To go back, run the normal installer without a version.\n\n'
  printf '## Changes so far\n'
  printf '%s\n' "$section"
  printf '\n---\n\n'
  if [[ "$SIGNED" == "1" ]]; then
    printf 'Signed with a Developer ID and notarized by Apple. Download the DMG or zip below, or use the line above.\n\n'
  else
    printf 'This build is **not signed with an Apple Developer ID** (ad hoc signature): use the line above, which downloads with curl and opens without the Gatekeeper prompt.\n\n'
  fi
  printf 'Checksums are in `SHA256SUMS`.\n'
  exit 0
fi

printf '## Update\n\n'
printf 'Already using BenchBar? In the app, click **Update Now** in the update banner or the menu bar menu (BenchBar 0.6 and later check once a day). On 0.5.x, run this in Terminal:\n\n'
printf '```bash\ncurl -fsSL %s | bash -s -- --yes\n```\n\n' "$INSTALLER"
printf 'It updates the benchbar CLI in `~/.local/share/benchbar` and the app in `~/Applications`, quits a running BenchBar first and never touches a bench. From 0.6 on, `benchbar self-update` runs the same. If your benchbar is a git checkout of your own, `git pull` there and add `--app-only`.\n\n'
printf 'Installed with Homebrew? Run `brew upgrade`, or click **Update Now** in the app: from 0.7.1 the app carries its command line tool, and Homebrew'"'"'s benchbar hands off to it, so either way updates both. The tap gets a release a few minutes after it is published.\n\n'
printf 'What this release means for you, and what to do after the update: [What'"'"'s new](https://benchbar.akashmishra.com/whats-new/).\n\n'
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
