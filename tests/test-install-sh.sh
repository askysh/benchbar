#!/usr/bin/env bash
# install.sh against a fake HOME with mocked git, curl, brew, ditto and the
# GitHub release API: fresh install, a rerun that changes nothing, an app
# upgrade, no release, --no-app, --app-only, --dry-run, a bad checksum, a
# checkout on a detached HEAD, --uninstall (the moved state stays), and the
# halves Homebrew owns (the benchbar formula, the benchbar-app cask).
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

export MOCK_REPO_ROOT="$ROOT"
INSTALL="$ROOT/install.sh"
CLI_HOME="$HOME/.local/share/benchbar"
APP="$HOME/Applications/BenchBar.app"
run_install() { set +e; OUT="$(bash "$INSTALL" "$@" 2>&1 </dev/null)"; CODE=$?; set -e; }

# a fake release: BenchBar-<version>.zip plus SHA256SUMS, served by the curl mock
make_release() {
  local version="$1" stage
  stage="$TMP_DIR/release-$version"
  rm -rf "$stage"; mkdir -p "$stage/BenchBar.app/Contents/MacOS"
  printf '<plist><dict>\n<key>CFBundleShortVersionString</key>\n<string>%s</string>\n</dict></plist>\n' "$version" >"$stage/BenchBar.app/Contents/Info.plist"
  printf '#!/bin/sh\necho BenchBar %s\n' "$version" >"$stage/BenchBar.app/Contents/MacOS/BenchBar"
  (cd "$stage" && zip -q -r "$MOCK_STATE/release.zip" BenchBar.app)
  printf '%s  BenchBar-%s.zip\n' "$(shasum -a 256 "$MOCK_STATE/release.zip" | awk '{print $1}')" "$version" >"$MOCK_STATE/release.sums"
  cat >"$MOCK_STATE/release.json" <<JSON
{
  "tag_name": "v${version}",
  "name": "BenchBar ${version}",
  "assets": [
    {"name": "BenchBar-${version}.dmg", "browser_download_url": "https://github.com/askysh/benchbar/releases/download/v${version}/BenchBar-${version}.dmg"},
    {"name": "BenchBar-${version}.zip", "browser_download_url": "https://github.com/askysh/benchbar/releases/download/v${version}/BenchBar-${version}.zip"},
    {"name": "SHA256SUMS", "browser_download_url": "https://github.com/askysh/benchbar/releases/download/v${version}/SHA256SUMS"}
  ]
}
JSON
}
installed_app_version() { sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p' "$APP/Contents/Info.plist" 2>/dev/null | head -n1; }

# ---- no release yet: CLI installed, app skipped with a clear message
run_install --yes
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "Plan:"
assert_contains "$OUT" "never runs sudo"
assert_contains "$OUT" "[OK] macOS"
assert_contains "$OUT" "[OK] Apple Silicon"
assert_contains "$OUT" "[OK] Homebrew"
assert_contains "$OUT" "CLI cloned into ${CLI_HOME}"
assert_file "$CLI_HOME/benchbar"
assert_eq "$CLI_HOME/benchbar" "$(readlink "$HOME/.local/bin/benchbar")"
assert_eq "$CLI_HOME/benchbar" "$(readlink "$HOME/.local/bin/frappe-mac")"
grep -q -x -F "# >>> benchbar-path >>>" "$HOME/.zshrc" || fail "PATH block expected"
grep -q 'export EDITOR=vim' "$HOME/.zshrc" || fail "existing rc content must survive"
assert_contains "$OUT" "no BenchBar release on GitHub yet; the app is skipped"
assert_no_file "$APP"
assert_contains "$OUT" "no bench found"
assert_contains "$OUT" "run: benchbar install"
assert_calls_not_contain '^sudo'
assert_calls_not_contain "^git clone.*${CLI_HOME}.*\n.*git clone" "(one clone)"

# ---- a release appears: rerun installs the app, CLI unchanged
make_release 0.3.0
reset_calls
run_install --yes
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "CLI at ${CLI_HOME} (abc1234) (unchanged)"
assert_contains "$OUT" "${HOME}/.local/bin/benchbar (unchanged)"
assert_contains "$OUT" "PATH block in ${HOME}/.zshrc (unchanged)"
assert_contains "$OUT" "sha256 verified against SHA256SUMS"
assert_contains "$OUT" "BenchBar 0.3.0 installed"
assert_eq "0.3.0" "$(installed_app_version)"
assert_calls_contain '^ditto -x -k .*BenchBar-0.3.0.zip'
assert_eq "1" "$(grep -c -x -F "# >>> benchbar-path >>>" "$HOME/.zshrc")" "(one PATH block)"

# ---- rerun: everything unchanged, nothing downloaded
reset_calls
snap_before="$(snapshot "$HOME")"
sleep 1
run_install --yes
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "BenchBar 0.3.0 in ${HOME}/Applications (unchanged)"
assert_contains "$OUT" "everything was already in place (unchanged)"
assert_eq "$snap_before" "$(snapshot "$HOME")" "(a rerun must write nothing)"
assert_calls_not_contain '^curl .*\.zip'
assert_calls_not_contain '^ditto'

# ---- upgrade: a newer release and a CLI update; the running app is quit first
make_release 0.4.0
touch "$MOCK_STATE/git_update"
add_proc 777 "BenchBar"
reset_calls
run_install --yes
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "CLI updated abc1234 to def5678"
assert_contains "$OUT" "BenchBar 0.3.0 installed, release 0.4.0 available"
assert_contains "$OUT" "quitting the running BenchBar"
assert_calls_contain '^osascript .*to quit'
assert_contains "$OUT" "BenchBar 0.4.0 installed"
assert_eq "0.4.0" "$(installed_app_version)"

# ---- pin a version
make_release 0.3.0
run_install --yes --version v0.3.0
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain 'releases/tags/v0.3.0'
assert_eq "0.3.0" "$(installed_app_version)"
run_install --yes --version 0.3.0
assert_contains "$OUT" "BenchBar 0.3.0 in ${HOME}/Applications (unchanged)"

# ---- a tampered zip is refused and the installed app is left alone
make_release 0.5.0
printf 'evil\n' >>"$MOCK_STATE/release.zip"
run_install --yes
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "checksum mismatch"
assert_eq "0.3.0" "$(installed_app_version)"
make_release 0.5.0

# ---- --no-app and --app-only
reset_calls
run_install --yes --no-app
assert_eq "0" "$CODE" "$OUT"
assert_not_contains "$OUT" "==> BenchBar app"
assert_eq "0.3.0" "$(installed_app_version)"
run_install --yes --app-only
assert_eq "0" "$CODE" "$OUT"
assert_not_contains "$OUT" "==> Command line tool"
assert_not_contains "$OUT" "[OK] Xcode Command Line Tools"
assert_not_contains "$OUT" "[OK] Homebrew"
assert_not_contains "$OUT" "Homebrew's installer"
assert_contains "$OUT" "app only: skipping"
assert_eq "0.5.0" "$(installed_app_version)"

# a custom bin folder goes into the PATH block, spelled with $HOME when it is under it
BENCHBAR_BIN_DIR="$HOME/bin" run_install --yes --no-app
assert_eq "0" "$CODE" "$OUT"
assert_eq "$CLI_HOME/benchbar" "$(readlink "$HOME/bin/benchbar")"
grep -q -F "export PATH=\"\$HOME/bin:\$PATH\"" "$HOME/.zshrc" || fail "PATH block must name the configured bin folder"
BENCHBAR_BIN_DIR="$HOME/bin" run_install --yes --no-app
assert_contains "$OUT" "PATH block in ${HOME}/.zshrc (unchanged)"
rm -f "$HOME/bin/benchbar" "$HOME/bin/frappe-mac"
run_install --yes --no-app
grep -q -F "export PATH=\"\$HOME/.local/bin:\$PATH\"" "$HOME/.zshrc" || fail "PATH block must follow the bin folder back"

# ---- a clean checkout on a detached HEAD (a tag checked out by hand) goes
# back to main before the pull; untracked files, such as the symlink a 0.7
# CLI leaves for its moved state, are not changes
printf 'abc1234\n' >"$CLI_HOME/.git/HEAD"
printf '?? .benchbar\n' >"$CLI_HOME/.git/untracked"
run_install --dry-run --no-app
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "dry-run: git -C ${CLI_HOME} checkout --quiet main   (it is on a detached HEAD)"
assert_eq "abc1234" "$(cat "$CLI_HOME/.git/HEAD")" "(dry-run switches nothing)"
reset_calls
run_install --yes --no-app
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "${CLI_HOME} was on a detached HEAD ($(cat "$MOCK_STATE/git_head")); switched back to main"
assert_eq "ref: refs/heads/main" "$(cat "$CLI_HOME/.git/HEAD")"
assert_calls_contain "^git -C ${CLI_HOME} checkout --quiet main$"
assert_calls_contain "^git -C ${CLI_HOME} pull --ff-only$"
# on a branch: no checkout
reset_calls
run_install --yes --no-app
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain ' checkout '
# a detached checkout with changes is left alone: the pull fails as before
printf 'abc1234\n' >"$CLI_HOME/.git/HEAD"; printf ' M benchbar\n' >"$CLI_HOME/.git/dirty"
reset_calls
run_install --yes --no-app
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "git pull failed in ${CLI_HOME}"
assert_contains "$OUT" "fix the checkout (uncommitted changes?) or move it aside"
assert_calls_not_contain ' checkout '
assert_eq "abc1234" "$(cat "$CLI_HOME/.git/HEAD")"
rm -f "$CLI_HOME/.git/dirty" "$CLI_HOME/.git/untracked"
printf 'ref: refs/heads/main\n' >"$CLI_HOME/.git/HEAD"

# ---- dry-run writes nothing, even from scratch
rm -rf "$CLI_HOME" "$APP" "$HOME/.local/bin/benchbar" "$HOME/.local/bin/frappe-mac"
# a symlinked ~/.zshrc (a dotfiles repo): the PATH block lands in the target, the link stays
REAL_RC="$HOME/dotfiles/zshrc"; mkdir -p "$HOME/dotfiles"; printf 'export FROM_DOTFILES=1\n' >"$REAL_RC"
rm -f "$HOME/.zshrc"; ln -s "$REAL_RC" "$HOME/.zshrc"
run_install --yes
assert_eq "0" "$CODE" "$OUT"
[[ -L "$HOME/.zshrc" ]] || fail "install.sh must keep ~/.zshrc a symlink"
grep -q -x -F "# >>> benchbar-path >>>" "$REAL_RC" || fail "the PATH block must land in the symlink's target"
grep -q '^export FROM_DOTFILES=1$' "$REAL_RC" || fail "the target's own content must survive"
run_install --uninstall --yes
assert_eq "0" "$CODE" "$OUT"
[[ -L "$HOME/.zshrc" ]] || fail "the uninstall must keep the symlink too"
! grep -q -F "# >>> benchbar-path >>>" "$REAL_RC" || fail "the PATH block must be removed from the target"
rm -f "$HOME/.zshrc"
# ZDOTDIR names the rc file
mkdir -p "$HOME/zdot"
ZDOTDIR="$HOME/zdot" run_install --yes
assert_eq "0" "$CODE" "$OUT"
grep -q -x -F "# >>> benchbar-path >>>" "$HOME/zdot/.zshrc" || fail "with ZDOTDIR the block goes to \$ZDOTDIR/.zshrc"
ZDOTDIR="$HOME/zdot" run_install --uninstall --yes
printf '# fresh\n' >"$HOME/.zshrc"
snap_before="$(snapshot "$HOME")"
run_install --dry-run
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "dry-run: git clone"
assert_contains "$OUT" "dry-run: would download"
assert_contains "$OUT" "dry-run finished; nothing was changed"
assert_eq "$snap_before" "$(snapshot "$HOME")" "(dry-run must write nothing)"
assert_no_file "$CLI_HOME"

# ---- an existing bench is offered to adopt; with --yes it is adopted
BENCH="$HOME/frappe-bench"; make_fake_bench "$BENCH"
run_install --yes --no-app
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "found a bench at ${BENCH}"
assert_contains "$OUT" "benchbar adopt"
assert_file "$BENCH/Procfile.lean"
assert_file "$HOME/Library/LaunchAgents/com.benchbar.frappe-bench.plist"
assert_calls_not_contain '^bench (migrate|build|update)'
# without --yes and without a terminal adopt shows its plan and stops
rm -f "$BENCH/Procfile.lean"
run_install --no-app
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "write Procfile.lean"
assert_contains "$OUT" "Cancelled. Nothing was changed."
assert_contains "$OUT" "later: benchbar adopt ${BENCH} --yes"
assert_no_file "$BENCH/Procfile.lean"

# ---- an update with --yes (the CLI was already there) adopts nothing
reset_calls
run_install --yes --no-app
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "update with --yes: no bench is adopted or installed"
assert_no_file "$BENCH/Procfile.lean"
# and never offers the Homebrew installer (the one step that asks for a password)
mkdir -p "$TMP_DIR/nobrew"
for m in "$ROOT"/tests/mocks/bin/*; do [[ "$(basename "$m")" == brew ]] || ln -sf "$m" "$TMP_DIR/nobrew/"; done
PATH="$TMP_DIR/nobrew:/usr/bin:/bin:/usr/sbin:/sbin" run_install --yes --no-app
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "an update with --yes never runs the Homebrew installer"
assert_calls_not_contain 'Homebrew/install'

# ---- Intel Mac: CLI only, with a warning
cat >"$TMP_DIR/uname-intel" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in -m) echo x86_64 ;; *) echo Darwin ;; esac
SH
chmod +x "$TMP_DIR/uname-intel"; mkdir -p "$TMP_DIR/intel"; cp "$TMP_DIR/uname-intel" "$TMP_DIR/intel/uname"
PATH="$TMP_DIR/intel:$PATH" run_install --yes
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "Intel Mac"
assert_not_contains "$OUT" "==> BenchBar app"

# ---- --uninstall --dry-run: the whole plan, nothing removed, the app keeps running
run_install --yes --app-only
assert_file "$APP"
add_proc 778 "BenchBar"
# a 0.7 CLI's state is outside the checkout, behind a symlink in it
STATE_DIR="$HOME/.local/state/benchbar"
mkdir -p "$STATE_DIR/logs"; printf 'a run\n' >"$STATE_DIR/logs/20261001-120000.log"
ln -s "$STATE_DIR" "$CLI_HOME/.benchbar"
reset_calls
snap_before="$(snapshot "$HOME")"
run_install --uninstall --dry-run --yes
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "dry-run: would quit the running BenchBar"
assert_contains "$OUT" "dry-run: rm -rf ${APP}"
assert_contains "$OUT" "uninstall-service --bench-dir ${BENCH} --yes"
assert_contains "$OUT" "dry-run: rm -rf ${CLI_HOME}"
assert_contains "$OUT" "dry-run finished; nothing was removed"
assert_not_contains "$OUT" "BenchBar removed"
assert_eq "$snap_before" "$(snapshot "$HOME")" "(uninstall dry-run must write nothing)"
assert_file "$APP"
assert_file "$HOME/.local/bin/benchbar"
assert_file "$HOME/Library/LaunchAgents/com.benchbar.frappe-bench.plist"
assert_file "$CLI_HOME/benchbar"
assert_calls_not_contain '^(osascript|pkill|launchctl)'

# ---- --uninstall: app, links and block go; agents are offered; benches stay
reset_calls
run_install --uninstall --yes
assert_eq "0" "$CODE" "$OUT"
assert_no_file "$APP"
assert_no_file "$HOME/.local/bin/benchbar"
assert_no_file "$HOME/.local/bin/frappe-mac"
! grep -q -F "# >>> benchbar-path >>>" "$HOME/.zshrc" || fail "PATH block must be removed"
assert_contains "$OUT" "agent com.benchbar.frappe-bench runs the bench at ${BENCH}"
assert_no_file "$HOME/Library/LaunchAgents/com.benchbar.frappe-bench.plist"
assert_no_file "$CLI_HOME"
assert_file "$BENCH/sites/macdev/site_config.json"
assert_file "$BENCH/apps/frappe"
assert_contains "$OUT" "BenchBar removed"
# the state stays where it is, named, with what it holds
assert_contains "$OUT" "${CLI_HOME} holds the CLI; its logs, backups and remembered benches are in ${STATE_DIR}"
assert_contains "$OUT" "kept ${STATE_DIR} (logs, backups, the remembered benches)"
assert_eq "a run" "$(cat "$STATE_DIR/logs/20261001-120000.log")"
# again: nothing left
run_install --uninstall --yes
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "nothing to remove (unchanged)"

# ---- Homebrew has the CLI (the formula) and the app (the cask): this
# installer leaves both halves to brew, says how to update them, writes
# nothing and exits 0
mkdir -p "$MOCK_BREW_PREFIX/Cellar/benchbar/0.7.0/bin" "$MOCK_BREW_PREFIX/Caskroom/benchbar-app/0.7.0"
ln -sfn ../Cellar/benchbar/0.7.0 "$MOCK_BREW_PREFIX/opt/benchbar"
reset_calls
snap_before="$(snapshot "$HOME")"
run_install --yes
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "the benchbar CLI is installed with Homebrew (${MOCK_BREW_PREFIX}/opt/benchbar); this installer leaves it to brew"
assert_contains "$OUT" "update it with: brew upgrade askysh/tap/benchbar"
assert_contains "$OUT" "the BenchBar app is installed with Homebrew (cask benchbar-app); it updates itself"
assert_contains "$OUT" "or with brew: brew upgrade askysh/tap/benchbar-app"
assert_contains "$OUT" "nothing for this installer to do"
assert_not_contains "$OUT" "Plan:"
assert_not_contains "$OUT" " repair"
assert_eq "$snap_before" "$(snapshot "$HOME")" "(nothing written next to Homebrew's copies)"
assert_no_file "$CLI_HOME"
assert_calls_not_contain '^(git|curl|ditto) '
# an old app's Update Now runs the newest installer with --app-only: the
# cask's app is left alone; a dry run says the same
run_install --yes --app-only --version v0.5.0
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "the BenchBar app is installed with Homebrew"
assert_not_contains "$OUT" "the benchbar CLI is installed with Homebrew"
run_install --dry-run
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "nothing for this installer to do"
assert_calls_not_contain '^(git|curl|ditto) '
assert_eq "$snap_before" "$(snapshot "$HOME")"

# the formula alone: the CLI half is brew's, the app half still runs
rm -rf "$MOCK_BREW_PREFIX/Caskroom"
reset_calls
run_install --yes
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "the benchbar CLI is installed with Homebrew"
assert_contains "$OUT" "BenchBar 0.5.0 installed"
assert_not_contains "$OUT" "==> Command line tool"
assert_not_contains "$OUT" "==> Your bench"
assert_no_file "$CLI_HOME"
assert_no_file "$HOME/.local/bin/benchbar"
! grep -q -F "# >>> benchbar-path >>>" "$HOME/.zshrc" || fail "no PATH block next to Homebrew's CLI"
assert_calls_not_contain '^git '

# the one line installer's copy is still here: the repair line that hands
# over to Homebrew's CLI, and the copy is neither pulled nor linked
mkdir -p "$CLI_HOME/.git"; cp "$ROOT/benchbar" "$CLI_HOME/benchbar"
reset_calls
run_install --yes --no-app
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "${MOCK_BREW_PREFIX}/opt/benchbar/bin/benchbar repair   (moves the state, points ~/.local/bin at it, rewrites the helper block)"
assert_calls_not_contain '^git '

# --uninstall before Homebrew's CLI ever ran: the checkout's own state is
# not deleted with it. With Homebrew's state already there, never merged:
# the checkout stays
mkdir -p "$MOCK_BREW_PREFIX/Caskroom/benchbar-app/0.7.0" "$STATE_DIR" "$CLI_HOME/.benchbar/backups"
printf 'BENCH_DIR=%s\n' "$BENCH" >"$CLI_HOME/.benchbar/state.env"
run_install --uninstall --yes
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "Homebrew's benchbar already has its own in ${STATE_DIR}; kept ${CLI_HOME}"
assert_file "$CLI_HOME/.benchbar/state.env"
# without it, the state moves where Homebrew's CLI reads it, then the checkout goes
rm -rf "$STATE_DIR"
run_install --uninstall --yes
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "moved ${CLI_HOME}/.benchbar to ${STATE_DIR}"
assert_eq "BENCH_DIR=$BENCH" "$(cat "$STATE_DIR/state.env")"
assert_file "$STATE_DIR/backups"
[[ -z "$(find "$HOME/.local/state" -name '.benchbar-moving.*')" ]] || fail "no folder left half way"
assert_contains "$OUT" "kept ${STATE_DIR}: Homebrew's benchbar uses it"
assert_contains "$OUT" "Homebrew's copies stay"
assert_contains "$OUT" "benchbar uninstall-service --all, then: brew uninstall benchbar"
assert_contains "$OUT" "brew uninstall --cask benchbar-app"
assert_no_file "$CLI_HOME"
assert_file "$MOCK_BREW_PREFIX/opt/benchbar"
assert_file "$STATE_DIR"
rm -rf "$MOCK_BREW_PREFIX/Caskroom" "$MOCK_BREW_PREFIX/Cellar" "$MOCK_BREW_PREFIX/opt/benchbar"

# ---- help and a bad flag
run_install --help; assert_eq "0" "$CODE"; assert_contains "$OUT" "the one line installer"
run_install --bogus; assert_eq "1" "$CODE"; assert_contains "$OUT" "Unknown option"

printf 'test-install-sh: ok\n'
