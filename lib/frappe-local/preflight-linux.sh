#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# preflight-linux.sh: what a Linux install (WSL above all) looks at before it
# asks for sudo or starts the long work, and apt itself.
#
# Sourced at the end of platform-linux.sh. The checks answer in two lists of
# lines "id|message|fix": blockers (the plan lists them and the run stops
# before any sudo or step, fl_install_blockers_die) and warnings (the plan
# lists them, the run goes on). Their ids are stable:
#
#   blockers  port_3306_in_use, port_6379_in_use (a program of this distro,
#             another distro or Windows holds it), systemd_not_running,
#             bench_on_windows_fs, github_unreachable
#   warnings  wsl_memory_low, wsl_disk_low, apt_mirror_unreachable,
#             pypi_unreachable, npm_registry_unreachable, nodejs_unreachable, astral_unreachable
#
# Nothing here changes the machine, edits .wslconfig or reads a password.

FL_MEMINFO="${FL_MEMINFO:-/proc/meminfo}"
FL_APT_DIR="${FL_APT_DIR:-/etc/apt}"
FL_PROC_MOUNTS="${FL_PROC_MOUNTS:-/proc/self/mounts}"
# the Windows drive whose free space the install plan looks at (the one that
# normally holds the distro's disk), and the memory a build is happy with
FL_WIN_DRIVE_DIR="${FL_WIN_DRIVE_DIR:-/mnt/c}"
FL_WSL_DISK_WARN_GB="${FL_WSL_DISK_WARN_GB:-15}"
FL_WSL_MEM_WARN_MB="${FL_WSL_MEM_WARN_MB:-5500}"
# --allow-windows-fs: the only override of bench_on_windows_fs
FL_ALLOW_WINDOWS_FS="${FL_ALLOW_WINDOWS_FS:-0}"

# ------------------------------------------------------------- apt

# fl_apt_get ARGS...: apt-get as root through the sudo wrapper (the password of
# BENCHBAR_SUDO=env stays on its pipe: this is a plain "sudo" call). No
# questions (debconf frontend, needrestart), a wait of up to 10 minutes for the
# dpkg lock another apt holds (unattended-upgrades on a fresh distro), the old
# config file kept, and the proxy of this shell handed on, which sudo drops. A
# proxy can carry credentials (user:password@host), so it never goes on a
# command line (ps, sudo's log): it is written to an apt config file (0600, in
# a private temp dir, removed after the call) that APT_CONFIG points to.
fl_apt_get() {
  local v p dir="" conf="" code=0 envs=(DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a)
  for v in no_proxy NO_PROXY; do
    [[ -z "${!v:-}" ]] || envs+=("${v}=${!v}")
  done
  p="${http_proxy:-${HTTP_PROXY:-}}"
  v="${https_proxy:-${HTTPS_PROXY:-}}"
  [[ -n "$v" ]] || v="$p"
  [[ -n "$p" ]] || p="$v"
  if [[ -n "$p" ]]; then
    dir="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/benchbar-apt.XXXXXX")" || return 1
    conf="${dir}/apt.conf"
    # a double quote, backslash or newline in a value would end the apt string
    p="${p//[\\\"$'\n']/}"
    v="${v//[\\\"$'\n']/}"
    if ! (umask 077 && printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$p" "$v" >"$conf"); then
      rm -f "$conf"
      rmdir "$dir" 2>/dev/null || true
      return 1
    fi
    envs+=("APT_CONFIG=${conf}")
  fi
  sudo env "${envs[@]}" apt-get -o "DPkg::Lock::Timeout=${FL_APT_LOCK_TIMEOUT:-600}" -o Dpkg::Options::=--force-confold "$@" || code=$?
  if [[ -n "$dir" ]]; then
    rm -f "$conf"
    rmdir "$dir" 2>/dev/null || true
  fi
  return "$code"
}

# true while another apt, dpkg or unattended-upgrades runs (it holds the lock)
fl_apt_busy() { pgrep -x '^(apt|apt-get|aptitude|dpkg|unattended-upgr)$' >/dev/null 2>&1; }

# fl_apt_run_long LABEL APT_ARGS...: fl_apt_get with a spinner and, when
# another apt holds the lock, one line (and progress line) saying that this is
# the wait, so the JSON stream is not silent while apt waits for it
fl_apt_run_long() {
  local label="$1"
  shift
  if [[ "${FL_DRY_RUN:-0}" != "1" ]] && fl_apt_busy; then
    fl_info "waiting for another apt (unattended-upgrades): apt waits up to $((${FL_APT_LOCK_TIMEOUT:-600} / 60)) minutes for its lock"
    fl_jsonl_progress "waiting for another apt (unattended-upgrades)" 0
  fi
  fl_run_long "$label" fl_apt_get "$@"
}

# ------------------------------------------------------------- systemd

# the fix for a distro that does not run systemd
fl_linux_systemd_fix() {
  if fl_is_wsl; then
    printf "add '[boot]' and 'systemd=true' to /etc/wsl.conf (sudo nano /etc/wsl.conf), then run in Windows: wsl.exe --terminate %s" "${WSL_DISTRO_NAME:-DISTRO}"
  else
    printf 'boot this system with systemd as its init'
  fi
}

# ------------------------------------------------------------- the Windows side

# the folder of netstat.exe: FL_WIN_NETSTAT (a test's), the Windows PATH that
# WSL appends, wslpath for the Windows folder, then the C: drive
fl_wsl_netstat_bin() {
  local bin p
  if [[ -n "${FL_WIN_NETSTAT:-}" ]]; then
    [[ -x "$FL_WIN_NETSTAT" ]] || return 1
    printf '%s' "$FL_WIN_NETSTAT"
    return 0
  fi
  bin="$(command -v netstat.exe 2>/dev/null || true)"
  if [[ -z "$bin" ]] && command -v wslpath >/dev/null 2>&1; then
    p="$(wslpath -u 'C:\Windows\System32' 2>/dev/null || true)"
    [[ -n "$p" && -x "$p/netstat.exe" ]] && bin="$p/netstat.exe"
  fi
  [[ -n "$bin" ]] || { [[ -x /mnt/c/Windows/System32/netstat.exe ]] && bin=/mnt/c/Windows/System32/netstat.exe; }
  [[ -n "$bin" && -x "$bin" ]] || return 1
  printf '%s' "$bin"
}

# the Windows sockets that listen, "port pid" lines (loaded once by
# fl_wsl_windows_load, in the parent: a $(...) copy sees the variable)
FL_WIN_LISTEN=""
FL_WIN_LISTEN_STATE=""

# fl_wsl_windows_load: one "netstat.exe -ano" of Windows (the TCP and TCPv6
# lines; a listening socket has 0.0.0.0:0 or [::]:0 as its foreign address,
# whatever language the state word is in), a few seconds at most. Only
# listeners on 0.0.0.0, 127.0.0.1 and [::] count. Silent and harmless when
# Windows interop is off, netstat.exe is missing or slow.
fl_wsl_windows_load() {
  local bin out err
  [[ -z "$FL_WIN_LISTEN_STATE" ]] || return 0
  FL_WIN_LISTEN_STATE=unavailable
  fl_is_wsl || return 0
  bin="$(fl_wsl_netstat_bin)" || return 0
  out="$(mktemp "${TMPDIR:-/tmp}/benchbar-netstat.XXXXXX")"
  err="$(mktemp "${TMPDIR:-/tmp}/benchbar-netstat.XXXXXX")"
  # from / : on some WSL builds a Windows program cannot start when the
  # working directory is a folder under the Linux home ("Invalid argument")
  if ( cd / && fl_run_capture_timeout "${FL_WIN_NETSTAT_SECS:-5}" "$out" "$err" "$bin" -ano ); then
    FL_WIN_LISTEN="$(tr -d '\r' <"$out" | awk '
      $1 == "TCP" && NF >= 5 && $3 ~ /:0$/ {
        la = $2; i = length(la)
        while (i > 0 && substr(la, i, 1) != ":") i--
        if (i == 0) next
        addr = substr(la, 1, i - 1)
        if (addr == "0.0.0.0" || addr == "127.0.0.1" || addr == "[::]") print substr(la, i + 1), $NF
      }')"
    FL_WIN_LISTEN_STATE=ok
  fi
  rm -f "$out" "$err"
  return 0
}

# fl_port_outside_holder PORT: under WSL, who holds PORT outside this distro
# (a sentence part, status 0), or nothing (status 1). A listener inside this
# distro is not asked about: the checks of the distro own it, and it is what
# WSL's localhost forwarding (wslrelay.exe) shows in Windows' netstat too. Two
# ways to see Windows: its own netstat (once loaded) and a TCP connect to
# 127.0.0.1, which reaches a Windows listener under mirrored networking.
fl_port_outside_holder() {
  local pid
  fl_is_wsl || return 1
  fl_port_listening "$1" && return 1
  pid="$(awk -v p="$1" '$1 == p {print $2; exit}' <<<"$FL_WIN_LISTEN")"
  if [[ -n "$pid" ]]; then
    printf 'a Windows program (PID %s)' "$pid"
    return 0
  fi
  if declare -F fl_tcp_open >/dev/null && fl_tcp_open "$1"; then
    printf 'a program outside this distro (a Windows program, with mirrored networking)'
    return 0
  fi
  return 1
}

# fl_windows_port_fix PORT: how to find the Windows program
fl_windows_port_fix() {
  printf 'In Windows PowerShell run: netstat -ano | findstr :%s (the last column is the PID), find that PID in Task Manager (Details tab), close the program, then run benchbar install again' "$1"
}

# ------------------------------------------------------------- the network

# the hosts the install downloads from: "id|name|url|blocker" (1 = a failure
# stops the plan, 0 = a warning). The apt mirror is the first archive in
# /etc/apt and only a warning: curl does not know apt's own proxy settings, and
# a mirror can be file: or mirror+file:, which are skipped. github.com holds
# frappe and the uv Pythons.
fl_net_hosts() {
  local mirror
  mirror="$(fl__apt_mirror_url)"
  case "$mirror" in
    http://*|https://*) printf 'apt_mirror_unreachable|%s|%s|0\n' "$(fl__url_host "$mirror")" "$mirror" ;;
  esac
  printf 'github_unreachable|github.com|https://github.com|1\n'
  printf 'pypi_unreachable|pypi.org|https://pypi.org|0\n'
  printf 'npm_registry_unreachable|registry.npmjs.org|https://registry.npmjs.org|0\n'
  printf 'nodejs_unreachable|nodejs.org|https://nodejs.org|0\n'
  printf 'astral_unreachable|astral.sh|https://astral.sh|0\n'
}

fl__url_host() {
  local h="${1#*://}"
  h="${h%%/*}"
  printf '%s' "${h%%:*}"
}

# the hosts that did not answer, as fl_net_hosts lines (set by fl_net_probe)
FL_NET_FAILED=""
FL_NET_PROBED=0

# fl_net_probe: every host of fl_net_hosts, together, 10 seconds each at most;
# a host that failed is asked once more before it is reported.
# Any answer counts (a 403 too): only no answer at all is a failure.
fl_net_probe() {
  local dir id name url blocker line pid pids=()
  [[ "$FL_NET_PROBED" != "1" ]] || return 0
  FL_NET_PROBED=1
  FL_NET_FAILED=""
  command -v curl >/dev/null 2>&1 || return 0
  dir="$(mktemp -d "${TMPDIR:-/tmp}/benchbar-net.XXXXXX")"
  while IFS='|' read -r id name url blocker; do
    [[ -n "$id" ]] || continue
    (curl -s -o /dev/null --connect-timeout 10 --max-time 10 "$url" >/dev/null 2>&1 || curl -s -o /dev/null --connect-timeout 10 --max-time 10 "$url" >/dev/null 2>&1 || : >"${dir}/${id}") </dev/null >/dev/null 2>&1 3>&- &
    pids+=("$!")
  done < <(fl_net_hosts)
  # each probe by its pid: a bare "wait" would also wait for a spinner or any other job of the run
  for pid in ${pids[@]+"${pids[@]}"}; do wait "$pid" 2>/dev/null || true; done
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ -f "${dir}/${line%%|*}" ]] && FL_NET_FAILED="${FL_NET_FAILED}${line}"$'\n'
  done < <(fl_net_hosts)
  rm -rf "$dir"
  return 0
}

# the advice that goes with every host that did not answer
fl_net_fix() {
  if fl_is_wsl; then
    printf 'a VPN or proxy on Windows often blocks WSL: pause the VPN, or set http_proxy and https_proxy in this distro. In %%UserProfile%%\\.wslconfig under [wsl2] you can try networkingMode=mirrored, dnsTunneling=true and autoProxy=true (BenchBar never edits that file), then run wsl.exe --shutdown in Windows and benchbar install again'
  else
    printf 'check the network, DNS and any proxy (set http_proxy and https_proxy), then run benchbar install again'
  fi
}

# fl_install_preflight_load: the slow looks, once, in the parent shell, before
# the plan: Windows' listening ports (WSL) and the hosts (unless --offline)
fl_install_preflight_load() {
  fl_wsl_windows_load
  [[ "${OFFLINE:-0}" == "1" ]] || fl_net_probe
  return 0
}

# fl_preflight_internet [OFFLINE]: the phase scripts' check. The hosts the
# install needs, not one address: github.com stops the run, the
# others warn. benchbar install has asked already (its plan), so a run that
# got here from it finds the same answer.
fl_preflight_internet() {
  local offline="${1:-0}" id name url blocker line stop=0
  if [[ "$offline" == "1" || "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_warn "Skipping internet connectivity check."
    return 0
  fi
  fl_require_cmd curl "Install curl: sudo apt-get install -y curl"
  fl_net_probe
  while IFS='|' read -r id name url blocker; do
    [[ -n "$id" ]] || continue
    if [[ "$blocker" == "1" ]]; then
      fl_fail "${name} did not answer within 10 seconds"
      stop=1
    else
      fl_warn "${name} did not answer within 10 seconds; the install downloads from it"
    fi
    fl_info "fix: $(fl_net_fix)"
  done <<<"$FL_NET_FAILED"
  [[ "$stop" != "1" ]] || { FL_ERROR_ID="network_unreachable"; fl_die "No internet connection to the hosts the install needs." "$(fl_net_fix)"; }
  [[ -n "$FL_NET_FAILED" ]] || fl_ok "Internet connectivity available (apt, github.com, pypi.org, npm, nodejs.org, astral.sh)"
  return 0
}

# ------------------------------------------------------------- Windows file system

# fl_bench_windows_fs_reason PATH: why PATH is on the Windows file system under
# WSL (status 0), nothing and status 1 when it is not. A path under /mnt/<drive>
# or on a drvfs or 9p mount; the nearest folder that exists decides for a
# bench that is not there yet.
fl_bench_windows_fs_reason() {
  local path="$1" probe="$1" fstype="" real drive
  fl_is_wsl || return 1
  case "$path" in
    /mnt/[a-zA-Z]|/mnt/[a-zA-Z]/*) drive="${path#/mnt/}"; printf 'it is on the Windows drive %s:' "${drive%%/*}"; return 0 ;;
  esac
  while [[ ! -e "$probe" && "$probe" != "/" && -n "$probe" ]]; do probe="${probe%/*}"; done
  [[ -n "$probe" ]] || probe=/
  real="$(cd "$probe" 2>/dev/null && pwd -P || true)"
  [[ -n "$real" ]] || real="$probe"
  case "$real" in
    /mnt/[a-zA-Z]|/mnt/[a-zA-Z]/*) drive="${real#/mnt/}"; printf 'it resolves to the Windows drive %s:' "${drive%%/*}"; return 0 ;;
  esac
  [[ -r "$FL_PROC_MOUNTS" ]] || return 1
  fstype="$(awk -v p="$real" '{ mp = $2; if (mp == "/" || p == mp || index(p, mp "/") == 1) if (length(mp) >= best) { best = length(mp); t = $3 } } END { print t }' "$FL_PROC_MOUNTS")"
  case "$fstype" in
    drvfs|9p|virtiofs) printf 'it is on a Windows file system mount (%s)' "$fstype"; return 0 ;;
  esac
  return 1
}

# fl_bench_windows_fs_blocker PATH: the line "id|message|fix" for a bench on the
# Windows file system, nothing otherwise or with --allow-windows-fs
fl_bench_windows_fs_blocker() {
  local why
  [[ "$FL_ALLOW_WINDOWS_FS" != "1" ]] || return 0
  why="$(fl_bench_windows_fs_reason "$1")" || return 0
  printf 'bench_on_windows_fs|The bench folder %s is not on the Linux file system: %s. A bench there is very slow, file watching (benchwatch, bench build --watch) does not work and file permissions break.|Use a folder under your Linux home, for example %s/frappe-bench (benchbar install --bench-dir %s/frappe-bench). Only if you accept that, pass --allow-windows-fs\n' "$1" "$why" "$HOME" "$HOME"
}

# ------------------------------------------------------------- blockers and warnings

# fl_install_env_blockers: the lines "id|message|fix" of everything but ports
# that stops an install before sudo and step 1: systemd is not running, the
# bench is on the Windows file system, github.com not answering
fl_install_env_blockers() {
  local id name url blocker
  if ! fl_linux_systemd_booted; then
    printf 'systemd_not_running|systemd is not running, and MariaDB, Redis and the bench service are systemd services here.|%s\n' "$(fl_linux_systemd_fix)"
  fi
  fl_bench_windows_fs_blocker "$FL_BENCH_DIR"
  while IFS='|' read -r id name url blocker; do
    [[ -n "$id" && "$blocker" == "1" ]] || continue
    printf '%s|%s (%s) did not answer within 10 seconds, so the install cannot download from it.|%s\n' "$id" "$name" "$url" "$(fl_net_fix)"
  done <<<"$FL_NET_FAILED"
}

# fl_install_env_warnings: lines "id|message|fix" that the plan shows and the
# run goes on from: the other hosts that did not answer, too little memory and
# too little free space on the Windows drive (WSL)
fl_install_env_warnings() {
  local id name url blocker mem_kb mb kb gb
  while IFS='|' read -r id name url blocker; do
    [[ -n "$id" && "$blocker" == "0" ]] || continue
    printf '%s|%s (%s) did not answer within 10 seconds; the install downloads from it and may fail later.|%s\n' "$id" "$name" "$url" "$(fl_net_fix)"
  done <<<"$FL_NET_FAILED"
  fl_is_wsl || return 0
  mem_kb="$(awk '/^MemTotal:/ { print $2; exit }' "$FL_MEMINFO" 2>/dev/null || true)"
  if [[ "$mem_kb" =~ ^[0-9]+$ ]]; then
    mb=$((mem_kb / 1024))
    if [[ "$mb" -lt "$FL_WSL_MEM_WARN_MB" ]]; then
      printf 'wsl_memory_low|WSL has %s MB of memory; bench build (the asset build) can be killed below about 6 GB.|raise it: memory=8GB under [wsl2] in %%UserProfile%%\\.wslconfig (BenchBar never edits that file), then run wsl.exe --shutdown in Windows\n' "$mb"
    fi
  fi
  if [[ -d "$FL_WIN_DRIVE_DIR" ]]; then
    kb="$(df -Pk "$FL_WIN_DRIVE_DIR" 2>/dev/null | awk 'NR == 2 { print $4 }')"
    if [[ "$kb" =~ ^[0-9]+$ ]]; then
      gb=$((kb / 1024 / 1024))
      if [[ "$gb" -lt "$FL_WSL_DISK_WARN_GB" ]]; then
        printf 'wsl_disk_low|The Windows drive that holds this distro has %s GB free; a bench with its database, node_modules and builds needs about %s GB.|free space on that drive (Windows Settings, Storage), or move the distro to a bigger drive\n' "$gb" "$FL_WSL_DISK_WARN_GB"
      fi
    fi
  fi
}
