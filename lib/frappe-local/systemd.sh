#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# systemd.sh: the Linux backend of the agent layer. It redefines, with the
# same names, the functions launchd.sh and benchinfo.sh define for macOS, so
# no caller branches: one systemd --user unit per bench,
# benchbar-<bench name>.service, in ${XDG_CONFIG_HOME:-~/.config}/systemd/user.
# fl_platform_load sources this file after every other library when the
# platform is linux. "label" here is the unit name without .service, and a
# "target" is the unit name.
#
# Mapping of what the callers read (launchd.sh): the job is "loaded" when
# systemd has read its unit file; ActiveState active is state "running";
# MainPID is the runner's pid; ExecMainStatus is the last exit code.

FL_AGENT_MANAGER="systemd"
FL_AGENT_CTL="systemctl"
FL_AGENT_CTL_START="systemctl --user start"
FL_AGENT_CTL_RESTART="systemctl --user restart"
# units moved aside by uninstall-service go here: a folder systemd never scans
if [[ -z "${FL_LEGACY_DIR:-}" || "$FL_LEGACY_DIR" == "$HOME/Library/LaunchAgents-disabled" ]]; then
  FL_LEGACY_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user-disabled"
fi

# ------------------------------------------------------------- names and paths

fl_unit_dir() { printf '%s/systemd/user' "${XDG_CONFIG_HOME:-$HOME/.config}"; }

# fl_unit_name TARGET: the unit name of a target, a label or a "/label" (what
# the macOS callers build with the empty launchd domain)
fl_unit_name() {
  local t="${1##*/}"
  case "$t" in *.service) ;; *) t="${t}.service" ;; esac
  printf '%s' "$t"
}

fl_launchd_domain() { :; }

fl_agent_label_legacy() { :; }

fl_agent_plist_path() {
  printf '%s/%s.service' "$(fl_unit_dir)" "$(fl_agent_label)"
}

# fl_agent_file_v VAR LABEL: the unit file of a label
fl_agent_file_v() { printf -v "$1" '%s/%s.service' "$(fl_unit_dir)" "$2"; }

# The unit name of this bench, like the macOS label with benchbar- for
# com.benchbar. and the same rules: an installed name stays stable, another
# bench's unit is never claimed, a second bench of the same name gets the
# path hash.
fl_agent_label_compute() {
  local base="benchbar-${FL_BENCH_NAME}" hash hashed f owner d name dir
  dir="$(fl_unit_dir)"
  if [[ "$FL_BENCH_HASH_DIR" == "$FL_BENCH_DIR" && -n "$FL_BENCH_HASH" ]]; then hash="$FL_BENCH_HASH"; else fl_path_hash_v hash "$FL_BENCH_DIR"; fi
  hashed="${base}-${hash}"
  for f in "$hashed" "$base"; do
    if [[ -f "${dir}/${f}.service" ]]; then
      owner="$(fl_plist_working_dir "${dir}/${f}.service")"
      if fl_same_path "$owner" "$FL_BENCH_DIR"; then printf '%s' "$f"; return 0; fi
    fi
  done
  if [[ -f "${dir}/${base}.service" ]]; then printf '%s' "$hashed"; return 0; fi
  while IFS= read -r d; do
    [[ -n "$d" && "$d" != "$FL_BENCH_DIR" ]] || continue
    fl_bench_name_v name "$d"
    if [[ "$name" == "$FL_BENCH_NAME" ]]; then printf '%s' "$hashed"; return 0; fi
  done <<<"$(fl_known_benches_cached)"
  printf '%s' "$base"
}

# fl_agent_files [all]: the unit files of every benchbar bench, one path per
# line (the macOS version also lists the frappe-mac plists for "all")
fl_agent_files() {
  local f
  for f in "$(fl_unit_dir)"/benchbar-*.service; do
    [[ -f "$f" ]] && printf '%s\n' "$f"
  done
  return 0
}

# ------------------------------------------------------------- path

# The PATH of the unit: the toolchain this CLI installed (fnm's Node, uv's
# Python), then the user's and the system's.
fl_launchd_path_value() {
  local p="" d
  if declare -F fl_node_bin >/dev/null; then
    d="$(fl_node_bin 2>/dev/null || true)"
    [[ -n "$d" ]] && p="${d%/*}:"
  fi
  if declare -F fl_python_bin >/dev/null; then
    d="$(fl_python_bin 2>/dev/null || true)"
    [[ -n "$d" ]] && p="${p}${d%/*}:"
  fi
  p="${p}${HOME}/.local/bin:${FL_LAUNCHD_PATH_SYSTEM:-/usr/local/bin:/usr/bin:/bin}"
  printf '%s' "$p"
}

# ------------------------------------------------------------- state

# fl_unit_show UNIT: sets U_LOAD, U_ACTIVE, U_PID and U_EXIT from one
# "systemctl show" (empty when systemd does not answer)
U_LOAD=""; U_ACTIVE=""; U_PID=""; U_EXIT=""
fl_unit_show() {
  local out line
  U_LOAD=""; U_ACTIVE=""; U_PID=""; U_EXIT=""
  out="$(systemctl --user show -p LoadState,ActiveState,MainPID,ExecMainStatus "$1" 2>/dev/null)" || return 0
  while IFS= read -r line; do
    case "$line" in
      LoadState=*) U_LOAD="${line#LoadState=}" ;;
      ActiveState=*) U_ACTIVE="${line#ActiveState=}" ;;
      MainPID=*) U_PID="${line#MainPID=}" ;;
      ExecMainStatus=*) U_EXIT="${line#ExecMainStatus=}" ;;
    esac
  done <<<"$out"
  [[ "$U_PID" == "0" ]] && U_PID=""
  return 0
}

# the launchd words the callers compare with: running, waiting (between
# restarts), stopping, not running
fl_unit_state_word() {
  case "$1" in
    active|reloading) printf 'running' ;;
    activating) printf 'waiting' ;;
    deactivating) printf 'stopping' ;;
    *) printf 'not running' ;;
  esac
}

fl_agent_target() { fl_unit_name "$(fl_agent_label)"; }

fl_agent_loaded() {
  [[ "$(systemctl --user show -p LoadState --value "$(fl_unit_name "${1:-$(fl_agent_target)}")" 2>/dev/null)" == "loaded" ]]
}

# fl_agent_listed TARGET: systemd knows the unit
fl_agent_listed() { fl_agent_loaded "$1"; }

# fl_agent_read [TARGET]: sets AG_LOADED, AG_STATE, AG_PID and AG_EXIT, the
# same globals as on macOS, from one "systemctl show".
AG_LOADED=0; AG_STATE=""; AG_PID=""; AG_EXIT=""
fl_agent_read() {
  local target="${1:-}"
  [[ -n "$target" ]] || target="$(fl_agent_target)"
  AG_LOADED=0; AG_STATE=""; AG_PID=""; AG_EXIT=""
  fl_unit_show "$(fl_unit_name "$target")"
  [[ "$U_LOAD" == "loaded" ]] || return 0
  AG_LOADED=1
  AG_STATE="$(fl_unit_state_word "$U_ACTIVE")"
  AG_PID="$U_PID"
  AG_EXIT="$U_EXIT"
  return 0
}

# fl_agent_field FIELD [TARGET]: "state", "pid" or "last exit code"; nothing
# when the unit is not loaded
fl_agent_field() {
  local field="$1" target="${2:-$(fl_agent_target)}"
  fl_agent_read "$target"
  [[ "$AG_LOADED" == "1" ]] || return 0
  case "$field" in
    state) printf '%s\n' "$AG_STATE" ;;
    pid) [[ -z "$AG_PID" ]] || printf '%s\n' "$AG_PID" ;;
    "last exit code") [[ -z "$AG_EXIT" ]] || printf '%s\n' "$AG_EXIT" ;;
  esac
  return 0
}

# the unit is masked: systemd refuses to start it (launchd's disabled list)
fl_agent_disabled() {
  [[ "$(systemctl --user show -p UnitFileState --value "$(fl_unit_name "$1")" 2>/dev/null)" == "masked" ]]
}

# ------------------------------------------------------------- control

# The unit asks for autostart when its file says so (RunAtLoad on the Mac).
fl_unit_autostart() { grep -q -x '# benchbar-autostart: true' "$1" 2>/dev/null; }

# Makes systemd read the unit file. Writes nothing itself. With autostart on
# the unit is enabled (WantedBy=default.target) and started, as RunAtLoad
# starts a bootstrapped agent; with it off the unit is not enabled and not
# started.
fl_agent_bootstrap() {
  local file="$1" unit
  unit="$(basename "$file" .service).service"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: systemctl --user daemon-reload, enable and start ${unit}"
    return 0
  fi
  fl_log "systemctl --user daemon-reload"
  systemctl --user daemon-reload 2>/dev/null || { fl_log "systemctl --user daemon-reload failed"; return 1; }
  if fl_unit_autostart "$file"; then
    fl_log "systemctl --user enable ${unit}"
    systemctl --user enable "$unit" >/dev/null 2>&1 || { fl_log "systemctl --user enable ${unit} failed"; return 1; }
    fl_log "systemctl --user start ${unit}"
    # a refused start job (masked unit, start limit) is a failed load, not a
    # loaded agent: the caller reports it instead of "agent loaded"
    systemctl --user start "$unit" >/dev/null 2>&1 || { fl_log "systemctl --user start ${unit} failed"; return 1; }
  else
    fl_log "systemctl --user disable ${unit}"
    systemctl --user disable "$unit" >/dev/null 2>&1 || true
  fi
  if ! fl_agent_loaded "$unit"; then
    fl_log "systemd does not list ${unit} after daemon-reload"
    return 1
  fi
  return 0
}

# systemd forgets a unit file that is gone only at the next daemon-reload
fl_agent_files_changed() {
  [[ "${FL_DRY_RUN:-0}" == "1" ]] && return 0
  systemctl --user daemon-reload 2>/dev/null || true
}

# Waits until the unit no longer runs (stop returns once the runner has
# exited, but a stop that was only asked for may still be going), up to
# FL_BOOTOUT_WAIT_SECS.
FL_BOOTOUT_WAIT_SECS="${FL_BOOTOUT_WAIT_SECS:-30}"
fl_agent_wait_gone() {
  local unit i=0 limit=$((FL_BOOTOUT_WAIT_SECS * 4))
  unit="$(fl_unit_name "$1")"
  while :; do
    fl_unit_show "$unit"
    case "$U_ACTIVE" in active|activating|deactivating|reloading) ;; *) break ;; esac
    if [[ "$i" -ge "$limit" ]]; then
      fl_warn "systemd still runs ${unit} after ${FL_BOOTOUT_WAIT_SECS} s"
      return 1
    fi
    sleep 0.25
    i=$((i + 1))
  done
  [[ "$i" == "0" ]] || fl_log "${unit} stopped after $((i / 4)) s"
  return 0
}

# Stops the unit and takes it out of the autostart set. The file stays.
fl_agent_bootout() {
  local unit
  unit="$(fl_unit_name "${1:-$(fl_agent_target)}")"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: systemctl --user disable --now ${unit}"
    return 0
  fi
  fl_log "systemctl --user disable --now ${unit}"
  systemctl --user disable --now "$unit" >/dev/null 2>&1 || systemctl --user stop "$unit" >/dev/null 2>&1 || true
  fl_agent_wait_gone "$unit"
}

# fl_agent_unload TARGET FILE: like fl_agent_bootout, for a unit that is not
# this bench's (the orphan removal); the unit file is FILE
fl_agent_unload() {
  fl_agent_bootout "$1"
}

# start, or restart for -k (launchd's kickstart -k kills a running job)
fl_agent_kickstart() {
  local kill_flag="${1:-}" verb=start unit
  unit="$(fl_agent_target)"
  [[ -n "$kill_flag" ]] && verb=restart
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: systemctl --user ${verb} ${unit}"
    return 0
  fi
  fl_log "systemctl --user ${verb} ${unit}"
  systemctl --user "$verb" "$unit"
}

# what launchctl kill signals: the job's main process, the runner
fl_agent_signal() {
  local sig="${1:-SIGTERM}" unit
  unit="$(fl_agent_target)"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: systemctl --user kill -s ${sig} --kill-whom=main ${unit}"
    return 0
  fi
  fl_log "systemctl --user kill -s ${sig} --kill-whom=main ${unit}"
  systemctl --user kill -s "$sig" --kill-whom=main "$unit" 2>/dev/null || true
}

# The command that loads a unit by hand, for the fix lines of doctor
fl_agent_load_hint() {
  printf 'systemctl --user daemon-reload && systemctl --user enable --now %s' "$(basename "$1" .service).service"
}
fl_agent_bootout_hint() { printf 'systemctl --user disable --now %s' "$(fl_unit_name "$1")"; }
fl_agent_list_hint() { printf 'ls ~/.config/systemd/user/benchbar-*.service'; }

# A bench started with autostart on should come back after a reboot, which
# a user manager only does for a user whose services may run without a login.
fl_linger_ensure() {
  local user="${USER:-${LOGNAME:-}}" now
  [[ -n "$user" ]] || return 0
  now="$(loginctl show-user "$user" -p Linger --value 2>/dev/null || true)"
  [[ "$now" == "yes" ]] && return 0
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: loginctl enable-linger ${user}"
    return 0
  fi
  fl_log "loginctl enable-linger ${user}"
  # --no-ask-password: polkit may want an admin password outside an active
  # session; that is the sudo fix below, never a prompt in the middle of up
  if loginctl --no-ask-password enable-linger "$user" >/dev/null 2>&1; then
    fl_info "lingering is on for ${user}: the bench can come back after a reboot, before you log in"
  else
    fl_warn "could not turn on lingering; the bench returns after a reboot only once you log in"
    fl_fix "sudo loginctl enable-linger ${user}"
  fi
  return 0
}

# ------------------------------------------------------------- unit files

# The label of a unit: the benchbar-label comment, else Description's name.
fl_plist_label() {
  local label
  label="$(sed -n 's/^# benchbar-label: *//p' "$1" 2>/dev/null | head -n1)"
  [[ -n "$label" ]] || label="$(sed -n 's/^Description=BenchBar bench //p' "$1" 2>/dev/null | head -n1)"
  [[ -n "$label" ]] || return 0
  printf '%s\n' "$label"
}

# a % in a unit file is a specifier; the renderer writes it doubled
fl_unit_unescape_v() {
  local __s="$2" __pp='%%' __p='%'
  __s="${__s//"$__pp"/$__p}"
  printf -v "$1" '%s' "$__s"
}

fl_plist_working_dir() {
  local line l=""
  [[ -f "$1" && -r "$1" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in WorkingDirectory=*) l="${line#WorkingDirectory=}"; break ;; esac
  done <"$1"
  [[ -n "$l" ]] || return 0
  fl_unit_unescape_v l "$l"
  printf '%s\n' "$l"
}

# fl_plist_runner UNIT: the script ExecStart runs (the argument after /bin/bash)
fl_plist_runner() {
  local line l=""
  [[ -f "$1" && -r "$1" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in ExecStart=*) l="${line#ExecStart=}"; break ;; esac
  done <"$1"
  [[ -n "$l" ]] || return 0
  l="${l#/bin/bash }"
  l="${l#\"}"; l="${l%\"}"
  fl_unit_unescape_v l "$l"
  printf '%s\n' "$l"
}

# benchbar units whose WorkingDirectory is DIR, even when DIR is no longer a
# bench: "unit|label" lines.
fl_agents_for_dir() {
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    fl_same_path "$(fl_plist_working_dir "$f")" "$1" || continue
    printf '%s|%s\n' "$f" "$(basename "$f" .service)"
  done < <(fl_agent_files)
}

# Running or restarting benchbar units whose runner script is gone: they
# start every 20 seconds, exit 127 and fill bench.log. "unit|label|dir".
fl_dead_agents_list() {
  local f label runner
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    runner="$(fl_plist_runner "$f")"
    [[ -n "$runner" && ! -f "$runner" ]] || continue
    label="$(basename "$f" .service)"
    fl_unit_show "$label.service"
    case "$U_ACTIVE" in active|activating|reloading) ;; *) continue ;; esac
    printf '%s|%s|%s\n' "$f" "$label" "$(fl_plist_working_dir "$f")"
  done < <(fl_agent_files)
}

# There are no agents from before the BenchBar rename on Linux.
fl_legacy_agents_list() { :; }
fl_legacy_agent_migrate() { return 0; }

# ------------------------------------------------------------- rendering

# fl_unit_escape_v VAR TEXT: TEXT with % doubled, as a unit file needs it
fl_unit_escape_v() {
  local __s="$2" __pp='%%' __p='%'
  __s="${__s//"$__p"/$__pp}"
  printf -v "$1" '%s' "$__s"
}

# fl_render_agent RUN_AT_LOAD: FL_R_PLIST gets the unit instead of the plist
fl_render_agent() {
  local run_at_load="$1" bench runner log path
  fl_unit_escape_v bench "$FL_BENCH_DIR"
  fl_unit_escape_v runner "$(fl_runner_path)"
  fl_unit_escape_v log "$(fl_bench_log_path)"
  fl_unit_escape_v path "$(fl_launchd_path_value)"
  FL_R_PLIST="$(fl_template_render systemd-user.service \
    "LABEL=$(fl_agent_label)" \
    "BENCH_NAME=${FL_BENCH_NAME}" \
    "RUNNER=${runner}" \
    "BENCH_DIR=${bench}" \
    "PATH=${path}" \
    "RUN_AT_LOAD=${run_at_load}" \
    "LOG=${log}")"
}

# The runner's per platform lines (templates/bench-run.sh.tmpl): no
# notification, and /proc and ss where the Mac uses lsof.
FL_RUNNER_EXTRA=()
# shellcheck disable=SC2016  # the runner expands $1 and $PORTS, not this file
fl_runner_extra_args() {
  FL_RUNNER_EXTRA=(
    "NOTIFY_BODY=:"
    'CWD_OF=readlink "/proc/$1/cwd" 2>/dev/null'
    'LISTENER_PIDS=ss -Hltnp 2>/dev/null | awk -v p=",$PORTS," '"'"'{ n = split($4, a, ":"); if (index(p, "," a[n] ",") && match($0, /pid=[0-9]+/)) print substr($0, RSTART + 4, RLENGTH - 4) }'"'"' | sort -u'
  )
}
