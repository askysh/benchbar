#!/usr/bin/env bash
#
# process.sh: find and stop only this bench's background processes.
#
# Matched (and nothing else):
#   honcho start -f Procfile.lean        whose working folder is this bench
#   <bench>/env/bin/python -m frappe.utils.bench_helper frappe (serve|worker|schedule)
#   apps/frappe/socketio.js              whose working folder is this bench
#   listeners on the bench's web, socketio and redis ports
# A user's own "bench migrate" or "bench console" never matches, and neither
# does another bench's honcho or socketio: both are started with a relative
# path, so their command lines are the same in every bench and only the
# working folder tells them apart.

# A backslash before every ERE special character, in bash: the same text
# `sed 's/[][\.*^$+?(){}|\\]/\\&/g'` gives (the rendered runner embeds it, so
# a different byte would mark every runner outdated), without a process.
fl_regex_escape() {
  local s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      '['|']'|\\|'.'|'*'|'^'|'$'|'+'|'?'|'('|')'|'{'|'}'|'|') out="${out}\\${c}" ;;
      *) out="${out}${c}" ;;
    esac
  done
  printf '%s' "$out"
}

fl_bench_helper_pattern() {
  printf '^%s/env/bin/python -m frappe\\.utils\\.bench_helper frappe (serve|worker|schedule)' "$(fl_regex_escape "$FL_BENCH_DIR")"
}

# The working folder of a process, from lsof; nothing when it cannot be read.
fl_pid_cwd() {
  lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n1
}

# Reads pids on stdin, prints the ones running in this bench. A pid whose
# folder cannot be read (it just exited) is kept: that is the pre 0.4
# behaviour, and stopping an exiting process costs nothing.
fl_pids_in_bench() {
  local pid cwd
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    cwd="$(fl_pid_cwd "$pid")"
    [[ -z "$cwd" || "$cwd" == "$FL_BENCH_DIR" ]] && printf '%s\n' "$pid"
  done
  return 0
}

fl_bench_honcho_pids() {
  { pgrep -f "honcho start -f Procfile\\.lean" 2>/dev/null || true; } | fl_pids_in_bench
}

fl_bench_socketio_pids() {
  { pgrep -f "apps/frappe/socketio\\.js" 2>/dev/null || true; } | fl_pids_in_bench
}

# Listeners on the bench's ports that run inside the bench folder (redis,
# web and socketio start there). A listener elsewhere on the same port, such
# as another bench or an unrelated server, is never this bench's to stop, and
# neither is one whose folder cannot be read: stopping needs proof.
fl_bench_listener_pids() {
  local pid
  { lsof -ti "tcp:$(fl_bench_ports_csv)" -sTCP:LISTEN 2>/dev/null || true; } | while IFS= read -r pid; do
    [[ -n "$pid" ]] && fl_pid_is_bench_own_strict "$pid" && printf '%s\n' "$pid"
  done
  return 0
}

fl_bench_process_pids() {
  {
    fl_bench_honcho_pids
    pgrep -f "$(fl_bench_helper_pattern)" 2>/dev/null || true
    fl_bench_socketio_pids
    fl_bench_listener_pids
  } | sort -u
}

fl_bench_is_running() {
  [[ -n "$(fl_bench_process_pids)" ]]
}

# fl_bench_status_pids: this bench's honcho, then its serve, worker,
# schedule and socketio pids, one per line, from one pgrep and at most one
# lsof for the folders of them all. status uses it only when state.json
# cannot say; down and the port checks keep the full scan above, listeners
# included. No pattern carries the bench's path: a Homebrew Python
# re-executes itself, so serve's command line starts with the framework's
# interpreter, not <bench>/env/bin/python. The folder decides instead:
# honcho and socketio run in the bench, serve and the workers in its sites/.
fl_bench_status_pids() {
  local found line pid cmd all="" honcho=" " drop=" " cwds="" cur="" first="" rest=""
  found="$(pgrep -lf 'honcho start -f Procfile\.lean|-m frappe\.utils\.bench_helper frappe (serve|worker|schedule)|apps/frappe/socketio\.js' 2>/dev/null)" || return 0
  while IFS= read -r line; do
    pid="${line%% *}"; cmd="${line#* }"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    all="${all:+${all},}${pid}"
    [[ "$cmd" == *"honcho start -f Procfile.lean"* ]] && honcho="${honcho}${pid} "
  done <<<"$found"
  [[ -n "$all" ]] || return 0
  # a pid lsof cannot answer for (it just exited) is kept, as fl_pids_in_bench does
  cwds="$(lsof -a -d cwd -Fn -p "$all" 2>/dev/null || true)"
  while IFS= read -r line; do
    case "$line" in
      p*) cur="${line#p}" ;;
      n*)
        case "${line#n}" in
          "$FL_BENCH_DIR"|"$FL_BENCH_DIR"/*) ;;
          *) [[ -n "$cur" ]] && drop="${drop}${cur} " ;;
        esac ;;
    esac
  done <<<"$cwds"
  # honcho first: status falls back to the first pid, and the app samples
  # CPU and memory from it down
  for pid in ${all//,/ }; do
    case "$drop" in *" $pid "*) continue ;; esac
    case "$honcho" in *" $pid "*) first="${first}${pid}"$'\n' ;; *) rest="${rest}${pid}"$'\n' ;; esac
  done
  printf '%s%s' "$first" "$rest"
}

# fl_bench_kill_processes [SIGNAL]
fl_bench_kill_processes() {
  local sig="${1:-TERM}" pids
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would stop this bench's honcho, serve, worker, socketio and port listeners"
    return 0
  fi
  pkill "-${sig}" -f "$(fl_bench_helper_pattern)" 2>/dev/null || true
  pids="$(fl_bench_honcho_pids; fl_bench_socketio_pids; fl_bench_listener_pids)"
  if [[ -n "$pids" ]]; then
    # shellcheck disable=SC2086
    "${FL_KILL_CMD:-kill}" "-${sig}" $pids 2>/dev/null || true
  fi
  fl_log "sent SIG${sig} to bench processes"
}

# Waits up to N seconds for the bench processes to go away.
fl_bench_wait_stopped() {
  local secs="${1:-10}" i=0
  while [[ "$i" -lt "$secs" ]]; do
    fl_bench_is_running || return 0
    sleep 1
    i=$((i + 1))
  done
  fl_bench_is_running && return 1
  return 0
}

fl_port_listener_pid() {
  lsof -ti "tcp:$1" -sTCP:LISTEN 2>/dev/null | head -n1 || true
}

fl_port_listener_summary() {
  # prints "pid command" for the first listener on a port, or nothing
  lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk 'NR == 2 {print $2 " " $1}' || true
}

fl_port_listen_addresses() {
  # prints the local address:port of every listener on a port, one per line
  lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 {print $9}' | sort -u || true
}
