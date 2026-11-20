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
  rm -f "$MOCK_STATE/release.zip"
  if command -v zip >/dev/null 2>&1; then
    (cd "$stage" && zip -q -r "$MOCK_STATE/release.zip" BenchBar.app)
  else
    # a Linux host without zip: the same archive from Python's zipfile
    (cd "$stage" && python3 -m zipfile -c "$MOCK_STATE/release.zip" BenchBar.app)
  fi
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
installed_app_version() { sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p' "$APP/Contents/Info.plist" 2>/dev/null | awk 'NR==1'; }

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

# ---- a release candidate is a GitHub pre-release: installed only when named.
# The default asks for "latest", which GitHub answers without pre-releases.
make_release 0.9.0-rc.1
reset_calls
run_install --yes --version 0.9.0-rc.1
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain 'releases/tags/v0.9.0-rc.1'
assert_eq "0.9.0-rc.1" "$(installed_app_version)"
make_release 0.3.0
reset_calls
run_install --yes
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain 'api.github.com/repos/askysh/benchbar/releases/latest'
assert_calls_not_contain 'releases/tags/|releases\?'
assert_eq "0.3.0" "$(installed_app_version)"

# ---- a tampered zip is refused and the installed app is left alone
make_release 0.5.0
printf 'evil\n' >>"$MOCK_STATE/release.zip"
run_install --yes
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "checksum mismatch"
assert_eq "0.3.0" "$(installed_app_version)"
make_release 0.5.0

# ---- the build provenance: gh signed in checks the zip, and a refusal stops the install
make_release 0.6.0
reset_calls
run_install --yes --app-only
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "build provenance verified (gh attestation verify)"
assert_calls_contain "^gh auth status"
assert_calls_contain "^gh attestation verify .*BenchBar-0.6.0.zip -R askysh/benchbar --signer-workflow askysh/benchbar/.github/workflows/release.yml$"
assert_contains "$OUT" "code signature valid (codesign --verify --deep --strict)"
assert_contains "$OUT" "Gatekeeper accepts the app: notarized (spctl --assess --type execute)"
assert_calls_contain '^codesign --verify --deep --strict .*/unpacked/BenchBar.app$'
assert_calls_contain '^spctl --assess --type execute .*/unpacked/BenchBar.app$'
assert_eq "0.6.0" "$(installed_app_version)"
# the new app was copied beside the old one and renamed over it: nothing left
assert_no_file "$APP.new"
assert_no_file "$APP.old"
# every download goes over https only, TLS 1.2 or newer
assert_calls_contain "^curl --proto =https --tlsv1.2 -fsSL .*releases/latest"
assert_calls_contain "^curl --proto =https --tlsv1.2 -fsSL --retry 3 -o .*BenchBar-0.6.0.zip "
assert_calls_not_contain '^curl -fsSL'

# 0.9.0 and later: a failed check stops the install
make_release 1.0.0
touch "$MOCK_STATE/gh_attest_fail"
reset_calls
run_install --yes --app-only
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "gh attestation verify did not accept BenchBar-1.0.0.zip"
assert_contains "$OUT" "no attestations found"
assert_contains "$OUT" "the build provenance of BenchBar-1.0.0.zip did not verify; nothing installed"
assert_eq "0.6.0" "$(installed_app_version)"
assert_calls_not_contain '^ditto'
# the same for 0.9.0 itself, and a release candidate of it
make_release 0.9.0
run_install --yes --app-only
assert_eq "1" "$CODE" "$OUT"
assert_eq "0.6.0" "$(installed_app_version)"
# before 0.9.0 no Mac file has an attestation: gh finds none (HTTP 404), so only
# the checksum is checked, and it says so
make_release 0.8.3
printf 'HTTP 404: Not Found (https://api.github.com/repos/askysh/benchbar/attestations/sha256:abc)' >"$MOCK_STATE/gh_attest_fail"
reset_calls
run_install --yes --app-only
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "v0.8.3 is older than 0.9.0, the first release with build provenance: only the checksum was checked"
assert_not_contains "$OUT" "build provenance verified"
assert_eq "0.8.3" "$(installed_app_version)" "$OUT"
# but any other gh error is still a refusal, also for an old release
printf 'verification failed: the signer workflow does not match' >"$MOCK_STATE/gh_attest_fail"
make_release 0.8.4
run_install --yes --app-only
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "signer workflow does not match"
assert_eq "0.8.3" "$(installed_app_version)"
rm -f "$MOCK_STATE/gh_attest_fail"
# the signer is pinned
assert_calls_contain '^gh attestation verify .* --signer-workflow askysh/benchbar/.github/workflows/release.yml$'
# a gh that does not answer: the fallback after the deadline, not a stall
touch "$MOCK_STATE/gh_hang"
make_release 0.9.2
reset_calls
BENCHBAR_ATTEST_TIMEOUT=2 run_install --yes --app-only
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "gh attestation verify did not answer within 2 s: only the checksum was checked"
assert_eq "0.9.2" "$(installed_app_version)" "$OUT"
rm -f "$MOCK_STATE/gh_hang"
make_release 0.7.0
make_release 0.6.0
run_install --yes --app-only --version v0.6.0
assert_eq "0.6.0" "$(installed_app_version)" "$OUT"

# gh signed out: only the checksum, and the command to run by hand
make_release 0.7.0
touch "$MOCK_STATE/gh_signed_out"
reset_calls
run_install --yes --app-only
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "gh is not signed in (gh auth login): only the checksum was checked, not where the file was built"
assert_contains "$OUT" "to check by hand: gh attestation verify BenchBar-0.7.0.zip -R askysh/benchbar --signer-workflow askysh/benchbar/.github/workflows/release.yml"
assert_not_contains "$OUT" "build provenance verified"
assert_calls_not_contain '^gh attestation verify'
assert_eq "0.7.0" "$(installed_app_version)"
rm -f "$MOCK_STATE/gh_signed_out"

# no gh at all: a PATH with every other command (the host's gh left out)
mkdir -p "$TMP_DIR/nogh"
for m in /usr/bin/* /bin/*; do [[ "${m##*/}" == gh ]] || ln -sf "$m" "$TMP_DIR/nogh/${m##*/}" 2>/dev/null || true; done
for m in "$ROOT"/tests/mocks/bin/*; do [[ "$(basename "$m")" == gh ]] || ln -sf "$m" "$TMP_DIR/nogh/$(basename "$m")"; done
make_release 0.8.0
reset_calls
PATH="$TMP_DIR/nogh" run_install --yes --app-only
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "gh (the GitHub CLI) is not installed: only the checksum was checked, not where the file was built"
assert_contains "$OUT" "to check by hand: gh attestation verify BenchBar-0.8.0.zip -R askysh/benchbar --signer-workflow askysh/benchbar/.github/workflows/release.yml"
assert_eq "0.8.0" "$(installed_app_version)"

# the signature: codesign or Gatekeeper refuses, and the old app stays
make_release 0.9.0
touch "$MOCK_STATE/codesign_fail"
reset_calls
run_install --yes --app-only
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "codesign --verify --deep --strict refused the app"
assert_contains "$OUT" "the unpacked app did not pass the signature check; nothing installed"
assert_eq "0.8.0" "$(installed_app_version)"
assert_calls_not_contain '^spctl'
rm -f "$MOCK_STATE/codesign_fail"
touch "$MOCK_STATE/spctl_fail"
run_install --yes --app-only
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "spctl --assess --type execute refused the app (not notarized"
assert_eq "0.8.0" "$(installed_app_version)"
rm -f "$MOCK_STATE/spctl_fail"

# the running app is quit only after the checks passed: a refused app leaves it running
add_proc 779 "BenchBar"
touch "$MOCK_STATE/codesign_fail"
reset_calls
run_install --yes --app-only
assert_eq "1" "$CODE" "$OUT"
assert_calls_not_contain '^osascript'
assert_calls_not_contain '^pkill'
assert_calls_not_contain '^ditto .*\.app\.new'
rm -f "$MOCK_STATE/codesign_fail"
reset_calls
run_install --yes --app-only
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^osascript .*to quit'
# and the quit comes after the signature check in the call order
cs="$(grep -n -m1 '^codesign ' "$MOCK_LOG" | cut -d: -f1)"; qt="$(grep -n -m1 '^osascript .*to quit' "$MOCK_LOG" | cut -d: -f1)"
[[ -n "$cs" && -n "$qt" && "$cs" -lt "$qt" ]] || fail "codesign (line ${cs:-none}) must run before the running app is quit (line ${qt:-none})"

# the copy beside the app fails: the old app is as it was, and no half copy stays.
# The run above installed 0.9.0, and the same version is "unchanged", so put 0.8.0 back first.
make_release 0.8.0
run_install --yes --app-only --version v0.8.0
assert_eq "0.8.0" "$(installed_app_version)" "$OUT"
make_release 0.9.0
touch "$MOCK_STATE/ditto_fail_new"
run_install --yes --app-only
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "could not put the app into ${HOME}/Applications; the old app is as it was"
assert_eq "0.8.0" "$(installed_app_version)"
assert_no_file "$APP.new"
rm -f "$MOCK_STATE/ditto_fail_new"
# a stale copy from a run that died is replaced
mkdir -p "$APP.new" "$APP.old"; printf 'stale\n' >"$APP.new/stale"
run_install --yes --app-only
assert_eq "0" "$CODE" "$OUT"
assert_eq "0.9.0" "$(installed_app_version)" "$OUT"
assert_no_file "$APP.new"
assert_no_file "$APP.old"

# ---- --help reads its text from the script, not from $0: it works through a pipe
set +e; OUT="$(bash -s -- --help <"$INSTALL" 2>&1)"; CODE=$?; set -e
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "the one line installer"
assert_contains "$OUT" "gh attestation verify, pinned to this repository's release workflow"
assert_contains "$OUT" "curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash"

# ---- a download that is cut short runs nothing: everything is in main, called on the last line
reset_calls
snap_before="$(snapshot "$HOME")"
last="$(grep -n '^main "\$@"$' "$INSTALL" | cut -d: -f1)"
assert_eq "$(wc -l <"$INSTALL" | tr -d ' ')" "$last" "(main is called on the last line)"
set +e; OUT="$(head -n "$((last - 1))" "$INSTALL" | bash -s -- --yes 2>&1)"; CODE=$?; set -e
assert_eq "0" "$CODE" "$OUT"
assert_not_contains "$OUT" "BenchBar installer"
set +e; OUT="$(head -c 30000 "$INSTALL" | bash -s -- --yes 2>&1)"; CODE=$?; set -e
assert_not_contains "$OUT" "BenchBar installer"
assert_calls_not_contain '^(git|curl|ditto|gh|codesign|spctl) '
assert_eq "$snap_before" "$(snapshot "$HOME")" "(a cut download writes nothing)"

# ---- --uninstall --yes removes BENCHBAR_HOME only when it holds benchbar and .git
mkdir -p "$TMP_DIR/not-ours/docs"; printf 'mine\n' >"$TMP_DIR/not-ours/docs/notes"
BENCHBAR_HOME="$TMP_DIR/not-ours" run_install --uninstall --yes
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "${TMP_DIR}/not-ours does not hold benchbar and .git, so it is not a BenchBar checkout; kept it"
assert_file "$TMP_DIR/not-ours/docs/notes"
mkdir -p "$TMP_DIR/half/.git"
BENCHBAR_HOME="$TMP_DIR/half" run_install --uninstall --yes
assert_contains "$OUT" "does not hold benchbar and .git"
assert_file "$TMP_DIR/half/.git"
# those uninstalls took the app and the PATH block: put them back for what follows
run_install --yes --app-only
assert_eq "0.9.0" "$(installed_app_version)" "$OUT"

# ---- --no-app and --app-only
reset_calls
run_install --yes --no-app
assert_eq "0" "$CODE" "$OUT"
assert_not_contains "$OUT" "==> BenchBar app"
assert_eq "0.9.0" "$(installed_app_version)"
make_release 0.5.0
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

# ---- macOS 13: the app needs 14, so only the CLI is installed, with a warning
MOCK_SW_VERS=13.6.1 run_install --yes
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "macOS 13.6.1 is older than 14 (Sonoma)"
assert_not_contains "$OUT" "==> BenchBar app"
assert_no_file "$APP"
# macOS 14 and a two digit major version are fine
MOCK_SW_VERS=14.0 run_install --yes --dry-run
assert_not_contains "$OUT" "older than 14"
MOCK_SW_VERS=26.1 run_install --yes --dry-run
assert_not_contains "$OUT" "older than 14"

# ---- a fish user gets the PATH line to run; a bash user on a Mac the line for ~/.bash_profile
SHELL=/opt/homebrew/bin/fish run_install --yes --no-app
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "fish_add_path ${HOME}/.local/bin"
SHELL=/bin/bash run_install --yes --no-app
assert_contains "$OUT" "add this line to ~/.bash_profile: export PATH=\"\$HOME/.local/bin:\$PATH\""
SHELL=/bin/zsh run_install --yes --no-app
assert_not_contains "$OUT" "fish_add_path"
assert_not_contains "$OUT" "bash_profile"

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

# ---- the other volume layout: the state stayed in the checkout and
# ~/.local/state/benchbar is a link to it. Removing the checkout would take
# the state with it, so the checkout is kept, with the reason
rm -rf "$STATE_DIR"
mkdir -p "$CLI_HOME/.benchbar/backups"; printf 'BENCH_DIR=%s\n' "$BENCH" >"$CLI_HOME/.benchbar/state.env"
cp "$ROOT/benchbar" "$CLI_HOME/benchbar"
ln -s "$CLI_HOME/.benchbar" "$STATE_DIR"
run_install --uninstall --dry-run --yes
assert_eq "0" "$CODE" "$OUT"
assert_not_contains "$OUT" "rm -rf ${CLI_HOME}"
assert_contains "$OUT" "${STATE_DIR} leads to ${CLI_HOME}/.benchbar"
run_install --uninstall --yes
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "${STATE_DIR} leads to ${CLI_HOME}/.benchbar, which holds the state"
assert_contains "$OUT" "kept ${CLI_HOME}"
assert_file "$CLI_HOME/.benchbar/state.env"
assert_eq "BENCH_DIR=$BENCH" "$(cat "$CLI_HOME/.benchbar/state.env")"
[[ -L "$STATE_DIR" ]] || fail "the link to the state must stay"
rm "$STATE_DIR"; rm -rf "$CLI_HOME"

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
