#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# benchstate.sh: the versioned JSON contract used by the BenchBar app.
#
#   benchbar list --json      every known bench
#   benchbar status --json    one bench: state, pid, ping, uptime
#   <bench>/logs/.benchbar/state.json
#                             written atomically on every transition by the
#                             runner (and by up, down, restart)
#
# The format is documented in docs/json-schema.md. Bump FL_SCHEMA_VERSION
# only for changes that break a reader; adding fields is not breaking.

FL_SCHEMA_VERSION=1

fl_state_json_path() { printf '%s/logs/.benchbar/state.json' "$FL_BENCH_DIR"; }

# fl_json_field_v VAR LINE KEY: KEY's string or integer in the one line JSON
# document LINE, empty for null or a missing key. state.json is one line we
# wrote ourselves, so parameter expansion is enough.
fl_json_field_v() {
  local __rest="$2" __key="\"$3\":" __v=""
  if [[ "$__rest" == *"$__key"* ]]; then
    __rest="${__rest#*"$__key"}"
    if [[ "$__rest" == \"* ]]; then
      __rest="${__rest#\"}"; __v="${__rest%%\"*}"
    elif [[ "$__rest" =~ ^(-?[0-9]+) ]]; then
      __v="${BASH_REMATCH[1]}"
    fi
  fi
  printf -v "$1" '%s' "$__v"
}

# fl_state_json_read: SJ_STATE, SJ_PID, SJ_STARTED and SJ_EXIT from one read
# of state.json (empty for null or a missing file).
SJ_STATE=""; SJ_PID=""; SJ_STARTED=""; SJ_EXIT=""
fl_state_json_read() {
  local line="" file="${FL_BENCH_DIR}/logs/.benchbar/state.json"
  SJ_STATE=""; SJ_PID=""; SJ_STARTED=""; SJ_EXIT=""
  [[ -f "$file" && -r "$file" ]] || return 0
  IFS= read -r line <"$file" || true
  fl_json_field_v SJ_STATE "$line" state
  fl_json_field_v SJ_PID "$line" pid
  fl_json_field_v SJ_STARTED "$line" started_at
  fl_json_field_v SJ_EXIT "$line" last_exit_code
}

# fl_state_json_get KEY: prints a string or number from state.json, nothing
# for null or a missing file.
fl_state_json_get() {
  local line="" v file
  file="$(fl_state_json_path)"
  [[ -f "$file" && -r "$file" ]] || return 0
  IFS= read -r line <"$file" || true
  fl_json_field_v v "$line" "$1"
  [[ -n "$v" ]] && printf '%s\n' "$v"
  return 0
}

# fl_state_core_json STATE STOP_REASON PID STARTED_AT LAST_EXIT PING
# Prints the fields shared by status --json and state.json, without braces.
fl_state_core_json() {
  local ping="${6:-}" j_bench j_name j_site j_label j_reason j_pid j_started j_exit j_url j_ping
  [[ "$ping" == "000" ]] && ping=""
  fl_json_str_v j_bench "$FL_BENCH_DIR"; fl_json_str_v j_name "$FL_BENCH_NAME"; fl_json_str_v j_site "$FL_SITE"
  fl_agent_label_v j_label
  fl_json_str_v j_reason "$2"; fl_json_num_v j_pid "$3"; fl_json_str_v j_started "$4"; fl_json_num_v j_exit "$5"
  fl_json_str_v j_url "http://${FL_SITE}:${FL_WEB_PORT}"
  [[ -n "$FL_SITE" ]] || j_url="null"
  fl_json_num_v j_ping "$ping"
  printf '"schema_version":%d,"cli_version":"%s","bench":%s,"name":%s,"site":%s,"label":"%s","state":"%s","stop_reason":%s,"pid":%s,"started_at":%s,"last_exit_code":%s,"web_url":%s,"web_ping_code":%s' \
    "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$j_bench" "$j_name" "$j_site" "$j_label" \
    "$1" "$j_reason" "$j_pid" "$j_started" "$j_exit" "$j_url" "$j_ping"
}

# fl_state_json_write STATE STOP_REASON PID STARTED_AT LAST_EXIT PING
# Writes state.json with a temp file and mv, so a reader never sees half a file.
fl_state_json_write() {
  local file dir tmp
  [[ "${FL_DRY_RUN:-0}" == "1" ]] && return 0
  file="$(fl_state_json_path)"
  dir="$(dirname "$file")"
  mkdir -p "$dir" 2>/dev/null || return 0
  tmp="$(mktemp "${dir}/.state.json.XXXXXX" 2>/dev/null)" || return 0
  {
    printf '{'
    fl_state_core_json "$@"
    printf ',"updated_at":"%s","source":"cli"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$tmp" && mv -f "$tmp" "$file"
  fl_log "state.json: $1${2:+ ($2)}"
}

# fl_status_compute: reads the live facts and sets ST_* globals.
#
#   processes of this bench running  -> running (site answers) or starting
#   stop flag manual                 -> stopped, stop_reason manual
#   stop flag crash                  -> paused, stop_reason crash
#   stop flag broken (or unknown)    -> paused, stop_reason broken
#   last run crashed (state.json)    -> crashed, stop_reason crash (launchd retries)
#   otherwise                        -> stopped, stop_reason null
#
# Cost (the app runs this for every bench on a timer): one launchctl print,
# one curl while processes run, and while the runner's state.json and
# launchd agree, nothing else. Otherwise one pgrep and at most one lsof
# (fl_bench_status_pids); never an lsof per pid or of the ports.
# shellcheck disable=SC2153  # AG_* are set by fl_agent_read (launchd.sh)
fl_status_compute() {
  local pids=""
  fl_stop_flag_reason_v ST_FLAG
  fl_agent_read
  ST_LOADED="$AG_LOADED"; ST_AGENT_STATE="$AG_STATE"
  fl_state_json_read
  ST_STARTED="$SJ_STARTED"; ST_EXIT="$SJ_EXIT"
  if [[ -z "$ST_EXIT" && "$AG_EXIT" =~ ^-?[0-9]+$ ]]; then ST_EXIT="$AG_EXIT"; fi

  # The runner's word first: state.json says running or starting, launchd
  # runs that very pid, and it is alive. A pid from a runner that was killed
  # (and maybe reused since) never has launchd's agreement.
  ST_PROCS=0; ST_PID=""
  if [[ ( "$SJ_STATE" == running || "$SJ_STATE" == starting ) && "$SJ_PID" =~ ^[0-9]+$ \
        && "$AG_STATE" == running && "$AG_PID" == "$SJ_PID" ]] && fl_pid_alive "$SJ_PID"; then
    ST_PROCS=1; ST_PID="$SJ_PID"
  else
    pids="$(fl_bench_status_pids)"
    if [[ -n "$pids" ]]; then
      ST_PROCS=1
      if [[ "$AG_STATE" == "running" && -n "$AG_PID" ]]; then
        ST_PID="$AG_PID"
      elif [[ "$SJ_PID" =~ ^[0-9]+$ ]] && fl_pid_alive "$SJ_PID"; then
        ST_PID="$SJ_PID"
      else
        ST_PID="${pids%%$'\n'*}"
      fi
    fi
  fi
  # the site is asked only while processes run, with the runner's own 2
  # second limit (a slower answer reads as starting, as it does there)
  ST_PING="000"
  if [[ "$ST_PROCS" == "1" ]]; then ST_PING="$(fl_site_ping_code 2)"; fi

  ST_REASON=""
  if [[ "$ST_PROCS" == "1" ]]; then
    if [[ "$ST_PING" != "000" ]]; then ST_STATE=running; else ST_STATE=starting; fi
  else
    case "$ST_FLAG" in
      manual) ST_STATE=stopped; ST_REASON=manual ;;
      crash) ST_STATE=paused; ST_REASON=crash ;;
      port_conflict) ST_STATE=paused; ST_REASON=port_conflict ;;
      "")
        if [[ "$SJ_STATE" == "crashed" ]]; then ST_STATE=crashed; ST_REASON=crash
        elif fl_bench_adopted; then ST_STATE=stopped
        else ST_STATE=not_adopted; fi ;;
      *) ST_STATE=paused; ST_REASON=broken ;;
    esac
  fi
}

# fl_pid_alive PID: kill -0, the builtin (FL_KILL_CMD stands in for it in the
# tests, and only under FL_TESTING=1)
fl_pid_alive() {
  local k=kill
  [[ "${FL_TESTING:-}" == "1" ]] && k="${FL_KILL_CMD:-kill}"
  "$k" -0 "$1" 2>/dev/null
}

# fl_bench_bin_v VAR: the `bench` executable the bench's service runs: the
# first one on the PATH its agent (unit) bakes in, as a JSON string; null
# without a service or when no such file is there. Bash builtins only: status
# is polled and starts no process for it.
fl_bench_bin_v() {
  local __p __d __found=""
  fl_service_path_v __p
  while [[ -n "$__p" ]]; do
    __d="${__p%%:*}"
    if [[ "$__p" == *:* ]]; then __p="${__p#*:}"; else __p=""; fi
    if [[ -n "$__d" && -f "$__d/bench" && -x "$__d/bench" ]]; then __found="$__d/bench"; break; fi
  done
  fl_json_str_v "$1" "$__found"
}

# fl_bstate_file_substantive FILE: the bench's state file holds something besides
# acknowledged doctor warnings (ACK_*): an ack is not a service, not a registration
fl_bstate_file_substantive() {
  local line
  [[ -r "$1" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == ACK_* ]] || return 0
  done <"$1"
  return 1
}

# fl_bench_adopted: benchbar knows this bench: it has a service (agent or
# unit), or it is remembered (the default bench, its own state file, or
# `register`). A folder that is a bench and neither is "not_adopted". Builtins only.
fl_bench_adopted() {
  local label f line
  fl_agent_label_v label
  fl_agent_file_v f "$label"
  [[ ! -f "$f" ]] || return 0
  if [[ "$FL_BS_DIR" == "$FL_BENCH_DIR" && "$FL_BS_DEFAULT" == "1" ]]; then return 0; fi
  fl_bstate_file_substantive "$(fl_bench_state_file_for "$FL_BENCH_DIR")" && return 0
  if [[ -r "${FL_STATE_DIR}/registered-benches.txt" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" ]] || ! fl_same_path "$line" "$FL_BENCH_DIR" || return 0
    done <"${FL_STATE_DIR}/registered-benches.txt"
  fi
  # a primed read (status, list) answered for the default bench above already
  [[ "$FL_BS_DIR" != "$FL_BENCH_DIR" ]] || return 1
  fl_same_path "$(fl_state_get BENCH_DIR 2>/dev/null || true)" "$FL_BENCH_DIR"
}

# fl_status_print_json [PINGS]: PINGS "ping" asks every site (status --ping);
# without it only web_ping_code, the default site's, is known.
fl_status_print_json() {
  local mode="${1:-none}" j_auto j_notices j_listen j_labs j_ports j_sites j_redis j_sched j_file j_log j_loaded j_astate j_procs j_url j_label j_bin j_pending j_ready j_leases sched=0
  # a folder benchbar does not know has no site of its own to name: never the
  # default bench's, never one it guessed
  [[ "$ST_STATE" != "not_adopted" ]] || FL_SITE=""
  fl_ports_json_v j_ports
  FL_DEFAULT_PING=""; [[ "$ST_PROCS" == "1" ]] && FL_DEFAULT_PING="$ST_PING"
  fl_sites_json_v j_sites "$mode" 0 1
  fl_redis_json_v j_redis
  fl_ready_compute "${OPT_DEEP:-0}"
  fl_ready_json_v j_ready
  fl_scheduler_enabled && sched=1
  fl_json_bool_v j_sched "$sched"
  fl_autostart_enabled && j_auto=true || j_auto=false
  fl_json_str_v j_listen "$(fl_listen_mode)"
  fl_json_str_v j_file "${FL_BENCH_DIR}/logs/.benchbar/state.json"
  fl_json_str_v j_log "${FL_BENCH_DIR}/logs/bench.log"
  fl_json_bool_v j_loaded "$ST_LOADED"; fl_json_str_v j_astate "$ST_AGENT_STATE"; fl_json_bool_v j_procs "$ST_PROCS"
  fl_json_str_v j_url "http://${FL_SITE}:${FL_WEB_PORT}"
  [[ -n "$FL_SITE" ]] || j_url="null"
  fl_agent_label_v j_label
  fl_pending_json_v j_pending
  printf '{'
  fl_state_core_json "$ST_STATE" "$ST_REASON" "$ST_PID" "$ST_STARTED" "$ST_EXIT" "$ST_PING"
  fl_bench_bin_v j_bin
  printf ',"ports":%s,"sites":%s,"scheduler":%s,"autostart":%s,"listen":%s,"redis":%s,"bench_bin":%s' "$j_ports" "$j_sites" "$j_sched" "$j_auto" "$j_listen" "$j_redis" "$j_bin"
  printf ',"state_file":%s,"log":%s,"agent_loaded":%s,"agent_state":%s,"processes_running":%s' \
    "$j_file" "$j_log" "$j_loaded" "$j_astate" "$j_procs"
  # fields from frappe-mac 0.2.0, kept for older readers
  printf ',"url":%s,"agent":"%s","loaded":"%s","stop_flag":"%s","ping":"%s"' \
    "$j_url" "$j_label" "$([[ "$ST_LOADED" == "1" ]] && printf yes || printf no)" "${ST_FLAG:-none}" "$ST_PING"
  # app update or app add runs that stopped half way, with the steps left
  fl_lab_enabled_json_v j_labs
  fl_notices_json_v j_notices
  fl_leases_json_v j_leases "$FL_BENCH_DIR"
  printf ',"pending_operations":%s,"ready":%s,"labs":%s,"notices":%s,"leases":%s}\n' "$j_pending" "$j_ready" "$j_labs" "$j_notices" "$j_leases"
}

# ---------------------------------------------------------------- leases (the read side)
#
# lease.sh owns the leases; status shows the active ones of its bench, so this
# small reader lives in the lean load. <state folder>/leases.tsv has one lease
# per line, fields separated by a tab, none empty ("-" for no site, no note):
#   id kind bench site holder since since_epoch expires expires_epoch minutes note
# Without leases (no file, or an empty one) it reads nothing and starts no
# program; with them it asks the clock once.

# fl_lease_now_v VAR: seconds since the epoch (FL_NOW fixes it, only under FL_TESTING=1)
fl_lease_now_v() {
  if [[ "${FL_TESTING:-}" == "1" && "${FL_NOW:-}" =~ ^[0-9]+$ ]]; then printf -v "$1" '%s' "$FL_NOW"
  else printf -v "$1" '%s' "$(date +%s)"; fi
}

# fl_leases_json_v VAR BENCH: the active leases on BENCH (the bench, or one of
# its sites) as a JSON array, without their ids: an id is what lets a run
# change a leased bench, so only `lease take` and a person's `lease list` show it
fl_leases_json_v() {
  local __f="${FL_STATE_DIR}/leases.tsv" __now="" __out="" __sep="" id kind b site holder since se exp ee mins note jsite jh jn js je
  if [[ ! -s "$__f" ]]; then printf -v "$1" '[]'; return 0; fi
  fl_lease_now_v __now
  while IFS=$'\t' read -r id kind b site holder since se exp ee mins note || [[ -n "$id" ]]; do
    [[ "$kind" == "bench" || "$kind" == "site" ]] || continue
    [[ "$ee" =~ ^[0-9]+$ && "$ee" -gt "$__now" && "$b" == "$2" ]] || continue
    [[ "$site" != "-" ]] || site=""
    [[ "$note" != "-" ]] || note=""
    fl_json_str_v jsite "$site"; fl_json_str_v jh "$holder"; fl_json_str_v jn "$note"; fl_json_str_v js "$since"; fl_json_str_v je "$exp"
    __out="${__out}${__sep}{\"scope\":\"${kind}\",\"site\":${jsite},\"holder\":${jh},\"note\":${jn},\"since\":${js},\"expires_at\":${je}}"
    __sep=","
  done <"$__f"
  printf -v "$1" '[%s]' "$__out"
}

# fl_redis_json_v VAR: {"queue":{"port","running"},"cache":{...}}. running is whether
# something accepts a connection on the port (bash's /dev/tcp: status starts
# no program for it); a bench's own Redis, started by up --services-only or
# by the service, and a stranger on the port look the same here, as they
# do to the web server that would use them.
fl_redis_json_v() {
  fl_redis_probe
  printf -v "$1" '{"queue":{"port":%s,"running":%s},"cache":{"port":%s,"running":%s}}' "$FL_REDIS_QUEUE_PORT" "$FL_RD_REDIS_Q" "$FL_REDIS_CACHE_PORT" "$FL_RD_REDIS_C"
}

# fl_redis_probe: FL_RD_REDIS_Q and FL_RD_REDIS_C (true or false), each port
# asked once per run; the readiness contract reuses the answer. Clear both to
# ask again (the wait loop does).
FL_RD_REDIS_Q=""; FL_RD_REDIS_C=""
fl_redis_probe() {
  [[ -z "$FL_RD_REDIS_Q" ]] || return 0
  FL_RD_REDIS_Q=false; FL_RD_REDIS_C=false
  fl_tcp_open "$FL_REDIS_QUEUE_PORT" && FL_RD_REDIS_Q=true
  fl_tcp_open "$FL_REDIS_CACHE_PORT" && FL_RD_REDIS_C=true
  return 0
}

# ---------------------------------------------------------------- readiness
#
# One definition of "ready", for status --json (the ready object), wait, up
# and restart. The parts, each true, false or (not asked yet) null:
#
#   agent       the service is loaded in launchd or systemd
#   processes   the bench's processes run
#   web         the default site answers its ping with a 2xx or 3xx
#   socketio    the realtime port accepts a connection
#   redis       the queue and the cache Redis accept a connection
#   workers     a background worker runs            (deep only)
#   stale       a Python file under apps/ changed after the bench started,
#               so the running code is old          (deep only)
#
# ready is true when no part is false and stale is not true. The fast path
# (status without --deep) starts no program beyond what status already runs:
# agent, processes and web come from fl_status_compute, socketio and redis
# from bash's /dev/tcp. The deep parts need pgrep, lsof and find, so only
# wait, up, restart and status --deep ask for them.

# fl_ready_web_ok CODE: the web part, for an HTTP code: 2xx or 3xx
fl_ready_web_ok() { [[ "$1" =~ ^[23][0-9][0-9]$ ]]; }

# fl_ready_part_ok PART: after fl_ready_compute, whether the part holds
# (workers and stale count as holding while they are not asked)
fl_ready_part_ok() {
  case "$1" in
    agent) [[ "$RD_AGENT" == true ]] ;;
    processes) [[ "$RD_PROCESSES" == true ]] ;;
    web) [[ "$RD_WEB" == true ]] ;;
    socketio) [[ "$RD_SOCKETIO" == true ]] ;;
    redis) [[ "$RD_REDIS" == true ]] ;;
    workers) [[ "$RD_WORKERS" != false ]] ;;
    stale) [[ "$RD_STALE" != true ]] ;;
    *) return 1 ;;
  esac
}

# fl_ready_stale_v VAR: true when a *.py file under apps/ is newer than the
# runner that started the bench's processes (state.json's started_at, UTC,
# before the web server loads its code), false when none is, null when the
# start time is not known. RD_STALE_FILE names the first one found.
fl_ready_stale_v() {
  local __since="" __hit=""
  RD_STALE_FILE=""
  if [[ "$SJ_STARTED" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}:[0-9]{2}:[0-9]{2})Z$ ]]; then
    __since="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
  fi
  if [[ -z "$__since" || ! -d "${FL_BENCH_DIR}/apps" ]]; then printf -v "$1" '%s' null; return 0; fi
  # -H follows the symlinks named on the command line: an app folder that is a
  # link to a checkout elsewhere (bench get-app --soft-link, a dev clone) is searched,
  # and links inside an app are not followed, so there is no loop to guard against
  local __app
  for __app in "${FL_BENCH_DIR}/apps"/*/; do
    [[ -d "$__app" ]] || continue
    __hit="$(TZ=UTC find -H "${__app%/}" \( -name node_modules -o -name .git -o -name __pycache__ \) -prune -o -type f -name '*.py' -newermt "$__since" -print -quit 2>/dev/null || true)"
    [[ -z "$__hit" ]] || break
  done
  if [[ -n "$__hit" ]]; then RD_STALE_FILE="${__hit#"${FL_BENCH_DIR}/"}"; printf -v "$1" '%s' true; else printf -v "$1" '%s' false; fi
}

# fl_ready_compute [deep]: sets RD_* from the ST_* of fl_status_compute (run
# that first). deep "1" also asks workers and stale.
fl_ready_compute() {
  local deep="${1:-0}"
  RD_AGENT=false; RD_PROCESSES=false; RD_WEB=false; RD_SOCKETIO=false; RD_REDIS=false
  RD_WORKERS=null; RD_STALE=null; RD_STALE_FILE=""; RD_DEEP=false
  [[ "$ST_LOADED" != "1" ]] || RD_AGENT=true
  [[ "$ST_PROCS" != "1" ]] || RD_PROCESSES=true
  ! fl_ready_web_ok "$ST_PING" || RD_WEB=true
  if [[ "$ST_PROCS" == "1" ]] && fl_tcp_open "$FL_SOCKETIO_PORT"; then RD_SOCKETIO=true; fi
  fl_redis_probe
  [[ "$FL_RD_REDIS_Q" == true && "$FL_RD_REDIS_C" == true ]] && RD_REDIS=true
  if [[ "$deep" == "1" ]]; then
    RD_DEEP=true
    RD_WORKERS=false
    if [[ "$ST_PROCS" == "1" ]]; then
      [[ -z "$(fl_pgrep_f ' -m frappe\.utils\.bench_helper frappe worker( |$)' | fl_pids_in_bench)" ]] || RD_WORKERS=true
      fl_ready_stale_v RD_STALE
    fi
  fi
  RD_WAITING=""
  local p
  for p in agent processes web socketio redis workers stale; do
    fl_ready_part_ok "$p" || RD_WAITING="${RD_WAITING}${RD_WAITING:+ }${p}"
  done
  RD_READY=false; [[ -n "$RD_WAITING" ]] || RD_READY=true
  fl_ready_fix_v RD_FIX
}

# fl_ready_fix_v VAR: the command that moves the first missing part, empty when ready
fl_ready_fix_v() {
  local __f=""
  if [[ "$RD_READY" == true ]]; then
    __f=""
  elif [[ "$ST_STATE" == "not_adopted" ]]; then
    __f="${FL_SELF} adopt ${FL_BENCH_DIR}"
  elif [[ "$ST_STATE" == "paused" || "$ST_STATE" == "crashed" ]]; then
    __f="${FL_SELF} doctor --bench-dir ${FL_BENCH_DIR}"
  elif [[ "$RD_PROCESSES" != true ]]; then
    __f="${FL_SELF} up --bench-dir ${FL_BENCH_DIR}"
  elif [[ "$RD_STALE" == true ]]; then
    __f="${FL_SELF} restart --bench-dir ${FL_BENCH_DIR}"
  else
    __f="${FL_SELF} logs --bench-dir ${FL_BENCH_DIR}"
  fi
  printf -v "$1" '%s' "$__f"
}

# fl_ready_json_v VAR: the ready object of status --json, from the RD_* of fl_ready_compute
fl_ready_json_v() {
  local __w="" __p __fix __stale_file
  for __p in $RD_WAITING; do __w="${__w}${__w:+,}\"${__p}\""; done
  fl_json_str_v __fix "$RD_FIX"; [[ -n "$RD_FIX" ]] || __fix=null
  fl_json_str_v __stale_file "$RD_STALE_FILE"; [[ -n "$RD_STALE_FILE" ]] || __stale_file=null
  printf -v "$1" '{"ready":%s,"deep":%s,"agent":%s,"processes":%s,"web":%s,"socketio":%s,"redis":%s,"workers":%s,"stale":%s,"stale_file":%s,"waiting_on":[%s],"fix":%s}' \
    "$RD_READY" "$RD_DEEP" "$RD_AGENT" "$RD_PROCESSES" "$RD_WEB" "$RD_SOCKETIO" "$RD_REDIS" "$RD_WORKERS" "$RD_STALE" "$__stale_file" "$__w" "$__fix"
}

# fl_state_after_v VAR: the bench's status --json object as it is now, for the
# state_after of a done (no per site ping), "null" without a bench. A subshell:
# it changes nothing of the run it ends and cannot end it.
fl_state_after_v() {
  local __j="null"
  if [[ "${FL_CONTEXT_READY:-0}" == "1" ]] && fl_is_bench_dir "${FL_BENCH_DIR:-}"; then
    __j="$( set +e; trap - ERR; FL_RD_REDIS_Q=""; { fl_status_compute; fl_status_print_json; } 2>/dev/null )" || __j="null"
    __j="${__j//$'\n'/}"
    [[ "$__j" == "{"*"}" ]] || __j="null"
  fi
  printf -v "$1" '%s' "$__j"
}

fl_ports_json_v() {
  printf -v "$1" '{"web":%s,"socketio":%s,"redis_queue":%s,"redis_socketio":%s,"redis_cache":%s}' \
    "$FL_WEB_PORT" "$FL_SOCKETIO_PORT" "$FL_REDIS_QUEUE_PORT" "${FL_REDIS_SOCKETIO_PORT:-$FL_REDIS_CACHE_PORT}" "$FL_REDIS_CACHE_PORT"
}

# ---------------------------------------------------------------- list

# Prints every bench folder benchbar knows about, one per line, remembered
# bench first: state.env, agents in ~/Library/LaunchAgents, auto-detection.
# In bash, without a pipeline: every command that looks for a bench label
# runs it once.
# fl_known_bench_candidates: every folder benchbar has been told of, one per
# line, before the "is it a bench" filter: state.env, the registered list,
# agents, auto-detection. A folder that is gone (an unmounted volume) is in
# it; fl_known_benches leaves such ones out.
fl_known_bench_candidates() {
  local f d
  d="$(fl_state_get BENCH_DIR 2>/dev/null || true)"
  [[ -z "$d" ]] || printf '%s\n' "$d"
  if [[ -f "${FL_STATE_DIR}/registered-benches.txt" ]]; then
    while IFS= read -r d || [[ -n "$d" ]]; do [[ -z "$d" ]] || printf '%s\n' "$d"; done <"${FL_STATE_DIR}/registered-benches.txt"
  fi
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    d="$(fl_plist_working_dir "$f")"
    [[ -z "$d" ]] || printf '%s\n' "$d"
  done < <(fl_agent_files all)
  fl_bench_candidates
}

fl_known_benches() {
  local d c seen=$'\n' cands=()
  while IFS= read -r d; do cands+=("$d"); done < <(fl_known_bench_candidates)
  for d in ${cands[@]+"${cands[@]}"}; do
    if [[ -z "$d" ]] || ! fl_is_bench_dir "$d"; then continue; fi
    c="$(fl_abs_path "$d")"
    [[ -n "${c//[[:space:]]/}" ]] || continue
    case "$seen" in *$'\n'"$c"$'\n'*) continue ;; esac
    seen="${seen}${c}"$'\n'
    printf '%s\n' "$c"
  done
}

# fl_bench_load DIR: points the FL_* bench globals at DIR (site and ports
# from that bench, never from the environment). list exits afterwards; the
# other callers (port management, the MariaDB restart note) run it in a
# subshell, so nothing needs restoring.
fl_bench_load() {
  SITE_NAME=""; BENCH_DIR=""
  FL_WEB_PORT=8000; FL_SOCKETIO_PORT=9000; FL_REDIS_CACHE_PORT=13000; FL_REDIS_QUEUE_PORT=11000; FL_REDIS_SOCKETIO_PORT=""
  fl_bench_detect "$1"
  # the read only callers (list, ports check) read each bench's files once
  fl_bench_hash_prime
  fl_bstate_prime
  fl_site_config_prime
  fl_site_detect ""
  fl_ports_detect
  fl_agent_label_prime
}

# The lockfile of a bench. Here, not in teamlock.sh: list --json asks for it and a
# lean start does not load teamlock.sh.
FL_LOCK_FILE=""
FL_LOCK_SOURCE=""
# fl_lock_file_resolve [FLAG] [no-env]: sets FL_LOCK_FILE (maybe a file
# that does not exist yet) and FL_LOCK_SOURCE (flag, env, state, bench, or
# none when nothing names one and <bench>/benchbar.toml does not exist).
fl_lock_file_resolve() {
  local flag="${1:-}" noenv="${2:-}" v
  FL_LOCK_SOURCE=""
  if [[ -n "$flag" ]]; then
    case "$flag" in
      /*) FL_LOCK_FILE="$flag" ;;
      '~/'*) FL_LOCK_FILE="${HOME}/${flag#'~/'}" ;;
      *) if [[ -e "${PWD}/${flag}" ]]; then FL_LOCK_FILE="${PWD}/${flag}"; else FL_LOCK_FILE="${FL_BENCH_DIR}/${flag}"; fi ;;
    esac
    FL_LOCK_SOURCE=flag
  elif [[ -z "$noenv" && -n "${BENCHBAR_LOCK:-}" ]]; then
    FL_LOCK_FILE="$BENCHBAR_LOCK"; FL_LOCK_SOURCE="env"
  elif v="$(fl_bstate_get LOCK_FILE 2>/dev/null)" && [[ -n "$v" ]]; then
    FL_LOCK_FILE="$v"; FL_LOCK_SOURCE=state
  else
    FL_LOCK_FILE="${FL_BENCH_DIR}/benchbar.toml"
    FL_LOCK_SOURCE=bench
    [[ -f "$FL_LOCK_FILE" ]] || FL_LOCK_SOURCE=none
  fi
  return 0
}

# One bench of list --json. Sites are listed with ping_code null: list never
# asks a site or looks for listeners (status does, for one bench).
fl_list_entry_json() {
  local default="$1" installed=0 adopted=0 lock="" label f j_path j_name j_site j_url j_ports j_sites j_default j_installed j_file j_lock j_adopted
  fl_agent_label_v label
  fl_agent_file_v f "$label"
  [[ -f "$f" ]] && installed=1
  if fl_bench_adopted; then adopted=1; fi
  # the bench's lockfile: remembered or <bench>/benchbar.toml (BENCHBAR_LOCK names one bench, not all)
  fl_lock_file_resolve "" no-env
  [[ "$FL_LOCK_SOURCE" != "none" ]] && lock="$FL_LOCK_FILE"
  fl_json_str_v j_path "$FL_BENCH_DIR"; fl_json_str_v j_name "$FL_BENCH_NAME"; fl_json_str_v j_site "$FL_SITE"
  fl_json_str_v j_url "http://${FL_SITE}:${FL_WEB_PORT}"
  fl_ports_json_v j_ports
  FL_DEFAULT_PING=""
  fl_sites_json_v j_sites none
  fl_json_bool_v j_default "$default"; fl_json_bool_v j_installed "$installed"
  fl_json_str_v j_file "${FL_BENCH_DIR}/logs/.benchbar/state.json"
  fl_json_str_v j_lock "$lock"
  # adopted: benchbar knows this bench (a service, registered, or remembered); a folder that only looks
  # like a bench under ~ or ~/dev is listed with false (the MCP server changes only adopted benches)
  fl_json_bool_v j_adopted "$adopted"
  printf '{"path":%s,"name":%s,"site":%s,"label":"%s","web_url":%s,"ports":%s,"sites":%s,"default":%s,"service_installed":%s,"state_file":%s,"lock_file":%s,"adopted":%s}' \
    "$j_path" "$j_name" "$j_site" "$label" "$j_url" "$j_ports" "$j_sites" "$j_default" "$j_installed" "$j_file" "$j_lock" "$j_adopted"
}

# fl_cmd_list JSON: the default bench is the one commands use without --bench-dir.
fl_cmd_list() {
  local json="${1:-0}" default="" d sep="" rows=() benches=() is_default cell_name cell_site cell_dir
  fl_bench_detect "${OPT_BENCH_DIR:-}"
  fl_is_bench_dir "$FL_BENCH_DIR" && default="$FL_BENCH_DIR"
  while IFS= read -r d; do
    [[ -n "$d" ]] && benches+=("$d")
  done < <(fl_known_benches)
  # every bench's label needs this list; build it once, not per label
  FL_KNOWN_BENCHES_CACHE="$(printf '%s\n' ${benches[@]+"${benches[@]}"})"; FL_KNOWN_BENCHES_CACHED=1
  if [[ "$json" == "1" ]]; then
    printf '{"schema_version":%d,"cli_version":"%s","default_bench":%s,"benches":[' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$default")"
    for d in ${benches[@]+"${benches[@]}"}; do
      fl_bench_load "$d"
      is_default=0; [[ "$d" == "$default" ]] && is_default=1
      printf '%s' "$sep"
      fl_list_entry_json "$is_default"
      sep=","
    done
    printf ']}\n'
    return 0
  fi
  if [[ "${#benches[@]}" == "0" ]]; then
    fl_info "no benches found; create one with: ${FL_SELF} install"
    return 0
  fi
  rows+=("Bench|Site|Web|Path")
  for d in "${benches[@]}"; do
    fl_bench_load "$d"
    is_default=""; [[ "$d" == "$default" ]] && is_default=" (default)"
    fl_cell_v cell_name "${FL_BENCH_NAME}${is_default}"; fl_cell_v cell_site "$FL_SITE"; fl_cell_v cell_dir "$FL_BENCH_DIR"
    rows+=("${cell_name}|${cell_site}|${FL_WEB_PORT}|${cell_dir}")
  done
  fl_table "${rows[@]}"
}

# fl_site_ping_code [SECONDS]: the default site's ping (3 s; status asks with 1)
fl_site_ping_code() {
  local code
  code="$(curl -s -o /dev/null -m "${1:-3}" -w '%{http_code}' -H "Host: ${FL_SITE}" "http://127.0.0.1:${FL_WEB_PORT}/api/method/ping" 2>/dev/null || true)"
  case "$code" in
    [0-9][0-9][0-9]) printf '%s' "$code" ;;
    *) printf '000' ;;
  esac
}

# fl_bench_guess_gate [LINE]: a command that changes things and was not told which
# bench (no --bench-dir, no BENCH_DIR, none remembered) acts on the first one
# fl_bench_detect finds. Say which, and why; and where nobody can be asked
# (--for-agent, BENCHBAR_NONINTERACTIVE=1) with more than one bench known,
# refuse to guess. The note goes to stderr: a --json run keeps its stdout.
# The refusal tells what to run instead: the command and its first argument with --bench-dir PATH,
# or, with LINE (the whole command line that was typed), LINE with --bench-dir PATH.
fl_bench_guess_gate() {
  local d n=0 list="" sep="" line="${COMMAND}${ARGS[0]:+ ${ARGS[0]}}"
  [[ -z "${1:-}" ]] || line="$1"
  fl_bench_detect "$OPT_BENCH_DIR"
  [[ "${FL_BENCH_SOURCE:-}" == "detected" ]] || return 0
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    n=$((n + 1)); list="${list}${sep}${d}"; sep=", "
  done < <(fl_known_benches)
  if [[ "$n" -gt 1 ]] && fl_noninteractive; then
    fl_die "More than one bench is possible and none was chosen: ${list}." "Choose one: benchbar ${line} --bench-dir PATH (or set BENCH_DIR). benchbar list shows them."
  fi
  printf 'benchbar: acting on %s (auto-detected: no --bench-dir, BENCH_DIR or remembered bench%s; pass --bench-dir to choose)
'     "$FL_BENCH_DIR" "$([[ "$n" -gt 1 ]] && printf '; %s benches are known: %s' "$n" "$list")" >&2
}

# fl_bench_write_gate: the guess gate for the forms that write benchbar's state while their command, in the commands
# table, reads: app focus NAME, doctor --ack ID and doctor --unack ID. The table says "mutating no" for both keys (it is
# per command, and "yes" would make doctor --json refuse for an agent with two benches), so the dispatch (benchbar)
# calls this next to the gate of the table: before the run opens its log, takes the lock or writes anything, with the
# same notice for a person and the same refusal for an agent. The refusal names the whole form that was typed.
fl_bench_write_gate() {
  local line="$COMMAND" i=1 a named=0
  case "$COMMAND" in
    doctor) [[ -n "$OPT_ACK$OPT_UNACK" ]] || return 0
      [[ -z "$OPT_ACK" ]] || line="${line} --ack $(printf '%q' "$OPT_ACK")"
      [[ -z "$OPT_UNACK" ]] || line="${line} --unack $(printf '%q' "$OPT_UNACK")" ;;
    app) [[ "${ARGS[0]:-}" == focus ]] || return 0
      line="${line} focus"
      while [[ "$i" -lt "${#ARGS[@]}" ]]; do
        a="${ARGS[$i]}"
        # a word that is not a flag is the app: the form that pins
        if [[ "$a" != -* && "$named" == 0 ]]; then named=1; fi
        line="${line} $(printf '%q' "$a")"
        i=$((i + 1))
      done
      [[ "$named" == 1 ]] || return 0 ;;
    *) return 0 ;;
  esac
  fl_bench_guess_gate "$line"
}
