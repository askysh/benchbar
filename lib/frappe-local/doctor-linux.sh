#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# doctor-linux.sh: doctor, repair and report on Linux (Ubuntu and Debian, WSL
# too). Sourced at the end of platform-linux.sh, after checks.sh, repair.sh and
# report.sh, so each function here replaces the Mac one of the same name.
#
# Checks that only make sense on a Mac are left out of the list (not emitted):
# formula_dates, python_leaves, legacy_agents, cleanmymac, mole, app_copies,
# full_disk_access, fork_safety and redis_6379 (the apt redis-server on 6379
# is expected here). The ids that stay keep their ids and action ids, so
# doctor --json and repair --json keep their shape.
#
# Doctor stays read only and never reads the MariaDB password file.

FL_CHECK_ORDER="brew mariadb_bind mariadb_utf8 pdf_engine env_python env_setuptools bench_version toolchain_node toolchain_yarn mariadb_version toolchain_pkgconfig socketio assets apps_txt app_branch_policy dependency_behind apps_behind lock_parse lock_drift profile_outdated logs bench_path honcho honcho_setuptools procfile runner agent runner_heartbeat scheduler stop_flag helpers cli_link cli_duplicate dead_agents hosts port_clash orphans ping"

# repair: no python_leaves, legacy_migrate, hosts_entry or redis_stop
FL_ACTION_ORDER="node_install yarn_install env_rebuild env_setuptools honcho_install honcho_setuptools node_requirements build clear_cache mariadb_bind mariadb_utf8 wkhtmltopdf_install port_block write_procfile write_runner write_plist write_helpers write_cli_link rotate_logs"
FL_OPTIONAL_ACTIONS="wkhtmltopdf_install"

# the apt packages a bench needs: the first two groups fail, the build ones warn
# (mysqlclient for Frappe v16 compiles against them; v15 does not)
FL_LINUX_PKGS_REQUIRED="mariadb-server mariadb-client redis-server"
FL_LINUX_PKGS_BUILD="pkg-config libmariadb-dev"

# the files and tools the checks read, overridable for the tests
# the same folder the install writes to (platform-linux.sh), one override for both
FL_MARIADB_CONF_DIR="${FL_MARIADB_CONF_DIR:-${FL_MYSQL_CONF_DIR:-/etc/mysql/mariadb.conf.d}}"
FL_MYSQL_CNF="${FL_MYSQL_CNF:-/etc/mysql/my.cnf}"
FL_MARIADBD_BIN="${FL_MARIADBD_BIN:-/usr/sbin/mariadbd}"
FL_CPUINFO="${FL_CPUINFO:-/proc/cpuinfo}"

# ------------------------------------------------------------- helpers

fl__apt_installed() {
  local st
  st="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)"
  [[ "$st" == *"install ok installed"* ]]
}

# fl__apt_missing PACKAGES...: the ones dpkg does not have, space separated
fl__apt_missing() {
  local p out=""
  for p in "$@"; do
    fl__apt_installed "$p" || out="${out}${out:+ }${p}"
  done
  printf '%s' "$out"
}

# The tools as the bench's processes see them: the uv Python and fnm Node
# folders and ~/.local/bin (what fl_profile_path_exports puts in the shell
# block), then the system folders. nvm's node lives in a shell PATH only.
fl_bench_which() {
  local p="" line
  while IFS= read -r line; do
    line="${line#export PATH=\"}"; line="${line%%:\$PATH\"}"
    p="${p}${line}:"
  done < <(fl_profile_path_exports "$FL_PROFILE" | grep '^export PATH=')
  p="${p}${FL_LAUNCHD_PATH_SYSTEM:-/usr/local/bin:/usr/bin:/bin}"
  PATH="$p" command -v "$1" 2>/dev/null || true
}

fl__mariadb_conf_dir() { printf '%s' "${FL_MARIADB_CONF_DIR%/}"; }

# true when /etc/mysql/my.cnf pulls the drop-in folder in
fl__mariadb_includedir_present() {
  local dir
  dir="$(fl__mariadb_conf_dir)"
  [[ -f "$FL_MYSQL_CNF" ]] || return 1
  grep -Eq "^[[:space:]]*!includedir[[:space:]]+${dir}/?[[:space:]]*$" "$FL_MYSQL_CNF" 2>/dev/null
}

# ------------------------------------------------------------- system packages

# Same id as on the Mac (brew): apt packages, the profile's uv Python and
# fnm Node. The fix line names the exact command.
chk_brew() {
  local missing build py node pyver major fixes="" msgs="" only_node=1
  pyver="${FL_PYTHON_BIN_NAME#python}"; major="$FL_NODE_MAJOR"
  # shellcheck disable=SC2086  # the lists are words on purpose
  missing="$(fl__apt_missing $FL_LINUX_PKGS_REQUIRED)"
  if [[ -n "$missing" ]]; then
    msgs="missing apt packages: ${missing}"
    fixes="sudo apt-get install -y ${missing}"
    only_node=0
  fi
  py="$(fl_python_bin)"
  if [[ ! -x "$py" ]]; then
    msgs="${msgs}${msgs:+; }Python ${pyver} (uv) not found"
    fixes="${fixes}${fixes:+ && }uv python install ${pyver}"
    only_node=0
  fi
  node="$(fl_node_bin)"
  if [[ ! -x "$node" ]]; then
    if [[ "$only_node" == "1" ]] && [[ -x "$(fl_fnm_bin)" ]] && [[ -d "${FL_BENCH_DIR}/apps/frappe" ]]; then
      # only Node: a profile that moved to a newer one; the bench still runs on the old
      msgs="Node ${major} (fnm) not found (the profile's Node moved; the bench still runs on the old one)"
    else
      msgs="${msgs}${msgs:+; }Node ${major} (fnm) not found"
    fi
    if [[ -x "$(fl_fnm_bin)" ]]; then
      fixes="${fixes}${fixes:+ && }$(fl_fnm_cmd) install ${major}"
    else
      fixes="${fixes}${fixes:+ && }${FL_SELF_DIR}/00-linux-system-deps.sh --profile ${FL_PROFILE}   (installs fnm)"
      only_node=0
    fi
  else
    only_node=0
  fi
  if [[ -n "$msgs" ]]; then
    if [[ "$only_node" == "1" ]]; then
      chk__set fail "$msgs" "$(fl_fnm_cmd) install ${major}" node_install
    else
      chk__set fail "$msgs" "$fixes"
    fi
    return 0
  fi
  # shellcheck disable=SC2086
  build="$(fl__apt_missing $FL_LINUX_PKGS_BUILD)"
  if [[ -n "$build" ]]; then
    chk__set warn "${FL_LINUX_PKGS_REQUIRED// /, } installed; missing build packages: ${build} (needed to build mysqlclient for frappe v16)" "sudo apt-get install -y ${build}"
  else
    chk__set ok "${FL_LINUX_PKGS_REQUIRED// /, }, ${FL_LINUX_PKGS_BUILD// /, }, Python ${pyver} (uv) and Node ${major} (fnm) installed"
  fi
}

# ------------------------------------------------------------- toolchain

chk_toolchain_node() {
  local node where ver major bindir
  bindir="$(fl__node_bindir_for "$FL_NODE_MAJOR")"
  if [[ -x "${FL_BENCH_DIR}/env/bin/node" ]]; then node="${FL_BENCH_DIR}/env/bin/node"; where="env/bin/node"
  else node="$(fl_bench_which node)"; where="$node"; fi
  if [[ -z "$node" ]]; then
    if [[ -d "$HOME/.nvm" ]]; then
      chk__set warn "no node on the bench's PATH (nvm's node is only on your shell's PATH, bench does not see it)" "$(fl_fnm_cmd) install ${FL_NODE_MAJOR}" node_install
    else
      chk__set warn "no node on the bench's PATH" "$(fl_fnm_cmd) install ${FL_NODE_MAJOR}" node_install
    fi
    return 0
  fi
  ver="$("$node" --version 2>/dev/null | tr -d 'v' || true)"
  major="${ver%%.*}"
  if [[ "$major" == "$FL_NODE_MAJOR" ]]; then
    chk__set ok "Node ${ver} at ${where}, profile ${FL_PROFILE} expects ${FL_NODE_MAJOR}"
  elif [[ "$where" == "env/bin/node" ]]; then
    # bench put it there; fnm cannot change it
    chk__set warn "Node ${ver:-unknown} at ${where}, profile ${FL_PROFILE} expects ${FL_NODE_MAJOR}" "$(fl_fnm_cmd) install ${FL_NODE_MAJOR}, then remove ${FL_BENCH_DIR}/env/bin/node so the bench uses ${bindir}/node"
  else
    chk__set warn "Node ${ver:-unknown} at ${where}, profile ${FL_PROFILE} expects ${FL_NODE_MAJOR}" "$(fl_fnm_cmd) install ${FL_NODE_MAJOR}   (the bench's PATH puts ${bindir} first)" node_install
  fi
}

chk_toolchain_yarn() {
  local yarn ver
  yarn="$(fl_bench_which yarn)"
  if [[ -z "$yarn" ]]; then
    chk__set warn "no yarn on the bench's PATH (bench build needs it)" "$(fl_npm_bin) install -g yarn" yarn_install
    return 0
  fi
  ver="$("$yarn" --version 2>/dev/null || true)"
  chk__set ok "yarn ${ver:-found} at ${yarn}"
}

chk_toolchain_pkgconfig() {
  local pc ver
  pc="$(fl_bench_which pkg-config)"
  if [[ -z "$pc" ]]; then
    chk__set warn "no pkg-config on the bench's PATH (mysqlclient for frappe v16 needs it)" "sudo apt-get install -y pkg-config libmariadb-dev"
    return 0
  fi
  ver="$("$pc" --version 2>/dev/null || true)"
  if "$pc" --exists libmariadb 2>/dev/null; then
    chk__set ok "pkg-config ${ver} finds libmariadb"
  else
    chk__set warn "pkg-config ${ver} does not find libmariadb" "sudo apt-get install -y libmariadb-dev"
  fi
}

# ------------------------------------------------------------- MariaDB

# The version of the server listening on 3306: the binary behind the
# listener (/proc/PID/exe), else /usr/sbin/mariadbd. Never logs in, so the
# password file is never read.
fl_mariadb_server_version() {
  local pid exe bin=""
  pid="$(fl_port_listener_pid 3306)"
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
    exe="$(readlink "${FL_PROC_DIR}/${pid}/exe" 2>/dev/null || true)"
    exe="${exe% (deleted)}"
    [[ "$exe" == */mariadbd && -x "$exe" ]] && bin="$exe"
  fi
  [[ -n "$bin" ]] || bin="$FL_MARIADBD_BIN"
  [[ -x "$bin" ]] || return 0
  "$bin" --version 2>/dev/null | fl_parse_mariadb_version | head -n1
}

# "formula version" of the server on 3306, the formula being the profile's
# name for that series (mariadb@10.11), so the policy comparison works
fl_mariadb_running_formula() {
  local ver
  [[ -n "$(fl_port_listener_pid 3306)" ]] || return 0
  ver="$(fl_mariadb_server_version)"
  [[ -n "$ver" ]] || return 0
  printf 'mariadb@%s %s' "$(printf '%s' "$ver" | awk -F. '{print $1 "." $2}')" "$ver"
}

# shellcheck disable=SC2153  # FL_MARIADB_MIN is set by the profile
chk_mariadb_version() {
  local ver mm
  if [[ -z "$(fl_port_listener_pid 3306)" ]]; then
    chk__set warn "nothing listens on 3306: MariaDB is not running" "sudo systemctl start mariadb"
    return 0
  fi
  ver="$(fl_mariadb_server_version)"
  mm="$(fl_mm_num "$ver")"
  if [[ -z "$ver" ]]; then
    chk__set ok "MariaDB listens on 3306 (version not readable)"
  elif [[ "$mm" -lt "$(fl_mm_num "$FL_MARIADB_MIN")" ]]; then
    chk__set warn "MariaDB ${ver} is older than ${FL_MARIADB_MIN}, the oldest profile ${FL_PROFILE} supports" "sudo apt-get install -y mariadb-server   (or MariaDB's own apt repository: https://mariadb.org/download/?t=repo-config)"
  elif [[ "$mm" -gt "$(fl_mm_num "$FL_MARIADB_MAX")" ]]; then
    chk__set warn "MariaDB ${ver} is newer than ${FL_MARIADB_MAX}, the newest profile ${FL_PROFILE} is tested with" "sudo apt-get install -y mariadb-server   (or MariaDB's own apt repository: https://mariadb.org/download/?t=repo-config)"
  else
    chk__set ok "MariaDB ${ver} on 3306 (profile ${FL_PROFILE} accepts ${FL_MARIADB_MIN} to ${FL_MARIADB_MAX})"
  fi
}

fl_mariadb_dropin_path() {
  printf '%s/99-benchbar-local-only.cnf' "$(fl__mariadb_conf_dir)"
}

chk_mariadb_bind() {
  local addrs exposed="" a dropin
  dropin="$(fl_mariadb_dropin_path)"
  addrs="$(fl_port_listen_addresses 3306)"
  if [[ -n "$addrs" ]]; then
    while IFS= read -r a; do
      case "$a" in
        127.0.0.1:*|"[::1]:"*|localhost:*) ;;
        *) exposed="${exposed} ${a}" ;;
      esac
    done <<<"$addrs"
    if [[ -n "$exposed" ]]; then
      chk__set warn "MariaDB listens on${exposed} (reachable from the network)" "${FL_SELF} repair (writes ${dropin} with sudo and restarts MariaDB)" mariadb_bind
    else
      chk__set ok "MariaDB listens on 127.0.0.1 only"
    fi
    return 0
  fi
  if [[ -f "$dropin" ]] || grep -qs 'bind-address[[:space:]]*=[[:space:]]*127\.0\.0\.1' "$(fl__mariadb_conf_dir)"/*.cnf 2>/dev/null; then
    chk__set ok "MariaDB is not running; bind-address drop-in present"
  else
    chk__set warn "MariaDB is not running and no bind-address drop-in exists" "${FL_SELF} repair (writes ${dropin} with sudo)" mariadb_bind
  fi
}

chk_mariadb_utf8() {
  local dropin status
  dropin="$(fl__mariadb_conf_dir)/99-frappe.cnf"
  status="$(fl_template_status "$dropin" "$(fl_template_render mariadb-frappe.cnf)")"
  case "$status" in
    current) chk__set ok "utf8mb4 drop-in ${dropin} is current" ;;
    foreign)
      if grep -q 'character-set-server[[:space:]]*=[[:space:]]*utf8mb4' "$dropin" 2>/dev/null; then
        chk__set ok "${dropin} sets utf8mb4 (not written by benchbar, left alone)"
      else
        chk__set warn "${dropin} exists but does not set utf8mb4" "${FL_SELF} repair (writes it with sudo and restarts MariaDB)" mariadb_utf8
        return 0
      fi ;;
    *) chk__set warn "utf8mb4 drop-in is ${status} (${dropin}); Frappe needs utf8mb4 server wide" "${FL_SELF} repair (writes it with sudo and restarts MariaDB)" mariadb_utf8; return 0 ;;
  esac
  # the drop-in only counts when my.cnf pulls the folder in. The server's
  # live charset is not queried: doctor is read only and must never read the
  # password file (the app runs it on a timer).
  if ! fl__mariadb_includedir_present; then
    chk__set warn "${FL_MYSQL_CNF} is missing or has no '!includedir ${FL_MARIADB_CONF_DIR}', so the utf8mb4 drop-in is ignored" "add the line '!includedir ${FL_MARIADB_CONF_DIR}/' to ${FL_MYSQL_CNF} (sudo), then: sudo systemctl restart mariadb   (Ubuntu's own my.cnf has it; benchbar does not edit that file)"
  fi
}

# ------------------------------------------------------------- service unit, hosts

# agent: the bench's systemd user unit. fl_agent_* read systemd (systemd.sh).
chk_agent() {
  local unit state pid code
  unit="$(fl_agent_plist_path)"
  chk__template "systemd unit" "$unit" "$FL_R_PLIST" write_plist
  [[ "$CHK_STATUS" == "ok" ]] || return 0
  if ! fl_agent_loaded; then
    chk__set warn "unit $(fl_agent_label) is written but not loaded" "$(fl_agent_load_hint "$unit")" write_plist
    return 0
  fi
  state="$(fl_agent_field state)"; pid="$(fl_agent_field pid)"; code="$(fl_agent_field 'last exit code')"
  if [[ "$state" == "running" ]]; then
    chk__set ok "unit $(fl_agent_label) loaded, running (pid ${pid:-?})"
  elif [[ -n "$code" && "$code" != "0" && "$code" != "(never exited)" ]]; then
    chk__set warn "unit loaded, ${state:-not running}, last exit code ${code}" "${FL_SELF} logs"
  else
    chk__set ok "unit $(fl_agent_label) loaded, ${state:-not running}"
  fi
}

# No /etc/hosts edit on Linux: *.localhost resolves to loopback by itself.
# The name has to resolve to 127.0.0.1 or ::1, whichever way (nss-myhostname,
# systemd-resolved, a hosts line the user made).
# the fix for a site name that does not resolve: *.localhost needs
# nss-myhostname (the install adds it); any other name needs a hosts line
fl_linux_hosts_fix() {
  case "$FL_SITE" in
    *.localhost) printf "sudo apt-get install -y libnss-myhostname (it adds 'myhostname' to the hosts line of /etc/nsswitch.conf; check that line if the package is already there)" ;;
    *) printf "use a *.localhost site name (%s site default <name>.localhost), or map this one yourself: echo '127.0.0.1 %s' | sudo tee -a /etc/hosts" "$FL_SELF" "$FL_SITE" ;;
  esac
}

chk_hosts() {
  local first
  first="$(getent hosts "$FL_SITE" 2>/dev/null | awk 'NR == 1 {print $1}')"
  case "$first" in
    127.0.0.1|::1) chk__set ok "${FL_SITE} resolves to ${first}" ;;
    "") chk__set fail "${FL_SITE} does not resolve (getent hosts finds nothing)" "$(fl_linux_hosts_fix)" ;;
    *) chk__set fail "${FL_SITE} resolves to ${first}, not to 127.0.0.1 or ::1" "$(fl_linux_hosts_fix)" ;;
  esac
}

# Homebrew and the installer's app hand-off do not exist here; only the
# bashrc block and ~/.local/bin links matter (chk_helpers, chk_cli_link)
chk_cli_duplicate() {
  chk__set ok "no other copy: Homebrew and the app are not part of a Linux install"
}

# ------------------------------------------------------------- repair

# apt, the .deb and the MariaDB config and restart need root; nothing else does
fl_action_needs_sudo() {
  case "$1" in mariadb_bind|mariadb_utf8|wkhtmltopdf_install) return 0 ;; esac
  return 1
}

# the bench's tools by the uv Python and fnm Node folders; the apt -dev
# packages put headers and pkg-config files where the compiler looks
fl_bench_env_exports() {
  local py node
  py="$(fl_python_bin)"; node="$(fl_node_bin)"
  export PATH="${py%/*}:${node%/*}:$HOME/.local/bin:$PATH"
}

# Only Node: the old one stays for whatever else uses it, and the bench's
# PATH (shell block, unit) puts the profile's first.
act_node_install() {
  if [[ -x "$(fl_node_bin)" ]]; then
    fl_info "Node ${FL_NODE_MAJOR} is already installed"
    return 0
  fi
  [[ -x "$(fl_fnm_bin)" ]] || { fl_fail "fnm is not installed; run ${FL_SELF_DIR}/00-linux-system-deps.sh --profile ${FL_PROFILE}"; return 1; }
  FNM_DIR="$(fl__fnm_dir)" fl_run_long "fnm install ${FL_NODE_MAJOR}" "$(fl_fnm_bin)" install "$FL_NODE_MAJOR" || return 1
  [[ -x "$(fl_node_bin)" || "${FL_DRY_RUN:-0}" == "1" ]] || { fl_fail "Node ${FL_NODE_MAJOR} installed, but $(fl_node_bin) is missing"; return 1; }
  return 0
}

# yarn is global to a Node: a new Node needs its own.
act_yarn_install() {
  local npm
  npm="$(fl_npm_bin)"
  [[ -x "$npm" || "${FL_DRY_RUN:-0}" == "1" ]] || { fl_fail "no npm at ${npm}; install Node ${FL_NODE_MAJOR} first ($(fl_fnm_cmd) install ${FL_NODE_MAJOR})"; return 1; }
  fl_run_long "npm install -g yarn (Node ${FL_NODE_MAJOR})" "$npm" install -g yarn || return 1
  return 0
}

# ------------------------------------------------------------- report

# a WSL Desktop can be a Windows folder: the reports live in the state folder
fl_report_default_out() { printf '%s/reports' "$FL_STATE_DIR"; }

fl_report_platform_versions() {
  local f="$1"
  fl_report_cmd "$f" "OS (os-release)" cat "$FL_OS_RELEASE"
  fl_report_cmd "$f" "kernel" uname -r
  fl_report_cmd "$f" "arch" uname -m
  fl_report_cmd "$f" "WSL" printf '%s\n' "$(fl_is_wsl && printf yes || printf no)"
  # shellcheck disable=SC2016  # an awk program
  fl_report_cmd "$f" "cpu" awk -F': *' '/^model name/ {print $2; exit}' "$FL_CPUINFO"
  # shellcheck disable=SC2016  # dpkg-query's own format string
  fl_report_cmd "$f" "apt packages" dpkg-query -W -f='${Package} ${Version}\n' mariadb-server redis-server pkg-config libmariadb-dev
  fl_report_cmd "$f" "uv" uv --version
  fl_report_cmd "$f" "fnm" "$(fl_fnm_bin)" --version
}

# the systemd user unit instead of the launchd agent
fl_report_agent() {
  local unit
  unit="$(fl_agent_label).service"
  : >"${FL_REPORT_DIR}/systemd.txt"
  fl_report_cmd systemd.txt "systemctl --user status ${unit}" systemctl --user status "$unit" --no-pager
  : >"${FL_REPORT_DIR}/journal.txt"
  fl_report_cmd journal.txt "journalctl --user -u ${unit} -n ${FL_REPORT_TAIL_LINES}" journalctl --user -u "$unit" -n "$FL_REPORT_TAIL_LINES" --no-pager
  fl_report_copy "$(fl_agent_plist_path)" agent.service
}

# The names this machine goes by: what "hostname" prints, its short form and
# /etc/hostname. One per line, longest first, nothing shorter than three
# characters, never localhost.
fl_report_host_names() {
  local h
  h="$(hostname 2>/dev/null || true)"
  {
    printf '%s\n' "$h"
    printf '%s\n' "${h%%.*}"
    head -n1 /etc/hostname 2>/dev/null || true
  } | awk 'length($0) >= 3 && $0 != "localhost" && !seen[$0]++ { print length($0) "\t" $0 }' | sort -rn | cut -f2-
}
