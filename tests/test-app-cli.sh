#!/usr/bin/env bash
# The CLI inside BenchBar.app (install kind "app"): its kind and the path it
# records, with and without the link the app keeps in
# ~/.local/state/benchbar/bin; Homebrew's and the installer's copy handing
# off to it (and not when told not to, when the link dangles, or from a
# checkout); where; doctor's view of the copies next to it; the helper block
# kept when it names a copy that hands off; nothing written into the app;
# and self-update, which leaves the app's CLI to the app's own channel.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

PREFIX="$MOCK_BREW_PREFIX"
CELLAR="$PREFIX/Cellar/benchbar"
OPT_SELF="$PREFIX/opt/benchbar/bin/benchbar"
APPS="$TMP_DIR/Applications"
APP="$APPS/BenchBar.app"
APP_CLI_DIR="$APP/Contents/Resources/cli"
LINK="$HOME/.local/state/benchbar/bin/benchbar"
export FL_APP_DIRS="$APPS" FL_SELFUPDATE_CASK_PREFIXES="$TMP_DIR/no-prefix"

# tree DIR VERSION: the CLI's files, copied, with FL_VERSION set to VERSION
tree() {
  mkdir -p "$1"
  cp -R "$ROOT/benchbar" "$ROOT/00-mac-system-deps.sh" "$ROOT/01-install-bench-and-site.sh" \
    "$ROOT/02-background-service.sh" "$ROOT/lib" "$ROOT/templates" "$ROOT/config" "$1/"
  sed_inplace "s/^FL_VERSION=\".*\"\$/FL_VERSION=\"$2\"/" "$1/benchbar"
  chmod +x "$1/benchbar"
}
# keg VERSION: Homebrew's formula at VERSION, bin/benchbar the wrapper it writes
keg() {
  rm -rf "$CELLAR"
  tree "$CELLAR/$1/libexec" "$1"
  mkdir -p "$CELLAR/$1/bin"
  printf '#!/bin/bash\nexec "%s/opt/benchbar/libexec/benchbar" "$@"\n' "$PREFIX" >"$CELLAR/$1/bin/benchbar"
  chmod +x "$CELLAR/$1/bin/benchbar"
  ln -sfn "../Cellar/benchbar/$1" "$PREFIX/opt/benchbar"
  ln -sfn "../Cellar/benchbar/$1/bin/benchbar" "$PREFIX/bin/benchbar"
}
# app VERSION: BenchBar.app at VERSION with its CLI inside
app() {
  rm -rf "$APP"
  tree "$APP_CLI_DIR" "$1"
  printf '<plist><dict>\n<key>CFBundleShortVersionString</key>\n<string>%s</string>\n</dict></plist>\n' "$1" >"$APP/Contents/Info.plist"
}
# register: the link BenchBar.app makes at launch
register() { mkdir -p "${LINK%/*}"; ln -sfn "$APP_CLI_DIR/benchbar" "$LINK"; }
# run CLI ARGS...: that benchbar, with the state where a real install keeps it
run() {
  set +e
  OUT="$(env -u FL_STATE_DIR -u FL_STATE_FILE -u FL_BACKUP_ROOT "$@" 2>&1)"
  CODE="$?"
  set -e
}
where_field() { printf '%s' "$OUT" | jget - "d['$1']"; }
check_status() { printf '%s' "$OUT" | jget - "[c['status'] for c in d['checks'] if c['id'] == '$1'][0]"; }
check_msg() { printf '%s' "$OUT" | jget - "[c['message'] for c in d['checks'] if c['id'] == '$1'][0]"; }
helper_path() { sed -n 's/^BENCHBAR="\(.*\)"$/\1/p' "$HOME/.zshrc"; }

# ---- the kind and FL_SELF from SCRIPT_DIR alone
kind_of() {
  # shellcheck disable=SC2016 # expands in the child bash
  SCRIPT_DIR="$1" bash -c 'set -euo pipefail; . "$0/lib/frappe-local/install-kind.sh"; printf "%s %s %s" "$FL_INSTALL_KIND" "$FL_SELF" "$FL_SELF_DIR"' "$ROOT"
}
app 0.7.2
assert_eq "app $APP_CLI_DIR/benchbar $APP_CLI_DIR" "$(kind_of "$APP_CLI_DIR")" "(no link: its own path)"
register
assert_eq "app $LINK $APP_CLI_DIR" "$(kind_of "$APP_CLI_DIR")" "(the app's link leads here: the link)"
other="$TMP_DIR/xcode/Build/Products/Debug/BenchBar.app/Contents/Resources/cli"
tree "$other" 0.7.2
assert_eq "app $other/benchbar $other" "$(kind_of "$other")" "(a second build: the link leads elsewhere, so its own path)"
state_dir() {
  # shellcheck disable=SC2016 # expands in the child bash
  env -u FL_STATE_DIR -u FL_STATE_FILE FL_INSTALL_KIND=app SCRIPT_DIR="$APP_CLI_DIR" \
    bash -c 'set -euo pipefail; . "$0/lib/frappe-local/state.sh"; printf "%s" "$FL_STATE_DIR"' "$ROOT"
}
assert_eq "$HOME/.local/state/benchbar" "$(state_dir)" "(the app's CLI keeps the user state, never the bundle)"
rm -f "$LINK"

# ---- Homebrew's CLI runs itself while no app is registered
keg 0.7.1
run "$PREFIX/bin/benchbar" --version
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "benchbar 0.7.1"

# ---- registered: Homebrew's CLI hands off, arguments and exit code intact
register
run "$PREFIX/bin/benchbar" --version
assert_contains "$OUT" "benchbar 0.7.2"
run "$PREFIX/bin/benchbar" where --json
assert_eq "0" "$CODE" "$OUT"
assert_eq "app" "$(where_field install)"
assert_eq "$LINK" "$(where_field self)"
assert_eq "$OPT_SELF" "$(where_field handoff_from)"
assert_eq "$HOME/.local/state/benchbar" "$(where_field state_dir)"
assert_eq "$APP" "$(where_field app_path)" "(the app it is part of)"
assert_eq "0.7.2" "$(where_field app_version)"
run "$PREFIX/bin/benchbar" where
assert_contains "$OUT" "installed inside BenchBar.app"
assert_contains "$OUT" "via      $OPT_SELF (0.7.1), which hands off to this CLI"
run "$PREFIX/bin/benchbar" no-such-command
assert_eq "1" "$CODE" "(the app's CLI's exit code comes back)"
assert_contains "$OUT" "Unknown command: no-such-command"
# the marker reaches no child of the app's CLI
run env BENCHBAR_HANDOFF_FROM=x "$APP_CLI_DIR/benchbar" where --json
assert_eq "x" "$(where_field handoff_from)"
# shellcheck disable=SC2016 # expands in the child bash
run env BENCHBAR_HANDOFF_FROM=x bash -c 'SCRIPT_DIR="$1"; . "$1/lib/frappe-local/install-kind.sh"; printf "[%s]" "${BENCHBAR_HANDOFF_FROM:-}"' _ "$APP_CLI_DIR"
assert_eq "[]" "$OUT" "(unset once read)"
# ...and no second hand off: a copy started with the marker runs itself
run env BENCHBAR_HANDOFF_FROM=x "$PREFIX/bin/benchbar" --version
assert_contains "$OUT" "benchbar 0.7.1"

# ---- not handed off: BENCHBAR_NO_HANDOFF, a dangling link, a checkout
run env BENCHBAR_NO_HANDOFF=1 "$PREFIX/bin/benchbar" --version
assert_contains "$OUT" "benchbar 0.7.1"
mv "$APP" "$TMP_DIR/Trashed.app"
run "$PREFIX/bin/benchbar" --version
assert_contains "$OUT" "benchbar 0.7.1" "(the app in the Trash: the link dangles, Homebrew's runs itself)"
mv "$TMP_DIR/Trashed.app" "$APP"
run "$ROOT/benchbar" where --json
assert_eq "checkout" "$(where_field install)" "(a checkout never hands off)"
assert_eq "None" "$(where_field handoff_from)"

# ---- the installer's checkout hands off too
tree "$HOME/.local/share/benchbar" 0.7.1
run "$HOME/.local/share/benchbar/benchbar" where --json
assert_eq "app" "$(where_field install)"
assert_eq "$HOME/.local/share/benchbar/benchbar" "$(where_field handoff_from)"

# ---- doctor from the app's CLI: copies that hand off are fine
BENCH="$HOME/work/app-bench"
make_fake_bench "$BENCH"
# the block as Homebrew's CLI wrote it before the app came
run env BENCHBAR_NO_HANDOFF=1 "$PREFIX/bin/benchbar" service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "$OPT_SELF" "$(helper_path)"
ln -sfn "$OPT_SELF" "$HOME/.local/bin/benchbar"
ln -sfn "$PREFIX/opt/benchbar/bin/frappe-mac" "$HOME/.local/bin/frappe-mac"
before="$(snapshot "$APP")"
run "$PREFIX/bin/benchbar" doctor --json --bench-dir "$BENCH"
assert_eq "ok" "$(check_status helpers)" "(a block naming a copy that hands off is current)"
assert_eq "ok" "$(check_status cli_duplicate)"
assert_contains "$(check_msg cli_duplicate)" "hand off to the app's CLI, so every benchbar runs 0.7.2"
assert_eq "ok" "$(check_status cli_link)"
run "$PREFIX/bin/benchbar" repair --yes --bench-dir "$BENCH"
assert_eq "$OPT_SELF" "$(helper_path)" "(repair leaves that block alone)"
run "$PREFIX/bin/benchbar" status --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "$before" "$(snapshot "$APP")" "(no run writes into the app)"

# ---- the helper block names a copy that outlives the app: Homebrew's or
# the installer's benchbar hands off to the app's CLI while the app is
# there, and runs itself once the app is gone, so benchup keeps working
# the block as a 0.7.1 app CLI wrote it: the app's link, with a hash of its own
sed_inplace "s#^BENCHBAR=.*#BENCHBAR=\"$LINK\"#; s#^\(\# benchbar-template: shell-helpers v1 \).*#\1000000000000#" "$HOME/.zshrc"
run "$LINK" doctor --json --bench-dir "$BENCH"
assert_eq "warn" "$(check_status helpers)" "(a block naming the app's link is outdated while a standalone copy hands off)"
run "$LINK" service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "$OPT_SELF" "$(helper_path)" "(run directly: Homebrew's copy comes first)"
run "$LINK" doctor --json --bench-dir "$BENCH"
assert_eq "ok" "$(check_status helpers)"
run "$LINK" service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "unchanged: all"
# no block yet, run through the installer's copy: the copy that handed off
printf '# test zshrc\nexport EDITOR=vim\n' >"$HOME/.zshrc"
run "$HOME/.local/share/benchbar/benchbar" service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "$HOME/.local/share/benchbar/benchbar" "$(helper_path)" "(the copy that handed off)"
run "$PREFIX/bin/benchbar" doctor --json --bench-dir "$BENCH"
assert_eq "ok" "$(check_status helpers)" "(a recorded copy that hands off stays, whichever copy runs doctor)"
run "$PREFIX/bin/benchbar" service --yes --bench-dir "$BENCH"
assert_contains "$OUT" "unchanged: all"
# no block yet, run through Homebrew's: brew's path; with the app in the
# Trash, the helpers run Homebrew's copy itself
printf '# test zshrc\nexport EDITOR=vim\n' >"$HOME/.zshrc"
run "$PREFIX/bin/benchbar" service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "$OPT_SELF" "$(helper_path)"
mv "$APP" "$TMP_DIR/Trashed.app"
assert_contains "$("$(helper_path)" --version 2>&1)" "benchbar 0.7.1" "(benchup still runs, through Homebrew's copy)"
mv "$TMP_DIR/Trashed.app" "$APP"
run "$PREFIX/bin/benchbar" doctor --json --bench-dir "$BENCH"
assert_eq "ok" "$(check_status helpers)"
run "$PREFIX/bin/benchbar" service --yes --bench-dir "$BENCH"
assert_contains "$OUT" "unchanged: all"

# ---- a standalone copy newer than the app's CLI: it hands off to the older
# one, so doctor names the app update; where says which version handed off
keg 9.9.9
run "$PREFIX/bin/benchbar" doctor --json --bench-dir "$BENCH"
assert_eq "warn" "$(check_status cli_duplicate)"
assert_contains "$(check_msg cli_duplicate)" "Homebrew's benchbar 9.9.9"
assert_contains "$(check_msg cli_duplicate)" "newer than"
fix="$(printf '%s' "$OUT" | jget - "[c['fix'] for c in d['checks'] if c['id'] == 'cli_duplicate'][0]")"
assert_contains "$fix" "Check for Updates in BenchBar"
assert_contains "$fix" "brew upgrade askysh/tap/benchbar-app"
run "$PREFIX/bin/benchbar" where --json
assert_eq "0" "$CODE" "$OUT"
assert_eq "$OPT_SELF" "$(where_field handoff_from)"
assert_eq "9.9.9" "$(where_field handoff_from_version)"
assert_eq "$HOME/.local/state/benchbar" "$(where_field state_dir_real)" "(not a link: the same as state_dir)"
run "$PREFIX/bin/benchbar" where
assert_contains "$OUT" "via      $OPT_SELF (9.9.9), which hands off to this CLI"
run "$LINK" where --json
assert_eq "None" "$(where_field handoff_from_version)" "(run directly: nothing handed off)"
keg 0.7.1
run "$PREFIX/bin/benchbar" doctor --json --bench-dir "$BENCH"
assert_eq "ok" "$(check_status cli_duplicate)"
# a Homebrew copy too old to hand off is named, with the upgrade
keg 0.7.0
run "$LINK" doctor --json --bench-dir "$BENCH"
assert_eq "warn" "$(check_status cli_duplicate)"
assert_contains "$(check_msg cli_duplicate)" "Homebrew's benchbar 0.7.0"
assert_contains "$(check_msg cli_duplicate)" "too old to hand off"
assert_eq "warn" "$(check_status helpers)" "(and its block is no longer one that leads here)"
tree "$HOME/.local/share/benchbar" 0.7.0
run "$LINK" doctor --json --bench-dir "$BENCH"
assert_contains "$(check_msg cli_duplicate)" "the one line installer's benchbar 0.7.0 ($HOME/.local/share/benchbar) are too old"
assert_contains "$(printf '%s' "$OUT" | jget - "[c['fix'] for c in d['checks'] if c['id'] == 'cli_duplicate'][0]")" "brew upgrade askysh/tap/benchbar && git -C $HOME/.local/share/benchbar pull --ff-only"
keg 0.7.1
# no other copy at all
rm -rf "$CELLAR" "$PREFIX/opt/benchbar" "$PREFIX/bin/benchbar" "$HOME/.local/share/benchbar"
run "$LINK" doctor --json --bench-dir "$BENCH"
assert_eq "ok" "$(check_status cli_duplicate)"
assert_contains "$(check_msg cli_duplicate)" "no other copy"
run "$LINK" repair --yes --bench-dir "$BENCH"
assert_eq "$LINK" "$(helper_path)" "(with nothing to hand off from, the block names the app's link)"
assert_eq "$LINK" "$(readlink "$HOME/.local/bin/benchbar")" "(and ~/.local/bin leads to it)"

# ---- a second state folder in the installer's checkout next to the user
# state (an older CLI started one, or the two were never merged): a split,
# named with the Trash for the folder, never a delete
MANAGED="$HOME/.local/share/benchbar"
mkdir -p "$MANAGED/.benchbar"; printf 'BENCH_DIR=%s\n' "$BENCH" >"$MANAGED/.benchbar/state.env"
run "$LINK" doctor --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "warn" "$(check_status cli_duplicate)"
assert_contains "$(check_msg cli_duplicate)" "$MANAGED/.benchbar"
assert_contains "$(check_msg cli_duplicate)" "state folder"
assert_contains "$(check_msg cli_duplicate)" "$HOME/.local/state/benchbar"
fix="$(printf '%s' "$OUT" | jget - "[c['fix'] for c in d['checks'] if c['id'] == 'cli_duplicate'][0]")"
assert_contains "$fix" "mv $MANAGED/.benchbar ~/.Trash/"
assert_not_contains "$fix" "rm "
assert_eq "None" "$(printf '%s' "$OUT" | jget - "[c['action'] for c in d['checks'] if c['id'] == 'cli_duplicate'][0]")" "(no repair action: nothing is deleted for the user)"
# with the installer's CLI there too, the whole checkout is what goes
tree "$MANAGED" 0.7.1
run "$LINK" doctor --json --bench-dir "$BENCH"
assert_eq "warn" "$(check_status cli_duplicate)"
assert_contains "$(check_msg cli_duplicate)" "state folder of its own ($MANAGED/.benchbar)"
assert_contains "$(printf '%s' "$OUT" | jget - "[c['fix'] for c in d['checks'] if c['id'] == 'cli_duplicate'][0]")" "mv $MANAGED ~/.Trash/"
# the state still in the checkout, the new path a link to it (another
# volume): no split, keep the folder
mv "$HOME/.local/state/benchbar" "$HOME/.local/state/benchbar.saved"
ln -s "$MANAGED/.benchbar" "$HOME/.local/state/benchbar"
mkdir -p "$MANAGED/.benchbar/bin"; ln -s "$APP_CLI_DIR/benchbar" "$MANAGED/.benchbar/bin/benchbar"
run "$MANAGED/benchbar" doctor --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "ok" "$(check_status cli_duplicate)"
assert_contains "$(check_msg cli_duplicate)" "also holds the state"
rm "$HOME/.local/state/benchbar"; mv "$HOME/.local/state/benchbar.saved" "$HOME/.local/state/benchbar"
rm -rf "$MANAGED"
run "$LINK" doctor --json --bench-dir "$BENCH"
assert_eq "ok" "$(check_status cli_duplicate)"

# ---- self-update: the app's CLI is the app's to update
release() {
  cat >"$MOCK_STATE/release.json" <<JSON
{"url": "https://api.github.com/repos/askysh/benchbar/releases/1", "html_url": "https://github.com/askysh/benchbar/releases/tag/v$1", "tag_name": "v$1", "draft": false}
JSON
}
release 0.7.2
run "$LINK" self-update --yes
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "BenchBar is up to date (0.7.2)"
release 99.0.0
reset_calls
run "$LINK" self-update --json
assert_eq "app" "$(where_field install)"
assert_eq "True" "$(where_field update_available)"
assert_eq "None" "$(where_field command)" "(Sparkle's: nothing to run here)"
assert_eq "$APP" "$(where_field app_path)"
run "$LINK" self-update --yes
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "Check for Updates"
assert_calls_not_contain '^brew upgrade'
assert_calls_not_contain 'install\.sh'
# the cask's app: brew upgrades it, never the installer
mkdir -p "$PREFIX/Caskroom/benchbar-app/0.7.2"
run env FL_BREW_PREFIX="$PREFIX" "$LINK" self-update --json
assert_eq "brew upgrade askysh/tap/benchbar-app" "$(where_field command)"
run env FL_BREW_PREFIX="$PREFIX" "$LINK" self-update --yes
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^brew upgrade askysh/tap/benchbar-app$'
assert_calls_not_contain 'install\.sh'

printf 'test-app-cli: ok\n'
