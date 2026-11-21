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

# fl_ensure_service_started waits for a service launchd starts in the background:
# on a new Mac (a hosted runner) Redis was not up two seconds after
# "brew services start", and the install stopped with "redis did not come up"
# although it came up (issue 139). Here it is "started" from the fourth
# "brew services list" on, about a second and a half after the start.
SVC_DIR="$(mktemp -d)"
mkdir "$SVC_DIR/bin"
cat >"$SVC_DIR/bin/brew" <<'SH'
#!/bin/sh
if [ "$1 $2" = "services list" ]; then
  n="$(cat "$SVC_COUNT" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" >"$SVC_COUNT"
  if [ "$n" -ge "$SVC_UP_AT" ]; then echo "redis started me ~/x.plist"; else echo "redis none"; fi
fi
exit 0
SH
printf '#!/bin/sh\nexit 1\n' >"$SVC_DIR/bin/pgrep"
chmod +x "$SVC_DIR/bin/brew" "$SVC_DIR/bin/pgrep"
svc_out="$(PATH="$SVC_DIR/bin:$PATH" SVC_COUNT="$SVC_DIR/count" SVC_UP_AT=4 fl_ensure_service_started redis redis-server 2>&1)" || {
  printf 'a service that starts a moment late failed the install:\n%s\n' "$svc_out"; exit 1; }
[[ "$svc_out" == *"redis is running"* ]] || { printf 'no "redis is running" line: %s\n' "$svc_out"; exit 1; }
# one that never starts still fails, with the time it was given
echo 0 >"$SVC_DIR/count"
if svc_out="$(PATH="$SVC_DIR/bin:$PATH" SVC_COUNT="$SVC_DIR/count" SVC_UP_AT=999 FL_SERVICE_START_SECS=1 fl_ensure_service_started redis redis-server 2>&1)"; then
  printf 'a service that never starts passed\n'; exit 1
fi
[[ "$svc_out" == *"redis did not come up within 1s"* ]] || { printf 'unexpected failure text: %s\n' "$svc_out"; exit 1; }
find "$SVC_DIR" -delete

printf 'test-platform: ok\n'
