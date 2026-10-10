#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# platform-linux.sh: the Linux (Ubuntu and Debian, WSL too) layer.
#
# Sourced by fl_platform_load after every other lib file, so each function
# here replaces the macOS one of the same name and callers never branch.
# Toolchain: Python from uv, Node from fnm, MariaDB and Redis from apt as
# systemd system units. Ports and processes come from ss and /proc.

FL_BREW_PREFIX=""
# the files the layer reads, overridable for the tests
FL_PROC_VERSION="${FL_PROC_VERSION:-/proc/version}"
FL_OS_RELEASE="${FL_OS_RELEASE:-/etc/os-release}"
FL_PROC_DIR="${FL_PROC_DIR:-/proc}"

# ------------------------------------------------------------- startup

# true inside WSL (the kernel version string says Microsoft)
fl_is_wsl() {
  [[ -r "$FL_PROC_VERSION" ]] && grep -qi microsoft "$FL_PROC_VERSION" 2>/dev/null
}

fl_platform_init() {
  local id="" like="" line
  if [[ -r "$FL_OS_RELEASE" ]]; then
    while IFS= read -r line; do
      case "$line" in
        ID=*) id="${line#ID=}" ;;
        ID_LIKE=*) like="${line#ID_LIKE=}" ;;
      esac
    done <"$FL_OS_RELEASE"
  fi
  id="${id//\"/}"; like="${like//\"/}"
  case " ${id} ${like} " in
    *" ubuntu "*|*" debian "*) ;;
    *) fl_die "This installer targets Ubuntu and Debian on Linux (found ${id:-an unknown system})." "Other distributions are not supported yet." ;;
  esac
  command -v apt-get >/dev/null 2>&1 || fl_die "apt-get was not found." "This installer needs an apt based system (Ubuntu or Debian)."
  FL_BREW_PREFIX=""
  FL_ARCH="$(uname -m)"
  if fl_is_wsl; then FL_IS_WSL=1; else FL_IS_WSL=0; fi
}

fl_default_site() { printf 'linuxdev.localhost'; }

# wslview inside WSL (it opens the Windows browser), xdg-open elsewhere
fl_open_cmd() {
  if fl_is_wsl; then printf 'wslview'; else printf 'xdg-open'; fi
}

fl_open_url() {
  local cmd
  cmd="$(fl_open_cmd)"
  command -v "$cmd" >/dev/null 2>&1 || { cmd=xdg-open; command -v "$cmd" >/dev/null 2>&1 || return 127; }
  "$cmd" "$1"
}

# bench init writes a crontab; Linux has no Full Disk Access gate
fl_crontab_denied() { return 1; }

# ------------------------------------------------------------- services

# fl__apt_unit NAME: the systemd system unit for a formula style name
fl__apt_unit() {
  case "$1" in
    mariadb|mariadb@*) printf 'mariadb' ;;
    redis|redis-server|redis@*) printf 'redis-server' ;;
    *) printf '%s' "$1" ;;
  esac
}

# fl__apt_package NAME: the apt package behind a formula style name
fl__apt_package() {
  case "$1" in
    mariadb|mariadb@*) printf 'mariadb-server' ;;
    redis|redis@*) printf 'redis-server' ;;
    *) printf '%s' "$1" ;;
  esac
}

fl_process_running() {
  pgrep -f "$1" >/dev/null 2>&1
}

fl_brew_service_running() {
  systemctl is-active --quiet "$(fl__apt_unit "$1")" 2>/dev/null
}

# No Homebrew: nothing dates a package. "unknown - - -" has no disable date,
# so fl_formula_disable_days_from prints nothing.
fl_brew_formula_dates() {
  printf 'unknown - - -'
}

fl_brew_formula_available() {
  local pkg st
  pkg="$(fl__apt_package "$1")"
  st="$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)"
  [[ "$st" == *"install ok installed"* ]] && return 0
  apt-get -s install "$pkg" >/dev/null 2>&1
}

# ------------------------------------------------------------- toolchain

# fl__ver_num VERSION: a number that sorts like the dotted version (22.11.0)
fl__ver_num() {
  local IFS=. a=0 b=0 c=0
  # shellcheck disable=SC2086  # split on the dots on purpose
  set -- $1
  a="${1:-0}"; b="${2:-0}"; c="${3:-0}"
  [[ "$a$b$c" =~ ^[0-9]+$ ]] || { printf '0'; return 0; }
  printf '%s' "$((10#$a * 1000000 + 10#$b * 1000 + 10#$c))"
}

fl__uv_python_dir() { printf '%s' "${UV_PYTHON_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/uv/python}"; }
fl__fnm_dir() { printf '%s' "${FNM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/fnm}"; }

# fl__python_bin_for VERSION: the uv managed python3.X for a version like 3.11
# (the newest patch release on disk), found without starting uv; uv itself is
# asked only when nothing is there and the command is not a read only one.
fl__python_bin_for() {
  local ver="$1" d best="" best_n=-1 n rest found
  for d in "$(fl__uv_python_dir)"/cpython-"${ver}"*-linux-*; do
    [[ -x "$d/bin/python${ver}" ]] || continue
    rest="${d##*/cpython-"${ver}"}"
    case "$rest" in
      .*) n="$(fl__ver_num "${ver}${rest%%-*}")" ;;
      *) n=0 ;;
    esac
    if [[ "$n" -gt "$best_n" ]]; then best="$d/bin/python${ver}"; best_n="$n"; fi
  done
  if [[ -n "$best" ]]; then printf '%s' "$best"; return 0; fi
  if [[ "${FL_CONTEXT_LIGHT:-0}" != "1" ]] && command -v uv >/dev/null 2>&1; then
    found="$(uv python find "$ver" 2>/dev/null | head -n1 || true)"
    if [[ -n "$found" && -x "$found" ]]; then printf '%s' "$found"; return 0; fi
  fi
  # where uv puts it: the path is right once `uv python install` has run
  printf '%s/cpython-%s-linux-%s-gnu/bin/python%s' "$(fl__uv_python_dir)" "$ver" "${FL_ARCH:-x86_64}" "$ver"
}

# fl__node_bindir_for MAJOR: fnm's bin folder of the newest Node of a major
fl__node_bindir_for() {
  local major="$1" d best="" best_n=-1 n
  for d in "$(fl__fnm_dir)"/node-versions/v"${major}".*/installation; do
    [[ -x "$d/bin/node" ]] || continue
    n="${d%/installation}"; n="${n##*/v}"
    n="$(fl__ver_num "$n")"
    if [[ "$n" -gt "$best_n" ]]; then best="$d/bin"; best_n="$n"; fi
  done
  if [[ -n "$best" ]]; then printf '%s' "$best"; return 0; fi
  printf '%s/node-versions/v%s/installation/bin' "$(fl__fnm_dir)" "$major"
}

fl_formula_prefix() {
  local formula="$1" bin
  case "$formula" in
    python@*) bin="$(fl__python_bin_for "${formula#python@}")"; printf '%s\n' "${bin%/bin/*}" ;;
    node@*) bin="$(fl__node_bindir_for "${formula#node@}")"; printf '%s\n' "${bin%/bin}" ;;
    *) printf '/usr\n' ;;
  esac
}

fl_python_bin() {
  fl__python_bin_for "${FL_PYTHON_BIN_NAME#python}"
  printf '\n'
}

fl_node_bin() {
  printf '%s/node\n' "$(fl__node_bindir_for "$FL_NODE_MAJOR")"
}

fl_npm_bin() {
  printf '%s/npm\n' "$(fl__node_bindir_for "$FL_NODE_MAJOR")"
}

fl_mariadb_bin() {
  # FL_MARIADB_BIN: the tests' client (a mock), never the machine's
  if [[ -n "${FL_MARIADB_BIN:-}" ]]; then printf '%s\n' "$FL_MARIADB_BIN"; return 0; fi
  if [[ -x /usr/bin/mariadb ]]; then printf '/usr/bin/mariadb\n'; return 0; fi
  command -v mariadb 2>/dev/null || printf '/usr/bin/mariadb\n'
}

# fl_profile_path_exports [PROFILE]: the shell block's exports, for the
# loaded profile or the one named. The uv Python and fnm Node folders only:
# the apt -dev packages put headers and pkg-config files where the compiler
# looks, so there are no LDFLAGS, CPPFLAGS or PKG_CONFIG_PATH.
# shellcheck disable=SC2016  # the lines go to the rc file unexpanded
fl_profile_path_exports() {
  local pyver="${FL_PYTHON_BIN_NAME#python}" nodemajor="$FL_NODE_MAJOR" row bin
  if [[ -n "${1:-}" && "${1:-}" != "$FL_PROFILE" ]]; then
    row="$(awk -F '\t' -v p="$1" 'NR > 1 && $1 == p {print $6 "|" $8}' "$(fl_config_file release-profiles.tsv)")"
    if [[ -n "$row" ]]; then
      IFS='|' read -r pyver nodemajor <<<"$row"
      pyver="${pyver#python}"
    fi
  fi
  bin="$(fl__python_bin_for "$pyver")"
  printf 'export PATH="%s:$PATH"\n' "${bin%/*}"
  printf 'export PATH="%s:$PATH"\n' "$(fl__node_bindir_for "$nodemajor")"
  printf 'export PATH="$HOME/.local/bin:$PATH"\n'
}

# ~/.local/pipx unless pipx says otherwise
fl_pipx_home() {
  local h=""
  if command -v pipx >/dev/null 2>&1; then h="$(pipx environment --value PIPX_HOME 2>/dev/null || true)"; fi
  [[ -n "$h" ]] && { printf '%s' "$h"; return 0; }
  printf '%s' "$HOME/.local/pipx"
}

# ------------------------------------------------------------- secret store

# The MariaDB root password is a 0600 file in a 0700 folder of the state
# folder, in place of the Keychain. The arguments and results are the Keychain
# functions' (mariadb.sh); the password is never printed or logged.
fl__secret_file() { printf '%s/secrets/mariadb-root' "$FL_STATE_DIR"; }

fl_keychain_get() {
  local f line=""
  f="$(fl__secret_file)"
  [[ -f "$f" && -r "$f" ]] || return 1
  IFS= read -r line <"$f" || true
  [[ -n "$line" ]] || return 1
  printf '%s' "$line"
}

fl_keychain_set() {
  local pw="$1" f dir tmp
  f="$(fl__secret_file)"
  dir="${f%/*}"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would store the MariaDB root password in ${f}"
    return 0
  fi
  case "$pw" in *$'\n'*|"") fl_warn "the MariaDB root password cannot be saved: it is empty or has a line break"; return 1 ;; esac
  if [[ "$(fl_keychain_get || true)" == "$pw" ]]; then
    return 0
  fi
  (
    umask 077
    mkdir -p "$dir" && chmod 700 "$dir" || exit 1
    tmp="$(mktemp "${dir}/.mariadb-root.XXXXXX")" || exit 1
    if printf '%s\n' "$pw" >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$f"; then exit 0; fi
    rm -f "$tmp"
    exit 1
  ) 2>/dev/null || true
  [[ "$(fl_keychain_get || true)" == "$pw" ]] || { fl_warn "could not write the password file ${f}"; return 1; }
  fl_ok "MariaDB root password saved to ${f} (benchbar mariadb-password prints it)"
  fl_log "secrets: wrote ${f}"
}

fl_keychain_delete() {
  rm -f "$(fl__secret_file)" 2>/dev/null || true
}

# ------------------------------------------------------------- ports and processes

# fl__ss_listeners [PORTS]: one line "port pid command address" per listening
# TCP socket (and per process sharing it), from ss -Hltnp, for the comma
# separated PORTS or all of them. The one parser behind every port question.
# A socket whose owner ss may not show (another user's) gets pid 0 and
# command "?". Addresses read like lsof's: *:3306, 127.0.0.1:3306, [::1]:3306.
fl__ss_listeners() {
  ss -Hltnp 2>/dev/null | awk -v want="${1:-}" '
    BEGIN { n = split(want, w, ","); for (i = 1; i <= n; i++) if (w[i] != "") ok[w[i]] = 1 }
    {
      laddr = $4
      i = length(laddr)
      while (i > 0 && substr(laddr, i, 1) != ":") i--
      if (i == 0) next
      port = substr(laddr, i + 1)
      addr = substr(laddr, 1, i - 1)
      if (want != "" && !(port in ok)) next
      # 127.0.0.53%lo and [fe80::1%eth0]: the interface is not part of the address
      pct = index(addr, "%")
      if (pct > 0) {
        br = (substr(addr, length(addr), 1) == "]") ? "]" : ""
        addr = substr(addr, 1, pct - 1) br
      }
      if (addr == "0.0.0.0" || addr == "[::]" || addr == "*") addr = "*"
      # the rest of the line: a command name may hold blanks
      u = index($0, "users:")
      users = (u > 0) ? substr($0, u) : ""
      emitted = 0
      rest = users
      while ((s = index(rest, "(\"")) > 0) {
        rest = substr(rest, s + 2)
        q = index(rest, "\"")
        cmd = substr(rest, 1, q - 1)
        rest = substr(rest, q + 1)
        p = index(rest, "pid=")
        if (p == 0) break
        rest = substr(rest, p + 4)
        pid = rest
        sub(/[^0-9].*/, "", pid)
        gsub(/[ \t]/, "_", cmd)
        print port, pid, cmd, addr ":" port
        emitted = 1
      }
      if (!emitted) print port, 0, "?", addr ":" port
    }'
}

fl_port_listening() {
  [[ -n "$(ss -Hltn "sport = :$1" 2>/dev/null)" ]]
}

# the working folder of a process, from /proc; nothing when it cannot be read
fl_pid_cwd() {
  [[ "$1" =~ ^[0-9]+$ ]] || return 0
  readlink "${FL_PROC_DIR}/$1/cwd" 2>/dev/null || true
}

fl_bench_listener_pids() {
  local port pid cmd addr
  fl__ss_listeners "$(fl_bench_ports_csv)" | while read -r port pid cmd addr; do
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] && fl_pid_is_bench_own_strict "$pid" && printf '%s\n' "$pid"
  done
  return 0
}

fl_port_listener_pid() {
  local port pid cmd addr
  fl__ss_listeners "$1" | { read -r port pid cmd addr && printf '%s\n' "$pid"; } || true
}

fl_port_listener_summary() {
  # prints "pid command" for the first listener on a port, or nothing
  local port pid cmd addr
  fl__ss_listeners "$1" | { read -r port pid cmd addr && printf '%s %s\n' "$pid" "$cmd"; } || true
}

fl_port_listen_addresses() {
  # prints the local address:port of every listener on a port, one per line
  fl__ss_listeners "$1" | awk '{print $4}' | sort -u || true
}

# fl_bench_status_pids: as on the Mac, from `pgrep -af` (procps prints the
# whole command line with -a; -l prints only the name) and the folders in /proc
fl_bench_status_pids() {
  local found line pid cmd first="" rest=""
  found="$(pgrep -af 'honcho start -f Procfile\.lean|-m frappe\.utils\.bench_helper frappe (serve|worker|schedule)|apps/frappe/socketio\.js' 2>/dev/null)" || return 0
  while IFS= read -r line; do
    pid="${line%% *}"; cmd="${line#* }"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    fl_pid_is_bench_own_strict "$pid" || continue
    if [[ "$cmd" == *"honcho start -f Procfile.lean"* ]]; then first="${first}${pid}"$'\n'; else rest="${rest}${pid}"$'\n'; fi
  done <<<"$found"
  printf '%s%s' "$first" "$rest"
}

# ------------------------------------------------------------- install (MariaDB, wkhtmltopdf, phase 00)

# What the install needs from apt: the servers, the compiler and the -dev
# packages a Frappe bench builds against, git, curl and zip, and
# libnss-myhostname: glibc on Ubuntu (WSL above all, whose DNS proxy does
# not answer .localhost) does not resolve *.localhost by itself, so
# wkhtmltopdf and Python could not reach the site by its name. The package
# adds "myhostname" to the hosts line of /etc/nsswitch.conf on install.
FL_LINUX_APT_PACKAGES="mariadb-server mariadb-client redis-server build-essential pkg-config libmariadb-dev libssl-dev libffi-dev zlib1g-dev git curl zip libnss-myhostname"
# where Ubuntu reads MariaDB drop-ins (it includes the folder already), and
# the folder systemd marks a booted system with; both overridable for the tests
FL_MYSQL_CONF_DIR="${FL_MYSQL_CONF_DIR:-/etc/mysql/mariadb.conf.d}"
FL_SYSTEMD_RUN_DIR="${FL_SYSTEMD_RUN_DIR:-/run/systemd/system}"
FL_MARIADB_DATA_DIR="${FL_MARIADB_DATA_DIR:-/var/lib/mysql}"
# 1 when this run administers MariaDB through "sudo mariadb"
FL_MARIADB_ADMIN_SUDO=0

# the password is a 0600 file here, and the messages say so
FL_SECRET_STORE="password file"

fl_phase00_script() { printf '00-linux-system-deps.sh'; }

fl_service_start_hint() { printf 'sudo systemctl start %s' "$(fl__apt_unit "$1")"; }

fl_preflight_not_root() {
  local effective_uid="${FL_EFFECTIVE_UID:-$EUID}"
  [[ "$effective_uid" != "0" ]] || fl_die "Do not run this installer as root." "Run it as your normal user; the scripts ask for sudo only where apt and MariaDB need it."
  fl_ok "Running as a regular user"
}

# "Ubuntu 24.04" from the os-release file
fl_linux_os_summary() {
  local name="" ver="" line
  if [[ -r "$FL_OS_RELEASE" ]]; then
    while IFS= read -r line; do
      case "$line" in
        NAME=*) name="${line#NAME=}" ;;
        VERSION_ID=*) ver="${line#VERSION_ID=}" ;;
      esac
    done <"$FL_OS_RELEASE"
  fi
  name="${name//\"/}"; ver="${ver//\"/}"
  printf '%s%s' "${name:-Linux}" "${ver:+ $ver}"
}

# true when systemd runs as the init (WSL needs "systemd=true" in /etc/wsl.conf)
fl_linux_systemd_booted() { [[ -d "$FL_SYSTEMD_RUN_DIR" ]]; }

# Only v15-lts runs on Linux so far: its MariaDB 10.11, Python 3.11 and
# Node 22 are what apt, uv and fnm give. Another profile needs a vendor
# repository or another Python and is refused before anything is installed.
fl_linux_profile_supported() {
  [[ "$FL_PYTHON_BIN_NAME" == "python3.11" && "$FL_NODE_MAJOR" == "22" && "$FL_MARIADB_MAJOR_MINOR" == "10.11" ]]
}

fl_linux_profile_require() {
  fl_linux_profile_supported && return 0
  fl_die "Profile ${FL_PROFILE} is not supported on Linux yet (it needs ${FL_PYTHON_BIN_NAME}, Node ${FL_NODE_MAJOR} and MariaDB ${FL_MARIADB_MAJOR_MINOR})." \
    "v15-lts is: benchbar install --profile v15-lts"
}

# fl_linux_toolchain_path: the PATH prefix for the loaded profile's uv Python,
# fnm Node and ~/.local/bin (where uv and bench live)
fl_linux_toolchain_path() {
  local py
  py="$(fl__python_bin_for "${FL_PYTHON_BIN_NAME#python}")"
  printf '%s:%s:%s/.local/bin' "${py%/*}" "$(fl__node_bindir_for "$FL_NODE_MAJOR")" "$HOME"
}

# ---- apt

fl_linux_pkg_installed() {
  local st
  st="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)"
  [[ "$st" == *"install ok installed"* ]]
}

# the apt packages of the list that are not installed, space separated
fl_linux_missing_packages() {
  local p out=""
  for p in $FL_LINUX_APT_PACKAGES; do
    fl_linux_pkg_installed "$p" || out="${out:+$out }$p"
  done
  # fnm's installer unpacks a zip: unzip only while fnm is not there yet
  if ! command -v fnm >/dev/null 2>&1 && [[ ! -x "$(fl__fnm_dir)/fnm" ]] \
     && ! command -v unzip >/dev/null 2>&1 && ! fl_linux_pkg_installed unzip; then
    out="${out:+$out }unzip"
  fi
  printf '%s' "$out"
}

fl_linux_unit_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

# fl_ensure_service_started FORMULA PATTERN: the systemd system unit of an
# apt service, started with sudo when it is not running
fl_ensure_service_started() {
  local unit n=0
  unit="$(fl__apt_unit "$1")"
  if fl_linux_unit_active "$unit"; then
    fl_ok "${unit} is running"
    return 0
  fi
  fl_warn "${unit} is not running; starting now"
  fl_sudo_begin "start the ${unit} service (systemctl start ${unit})" || fl_die "sudo is needed to start ${unit}." "Run: sudo systemctl start ${unit}"
  fl_log "run: sudo systemctl start ${unit}"
  sudo systemctl start "$unit" || fl_die "systemctl start ${unit} failed." "Look at: sudo systemctl status ${unit}"
  while ! fl_linux_unit_active "$unit" && [[ "$n" -lt 15 ]]; do sleep 1; n=$((n + 1)); done
  fl_linux_unit_active "$unit" || fl_die "${unit} did not come up." "Look at: sudo systemctl status ${unit}"
  fl_ok "${unit} is running"
}

# ---- the MariaDB root password

fl_secret_store_locked_hint() {
  fl_fail "the password file $(fl__secret_file) could not be written, so MariaDB was left unchanged"
  fl_fix "make ${FL_STATE_DIR} writable, or pass MARIADB_ROOT_PASSWORD='...' to use a password you keep yourself"
}

fl_mariadb_password_missing_msg() { printf 'no MariaDB root password in %s' "$(fl__secret_file)"; }

fl_mariadb_admin_note() {
  fl_warn "MariaDB root@localhost logs in over the socket only (a fresh apt install); setting a password ($1) through sudo mariadb"
}

# Ubuntu's root@localhost has no password: the OS root user logs in over the
# unix socket (authentication_string 'invalid', empty or NULL). Only that
# fresh state is ours to change. A root that already has a password is not
# touched, and its password is asked for, as on the Mac. The password
# sources are tried first, so a set up machine never asks for sudo at all.
# The probe runs as the OS root user ("sudo mariadb"), inside the install's
# one sudo session.
fl_mariadb_admin_open() {
  local bin pw hash
  FL_MARIADB_ADMIN_USER=""; FL_MARIADB_ADMIN_SUDO=0
  bin="$(fl_mariadb_client)"
  [[ -n "$bin" ]] || return 1
  if fl_mariadb_root_open; then FL_MARIADB_ADMIN_USER="root"; return 0; fi
  if [[ -n "${MARIADB_ROOT_PASSWORD:-}" ]] && fl_mariadb_root_verify "$MARIADB_ROOT_PASSWORD"; then return 1; fi
  pw="$(fl_keychain_get || true)"
  if [[ -n "$pw" ]] && fl_mariadb_root_verify "$pw"; then return 1; fi
  # a dry run asks for nothing and runs nothing as root
  [[ "${FL_DRY_RUN:-0}" != "1" ]] || return 1
  if ! fl_sudo_begin "administer MariaDB over its local socket (sudo mariadb), to set the root password"; then
    fl_warn "sudo is needed to set the MariaDB root password on a fresh install"
    return 1
  fi
  hash="$(sudo "$bin" --protocol=socket -u root --connect-timeout=2 -sNe "SELECT authentication_string FROM mysql.user WHERE User='root' AND Host='localhost'" 2>/dev/null)" || return 1
  case "$(printf '%s\n' "$hash" | head -n1)" in
    invalid|NULL|"") ;;
    *) return 1 ;;
  esac
  FL_MARIADB_ADMIN_USER="root"; FL_MARIADB_ADMIN_SUDO=1
}

# fl_mariadb_secure PASSWORD: the secure-installation SQL (shared with the
# Mac) through the admin login. root keeps unix_socket next to the new
# native password, so "sudo mariadb" keeps working for the administrator.
# The SQL, and with it the password, goes on stdin, never in an argument.
fl_mariadb_secure() {
  local pw="$1" bin via="unix_socket OR mysql_native_password"
  bin="$(fl_mariadb_client)"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would set the root password, remove anonymous users and the test database, and block remote root (as root, sudo mariadb)"
    return 0
  fi
  fl_log "mariadb: securing root@localhost through the socket (password not logged)"
  if [[ "$FL_MARIADB_ADMIN_SUDO" == "1" ]]; then
    fl_mariadb_secure_sql "$pw" "$via" | sudo "$bin" --protocol=socket -u root
  else
    # root accepted a login without a password already
    fl_mariadb_secure_sql "$pw" "mysql_native_password" | MYSQL_PWD="" "$bin" -u root --protocol=socket
  fi
}

# ---- config drop-in and restart

fl_mariadb_utf8_dropin_path() { printf '%s/99-frappe.cnf' "$FL_MYSQL_CONF_DIR"; }

# Ubuntu's my.cnf includes mariadb.conf.d: nothing to add
fl_mariadb_includedir_present() { return 0; }
fl_mariadb_includedir_ensure() { FL_MYCNF_CHANGED=0; return 0; }

# fl_mariadb_dropin_apply TEMPLATE PATH: as on the Mac, but the folder is
# root's: the rendered file is written to a temporary file and put in place
# with "sudo install -m 0644". Sets FL_TEMPLATE_CHANGED.
fl_mariadb_dropin_apply() {
  local template="$1" path="$2" rendered status tmp
  FL_TEMPLATE_CHANGED=0
  rendered="$(fl_template_render "$template")"
  status="$(fl_template_status "$path" "$rendered")"
  [[ "$status" == "current" ]] && return 0
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would write ${path} (${status}) with sudo install -m 0644"
    FL_TEMPLATE_CHANGED=1
    return 0
  fi
  [[ "$status" == "foreign" ]] && fl_warn "${path} was not written by benchbar; backing it up before replacing"
  if [[ "$status" != "missing" ]]; then fl_backup_file "$path" || return 1; fi
  fl_sudo_begin "write ${path} (the utf8mb4 settings Frappe needs)" || { fl_fail "sudo is needed to write ${path}"; return 1; }
  tmp="$(mktemp "${TMPDIR:-/tmp}/benchbar-cnf.XXXXXX")" || { fl_fail "could not create a temporary file"; return 1; }
  printf '%s' "$rendered" >"$tmp" || { rm -f "$tmp"; fl_fail "could not write ${tmp}"; return 1; }
  fl_log "run: sudo install -m 0644 ${tmp} ${path}"
  if ! sudo install -m 0644 "$tmp" "$path"; then
    rm -f "$tmp"
    fl_fail "could not write ${path} (sudo install failed)"
    return 1
  fi
  rm -f "$tmp"
  FL_TEMPLATE_CHANGED=1
  fl_ok "wrote ${path}"
}

fl_mariadb_service_formula() { printf 'mariadb'; }

# a changed drop-in needs a restart; a stopped server reads it on its next start
fl_mariadb_restart_if_running() {
  local running
  fl_linux_unit_active mariadb || return 0
  running="$(fl_mariadb_running_benches | tr '\n' ' ')"
  if [[ -n "${running% }" ]]; then
    fl_warn "restarting MariaDB, which these running benches use: ${running% }; their database connections drop for a few seconds"
  else
    fl_info "restarting MariaDB (no known bench is running)"
  fi
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: sudo systemctl restart mariadb"
    return 0
  fi
  fl_sudo_begin "restart MariaDB (systemctl restart mariadb)" || { fl_warn "restart skipped; run: sudo systemctl restart mariadb"; return 1; }
  fl_run_long "systemctl restart mariadb" sudo systemctl restart mariadb || { fl_warn "restart failed; run: sudo systemctl restart mariadb"; return 1; }
}

# ---- what needs sudo, asked once up front

# true when neither the environment nor the password file has a MariaDB root
# password that logs in: a fresh server, administered with sudo mariadb
fl_linux_db_needs_admin() {
  local pw
  fl_linux_pkg_installed mariadb-server || return 0
  fl_linux_unit_active mariadb || return 0
  if [[ -n "${MARIADB_ROOT_PASSWORD:-}" ]] && fl_mariadb_root_verify "$MARIADB_ROOT_PASSWORD"; then return 1; fi
  pw="$(fl_keychain_get || true)"
  if [[ -n "$pw" ]] && fl_mariadb_root_verify "$pw"; then return 1; fi
  return 0
}

# fl_linux_sudo_reasons: one line per thing in this run that needs sudo
# (nothing when the machine is set up, so a second run never asks)
fl_linux_sudo_reasons() {
  local missing path
  missing="$(fl_linux_missing_packages)"
  [[ -z "$missing" ]] || printf 'install the apt packages: %s\n' "$missing"
  if [[ -z "$missing" ]]; then
    fl_linux_unit_active mariadb || printf 'start the mariadb service (systemctl start mariadb)\n'
    fl_linux_unit_active redis-server || printf 'start the redis-server service (systemctl start redis-server)\n'
  fi
  fl_linux_db_needs_admin && printf 'set the MariaDB root password over its local socket (sudo mariadb)\n'
  path="$(fl_mariadb_utf8_dropin_path)"
  [[ "$(fl_template_status "$path" "$(fl_template_render mariadb-frappe.cnf)")" == "current" ]] \
    || printf 'write %s and restart MariaDB (the utf8mb4 settings)\n' "$path"
  if fl_wkhtmltopdf_will_install; then
    printf 'install the patched wkhtmltopdf package (apt-get install, sha256 verified)\n'
  fi
  return 0
}

# ---- wkhtmltopdf from the pinned .deb

fl_wkhtmltopdf_sudo_reason() { printf 'install the wkhtmltopdf package (apt-get install %s)' "$FL_WKHTML_FILE"; }
fl_wkhtmltopdf_manual_install() { printf 'sudo apt-get install -y %s' "$FL_WKHTML_PKG"; }

# the package is built for x86_64 only
fl_wkhtmltopdf_will_install() {
  [[ "$(fl_wkhtmltopdf_state)" != "patched" ]] || return 1
  [[ "${FL_ARCH:-$(uname -m)}" == "x86_64" ]] || return 1
  [[ "${FL_ASSUME_YES:-0}" == "1" || -t 0 ]]
}

# fl_wkhtmltopdf_install: sudo apt-get install of the verified .deb, so apt
# pulls in the fonts and libraries it needs. As on the Mac, root copies the
# download into a fresh folder only root can write, hashes that copy itself
# and installs it, so the file that was verified is the file that is installed.
fl_wkhtmltopdf_install() {
  local root_dir="" root_pkg sum code=0
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: sudo mktemp -d ${FL_WKHTML_ROOT_TMP_TEMPLATE}"
    fl_info "dry-run: sudo install -m 0644 -o root ${FL_WKHTML_PKG} <that folder>/${FL_WKHTML_FILE}"
    fl_info "dry-run: sudo sha256sum <that folder>/${FL_WKHTML_FILE}   (must be ${FL_WKHTML_SHA256})"
    fl_info "dry-run: sudo apt-get update"
    fl_info "dry-run: sudo apt-get install -y <that folder>/${FL_WKHTML_FILE}"
    fl_info "dry-run: sudo rm -rf <that folder>"
    return 0
  fi
  root_dir="$(sudo mktemp -d "$FL_WKHTML_ROOT_TMP_TEMPLATE" 2>/dev/null || true)"
  case "$root_dir" in
    /tmp/benchbar-wkhtmltopdf.*) ;;
    *) fl_fail "could not create a root owned folder for the package (sudo mktemp -d ${FL_WKHTML_ROOT_TMP_TEMPLATE})"; return 1 ;;
  esac
  root_pkg="${root_dir}/${FL_WKHTML_FILE}"
  # apt reads the file as its own unprivileged user; only root can write here
  sudo chmod 0755 "$root_dir" 2>/dev/null || true
  fl_log "run: sudo install -m 0644 -o root ${FL_WKHTML_PKG} ${root_pkg}"
  if ! sudo install -m 0644 -o root "$FL_WKHTML_PKG" "$root_pkg"; then
    fl_fail "could not copy ${FL_WKHTML_FILE} into ${root_dir}"
    code=1
  else
    sum="$(sudo sha256sum "$root_pkg" 2>/dev/null | awk '{print $1}')"
    if [[ "$sum" != "$FL_WKHTML_SHA256" ]]; then
      fl_fail "checksum mismatch on the root owned copy of ${FL_WKHTML_FILE}: got ${sum:-nothing}, pinned ${FL_WKHTML_SHA256}"
      fl_note "nothing was installed; the download in ${FL_WKHTML_DOWNLOAD_DIR} is discarded"
      rm -f "$FL_WKHTML_PKG"
      code=1
    else
      fl_ok "root owned copy verified (sha256 ok)"
      # the package indexes may be stale on a fresh machine; a failed update is not fatal
      fl_run_long "apt-get update" sudo apt-get update || fl_warn "apt-get update failed; trying the install with the indexes there are"
      fl_run_long "apt-get install ${FL_WKHTML_FILE}" sudo apt-get install -y "$root_pkg" || code=1
    fi
  fi
  fl_log "run: sudo rm -rf ${root_dir}"
  sudo rm -rf "$root_dir" 2>/dev/null || fl_warn "could not remove ${root_dir}; run: sudo rm -rf ${root_dir}"
  [[ "$code" == "0" ]] || return 1
  hash -r 2>/dev/null || true
  case "$(fl_wkhtmltopdf_state)" in
    patched) fl_ok "$("$(fl_wkhtmltopdf_bin)" --version 2>&1 | head -n1) at $(fl_wkhtmltopdf_bin)"; fl_wkhtmltopdf_shadow_warn ;;
    *) fl_fail "the package installed but 'wkhtmltopdf --version' does not say 'with patched qt'"; return 1 ;;
  esac
}

# ---- hosts: *.localhost resolves to the loopback, nothing is written to /etc/hosts

# true when NAME resolves to the loopback address (any *.localhost does)
fl_linux_hosts_resolves() {
  local ip
  case "$1" in localhost|*.localhost) return 0 ;; esac
  ip="$(getent hosts "$1" 2>/dev/null | awk 'NR == 1 {print $1}')"
  case "$ip" in 127.*|::1) return 0 ;; esac
  return 1
}

# the JSON field hosts_entry and the Hosts column keep their meaning: "this
# name reaches the machine", true without a hosts line for *.localhost
fl_hosts_has_name() { fl_linux_hosts_resolves "$1"; }

# a name that does not resolve gets the command to run; benchbar never edits /etc/hosts here
fl_hosts_add_names() {
  local n
  for n in "$@"; do
    fl_site_name_ok "$n" || continue
    fl_linux_hosts_resolves "$n" && continue
    fl_warn "${n} does not resolve to this machine; add it to /etc/hosts yourself:"
    printf '  printf "127.0.0.1 %s\\n" | sudo tee -a /etc/hosts\n\n' "$n"
  done
  return 0
}

fl_hosts_line_place() { return 0; }
fl_hosts_manual_removal() { return 0; }
fl_hosts_remove_name() { FL_HOSTS_REMOVED=0; FL_HOSTS_MANUAL=""; return 0; }

# ------------------------------------------------------------- doctor, repair, report

# the Linux checks, repair actions and report pieces live in their own file
# shellcheck source=lib/frappe-local/doctor-linux.sh
. "${SCRIPT_DIR}/lib/frappe-local/doctor-linux.sh"
