#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT"
export FL_TESTING=1
. "$ROOT/lib/frappe-local/ui.sh"
. "$ROOT/lib/frappe-local/run.sh"
. "$ROOT/lib/frappe-local/platform.sh"

assert_eq() {
  [[ "$1" == "$2" ]] || { printf 'Expected [%s], got [%s]\n' "$1" "$2"; exit 1; }
}

assert_eq "10.11.14" "$(printf '%s\n' 'mariadb  Ver 15.1 Distrib 10.11.14-MariaDB' | fl_parse_mariadb_version)"
assert_eq "12.2.0" "$(printf '%s\n' 'mariadb from 12.2.0-MariaDB, client 15.2' | fl_parse_mariadb_version)"

# Homebrew's default prefix follows the CPU: an Intel Mac never falls back to /opt/homebrew
intel_bin="$(mktemp -d)"
# shellcheck disable=SC2016  # the mock script, not this shell
printf '#!/bin/sh\n[ "$1" = "-m" ] && echo x86_64 || echo Darwin\n' >"$intel_bin/uname"; chmod +x "$intel_bin/uname"
assert_eq "/usr/local" "$(PATH="$intel_bin:$PATH" fl_brew_default_prefix)"
# shellcheck disable=SC2016  # the mock script, not this shell
printf '#!/bin/sh\n[ "$1" = "-m" ] && echo arm64 || echo Darwin\n' >"$intel_bin/uname"
assert_eq "/opt/homebrew" "$(PATH="$intel_bin:$PATH" fl_brew_default_prefix)"
find "$intel_bin" -delete

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

# fl_process_running NAME on macOS: pgrep -x compares NAME with the title a
# process gave itself, so it never finds Redis, which runs as
# "redis-server 127.0.0.1:6379" (issue 139). This pgrep answers as the one of
# macOS does for that process: nothing for -x, the title for -f.
PG_DIR="$(mktemp -d)"
cat >"$PG_DIR/pgrep" <<'SH'
#!/bin/sh
case "$1" in
  -qf) printf '%s\n' "$PG_TITLE" | grep -qE -- "$2" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$PG_DIR/pgrep"
pg() { if PATH="$PG_DIR:$PATH" PG_TITLE="$1" fl_process_running "$2"; then echo yes; else echo no; fi; }
assert_eq "yes" "$(pg 'redis-server 127.0.0.1:6379' redis-server)"
assert_eq "yes" "$(pg '/opt/homebrew/opt/redis/bin/redis-server /opt/homebrew/etc/redis.conf' redis-server)"
assert_eq "yes" "$(pg 'redis-server' redis-server)"
# a word in the arguments, or a longer name, is not the process
assert_eq "no" "$(pg 'tail -f /opt/homebrew/var/log/redis-server.log' redis-server)"
assert_eq "no" "$(pg 'redis-server-wrapper 127.0.0.1:6379' redis-server)"
assert_eq "no" "$(pg 'mariadbd-safe --datadir=/x' mariadbd)"
# a dot in a name is a dot
assert_eq "no" "$(pg 'pythonX11 x' python3.11)"
find "$PG_DIR" -delete

printf 'test-platform: ok\n'
