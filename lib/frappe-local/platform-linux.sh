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
