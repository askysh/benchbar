#!/usr/bin/env bash
# The Linux platform layer: platform selection, and every function that
# lib/frappe-local/platform-linux.sh (and the platform neutral helpers around
# it) answers differently on Linux. Runs on any host: ss, /proc, uv, fnm and
# the rest are mocks or fake folders.
# shellcheck disable=SC2016  # bash -c scripts and the rc lines are quoted on purpose
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
use_linux
. "$ROOT/lib/frappe-local/ui.sh"
. "$ROOT/lib/frappe-local/run.sh"
. "$ROOT/lib/frappe-local/platform.sh"
. "$ROOT/lib/frappe-local/version-policy.sh"
. "$ROOT/lib/frappe-local/state.sh"
. "$ROOT/lib/frappe-local/templates.sh"
. "$ROOT/lib/frappe-local/shellrc.sh"
. "$ROOT/lib/frappe-local/benchinfo.sh"
. "$ROOT/lib/frappe-local/process.sh"
. "$ROOT/lib/frappe-local/mariadb.sh"

# ---- fl_platform_load: FL_PLATFORM wins, else OSTYPE, no uname process
sel() { # sel FL_PLATFORM OSTYPE: what the loader picks
  env -u FL_PLATFORM ${1:+FL_PLATFORM="$1"} SCRIPT_DIR="$ROOT" OSTYPE_TEST="$2" bash -c '
    . "$SCRIPT_DIR/lib/frappe-local/platform.sh"; OSTYPE="$OSTYPE_TEST"; fl_platform_load; printf "%s" "$FL_PLATFORM"'
}
assert_eq "linux" "$(sel "" linux-gnu)"
assert_eq "macos" "$(sel "" darwin24.0)"
assert_eq "macos" "$(sel "" freebsd14)" "(an unknown system is treated as a Mac, as before)"
assert_eq "macos" "$(sel macos linux-gnu)" "(FL_PLATFORM overrides OSTYPE)"
assert_eq "linux" "$(sel linux darwin24.0)"
# the Mac keeps its own functions; Linux replaces them
assert_eq "no" "$(FL_PLATFORM=macos SCRIPT_DIR="$ROOT" bash -c '. "$SCRIPT_DIR/lib/frappe-local/platform.sh"; fl_platform_load; declare -F fl__ss_listeners >/dev/null && echo yes || echo no')"
assert_eq "yes" "$(FL_PLATFORM=linux SCRIPT_DIR="$ROOT" bash -c '. "$SCRIPT_DIR/lib/frappe-local/platform.sh"; fl_platform_load; declare -F fl__ss_listeners >/dev/null && echo yes || echo no')"
assert_eq "macdev" "$(FL_PLATFORM=macos bash -c ". '$ROOT/lib/frappe-local/platform.sh'; fl_default_site")"
assert_eq "no" "$(FL_PLATFORM=macos bash -c ". '$ROOT/lib/frappe-local/platform.sh'; fl_is_linux && echo yes || echo no")"

fl_platform_load service
assert_eq "linux" "$FL_PLATFORM"
fl_is_linux || fail "fl_is_linux must be true on linux"
assert_eq "linuxdev.localhost" "$(fl_default_site)"

# ---- fl_platform_init: Ubuntu or Debian with apt, no brew
fl_platform_init
assert_eq "" "$FL_BREW_PREFIX"
assert_eq "x86_64" "$FL_ARCH" "(from uname -m)"
assert_eq "1" "$FL_IS_WSL"
printf 'ID=debian\n' >"$FL_OS_RELEASE"; ( fl_platform_init ) >/dev/null 2>&1 || fail "Debian is accepted"
printf 'ID=pop\nID_LIKE="ubuntu debian"\n' >"$FL_OS_RELEASE"; ( fl_platform_init ) >/dev/null 2>&1 || fail "ID_LIKE ubuntu is accepted"
printf 'ID=fedora\nID_LIKE="rhel"\n' >"$FL_OS_RELEASE"
if out="$( ( fl_platform_init ) 2>&1 )"; then fail "Fedora must be refused"; fi
assert_contains "$out" "Ubuntu and Debian"
printf 'NAME="Ubuntu"\nID=ubuntu\nID_LIKE=debian\n' >"$FL_OS_RELEASE"

# ---- ports: one ss parser behind every question
: >"$MOCK_LISTEN"
add_listener 8000 4242 node '*'
add_listener 9000 4343 node '::1'
add_listener 11000 4444 redis-server 127.0.0.1
add_listener 3306 111 mariadbd '[::]'
add_listener 13000 - redis-server 127.0.0.1
reset_calls
fl_port_listening 8000 || fail "8000 listens"
fl_port_listening 9000 || fail "9000 listens"
! fl_port_listening 8001 || fail "8001 does not listen"
assert_calls_contain '^ss -Hltn sport = :8000$'
assert_eq "4242" "$(fl_port_listener_pid 8000)"
assert_eq "" "$(fl_port_listener_pid 8001)"
assert_eq "4242 node" "$(fl_port_listener_summary 8000)"
assert_eq "0 ?" "$(fl_port_listener_summary 13000)" "(an owner ss may not show is pid 0, still a listener)"
assert_eq "*:8000" "$(fl_port_listen_addresses 8000)" "(a wildcard reads *:PORT, as lsof prints it)"
assert_eq "[::1]:9000" "$(fl_port_listen_addresses 9000)" "(IPv6 loopback)"
assert_eq "*:3306" "$(fl_port_listen_addresses 3306)" "([::] is a wildcard)"
assert_eq "127.0.0.1:11000" "$(fl_port_listen_addresses 11000)"
assert_eq "" "$(fl_port_listen_addresses 8001)"
# the raw parser: port pid command address
assert_eq "8000 4242 node *:8000" "$(fl__ss_listeners 8000)"
assert_eq "2" "$(fl__ss_listeners 8000,9000 | wc -l | tr -d ' ')" "(a list of ports)"
# the parser on a real ss shape: several owners, a zone id, a hidden owner
# shellcheck disable=SC2329  # fl__ss_listeners calls it
ss() {
  cat <<'SS'
LISTEN 0 4096 127.0.0.53%lo:53 0.0.0.0:* users:(("systemd-resolve",pid=511,fd=14))
LISTEN 0 511 [::]:8080 [::]:* users:(("nginx",pid=700,fd=6),("nginx",pid=701,fd=6))
LISTEN 0 128 [fe80::1%eth0]:22 [::]:*
LISTEN 0 128 0.0.0.0:6379 0.0.0.0:* users:(("Web Content",pid=4545,fd=3))
SS
}
assert_eq "53 511 systemd-resolve 127.0.0.53:53" "$(fl__ss_listeners 53)" "(the %lo zone is dropped)"
assert_eq "8080 700 nginx *:8080
8080 701 nginx *:8080" "$(fl__ss_listeners 8080)" "(one line per owner)"
assert_eq "22 0 ? [fe80::1]:22" "$(fl__ss_listeners 22)"
assert_eq "6379 4545 Web_Content *:6379" "$(fl__ss_listeners 6379)" "(0.0.0.0 is a wildcard; a blank in the command cannot split the line)"
unset -f ss

# ---- /proc: the working folder of a process
BENCH="$HOME/frappe-bench"
make_fake_bench "$BENCH" linuxdev.localhost
FL_BENCH_DIR="$BENCH"
FL_WEB_PORT=8000; FL_SOCKETIO_PORT=9000; FL_REDIS_QUEUE_PORT=11000; FL_REDIS_CACHE_PORT=13000
: >"$MOCK_LISTEN"
add_proc 4242 "node apps/frappe/socketio.js" "$BENCH"
add_proc 4343 "redis-server *:11000" "$BENCH/config"
add_proc 4444 "python -m http.server 8000" "$HOME/elsewhere"
add_proc 4545 "honcho start -f Procfile.lean" "$BENCH"
add_proc 4646 "honcho start -f Procfile.lean" "$HOME/other-bench"
add_proc 4747 "$BENCH/env/bin/python -m frappe.utils.bench_helper frappe serve --port 8000" "$BENCH/sites"
add_proc 4848 "honcho start -f Procfile.lean"
assert_eq "$BENCH" "$(fl_pid_cwd 4242)"
assert_eq "$BENCH/config" "$(fl_pid_cwd 4343)"
assert_eq "" "$(fl_pid_cwd 4848)" "(no readable folder)"
assert_eq "" "$(fl_pid_cwd 99999)"
assert_eq "" "$(fl_pid_cwd 'x/../..')" "(only a number is a pid)"
fl_pid_is_bench_own_strict 4343 || fail "a folder inside the bench is the bench's"
! fl_pid_is_bench_own_strict 4444 || fail "another folder is not"
! fl_pid_is_bench_own_strict 4848 || fail "an unreadable folder proves nothing"
add_listener 9000 4242 node '*'
add_listener 11000 4343 redis-server 127.0.0.1
add_listener 8000 4444 python 127.0.0.1
add_listener 13000 - redis-server 127.0.0.1
assert_eq "4242
4343" "$(fl_bench_listener_pids | sort)" "(only listeners that provably run in the bench; not the foreign 8000, not the hidden owner)"

# pgrep -af: "PID command line", the shape fl_bench_status_pids parses
reset_calls
assert_eq "4242
4545
4747" "$(fl_bench_status_pids | sort)" "(this bench's socketio, honcho and serve; the other bench's honcho and an unreadable one are left out)"
assert_eq "4545" "$(fl_bench_status_pids | head -n 1)" "(honcho first)"
assert_calls_contain '^pgrep -af '
assert_calls_not_contain '^pgrep -lf '
assert_eq "4545 honcho start -f Procfile.lean" "$(pgrep -af 'honcho start' | head -n 1)"
fl_process_running 'socketio\.js' || fail "a running process is found"
! fl_process_running 'no-such-process-anywhere' || fail "a missing one is not"
assert_calls_not_contain '^pgrep -q'

# ---- services: systemctl is-active on the mapped unit
FAKEBIN="$TMP_DIR/fakebin"; mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$MOCK_LOG"
[[ "$1" == "is-active" ]] || exit 3
[[ "$2" == "--quiet" ]] && shift
grep -qx "$2" "$MOCK_STATE/active_units" 2>/dev/null
SH
chmod +x "$FAKEBIN/systemctl"
OLDPATH="$PATH"; PATH="$FAKEBIN:$PATH"
printf 'mariadb\nredis-server\n' >"$MOCK_STATE/active_units"
fl_brew_service_running mariadb@10.11 || fail "mariadb@10.11 maps to the mariadb unit"
fl_brew_service_running mariadb || fail "mariadb"
fl_brew_service_running redis || fail "redis maps to redis-server"
assert_calls_contain '^systemctl is-active --quiet redis-server$'
printf 'mariadb\n' >"$MOCK_STATE/active_units"
! fl_brew_service_running redis || fail "redis is not active"
PATH="$OLDPATH"

# no date means no disable days
read -r dep dis depd disd <<<"$(fl_brew_formula_dates python@3.11)"
assert_eq "unknown" "$dep"
assert_eq "" "$(fl_formula_disable_days_from "$dep" "$dis" "$disd")"
assert_eq "" "$(fl_formula_disable_days python@3.11)"
fl_brew_formula_available mariadb@10.11 || fail "installed apt package"
fl_brew_formula_available redis || fail "redis maps to redis-server"
fl_brew_formula_available zip || fail "installed"
fl_brew_formula_available some-other-package || fail "apt can install it (simulated)"
printf 'some-other-package\n' >"$MOCK_STATE/apt_unavailable"
! fl_brew_formula_available some-other-package || fail "apt cannot find it"
! fl_crontab_denied || fail "no crontab gate on Linux"

# ---- toolchain: uv Python, fnm Node, apt MariaDB
FL_PYTHON_BIN_NAME=python3.11; FL_NODE_MAJOR=22; FL_PROFILE=v15-lts
PYDIR="$HOME/.local/share/uv/python"
NODEDIR="$HOME/.local/share/fnm/node-versions"
assert_eq "$PYDIR/cpython-3.11.9-linux-x86_64-gnu/bin/python3.11" "$(fl_python_bin)"
"$(fl_python_bin)" --version | grep -q 'Python 3.11' || fail "the mock python answers"
assert_eq "$NODEDIR/v22.11.0/installation/bin/node" "$(fl_node_bin)"
assert_eq "$NODEDIR/v22.11.0/installation/bin/npm" "$(fl_npm_bin)"
# the newest patch release wins, by number and not by text
mkdir -p "$PYDIR/cpython-3.11.10-linux-x86_64-gnu/bin" "$PYDIR/cpython-3.11-linux-x86_64-gnu/bin" "$NODEDIR/v22.9.0/installation/bin" "$NODEDIR/v22.2.0/installation/bin"
cp "$ROOT/tests/mocks/python3.11" "$PYDIR/cpython-3.11.10-linux-x86_64-gnu/bin/python3.11"
cp "$ROOT/tests/mocks/python3.11" "$PYDIR/cpython-3.11-linux-x86_64-gnu/bin/python3.11"
for d in v22.9.0 v22.2.0; do cp "$ROOT/tests/mocks/node" "$NODEDIR/$d/installation/bin/node"; done
chmod +x "$PYDIR"/*/bin/* "$NODEDIR"/*/installation/bin/*
assert_eq "$PYDIR/cpython-3.11.10-linux-x86_64-gnu/bin/python3.11" "$(fl_python_bin)"
assert_eq "$NODEDIR/v22.11.0/installation/bin/node" "$(fl_node_bin)" "(22.11.0 is newer than 22.9.0)"
FL_PYTHON_BIN_NAME=python3.14; FL_NODE_MAJOR=24
assert_eq "$PYDIR/cpython-3.14.9-linux-x86_64-gnu/bin/python3.14" "$(fl_python_bin)"
assert_eq "$NODEDIR/v24.11.0/installation/bin/node" "$(fl_node_bin)"
FL_PYTHON_BIN_NAME=python3.11; FL_NODE_MAJOR=22
assert_eq "$PYDIR/cpython-3.11.10-linux-x86_64-gnu" "$(fl_formula_prefix python@3.11)"
assert_eq "$NODEDIR/v22.11.0/installation" "$(fl_formula_prefix node@22)"
assert_eq "/usr" "$(fl_formula_prefix mariadb@10.11)"
# nothing installed yet: the path uv and fnm will use, without starting uv in a read only command
reset_calls
assert_eq "$PYDIR/cpython-3.9-linux-x86_64-gnu/bin/python3.9" "$(FL_CONTEXT_LIGHT=1 FL_PYTHON_BIN_NAME=python3.9 fl_python_bin)"
assert_calls_not_contain '^uv '
assert_eq "$NODEDIR/v20/installation/bin/node" "$(FL_NODE_MAJOR=20 fl_node_bin)"
# and not installed by benchbar: uv is asked
reset_calls
FL_PYTHON_BIN_NAME=python3.9 fl_python_bin >/dev/null
assert_calls_contain '^uv python find 3.9$'
case "$(fl_mariadb_bin)" in /usr/bin/mariadb) ;; *) fail "mariadb is /usr/bin/mariadb" ;; esac

exports="$(fl_profile_path_exports)"
assert_contains "$exports" "export PATH=\"$PYDIR/cpython-3.11.10-linux-x86_64-gnu/bin:\$PATH\""
assert_contains "$exports" "export PATH=\"$NODEDIR/v22.11.0/installation/bin:\$PATH\""
assert_contains "$exports" 'export PATH="$HOME/.local/bin:$PATH"'
assert_not_contains "$exports" "LDFLAGS"
assert_not_contains "$exports" "CPPFLAGS"
assert_not_contains "$exports" "PKG_CONFIG_PATH"
assert_not_contains "$exports" "opt/homebrew"
v16="$(fl_profile_path_exports v16-lts)"
assert_contains "$v16" "cpython-3.14.9-linux-x86_64-gnu/bin"
assert_contains "$v16" "v24.11.0/installation/bin"
assert_eq "$HOME/.local/pipx" "$(fl_pipx_home)"

# ---- opening a URL: wslview in WSL, xdg-open elsewhere
reset_calls
fl_open_url "http://linuxdev.localhost:8000" || fail "wslview opens"
assert_calls_contain '^wslview http://linuxdev.localhost:8000$'
assert_calls_not_contain '^xdg-open '
assert_eq "wslview" "$(fl_open_cmd)"
printf 'Linux version 6.8.0-generic (buildd@lcy02) (gcc 13.2.0)\n' >"$FL_PROC_VERSION"
reset_calls
fl_open_url "http://linuxdev.localhost:8000" || fail "xdg-open opens"
assert_calls_contain '^xdg-open http://linuxdev.localhost:8000$'
assert_calls_not_contain '^wslview '
assert_eq "xdg-open" "$(fl_open_cmd)"
printf 'Linux version 5.15.0-Microsoft-standard (WSL2)\n' >"$FL_PROC_VERSION"
assert_eq "wslview" "$(fl_open_cmd)" "(microsoft in any case)"
# a failing opener fails the call; no opener at all is 127
MOCK_OPEN_EXIT=1 fl_open_url "http://x" && fail "a failing opener must fail" || true
EMPTYBIN="$TMP_DIR/emptybin"; mkdir -p "$EMPTYBIN"
rc=0; ( PATH="$EMPTYBIN"; fl_open_url "http://x" ) || rc=$?
assert_eq "127" "$rc" "(no wslview and no xdg-open)"
# the CLI's own callers
reset_calls
MOCK_CURL_CODE=200 run_fm docs; assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^wslview https://benchbar.akashmishra.com/$'
assert_calls_not_contain '^open '

# ---- the default site, also where a bench with no site is read
assert_eq "linuxdev.localhost" "$(fl_default_site)"
EMPTY="$TMP_DIR/empty-bench"; mkdir -p "$EMPTY/sites"
FL_BENCH_DIR="$EMPTY"; fl_site_detect
assert_eq "linuxdev.localhost" "$FL_SITE"
assert_eq "default" "$FL_SITE_SOURCE"
FL_BENCH_DIR="$BENCH"

# ---- state folder: XDG_STATE_HOME on Linux, the Mac unchanged, FL_STATE_DIR first
state_dir() { # state_dir PLATFORM [XDG_STATE_HOME]
  env -u FL_STATE_DIR -u FL_STATE_FILE -u XDG_STATE_HOME ${2:+XDG_STATE_HOME="$2"} FL_PLATFORM="$1" FL_INSTALL_KIND=homebrew \
    SCRIPT_DIR="$ROOT" HOME="$TMP_DIR/xdg-home" bash -c '. "$SCRIPT_DIR/lib/frappe-local/ui.sh"; . "$SCRIPT_DIR/lib/frappe-local/state.sh"; printf "%s" "$FL_STATE_DIR"'
}
mkdir -p "$TMP_DIR/xdg-home"
assert_eq "$TMP_DIR/xdg-state/benchbar" "$(state_dir linux "$TMP_DIR/xdg-state")"
assert_eq "$TMP_DIR/xdg-home/.local/state/benchbar" "$(state_dir linux)" "(XDG_STATE_HOME unset)"
assert_eq "$TMP_DIR/xdg-home/.local/state/benchbar" "$(state_dir macos "$TMP_DIR/xdg-state")" "(the Mac ignores it)"
assert_eq "$TMP_DIR/override" "$(env FL_STATE_DIR="$TMP_DIR/override" FL_PLATFORM=linux XDG_STATE_HOME="$TMP_DIR/xdg-state" SCRIPT_DIR="$ROOT" bash -c '. "$SCRIPT_DIR/lib/frappe-local/ui.sh"; . "$SCRIPT_DIR/lib/frappe-local/state.sh"; printf "%s" "$FL_STATE_DIR"')" "(FL_STATE_DIR wins)"

# ---- shell rc file: .bashrc on Linux unless the shell is zsh
rc_for() { env -u FL_RC_FILE SHELL="$1" FL_PLATFORM="$2" HOME="$TMP_DIR/rc-home" ZDOTDIR= SCRIPT_DIR="$ROOT" FL_STATE_DIR="$TMP_DIR/rc-state" bash -c \
  '. "$SCRIPT_DIR/lib/frappe-local/ui.sh"; . "$SCRIPT_DIR/lib/frappe-local/state.sh"; . "$SCRIPT_DIR/lib/frappe-local/shellrc.sh"; fl_rc_file'; }
mkdir -p "$TMP_DIR/rc-home" "$TMP_DIR/rc-state"
assert_eq "$TMP_DIR/rc-home/.bashrc" "$(rc_for /bin/bash linux)"
assert_eq "$TMP_DIR/rc-home/.bashrc" "$(rc_for /usr/bin/fish linux)" "(any shell but zsh gets .bashrc on Linux)"
assert_eq "$TMP_DIR/rc-home/.bashrc" "$(rc_for "" linux)"
assert_eq "$TMP_DIR/rc-home/.zshrc" "$(rc_for /usr/bin/zsh linux)"
assert_eq "$TMP_DIR/rc-home/.zshrc" "$(rc_for /bin/zsh macos)"
assert_eq "$TMP_DIR/rc-home/.bash_profile" "$(rc_for /bin/bash macos)" "(the Mac: no .bashrc yet, so .bash_profile as before)"

# ---- the MariaDB root password: a 0600 file in a 0700 folder, never printed
SECRET_DIR="$FL_STATE_DIR/secrets"; SECRET="$SECRET_DIR/mariadb-root"
PW='Sup3r secret/pw$with"quotes'
mode_of() { if [[ "$STAT_GNU" == "1" ]]; then stat -c %a "$1"; else stat -f %Lp "$1"; fi; }
assert_status 1 fl_keychain_get
out="$(fl_keychain_set "$PW" 2>&1)"; rc=$?
assert_eq "0" "$rc" "$out"
assert_not_contains "$out" "$PW" "(the password must not be printed)"
assert_not_contains "$out" "Sup3r"
assert_eq "600" "$(mode_of "$SECRET")"
assert_eq "700" "$(mode_of "$SECRET_DIR")"
assert_eq "$PW" "$(fl_keychain_get)"
assert_eq "1" "$(find "$SECRET_DIR" -type f | wc -l | tr -d ' ')" "(the temporary file is gone)"
# an unchanged password is not written again
before="$(snapshot "$SECRET_DIR")"
sleep 1
fl_keychain_set "$PW" >/dev/null 2>&1
assert_eq "$before" "$(snapshot "$SECRET_DIR")"
fl_keychain_set "second-pw" >/dev/null 2>&1
assert_eq "second-pw" "$(fl_keychain_get)"
assert_eq "600" "$(mode_of "$SECRET")"
# nothing but the secret file holds it
fl_keychain_set "$PW" >/dev/null 2>&1
others="$(grep -rlF -- "$PW" "$FL_STATE_DIR" 2>/dev/null | grep -v "^${SECRET}$" || true)"
assert_eq "" "$others" "(no log or state file holds the password)"
# umask 077 even under a loose umask
rm -rf "$SECRET_DIR"
( umask 000; fl_keychain_set "loose-umask" >/dev/null 2>&1 )
assert_eq "600" "$(mode_of "$SECRET")"
assert_eq "700" "$(mode_of "$SECRET_DIR")"
# dry run writes nothing; a line break or an empty password is refused
rm -rf "$SECRET_DIR"
FL_DRY_RUN=1 fl_keychain_set "dry" >/dev/null 2>&1
assert_no_file "$SECRET"
assert_status 1 fl_keychain_set ""
assert_status 1 fl_keychain_set $'a\nb'
assert_no_file "$SECRET"
fl_keychain_set "to-delete" >/dev/null 2>&1
assert_file "$SECRET"
fl_keychain_delete
assert_no_file "$SECRET"
fl_keychain_delete   # again: nothing to do, no error

# ---- the content hash is the same 12 hex digits with sha256sum as with shasum
# the real sha256sum, not the tests/mocks shim (macOS hosts have none: skipped)
REAL_SHA256SUM="$(type -ap sha256sum | grep -v '/tests/mocks/' | head -n1 || true)"
if [[ -n "$REAL_SHA256SUM" ]] && command -v shasum >/dev/null 2>&1; then
  NOSHA="$TMP_DIR/nosha"; mkdir -p "$NOSHA"
  ln -s "$REAL_SHA256SUM" "$NOSHA/sha256sum"; ln -s "$(command -v cut)" "$NOSHA/cut"
  for text in "hello" "" "a longer text with spaces and $(printf 'a\tb')"; do
    a="$(printf '%s' "$text" | fl_content_hash)"
    b="$(printf '%s' "$text" | PATH="$NOSHA" fl_content_hash)"
    assert_eq "$a" "$b" "(shasum and sha256sum agree on [$text])"
    [[ "$a" =~ ^[0-9a-f]{12}$ ]] || fail "12 hex digits expected, got $a"
  done
else
  printf 'test-platform-linux: SKIP the sha256sum comparison (needs both shasum and sha256sum)\n'
fi

# ---- sudo: a NOPASSWD rule next to a password rule (Ubuntu's %sudo line)
# makes "sudo -v" ask even though commands need no password; the session
# starts without "sudo -v" then. A cached credential alone still goes
# through "sudo -v", as before.
(
  # shellcheck source=lib/frappe-local/sudo.sh
  . "$ROOT/lib/frappe-local/sudo.sh"
  rm -f "$MOCK_STATE/sudo_cred"; touch "$MOCK_STATE/sudo_nopasswd"; reset_calls
  FL_SUDO_SESSION=0; FL_SUDO_REFUSED=0
  fl_sudo_begin "test reason" >/dev/null 2>&1 || fail "fl_sudo_begin refused under NOPASSWD"
  assert_eq "1" "$FL_SUDO_SESSION" "(NOPASSWD starts a session)"
  assert_calls_not_contain '^sudo -v' "(no sudo -v under NOPASSWD)"
  fl_sudo_end
  rm -f "$MOCK_STATE/sudo_nopasswd"; touch "$MOCK_STATE/sudo_cred"; reset_calls
  FL_SUDO_SESSION=0; FL_SUDO_REFUSED=0
  fl_sudo_begin "test reason" >/dev/null 2>&1 || fail "fl_sudo_begin refused with a cached credential"
  assert_calls_contain '^sudo -v' "(a cached credential still goes through sudo -v)"
  fl_sudo_end
)

printf 'test-platform-linux: ok\n'
