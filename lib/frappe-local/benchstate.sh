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

fl_json_str() {
  if [[ -n "$1" ]]; then printf '"%s"' "$(fl_json_escape "$1")"; else printf 'null'; fi
}

fl_json_num() {
  case "$1" in
    ''|-|*[!0-9-]*) printf 'null' ;;
    *) printf '%s' "$1" ;;
  esac
}

fl_json_bool() {
  if [[ "$1" == "1" || "$1" == "yes" || "$1" == "true" ]]; then printf 'true'; else printf 'false'; fi
}

# fl_state_json_get KEY: prints a string or number from state.json, nothing
# for null or a missing file. The file is one line written by us, so sed is enough.
fl_state_json_get() {
  local key="$1" file
  file="$(fl_state_json_path)"
  [[ -f "$file" ]] || return 0
  sed -n -e "s/.*\"${key}\":\"\([^\"]*\)\".*/\1/p" -e "s/.*\"${key}\":\(-\{0,1\}[0-9][0-9]*\).*/\1/p" "$file" 2>/dev/null | head -n1
}

# fl_state_core_json STATE STOP_REASON PID STARTED_AT LAST_EXIT PING
# Prints the fields shared by status --json and state.json, without braces.
fl_state_core_json() {
  local ping="${6:-}"
  [[ "$ping" == "000" ]] && ping=""
  printf '"schema_version":%d,"cli_version":"%s","bench":%s,"name":%s,"site":%s,"label":"%s","state":"%s","stop_reason":%s,"pid":%s,"started_at":%s,"last_exit_code":%s,"web_url":%s,"web_ping_code":%s' \
    "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" \
    "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$FL_BENCH_NAME")" "$(fl_json_str "$FL_SITE")" "$(fl_agent_label)" \
    "$1" "$(fl_json_str "$2")" "$(fl_json_num "$3")" "$(fl_json_str "$4")" "$(fl_json_num "$5")" \
    "$(fl_json_str "$(fl_site_url)")" "$(fl_json_num "$ping")"
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
fl_status_compute() {
  local jstate jpid agent_pid="" agent_exit=""
  ST_FLAG="$(fl_stop_flag_reason)"
  ST_PING="$(fl_site_ping_code)"
  ST_PROCS=0; fl_bench_is_running && ST_PROCS=1
  ST_LOADED=0; ST_AGENT_STATE=""
  if fl_agent_loaded; then
    ST_LOADED=1
    ST_AGENT_STATE="$(fl_agent_field state)"
    agent_pid="$(fl_agent_field pid)"
    agent_exit="$(fl_agent_field 'last exit code')"
  fi
  jstate="$(fl_state_json_get state)"
  jpid="$(fl_state_json_get pid)"
  ST_STARTED="$(fl_state_json_get started_at)"
  ST_EXIT="$(fl_state_json_get last_exit_code)"
  if [[ -z "$ST_EXIT" && "$agent_exit" =~ ^-?[0-9]+$ ]]; then ST_EXIT="$agent_exit"; fi

  ST_REASON=""
  if [[ "$ST_PROCS" == "1" ]]; then
    if [[ "$ST_PING" != "000" ]]; then ST_STATE=running; else ST_STATE=starting; fi
  else
    case "$ST_FLAG" in
      manual) ST_STATE=stopped; ST_REASON=manual ;;
      crash) ST_STATE=paused; ST_REASON=crash ;;
      "")
        if [[ "$jstate" == "crashed" ]]; then ST_STATE=crashed; ST_REASON=crash; else ST_STATE=stopped; fi ;;
      *) ST_STATE=paused; ST_REASON=broken ;;
    esac
  fi

  ST_PID=""
  if [[ "$ST_PROCS" == "1" ]]; then
    if [[ "$ST_AGENT_STATE" == "running" && -n "$agent_pid" ]]; then
      ST_PID="$agent_pid"
    elif [[ -n "$jpid" ]] && kill -0 "$jpid" 2>/dev/null; then
      ST_PID="$jpid"
    else
      ST_PID="$(fl_bench_process_pids | head -n1)"
    fi
  fi
}

fl_status_print_json() {
  printf '{'
  fl_state_core_json "$ST_STATE" "$ST_REASON" "$ST_PID" "$ST_STARTED" "$ST_EXIT" "$ST_PING"
  printf ',"ports":%s,"sites":%s,"scheduler":%s' "$(fl_ports_json)" "$(fl_sites_json)" "$(fl_json_bool "$(fl_scheduler_enabled && printf 1 || printf 0)")"
  printf ',"state_file":%s,"log":%s,"agent_loaded":%s,"agent_state":%s,"processes_running":%s' \
    "$(fl_json_str "$(fl_state_json_path)")" "$(fl_json_str "$(fl_bench_log_path)")" \
    "$(fl_json_bool "$ST_LOADED")" "$(fl_json_str "$ST_AGENT_STATE")" "$(fl_json_bool "$ST_PROCS")"
  # fields from frappe-mac 0.2.0, kept for older readers
  printf ',"url":%s,"agent":"%s","loaded":"%s","stop_flag":"%s","ping":"%s"}\n' \
    "$(fl_json_str "$(fl_site_url)")" "$(fl_agent_label)" \
    "$([[ "$ST_LOADED" == "1" ]] && printf yes || printf no)" "${ST_FLAG:-none}" "$ST_PING"
}

fl_ports_json() {
  printf '{"web":%s,"socketio":%s,"redis_queue":%s,"redis_socketio":%s,"redis_cache":%s}' \
    "$FL_WEB_PORT" "$FL_SOCKETIO_PORT" "$FL_REDIS_QUEUE_PORT" "${FL_REDIS_SOCKETIO_PORT:-$FL_REDIS_CACHE_PORT}" "$FL_REDIS_CACHE_PORT"
}

# ---------------------------------------------------------------- list

# Prints every bench folder benchbar knows about, one per line, remembered
# bench first: state.env, agents in ~/Library/LaunchAgents, auto-detection.
fl_known_benches() {
  local f d
  {
    fl_state_get BENCH_DIR 2>/dev/null || true
    for f in "$HOME"/Library/LaunchAgents/com.benchbar.*.plist "$HOME"/Library/LaunchAgents/com.frappe-mac.*.plist; do
      [[ -f "$f" ]] || continue
      fl_plist_working_dir "$f"
      printf '\n'
    done
    fl_bench_candidates
  } | while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    fl_is_bench_dir "$d" && fl_abs_path "$d" && printf '\n'
  done | awk 'NF && !seen[$0]++'
}

# fl_bench_load DIR: points the FL_* bench globals at DIR (site and ports
# from that bench, never from the environment). list is the only caller and
# exits afterwards, so nothing needs restoring.
fl_bench_load() {
  SITE_NAME=""; BENCH_DIR=""
  FL_WEB_PORT=8000; FL_SOCKETIO_PORT=9000; FL_REDIS_CACHE_PORT=13000; FL_REDIS_QUEUE_PORT=11000; FL_REDIS_SOCKETIO_PORT=""
  fl_bench_detect "$1"
  fl_site_detect ""
  fl_ports_detect
}

fl_list_entry_json() {
  local default="$1" installed=0 lock=""
  [[ -f "$(fl_agent_plist_path)" ]] && installed=1
  # the bench's lockfile: remembered or <bench>/benchbar.toml (BENCHBAR_LOCK names one bench, not all)
  if declare -F fl_lock_file_resolve >/dev/null; then
    fl_lock_file_resolve "" no-env
    [[ "$FL_LOCK_SOURCE" != "none" ]] && lock="$FL_LOCK_FILE"
  fi
  printf '{"path":%s,"name":%s,"site":%s,"label":"%s","web_url":%s,"ports":%s,"sites":%s,"default":%s,"service_installed":%s,"state_file":%s,"lock_file":%s}' \
    "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$FL_BENCH_NAME")" "$(fl_json_str "$FL_SITE")" "$(fl_agent_label)" \
    "$(fl_json_str "$(fl_site_url)")" "$(fl_ports_json)" "$(fl_sites_json)" \
    "$(fl_json_bool "$default")" "$(fl_json_bool "$installed")" "$(fl_json_str "$(fl_state_json_path)")" "$(fl_json_str "$lock")"
}

# fl_cmd_list JSON: the default bench is the one commands use without --bench-dir.
fl_cmd_list() {
  local json="${1:-0}" default="" d sep="" rows=() benches=() is_default
  fl_bench_detect "${OPT_BENCH_DIR:-}"
  fl_is_bench_dir "$FL_BENCH_DIR" && default="$FL_BENCH_DIR"
  while IFS= read -r d; do
    [[ -n "$d" ]] && benches+=("$d")
  done < <(fl_known_benches)
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
    fl_info "no benches found; create one with: ${SCRIPT_DIR}/benchbar install"
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
