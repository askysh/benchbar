#!/usr/bin/env bash
#
# The Linux install path under mocks: phase 00 (apt, uv, fnm, MariaDB over its
# unix socket, the utf8mb4 drop-in, Redis, the wkhtmltopdf .deb, the shell
# block), the MariaDB root password file, phase 01's Linux defaults, the
# benchbar install entry point and the hosts functions that do nothing here.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
use_linux

# ---- the machine: Ubuntu 24.04 with systemd, a socket-only MariaDB root
XBIN="$MOCK_STATE/xbin"; FRESHBIN="$MOCK_STATE/fresh/bin"
mkdir -p "$XBIN" "$FRESHBIN"
# the mocks look for their helpers next to bin/ (env-python, honcho, python3.11)
for f in "$ROOT"/tests/mocks/*; do [[ -f "$f" ]] && ln -sf "$f" "$MOCK_STATE/fresh/${f##*/}"; done
cp "$ROOT/tests/mocks/bin/_mocklib.sh" "$XBIN/"
cp "$ROOT/tests/mocks/mariadb" "$XBIN/mariadb"
# a systemctl for the system units mariadb and redis-server: active when their
# apt package is installed (apt starts them), until stopped; start clears that
cat >"$XBIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
. "$(dirname "$0")/_mocklib.sh"
# the user units belong to the shared systemctl mock
for a in "$@"; do [[ "$a" == "--user" ]] && exec "__ROOT__/tests/mocks/bin/systemctl" "$@"; done
mock_log "$@"
args=()
for a in "$@"; do case "$a" in --quiet|--no-pager) ;; *) args+=("$a") ;; esac; done
verb="${args[0]:-}"; unit="${args[1]:-}"
case "$unit" in mariadb) pkg=mariadb-server ;; redis-server) pkg=redis-server ;; *) pkg="" ;; esac
case "$verb" in
  is-active)
    [[ -n "$pkg" && ! -f "$MOCK_STATE/stopped_$unit" ]] && grep -qx "$pkg" "$MOCK_STATE/apt_installed" 2>/dev/null && exit 0
    exit 3 ;;
  start|restart) rm -f "$MOCK_STATE/stopped_$unit" ;;
  stop) touch "$MOCK_STATE/stopped_$unit" ;;
esac
exit 0
MOCK
sed_inplace "s#__ROOT__#$ROOT#" "$XBIN/systemctl"; chmod +x "$XBIN/systemctl"
chmod +x "$XBIN/systemctl" "$XBIN/mariadb"
# the mock tools minus uv and fnm: the installers below put those in place
for f in "$ROOT"/tests/mocks/bin/*; do
  case "${f##*/}" in uv|fnm) ;; *) ln -sf "$f" "$FRESHBIN/${f##*/}" ;; esac
done
# no uv or fnm of the machine running the suite either
export PATH="$XBIN:$FRESHBIN:/usr/bin:/bin"
export FL_MARIADB_BIN="$XBIN/mariadb"
export FL_MYSQL_CONF_DIR="$MOCK_STATE/mysql-conf.d" FL_SYSTEMD_RUN_DIR="$MOCK_STATE/run-systemd" FL_MARIADB_DATA_DIR="$MOCK_STATE/var-lib-mysql"
export MOCK_MARIADB_ROOT_SOCKET_ONLY=1
mkdir -p "$FL_SYSTEMD_RUN_DIR"
# the installers' scripts the curl mock serves: they put wrappers around the mocks in place
key() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
mkdir -p "$MOCK_STATE/http"
cat >"$MOCK_STATE/http/$(key https://astral.sh/uv/install.sh)" <<SCRIPT
#!/bin/sh
mkdir -p "\$HOME/.local/bin"
printf '#!/usr/bin/env bash\nexec "$ROOT/tests/mocks/bin/uv" "\$@"\n' >"\$HOME/.local/bin/uv"
chmod +x "\$HOME/.local/bin/uv"
printf 'UV_NO_MODIFY_PATH=%s\n' "\$UV_NO_MODIFY_PATH" >>"$MOCK_STATE/installer_env"
SCRIPT
cat >"$MOCK_STATE/http/$(key https://fnm.vercel.app/install)" <<SCRIPT
#!/usr/bin/env bash
dir=""; while [[ "\$#" -gt 0 ]]; do case "\$1" in --install-dir) dir="\$2"; shift 2 ;; *) shift ;; esac; done
printf 'fnm installer args: --install-dir %s\n' "\$dir" >>"$MOCK_STATE/installer_env"
mkdir -p "\$dir"
printf '#!/usr/bin/env bash\nexec "$ROOT/tests/mocks/bin/fnm" "\$@"\n' >"\$dir/fnm"
chmod +x "\$dir/fnm"
SCRIPT

run00() { set +e; OUT="$("$ROOT/00-linux-system-deps.sh" "$@" 2>&1)"; CODE=$?; set -e; }
run01() { set +e; OUT="$("$ROOT/01-install-bench-and-site.sh" "$@" 2>&1)"; CODE=$?; set -e; }
pw_file() { printf '%s' "$FL_STATE_DIR/secrets/mariadb-root"; }
perm_of() { if [[ "$STAT_GNU" == "1" ]]; then stat -c %a "$1"; else stat -f %Lp "$1"; fi; }
count_calls() { grep -c -E "$1" "$MOCK_LOG" || true; }

fresh_machine() {
  : >"$MOCK_STATE/apt_installed"
  rm -rf "$HOME/.local/share/uv" "$HOME/.local/share/fnm" "$HOME/.local/bin/uv" "$FL_STATE_DIR/secrets" "$FL_STATE_DIR/downloads" \
    "$FL_MYSQL_CONF_DIR" "$MOCK_STATE/installer_env" "$MOCK_STATE/stopped_mariadb" "$MOCK_STATE/stopped_redis-server"
  mkdir -p "$FL_MYSQL_CONF_DIR"
  rm -f "$MOCK_STATE/mariadb_root_pw" "$MOCK_STATE/mariadb_sql.log" "$MOCK_STATE/wkhtml_installed"
  touch "$MOCK_STATE/wkhtml_missing"
  printf '# test bashrc\nexport EDITOR=vim\n' >"$HOME/.bashrc"
  printf '127.0.0.1 localhost\n' >"$FL_HOSTS_FILE"
  reset_calls
}

# ---- platform choice and the Linux profile gate (no mutation at all)
fresh_machine
run00 --profile v16-lts --yes
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "not supported on Linux yet"
assert_contains "$OUT" "v15-lts is"
assert_calls_not_contain '^(sudo|apt-get|uv|fnm|curl .*(wkhtmltox|astral|fnm))'
run_fm install --profile v16-lts --dry-run
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "not supported on Linux yet"
assert_calls_not_contain '^(sudo|apt-get|uv|fnm|curl .*(wkhtmltox|astral|fnm))'

# ---- dry run on a fresh machine: the plan, no sudo, no apt-get, no installer
run00 --profile v15-lts --dry-run
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "DRY RUN"
assert_contains "$OUT" "dry-run: sudo apt-get install -y mariadb-server"
assert_contains "$OUT" "dry-run: would ask for your password once (sudo)"
assert_contains "$OUT" "uv python install 3.11"
assert_contains "$OUT" "fnm install 22"
assert_calls_not_contain '^(sudo|apt-get|uv|fnm|curl .*(wkhtmltox|astral|fnm))'
[[ ! -s "$(pw_file)" ]] || fail "a dry run must not write the password file"
assert_no_file "$FL_MYSQL_CONF_DIR/99-frappe.cnf"
run_fm install --dry-run --yes --bench-dir "$HOME/frappe-bench"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "System dependencies (00-linux-system-deps.sh)"
assert_contains "$OUT" "linuxdev.localhost"
assert_calls_not_contain '^(sudo|apt-get|uv|fnm)'
assert_eq "127.0.0.1 localhost" "$(cat "$FL_HOSTS_FILE")" "(no hosts line on Linux)"

# ---- 00 on a fresh machine: apt, uv, fnm, the socket-only root, the drop-in, the .deb
fresh_machine
run00 --yes --profile v15-lts
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "Ubuntu 24.04 detected, running in WSL"
assert_eq "1" "$(count_calls '^sudo -v$')" "(one sudo prompt for the whole run)"
assert_contains "$OUT" "install the apt packages: mariadb-server mariadb-client redis-server build-essential pkg-config libmariadb-dev libssl-dev libffi-dev zlib1g-dev git curl zip"
assert_calls_contain '^sudo apt-get update$'
assert_calls_contain '^sudo apt-get install -y mariadb-server mariadb-client redis-server build-essential pkg-config libmariadb-dev libssl-dev libffi-dev zlib1g-dev git curl zip'
# uv and fnm installers (no sudo, no shell edits), then Python and Node through them
assert_calls_contain '^curl .*https://astral.sh/uv/install.sh'
assert_calls_contain '^curl .*https://fnm.vercel.app/install'
assert_contains "$(cat "$MOCK_STATE/installer_env")" "UV_NO_MODIFY_PATH=1"
assert_contains "$(cat "$MOCK_STATE/installer_env")" "fnm installer args: --install-dir $HOME/.local/share/fnm"
assert_calls_contain '^uv python install 3.11$'
assert_calls_contain '^fnm install 22$'
assert_contains "$OUT" "[OK] python3.11 - 3.11.9"
assert_contains "$OUT" "[OK] node - v22."
assert_contains "$OUT" "[OK] yarn - "
assert_calls_not_contain '^sudo (curl|sh|bash|uv|fnm|npm)( |$)' "(the third party installers run as the user)"
# MariaDB: started by apt, then root administered over the socket with sudo
assert_contains "$OUT" "[OK] mariadb - 10.11.14"
assert_contains "$OUT" "logs in over the socket only (a fresh apt install); setting a password (generated) through sudo mariadb"
assert_calls_contain "^sudo $XBIN/mariadb --protocol=socket -u root"
PW="$(cat "$(pw_file)")"
[[ "${#PW}" -ge 20 ]] || fail "a generated password is expected in the password file, got [$PW]"
assert_eq "$PW" "$(mariadb_pw)" "(the file and MariaDB must agree)"
assert_eq "600" "$(perm_of "$(pw_file)")"
assert_eq "700" "$(perm_of "$FL_STATE_DIR/secrets")"
assert_contains "$OUT" "saved to $(pw_file)"
sql="$(cat "$MOCK_STATE/mariadb_sql.log")"
assert_contains "$sql" "DELETE FROM mysql.global_priv WHERE User='';"
assert_contains "$sql" "Host NOT IN ('localhost', '127.0.0.1', '::1')"
assert_contains "$sql" "DROP DATABASE IF EXISTS test;"
assert_contains "$sql" "ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('"
assert_contains "$OUT" "MariaDB root password set, anonymous users and the test database removed, remote root blocked"
# the password is never printed, on a command line, or in a log
assert_not_contains "$OUT" "$PW" "(the password is never printed)"
assert_not_contains "$(cat "$MOCK_LOG")" "$PW" "(the password is never on a command line)"
if grep -rqF --exclude-dir=secrets -- "$PW" "$FL_STATE_DIR"; then fail "the password is in a file of the state folder"; fi
# the drop-in goes in with sudo install, then MariaDB restarts
assert_file "$FL_MYSQL_CONF_DIR/99-frappe.cnf"
grep -q 'character-set-server = utf8mb4' "$FL_MYSQL_CONF_DIR/99-frappe.cnf" || fail "utf8mb4 config expected"
assert_calls_contain "^sudo install -m 0644 .* ${FL_MYSQL_CONF_DIR}/99-frappe.cnf\$"
assert_calls_contain '^sudo systemctl restart mariadb$'
# Redis is the apt unit
assert_contains "$OUT" "[OK] redis-server is running"
# the pinned .deb: downloaded, checksummed by the user and by root, installed through apt
assert_calls_contain '^curl .*wkhtmltox_0.12.6.1-3.jammy_amd64.deb'
assert_contains "$OUT" "sha256 ok"
assert_calls_contain '^sudo sha256sum /tmp/benchbar-wkhtmltopdf\..*/wkhtmltox_0.12.6.1-3.jammy_amd64.deb$'
assert_calls_contain '^sudo apt-get install -y /tmp/benchbar-wkhtmltopdf\..*/wkhtmltox_0.12.6.1-3.jammy_amd64.deb$'
assert_file "$FL_STATE_DIR/downloads/wkhtmltox_0.12.6.1-3.jammy_amd64.deb"
assert_contains "$OUT" "[OK] wkhtmltopdf 0.12.6 (with patched qt)"
assert_calls_not_contain '(softwareupdate|installer -pkg|brew)' "(no Mac tool is called)"
# the credential is dropped before the uv and fnm installers
assert_calls_contain '^sudo -k$'
# the shell block is in ~/.bashrc with the uv Python and fnm Node folders
grep -q -x -F "# >>> benchbar >>>" "$HOME/.bashrc" || fail "00 must write the benchbar block"
grep -q "uv/python/cpython-3.11" "$HOME/.bashrc" || fail "the uv Python folder is expected in the block"
grep -q "fnm/node-versions/v22" "$HOME/.bashrc" || fail "the fnm Node folder is expected in the block"
assert_contains "$OUT" "source ${HOME}/.bashrc"
# nothing touched /etc/hosts or the Homebrew world
assert_eq "127.0.0.1 localhost" "$(cat "$FL_HOSTS_FILE")"
assert_calls_not_contain 'hosts'

# ---- second run: unchanged everywhere, no sudo, no apt-get install, no installer
reset_calls; : >"$MOCK_STATE/mariadb_sql.log"
snap_before="$(snapshot "$HOME" "$FL_MYSQL_CONF_DIR" "$FL_STATE_DIR/secrets")"
sleep 1
run00 --yes --profile v15-lts
assert_eq "0" "$CODE" "$OUT"
assert_eq "$snap_before" "$(snapshot "$HOME" "$FL_MYSQL_CONF_DIR" "$FL_STATE_DIR/secrets")" "(00 rerun must write nothing)"
assert_calls_not_contain '^sudo ' "(a set up machine never asks for sudo)"
assert_calls_not_contain '^apt-get (install|update)'
assert_calls_not_contain '^(uv python install|fnm install|curl .*(wkhtmltox|astral|fnm))'
[[ ! -s "$MOCK_STATE/mariadb_sql.log" ]] || fail "no SQL on a rerun"
assert_contains "$OUT" "[OK] unchanged: all apt packages are installed"
assert_contains "$OUT" "[OK] MariaDB root password verified (password file, unchanged)"
assert_contains "$OUT" "[OK] frappe.cnf utf8mb4 config present"
assert_contains "$OUT" "[OK] mariadb is running"
assert_contains "$OUT" "[OK] redis-server is running"
assert_contains "$OUT" "[OK] wkhtmltopdf patched Qt build"
assert_contains "$OUT" "has the benchbar block"
assert_contains "$OUT" "All dependencies are configured"
assert_not_contains "$OUT" "$PW"

# ---- 01 on Linux: site linuxdev.localhost, the password from the file, no hosts check
BENCH="$HOME/frappe-bench"
ADMIN_PASSWORD=adminpw run01 --yes --offline
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "MariaDB root password read from the password file"
assert_calls_contain '^bench new-site linuxdev.localhost'
assert_contains "$OUT" "http://linuxdev.localhost:8000"
assert_not_contains "$OUT" "/etc/hosts"
assert_not_contains "$(cat "$MOCK_LOG")" "$PW" "(phase 01 passes the password on stdin, not argv)"
assert_not_contains "$OUT" "$PW"
assert_calls_not_contain '(brew|pipx)'
assert_eq "127.0.0.1 localhost" "$(cat "$FL_HOSTS_FILE")"
rm -rf "$BENCH"
# a name that does not resolve gets the command to run by hand
ADMIN_PASSWORD=adminpw SITE_NAME=erp.test run01 --yes --offline
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "erp.test does not resolve to this machine; add it to /etc/hosts yourself"
assert_eq "127.0.0.1 localhost" "$(cat "$FL_HOSTS_FILE")" "(benchbar never edits /etc/hosts on Linux)"
rm -rf "$BENCH"
# the profile gate is in phase 01 too
run01 --yes --offline --profile v16-lts
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "not supported on Linux yet"
# the hosts functions: *.localhost always reaches the machine; the JSON keeps its keys
make_fake_bench "$BENCH" linuxdev.localhost
run_fm site list --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "True" "$(printf '%s' "$OUT" | jget - "d['sites'][0]['hosts_entry']")"
assert_eq "linuxdev.localhost" "$(printf '%s' "$OUT" | jget - "d['sites'][0]['name']")"
assert_eq "None" "$(printf '%s' "$OUT" | jget - "d['sites'][0]['ping_code']")"
run_fm site hosts --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain '^sudo '
rm -rf "$BENCH"

# ---- MARIADB_ROOT_PASSWORD on a fresh machine: that password is set, kept in the file, never shown
fresh_machine
MARIADB_ROOT_PASSWORD='My0wnPassw0rd' run00 --yes --profile v15-lts
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "setting a password (environment) through sudo mariadb"
assert_eq "My0wnPassw0rd" "$(cat "$(pw_file)")"
assert_eq "My0wnPassw0rd" "$(mariadb_pw)"
assert_not_contains "$OUT" "My0wnPassw0rd"
assert_not_contains "$(cat "$MOCK_LOG")" "My0wnPassw0rd"
assert_eq "1" "$(count_calls '^sudo -v$')"

# ---- an existing password nobody knows: exit 2 with the manual step; the env var fixes it
rm -rf "$FL_STATE_DIR/secrets"; reset_calls
printf 'olderpw' >"$MOCK_STATE/mariadb_root_pw"
run00 --yes --profile v15-lts
assert_eq "2" "$CODE" "$OUT"
assert_contains "$OUT" "PENDING MANUAL STEPS"
assert_contains "$OUT" "MARIADB_ROOT_PASSWORD='the password'"
assert_contains "$OUT" "sudo mariadb -e \"ALTER USER 'root'@'localhost'"
assert_eq "olderpw" "$(mariadb_pw)" "(an existing password is never replaced)"
assert_no_file "$(pw_file)"
MARIADB_ROOT_PASSWORD=wrongpw run00 --yes --profile v15-lts
assert_eq "2" "$CODE" "$OUT"
assert_contains "$OUT" "does not work"
MARIADB_ROOT_PASSWORD=olderpw run00 --yes --profile v15-lts
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "verified (from MARIADB_ROOT_PASSWORD)"
assert_eq "olderpw" "$(cat "$(pw_file)")"
assert_eq "600" "$(perm_of "$(pw_file)")"
run_fm mariadb-password --yes
assert_eq "0" "$CODE" "$OUT"
assert_eq "olderpw" "$OUT"
rm -rf "$FL_STATE_DIR/secrets"
run_fm mariadb-password --yes
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "no MariaDB root password in $(pw_file)"

# ---- sudo refused: nothing is installed, the run says how to continue
fresh_machine
touch "$MOCK_STATE/sudo_refused"
run00 --yes --profile v15-lts
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "sudo is needed to set up the system dependencies"
assert_calls_not_contain '^(apt-get|uv|fnm|curl .*(wkhtmltox|astral|fnm))'
rm -f "$MOCK_STATE/sudo_refused"

# ---- a tampered .deb: the checksum stops it, apt never sees it, the run goes on
fresh_machine
printf 'tampered\n' >"$MOCK_STATE/download_payload"
run00 --yes --profile v15-lts
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "checksum mismatch"
assert_contains "$OUT" "wkhtmltopdf            FAILED"
assert_calls_not_contain '^sudo apt-get install -y /tmp/benchbar-wkhtmltopdf'
printf 'stub download\n' >"$MOCK_STATE/download_payload"

# ---- benchbar install: the Linux phase 00 is chosen, one sudo prompt, then phase 01
fresh_machine
rm -rf "$BENCH"; : >"$FL_STATE_FILE"
export ADMIN_PASSWORD=adminpw
# what ran before the background service step (its own sudo needs are the service layer's)
before_service() { sed '/^systemctl --user/,$d' "$MOCK_LOG"; }
run_fm install --yes --bench-dir "$BENCH" --site linuxdev.localhost
assert_contains "$OUT" "1. System dependencies (00-linux-system-deps.sh)"
assert_contains "$OUT" "install the apt packages: mariadb-server"
assert_eq "1" "$(before_service | grep -c '^sudo -v$')" "(one sudo prompt for phases 00 and 01)"
# no /etc/hosts write (doctor's read only "getent hosts" is fine)
assert_not_contains "$(before_service)" "/etc/hosts"
assert_not_contains "$(before_service)" "tee -a"
assert_not_contains "$(cat "$MOCK_LOG")" "softwareupdate"
assert_not_contains "$(cat "$MOCK_LOG")" "installer -pkg"
assert_calls_contain '^bench new-site linuxdev.localhost'
PW="$(cat "$(pw_file)")"
assert_not_contains "$OUT" "$PW"
assert_not_contains "$(cat "$MOCK_LOG")" "$PW"
# the second install asks for nothing in phases 00 and 01
reset_calls
run_fm install --yes --bench-dir "$BENCH" --site linuxdev.localhost
assert_eq "0" "$(before_service | grep -c '^sudo ')"
assert_eq "0" "$(before_service | grep -c -E '^apt-get (install|update)')"
assert_not_contains "$OUT" "install the apt packages"
unset ADMIN_PASSWORD
