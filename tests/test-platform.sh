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

printf 'test-platform: ok\n'
