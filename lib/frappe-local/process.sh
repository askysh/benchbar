#!/usr/bin/env bash
#
# process.sh: find and stop only this bench's background processes.
#
# Matched (and nothing else):
#   honcho start -f Procfile.lean        whose working folder is this bench
#   -m frappe.utils.bench_helper frappe (serve|worker|schedule)
#                                        whose working folder is this bench
#   apps/frappe/socketio.js              whose working folder is this bench
#   listeners on the bench's web, socketio and redis ports
# A user's own "bench migrate" or "bench console" never matches, and neither
# does another bench's honcho, socketio, serve or worker: their command lines
# are the same in every bench, so only the working folder tells them apart.
# The command line never carries the bench or the interpreter path: a
# Homebrew Python re-executes itself, so it shows the framework's Python
# (/opt/homebrew/Cellar/python@3.11/.../Python.app/Contents/MacOS/Python),
# and under uv on Linux it is the venv's python or uv's own interpreter.
# The one pattern is fl_bench_helper_pattern; the runner template carries
# the same text (tests/test-process-match.sh keeps them equal).

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

# The command line of serve, worker and schedule, as an ERE for pgrep -f. It
# matches every bench and every interpreter; the working folder
# (fl_pids_in_bench) says whose it is. The leading space keeps pgrep from
# reading the pattern as its own -m option.
fl_bench_helper_pattern() {
  printf '%s' ' -m frappe\.utils\.bench_helper frappe (serve|worker|schedule)( |$)'
}

# The working folder of a process, from lsof; nothing when it cannot be read.
# In a doctor run (facts.sh) one lsof per pid, read in bash.
fl_pid_cwd() {
  local out line
  if [[ -n "${FL_FACTS_DIR:-}" ]]; then
    fl_memo_v out "cwd:${1}" lsof -a -p "$1" -d cwd -Fn || true
    while IFS= read -r line; do
      [[ "$line" == n* ]] && { printf '%s\n' "${line#n}"; return 0; }
    done <<<"$out"
    return 0
  fi
  lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | awk 'NR==1'
}

# fl_pgrep_f PATTERN: pgrep -f, once per pattern in a doctor run
fl_pgrep_f() {
  if [[ -n "${FL_FACTS_DIR:-}" ]]; then fl_memo "pgrep:${1}" pgrep -f "$1" || true; else pgrep -f "$1" 2>/dev/null || true; fi
}

# fl_pid_is_bench_own_strict PID: the one ownership test. True only when
# lsof reports the process's working folder as this bench or a folder inside
# it. A folder that cannot be read proves nothing: the process may have just
# exited (then there is nothing to stop) or belong to someone else (then it
# is not ours to stop). Every kill in benchbar and the runner goes through
# this test, and nothing is ever killed by pattern alone.
fl_pid_is_bench_own_strict() {
  local cwd
  cwd="$(fl_pid_cwd "$1")"
  [[ -n "$cwd" ]] && [[ "$cwd" == "$FL_BENCH_DIR" || "$cwd" == "$FL_BENCH_DIR"/* ]]
}

# Reads pids on stdin, prints the ones that provably run in this bench
# (fl_pid_is_bench_own_strict). A pid whose folder cannot be read is left
# out, so down never signals another bench's honcho or socketio.
fl_pids_in_bench() {
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    fl_pid_is_bench_own_strict "$pid" && printf '%s\n' "$pid"
  done
  return 0
}

fl_bench_honcho_pids() {
  fl_pgrep_f "honcho start -f Procfile\\.lean" | fl_pids_in_bench
}

fl_bench_socketio_pids() {
  fl_pgrep_f "apps/frappe/socketio\\.js" | fl_pids_in_bench
}

# This bench's serve, worker and schedule pids: the command line says what
# they are, the working folder (<bench>/sites) whose they are.
fl_bench_helper_pids() {
  fl_pgrep_f "$(fl_bench_helper_pattern)" | fl_pids_in_bench
}

# Listeners on the bench's ports that run inside the bench folder (redis,
# web and socketio start there). A listener elsewhere on the same port, such
# as another bench or an unrelated server, is never this bench's to stop, and
# neither is one whose folder cannot be read: stopping needs proof.
fl_bench_listener_pids() {
  local pid
  { fl_listener_pids_of "${1:-$(fl_bench_ports_csv)}"; } | while IFS= read -r pid; do
    [[ -n "$pid" ]] && fl_pid_is_bench_own_strict "$pid" && printf '%s\n' "$pid"
  done
  return 0
}

fl_bench_process_pids() {
  {
    fl_bench_honcho_pids
    fl_bench_helper_pids
    fl_bench_socketio_pids
    fl_bench_listener_pids
  } | sort -u
}

fl_bench_is_running() {
  [[ -n "$(fl_bench_process_pids)" ]]
}

# fl_bench_is_serving: something that serves the site is alive: honcho, serve,
# worker, schedule, socketio or a listener on the web or socketio port. The
# bench's Redis alone (up --services-only, a leftover setup Redis) is not a
# bench that should answer a ping; fl_bench_is_running still counts it, for
# down and the waits that must see it gone.
fl_bench_is_serving() {
  [[ -n "$(fl_bench_honcho_pids)" || -n "$(fl_bench_socketio_pids)" ]] && return 0
  [[ -n "$(fl_bench_helper_pids)" ]] && return 0
  [[ -n "$(fl_bench_listener_pids "${FL_WEB_PORT},${FL_SOCKETIO_PORT}")" ]]
}

# honcho on any Procfile whose working folder is this bench: benchfg and the
# agent run Procfile.lean, "bench start" runs the bench's own Procfile
fl_bench_any_honcho_pids() {
  fl_pgrep_f "honcho start" | fl_pids_in_bench
}

# fl_bench_running_outside_benchbar: the bench's honcho, serve, worker,
# schedule or socketio is alive (a listener alone, such as a leftover setup
# Redis, is not a session) and this bench's agent is not the one running
# them (bench start, benchfg, a hand-run honcho). That is a person's
# terminal session: nothing of benchbar may stop or restart it.
fl_bench_running_outside_benchbar() {
  [[ -n "$(fl_bench_any_honcho_pids)" || -n "$(fl_bench_socketio_pids)" || -n "$(fl_bench_helper_pids)" ]] || return 1
  [[ "$(fl_agent_field state 2>/dev/null)" != "running" ]]
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
  local found line pid cmd all="" honcho=" " keep=" " cwds="" cur="" first="" rest=""
  found="$(pgrep -lf "honcho start -f Procfile\\.lean|$(fl_bench_helper_pattern)|apps/frappe/socketio\\.js" 2>/dev/null)" || return 0
  while IFS= read -r line; do
    pid="${line%% *}"; cmd="${line#* }"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    all="${all:+${all},}${pid}"
    [[ "$cmd" == *"honcho start -f Procfile.lean"* ]] && honcho="${honcho}${pid} "
  done <<<"$found"
  [[ -n "$all" ]] || return 0
  # only a pid whose folder lsof reports inside the bench counts: the one
  # pgrep sees every bench's processes, and one that exited before lsof (or
  # whose folder cannot be read) proves nothing. status only reads; down and
  # the port checks keep their own scan.
  cwds="$(lsof -a -d cwd -Fn -p "$all" 2>/dev/null || true)"
  while IFS= read -r line; do
    case "$line" in
      p*) cur="${line#p}" ;;
      n*)
        case "${line#n}" in
          "$FL_BENCH_DIR"|"$FL_BENCH_DIR"/*) if [[ -n "$cur" ]]; then keep="${keep}${cur} "; fi ;;
        esac ;;
    esac
  done <<<"$cwds"
  # honcho first: status falls back to the first pid, and the app samples
  # CPU and memory from it down
  for pid in ${all//,/ }; do
    case "$keep" in *" $pid "*) ;; *) continue ;; esac
    case "$honcho" in *" $pid "*) first="${first}${pid}"$'\n' ;; *) rest="${rest}${pid}"$'\n' ;; esac
  done
  printf '%s%s' "$first" "$rest"
}

# fl_bench_kill_processes [SIGNAL]
fl_bench_kill_processes() {
  local sig="${1:-TERM}" pids killer=kill
  [[ "${FL_TESTING:-}" == "1" ]] && killer="${FL_KILL_CMD:-kill}"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would stop this bench's honcho, serve, worker, socketio and port listeners"
    return 0
  fi
  pids="$(fl_bench_honcho_pids; fl_bench_helper_pids; fl_bench_socketio_pids; fl_bench_listener_pids)"
  if [[ -n "$pids" ]]; then
    # shellcheck disable=SC2086
    "$killer" "-${sig}" $pids 2>/dev/null || true
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

# The listeners of a doctor run: one "lsof -nP -iTCP -sTCP:LISTEN" for every
# port (facts.sh keeps it), filtered here. fl__listen_rows PORTS prints "port
# pid command address" for each listening socket on one of the comma
# separated PORTS, in lsof's order; the address ends with ":port".
fl__listen_rows() {
  local snap line cmd pid user fd type dev size node name rest port
  fl_memo_v snap listeners lsof -nP -iTCP -sTCP:LISTEN || true
  while IFS= read -r line; do
    [[ -n "$line" && "$line" != COMMAND* ]] || continue
    read -r cmd pid user fd type dev size node name rest <<<"$line"
    port="${name##*:}"
    case ",${1}," in *",${port},"*) printf '%s %s %s %s\n' "$port" "$pid" "$cmd" "$name" ;; esac
  done <<<"$snap"
}

# fl_listener_pids_of PORTS: the pid of every listener on the comma separated
# PORTS, once each, one per line (lsof -ti)
fl_listener_pids_of() {
  local port pid cmd addr seen=" "
  if [[ -z "${FL_FACTS_DIR:-}" ]]; then lsof -ti "tcp:$1" -sTCP:LISTEN 2>/dev/null || true; return 0; fi
  while read -r port pid cmd addr; do
    case "$seen" in *" $pid "*) continue ;; esac
    seen="${seen}${pid} "
    printf '%s\n' "$pid"
  done < <(fl__listen_rows "$1")
}

fl_port_listener_pid() {
  local port pid cmd addr
  if [[ -n "${FL_FACTS_DIR:-}" ]]; then
    while read -r port pid cmd addr; do printf '%s\n' "$pid"; return 0; done < <(fl__listen_rows "$1")
    return 0
  fi
  lsof -ti "tcp:$1" -sTCP:LISTEN 2>/dev/null | awk 'NR==1' || true
}

# fl_port_listener_pids PORT: the pid of every listener on PORT, one per line
fl_port_listener_pids() {
  fl_listener_pids_of "$1"
}

fl_port_listener_summary() {
  # prints "pid command" for the first listener on a port, or nothing
  local port pid cmd addr
  if [[ -n "${FL_FACTS_DIR:-}" ]]; then
    while read -r port pid cmd addr; do printf '%s %s\n' "$pid" "$cmd"; return 0; done < <(fl__listen_rows "$1")
    return 0
  fi
  lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk 'NR == 2 {print $2 " " $1}' || true
}

fl_port_listen_addresses() {
  # prints the local address:port of every listener on a port, one per line
  local port pid cmd addr out="" n=0
  if [[ -n "${FL_FACTS_DIR:-}" ]]; then
    while read -r port pid cmd addr; do
      [[ $'\n'"$out" == *$'\n'"$addr"$'\n'* ]] && continue
      out="${out}${addr}"$'\n'; n=$((n + 1))
    done < <(fl__listen_rows "$1")
    # one address needs no sort; several keep the order sort -u gives
    if [[ "$n" -le 1 ]]; then printf '%s' "$out"; else printf '%s' "$out" | sort -u; fi
    return 0
  fi
  lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 {print $9}' | sort -u || true
}

# fl_tcp_open PORT: true when something accepts a connection on 127.0.0.1.
# Bash's own /dev/tcp, so the status path starts no program for it (the app
# polls status for every bench on a timer). FL_LOCAL_PROBES=0 turns both
# probes off (the tests, which must never talk to a service of the machine
# they run on); a production run (no FL_TESTING=1) ignores it.
fl_local_probes_off() { [[ "${FL_TESTING:-}" == "1" && "${FL_LOCAL_PROBES:-1}" != "1" ]]; }
fl_tcp_open() {
  ! fl_local_probes_off || return 1
  ( exec 9<>"/dev/tcp/127.0.0.1/$1" ) 2>/dev/null
}

# fl_http_code_v VAR HOST PORT PATH SECS: the status code of one GET of PATH
# on 127.0.0.1:PORT with HOST as the Host header, empty when nothing answered
# within SECS seconds. Bash alone, like fl_tcp_open: no curl, no program.
fl_http_code_v() {
  local __line=""
  if fl_local_probes_off; then printf -v "$1" '%s' ""; return 0; fi
  __line="$(
    {
      exec 9<>"/dev/tcp/127.0.0.1/$3" || exit 0
      printf 'GET %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n' "$4" "$2" >&9
      IFS= read -r -t "$5" __first <&9 && printf '%s' "$__first"
    } 2>/dev/null
  )" || true
  if [[ "$__line" =~ ^HTTP/[0-9.]+[[:space:]]+([0-9][0-9][0-9]) ]]; then printf -v "$1" '%s' "${BASH_REMATCH[1]}"; else printf -v "$1" '%s' ""; fi
}
