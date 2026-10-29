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

# fl_pid_alive PID: kill -0, the builtin (FL_KILL_CMD stands in for it in the tests)
fl_pid_alive() { "${FL_KILL_CMD:-kill}" -0 "$1" 2>/dev/null; }

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
  local mode="${1:-none}" j_ports j_sites j_sched j_file j_log j_loaded j_astate j_procs j_url j_label j_bin j_pending sched=0
  # a folder benchbar does not know has no site of its own to name: never the
  # default bench's, never one it guessed
  [[ "$ST_STATE" != "not_adopted" ]] || FL_SITE=""
  fl_ports_json_v j_ports
  FL_DEFAULT_PING=""; [[ "$ST_PROCS" == "1" ]] && FL_DEFAULT_PING="$ST_PING"
  fl_sites_json_v j_sites "$mode"
  fl_scheduler_enabled && sched=1
  fl_json_bool_v j_sched "$sched"
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
  printf ',"ports":%s,"sites":%s,"scheduler":%s,"bench_bin":%s' "$j_ports" "$j_sites" "$j_sched" "$j_bin"
  printf ',"state_file":%s,"log":%s,"agent_loaded":%s,"agent_state":%s,"processes_running":%s' \
    "$j_file" "$j_log" "$j_loaded" "$j_astate" "$j_procs"
  # fields from frappe-mac 0.2.0, kept for older readers
  printf ',"url":%s,"agent":"%s","loaded":"%s","stop_flag":"%s","ping":"%s"' \
    "$j_url" "$j_label" "$([[ "$ST_LOADED" == "1" ]] && printf yes || printf no)" "${ST_FLAG:-none}" "$ST_PING"
  # app update or app add runs that stopped half way, with the steps left
  printf ',"pending_operations":%s}\n' "$j_pending"
}

# fl_state_after_v VAR: the bench's status --json object as it is now, for the
# state_after of a done (no per site ping), "null" without a bench. A subshell:
# it changes nothing of the run it ends and cannot end it.
fl_state_after_v() {
  local __j="null"
  if [[ "${FL_CONTEXT_READY:-0}" == "1" ]] && fl_is_bench_dir "${FL_BENCH_DIR:-}"; then
    __j="$( set +e; trap - ERR; { fl_status_compute; fl_status_print_json; } 2>/dev/null )" || __j="null"
    __j="${__j//$'\n'/}"
    [[ "$__j" == "{"*"}" ]] || __j="null"
  fi
  printf -v "$1" '%s' "$__j"
}

fl_ports_json_v() {
  printf -v "$1" '{"web":%s,"socketio":%s,"redis_queue":%s,"redis_socketio":%s,"redis_cache":%s}' \
    "$FL_WEB_PORT" "$FL_SOCKETIO_PORT" "$FL_REDIS_QUEUE_PORT" "${FL_REDIS_SOCKETIO_PORT:-$FL_REDIS_CACHE_PORT}" "$FL_REDIS_CACHE_PORT"
}
fl_ports_json() { local j; fl_ports_json_v j; printf '%s' "$j"; }

# ---------------------------------------------------------------- list

# Prints every bench folder benchbar knows about, one per line, remembered
# bench first: state.env, agents in ~/Library/LaunchAgents, auto-detection.
# In bash, without a pipeline: every command that looks for a bench label
# runs it once.
fl_known_benches() {
  local f d c seen=$'\n' cands=()
  d="$(fl_state_get BENCH_DIR 2>/dev/null || true)"
  cands+=("$d")
  if [[ -f "${FL_STATE_DIR}/registered-benches.txt" ]]; then
    while IFS= read -r d || [[ -n "$d" ]]; do cands+=("$d"); done <"${FL_STATE_DIR}/registered-benches.txt"
  fi
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    cands+=("$(fl_plist_working_dir "$f")")
  done < <(fl_agent_files all)
  while IFS= read -r d; do cands+=("$d"); done < <(fl_bench_candidates)
  for d in "${cands[@]}"; do
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

# One bench of list --json. Sites are listed with ping_code null: list never
# asks a site or looks for listeners (status does, for one bench).
fl_list_entry_json() {
  local default="$1" installed=0 lock="" label f j_path j_name j_site j_url j_ports j_sites j_default j_installed j_file j_lock
  fl_agent_label_v label
  fl_agent_file_v f "$label"
  [[ -f "$f" ]] && installed=1
  # the bench's lockfile: remembered or <bench>/benchbar.toml (BENCHBAR_LOCK names one bench, not all)
  if declare -F fl_lock_file_resolve >/dev/null; then
    fl_lock_file_resolve "" no-env
    [[ "$FL_LOCK_SOURCE" != "none" ]] && lock="$FL_LOCK_FILE"
  fi
  fl_json_str_v j_path "$FL_BENCH_DIR"; fl_json_str_v j_name "$FL_BENCH_NAME"; fl_json_str_v j_site "$FL_SITE"
  fl_json_str_v j_url "http://${FL_SITE}:${FL_WEB_PORT}"
  fl_ports_json_v j_ports
  FL_DEFAULT_PING=""
  fl_sites_json_v j_sites none
  fl_json_bool_v j_default "$default"; fl_json_bool_v j_installed "$installed"
  fl_json_str_v j_file "${FL_BENCH_DIR}/logs/.benchbar/state.json"
  fl_json_str_v j_lock "$lock"
  printf '{"path":%s,"name":%s,"site":%s,"label":"%s","web_url":%s,"ports":%s,"sites":%s,"default":%s,"service_installed":%s,"state_file":%s,"lock_file":%s}' \
    "$j_path" "$j_name" "$j_site" "$label" "$j_url" "$j_ports" "$j_sites" "$j_default" "$j_installed" "$j_file" "$j_lock"
}

# fl_cmd_list JSON: the default bench is the one commands use without --bench-dir.
fl_cmd_list() {
  local json="${1:-0}" default="" d sep="" rows=() benches=() is_default
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
    rows+=("${FL_BENCH_NAME}${is_default}|${FL_SITE}|${FL_WEB_PORT}|${FL_BENCH_DIR}")
  done
  fl_table "${rows[@]}"
}
