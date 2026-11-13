#!/usr/bin/env bash
#
# What a Linux install (WSL above all) checks before it asks for sudo: the
# blockers and warnings of the install plan with their stable ids
# (systemd_not_running, port_N_in_use held by a Windows program,
# bench_on_windows_fs, apt_mirror_unreachable, github_unreachable, the
# warnings wsl_memory_low, wsl_disk_low, pypi_unreachable ...), the
# connectivity probe and the .wslconfig advice, apt through fl_apt_get (frontend,
# lock wait, proxy, the wait line), the user bus of an old WSL, "user manager
# not reachable" against "unit not loaded", lingering from install, the
# explorer.exe fallback of open, passwords with a line break, the arm64
# wkhtmltopdf row. Everything is a mock or a fake folder.
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
: >"$MOCK_LISTEN"
BENCH="$HOME/frappe-bench"

plan() { run_fm install --dry-run --json --yes --bench-dir "${1:-$BENCH}"; }
WSL_VERSION='Linux version 6.6.0-microsoft-standard-WSL2 (root@build) (gcc) #1 SMP'
PLAIN_VERSION='Linux version 6.8.0-generic (buildd@lcy02) #1 SMP'
wsl() { printf '%s\n' "$WSL_VERSION" >"$FL_PROC_VERSION"; }
not_wsl() { printf '%s\n' "$PLAIN_VERSION" >"$FL_PROC_VERSION"; }

# ---- a healthy distro: no blockers, no warnings, no sudo
wsl
plan
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" '"blockers":[],"warnings":[]'
assert_calls_not_contain '^sudo '

# ---- systemd_not_running: in the plan, before any sudo, with the wsl.conf fix
FL_SYSTEMD_RUN_DIR="$TMP_DIR/no-systemd" plan
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" '"id":"systemd_not_running"'
assert_contains "$OUT" "systemd=true"
assert_contains "$OUT" "/etc/wsl.conf"
assert_contains "$OUT" "wsl.exe --terminate Ubuntu-test"
assert_contains "$OUT" '"error_id":"systemd_not_running"'
assert_calls_not_contain '^sudo ' "(the blocker comes before the sudo prompt and the wkhtmltopdf install)"
assert_calls_not_contain '^(apt-get|uv|fnm|curl .*(wkhtmltox|astral\.sh/uv|fnm\.vercel))'
not_wsl
FL_SYSTEMD_RUN_DIR="$TMP_DIR/no-systemd" plan
assert_contains "$OUT" '"id":"systemd_not_running"'
assert_contains "$OUT" "boot this system with systemd as its init"
assert_not_contains "$OUT" "wsl.exe"
wsl
# phase 00 run by hand says the same, with the same id
set +e; OUT="$(FL_SYSTEMD_RUN_DIR="$TMP_DIR/no-systemd" "$ROOT/00-linux-system-deps.sh" --dry-run --yes 2>&1)"; CODE=$?; set -e
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "wsl.exe --terminate Ubuntu-test"

# ---- ports Windows holds: netstat.exe -ano, the localized state word, CRLF
NETSTAT="$TMP_DIR/netstat.exe"
cat >"$NETSTAT" <<'MOCK'
#!/usr/bin/env bash
printf 'netstat %s\n' "$*" >>"${MOCK_STATE}/netstat_calls"
[[ -z "${MOCK_NETSTAT_SLEEP:-}" ]] || sleep "$MOCK_NETSTAT_SLEEP"
printf '\r\nActive Connections\r\n\r\n  Proto  Local Address          Foreign Address        State           PID\r\n'
printf '  TCP    0.0.0.0:135            0.0.0.0:0              LISTENING       1048\r\n'
printf '  TCP    0.0.0.0:3306           0.0.0.0:0              LISTENING       4321\r\n'
printf '  TCP    127.0.0.1:8000         0.0.0.0:0              ABH\xc3\x96REN         777\r\n'
printf '  TCP    [::]:6379              [::]:0                 LISTENING       5150\r\n'
printf '  TCP    192.168.1.5:9000       0.0.0.0:0              LISTENING       2\r\n'
printf '  TCP    127.0.0.1:50430        127.0.0.1:11000        ESTABLISHED     99\r\n'
printf '  UDP    0.0.0.0:11000          *:*                                    3\r\n'
MOCK
chmod +x "$NETSTAT"
export FL_WIN_NETSTAT="$NETSTAT"
: >"$MOCK_STATE/netstat_calls"
plan
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" '"id":"port_3306_in_use"'
assert_contains "$OUT" "a Windows program (PID 4321)"
assert_contains "$OUT" '"id":"port_6379_in_use"'
assert_contains "$OUT" "a Windows program (PID 5150)"
assert_contains "$OUT" "netstat -ano | findstr :3306"
assert_contains "$OUT" "Task Manager"
assert_eq "1" "$(wc -l <"$MOCK_STATE/netstat_calls" | tr -d ' ')" "(one netstat for the whole plan)"
assert_eq "netstat -ano" "$(head -n1 "$MOCK_STATE/netstat_calls")"
# the web port is a Windows program's too: the new bench gets the next free block
assert_contains "$OUT" '"port_offset":1'
assert_contains "$OUT" 'http://linuxdev.localhost:8001'
# a listener on another interface (192.168.1.5:9000) and a connection are not listeners
printf '%s\n' '#!/usr/bin/env bash' 'printf "  TCP    192.168.1.5:3306       0.0.0.0:0    LISTENING   2\r\n  TCP    127.0.0.1:6379     127.0.0.1:50000    ESTABLISHED   3\r\n"' >"$TMP_DIR/netstat2.exe"
chmod +x "$TMP_DIR/netstat2.exe"
FL_WIN_NETSTAT="$TMP_DIR/netstat2.exe" plan
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" '"blockers":[]'
# WSL's own forwarding: the port also listens in this distro (wslrelay.exe shows it in Windows), so it is not a Windows program's
add_listener 3306 111 mariadbd 127.0.0.1
add_listener 6379 112 redis-server 127.0.0.1
plan
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" '"blockers":[]'
: >"$MOCK_LISTEN"
# a netstat.exe that is slow is given up on after FL_WIN_NETSTAT_SECS, without a blocker or an error
# (behaviour, not a tight clock: the bound only catches a plan that waits the whole sleep and more)
start="$SECONDS"
: >"$MOCK_STATE/netstat_calls"
MOCK_NETSTAT_SLEEP=20 FL_WIN_NETSTAT_SECS=1 plan
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" '"steps":'
assert_contains "$OUT" '"blockers":[]'
[[ "$(wc -l <"$MOCK_STATE/netstat_calls" | tr -d ' ')" -le 2 ]] || fail "netstat.exe must be asked once or twice at most"
[[ $((SECONDS - start)) -lt 45 ]] || fail "a slow netstat.exe must not hold the plan up"
# no netstat.exe at all: nothing is said
FL_WIN_NETSTAT="$TMP_DIR/not-there.exe" plan
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" '"blockers":[]'
# outside WSL there is no Windows to ask
not_wsl
: >"$MOCK_STATE/netstat_calls"
plan
assert_eq "0" "$CODE" "$OUT"
assert_eq "0" "$(wc -l <"$MOCK_STATE/netstat_calls" | tr -d ' ')" "(netstat.exe is only asked under WSL)"
wsl
unset FL_WIN_NETSTAT
# the ports check of doctor --prerequisites sees them too
FL_WIN_NETSTAT="$NETSTAT" run_fm doctor --prerequisites --json --bench-dir "$HOME/new-bench"
assert_contains "$OUT" "8000 has a listener: a Windows program (PID 777)"

# ---- a TCP connect to 127.0.0.1 finds a program outside the distro (mirrored networking)
if command -v python3 >/dev/null 2>&1; then
  python3 -I -c '
import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(5)
print(s.getsockname()[1], flush=True)
time.sleep(60)' >"$TMP_DIR/listener.port" 2>/dev/null &
  LISTENER_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [[ -s "$TMP_DIR/listener.port" ]] && break; sleep 0.25; done
  PORT="$(head -n1 "$TMP_DIR/listener.port")"
  [[ "$PORT" =~ ^[0-9]+$ ]] || fail "the test listener did not start"
  holder() { FL_LOCAL_PROBES="$2" SCRIPT_DIR="$ROOT" FL_PROC_VERSION="$FL_PROC_VERSION" bash -c '
    . "$SCRIPT_DIR/lib/frappe-local/ui.sh"; . "$SCRIPT_DIR/lib/frappe-local/run.sh"; . "$SCRIPT_DIR/lib/frappe-local/platform.sh"
    . "$SCRIPT_DIR/lib/frappe-local/process.sh"; fl_platform_load; fl_port_outside_holder "$1"' _ "$1"; }
  assert_contains "$(holder "$PORT" 1)" "a program outside this distro"
  assert_eq "" "$(holder "$PORT" 0 || true)" "(FL_LOCAL_PROBES=0 turns the connect off)"
  # a listener the distro's ss shows is the distro's, not a Windows program
  add_listener "$PORT" 4242 node 127.0.0.1
  assert_eq "" "$(holder "$PORT" 1 || true)" "(a listener inside the distro is not asked about)"
  : >"$MOCK_LISTEN"
  not_wsl
  assert_eq "" "$(holder "$PORT" 1 || true)" "(outside WSL there is no outside)"
  wsl
  kill "$LISTENER_PID" 2>/dev/null || true
  wait "$LISTENER_PID" 2>/dev/null || true
else
  printf 'skipped: no python3 for the connect probe\n'
fi

# ---- the network: github.com is a blocker, the rest (apt's mirror too) warns; every host is named
HOSTS="$MOCK_STATE/curl_fail_hosts"
printf 'github.com\n' >"$HOSTS"
plan
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" '"id":"github_unreachable"'
assert_contains "$OUT" "github.com"
assert_contains "$OUT" '"error_id":"github_unreachable"'
assert_contains "$OUT" "networkingMode=mirrored"
assert_contains "$OUT" "dnsTunneling=true"
assert_contains "$OUT" "autoProxy=true"
assert_contains "$OUT" "VPN or proxy on Windows"
assert_contains "$OUT" "BenchBar never edits that file"
assert_calls_not_contain '^sudo '
printf 'archive.ubuntu.com\npypi.org\nregistry.npmjs.org\nnodejs.org\nastral.sh\n' >"$HOSTS"
plan
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" '"blockers":[]'
assert_contains "$OUT" '"warnings":[{"id":"apt_mirror_unreachable"'
assert_contains "$OUT" "archive.ubuntu.com"
for id in pypi_unreachable npm_registry_unreachable nodejs_unreachable astral_unreachable; do
  assert_contains "$OUT" "\"id\":\"${id}\"" "(a warning for each of the other hosts)"
done
for host in pypi.org registry.npmjs.org nodejs.org astral.sh; do assert_contains "$OUT" "$host"; done
# the warnings alone do not stop the plan
printf 'pypi.org\nnodejs.org\n' >"$HOSTS"
plan
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" '"blockers":[]'
assert_contains "$OUT" '"warnings":[{"id":"pypi_unreachable"'
assert_contains "$OUT" '"id":"nodejs_unreachable"'
# the text form: a warning with its fix line
run_fm install --dry-run --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "pypi_unreachable:"
assert_contains "$OUT" "fix: a VPN or proxy on Windows"
# outside WSL the advice is not about .wslconfig
not_wsl
printf 'github.com\n' >"$HOSTS"
plan
assert_contains "$OUT" '"id":"github_unreachable"'
assert_not_contains "$OUT" "wslconfig"
assert_contains "$OUT" "http_proxy and https_proxy"
wsl
# --offline probes nothing
reset_calls
run_fm install --dry-run --json --yes --offline --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" '"blockers":[]'
assert_calls_not_contain '^curl '
: >"$HOSTS"; mv "$HOSTS" "$TMP_DIR/hosts.off"
# each probe is bounded: 10 seconds
reset_calls
plan
assert_calls_contain '^curl -s -o /dev/null --connect-timeout 10 --max-time 10 https://github.com$'
assert_calls_contain '^curl -s -o /dev/null --connect-timeout 10 --max-time 10 http://archive.ubuntu.com/ubuntu/$'
for host in pypi.org registry.npmjs.org nodejs.org astral.sh; do assert_calls_contain "^curl .*--max-time 10 https://${host}\$"; done
# a host that fails is asked once more before it is reported
printf 'github.com\n' >"$HOSTS"
reset_calls
plan
assert_eq "2" "$(grep -c '^curl .* https://github.com$' "$MOCK_LOG" 2>/dev/null || true)" "(one retry of a failed host)"
mv "$HOSTS" "$TMP_DIR/hosts.off1"
# an apt mirror that is not http or https (file:, mirror+file:) is not probed
mkdir -p "$TMP_DIR/aptfile/sources.list.d"
printf 'Types: deb\nURIs: mirror+file:/etc/apt/mirrors.txt\nSuites: noble\nComponents: main\n' >"$TMP_DIR/aptfile/sources.list.d/ubuntu.sources"
reset_calls
FL_APT_DIR="$TMP_DIR/aptfile" plan
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain 'mirror\+file|file:'
assert_not_contains "$OUT" "apt_mirror_unreachable"
# a phase script run by hand fails on the same two hosts with the advice
printf 'github.com\n' >"$HOSTS"
set +e; OUT="$("$ROOT/01-install-bench-and-site.sh" --yes --dry-run 2>&1)"; CODE=$?; set -e
assert_eq "0" "$CODE" "(a dry run skips the check, as it always did)"
set +e; OUT="$("$ROOT/00-linux-system-deps.sh" --yes 2>&1)"; CODE=$?; set -e
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "github.com did not answer within 10 seconds"
assert_contains "$OUT" "networkingMode=mirrored"
assert_calls_not_contain '^sudo '
mv "$HOSTS" "$TMP_DIR/hosts.off2"

# ---- the bench on the Windows file system
plan /mnt/c/Users/dev/frappe-bench
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" '"id":"bench_on_windows_fs"'
assert_contains "$OUT" "the Windows drive c:"
assert_contains "$OUT" "very slow"
assert_contains "$OUT" "file watching"
assert_contains "$OUT" "permissions"
assert_contains "$OUT" "$HOME/frappe-bench"
assert_contains "$OUT" "--allow-windows-fs"
assert_calls_not_contain '^sudo '
# the one override
run_fm install --dry-run --json --yes --allow-windows-fs --bench-dir /mnt/c/Users/dev/frappe-bench
assert_not_contains "$OUT" "bench_on_windows_fs"
# a mount of drvfs or 9p, wherever it is, and the nearest folder that exists decides
mkdir -p "$TMP_DIR/winmount/projects" "$TMP_DIR/linuxdir"
printf '/dev/sdc / ext4 rw 0 0\nC:\\134 %s 9p rw,dirsync,aname=drvfs 0 0\n' "$TMP_DIR/winmount" >"$FL_PROC_MOUNTS"
plan "$TMP_DIR/winmount/projects/frappe-bench"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "Windows file system mount (9p)"
plan "$TMP_DIR/linuxdir/frappe-bench"
assert_eq "0" "$CODE" "$OUT"
assert_not_contains "$OUT" "bench_on_windows_fs"
# not under WSL, nothing is said
not_wsl
plan "$TMP_DIR/winmount/projects/frappe-bench"
assert_not_contains "$OUT" "bench_on_windows_fs"
wsl
# adopt refuses it too
make_fake_bench "$TMP_DIR/winmount/projects/adopted" linuxdev.localhost
run_fm adopt "$TMP_DIR/winmount/projects/adopted" --dry-run --yes
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "Windows file system mount (9p)"
assert_contains "$OUT" "--allow-windows-fs"
run_fm adopt "$TMP_DIR/winmount/projects/adopted" --dry-run --yes --allow-windows-fs
assert_not_contains "$OUT" "Windows file system mount (9p)"
printf '/dev/sdc / ext4 rw 0 0\n' >"$FL_PROC_MOUNTS"

# ---- WSL memory and the Windows drive's free space: warnings in the plan
printf 'MemTotal:        4000000 kB\n' >"$FL_MEMINFO"
plan
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" '"id":"wsl_memory_low"'
assert_contains "$OUT" "bench build"
assert_contains "$OUT" "memory=8GB"
assert_contains "$OUT" ".wslconfig"
run_fm install --dry-run --yes --bench-dir "$BENCH"
assert_contains "$OUT" "wsl_memory_low:"
assert_contains "$OUT" "fix: raise it"
not_wsl
plan
assert_not_contains "$OUT" "wsl_memory_low" "(not a WSL limit)"
wsl
printf 'MemTotal:        8123456 kB\n' >"$FL_MEMINFO"
mkdir -p "$TMP_DIR/windrive"
export FL_WIN_DRIVE_DIR="$TMP_DIR/windrive"
printf '%s' 8388608 >"$MOCK_STATE/df_avail_kb"
plan
assert_contains "$OUT" '"id":"wsl_disk_low"'
assert_contains "$OUT" "8 GB free"
printf '%s' 52428800 >"$MOCK_STATE/df_avail_kb"
plan
assert_not_contains "$OUT" "wsl_disk_low"
export FL_WIN_DRIVE_DIR="$TMP_DIR/no-windows-drive"
printf '%s' 8388608 >"$MOCK_STATE/df_avail_kb"
plan
assert_not_contains "$OUT" "wsl_disk_low" "(no Windows drive to look at: silent)"
printf '%s' 52428800 >"$MOCK_STATE/df_avail_kb"

# ---- fl_apt_get: no questions, a lock wait, the old config kept, the proxy handed on through sudo
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY
apt_sudo() { SCRIPT_DIR="$ROOT" "$@" bash -c '
    . "$SCRIPT_DIR/lib/frappe-local/ui.sh"; . "$SCRIPT_DIR/lib/frappe-local/run.sh"; . "$SCRIPT_DIR/lib/frappe-local/platform.sh"
    fl_platform_load; fl_apt_get update'; }
: >"$MOCK_STATE/apt_raw"; : >"$MOCK_STATE/apt_sudo_raw"
apt_sudo env
assert_contains "$(cat "$MOCK_STATE/apt_sudo_raw")" "env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confold update"
assert_not_contains "$(cat "$MOCK_STATE/apt_sudo_raw")" "proxy"
assert_calls_contain '^sudo apt-get update$'
# a proxy with credentials never reaches a command line: apt gets it from a 0600 config file named by APT_CONFIG
# (the apt-get mock keeps a copy of that file while it runs), and the file is gone afterwards
APTTMP="$TMP_DIR/apttmp"; mkdir -p "$APTTMP"
: >"$MOCK_STATE/apt_conf_seen"
apt_sudo env TMPDIR="$APTTMP" https_proxy=http://user:s3cret@proxy.example:3128 http_proxy=http://user:s3cret@proxy.example:3128 no_proxy=localhost
assert_contains "$(tail -n1 "$MOCK_STATE/apt_sudo_raw")" "APT_CONFIG=$APTTMP/benchbar-apt."
assert_contains "$(tail -n1 "$MOCK_STATE/apt_sudo_raw")" "no_proxy=localhost"
assert_not_contains "$(cat "$MOCK_STATE/apt_sudo_raw")" "s3cret"
assert_not_contains "$(cat "$MOCK_STATE/apt_sudo_raw")" "proxy.example"
assert_not_contains "$(cat "$MOCK_STATE/apt_raw")" "s3cret"
assert_not_contains "$(cat "$MOCK_LOG")" "s3cret"
assert_contains "$(cat "$MOCK_STATE/apt_conf_seen")" 'Acquire::http::Proxy "http://user:s3cret@proxy.example:3128";'
assert_contains "$(cat "$MOCK_STATE/apt_conf_seen")" 'Acquire::https::Proxy "http://user:s3cret@proxy.example:3128";'
assert_contains "$(cat "$MOCK_STATE/apt_conf_seen")" "mode=600"
assert_eq "" "$(ls -A "$APTTMP")" "(the temp config and its folder are removed)"
# the whole call reached apt-get with its options
assert_contains "$(tail -n1 "$MOCK_STATE/apt_raw")" "-o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confold update"

# another apt holds the lock (unattended-upgrades on a fresh distro): one line, and a progress line in the stream
busy() { SCRIPT_DIR="$ROOT" FL_JSONL="$1" FL_PLAIN=1 bash -c '
    . "$SCRIPT_DIR/lib/frappe-local/ui.sh"; . "$SCRIPT_DIR/lib/frappe-local/run.sh"; . "$SCRIPT_DIR/lib/frappe-local/platform.sh"
    fl_platform_load; FL_JSONL_CUR=system_deps; fl_apt_run_long "apt-get update" update' 3>&1; }
OUT="$(busy 0 2>&1)"
assert_not_contains "$OUT" "waiting for another apt"
printf '9001 unattended-upgr\n' >>"$MOCK_PROCS"
OUT="$(busy 0 2>&1)"
assert_contains "$OUT" "waiting for another apt (unattended-upgrades)"
OUT="$(busy 1 2>&1)"
assert_contains "$OUT" '"event":"progress"'
assert_contains "$OUT" '"label":"waiting for another apt (unattended-upgrades)"'
: >"$MOCK_PROCS"

# ---- the user bus of an old WSL (no login session): XDG_RUNTIME_DIR and the bus are pointed at /run/user/UID
mkdir -p "$TMP_DIR/run-user/$UID"
bus() { # bus RUN_BASE [XDG_RUNTIME_DIR]: what a CLI start sees
  env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS FL_USER_RUN_BASE="$1" ${2:+XDG_RUNTIME_DIR="$2"} SCRIPT_DIR="$ROOT" bash -c '
    . "$SCRIPT_DIR/lib/frappe-local/ui.sh"; . "$SCRIPT_DIR/lib/frappe-local/run.sh"; . "$SCRIPT_DIR/lib/frappe-local/platform.sh"
    fl_platform_load; printf "%s|%s" "${XDG_RUNTIME_DIR:-}" "${DBUS_SESSION_BUS_ADDRESS:-}"'
}
assert_eq "$TMP_DIR/run-user/$UID|unix:path=$TMP_DIR/run-user/$UID/bus" "$(bus "$TMP_DIR/run-user")"
assert_eq "/already/set|" "$(bus "$TMP_DIR/run-user" /already/set)" "(a session that has XDG_RUNTIME_DIR keeps it, and nothing is exported)"
assert_eq "|" "$(bus "$TMP_DIR/nothing")" "(no /run/user/UID: nothing is invented)"

# ---- "user manager not reachable" against "unit not loaded"
SB="$TMP_DIR/svc-bench"
make_fake_bench "$SB" linuxdev.localhost
run_fm service --yes --bench-dir "$SB"
assert_eq "0" "$CODE" "$OUT"
touch "$MOCK_STATE/user_manager_down"
run_fm doctor --bench-dir "$SB"
assert_contains "$OUT" "the systemd user manager is not reachable for"
assert_contains "$OUT" "sudo loginctl enable-linger"
assert_contains "$OUT" "wsl.exe --terminate Ubuntu-test"
assert_not_contains "$OUT" "is written but not loaded"
run_fm up --bench-dir "$SB" --yes
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "the systemd user manager is not reachable for"
assert_contains "$OUT" "wsl.exe --terminate Ubuntu-test"
rm "$MOCK_STATE/user_manager_down"
# a unit that is simply not loaded keeps its own message
rm "$MOCK_STATE/units/benchbar-svc-bench.service"
run_fm doctor --bench-dir "$SB"
assert_contains "$OUT" "is written but not loaded"
assert_not_contains "$OUT" "user manager is not reachable"

# ---- lingering: the plain call first; with "sudo" (install) a refusal is tried through sudo when a credential is there
lg() { # lg [ENV=VALUE...]: fl_linger_ensure sudo, as install calls it
  env "$@" SCRIPT_DIR="$ROOT" bash -c '
    . "$SCRIPT_DIR/lib/frappe-local/ui.sh"; . "$SCRIPT_DIR/lib/frappe-local/run.sh"; . "$SCRIPT_DIR/lib/frappe-local/sudo.sh"; . "$SCRIPT_DIR/lib/frappe-local/platform.sh"
    fl_platform_load service; fl_linger_ensure sudo'
}
printf 'no' >"$MOCK_STATE/linger/tester"
reset_calls
OUT="$(lg A=1 2>&1)"
assert_calls_contain '^loginctl --no-ask-password enable-linger tester$'
assert_calls_not_contain '^sudo '
assert_eq "yes" "$(cat "$MOCK_STATE/linger/tester")"
reset_calls
OUT="$(lg A=1 2>&1)"
assert_calls_not_contain '^loginctl --no-ask-password enable-linger' "(already on: nothing to do)"
printf 'no' >"$MOCK_STATE/linger/tester"
reset_calls
OUT="$(lg MOCK_LINGER_DENIED=1 2>&1)"
assert_calls_contain '^sudo loginctl enable-linger tester$'
assert_eq "yes" "$(cat "$MOCK_STATE/linger/tester")" "(the sudo credential of the run enabled it)"
# no credential and no password: a warning with the fix, never a failure
printf 'no' >"$MOCK_STATE/linger/tester"
rm -f "$MOCK_STATE/sudo_cred"
reset_calls
OUT="$(lg MOCK_LINGER_DENIED=1 2>&1)"
assert_contains "$OUT" "could not turn on lingering"
assert_contains "$OUT" "fix: sudo loginctl enable-linger tester"
assert_calls_not_contain '^sudo loginctl'
touch "$MOCK_STATE/sudo_cred"
# the install does it before phase 00 (while sudo is still there); a dry run says so
printf 'no' >"$MOCK_STATE/linger/tester"
run_fm install --dry-run --yes --bench-dir "$BENCH"
assert_contains "$OUT" "dry-run: loginctl enable-linger tester"

# ---- open: explorer.exe when wslview is missing (it exits 1 even when it worked)
OPEN_BIN="$TMP_DIR/open-bin"; mkdir -p "$OPEN_BIN"
printf '#!/bin/bash\nprintf "explorer.exe %%s\\n" "$*" >>"$MOCK_STATE/explorer_calls"\nexit 1\n' >"$OPEN_BIN/explorer.exe"; chmod +x "$OPEN_BIN/explorer.exe"
opener() { env PATH="$OPEN_BIN:$(printf '%s' "$PATH" | tr ':' '\n' | grep -v "$ROOT/tests/mocks/bin" | tr '\n' ':')" SCRIPT_DIR="$ROOT" bash -c '
    . "$SCRIPT_DIR/lib/frappe-local/ui.sh"; . "$SCRIPT_DIR/lib/frappe-local/run.sh"; . "$SCRIPT_DIR/lib/frappe-local/platform.sh"
    fl_platform_load; printf "%s\n" "$(fl_open_cmd)"; fl_open_url "$1"; echo "status $?"' _ "$1"; }
OUT="$(opener http://linuxdev.localhost:8000)"
assert_contains "$OUT" "explorer.exe"
assert_contains "$OUT" "status 0"
assert_contains "$(cat "$MOCK_STATE/explorer_calls")" "explorer.exe http://linuxdev.localhost:8000"
# wslview is still first when it is there
assert_eq "wslview" "$(SCRIPT_DIR="$ROOT" bash -c '. "$SCRIPT_DIR/lib/frappe-local/ui.sh"; . "$SCRIPT_DIR/lib/frappe-local/run.sh"; . "$SCRIPT_DIR/lib/frappe-local/platform.sh"; fl_platform_load; fl_open_cmd')"

# ---- a password with a line break is refused before any work, by name and never by value
NL_PW=$'first\nsecond'
reset_calls
ADMIN_PASSWORD="$NL_PW" run_fm install --yes --offline --bench-dir "$HOME/nl-bench"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "ADMIN_PASSWORD contains a line break"
assert_not_contains "$OUT" "second"
assert_calls_not_contain '^(sudo|apt-get|curl|bench|loginctl)'
assert_no_file "$HOME/nl-bench"
MARIADB_ROOT_PASSWORD="$NL_PW" run_fm install --yes --offline --bench-dir "$HOME/nl-bench"
assert_contains "$OUT" "MARIADB_ROOT_PASSWORD contains a line break"
ADMIN_PASSWORD="$NL_PW" run_fm install --yes --offline --json --bench-dir "$HOME/nl-bench"
assert_contains "$OUT" '"error_id":"password_has_newline"'
ADMIN_PASSWORD="$NL_PW" run_fm site add other --yes --bench-dir "$SB"
assert_contains "$OUT" "ADMIN_PASSWORD contains a line break"
BENCHBAR_SUDO=env BENCHBAR_SUDO_PASSWORD="$NL_PW" run_fm install --yes --offline --bench-dir "$HOME/nl-bench"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "BENCHBAR_SUDO_PASSWORD contains a line break"
assert_not_contains "$OUT" "second"
assert_calls_not_contain '^(sudo|apt-get|curl|bench)'
# a one line password still works
BENCHBAR_SUDO=env BENCHBAR_SUDO_PASSWORD=onepw run_fm install --dry-run --yes --offline --bench-dir "$HOME/nl-bench"
assert_not_contains "$OUT" "line break"

# ---- wkhtmltopdf on arm64: its own row of config/wkhtmltopdf.tsv, the amd64 row for x86_64, a clear warning elsewhere
row() { awk -F '\t' -v a="$1" '$7 == "linux" && $5 == a {print $2 " " $4}' "$ROOT/config/wkhtmltopdf.tsv"; }
assert_eq "wkhtmltox_0.12.6.1-3.jammy_arm64.deb 2095f20256661ebf0983b9311168596c9d012666e21a94bc24f304db6ac69ec5" "$(row arm64)"
assert_eq "wkhtmltox_0.12.6.1-3.jammy_amd64.deb 4f723b2691ad8638a9df960e0421d346d7315083e3583a334f33362280ddba15" "$(row amd64)"
pin() { FL_ARCH="$1" FL_CONFIG_DIR="$ROOT/config" SCRIPT_DIR="$ROOT" bash -c '
    . "$SCRIPT_DIR/lib/frappe-local/ui.sh"; . "$SCRIPT_DIR/lib/frappe-local/run.sh"; . "$SCRIPT_DIR/lib/frappe-local/platform.sh"
    . "$SCRIPT_DIR/lib/frappe-local/version-policy.sh"; . "$SCRIPT_DIR/lib/frappe-local/state.sh"; . "$SCRIPT_DIR/lib/frappe-local/wkhtmltopdf.sh"
    fl_platform_load; fl_wkhtmltopdf_pin && printf "%s" "$FL_WKHTML_FILE"'; }
assert_eq "wkhtmltox_0.12.6.1-3.jammy_arm64.deb" "$(pin aarch64)"
assert_eq "wkhtmltox_0.12.6.1-3.jammy_amd64.deb" "$(pin x86_64)"
rm -f "$MOCK_STATE/wkhtml_installed"; touch "$MOCK_STATE/wkhtml_missing"
set +e; OUT="$(MOCK_UNAME_M=riscv64 "$ROOT/00-linux-system-deps.sh" --dry-run --yes 2>&1)"; CODE=$?; set -e
assert_contains "$OUT" "PDF printing is not set up on riscv64"
assert_contains "$OUT" "built for x86_64 and arm64 only"
assert_contains "$OUT" "fix: "
assert_not_contains "$OUT" "[FAIL]"
# arm64 gets its package, in the install plan too
MOCK_UNAME_M=aarch64 run_fm install --dry-run --yes --bench-dir "$BENCH"
assert_contains "$OUT" "wkhtmltox_0.12.6.1-3.jammy_arm64.deb"
assert_not_contains "$OUT" "PDF printing is not set up"

echo "test-wsl-preflight: ok"
