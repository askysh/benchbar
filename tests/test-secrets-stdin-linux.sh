#!/usr/bin/env bash
#
# The secret channel on Linux (askysh/benchbar#167): BENCHBAR_SUDO=env with the
# sudo password on standard input (--secrets-stdin) and not in the
# environment. The right one runs every sudo step, a wrong one fails before any
# change (sudo_password_wrong), the passwords are in no argument, no log, no
# output and no environment (the mocks record what they see in sudo_leak), and
# BENCHBAR_SUDO_PASSWORD without BENCHBAR_SUDO=env is refused, not ignored.
# shellcheck disable=SC2016,SC2030,SC2031  # the bash -c scripts are single quoted on purpose
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
use_linux
# no Windows netstat: the owner's PC may hold the ports of the install
export FL_WIN_NETSTAT=/nonexistent/netstat.exe

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
# the installers are pinned by URL and sha256 (INST-9); a test is a mirror, so it
# names its own URLs and the sums of the scripts above
export UV_INSTALLER_URL=https://astral.sh/uv/install.sh FNM_INSTALLER_URL=https://fnm.vercel.app/install
UV_INSTALLER_SHA256="$(shasum -a 256 "$MOCK_STATE/http/$(key "$UV_INSTALLER_URL")" | awk '{print $1}')"
FNM_INSTALLER_SHA256="$(shasum -a 256 "$MOCK_STATE/http/$(key "$FNM_INSTALLER_URL")" | awk '{print $1}')"
export UV_INSTALLER_SHA256 FNM_INSTALLER_SHA256


# the machine's sudo asks for this password and has no terminal (see the sudo mock)
SECRET='Zq7!pass w0rd#Xk'
printf '%s\n' "$SECRET" >"$MOCK_STATE/sudo_password"
rm -f "$MOCK_STATE/sudo_cred"
LOGS="$FL_STATE_DIR/logs"
BENCH="$HOME/frappe-bench"
pw_file() { printf '%s' "$FL_STATE_DIR/secrets/mariadb-root"; }
fresh_machine() {
  : >"$MOCK_STATE/apt_installed"
  : >"$MOCK_LISTEN"
  rm -rf "$HOME/.local/share/uv" "$HOME/.local/share/fnm" "$HOME/.local/bin/uv" "$FL_STATE_DIR/secrets" "$FL_STATE_DIR/downloads" \
    "$FL_MYSQL_CONF_DIR" "$MOCK_STATE/installer_env" "$MOCK_STATE/stopped_mariadb" "$MOCK_STATE/stopped_redis-server" "$BENCH"
  mkdir -p "$FL_MYSQL_CONF_DIR"
  rm -f "$MOCK_STATE/mariadb_root_pw" "$MOCK_STATE/mariadb_sql.log" "$MOCK_STATE/wkhtml_installed" "$MOCK_STATE/sudo_leak" "$MOCK_STATE"/sudo_ticket.*
  touch "$MOCK_STATE/wkhtml_missing"
  printf '# test bashrc\nexport EDITOR=vim\n' >"$HOME/.bashrc"
  : >"$FL_STATE_FILE"
  reset_calls
}
# run_in INPUT ENV... -- ARGS...: benchbar with INPUT on standard input (a pipe) and BENCHBAR_SUDO=env unless ENV says otherwise
run_in() {
  local input="$1"; shift
  set +e
  OUT="$(printf '%s
' "$input" | env BENCHBAR_NONINTERACTIVE=1 "$@" 2>&1)"
  CODE=$?
  set -e
}
ADM='Adm1n-L1nux-0451'
# the password is nowhere it must not be: mock calls, the run logs, the output, files, a child's environment
assert_no_secret() {
  assert_not_contains "$OUT" "$SECRET" "(output) $1"
  assert_not_contains "$(cat "$MOCK_LOG")" "$SECRET" "(mock calls) $1"
  assert_not_contains "$OUT" "$ADM" "(output, admin) $1"
  if [[ -d "$LOGS" ]] && grep -rqF -- "$SECRET" "$LOGS"; then fail "the password is in the run log: $1"; fi
  if grep -rqF --exclude-dir=mock --exclude=sudo_password -- "$SECRET" "$TMP_DIR" 2>/dev/null; then
    fail "the password is in a file under the test folder: $1 ($(grep -rlF --exclude-dir=mock --exclude=sudo_password -- "$SECRET" "$TMP_DIR" | awk 'NR<=3' | tr '\n' ' '))"
  fi
  [[ ! -s "$MOCK_STATE/sudo_leak" ]] || fail "a program got the password in its arguments or environment: $1"$'\n'"$(cat "$MOCK_STATE/sudo_leak")"
}

# ---- the sudo password on stdin: every sudo step runs, nothing leaks
fresh_machine
run_in "BENCHBAR_SUDO_PASSWORD=${SECRET}
ADMIN_PASSWORD=${ADM}
" BENCHBAR_SUDO=env "$FM" install --offline --yes --json --secrets-stdin --bench-dir "$BENCH" --site linuxdev.localhost
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^sudo -S -p +-v$' "(the password was checked once with -S)"
assert_calls_contain '^sudo apt-get install -y mariadb-server' "(apt ran through sudo)"
assert_calls_contain '^bench new-site linuxdev.localhost' "(phase 01 ran)"
assert_no_secret "stdin install --json"

# ---- a wrong password on stdin fails before any change, with a stable id
fresh_machine
snap="$(find "$HOME" -type f 2>/dev/null | wc -l | tr -d ' ')"
run_in "BENCHBAR_SUDO_PASSWORD=not the password
ADMIN_PASSWORD=${ADM}
" BENCHBAR_SUDO=env "$FM" install --offline --yes --json --secrets-stdin --bench-dir "$BENCH" --site linuxdev.localhost
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" '"error_id":"sudo_password_wrong"'
assert_calls_not_contain '^sudo apt-get'
assert_not_contains "$OUT" "not the password" "(the wrong password is not printed either)"

# ---- the sudo password without BENCHBAR_SUDO=env is refused, not ignored
fresh_machine
run_in "BENCHBAR_SUDO_PASSWORD=${SECRET}
ADMIN_PASSWORD=${ADM}
" BENCHBAR_SUDO=gui "$FM" install --offline --yes --json --secrets-stdin --bench-dir "$BENCH" --site linuxdev.localhost
assert_eq "64" "$CODE" "$OUT"
assert_contains "$OUT" "BENCHBAR_SUDO=env"
assert_contains "$OUT" "secrets_stdin_invalid"
assert_not_contains "$OUT" "$SECRET"
assert_calls_not_contain '^sudo apt-get'

# ---- bash -x: the trace of a run with the passwords on stdin shows none of them
fresh_machine
trace="$(printf 'BENCHBAR_SUDO_PASSWORD=%s\nADMIN_PASSWORD=%s\nMARIADB_ROOT_PASSWORD=%s\n\n' "$SECRET" "$ADM" "Rt-L1nux-0451" \
  | env BENCHBAR_SUDO=env BENCHBAR_NONINTERACTIVE=1 bash -x "$FM" install --offline --dry-run --yes --json --secrets-stdin --bench-dir "$BENCH" --site linuxdev.localhost 2>&1 >/dev/null || true)"
assert_contains "$trace" "fl__secrets_read" "(the trace is the run's)"
assert_not_contains "$trace" "$SECRET" "(xtrace)"
assert_not_contains "$trace" "$ADM" "(xtrace)"
assert_not_contains "$trace" "Rt-L1nux-0451" "(xtrace)"
