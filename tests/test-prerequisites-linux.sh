#!/usr/bin/env bash
#
# benchbar doctor --prerequisites on Linux (Ubuntu 24.04, WSL or not): what a
# machine needs before "benchbar install", no bench needed, read only. The same
# JSON shape as the Mac list; each id, its level and its fix from the mocked
# conditions.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
use_linux

PRE="$TMP_DIR/pre-home"; mkdir -p "$PRE"
pre() { set +e; OUT="$(cd "$PRE" && "$FM" doctor --prerequisites --json "$@" 2>"$TMP_DIR/pre.err")"; CODE=$?; set -e; }
pq() { printf '%s' "$OUT" | python3 -I -c 'import json,re,sys; d=json.load(sys.stdin); c={x["id"]:x for x in d["prerequisites"]}; print('"$1"')'; }
lv() { pq "c[\"$1\"][\"level\"]"; }

# a healthy machine: Ubuntu 24.04 x86_64, systemd as init, lingering on, 8 GB, 50 GB free, apt reachable
export FL_ARCH=x86_64 FL_PREREQ_GROUPS="tester adm sudo users"
export FL_MEMINFO="$TMP_DIR/meminfo" FL_APT_DIR="$TMP_DIR/apt"
export FL_SYSTEMD_RUN_DIR="$TMP_DIR/run-systemd"
export FL_MARIADB_BIN="$ROOT/tests/mocks/mariadb" MOCK_MARIADB_ROOT_SOCKET_ONLY=1
mkdir -p "$FL_SYSTEMD_RUN_DIR" "$FL_APT_DIR/sources.list.d" "$MOCK_STATE/linger"
printf 'MemTotal:        8123456 kB\nMemFree: 1 kB\n' >"$FL_MEMINFO"
printf 'Types: deb\nURIs: http://archive.ubuntu.com/ubuntu/\nSuites: noble\n' >"$FL_APT_DIR/sources.list.d/ubuntu.sources"
printf 'yes' >"$MOCK_STATE/linger/tester"
# MariaDB is running with a root password benchbar kept in its password file
printf 'olderpw' >"$MOCK_STATE/mariadb_root_pw"
mkdir -p "$FL_STATE_DIR/secrets"; printf 'olderpw' >"$FL_STATE_DIR/secrets/mariadb-root"
printf '%s' 52428800 >"$MOCK_STATE/df_avail_kb"
mkdir -p "$MOCK_STATE/http"
: >"$MOCK_LISTEN"

snap="$(snapshot "$HOME" "$FL_STATE_DIR")"
pre --bench-dir "$HOME/not-created-yet"
assert_eq "0" "$CODE" "$OUT"
assert_eq "linux_distro architecture regular_user sudo apt systemd linger memory disk_free bench_folder mariadb_password default_ports" \
  "$(pq '" ".join(x["id"] for x in d["prerequisites"])')"
assert_eq "True" "$(pq 'all(set(x) >= {"id","label","level","message","fix_command"} for x in d["prerequisites"])')"
assert_eq "ok ok ok ok ok ok ok ok ok ok ok ok" "$(pq '" ".join(x["level"] for x in d["prerequisites"])')" "$OUT"
assert_eq '{"ok": 12, "warn": 0, "fail": 0}' "$(pq 'json.dumps(d["summary"])')"
assert_eq "True" "$(pq 'all(x["level"] == "ok" or bool(x["fix_command"]) for x in d["prerequisites"])')"
assert_eq "Ubuntu 24.04" "$(pq 'c["linux_distro"]["message"]')"
assert_eq "7933 True 50 0" "$(pq '" ".join(str(v) for v in (c["memory"]["total_mb"], c["systemd"]["enabled"], c["disk_free"]["free_gb"], c["default_ports"]["port_offset"]))')"
assert_eq "$snap" "$(snapshot "$HOME" "$FL_STATE_DIR")" "(prerequisites write nothing)"
assert_no_file "$HOME/not-created-yet"
assert_calls_not_contain '^sudo ' "(no sudo, no password: the check is read only)"
assert_calls_not_contain '^(apt-get|systemctl .*(start|restart|enable))'
# the text form
set +e; OUT="$(cd "$PRE" && "$FM" doctor --prerequisites 2>&1)"; CODE=$?; set -e
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "systemd: systemd runs as PID 1"
assert_contains "$OUT" "12 ok, 0 warn, 0 fail"

# distribution, architecture, user
printf 'NAME="Ubuntu"\nID=ubuntu\nVERSION_ID="22.04"\n' >"$FL_OS_RELEASE"
pre; assert_eq "warn 0" "$(lv linux_distro) $CODE"; assert_contains "$(pq 'c["linux_distro"]["fix_command"]')" "Ubuntu-24.04"
printf 'NAME="Ubuntu"\nID=ubuntu\nID_LIKE=debian\nVERSION_ID="24.04"\n' >"$FL_OS_RELEASE"
FL_ARCH=aarch64 pre; assert_eq "warn 0" "$(lv architecture) $CODE"; assert_contains "$(pq 'c["architecture"]["message"]')" "x86_64 only"
FL_EFFECTIVE_UID=0 pre; assert_eq "fail 1" "$(lv regular_user) $CODE"

# sudo: the group decides, nothing is run as root
FL_PREREQ_GROUPS="tester users" pre; assert_eq "fail 1" "$(lv sudo) $CODE"
assert_contains "$(pq 'c["sudo"]["fix_command"]')" "usermod -aG sudo"
FL_PREREQ_GROUPS="tester admin" pre; assert_eq "ok" "$(lv sudo)"
NOSUDO="$TMP_DIR/nosudo"; mkdir -p "$NOSUDO"
for t in awk sed head cat df id uname basename dirname date grep tr cut sort mkdir ls dpkg-query systemctl loginctl curl getent ss lsof mariadb bash env; do
  src="$(command -v "$t" 2>/dev/null || true)"; [[ -z "$src" ]] || ln -sf "$src" "$NOSUDO/$t"
done
PATH="$NOSUDO" pre; assert_eq "fail" "$(lv sudo)"; assert_contains "$(pq 'c["sudo"]["message"]')" "not installed"

# apt: the archive of the machine's own sources answers or not
printf 'deb http://mirror.example.net/ubuntu noble main\n' >"$FL_APT_DIR/sources.list"
rm -f "$FL_APT_DIR/sources.list.d/ubuntu.sources"
pre; assert_eq "ok" "$(lv apt)"; assert_contains "$(pq 'c["apt"]["message"]')" "http://mirror.example.net/ubuntu"
reset_calls
printf 'Types: deb\nURIs: http://archive.ubuntu.com/ubuntu/\nSuites: noble\n' >"$FL_APT_DIR/sources.list.d/ubuntu.sources"
touch "$MOCK_STATE/http_offline"
pre; assert_eq "warn 0" "$(lv apt) $CODE"; assert_contains "$(pq 'c["apt"]["fix_command"]')" "apt-get update"
rm -f "$MOCK_STATE/http_offline"
rm -f "$FL_APT_DIR/sources.list" "$FL_APT_DIR/sources.list.d/ubuntu.sources"
pre; assert_eq "ok" "$(lv apt)"; assert_contains "$(pq 'c["apt"]["message"]')" "archive.ubuntu.com"
printf 'Types: deb\nURIs: http://archive.ubuntu.com/ubuntu/\nSuites: noble\n' >"$FL_APT_DIR/sources.list.d/ubuntu.sources"

# systemd: PID 1 (or the run folder) decides; WSL gets the wsl.conf fix
rmdir "$FL_SYSTEMD_RUN_DIR"
pre; assert_eq "fail 1 False" "$(lv systemd) $CODE $(pq 'c["systemd"]["enabled"]')"
assert_contains "$(pq 'c["systemd"]["fix_command"]')" "/etc/wsl.conf"
mkdir -p "$FL_PROC_DIR/1"; printf 'systemd\n' >"$FL_PROC_DIR/1/comm"
pre; assert_eq "ok" "$(lv systemd)" "(PID 1 is systemd)"
rm -f "$FL_PROC_DIR/1/comm"
printf 'Linux version 6.8.0-generic (buildd@lcy02) #1 SMP\n' >"$FL_PROC_VERSION"
pre; assert_eq "fail" "$(lv systemd)"; assert_not_contains "$(pq 'c["systemd"]["fix_command"]')" "wsl.conf" "(outside WSL)"
printf 'Linux version 6.6.0-microsoft-standard-WSL2 (root@build) (gcc) #1 SMP\n' >"$FL_PROC_VERSION"
mkdir -p "$FL_SYSTEMD_RUN_DIR"

# linger
printf 'no' >"$MOCK_STATE/linger/tester"
pre; assert_eq "warn 0 False" "$(lv linger) $CODE $(pq 'c["linger"]["enabled"]')"; assert_contains "$(pq 'c["linger"]["fix_command"]')" "loginctl enable-linger tester"
printf 'yes' >"$MOCK_STATE/linger/tester"

# memory
printf 'MemTotal:        3000000 kB\n' >"$FL_MEMINFO"
pre; assert_eq "warn 0 2929" "$(lv memory) $CODE $(pq 'c["memory"]["total_mb"]')"; assert_contains "$(pq 'c["memory"]["fix_command"]')" ".wslconfig"
printf 'MemTotal:        1000000 kB\n' >"$FL_MEMINFO"
pre; assert_eq "fail 1" "$(lv memory) $CODE"
printf 'nothing useful\n' >"$FL_MEMINFO"
pre; assert_eq "warn None" "$(lv memory) $(pq 'c["memory"]["total_mb"]')"
printf 'MemTotal:        8123456 kB\n' >"$FL_MEMINFO"

# disk, folder
printf '%s' 15728640 >"$MOCK_STATE/df_avail_kb"; pre; assert_eq "warn 15" "$(lv disk_free) $(pq 'c["disk_free"]["free_gb"]')"
printf '%s' 5242880 >"$MOCK_STATE/df_avail_kb"; pre; assert_eq "fail 1" "$(lv disk_free) $CODE"
printf '%s' 52428800 >"$MOCK_STATE/df_avail_kb"
pre --bench-dir "$HOME/we\"ird"; assert_eq "fail 1" "$(lv bench_folder) $CODE"

# MariaDB: not installed, installed and stopped, running with a known password, running with an unknown one
grep -v '^mariadb-server$' "$MOCK_STATE/apt_installed" >"$MOCK_STATE/apt_installed.new"; mv "$MOCK_STATE/apt_installed.new" "$MOCK_STATE/apt_installed"
pre; assert_eq "ok False" "$(lv mariadb_password) $(pq 'c["mariadb_password"]["needs_password"]')"; assert_contains "$(pq 'c["mariadb_password"]["message"]')" "not installed yet"
printf '%s\n' mariadb-server >>"$MOCK_STATE/apt_installed"
# a password nobody told benchbar about (the apt service is active on the default mock)
rm -f "$FL_STATE_DIR/secrets/mariadb-root"
pre; assert_eq "warn True" "$(lv mariadb_password) $(pq 'c["mariadb_password"]["needs_password"]')"
assert_contains "$(pq 'c["mariadb_password"]["fix_command"]')" "MARIADB_ROOT_PASSWORD"
MARIADB_ROOT_PASSWORD=olderpw pre; assert_eq "ok" "$(lv mariadb_password)"; assert_contains "$(pq 'c["mariadb_password"]["message"]')" "MARIADB_ROOT_PASSWORD logs in"
MARIADB_ROOT_PASSWORD=wrongpw pre; assert_eq "warn" "$(lv mariadb_password)"
printf 'olderpw' >"$FL_STATE_DIR/secrets/mariadb-root"
pre; assert_eq "ok" "$(lv mariadb_password)"; assert_contains "$(pq 'c["mariadb_password"]["message"]')" "password file"
# the password itself is never printed
assert_not_contains "$OUT" "olderpw"
MARIADB_ROOT_PASSWORD=olderpw pre; assert_not_contains "$OUT" "olderpw"
grep -rqF -- olderpw "$TMP_DIR/pre.err" && fail "the password reached stderr"
true

# ports: a foreign listener moves the new bench to the next block
add_listener 8000 4242 ForeignApp
pre; assert_eq "warn 1" "$(lv default_ports) $(pq 'c["default_ports"]["port_offset"]')"; assert_eq "0" "$CODE"

# the doctor JSON of a bench carries the prerequisites next to the checks too
BENCH="$HOME/frappe-bench"; make_fake_bench "$BENCH" linuxdev.localhost
set +e; OUT="$(cd "$PRE" && "$FM" doctor --json --prerequisites --bench-dir "$BENCH" 2>/dev/null)"; set -e
assert_eq "linux_distro" "$(printf '%s' "$OUT" | jget - "d['prerequisites'][0]['id']")"

printf 'test-prerequisites-linux: ok\n'
