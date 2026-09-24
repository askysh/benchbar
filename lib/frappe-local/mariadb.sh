#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# mariadb.sh: the MariaDB root password, the Keychain, and the config drop-ins.
#
# The root password lives in the macOS Keychain under the service
# "benchbar-mariadb", account "root", never in a file. Order of sources:
#   MARIADB_ROOT_PASSWORD in the environment, then the Keychain, then a
#   prompt. Whatever verifies against the server is saved to the Keychain.
#
# The client gets the password through MYSQL_PWD, not on the command line,
# so it never shows in the process list.

FL_KEYCHAIN_SERVICE="${FL_KEYCHAIN_SERVICE:-benchbar-mariadb}"
FL_KEYCHAIN_ACCOUNT="root"
FL_MARIADB_ROOT_PW=""
FL_MARIADB_ROOT_PW_SOURCE=""

# ------------------------------------------------------------- keychain

fl_keychain_get() {
  command -v security >/dev/null 2>&1 || return 1
  security find-generic-password -s "$FL_KEYCHAIN_SERVICE" -a "$FL_KEYCHAIN_ACCOUNT" -w 2>/dev/null
}

# fl_keychain_set PASSWORD: adds or updates the entry (-U). The password is
# an argument of "security" for the moment of the call; there is no other
# non interactive way to write a Keychain item.
fl_keychain_set() {
  local pw="$1"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would store the MariaDB root password in the Keychain (${FL_KEYCHAIN_SERVICE})"
    return 0
  fi
  command -v security >/dev/null 2>&1 || { fl_warn "the security command is missing; the password was not saved"; return 1; }
  if [[ "$(fl_keychain_get || true)" == "$pw" ]]; then
    return 0
  fi
  security add-generic-password -U -s "$FL_KEYCHAIN_SERVICE" -a "$FL_KEYCHAIN_ACCOUNT" \
    -l "BenchBar MariaDB root" -j "MariaDB root password written by benchbar" -w "$pw" >/dev/null 2>&1 \
    || { fl_warn "could not write the Keychain item ${FL_KEYCHAIN_SERVICE}"; return 1; }
  fl_ok "MariaDB root password saved to the Keychain (benchbar mariadb-password prints it)"
  fl_log "keychain: wrote ${FL_KEYCHAIN_SERVICE}/${FL_KEYCHAIN_ACCOUNT}"
}

fl_keychain_delete() {
  command -v security >/dev/null 2>&1 || return 0
  security delete-generic-password -s "$FL_KEYCHAIN_SERVICE" -a "$FL_KEYCHAIN_ACCOUNT" >/dev/null 2>&1 || true
}

# ------------------------------------------------------------- client

fl_mariadb_client() {
  local bin
  bin="$(fl_mariadb_bin 2>/dev/null || true)"
  [[ -n "$bin" && -x "$bin" ]] || bin="$(command -v mariadb 2>/dev/null || command -v mysql 2>/dev/null || true)"
  printf '%s' "$bin"
}

# true when root@localhost accepts a login with no password (fresh Homebrew install)
fl_mariadb_root_open() {
  local bin
  bin="$(fl_mariadb_client)"
  [[ -n "$bin" ]] || return 1
  MYSQL_PWD="" "$bin" -u root --connect-timeout=2 -e "SELECT 1" >/dev/null 2>&1
}

# fl_mariadb_root_verify PASSWORD
fl_mariadb_root_verify() {
  local bin
  bin="$(fl_mariadb_client)"
  [[ -n "$bin" ]] || return 1
  MYSQL_PWD="$1" "$bin" -u root --connect-timeout=2 -e "SELECT 1" >/dev/null 2>&1
}

fl_mariadb_server_charset() {
  local bin
  bin="$(fl_mariadb_client)"
  MYSQL_PWD="$1" "$bin" -u root -sNe "SHOW VARIABLES LIKE 'character_set_server'" 2>/dev/null | awk '{print $2}'
}

fl_password_generate() {
  # 24 letters and digits: safe in SQL, shell and bench's command line.
  # The input is bounded (4 KB of urandom gives about 1500 usable
  # characters): BSD tr reading /dev/urandom forever never notices a
  # closed pipe when SIGPIPE is ignored, as it is under GitHub Actions.
  head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 24
}

fl_sql_escape() { printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g"; }

# fl_mariadb_secure PASSWORD: what mariadb-secure-installation does, in SQL,
# on a server that still accepts root without a password. Sets the root
# password (native auth, as Frappe needs), drops anonymous users and the
# test database, and limits root to this Mac.
fl_mariadb_secure() {
  local pw="$1" bin esc
  bin="$(fl_mariadb_client)"
  esc="$(fl_sql_escape "$pw")"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would set the root password, remove anonymous users and the test database, and block remote root"
    return 0
  fi
  fl_log "mariadb: securing root@localhost (password not logged)"
  MYSQL_PWD="" "$bin" -u root <<SQL
DELETE FROM mysql.global_priv WHERE User='';
DELETE FROM mysql.global_priv WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${esc}');
FLUSH PRIVILEGES;
SQL
}

# ------------------------------------------------------------- setup

# fl_mariadb_root_setup: makes sure root has a password we know.
#   returns 0  password known and verified (FL_MARIADB_ROOT_PW set)
#   returns 2  a password exists but none of the sources knows it
# Prints [OK]/[WARN] lines; never dies.
fl_mariadb_root_setup() {
  local pw source=""
  FL_MARIADB_ROOT_PW=""
  FL_MARIADB_ROOT_PW_SOURCE=""
  if fl_mariadb_root_open; then
    if [[ -n "${MARIADB_ROOT_PASSWORD:-}" ]]; then
      pw="$MARIADB_ROOT_PASSWORD"; source="environment"
    else
      pw="$(fl_password_generate)"; source="generated"
    fi
    fl_warn "MariaDB root@localhost has no password yet; setting one (${source})"
    # the Keychain write comes first: a generated password that exists only
    # in this process must never be applied to the server
    if ! fl_keychain_set "$pw"; then
      if [[ "$source" == "generated" ]]; then
        fl_fail "the Keychain refused the new password, so MariaDB was left unchanged (is the login Keychain locked?)"
        fl_fix "unlock the Keychain (security unlock-keychain), or pass MARIADB_ROOT_PASSWORD='...' to use a password you keep yourself"
        return 1
      fi
      fl_warn "the password from MARIADB_ROOT_PASSWORD could not be saved to the Keychain; keep it, later runs need it in the environment"
    fi
    if ! fl_mariadb_secure "$pw"; then
      fl_fail "could not set the MariaDB root password"
      [[ "$source" == "generated" ]] && fl_keychain_delete
      return 1
    fi
    if [[ "${FL_DRY_RUN:-0}" != "1" ]]; then
      fl_mariadb_root_verify "$pw" || { fl_fail "the new root password does not work; check the MariaDB log"; return 1; }
      fl_ok "MariaDB root password set, anonymous users and the test database removed, remote root blocked"
    fi
    FL_MARIADB_ROOT_PW="$pw"; FL_MARIADB_ROOT_PW_SOURCE="$source"
    return 0
  fi

  # root already has a password: find it
  if [[ -n "${MARIADB_ROOT_PASSWORD:-}" ]]; then
    if fl_mariadb_root_verify "$MARIADB_ROOT_PASSWORD"; then
      FL_MARIADB_ROOT_PW="$MARIADB_ROOT_PASSWORD"; FL_MARIADB_ROOT_PW_SOURCE="environment"
      fl_ok "MariaDB root password verified (from MARIADB_ROOT_PASSWORD)"
      fl_keychain_set "$FL_MARIADB_ROOT_PW" || true
      return 0
    fi
    fl_warn "MARIADB_ROOT_PASSWORD from the environment does not work"
  fi
  pw="$(fl_keychain_get || true)"
  if [[ -n "$pw" ]]; then
    if fl_mariadb_root_verify "$pw"; then
      FL_MARIADB_ROOT_PW="$pw"; FL_MARIADB_ROOT_PW_SOURCE="keychain"
      fl_ok "MariaDB root password verified (Keychain, unchanged)"
      return 0
    fi
    fl_warn "the password in the Keychain does not work any more"
  fi
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would ask for the existing MariaDB root password and save it to the Keychain"
    return 0
  fi
  if [[ "${FL_ASSUME_YES:-0}" == "1" || ! -t 0 ]]; then
    fl_warn "MariaDB root already has a password and no source knows it"
    return 2
  fi
  while true; do
    pw=""
    fl_ask_secret pw "Existing MariaDB root password"
    if fl_mariadb_root_verify "$pw"; then break; fi
    fl_warn "that password was rejected by MariaDB"
    fl_confirm "Try again?" || return 2
  done
  FL_MARIADB_ROOT_PW="$pw"; FL_MARIADB_ROOT_PW_SOURCE="prompt"
  fl_ok "MariaDB root password verified"
  fl_keychain_set "$pw" || true
  return 0
}

# fl_mariadb_root_password_resolve: for phase 01 and anything that only
# needs the password. Environment, then Keychain (verified), then a
# prompt. Sets FL_MARIADB_ROOT_PW or returns 1.
fl_mariadb_root_password_resolve() {
  local pw
  FL_MARIADB_ROOT_PW=""
  if [[ -n "${MARIADB_ROOT_PASSWORD:-}" ]]; then
    FL_MARIADB_ROOT_PW="$MARIADB_ROOT_PASSWORD"; FL_MARIADB_ROOT_PW_SOURCE="environment"
    fl_info "using env-provided MARIADB_ROOT_PASSWORD (hidden)"
    # a password that works is worth remembering; a wrong one fails later with a clear message
    if [[ "${FL_DRY_RUN:-0}" != "1" ]] && fl_mariadb_root_verify "$FL_MARIADB_ROOT_PW"; then fl_keychain_set "$FL_MARIADB_ROOT_PW" || true; fi
    return 0
  fi
  pw="$(fl_keychain_get || true)"
  if [[ -n "$pw" ]]; then
    if [[ "${FL_DRY_RUN:-0}" == "1" ]] || fl_mariadb_root_verify "$pw"; then
      FL_MARIADB_ROOT_PW="$pw"; FL_MARIADB_ROOT_PW_SOURCE="keychain"
      fl_info "MariaDB root password read from the Keychain"
      return 0
    fi
    fl_warn "the MariaDB root password in the Keychain does not work; asking"
  fi
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    FL_MARIADB_ROOT_PW="dry-run-placeholder"; FL_MARIADB_ROOT_PW_SOURCE="dry-run"
    fl_info "dry-run: using placeholder for MARIADB_ROOT_PASSWORD"
    return 0
  fi
  if [[ "${FL_ASSUME_YES:-0}" == "1" || ! -t 0 ]]; then
    fl_fail "MariaDB root password unknown: not in MARIADB_ROOT_PASSWORD and not in the Keychain"
    return 1
  fi
  fl_ask_secret pw "MariaDB root password"
  fl_mariadb_root_verify "$pw" || { fl_fail "MariaDB rejected that root password"; return 1; }
  FL_MARIADB_ROOT_PW="$pw"; FL_MARIADB_ROOT_PW_SOURCE="prompt"
  fl_keychain_set "$pw" || true
  return 0
}

# ------------------------------------------------------------- drop-ins

fl_mariadb_utf8_dropin_path() {
  printf '%s/etc/my.cnf.d/frappe.cnf' "${FL_BREW_PREFIX:-/opt/homebrew}"
}

# true when $(brew --prefix)/etc/my.cnf pulls in my.cnf.d (or does not exist
# yet: a fresh Homebrew MariaDB writes one that does)
fl_mariadb_includedir_present() {
  local brew="${FL_BREW_PREFIX:-/opt/homebrew}" mycnf
  mycnf="${brew}/etc/my.cnf"
  [[ -f "$mycnf" ]] || return 1
  grep -q "^!includedir ${brew}/etc/my.cnf.d" "$mycnf"
}

# Makes sure $(brew --prefix)/etc/my.cnf includes my.cnf.d. Returns 0 always;
# sets FL_MYCNF_CHANGED=1 when the file was written.
fl_mariadb_includedir_ensure() {
  local brew="${FL_BREW_PREFIX:-/opt/homebrew}" mycnf
  mycnf="${brew}/etc/my.cnf"
  FL_MYCNF_CHANGED=0
  if [[ -f "$mycnf" ]]; then
    grep -q "^!includedir ${brew}/etc/my.cnf.d" "$mycnf" && return 0
    if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
      fl_info "dry-run: would append '!includedir ${brew}/etc/my.cnf.d' to ${mycnf}"
    else
      fl_backup_file "$mycnf"
      printf '\n!includedir %s/etc/my.cnf.d\n' "$brew" >>"$mycnf"
      FL_MYCNF_CHANGED=1
      fl_ok "added !includedir to ${mycnf}"
    fi
    return 0
  fi
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would create ${mycnf} with !includedir"
  else
    mkdir -p "$(dirname "$mycnf")"
    printf '[client-server]\n!includedir %s/etc/my.cnf.d\n' "$brew" >"$mycnf"
    FL_MYCNF_CHANGED=1
    fl_ok "created ${mycnf}"
  fi
}

# fl_mariadb_dropin_apply TEMPLATE PATH: renders the drop-in and writes it
# when it is missing or outdated. Sets FL_TEMPLATE_CHANGED (drop-in or
# my.cnf written), so the caller knows a restart is due.
fl_mariadb_dropin_apply() {
  local template="$1" path="$2" rendered
  fl_mariadb_includedir_ensure
  rendered="$(fl_template_render "$template")"
  fl_template_apply "$path" "$rendered" 644
  [[ "$FL_TEMPLATE_CHANGED" == "1" && "${FL_DRY_RUN:-0}" != "1" ]] && fl_ok "wrote ${path}"
  [[ "${FL_MYCNF_CHANGED:-0}" == "1" ]] && FL_TEMPLATE_CHANGED=1
  return 0
}

# fl_mariadb_restart_if_running: a changed drop-in needs a restart; a
# stopped server picks it up on its next start.
fl_mariadb_restart_if_running() {
  local formula
  fl_process_running mariadbd || fl_port_listening 3306 || return 0
  formula="$(fl_mariadb_service_formula)"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: brew services restart ${formula}"
    return 0
  fi
  fl_run_long "brew services restart ${formula}" brew services restart "$formula" || { fl_warn "restart failed; run: brew services restart ${formula}"; return 1; }
}

fl_mariadb_service_formula() {
  local f
  f="$(brew services list 2>/dev/null | awk '$1 ~ /^mariadb/ && $2 == "started" {print $1; exit}' || true)"
  printf '%s' "${f:-${FL_MARIADB_FORMULA:-mariadb}}"
}

# ------------------------------------------------------------- command

# benchbar mariadb-password: prints the stored password after a confirmation
fl_cmd_mariadb_password() {
  local pw
  pw="$(fl_keychain_get || true)"
  if [[ -z "$pw" ]]; then
    fl_fail "no MariaDB root password in the Keychain (service ${FL_KEYCHAIN_SERVICE})"
    fl_fix "MARIADB_ROOT_PASSWORD='...' ${SCRIPT_DIR}/benchbar install    (verifies it and saves it)"
    return 1
  fi
  if [[ "${FL_ASSUME_YES:-0}" != "1" ]]; then
    fl_confirm "Print the MariaDB root password to this terminal?" || { fl_info "not printed"; return 1; }
  fi
  printf '%s\n' "$pw"
}
