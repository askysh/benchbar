#!/usr/bin/env bash
# install.sh on Linux (Ubuntu 24.04, WSL) against a fake HOME with a mocked
# git: the CLI half only, no sudo, no app, no questions (no TTY and
# BENCHBAR_NONINTERACTIVE=1), the PATH block in ~/.bashrc, a rerun that writes
# nothing, a pinned release, a missing git named with its apt command,
# --app-only refused, --dry-run and --uninstall.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
use_linux

export MOCK_REPO_ROOT="$ROOT"
INSTALL="$ROOT/install.sh"
CLI_HOME="$HOME/.local/share/benchbar"
run_install() { set +e; OUT="$(bash "$INSTALL" "$@" 2>&1 </dev/null)"; CODE=$?; set -e; }
fresh() {
  rm -rf "$CLI_HOME" "$HOME/.local/bin/benchbar"
  printf '# test bashrc\nexport EDITOR=vim\n' >"$HOME/.bashrc"
  reset_calls
}

# ---- fresh install, nothing asked
run_install
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "[OK] Ubuntu 24.04"
assert_contains "$OUT" "[OK] WSL"
assert_contains "$OUT" "never runs sudo"
assert_contains "$OUT" "CLI cloned into ${CLI_HOME}"
assert_not_contains "$OUT" "macOS"
assert_not_contains "$OUT" "Homebrew"
assert_not_contains "$OUT" "BenchBar app"
assert_file "$CLI_HOME/benchbar"
assert_eq "$CLI_HOME/benchbar" "$(readlink "$HOME/.local/bin/benchbar")"
assert_no_file "$HOME/.local/bin/frappe-mac"
assert_no_file "$HOME/Applications"
grep -q -x -F "# >>> benchbar-path >>>" "$HOME/.bashrc" || fail "PATH block expected in ~/.bashrc"
grep -q 'export EDITOR=vim' "$HOME/.bashrc" || fail "existing rc content must survive"
assert_contains "$OUT" "no bench found"
assert_contains "$OUT" "next: open a new terminal and run: benchbar install"
assert_contains "$OUT" "BenchBar tray on Windows"
assert_contains "$OUT" "source ${HOME}/.bashrc"
assert_calls_not_contain '^sudo'
assert_calls_not_contain '^apt'
assert_calls_not_contain '^curl'

# ---- BENCHBAR_NONINTERACTIVE=1 and a pipe, as the tray runs it
fresh
set +e; OUT="$(BENCHBAR_NONINTERACTIVE=1 bash -s -- <"$INSTALL" 2>&1)"; CODE=$?; set -e
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "CLI cloned into ${CLI_HOME}"
assert_contains "$OUT" "next: open a new terminal and run: benchbar install"
assert_eq "1" "$(grep -c -x -F "# >>> benchbar-path >>>" "$HOME/.bashrc")" "(one PATH block)"

# ---- rerun: unchanged, nothing written
reset_calls
snap_before="$(snapshot "$HOME")"
sleep 1
run_install
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "CLI at ${CLI_HOME} (abc1234) (unchanged)"
assert_contains "$OUT" "${HOME}/.local/bin/benchbar (unchanged)"
assert_contains "$OUT" "PATH block in ${HOME}/.bashrc (unchanged)"
assert_contains "$OUT" "everything was already in place (unchanged)"
assert_eq "$snap_before" "$(snapshot "$HOME")" "(a rerun must write nothing)"

# ---- an update pulls
touch "$MOCK_STATE/git_update"
run_install
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "CLI updated abc1234 to def5678"

# ---- --yes and --no-app are accepted, --app-only has nothing to do
run_install --yes --no-app
assert_eq "0" "$CODE" "$OUT"
run_install --app-only
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "there is no BenchBar app on Linux"

# ---- a pinned release: detached, idempotent, and a run without it goes back to main
fresh
run_install --version 0.8.1
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "CLI v0.8.1 cloned into ${CLI_HOME}"
assert_calls_contain '^git clone --quiet --branch v0\.8\.1 '
assert_calls_not_contain 'releases/tags'
printf 'deadbee\n' >"$CLI_HOME/.git/HEAD"
reset_calls
run_install --version v0.8.1
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "CLI v0.8.1 at ${CLI_HOME} ($(cat "$MOCK_STATE/git_head")) (unchanged)"
assert_calls_contain "^git -C ${CLI_HOME} fetch --quiet --tags$"
assert_calls_contain "^git -C ${CLI_HOME} checkout --quiet v0\.8\.1$"
assert_calls_not_contain ' pull '
run_install
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "was on a detached HEAD"
assert_eq "ref: refs/heads/main" "$(cat "$CLI_HOME/.git/HEAD")"

# ---- git missing: named with the apt command, nothing written
NOGIT="$TMP_DIR/nogit"; mkdir -p "$NOGIT"
for t in env bash uname id grep sed awk cat mkdir mktemp chmod stat mv rm ln readlink dirname basename head tr cut sort tput date; do
  src="$(command -v "$t" 2>/dev/null || true)"
  if [[ -n "$src" ]]; then ln -sf "$src" "$NOGIT/$t"; fi
done
fresh
set +e; OUT="$(PATH="$NOGIT" "$BASH" "$INSTALL" 2>&1 </dev/null)"; CODE=$?; set -e
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "git is not installed"
assert_contains "$OUT" "fix: sudo apt update && sudo apt install -y git"
assert_no_file "$CLI_HOME"
assert_no_file "$HOME/.local/bin/benchbar"

# ---- not Ubuntu 24.04: a warning, the install goes on
printf 'NAME="Debian"\nID=debian\nVERSION_ID="12"\n' >"$FL_OS_RELEASE"
fresh
run_install
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "[WARN] debian 12 is not Ubuntu 24.04"
printf 'NAME="Ubuntu"\nID=ubuntu\nVERSION_ID="24.04"\n' >"$FL_OS_RELEASE"

# ---- a zsh login shell gets ~/.zshrc
fresh
printf 'export Z=1\n' >"$HOME/.zshrc"
SHELL=/usr/bin/zsh run_install
assert_eq "0" "$CODE" "$OUT"
grep -q -x -F "# >>> benchbar-path >>>" "$HOME/.zshrc" || fail "zsh: PATH block expected in ~/.zshrc"

# ---- dry-run writes nothing
fresh
snap_before="$(snapshot "$HOME")"
run_install --dry-run
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "dry-run: git clone"
assert_eq "$snap_before" "$(snapshot "$HOME")" "(dry-run writes nothing)"

# ---- uninstall removes the link and the block, keeps the rest
run_install
assert_eq "0" "$CODE" "$OUT"
run_install --uninstall --yes
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "uninstall-service --all"
assert_no_file "$HOME/.local/bin/benchbar"
! grep -q -F "# >>> benchbar-path >>>" "$HOME/.bashrc" || fail "the PATH block must be removed"
grep -q 'export EDITOR=vim' "$HOME/.bashrc" || fail "existing rc content must survive"
assert_calls_not_contain '^launchctl'

echo "ok"
