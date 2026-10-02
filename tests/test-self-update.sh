#!/usr/bin/env bash
# benchbar self-update: the version compare, --check and --json against a
# mocked GitHub release, --dry-run, the installer it runs (a stub served by
# the curl mock) for a managed install, a git checkout and some other
# install, an app outside ~/Applications, a Homebrew install (brew upgrade
# through the brew mock, never the installer), offline, and never a bench.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

INSTALLER="https://raw.githubusercontent.com/askysh/benchbar/main/install.sh"
# an offered release is installed from its own tag, pinned with --version
PINNED="https://raw.githubusercontent.com/askysh/benchbar/v99.0.0/install.sh"

# ---- the version compare
lt() { bash -c '. "$1/lib/frappe-local/selfupdate.sh"; fl_version_lt "$2" "$3"' _ "$ROOT" "$1" "$2"; }
lt 0.5.8 0.6.0 || fail "0.5.8 < 0.6.0"
lt v0.5.8 0.6.0 || fail "v0.5.8 < 0.6.0"
lt 0.9.0 0.10.0 || fail "0.9 < 0.10"
lt 0.6 0.6.1 || fail "0.6 < 0.6.1"
lt 0.6.0-beta.1 0.6.0 || fail "a prerelease comes before its release"
! lt 0.6.0 0.6.0 || fail "equal is not older"
! lt 0.6.0 0.6 || fail "0.6.0 == 0.6"
! lt 0.10.0 0.9.0 || fail "0.10 is newer"
! lt 0.6.0 0.6.0-beta.1 || fail "a release is newer than its prerelease"
! lt local 0.6.0 || fail "a version that does not parse is never older"

release() {
  cat >"$MOCK_STATE/release.json" <<JSON
{"url": "https://api.github.com/repos/askysh/benchbar/releases/1", "html_url": "https://github.com/askysh/benchbar/releases/tag/v$1", "tag_name": "v$1", "draft": false}
JSON
}
# the stub installer records its arguments and the app folder it was given
cat >"$MOCK_STATE/installer.sh" <<'SH'
printf 'args: %s\n' "$*" >>"$MOCK_STATE/installer.log"
printf 'app_dir: %s\n' "${BENCHBAR_APP_DIR:-}" >>"$MOCK_STATE/installer.log"
echo "stub installer ran"
SH
installer_log() { cat "$MOCK_STATE/installer.log" 2>/dev/null || true; }
app_at() {
  mkdir -p "$1/BenchBar.app/Contents"
  printf '<plist><dict>\n<key>CFBundleShortVersionString</key>\n<string>%s</string>\n</dict></plist>\n' "$2" >"$1/BenchBar.app/Contents/Info.plist"
}

# ---- --help lists it; its own help
run_fm --help; assert_contains "$OUT" "self-update"
run_fm self-update --help; assert_eq "0" "$CODE"; assert_contains "$OUT" "never runs"
run_fm self-update --bogus; assert_eq "1" "$CODE"; assert_contains "$OUT" "Unknown self-update option"

# ---- up to date: nothing runs
release "$VER"
reset_calls
run_fm self-update --yes; assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "BenchBar is up to date (${VER})"
assert_eq "" "$(installer_log)" "(no installer when up to date)"
assert_calls_contain "^curl .*--max-time 10 .*/releases/latest"

# ---- --check: this CLI (a git checkout: the repo itself) against 99.0.0
release 99.0.0
reset_calls
run_fm self-update --check; assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "CLI ${VER} at ${ROOT} (a git checkout)"
assert_contains "$OUT" "BenchBar app not installed"
assert_contains "$OUT" "latest release 99.0.0: https://github.com/askysh/benchbar/releases/tag/v99.0.0"
assert_contains "$OUT" "BenchBar 99.0.0 is available"
assert_contains "$OUT" "git -C ${ROOT} pull"
assert_calls_not_contain "install.sh"

# ---- --json: the same, as JSON, and never runs anything
run_fm self-update --json; assert_eq "0" "$CODE" "$OUT"
printf '%s' "$OUT" >"$TMP_DIR/su.json"
assert_eq "1" "$(jget "$TMP_DIR/su.json" 'd["schema_version"]')"
assert_eq "$VER" "$(jget "$TMP_DIR/su.json" 'd["cli_version"]')"
assert_eq "99.0.0" "$(jget "$TMP_DIR/su.json" 'd["latest"]')"
assert_eq "True" "$(jget "$TMP_DIR/su.json" 'd["update_available"]')"
assert_eq "checkout" "$(jget "$TMP_DIR/su.json" 'd["install"]')"
assert_eq "True" "$(jget "$TMP_DIR/su.json" 'd["app_only"]')"
assert_eq "None" "$(jget "$TMP_DIR/su.json" 'd["app_version"]')"
assert_eq "None" "$(jget "$TMP_DIR/su.json" 'd["error"]')"
assert_eq "curl -fsSL ${PINNED} | bash -s -- --yes --app-only --version v99.0.0" "$(jget "$TMP_DIR/su.json" 'd["command"]')"
assert_eq "" "$(installer_log)"

# ---- --dry-run: the plan, nothing runs
run_fm self-update --dry-run; assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "runs: curl -fsSL ${PINNED} | bash -s -- --yes --app-only --version v99.0.0"
assert_contains "$OUT" "dry-run: nothing was run"
assert_eq "" "$(installer_log)"

# ---- no terminal and no --yes: asks, the answer is no
run_fm self-update </dev/null; assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "Cancelled"
assert_eq "" "$(installer_log)"

# ---- a git checkout with --yes: the installer runs with --app-only
reset_calls
run_fm self-update --yes; assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "stub installer ran"
assert_eq "args: --yes --app-only --version v99.0.0" "$(installer_log | sed -n 1p)" "(the release that was shown, not whatever is latest later)"
assert_calls_contain "^curl -fsSL ${PINNED}$"
assert_calls_not_contain '^bench '
rm -f "$MOCK_STATE/installer.log"

# ---- a managed install (the CLI in BENCHBAR_HOME): CLI and app
reset_calls
export BENCHBAR_HOME="$ROOT"
run_fm self-update --json; assert_eq "managed" "$(printf '%s' "$OUT" | jget - 'd["install"]')"
assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["app_only"]')"
run_fm self-update --yes; assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "it pulls the CLI in ${ROOT}"
assert_eq "args: --yes --version v99.0.0" "$(installer_log | sed -n 1p)"
assert_eq "app_dir: " "$(installer_log | sed -n 2p)"
assert_calls_not_contain '^bench '
rm -f "$MOCK_STATE/installer.log"

# ---- an older app with a current CLI is an update too; an app in a writable
# folder other than ~/Applications is updated where it is
release "$VER"
export FL_APP_DIRS="$TMP_DIR/Apps:$HOME/Applications"
app_at "$TMP_DIR/Apps" 0.1.0
run_fm self-update --json
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["update_available"]')"
assert_eq "0.1.0" "$(printf '%s' "$OUT" | jget - 'd["app_version"]')"
assert_eq "$TMP_DIR/Apps" "$(printf '%s' "$OUT" | jget - 'd["app_dir"]')"
assert_contains "$(printf '%s' "$OUT" | jget - 'd["command"]')" "| BENCHBAR_APP_DIR=${TMP_DIR}/Apps bash -s -- --yes"
run_fm self-update --yes; assert_eq "0" "$CODE" "$OUT"
assert_eq "app_dir: $TMP_DIR/Apps" "$(installer_log | sed -n 2p)"
rm -f "$MOCK_STATE/installer.log"
# the app in ~/Applications: the installer's default, no BENCHBAR_APP_DIR
rm -rf "$TMP_DIR/Apps"; app_at "$HOME/Applications" 0.1.0
run_fm self-update --json
assert_eq "None" "$(printf '%s' "$OUT" | jget - 'd["app_dir"]')"
unset BENCHBAR_HOME

# ---- a CLI installed some other way (no .git, not BENCHBAR_HOME): app only
OTHER="$TMP_DIR/other-cli"; mkdir -p "$OTHER"
cp -R "$ROOT/benchbar" "$ROOT/lib" "$ROOT/templates" "$ROOT/config" "$OTHER/"
set +e; OUT="$("$OTHER/benchbar" self-update --json 2>&1)"; CODE=$?; set -e
assert_eq "0" "$CODE" "$OUT"
assert_eq "other" "$(printf '%s' "$OUT" | jget - 'd["install"]')"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["app_only"]')"
assert_contains "$OUT" "the way you installed it"

# ---- a CLI installed with Homebrew (a keg in the fake prefix, run by its
# opt path): brew upgrades it, the installer never runs, and the JSON keeps
# its fields with install "homebrew"
KEG="$MOCK_BREW_PREFIX/Cellar/benchbar/$VER"
mkdir -p "$KEG/libexec" "$KEG/bin"
cp -R "$ROOT/benchbar" "$ROOT/lib" "$ROOT/templates" "$ROOT/config" "$KEG/libexec/"
printf '#!/bin/bash\nexec "%s/opt/benchbar/libexec/benchbar" "$@"\n' "$MOCK_BREW_PREFIX" >"$KEG/bin/benchbar"
chmod +x "$KEG/bin/benchbar"
ln -sfn "../Cellar/benchbar/$VER" "$MOCK_BREW_PREFIX/opt/benchbar"
BREW_CLI="$MOCK_BREW_PREFIX/opt/benchbar/bin/benchbar"
run_brew_cli() { set +e; OUT="$("$BREW_CLI" "$@" 2>&1)"; CODE=$?; set -e; }
export FL_APP_DIRS="$TMP_DIR/Apps:$HOME/Applications"
rm -rf "$HOME/Applications/BenchBar.app"; app_at "$TMP_DIR/Apps" 0.1.0
release 99.0.0
rm -f "$MOCK_STATE/installer.log"
reset_calls
run_brew_cli self-update --json; assert_eq "0" "$CODE" "$OUT"
printf '%s' "$OUT" >"$TMP_DIR/su-brew.json"
assert_eq "homebrew" "$(jget "$TMP_DIR/su-brew.json" 'd["install"]')"
assert_eq "False" "$(jget "$TMP_DIR/su-brew.json" 'd["app_only"]')"
assert_eq "None" "$(jget "$TMP_DIR/su-brew.json" 'd["app_dir"]')"
assert_eq "True" "$(jget "$TMP_DIR/su-brew.json" 'd["update_available"]')"
assert_eq "brew upgrade askysh/tap/benchbar" "$(jget "$TMP_DIR/su-brew.json" 'd["command"]')"
assert_eq "$MOCK_BREW_PREFIX/opt/benchbar/libexec" "$(jget "$TMP_DIR/su-brew.json" 'd["cli_dir"]')"
assert_contains "$(jget "$TMP_DIR/su-brew.json" '" ".join(d["notes"])')" "the app at $TMP_DIR/Apps/BenchBar.app updates itself"
# the same keys as every other kind: a reader of 0.6.1 finds its fields
assert_eq "$(jget "$TMP_DIR/su.json" 'sorted(d)')" "$(jget "$TMP_DIR/su-brew.json" 'sorted(d)')"
assert_not_contains "$OUT" "/Cellar/"
# --dry-run and --check show the brew command and run nothing
run_brew_cli self-update --dry-run; assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "(installed with Homebrew)"
assert_contains "$OUT" "runs: brew upgrade askysh/tap/benchbar"
assert_contains "$OUT" "dry-run: nothing was run"
run_brew_cli self-update --check; assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "fix: benchbar self-update   (runs: brew upgrade askysh/tap/benchbar)"
assert_calls_not_contain '^brew upgrade'
# no terminal and no --yes: asks, the answer is no
run_brew_cli self-update </dev/null; assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "Upgrade benchbar to 99.0.0 with Homebrew now?"
assert_calls_not_contain '^brew upgrade'
# --yes hands over to brew: no installer, no curl but the release check
run_brew_cli self-update --yes; assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "==> Upgrading askysh/tap/benchbar"
assert_calls_contain '^brew upgrade askysh/tap/benchbar$'
assert_calls_not_contain 'install\.sh'
assert_eq "" "$(installer_log)" "(the installer never runs under Homebrew)"
# with Homebrew's cask the note names brew's cask command
mkdir -p "$MOCK_BREW_PREFIX/Caskroom/benchbar-app/0.1.0"
run_brew_cli self-update --json; assert_eq "0" "$CODE" "$OUT"
assert_contains "$(printf '%s' "$OUT" | jget - '" ".join(d["notes"])')" "brew upgrade --cask --greedy askysh/tap/benchbar-app"
assert_eq "brew upgrade askysh/tap/benchbar" "$(printf '%s' "$OUT" | jget - 'd["command"]')"
# a current CLI is up to date, even with an older app: the app is not
# this command's, so nothing runs and the note says how the app updates
release "$VER"
reset_calls
run_brew_cli self-update --yes; assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "the benchbar CLI is up to date (${VER})"
assert_contains "$OUT" "BenchBar app 0.1.0 is older than ${VER}"
assert_contains "$OUT" "brew upgrade --cask --greedy askysh/tap/benchbar-app"
assert_calls_not_contain '^brew upgrade'
run_brew_cli self-update --json
assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["update_available"]')"
rm -rf "$MOCK_BREW_PREFIX/Caskroom" "$TMP_DIR/Apps"
export FL_APP_DIRS="$HOME/Applications"
release 99.0.0

# ---- offline: exit 1 with the command to run later
rm -f "$MOCK_STATE/release.json"
run_fm self-update --check; assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "could not ask GitHub"
assert_contains "$OUT" "fix: try again later, or run it yourself: curl -fsSL ${INSTALLER}"
assert_not_contains "$OUT" "Last command failed"
run_fm self-update --json; assert_eq "1" "$CODE" "$OUT"
assert_eq "None" "$(printf '%s' "$OUT" | jget - 'd["latest"]')"
assert_eq "None" "$(printf '%s' "$OUT" | jget - 'd["update_available"]')"
assert_contains "$(printf '%s' "$OUT" | jget - 'd["error"]')" "could not ask GitHub"
assert_eq "" "$(installer_log)"

printf 'test-self-update: ok\n'
