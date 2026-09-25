#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# service.sh: context for one bench (paths, profile, rendered templates) and
# the daily commands: up, down, restart, status, logs, fg, watch, autostart,
# uninstall-service.

FL_R_RUNNER=""
FL_R_PLIST=""
FL_R_PROCFILE=""
FL_R_HELPERS=""
FL_CRASH_MAX_STARTS="${FL_CRASH_MAX_STARTS:-3}"
FL_CRASH_WINDOW="${FL_CRASH_WINDOW:-600}"
FL_UP_WAIT_SECS="${FL_UP_WAIT_SECS:-45}"

# fl_context_init [BENCH_DIR_FLAG] [SITE_FLAG] [PROFILE_FLAG]
fl_context_init() {
  local profile="${3:-}"
  fl_bench_detect "${1:-}"
  fl_site_detect "${2:-}"
  fl_ports_detect
  [[ -n "$profile" ]] || profile="$(fl_bstate_get PROFILE 2>/dev/null || true)"
  [[ -n "$profile" ]] || profile="$(fl_profile_detect "$FL_BENCH_DIR")"
  [[ -n "$profile" ]] || profile="$(fl_default_profile)"
  fl_load_profile "$profile"
  if command -v brew >/dev/null 2>&1; then
    FL_BREW_PREFIX="$(brew --prefix 2>/dev/null || printf '/opt/homebrew')"
  else
    FL_BREW_PREFIX="${FL_BREW_PREFIX:-/opt/homebrew}"
  fi
  FL_ARCH="$(uname -m)"
  fl_honcho_resolve || true
  fl_render_all
}

# The profile the shell block's PATH follows: the default bench's, so
# setting up a second bench never changes the Python and Node of the shell.
fl_rc_profile() {
  local def p=""
  def="$(fl_state_get BENCH_DIR 2>/dev/null || true)"
  # --make-default: this bench is (or, in a dry run, would be) the default
  if [[ -z "$def" || "$def" == "$FL_BENCH_DIR" || ! -d "$def" || "${FL_MAKE_DEFAULT:-0}" == "1" ]]; then
    printf '%s' "$FL_PROFILE"
    return 0
  fi
  p="$(fl_bstate_get_for "$def" PROFILE)"
  [[ -n "$p" ]] || p="$(fl_profile_detect "$def")"
  printf '%s' "${p:-$FL_PROFILE}"
}

fl_autostart_enabled() {
  [[ "$(fl_bstate_get AUTOSTART 2>/dev/null || true)" != "off" ]]
}

fl_render_all() {
  local honcho="${FL_HONCHO:-${FL_BENCH_DIR}/env/bin/honcho}" run_at_load=true
  fl_autostart_enabled || run_at_load=false
  FL_R_PROCFILE="$(fl_template_render Procfile.lean "WEB_PORT=${FL_WEB_PORT}")"
  FL_R_RUNNER="$(fl_template_render bench-run.sh \
    "BENCH_DIR=${FL_BENCH_DIR}" \
    "BENCH_RE=$(fl_regex_escape "$FL_BENCH_DIR")" \
    "BENCH_NAME=${FL_BENCH_NAME}" \
    "HONCHO=${honcho}" \
    "PORTS=$(fl_bench_ports_csv)" \
    "SITE=${FL_SITE}" \
    "WEB_PORT=${FL_WEB_PORT}" \
    "CLI_VERSION=${FL_VERSION:-0}" \
    "LABEL=$(fl_agent_label)" \
    "MAX_STARTS=${FL_CRASH_MAX_STARTS}" \
    "WINDOW=${FL_CRASH_WINDOW}")"
  FL_R_PLIST="$(fl_template_render launchagent.plist \
    "LABEL=$(fl_agent_label)" \
    "APP_BUNDLE_ID=${FL_APP_BUNDLE_ID}" \
    "RUNNER=$(fl_runner_path)" \
    "BENCH_DIR=${FL_BENCH_DIR}" \
    "PATH=$(fl_launchd_path_value)" \
    "RUN_AT_LOAD=${run_at_load}" \
    "LOG=$(fl_bench_log_path)")"
  FL_R_HELPERS="$(fl_template_render shell-helpers \
    "PROFILE_EXPORTS=$(fl_profile_path_exports "$(fl_rc_profile)")" \
    "BENCHBAR=${SCRIPT_DIR}/benchbar")"
}

fl_require_bench() {
  fl_is_bench_dir "$FL_BENCH_DIR" || fl_die "No bench at ${FL_BENCH_DIR}." "Run: ${SCRIPT_DIR}/benchbar install, or pass --bench-dir <path>."
}

fl_require_service() {
  fl_require_bench
  [[ -f "$(fl_runner_path)" && -f "$(fl_agent_plist_path)" ]] && return 0
  # a bench set up before the rename still has its com.frappe-mac agent:
  # it is installed, it only needs the one time migration
  local list legacy
  list="$(fl_legacy_agents_list)"
  legacy="${list%%$'\n'*}"; legacy="${legacy#*|}"; legacy="${legacy%%|*}"
  if [[ -n "$legacy" ]]; then
    fl_die "${FL_BENCH_NAME} still uses the old agent ${legacy}, from before the BenchBar rename." \
      "Run: ${SCRIPT_DIR}/benchbar repair (moves the old agent aside and installs $(fl_agent_label); sites and data are not touched)."
  fi
  fl_die "The background service for ${FL_BENCH_NAME} is not installed." "Run: ${SCRIPT_DIR}/benchbar service (or benchbar install)."
}

fl_site_url() { printf 'http://%s:%s' "$FL_SITE" "$FL_WEB_PORT"; }

fl_wait_for_ping() {
  local secs="${1:-$FL_UP_WAIT_SECS}" i=0 code
  while [[ "$i" -lt "$secs" ]]; do
    code="$(fl_site_ping_code)"
    [[ "$code" == "200" ]] && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

fl_stop_flag_reason() {
  local flag
  flag="$(fl_stop_flag_path)"
  [[ -f "$flag" ]] || return 0
  tr -d "[:space:]" <"$flag" 2>/dev/null || true
}

fl_arm_start() {
  # removes the stop flag and the crash history; keeps the tail of the old log
  local flag hist log prev
  flag="$(fl_stop_flag_path)"; hist="$(fl_starts_path)"; log="$(fl_bench_log_path)"
  prev="${FL_BENCH_DIR}/logs/bench.previous.log"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would remove ${flag}, clear ${hist} and rotate ${log}"
    return 0
  fi
  mkdir -p "${FL_BENCH_DIR}/logs"
  rm -f "$flag"
  : >"$hist"
  if [[ -s "$log" ]]; then
    tail -n 500 "$log" >"$prev" 2>/dev/null || true
    : >"$log"
  fi
}

fl_check_port_clash_or_confirm() {
  local clash
  clash="$(fl_port_clash_running)"
  [[ -z "$clash" ]] && return 0
  fl_warn "another running bench uses the same port:${clash}"
  fl_confirm "Start anyway?" || return 1
}

fl_cmd_up() {
  fl_require_service
  if fl_bench_is_running; then
    fl_ok "bench ${FL_BENCH_NAME} is already running at $(fl_site_url)"
    return 0
  fi
  fl_check_port_clash_or_confirm || return 1
  fl_arm_start
  if ! fl_agent_loaded; then
    fl_info "agent not loaded; loading $(fl_agent_plist_path)"
    fl_agent_bootstrap "$(fl_agent_plist_path)" || fl_die "launchctl could not load the agent." "Run: ${SCRIPT_DIR}/benchbar repair"
  fi
  fl_state_json_write starting "" "" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "" ""
  fl_agent_kickstart || fl_die "launchctl kickstart failed." "Run: ${SCRIPT_DIR}/benchbar doctor"
  [[ "${FL_DRY_RUN:-0}" == "1" ]] && return 0
  fl_spinner_start "starting bench ${FL_BENCH_NAME}" "$(fl_bench_log_path)"
  if fl_wait_for_ping "$FL_UP_WAIT_SECS"; then
    fl_spinner_stop
    fl_ok "bench is up: $(fl_site_url)"
  else
    fl_spinner_stop
    fl_warn "no 200 from $(fl_site_url)/api/method/ping after ${FL_UP_WAIT_SECS}s; it may still be starting"
    fl_fix "${SCRIPT_DIR}/benchbar logs"
    return 1
  fi
}

fl_cmd_down() {
  local flag
  fl_require_bench
  flag="$(fl_stop_flag_path)"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would write 'manual' to ${flag}, send SIGTERM to the agent, then stop leftover bench processes"
    return 0
  fi
  mkdir -p "$(dirname "$flag")"
  printf 'manual\n' >"$flag"
  if fl_agent_loaded; then fl_agent_signal SIGTERM; fi
  if ! fl_bench_wait_stopped 8; then
    fl_bench_kill_processes TERM
    if ! fl_bench_wait_stopped 5; then
      fl_bench_kill_processes KILL
      sleep 1
    fi
  fi
  if fl_bench_is_running; then
    fl_fail "some bench processes are still alive: $(fl_bench_process_pids | tr '\n' ' ')"
    return 1
  fi
  fl_state_json_write stopped manual "" "$(fl_state_json_get started_at)" "$(fl_state_json_get last_exit_code)" ""
  fl_ok "bench ${FL_BENCH_NAME} stopped (auto-restart off until benchup)"
}

fl_cmd_restart() {
  fl_require_service
  fl_arm_start
  if ! fl_agent_loaded; then
    fl_agent_bootstrap "$(fl_agent_plist_path)" || fl_die "launchctl could not load the agent."
  fi
  fl_state_json_write starting "" "" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "" ""
  fl_agent_kickstart -k || fl_die "launchctl kickstart -k failed."
  [[ "${FL_DRY_RUN:-0}" == "1" ]] && return 0
  fl_spinner_start "restarting bench ${FL_BENCH_NAME}" "$(fl_bench_log_path)"
  if fl_wait_for_ping "$FL_UP_WAIT_SECS"; then
    fl_spinner_stop
    fl_ok "bench restarted: $(fl_site_url)"
  else
    fl_spinner_stop
    fl_warn "no 200 from $(fl_site_url)/api/method/ping after ${FL_UP_WAIT_SECS}s"
    fl_fix "${SCRIPT_DIR}/benchbar logs"
    return 1
  fi
}

fl_cmd_status() {
  local json="${1:-0}"
  fl_require_bench
  fl_status_compute
  if [[ "$json" == "1" ]]; then
    fl_status_print_json
    return 0
  fi
  fl_table \
    "bench|${FL_BENCH_DIR}" \
    "site|$(fl_site_url)" \
    "state|${ST_STATE}${ST_PID:+, pid ${ST_PID}}${ST_REASON:+ (${ST_REASON})}${ST_EXIT:+, last exit code ${ST_EXIT}}" \
    "agent|$(fl_agent_label) (loaded: $([[ "$ST_LOADED" == "1" ]] && printf yes || printf no)${ST_AGENT_STATE:+, ${ST_AGENT_STATE}})" \
    "stop flag|${ST_FLAG:-none (auto-restart armed)}" \
    "processes|$([[ "$ST_PROCS" == "1" ]] && printf yes || printf no)" \
    "web ping|${ST_PING}" \
    "ports|web ${FL_WEB_PORT}, socketio ${FL_SOCKETIO_PORT}, redis ${FL_REDIS_QUEUE_PORT}/${FL_REDIS_CACHE_PORT}" \
    "log|$(fl_bench_log_path)"
  if [[ "$ST_PING" == "200" ]]; then
    fl_ok "site responds"
  elif [[ "$ST_PROCS" == "1" ]]; then
    fl_warn "processes are running but the site does not respond (ping ${ST_PING}); see: ${SCRIPT_DIR}/benchbar logs"
  else
    case "$ST_FLAG" in
      crash) fl_warn "auto-restart paused after repeated crashes; run: ${SCRIPT_DIR}/benchbar logs, fix, then benchup" ;;
      broken) fl_warn "auto-restart paused: run ${SCRIPT_DIR}/benchbar repair, then benchup" ;;
      *) fl_info "bench is stopped; start with benchup" ;;
    esac
  fi
}

fl_cmd_logs() {
  local file lines=50 follow=1 arg
  fl_require_bench
  file="$(fl_bench_log_path)"
  for arg in "$@"; do
    case "$arg" in
      --worker) file="${FL_BENCH_DIR}/logs/worker.log" ;;
      --worker-error) file="${FL_BENCH_DIR}/logs/worker.error.log" ;;
      --previous) file="${FL_BENCH_DIR}/logs/bench.previous.log" ;;
      --no-follow) follow=0 ;;
      -n*) lines="${arg#-n}" ;;
      [0-9]*) lines="$arg" ;;
    esac
  done
  [[ -f "$file" ]] || { fl_warn "no log yet at ${file}"; return 0; }
  if [[ "$follow" == "1" && -t 1 ]]; then
    exec tail -n "$lines" -f "$file"
  fi
  tail -n "$lines" "$file"
}

fl_cmd_fg() {
  fl_require_bench
  [[ -n "$FL_HONCHO" ]] || fl_die "honcho not found." "Run: ${SCRIPT_DIR}/benchbar repair"
  [[ -f "$(fl_procfile_path)" ]] || fl_die "Procfile.lean missing." "Run: ${SCRIPT_DIR}/benchbar service"
  fl_cmd_down >/dev/null 2>&1 || true
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: cd ${FL_BENCH_DIR} && ${FL_HONCHO} start -f Procfile.lean"
    return 0
  fi
  fl_info "running in the foreground; Ctrl+C stops it (benchup brings the background service back)"
  cd "$FL_BENCH_DIR" || exit 1
  OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES NO_PROXY='*' exec "$FL_HONCHO" start -f Procfile.lean
}

fl_cmd_watch() {
  fl_require_bench
  fl_bench_env_exports
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: cd ${FL_BENCH_DIR} && bench watch"
    return 0
  fi
  cd "$FL_BENCH_DIR" || exit 1
  exec bench watch
}

fl_cmd_autostart() {
  local mode="${1:-}"
  fl_require_service
  case "$mode" in
    on|off) ;;
    "") if fl_autostart_enabled; then fl_ok "autostart is on (bench returns after login if it was running)"; else fl_ok "autostart is off"; fi; return 0 ;;
    *) fl_die "Usage: benchbar autostart on|off" ;;
  esac
  fl_bench_state_migrate "$FL_BENCH_DIR"
  fl_bstate_set AUTOSTART "$mode"
  fl_render_all
  act_write_plist || return 1
  fl_ok "autostart ${mode}"
}

fl_cmd_uninstall_service() {
  local plist rc dest
  fl_require_bench
  plist="$(fl_agent_plist_path)"
  rc="$(fl_rc_file)"
  fl_info "This removes the launchd agent, runner, Procfile.lean and the shell helper block."
  fl_info "The bench, its sites, apps and databases are not touched."
  fl_confirm "Uninstall the background service for ${FL_BENCH_NAME}?" || { fl_warn "Cancelled."; return 1; }
  fl_cmd_down || true
  if fl_agent_loaded; then fl_agent_bootout || true; fi
  if [[ -f "$plist" ]]; then
    dest="${FL_LEGACY_DIR}/$(basename "$plist" .plist)-$(fl_backup_stamp)"
    if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then fl_info "dry-run: would move ${plist} to ${dest}/"; else mkdir -p "$dest"; mv "$plist" "$dest/"; fl_ok "moved ${plist} to ${dest}/"; fi
  fi
  fl_backup_file "$(fl_runner_path)"; [[ "${FL_DRY_RUN:-0}" == "1" || ! -f "$(fl_runner_path)" ]] || { rm -f "$(fl_runner_path)"; fl_ok "removed runner (backup: ${FL_LAST_BACKUP})"; }
  fl_backup_file "$(fl_runner_path_legacy)"; [[ "${FL_DRY_RUN:-0}" == "1" || ! -f "$(fl_runner_path_legacy)" ]] || { rm -f "$(fl_runner_path_legacy)"; fl_ok "removed the old runner (backup: ${FL_LAST_BACKUP})"; }
  fl_backup_file "$(fl_procfile_path)"; [[ "${FL_DRY_RUN:-0}" == "1" || ! -f "$(fl_procfile_path)" ]] || { rm -f "$(fl_procfile_path)"; fl_ok "removed Procfile.lean (backup: ${FL_LAST_BACKUP})"; }
  fl_rc_block_remove "$rc"
  [[ "${FL_DRY_RUN:-0}" == "1" ]] || fl_ok "removed the helper block from ${rc}"
  fl_ok "service uninstalled; start the bench by hand with: cd ${FL_BENCH_DIR} && bench start"
}
