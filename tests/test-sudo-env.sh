#!/usr/bin/env bash
#
# BENCHBAR_SUDO=env on Linux: the sudo password comes in the environment of a
# program without a terminal (the Windows tray). It is checked once, up front,
# with "sudo -S" (a wrong one fails before any change, error_id
# sudo_password_wrong), the install, adopt, repair, site add and ports apply
# sudo steps then run without a prompt, and the password is never in an
# argument, never traced by "bash -x", never in the run log and never in the
# environment of a child (the mocks record what they see in sudo_leak).
# shellcheck disable=SC2016,SC2030,SC2031  # the bash -c scripts are single quoted on purpose; the subshell blocks keep their exports to themselves
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


# the machine's sudo asks for this password and has no terminal (see the sudo mock)
SECRET='Zq7!pass w0rd#Xk'
printf '%s\n' "$SECRET" >"$MOCK_STATE/sudo_password"
rm -f "$MOCK_STATE/sudo_cred"
LOGS="$FL_STATE_DIR/logs"
BENCH="$HOME/frappe-bench"
pw_file() { printf '%s' "$FL_STATE_DIR/secrets/mariadb-root"; }
fresh_machine() {
  : >"$MOCK_STATE/apt_installed"
  rm -rf "$HOME/.local/share/uv" "$HOME/.local/share/fnm" "$HOME/.local/bin/uv" "$FL_STATE_DIR/secrets" "$FL_STATE_DIR/downloads" \
    "$FL_MYSQL_CONF_DIR" "$MOCK_STATE/installer_env" "$MOCK_STATE/stopped_mariadb" "$MOCK_STATE/stopped_redis-server" "$BENCH"
  mkdir -p "$FL_MYSQL_CONF_DIR"
  rm -f "$MOCK_STATE/mariadb_root_pw" "$MOCK_STATE/mariadb_sql.log" "$MOCK_STATE/wkhtml_installed" "$MOCK_STATE/sudo_leak" "$MOCK_STATE"/sudo_ticket.*
  touch "$MOCK_STATE/wkhtml_missing"
  printf '# test bashrc\nexport EDITOR=vim\n' >"$HOME/.bashrc"
  : >"$FL_STATE_FILE"
  reset_calls
}
# run_env PASSWORD ARGS...: benchbar with BENCHBAR_SUDO=env, no terminal, the password only in the child's environment
run_env() {
  local pw="$1"
  shift
  set +e
  OUT="$(env BENCHBAR_SUDO=env BENCHBAR_NONINTERACTIVE=1 ${pw:+BENCHBAR_SUDO_PASSWORD="$pw"} "$FM" "$@" 2>&1 </dev/null)"
  CODE=$?
  set -e
}
# the password is nowhere it must not be: mock calls, the run logs, the output
assert_no_secret() {
  assert_not_contains "$OUT" "$SECRET" "(output) $1"
  assert_not_contains "$(cat "$MOCK_LOG")" "$SECRET" "(mock calls) $1"
  if [[ -d "$LOGS" ]] && grep -rqF -- "$SECRET" "$LOGS"; then fail "the password is in the run log: $1"; fi
  if grep -rqF --exclude-dir=mock --exclude=sudo_password -- "$SECRET" "$TMP_DIR" 2>/dev/null; then
    fail "the password is in a file under the test folder: $1 ($(grep -rlF --exclude-dir=mock --exclude=sudo_password -- "$SECRET" "$TMP_DIR" | head -n3 | tr '\n' ' '))"
  fi
  [[ ! -s "$MOCK_STATE/sudo_leak" ]] || fail "a program got the password in its arguments or environment: $1"$'\n'"$(cat "$MOCK_STATE/sudo_leak")"
}
export ADMIN_PASSWORD=adminpw

# ---- sudo-env.sh: the password leaves the environment before anything runs
leave="$(env BENCHBAR_SUDO=env BENCHBAR_SUDO_PASSWORD="$SECRET" bash -c '
  . "$1/lib/frappe-local/sudo-env.sh"
  # a variable of this shell, not of its children
  [[ "$FL_SUDO_PW" == "$2" ]] || echo "NOT-CAPTURED"
  env | grep -c -F -- "$2" || true
  bash -c "env" | grep -c -F -- "$2" || true
  declare -p BENCHBAR_SUDO_PASSWORD 2>&1 | grep -c "not found" || true' _ "$ROOT" "$SECRET")"
assert_eq $'0\n0\n1' "$leave" "(captured, unexported, not in env, not in a child, the variable is gone)"
# without BENCHBAR_SUDO=env the variable is dropped and nothing is kept
leave="$(env BENCHBAR_SUDO_PASSWORD="$SECRET" bash -c '
  . "$1/lib/frappe-local/sudo-env.sh"
  printf "[%s]" "$FL_SUDO_PW"; env | grep -c BENCHBAR_SUDO_PASSWORD || true' _ "$ROOT")"
assert_eq $'[]0' "$leave" "(no env mode: dropped, not kept)"
# the descriptor a parent passes: read once, closed
leave="$(env BENCHBAR_SUDO=env FL_SUDO_PW_FD=8 bash -c '
  . "$1/lib/frappe-local/sudo-env.sh"
  [[ "$FL_SUDO_PW" == "$2" ]] && echo captured
  [[ ! -e /proc/self/fd/8 ]] && echo closed
  env | grep -c FL_SUDO_PW_FD || true' _ "$ROOT" "$SECRET" 8< <(printf '%s\n' "$SECRET"))"
assert_eq $'captured\nclosed\n0' "$leave" "(fd handoff: read, closed, variable removed)"
# xtrace on: no line shows the value
trace="$(env BENCHBAR_SUDO=env BENCHBAR_SUDO_PASSWORD="$SECRET" bash -x -c '. "$1/lib/frappe-local/sudo-env.sh"; echo done' _ "$ROOT" 2>&1)"
assert_contains "$trace" "done"
assert_not_contains "$trace" "$SECRET" "(sudo-env.sh under xtrace)"
assert_not_contains "$trace" "Zq7"

# ---- install --json, the right password: every sudo step runs, nothing leaks
fresh_machine
run_env "$SECRET" install --yes --json --bench-dir "$BENCH" --site linuxdev.localhost
assert_eq "0" "$CODE" "$OUT"
done_line="$(printf '%s\n' "$OUT" | grep '"event":"done"' | tail -n1)"
assert_eq "0" "$(printf '%s' "$done_line" | jget - "d['exit']")" "$done_line"
assert_not_contains "$done_line" "error_id"
assert_calls_contain '^sudo -S -p +-v$' "(the password was checked once with -S, prompt empty)"
assert_calls_contain '^sudo apt-get install -y mariadb-server' "(apt ran through sudo)"
assert_calls_contain "^sudo $XBIN/mariadb --protocol=socket -u root" "(the MariaDB admin step ran through sudo)"
assert_calls_contain "^sudo install -m 0644 .* ${FL_MYSQL_CONF_DIR}/99-frappe.cnf\$"
assert_calls_contain '^sudo systemctl restart mariadb$'
assert_calls_contain '^sudo apt-get install -y /tmp/benchbar-wkhtmltopdf'
assert_calls_contain '^bench new-site linuxdev.localhost' "(phase 01 ran after phase 00)"
assert_file "$(pw_file)"
assert_no_secret "install --json"
# after phase 00 the credential is dropped and the password forgotten: nothing later can sudo
assert_calls_contain '^sudo -k$'
last_sudo="$(grep -n '^sudo ' "$MOCK_LOG" | tail -n1 | cut -d: -f1)"
first_bench="$(grep -n '^bench ' "$MOCK_LOG" | head -n1 | cut -d: -f1)"
[[ "$last_sudo" -lt "$first_bench" ]] || fail "sudo was used after the bench steps began (last sudo line $last_sudo, first bench line $first_bench)"

# ---- a second run on the set up machine asks for nothing
reset_calls
run_env "$SECRET" install --yes --json --bench-dir "$BENCH" --site linuxdev.localhost
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain '^sudo apt-get'
assert_no_secret "install --json, second run"

# ---- a wrong password fails before any change, with a stable id
fresh_machine
run_env "not the password" install --yes --json --bench-dir "$BENCH" --site linuxdev.localhost
assert_eq "1" "$CODE" "$OUT"
done_line="$(printf '%s\n' "$OUT" | grep '"event":"done"' | tail -n1)"
assert_eq "sudo_password_wrong" "$(printf '%s' "$done_line" | jget - "d['error_id']")" "$done_line"
assert_eq "1" "$(printf '%s' "$done_line" | jget - "d['exit']")"
assert_contains "$done_line" "BENCHBAR_SUDO_PASSWORD"
assert_calls_not_contain '^(apt-get|sudo apt-get|uv|fnm|bench|curl .*(wkhtmltox|astral|fnm))' "(nothing ran)"
assert_calls_not_contain '^sudo (install|mariadb|systemctl)'
assert_no_file "$(pw_file)"
assert_no_file "$FL_MYSQL_CONF_DIR/99-frappe.cnf"
assert_no_file "$BENCH"
assert_not_contains "$OUT" "not the password"
[[ ! -s "$MOCK_STATE/sudo_leak" ]] || fail "leak: $(cat "$MOCK_STATE/sudo_leak")"
# the same without --json: text, exit 1
run_env "not the password" install --yes --bench-dir "$BENCH" --site linuxdev.localhost
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "sudo did not accept the password in BENCHBAR_SUDO_PASSWORD"
assert_calls_not_contain '^(apt-get|sudo apt-get|uv|fnm|bench)'

# ---- no password and no terminal: the missing input is named, nothing changes
fresh_machine
run_env "" install --yes --json --bench-dir "$BENCH" --site linuxdev.localhost
assert_eq "1" "$CODE" "$OUT"
done_line="$(printf '%s\n' "$OUT" | grep '"event":"done"' | tail -n1)"
assert_contains "$done_line" "BENCHBAR_SUDO_PASSWORD"
assert_eq "True" "$(printf '%s' "$done_line" | jget - "'BENCHBAR_SUDO_PASSWORD' in d.get('missing', [])")" "$done_line"
assert_calls_not_contain '^(apt-get|sudo apt-get|uv|fnm|bench)'

# ---- a dry run needs no password and runs no sudo
fresh_machine
run_env "" install --dry-run --yes --json --bench-dir "$BENCH" --site linuxdev.localhost
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain '^sudo '
run_env "not the password" install --dry-run --yes --json --bench-dir "$BENCH" --site linuxdev.localhost
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain '^sudo '

# ---- xtrace: bash -x on the CLI and on phase 00 shows no value, nowhere
fresh_machine
set +e
TRACE_OUT="$(env BENCHBAR_SUDO=env BENCHBAR_NONINTERACTIVE=1 BENCHBAR_SUDO_PASSWORD="$SECRET" bash -x "$FM" install --yes --json --bench-dir "$BENCH" --site linuxdev.localhost 2>&1 </dev/null)"
TRACE_CODE=$?
set -e
OUT="$TRACE_OUT"
assert_eq "0" "$TRACE_CODE" "$(printf '%s' "$TRACE_OUT" | tail -n 20)"
assert_calls_contain '^sudo apt-get install -y mariadb-server'
assert_no_secret "bash -x benchbar install --json"
fresh_machine
set +e
OUT="$(env BENCHBAR_SUDO=env FL_SUDO_PW_FD=8 bash -x "$ROOT/00-linux-system-deps.sh" --yes --profile v15-lts 8< <(printf '%s\n' "$SECRET") 2>&1 </dev/null)"
CODE=$?
set -e
assert_eq "0" "$CODE" "$(printf '%s' "$OUT" | tail -n 20)"
assert_calls_contain '^sudo apt-get install -y mariadb-server'
assert_no_secret "bash -x 00-linux-system-deps.sh"

# ---- the sudo function: found from subshells and pipelines, and the stdin of the command stays its own
(
  # shellcheck source=lib/frappe-local/sudo.sh
  . "$ROOT/lib/frappe-local/sudo-env.sh"
  # shellcheck source=lib/frappe-local/ui.sh
  . "$ROOT/lib/frappe-local/ui.sh"
  # shellcheck source=lib/frappe-local/sudo.sh
  . "$ROOT/lib/frappe-local/sudo.sh"
  export BENCHBAR_SUDO=env
  FL_SUDO_PW="$SECRET"
  rm -f "$MOCK_STATE"/sudo_ticket.* "$MOCK_STATE/sudo_leak"
  fl_sudo_env_begin "test" || fail "fl_sudo_env_begin refused the right password"
  # a ticket for another parent is no use to the plain mock; the function validates again in its own shell
  got="$(printf 'from stdin\n' | sudo cat)"
  assert_eq "from stdin" "$got" "(the command reads its own stdin)"
  got="$( (sudo -n true && echo subshell-ok) )"
  assert_eq "subshell-ok" "$got"
  printf 'piped\n' | sudo tee "$TMP_DIR/sudo-out" >/dev/null
  assert_eq "piped" "$(cat "$TMP_DIR/sudo-out")"
  # what install does after phase 00
  fl_sudo_drop
  fl_sudo_env_forget
  command -v sudo >/dev/null 2>&1 && [[ "$(type -t sudo)" == "file" ]] || fail "the sudo function must be gone after fl_sudo_env_forget"
  assert_eq "" "$FL_SUDO_PW"
  # without the function and without a password the machine's sudo refuses
  if sudo -n true 2>/dev/null; then fail "sudo -n must fail without a ticket after the function is gone"; fi
  [[ ! -s "$MOCK_STATE/sudo_leak" ]] || fail "leak: $(cat "$MOCK_STATE/sudo_leak")"
) || exit 1

# ---- the other commands: a wrong password stops them before any change, the right one lets them run
fresh_machine
run_env "$SECRET" install --yes --json --bench-dir "$BENCH" --site linuxdev.localhost
assert_eq "0" "$CODE" "$OUT"
for cmd in "adopt $BENCH --yes --json" "repair --yes --json --bench-dir $BENCH" "service --yes --json --bench-dir $BENCH" \
  "site add second.localhost --yes --json --bench-dir $BENCH" "ports apply TOKEN --yes --json -- $BENCH"; do
  reset_calls
  # shellcheck disable=SC2086  # the words are the command line
  run_env "not the password" $cmd
  assert_eq "1" "$CODE" "$cmd: $OUT"
  done_line="$(printf '%s\n' "$OUT" | grep '"event":"done"' | tail -n1)"
  assert_contains "$done_line" '"error_id":"sudo_password_wrong"' "$cmd: $OUT"
  assert_calls_not_contain '^(apt-get|systemctl --user (enable|start)|sudo (install|apt-get|mariadb))' "$cmd"
  assert_not_contains "$OUT" "not the password"
done

# repair with the right password writes the MariaDB drop-in through sudo, and leaks nothing
export FL_MYSQL_CNF="$TMP_DIR/my.cnf"
printf '[client-server]\n!includedir %s/\n' "$FL_MYSQL_CONF_DIR" >"$FL_MYSQL_CNF"
rm -f "$FL_MYSQL_CONF_DIR/99-frappe.cnf"
reset_calls
run_env "$SECRET" repair --yes --json --bench-dir "$BENCH"
done_line="$(printf '%s\n' "$OUT" | grep '"event":"done"' | tail -n1)"
assert_not_contains "$done_line" "error_id" "$OUT"
assert_calls_contain "^sudo install -m 0644 .* ${FL_MYSQL_CONF_DIR}/99-frappe.cnf\$" "(repair used sudo for the drop-in)"
assert_file "$FL_MYSQL_CONF_DIR/99-frappe.cnf"
assert_no_secret "repair --json"

# adopt with the right password runs and leaks nothing
run_env "$SECRET" adopt "$BENCH" --yes --json
done_line="$(printf '%s\n' "$OUT" | grep '"event":"done"' | tail -n1)"
assert_eq "0" "$(printf '%s' "$done_line" | jget - "d['exit']")" "$OUT"
assert_no_secret "adopt --json"

# ---- BENCHBAR_SUDO=env is ignored on a Mac, and BENCHBAR_SUDO=gui is untouched
unset ADMIN_PASSWORD
(
  # shellcheck source=lib/frappe-local/ui.sh
  . "$ROOT/lib/frappe-local/ui.sh"
  # shellcheck source=lib/frappe-local/sudo.sh
  . "$ROOT/lib/frappe-local/sudo.sh"
  export FL_PLATFORM=macos BENCHBAR_SUDO=env
  FL_SUDO_PW="$SECRET"
  fl_sudo_env && fail "env mode must be Linux only"
  export BENCHBAR_SUDO=gui FL_PLATFORM=linux
  fl_sudo_env && fail "gui is not env"
  fl_sudo_gui && fail "the gui mode is a Mac thing"
  exit 0
) || exit 1

printf 'test-sudo-env: ok\n'
