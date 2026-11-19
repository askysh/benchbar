#!/usr/bin/env bash
#
# An install that failed says so (issue 148): a failed step is "failed" in the
# summary and the stream, the exit code is not 0 and "Next steps" starts with
# the fix (issue 116); status says "unknown (no user bus)" when systemd cannot
# be asked, and install tells a user without a user bus the reason and the fix
# before it does any work (issue 115); Linux stops, before sudo and before any
# package, on a release benchbar does not support (INST-5). Everything is a
# mock or a fake folder.
# shellcheck disable=SC2016  # bash -c scripts are quoted on purpose
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
use_linux

export FL_SYSTEMD_RUN_DIR="$TMP_DIR/run-systemd" FL_MYSQL_CONF_DIR="$TMP_DIR/conf.d"
export FL_MEMINFO="$TMP_DIR/meminfo" FL_APT_DIR="$TMP_DIR/apt" FL_PROC_MOUNTS="$TMP_DIR/mounts"
export FL_WIN_DRIVE_DIR="$TMP_DIR/no-windows-drive"
export WSL_DISTRO_NAME=Ubuntu-test
mkdir -p "$FL_SYSTEMD_RUN_DIR" "$FL_MYSQL_CONF_DIR" "$FL_APT_DIR/sources.list.d" "$MOCK_STATE/linger"
printf 'MemTotal:        8123456 kB\n' >"$FL_MEMINFO"
printf 'Types: deb\nURIs: http://archive.ubuntu.com/ubuntu/\nSuites: noble\n' >"$FL_APT_DIR/sources.list.d/ubuntu.sources"
printf 'proc /proc proc rw 0 0\n/dev/sdc / ext4 rw 0 0\n' >"$FL_PROC_MOUNTS"
printf 'Linux version 6.8.0-generic (buildd@lcy02) #1 SMP\n' >"$FL_PROC_VERSION"
: >"$MOCK_LISTEN"
BENCH="$HOME/frappe-bench"
make_fake_bench "$BENCH" linuxdev.localhost
export ADMIN_PASSWORD=adminpw
# MariaDB as Ubuntu has it: root logs in over its socket, as the sudo mock's root
XBIN="$MOCK_STATE/xbin"; mkdir -p "$XBIN"
cp "$ROOT/tests/mocks/bin/_mocklib.sh" "$XBIN/"
cp "$ROOT/tests/mocks/mariadb" "$XBIN/mariadb"; chmod +x "$XBIN/mariadb"
export PATH="$XBIN:$PATH" FL_MARIADB_BIN="$XBIN/mariadb" MOCK_MARIADB_ROOT_SOCKET_ONLY=1
unit_name="benchbar-$(basename "$BENCH").service"
unit_file="$XDG_CONFIG_HOME/systemd/user/$unit_name"

# ---- a failed service step is a failure (issue 116, INST-4, SVC-6)
# the unit is written, then systemd refuses to start it: [FAIL] in step 3
forget_unit() { rm -f "$unit_file" "$MOCK_STATE/units/$unit_name"; }
touch "$MOCK_STATE/start_refused"
forget_unit
run_fm install --yes --bench-dir "$BENCH" --site linuxdev.localhost
[[ "$CODE" != "0" ]] || fail "install exited 0 after a failed service step: $OUT"
assert_contains "$OUT" "[FAIL]"
printf '%s\n' "$OUT" | grep -q -E 'Background service +failed' || fail "the summary row is not failed: $OUT"
assert_not_contains "$OUT" "Background service: warning"
assert_contains "$OUT" "Next steps"
assert_contains "$OUT" "benchbar repair"
# the fix comes first: benchup is not offered on a line of its own for a bench with no loaded unit
assert_not_contains "$OUT" "start the bench in the background"
forget_unit
run_fm install --json --yes --bench-dir "$BENCH" --site linuxdev.localhost
[[ "$CODE" != "0" ]] || fail "install --json exited 0 after a failed service step"
last="$(printf '%s\n' "$OUT" | grep '^{' | tail -1)"
assert_contains "$last" '"event":"done"'
assert_contains "$last" '"exit":1'
printf '%s\n' "$OUT" | grep -E '"id":"service"' | grep -q '"status":"failed"' || fail "the stream has no failed service step: $OUT"
# a run whose steps all worked still says done, with Next steps as before
rm -f "$MOCK_STATE/start_refused"
forget_unit
run_fm install --yes --bench-dir "$BENCH" --site linuxdev.localhost
assert_eq "0" "$CODE" "$OUT"
printf '%s\n' "$OUT" | grep -q -E 'Background service +done' || fail "the summary row is not done: $OUT"
assert_contains "$OUT" "benchup"

# ---- status says "unknown" when systemd cannot be asked, not "loaded: no" (issue 115, SVC-7)
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
run_fm status --bench-dir "$BENCH"
assert_contains "$OUT" "loaded: yes"
touch "$MOCK_STATE/user_manager_down"
run_fm status --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "unknown (no user bus)"
assert_not_contains "$OUT" "loaded: no"
assert_contains "$OUT" "sudo loginctl enable-linger"
assert_contains "$OUT" "XDG_RUNTIME_DIR=/run/user/"
rm "$MOCK_STATE/user_manager_down"
run_fm status --bench-dir "$BENCH"
assert_contains "$OUT" "loaded: yes"
assert_not_contains "$OUT" "unknown (no user bus)"

# ---- a user with no user bus (no linger, no login session) is told why and what to do before
# install changes anything, not at its last step (issue 115)
touch "$MOCK_STATE/user_manager_down"
export FL_USER_BUS_WAIT_SECS=1
run_fm install --dry-run --json --yes --bench-dir "$BENCH" --site linuxdev.localhost
assert_contains "$OUT" '"id":"user_bus_unreachable"'
assert_contains "$OUT" "sudo loginctl enable-linger"
reset_calls
run_fm install --yes --bench-dir "$BENCH" --site linuxdev.localhost
[[ "$CODE" != "0" ]] || fail "install went on without a user bus: $OUT"
assert_contains "$OUT" "the systemd user manager is not reachable for"
assert_contains "$OUT" "sudo loginctl enable-linger"
assert_contains "$OUT" "XDG_RUNTIME_DIR=/run/user/"
assert_contains "$OUT" "Nothing was changed"
assert_not_contains "$OUT" "systemctl could not load"
assert_calls_not_contain '^(sudo )?apt-get (install|update)'
assert_calls_not_contain '^(uv|fnm|bench|sudo) '
rm "$MOCK_STATE/user_manager_down"
# the bus shows up (lingering started the manager): the environment is pointed at it
mkdir -p "$TMP_DIR/run-user/$UID"
got="$(env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS FL_USER_RUN_BASE="$TMP_DIR/run-user" FL_USER_BUS_WAIT_SECS=0 SCRIPT_DIR="$ROOT" bash -c '
  . "$SCRIPT_DIR/lib/frappe-local/ui.sh"; . "$SCRIPT_DIR/lib/frappe-local/run.sh"; . "$SCRIPT_DIR/lib/frappe-local/platform.sh"
  fl_platform_load service; fl_user_bus_wait && printf "%s" "$XDG_RUNTIME_DIR"')"
assert_eq "$TMP_DIR/run-user/$UID" "$got" "(fl_user_bus_wait points XDG_RUNTIME_DIR at /run/user/UID once it exists)"
unset FL_USER_BUS_WAIT_SECS

# ---- Linux installs on the system it is tested on and stops before any package on another (INST-5)
os_release() { printf 'NAME="%s"\nID=%s\nVERSION_ID="%s"\n' "$1" "$2" "$3" >"$FL_OS_RELEASE"; }
os_release "Ubuntu" ubuntu 22.04
reset_calls
run_fm install --yes --bench-dir "$BENCH" --site linuxdev.localhost
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "Ubuntu 24.04"
assert_contains "$OUT" "--allow-unsupported-distro"
assert_calls_not_contain '^(sudo|apt-get|uv|fnm|curl .*(wkhtmltox|astral\.sh/uv|fnm\.vercel))'
run_fm install --dry-run --json --yes --bench-dir "$BENCH" --site linuxdev.localhost
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" '"id":"linux_distro_unsupported"'
os_release "Debian GNU/Linux" debian 12
run_fm install --dry-run --json --yes --bench-dir "$BENCH" --site linuxdev.localhost
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" '"id":"linux_distro_unsupported"'
# phase 00 on its own stops the same way, before apt
reset_calls
set +e; OUT="$("$ROOT/00-linux-system-deps.sh" --yes 2>&1)"; CODE=$?; set -e
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "--allow-unsupported-distro"
assert_calls_not_contain '^(sudo|apt-get|uv|fnm|curl .*(wkhtmltox|astral\.sh/uv|fnm\.vercel))'
# the override is a flag (and BENCHBAR_ALLOW_UNSUPPORTED_DISTRO=1 for the phase script): the plan goes on
run_fm install --dry-run --json --yes --allow-unsupported-distro --bench-dir "$BENCH" --site linuxdev.localhost
assert_eq "0" "$CODE" "$OUT"
assert_not_contains "$OUT" "linux_distro_unsupported"
set +e; OUT="$(BENCHBAR_ALLOW_UNSUPPORTED_DISTRO=1 "$ROOT/00-linux-system-deps.sh" --dry-run 2>&1)"; CODE=$?; set -e
assert_eq "0" "$CODE" "$OUT"
os_release "Ubuntu" ubuntu 24.04
run_fm install --dry-run --json --yes --bench-dir "$BENCH" --site linuxdev.localhost
assert_eq "0" "$CODE" "$OUT"
assert_not_contains "$OUT" "linux_distro_unsupported"

echo "test-install-failures: ok"
