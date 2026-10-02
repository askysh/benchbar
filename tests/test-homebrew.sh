#!/usr/bin/env bash
# A Homebrew install of the CLI in a fake prefix: the install kind and the
# stable path it records (FL_SELF), for both shapes of the formula's
# bin/benchbar (a wrapper that runs opt/benchbar/libexec/benchbar, or a
# symlink into the versioned Cellar folder); state outside the install
# folder, which no run writes into; a brew upgrade followed by brew cleanup.
# Then the one time move of the installer checkout's state folder. Then
# where, ~/.local/bin under Homebrew (no link needed, a link elsewhere
# pointed at the opt path with a backup), a second CLI seen from both
# sides, two BenchBar.app copies, and helpers whose benchbar is gone.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# ---- the kind and FL_SELF from SCRIPT_DIR alone
# kind_of SCRIPT_DIR: "KIND FL_SELF FL_SELF_DIR"
kind_of() {
  # shellcheck disable=SC2016 # expands in the child bash
  SCRIPT_DIR="$1" bash -c 'set -euo pipefail; . "$0/lib/frappe-local/install-kind.sh"; printf "%s %s %s" "$FL_INSTALL_KIND" "$FL_SELF" "$FL_SELF_DIR"' "$ROOT"
}
assert_eq "homebrew /opt/homebrew/opt/benchbar/bin/benchbar /opt/homebrew/opt/benchbar/libexec" "$(kind_of /opt/homebrew/opt/benchbar/libexec)"
assert_eq "homebrew /opt/homebrew/opt/benchbar/bin/benchbar /opt/homebrew/opt/benchbar/libexec" "$(kind_of /opt/homebrew/Cellar/benchbar/0.7.0/libexec)"
assert_eq "homebrew /usr/local/opt/benchbar/bin/benchbar /usr/local/opt/benchbar/libexec" "$(kind_of /usr/local/Cellar/benchbar/HEAD-1a2b3c4/libexec)"
assert_eq "managed $HOME/.local/share/benchbar/benchbar $HOME/.local/share/benchbar" "$(kind_of "$HOME/.local/share/benchbar")"
mkdir -p "$TMP_DIR/clone/.git" "$TMP_DIR/plain"
assert_eq "checkout $TMP_DIR/clone/benchbar $TMP_DIR/clone" "$(kind_of "$TMP_DIR/clone")"
assert_eq "other $TMP_DIR/plain/benchbar $TMP_DIR/plain" "$(kind_of "$TMP_DIR/plain")"
assert_eq "other" "$(kind_of /opt/homebrew/opt/benchbar-dev/libexec | cut -d ' ' -f 1)" "(only the benchbar formula is Homebrew's)"

# ---- where state.sh puts the state for each kind (no folder to move here)
# state_dir_as KIND: FL_STATE_DIR as state.sh picks it for KIND
state_dir_as() {
  # shellcheck disable=SC2016 # expands in the child bash
  env -u FL_STATE_DIR -u FL_STATE_FILE FL_INSTALL_KIND="$1" SCRIPT_DIR="$TMP_DIR/plain" \
    bash -c 'set -euo pipefail; . "$0/lib/frappe-local/state.sh"; printf "%s" "$FL_STATE_DIR"' "$ROOT"
}
assert_eq "$HOME/.local/state/benchbar" "$(state_dir_as homebrew)"
assert_eq "$HOME/.local/state/benchbar" "$(state_dir_as managed)"
assert_eq "$TMP_DIR/plain/.benchbar" "$(state_dir_as checkout)"
assert_eq "$TMP_DIR/plain/.benchbar" "$(state_dir_as other)"
# a fixed path: the app, an MCP client and launchd never see an
# XDG_STATE_HOME exported in ~/.zshrc, and must find the same state
assert_eq "$HOME/.local/state/benchbar" "$(XDG_STATE_HOME="$TMP_DIR/xdg" state_dir_as homebrew)" "(XDG_STATE_HOME is not used)"
assert_no_file "$HOME/.local/state" "(picking the folder creates nothing)"

# ---- the fake prefix: kegs in Cellar/benchbar/VERSION, opt/benchbar and
# bin/benchbar linked the way brew link does it (relative links)
PREFIX="$MOCK_BREW_PREFIX"
CELLAR="$PREFIX/Cellar/benchbar"
OPT_SELF="$PREFIX/opt/benchbar/bin/benchbar"
STATE="$HOME/.local/state/benchbar"

# keg VERSION: what the formula installs into libexec, copied (a symlink
# into the repo would resolve back to it), with FL_VERSION set to VERSION
keg() {
  local lx="$CELLAR/$1/libexec"
  mkdir -p "$lx" "$CELLAR/$1/bin"
  cp -R "$ROOT/benchbar" "$ROOT/00-mac-system-deps.sh" "$ROOT/01-install-bench-and-site.sh" \
    "$ROOT/02-background-service.sh" "$ROOT/lib" "$ROOT/templates" "$ROOT/config" "$lx/"
  sed_inplace "s/^FL_VERSION=\".*\"\$/FL_VERSION=\"$1\"/" "$lx/benchbar"
  chmod +x "$lx/benchbar"
}
# link_keg VERSION wrapper|symlink: the keg's bin/benchbar as
# bin.write_exec_script writes it (runs the opt path), or as
# bin.install_symlink does (a relative link into libexec); then opt and bin
link_keg() {
  local bin="$CELLAR/$1/bin/benchbar"
  rm -f "$bin"
  if [[ "$2" == wrapper ]]; then
    printf '#!/bin/bash\nexec "%s/opt/benchbar/libexec/benchbar" "$@"\n' "$PREFIX" >"$bin"
    chmod +x "$bin"
  else
    ln -s ../libexec/benchbar "$bin"
  fi
  ln -sfn "../Cellar/benchbar/$1" "$PREFIX/opt/benchbar"
  ln -sfn "../Cellar/benchbar/$1/bin/benchbar" "$PREFIX/bin/benchbar"
}
# cellar_snap: every path under the Cellar, and every file's size and time
cellar_snap() { find "$CELLAR" -print | LC_ALL=C sort; snapshot "$CELLAR"; }
# run_bb ARGS...: the Homebrew CLI through PREFIX/bin/benchbar, with its
# state where a real install keeps it (the harness pins it for other tests)
run_bb() {
  set +e
  OUT="$(env -u FL_STATE_DIR -u FL_STATE_FILE -u FL_BACKUP_ROOT "$PREFIX/bin/benchbar" "$@" 2>&1)"
  CODE="$?"
  set -e
}
# check FIELD ID: one field of a doctor check in the last doctor --json
check() { printf '%s' "$OUT" | jget - "[c['$1'] for c in d['checks'] if c['id'] == '$2'][0]"; }
# check_status ID: the status of one doctor check in the last doctor --json
check_status() { printf '%s' "$OUT" | jget - "[c['status'] for c in d['checks'] if c['id'] == '$1'][0]"; }
# helper_path: the BENCHBAR the helper block in ~/.zshrc records
helper_path() { sed -n 's/^BENCHBAR="\(.*\)"$/\1/p' "$HOME/.zshrc"; }

# not under ~ or ~/dev, so only the state finds it without --bench-dir
BENCH="$HOME/work/brew-bench"
make_fake_bench "$BENCH"

# ---- the wrapper shape, the one the formula ships
keg 0.7.0; link_keg 0.7.0 wrapper
before="$(cellar_snap)"
run_bb --version
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "benchbar 0.7.0"
run_bb service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
# generated files name the opt path, never a Cellar one
assert_eq "$OPT_SELF" "$(helper_path)" "(the helper block records the opt path)"
! grep -q '/Cellar/' "$HOME/.zshrc" || fail "a Cellar path in the helper block"$'\n'"$(cat "$HOME/.zshrc")"
for f in "$BENCH/benchbar-run.sh" "$BENCH/Procfile.lean" "$HOME/Library/LaunchAgents/com.benchbar.brew-bench.plist"; do
  assert_file "$f"
  ! grep -q '/Cellar/' "$f" || fail "a Cellar path in ${f}"
done
for name in benchbar frappe-mac; do
  link="$HOME/.local/bin/$name"
  if [[ -L "$link" && "$(readlink "$link")" == */Cellar/* ]]; then fail "${link} points into the Cellar"; fi
done
# state in ~/.local/state/benchbar, and nothing written into the install folder
assert_eq "$BENCH" "$(sed -n 's/^BENCH_DIR=//p' "$STATE/state.env")"
[[ -n "$(ls "$STATE"/logs/*.log 2>/dev/null)" ]] || fail "the run log belongs in the state folder"
assert_eq "$before" "$(cellar_snap)" "(a run writes nothing into the install folder)"
# the report names the kind, the opt path and the state folder
run_bb report --print --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "benchbar CLI: 0.7.0 (homebrew, "
assert_contains "$OUT" "/opt/benchbar/bin/benchbar)"
assert_contains "$OUT" "benchbar state: ~/.local/state/benchbar"
assert_not_contains "$OUT" "/Cellar/"
assert_eq "$before" "$(cellar_snap)" "(report writes nothing into the install folder)"

# ---- brew upgrade, then brew cleanup: a new keg, opt and bin re-pointed,
# the old keg deleted. Nothing generated is outdated, the runner included
# (its CLI_VERSION is not hashed), and the recorded path still runs.
keg 0.7.1; link_keg 0.7.1 wrapper; rm -rf "${CELLAR:?}/0.7.0"
run_bb doctor --json --bench-dir "$BENCH"
for id in helpers runner procfile agent; do
  assert_eq "ok" "$(check_status "$id")" "(${id} after the upgrade)"
done
grep -q '"cli_version":"0.7.0"' "$BENCH/benchbar-run.sh" || fail "the runner keeps the version that wrote it"
assert_contains "$("$(helper_path)" --version)" "benchbar 0.7.1"
run_bb path
assert_eq "$BENCH" "$OUT" "(the default bench is still remembered)"
run_bb service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "unchanged: all"

# ---- the symlink shape: SCRIPT_DIR is the Cellar folder, FL_SELF the same
# opt path, so the block the wrapper wrote is current
link_keg 0.7.1 symlink
before="$(cellar_snap)"
run_bb doctor --json --bench-dir "$BENCH"
assert_eq "ok" "$(check_status helpers)" "(the symlink shape records the same path)"
# printed fixes name the opt path too
mv "$BENCH/Procfile.lean" "$TMP_DIR/Procfile.lean.saved"
run_bb doctor --fix-hints --bench-dir "$BENCH"
assert_contains "$OUT" "${OPT_SELF} repair"
assert_not_contains "$OUT" "/Cellar/"
mv "$TMP_DIR/Procfile.lean.saved" "$BENCH/Procfile.lean"
run_bb service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "$before" "$(cellar_snap)" "(a run through the Cellar path writes nothing into it)"
[[ -z "$(find "$PREFIX" \( -name .benchbar -o -name .frappe-local \) -print)" ]] || fail "a state folder in the prefix"
# upgrade and cleanup in this shape too
keg 0.7.2; link_keg 0.7.2 symlink; rm -rf "${CELLAR:?}/0.7.1"
run_bb doctor --json --bench-dir "$BENCH"
for id in helpers runner; do
  assert_eq "ok" "$(check_status "$id")" "(${id} after the second upgrade)"
done
assert_contains "$("$(helper_path)" --version)" "benchbar 0.7.2"

# ---- the one time move of the installer checkout's state
# (each case starts without the new folder; the state so far waits aside)
mv "$STATE" "$TMP_DIR/state.saved"
NEW="$STATE"
LEGACY="$HOME/.local/share/benchbar/.benchbar"
MA="$HOME/work/m-a"; MB="$HOME/work/m-b"; MC="$HOME/work/m-c"
for b in "$MA" "$MB" "$MC"; do make_fake_bench "$b"; done
# seed_legacy: the state an install.sh CLI left: MA the default, MB
# registered; and no state in the new place yet
seed_legacy() {
  rm -rf "$HOME/.local/share/benchbar" "$NEW"
  mkdir -p "$LEGACY/benches" "$LEGACY/logs" "$LEGACY/backups"
  printf 'BENCH_DIR=%s\nPIPX_BIN_DIR=%s\n' "$MA" "$HOME/.local/bin" >"$LEGACY/state.env"
  printf 'SITE_NAME=macdev\nAUTOSTART=off\n' >"$LEGACY/benches/m-a-0badf00d.env"
  printf '%s\n' "$MB" >"$LEGACY/registered-benches.txt"
  printf 'an old run\n' >"$LEGACY/logs/20260930-120000.log"
}
# listed: the bench paths of the last list --json, default first
listed() { printf '%s' "$OUT" | jget - '" ".join(b["path"] for b in d["benches"]) + " default=" + str(d["default_bench"])'; }
# state_in_use: the state_dir of a where --json
state_in_use() { run_bb where --json; printf '%s' "$OUT" | jget - 'd["state_dir"]'; }

# shims that log "exec NAME" for mv, ln and mkdir, to count what a run starts
SHIMS="$TMP_DIR/shims"; mkdir -p "$SHIMS"
for n in mv ln mkdir; do
  # shellcheck disable=SC2016 # expands when the shim runs
  printf '#!/bin/bash\nprintf "exec %s\\n" >>"$MOCK_LOG"\nexec %s "$@"\n' "$n" "$(command -v "$n")" >"$SHIMS/$n"
  chmod +x "$SHIMS/$n"
done
REAL_STAT="$(command -v stat)"; REAL_MV="$(command -v mv)"; REAL_LN="$(command -v ln)"

# moved once: the folder whole (same files, sizes and times) with one mv, a
# symlink left at the old path, and the state is the one in use
seed_legacy
seeded="$(cd "$LEGACY" && snapshot .)"
reset_calls
PATH="$SHIMS:$PATH" run_bb list --json
assert_eq "0" "$CODE" "$OUT"
assert_eq "1 1" "$(grep -c '^exec mv$' "$MOCK_LOG") $(grep -c '^exec ln$' "$MOCK_LOG")" "(one mv, one ln)"
[[ -L "$LEGACY" ]] || fail "the old folder must become a symlink"
assert_eq "$NEW" "$(readlink "$LEGACY")"
[[ -d "$NEW" && ! -L "$NEW" ]] || fail "the state must be a real folder in its new place"
assert_eq "$seeded" "$(cd "$NEW" && snapshot .)" "(moved as is)"
assert_contains "$(listed)" "$MB"
assert_contains "$(listed)" "default=$MA"
# a second run moves nothing, links nothing, and starts no mv, ln or mkdir
links="$(find "$HOME/.local/share/benchbar" "$HOME/.local/state" -type l | LC_ALL=C sort)"
reset_calls
PATH="$SHIMS:$PATH" run_bb list --json
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain '^exec (mv|ln|mkdir)$'
assert_eq "$links" "$(find "$HOME/.local/share/benchbar" "$HOME/.local/state" -type l | LC_ALL=C sort)" "(no second link)"
assert_eq "$seeded" "$(cd "$NEW" && snapshot .)" "(a read only second run writes nothing)"
# an older CLI that still uses the old path shares the state and the lock
run_old() {
  set +e
  OUT="$(FL_STATE_DIR="$LEGACY" FL_STATE_FILE="$LEGACY/state.env" FL_BACKUP_ROOT="$LEGACY/backups" "$FM" "$@" 2>&1)"
  CODE="$?"
  set -e
}
run_old register "$MC"
assert_eq "0" "$CODE" "$OUT"
run_bb list --json
assert_contains "$(listed)" "$MC"
mkdir "$NEW/lock"; printf '%s\n' "$$" >"$NEW/lock/pid"
run_old register "$MC"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "Another benchbar run is active"
rm -rf "$NEW/lock"
# an XDG_STATE_HOME in the shell changes nothing: a run with it and one
# without (the app's, an MCP client's) use the same state and lock
before="$(cd "$NEW" && snapshot .)"
XDG_STATE_HOME="$TMP_DIR/xdg" run_bb list --json
with_xdg="$(listed)"
run_bb list --json
assert_eq "$with_xdg" "$(listed)" "(the same benches with and without XDG_STATE_HOME)"
assert_eq "$NEW" "$(XDG_STATE_HOME="$TMP_DIR/xdg" state_in_use)"
assert_eq "$NEW" "$(state_in_use)"
assert_no_file "$TMP_DIR/xdg"
# a run stopped between the mv and the ln: the next run makes the link again
rm "$LEGACY"
reset_calls
PATH="$SHIMS:$PATH" run_bb list --json
assert_eq "0" "$CODE" "$OUT"
assert_eq "$NEW" "$(readlink "$LEGACY")" "(the link is made again)"
assert_eq "0 1" "$(grep -c '^exec mv$' "$MOCK_LOG") $(grep -c '^exec ln$' "$MOCK_LOG")" "(one ln, nothing moved)"
assert_contains "$(listed)" "$MB"

# a run that holds the old folder's lock defers the move: the old folder is
# used as is until it ends, then the next run moves it
seed_legacy
mkdir "$LEGACY/lock"; printf '%s\n' "$$" >"$LEGACY/lock/pid"
run_bb list --json
assert_eq "0" "$CODE" "$OUT"
[[ -d "$LEGACY" && ! -L "$LEGACY" ]] || fail "a held lock must keep the old folder in place"
assert_no_file "$NEW"
assert_contains "$(listed)" "$MB"
run_bb register "$MC"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "Another benchbar run is active"
assert_no_file "$NEW"
# meanwhile the second copy's fix never sends the folder that holds the state to the Trash
cp "$ROOT/benchbar" "$HOME/.local/share/benchbar/benchbar"
run_bb doctor --json --bench-dir "$BENCH"
assert_eq "warn" "$(check status cli_duplicate)"
assert_contains "$(check message cli_duplicate)" "and so is the state (${LEGACY})"
assert_contains "$(check fix_command cli_duplicate)" "repair once no other benchbar run is active"
assert_not_contains "$(check fix_command cli_duplicate)" "Trash"
rm -f "$HOME/.local/share/benchbar/benchbar"
rm -rf "$LEGACY/lock"
run_bb list --json
assert_eq "0" "$CODE" "$OUT"
[[ -L "$LEGACY" && -d "$NEW" ]] || fail "moved by the first run after the lock is gone"
assert_contains "$(listed)" "$MB"

# a .frappe-local from before 0.3.0 is renamed, then moved the same way
rm -rf "$HOME/.local/share/benchbar" "$NEW"; mkdir -p "$HOME/.local/share/benchbar/.frappe-local"
printf 'BENCH_DIR=%s\n' "$MA" >"$HOME/.local/share/benchbar/.frappe-local/state.env"
run_bb list --json
assert_eq "0" "$CODE" "$OUT"
assert_no_file "$HOME/.local/share/benchbar/.frappe-local"
[[ -L "$LEGACY" ]] || fail "the renamed folder must be moved and linked"
assert_eq "BENCH_DIR=$MA" "$(cat "$NEW/state.env")"

# the installer's own CLI (managed) moves its state the same way
seed_legacy
cp -R "$ROOT/benchbar" "$ROOT/lib" "$ROOT/templates" "$ROOT/config" "$HOME/.local/share/benchbar/"
set +e
OUT="$(env -u FL_STATE_DIR -u FL_STATE_FILE -u FL_BACKUP_ROOT "$HOME/.local/share/benchbar/benchbar" list --json 2>&1)"; CODE=$?
set -e
assert_eq "0" "$CODE" "$OUT"
[[ -L "$LEGACY" ]] || fail "a managed CLI moves its own state too"
assert_eq "$NEW" "$(readlink "$LEGACY")"
assert_contains "$(listed)" "$MB"

# a state folder already in the new place is never merged into: both stay
seed_legacy
mkdir -p "$NEW"; printf 'BENCH_DIR=%s\n' "$MC" >"$NEW/state.env"
run_bb list --json
assert_eq "0" "$CODE" "$OUT"
[[ -d "$LEGACY" && ! -L "$LEGACY" ]] || fail "an existing state folder must not be merged into"
assert_eq "BENCH_DIR=$MC" "$(cat "$NEW/state.env")"
assert_contains "$(listed)" "default=$MC"

# FL_STATE_DIR from the environment wins: nothing moves
seed_legacy
set +e
OUT="$(env -u FL_STATE_FILE -u FL_BACKUP_ROOT FL_STATE_DIR="$TMP_DIR/pinned" "$PREFIX/bin/benchbar" list --json 2>&1)"; CODE=$?
set -e
assert_eq "0" "$CODE" "$OUT"
[[ -d "$LEGACY" && ! -L "$LEGACY" ]] || fail "a pinned FL_STATE_DIR must leave the old folder alone"
assert_no_file "$NEW"

# race shims: stat runs after the last check and before the mv, ln right
# after the mv; each does what another process would do in between
RACE="$TMP_DIR/race"; mkdir -p "$RACE"
# another first run moves and links the folder after this run's last check:
# this run's mv puts that link inside the new folder, and it goes back
# (once: on macOS the first stat, GNU's -c, fails and the second runs)
printf '#!/bin/bash\nif [[ ! -e %q ]]; then : >%q; %s %q %q && %s -s %q %q; fi\nexec %s "$@"\n' \
  "$RACE/moved" "$RACE/moved" "$REAL_MV" "$LEGACY" "$NEW" "$REAL_LN" "$NEW" "$LEGACY" "$REAL_STAT" >"$RACE/stat"
chmod +x "$RACE/stat"
seed_legacy
seeded="$(cd "$LEGACY" && snapshot .)"
PATH="$RACE:$PATH" run_bb list --json
assert_eq "0" "$CODE" "$OUT"
assert_file "$RACE/moved" "(the other run moved it in between)"
assert_eq "$NEW" "$(readlink "$LEGACY")"
[[ ! -e "$NEW/.benchbar" && ! -L "$NEW/.benchbar" ]] || fail "no link to itself inside the state folder"
assert_eq "$seeded" "$(cd "$NEW" && snapshot .)" "(the state as moved by the other run)"
assert_contains "$(listed)" "$MB"

# an older CLI makes its folder again between the mv and the ln: ln would
# put the link inside it. That link goes, this run uses the moved state,
# and doctor's Second CLI names the folder the older CLI started
printf '#!/bin/bash\nmkdir -p %q\nexec %s "$@"\n' "$LEGACY/logs" "$REAL_LN" >"$RACE/ln"
chmod +x "$RACE/ln"; rm -f "$RACE/stat"
seed_legacy
PATH="$RACE:$PATH" run_bb list --json
assert_eq "0" "$CODE" "$OUT"
[[ -d "$LEGACY" && ! -L "$LEGACY" ]] || fail "the older CLI's folder is left as it is"
[[ ! -e "$LEGACY/benchbar" && ! -L "$LEGACY/benchbar" ]] || fail "no link inside the older CLI's folder"
assert_contains "$(listed)" "default=$MA"
assert_eq "$NEW" "$(state_in_use)"
cp "$ROOT/benchbar" "$HOME/.local/share/benchbar/benchbar"
run_bb doctor --json --bench-dir "$BENCH"
assert_eq "warn" "$(check status cli_duplicate)"
assert_contains "$(check message cli_duplicate)" "has started a state folder of its own (${LEGACY}) since the state moved to ${NEW}"
rm -f "$RACE/ln"

# another volume: mv would copy, so the folder stays and the new path leads
# to it; the second copy's folder then holds the state and is not for the Trash
# shellcheck disable=SC2016 # expands when the shim runs
printf '#!/bin/bash\nprintf "exec stat\\n" >>"$MOCK_LOG"\nprintf "1\\n2\\n"\n' >"$RACE/stat"
chmod +x "$RACE/stat"
seed_legacy
seeded="$(cd "$LEGACY" && snapshot .)"
reset_calls
PATH="$RACE:$SHIMS:$PATH" run_bb list --json
assert_eq "0" "$CODE" "$OUT"
[[ -d "$LEGACY" && ! -L "$LEGACY" ]] || fail "across volumes the folder stays"
assert_eq "$LEGACY" "$(readlink "$NEW")"
assert_eq "0" "$(grep -c '^exec mv$' "$MOCK_LOG")" "(nothing moved, nothing copied)"
assert_eq "$seeded" "$(cd "$LEGACY" && snapshot .)"
assert_contains "$(listed)" "default=$MA"
reset_calls
PATH="$RACE:$SHIMS:$PATH" run_bb list --json
assert_calls_not_contain '^exec (mv|ln|mkdir|stat)$'
cp "$ROOT/benchbar" "$HOME/.local/share/benchbar/benchbar"
run_bb doctor --json --bench-dir "$BENCH"
assert_eq "ok" "$(check status cli_duplicate)"
assert_contains "$(check message cli_duplicate)" "which also holds the state"
rm -f "$RACE/stat"

rm -rf "$HOME/.local/share/benchbar" "$NEW"
mv "$TMP_DIR/state.saved" "$STATE"

# app_at DIR VERSION: a BenchBar.app in DIR
app_at() {
  mkdir -p "$1/BenchBar.app/Contents"
  printf '<plist><dict>\n<key>CFBundleShortVersionString</key>\n<string>%s</string>\n</dict></plist>\n' "$2" >"$1/BenchBar.app/Contents/Info.plist"
}

# ---- where: the kind, the path it records, its state and the app, never a
# Cellar path (here the symlink shape, so SCRIPT_DIR is the Cellar folder)
run_bb where --json
assert_eq "0" "$CODE" "$OUT"
assert_eq "1 0.7.2 homebrew" "$(printf '%s' "$OUT" | jget - '"%s %s %s" % (d["schema_version"], d["cli_version"], d["install"])')"
assert_eq "$OPT_SELF" "$(printf '%s' "$OUT" | jget - 'd["self"]')"
assert_eq "$STATE" "$(printf '%s' "$OUT" | jget - 'd["state_dir"]')"
assert_eq "None None" "$(printf '%s' "$OUT" | jget - '"%s %s" % (d["app_version"], d["app_path"])')"
assert_not_contains "$OUT" "/Cellar/"
run_bb where
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "benchbar 0.7.2, installed with Homebrew"
assert_contains "$OUT" "self     ${OPT_SELF}"
assert_contains "$OUT" "app      not installed"
run_bb where extra
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "Usage: benchbar where [--json]"
# the repo itself is a checkout, with its pinned state; the app, when installed
app_at "$HOME/Applications" 0.7.2
run_fm where --json
assert_eq "0" "$CODE" "$OUT"
assert_eq "checkout $ROOT/benchbar $FL_STATE_DIR" "$(printf '%s' "$OUT" | jget - '" ".join([d["install"], d["self"], d["state_dir"]])')"
assert_eq "0.7.2 $HOME/Applications/BenchBar.app" "$(printf '%s' "$OUT" | jget - '"%s %s" % (d["app_version"], d["app_path"])')"
rm -rf "$HOME/Applications/BenchBar.app"

# ---- ~/.local/bin under Homebrew: brew puts benchbar on PATH, so no link
# is needed and repair makes none
rm -f "$HOME/.local/bin/benchbar" "$HOME/.local/bin/frappe-mac"
run_bb doctor --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "ok" "$(check status cli_link)"
assert_contains "$(check message cli_link)" "Homebrew puts benchbar on PATH"
assert_eq "ok" "$(check status cli_duplicate)"
run_bb repair --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_no_file "$HOME/.local/bin/benchbar"
assert_no_file "$HOME/.local/bin/frappe-mac"

# ---- the one line installer's CLI is still here, and ~/.local/bin leads
# to it: both links are a warning, and so is the second copy
MANAGED="$HOME/.local/share/benchbar"
mkdir -p "$MANAGED"
cp -R "$ROOT/benchbar" "$ROOT/lib" "$ROOT/templates" "$ROOT/config" "$MANAGED/"
sed_inplace 's/^FL_VERSION=".*"$/FL_VERSION="0.6.1"/' "$MANAGED/benchbar"
chmod +x "$MANAGED/benchbar"
ln -s "$MANAGED/benchbar" "$HOME/.local/bin/benchbar"
ln -s "$MANAGED/benchbar" "$HOME/.local/bin/frappe-mac"
managed_before="$(cd "$MANAGED" && snapshot .)"
run_bb doctor --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "warn write_cli_link" "$(check status cli_link) $(check action cli_link)"
assert_contains "$(check message cli_link)" "ahead of Homebrew's benchbar on PATH"
assert_eq "${OPT_SELF} repair" "$(check fix_command cli_link)"
assert_eq "warn None" "$(check status cli_duplicate) $(check action cli_duplicate)"
assert_contains "$(check message cli_duplicate)" "benchbar 0.6.1 is still in ${MANAGED}"
assert_contains "$(check fix_command cli_duplicate)" "${OPT_SELF} repair, then: mv ${MANAGED} ~/.Trash/"
# the plan re-points, and a dry run changes nothing
run_bb repair --dry-run --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "point ~/.local/bin/benchbar and frappe-mac at ${OPT_SELF}"
assert_contains "$OUT" "dry-run: ln -sfn ${OPT_SELF} $HOME/.local/bin/benchbar   (now a link to ${MANAGED}/benchbar"
assert_eq "$MANAGED/benchbar" "$(readlink "$HOME/.local/bin/benchbar")"
# repair points both at the opt path, keeps the old links in its backups,
# and leaves the installer's copy as it is
run_bb repair --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
for name in benchbar frappe-mac; do
  assert_eq "$OPT_SELF" "$(readlink "$HOME/.local/bin/$name")" "(${name} re-pointed)"
  kept="$(find "$STATE/backups" -name "HOME__.local__bin__${name}" -type l | LC_ALL=C sort | tail -n 1)"
  [[ -n "$kept" ]] || fail "the old ${name} link belongs in the backups"
  assert_eq "$MANAGED/benchbar" "$(readlink "$kept")"
done
assert_contains "$OUT" "pointed $HOME/.local/bin/benchbar at ${OPT_SELF} (it led to ${MANAGED}/benchbar"
assert_eq "$managed_before" "$(cd "$MANAGED" && snapshot .)" "(the installer's copy is left as it is)"
assert_contains "$("$HOME/.local/bin/benchbar" --version)" "benchbar 0.7.2"
run_bb doctor --json --bench-dir "$BENCH"
assert_eq "ok" "$(check status cli_link)"
assert_contains "$(check message cli_link)" "leads to this CLI (${OPT_SELF})"
assert_eq "warn" "$(check status cli_duplicate)"
assert_contains "$(check message cli_duplicate)" "though ~/.local/bin no longer leads to it"
assert_eq "mv ${MANAGED} ~/.Trash/   (the benches and ${STATE} stay)" "$(check fix_command cli_duplicate)"
# a link into the Cellar dangles after brew cleanup: it is re-pointed too
ln -sfn "$CELLAR/0.7.2/libexec/benchbar" "$HOME/.local/bin/benchbar"
run_bb doctor --json --bench-dir "$BENCH"
assert_eq "warn" "$(check status cli_link)"
run_bb repair --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "$OPT_SELF" "$(readlink "$HOME/.local/bin/benchbar")"
# a file that is not a link is left alone, with the mv that clears the way
rm -f "$HOME/.local/bin/frappe-mac"; printf '#!/bin/sh\n' >"$HOME/.local/bin/frappe-mac"
run_bb doctor --json --bench-dir "$BENCH"
assert_eq "warn None" "$(check status cli_link) $(check action cli_link)"
assert_eq "mv $HOME/.local/bin/frappe-mac $HOME/.local/bin/frappe-mac.bak" "$(check fix_command cli_link)"
run_bb repair --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
[[ -f "$HOME/.local/bin/frappe-mac" && ! -L "$HOME/.local/bin/frappe-mac" ]] || fail "repair must leave a regular file alone"
rm -f "$HOME/.local/bin/frappe-mac"

# ---- the same Mac seen by the installer's CLI: Homebrew's is a second
# copy, and links that lead to it are current, so this repair keeps them
set +e
OUT="$(env -u FL_STATE_DIR -u FL_STATE_FILE -u FL_BACKUP_ROOT "$MANAGED/benchbar" doctor --json --bench-dir "$BENCH" 2>&1)"; CODE=$?
set -e
assert_eq "0" "$CODE" "$OUT"
assert_eq "warn None" "$(check status cli_duplicate) $(check action cli_duplicate)"
assert_contains "$(check message cli_duplicate)" "Homebrew has benchbar 0.7.2 too (${OPT_SELF})"
assert_eq "${OPT_SELF} repair   (Homebrew's takes over), or: brew uninstall benchbar   (this one stays)" "$(check fix_command cli_duplicate)"
assert_eq "ok" "$(check status cli_link)"
assert_contains "$(check message cli_link)" "leads to Homebrew's benchbar (${OPT_SELF}), not to this copy"
set +e
OUT="$(env -u FL_STATE_DIR -u FL_STATE_FILE -u FL_BACKUP_ROOT "$MANAGED/benchbar" repair --dry-run --bench-dir "$BENCH" 2>&1)"; CODE=$?
set -e
assert_eq "0" "$CODE" "$OUT"
assert_not_contains "$OUT" "ln -sfn"
rm -rf "$MANAGED"
run_bb doctor --json --bench-dir "$BENCH"
assert_eq "ok" "$(check status cli_duplicate)"

# ---- a git checkout keeps its own .benchbar, which Homebrew's CLI never
# reads: Homebrew's repair leaves a link or a helper block that runs it,
# and the checkout's doctor never says Homebrew's takes over
CLONE="$TMP_DIR/clone"
cp "$ROOT/benchbar" "$CLONE/benchbar"
mkdir -p "$CLONE/.benchbar"; printf 'BENCH_DIR=%s\n' "$BENCH" >"$CLONE/.benchbar/state.env"
ln -sfn "$CLONE/benchbar" "$HOME/.local/bin/benchbar"
# the block as the checkout wrote it: its path, and a hash of its own
sed_inplace "s#^BENCHBAR=.*#BENCHBAR=\"$CLONE/benchbar\"#; s#^\(\# benchbar-template: shell-helpers v1 \).*#\1000000000000#" "$HOME/.zshrc"
run_bb doctor --json --bench-dir "$BENCH"
assert_eq "warn None" "$(check status cli_link) $(check action cli_link)"
assert_contains "$(check message cli_link)" "$HOME/.local/bin/benchbar leads to a checkout with its own state ($CLONE/.benchbar)"
assert_eq "warn None" "$(check status helpers) $(check action helpers)"
assert_contains "$(check message helpers)" "runs $CLONE/benchbar, a checkout with its own state ($CLONE/.benchbar)"
run_bb repair --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "$CLONE/benchbar" "$(readlink "$HOME/.local/bin/benchbar")" "(the link to the checkout stays)"
assert_eq "$CLONE/benchbar" "$(helper_path)" "(the block that runs the checkout stays)"
run_fm doctor --json --bench-dir "$BENCH"
assert_eq "warn None" "$(check status cli_duplicate) $(check action cli_duplicate)"
assert_contains "$(check message cli_duplicate)" "with its own state in $HOME/.local/state/benchbar: this copy's remembered benches, settings and backups are in $FL_STATE_DIR"
assert_eq "brew uninstall benchbar   (this one stays; Homebrew's would start without this copy's state)" "$(check fix_command cli_duplicate)"
# without its state the checkout is like any other copy: repair takes over
rm -rf "$CLONE/.benchbar"
run_bb repair --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "$OPT_SELF" "$(readlink "$HOME/.local/bin/benchbar")"
assert_eq "$OPT_SELF" "$(helper_path)"
rm -f "$CLONE/benchbar"

# ---- two BenchBar.app copies: a warning that names both; no repair action,
# and repair moves neither
export FL_APP_DIRS="$TMP_DIR/Applications:$HOME/Applications"
app_at "$TMP_DIR/Applications" 0.7.2; app_at "$HOME/Applications" 0.6.1
run_bb doctor --json --bench-dir "$BENCH"
assert_eq "warn None" "$(check status app_copies) $(check action app_copies)"
assert_contains "$(check message app_copies)" "$TMP_DIR/Applications/BenchBar.app (0.7.2), $HOME/Applications/BenchBar.app (0.6.1)"
assert_contains "$(check fix_command app_copies)" "keep the copy you use"
# with Homebrew's cask, the installer's copy in ~/Applications is the one to go
mkdir -p "$PREFIX/Caskroom/benchbar-app/0.7.2"
run_bb doctor --json --bench-dir "$BENCH"
assert_eq "quit BenchBar, then: mv '$HOME/Applications/BenchBar.app' ~/.Trash/   (the one line installer's copy; Homebrew's cask benchbar-app is the other)" "$(check fix_command app_copies)"
run_bb repair --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_file "$TMP_DIR/Applications/BenchBar.app"
assert_file "$HOME/Applications/BenchBar.app"
rm -rf "$HOME/Applications/BenchBar.app" "$PREFIX/Caskroom"
run_bb doctor --json --bench-dir "$BENCH"
assert_eq "ok" "$(check status app_copies)"
assert_contains "$(check message app_copies)" "one BenchBar.app ($TMP_DIR/Applications/BenchBar.app)"
export FL_APP_DIRS="$HOME/Applications"

# ---- a helper block whose benchbar is gone (a keg brew cleanup removed)
# breaks every helper: doctor fails until repair writes the opt path
sed_inplace "s#^BENCHBAR=.*#BENCHBAR=\"$CELLAR/0.7.0/libexec/benchbar\"#" "$HOME/.zshrc"
run_bb doctor --json --bench-dir "$BENCH"
assert_eq "1" "$CODE" "(a FAIL exits 1)"
assert_eq "fail write_helpers" "$(check status helpers) $(check action helpers)"
assert_contains "$(check message helpers)" "run $CELLAR/0.7.0/libexec/benchbar, which is gone"
assert_eq "${OPT_SELF} repair" "$(check fix_command helpers)"
run_bb repair --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "$OPT_SELF" "$(helper_path)"
run_bb doctor --json --bench-dir "$BENCH"
assert_eq "ok" "$(check status helpers)"

printf 'test-homebrew: ok\n'
