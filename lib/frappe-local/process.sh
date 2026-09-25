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

fl_regex_escape() {
  printf '%s' "$1" | sed -e 's/[][\.*^$+?(){}|\\]/\\&/g'
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

fl_bench_listener_pids() {
  lsof -ti "tcp:$(fl_bench_ports_csv)" -sTCP:LISTEN 2>/dev/null || true
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
