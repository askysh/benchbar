#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT"
. "$ROOT/lib/frappe-local/ui.sh"
. "$ROOT/lib/frappe-local/run.sh"
. "$ROOT/lib/frappe-local/platform.sh"

assert_eq() {
  [[ "$1" == "$2" ]] || { printf 'Expected [%s], got [%s]\n' "$1" "$2"; exit 1; }
}

assert_eq "10.11.14" "$(printf '%s\n' 'mariadb  Ver 15.1 Distrib 10.11.14-MariaDB' | fl_parse_mariadb_version)"
assert_eq "12.2.0" "$(printf '%s\n' 'mariadb from 12.2.0-MariaDB, client 15.2' | fl_parse_mariadb_version)"

FL_BREW_PREFIX="/opt/homebrew"
FL_PYTHON_FORMULA="python@3.11"
FL_PYTHON_BIN_NAME="python3.11"
FL_NODE_FORMULA="node@22"
FL_MARIADB_FORMULA="mariadb@10.11"

assert_eq "/opt/homebrew/opt/python@3.11/bin/python3.11" "$(fl_python_bin)"
assert_eq "/opt/homebrew/opt/node@22/bin/node" "$(fl_node_bin)"
assert_eq "/opt/homebrew/opt/node@22/bin/npm" "$(fl_npm_bin)"
assert_eq "/opt/homebrew/opt/mariadb@10.11/bin/mariadb" "$(fl_mariadb_bin)"

assert_fails() {
  if ( "$@" ) >/dev/null 2>&1; then
    printf 'Expected failure: %s\n' "$*"
    exit 1
  fi
}

FL_EFFECTIVE_UID=501
fl_preflight_not_root
FL_EFFECTIVE_UID=0
assert_fails fl_preflight_not_root
unset FL_EFFECTIVE_UID

FL_DISK_AVAILABLE_GB=20
fl_preflight_disk_space 10 "$ROOT"
FL_DISK_AVAILABLE_GB=5
assert_fails fl_preflight_disk_space 10 "$ROOT"
unset FL_DISK_AVAILABLE_GB

curl() {
  return 0
}
fl_preflight_internet 0

curl() {
  return 1
}
assert_fails fl_preflight_internet 0
fl_preflight_internet 1

# stat on both systems: GNU stat -f prints file system text and BSD stat -c
# fails, so each form counts only as a number
STAT_DIR="$(mktemp -d)"
FL_STATE_DIR="$STAT_DIR/state"
. "$ROOT/lib/frappe-local/lock.sh"
. "$ROOT/lib/frappe-local/state.sh"
. "$ROOT/lib/frappe-local/site-backups.sh"
OLD="$STAT_DIR/old"
mkdir "$OLD"
touch -t 202001010000 "$OLD"
age="$(fl__lock_age "$OLD")"
[[ "$age" =~ ^[0-9]+$ && "$age" -gt 100000 ]] || { printf 'lock age of an old folder: [%s]\n' "$age"; exit 1; }
assert_eq "0" "$(fl__lock_age "$OLD/missing")"
mtime="$(fl_file_mtime "$OLD")"
[[ "$mtime" =~ ^[0-9]+$ ]] || { printf 'mtime of a folder: [%s]\n' "$mtime"; exit 1; }
assert_fails fl_file_mtime "$OLD/missing"
fl_state_guard_stale "$OLD" || { printf 'an old guard without a pid is not stale\n'; exit 1; }
assert_fails fl_state_guard_stale "$OLD/missing"
fresh="$STAT_DIR/fresh"
mkdir "$fresh"
assert_fails fl_state_guard_stale "$fresh"
rm -rf "$STAT_DIR"

printf 'test-platform: ok\n'
