#!/usr/bin/env bash
# install.sh against a fake HOME with mocked git, curl, brew, ditto and the
# GitHub release API: fresh install, a rerun that changes nothing, an app
# upgrade, no release, --no-app, --app-only, --dry-run, a bad checksum and
# --uninstall.
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

# ---- dry-run writes nothing, even from scratch
rm -rf "$CLI_HOME" "$APP" "$HOME/.local/bin/benchbar" "$HOME/.local/bin/frappe-mac"
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

# ---- --uninstall: app, links and block go; agents are offered; benches stay
run_install --yes --app-only
assert_file "$APP"
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
# again: nothing left
run_install --uninstall --yes
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "nothing to remove (unchanged)"

# ---- help and a bad flag
run_install --help; assert_eq "0" "$CODE"; assert_contains "$OUT" "the one line installer"
run_install --bogus; assert_eq "1" "$CODE"; assert_contains "$OUT" "Unknown option"

printf 'test-install-sh: ok\n'
