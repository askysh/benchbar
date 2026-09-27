#!/usr/bin/env bash
# shellcheck disable=SC2034 # shared command state
# Transaction preview for a selection. Plans are read-only; apply recomputes
# under the CLI's global lock before invoking the existing adoption engine.

fl_pm_remember() {
  fl_bstate_set PORT_MODE "$(fl_pm_mode "$FL_BENCH_DIR")"
  fl_bstate_set PORT_RESERVATION "$(fl_pm_current)"
}
fl_pm_mode() { local m; m="$(fl_bstate_get_for "$1" PORT_MODE)"; printf '%s' "${m:-automatic}"; }
fl_pm_current() { printf '%s %s %s %s' "$FL_WEB_PORT" "$FL_SOCKETIO_PORT" "$FL_REDIS_QUEUE_PORT" "$FL_REDIS_CACHE_PORT"; }
fl_pm_ports_json() { local a b c d; read -r a b c d <<<"$1"; printf '{"web":%s,"socketio":%s,"redis_queue":%s,"redis_cache":%s}' "$a" "$b" "$c" "$d"; }
fl_pm_strings_json() {
  local line sep=""; printf '['
  while IFS= read -r line; do [[ -n "$line" ]] || continue; printf '%s%s' "$sep" "$(fl_json_str "$line")"; sep=,; done <<<"$1"
  printf ']'
}
fl_pm_selected() { local p; for p in "${PM_PATHS[@]}"; do [[ "$p" != "$1" ]] || return 0; done; return 1; }
fl_pm_reserve() { local p; for p in $2; do PM_TAKEN="${PM_TAKEN}${p} $1"$'\n'; done; }
fl_pm_conflicts() {
  local p pid row owner preferred=0
  fl_bench_established "$FL_BENCH_DIR" && preferred=1
  for p in $1; do
    while IFS= read -r row; do
      [[ "$row" == "$p "* && "${row#* }" != "$FL_BENCH_DIR" ]] || continue
      owner="${row#* }"
      if [[ "$preferred" == 1 ]] && printf '%s\n' "${PM_SOFT:-}" | grep -Fqx "$owner"; then continue; fi
      printf '%s reserved by %s\n' "$p" "$owner"
    done <<<"$PM_TAKEN"
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      if ! fl_pid_is_bench_own_strict "$pid"; then printf '%s has a listener: pid %s\n' "$p" "$pid"; fi
    done < <(lsof -ti "tcp:$p" -sTCP:LISTEN 2>/dev/null || true)
  done
  return 0
}
fl_pm_known_reservations() {
  local d current reserved
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    if [[ "${1:-}" == exclude-selected ]] && fl_pm_selected "$d"; then continue; fi
    current="$(fl_bench_load "$d"; fl_pm_current)"
    fl_pm_reserve "$d" "$current"
    reserved="$(fl_bstate_get_for "$d" PORT_RESERVATION)"
    if [[ -z "$reserved" && "$(fl_pm_mode "$d")" != fixed ]] && ! fl_bench_established "$d"; then PM_SOFT="${PM_SOFT:-}${d}"$'\n'; fi
    [[ -z "$reserved" || "$reserved" == "$current" ]] || fl_pm_reserve "$d" "$reserved"
  done < <(fl_known_benches)
}
fl_pm_running() {
  local pid
  # A listening socket alone is not proof of ownership. Foreign listeners
  # are conflicts to resolve, never a reason to claim this bench is running.
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    fl_pid_is_bench_own_strict "$pid" && return 0
  done < <(fl_bench_process_pids)
  [[ -n "$(pgrep -f "$(fl_bench_helper_pattern)" 2>/dev/null || true)" ]]
}
fl_pm_build() {
  local d i mode current proposed conflicts blocked installed n found priority rows="" sep="" evidence=""
  PM_PATHS=(); PM_TARGETS=(); PM_TAKEN=""; PM_SOFT=""; PM_CAN_APPLY=1
  [[ "$#" -gt 0 ]] || { fl_fail 'Select at least one bench.' >&2; return 1; }
  for d in "$@"; do
    d="$(fl_abs_path "$d")"
    case "$d" in *$'\n'*|*$'\r'*) fl_fail 'Bench paths cannot contain newlines.' >&2; return 1 ;; esac
    fl_is_bench_dir "$d" || { fl_fail "Not a bench: $d" >&2; return 1; }
    if [[ "${#PM_PATHS[@]}" == 0 ]] || ! fl_pm_selected "$d"; then PM_PATHS+=("$d"); fi
  done
  # Canonical ordering makes the outcome independent of selection order.
  local sorted=()
  while IFS= read -r d; do sorted+=("$d"); done < <(printf '%s\n' "${PM_PATHS[@]}" | LC_ALL=C sort)
  PM_PATHS=("${sorted[@]}")
  fl_pm_known_reservations exclude-selected
  # Reserve current allocations before looking for replacements. Otherwise an
  # early conflicting bench could steal a later bench's perfectly usable URL.
  # Fixed claims come first; established automatic benches precede newcomers.
  for d in "${PM_PATHS[@]}"; do
    if [[ "$(fl_pm_mode "$d")" == fixed ]]; then
      fl_bench_load "$d"; fl_pm_reserve "$d" "$(fl_pm_current)"
    fi
  done
  for priority in established newcomer; do
    for d in "${PM_PATHS[@]}"; do
      [[ "$(fl_pm_mode "$d")" != fixed ]] || continue
      if fl_bench_established "$d"; then [[ "$priority" == established ]] || continue
      else [[ "$priority" == newcomer ]] || continue; fi
      fl_bench_load "$d"; current="$(fl_pm_current)"
      [[ -n "$(fl_pm_conflicts "$current")" ]] || fl_pm_reserve "$d" "$current"
    done
  done
  for d in "${PM_PATHS[@]}"; do
    fl_bench_load "$d"
    mode="$(fl_pm_mode "$d")"; current="$(fl_pm_current)"; proposed="$current"; blocked=""; installed=0
    [[ ! -f "$(fl_agent_plist_path)" ]] || installed=1
    conflicts="$(fl_pm_conflicts "$current")"
    if fl_pm_running; then blocked='Stop this bench before setting up management or changing its ports.'
    elif [[ -n "$conflicts" && "$mode" == fixed ]]; then blocked='Fixed ports conflict. Choose Automatic or free the reserved ports.'
    elif [[ -n "$conflicts" ]]; then
      found=0; n=0
      while [[ "$n" -le "$FL_PORT_MAX_OFFSET" ]]; do
        proposed="$(fl_port_block "$n")"
        if [[ -z "$(fl_pm_conflicts "$proposed")" ]]; then found=1; break; fi
        n=$((n + 1))
      done
      [[ "$found" == 1 ]] || { blocked="No free port block between 0 and ${FL_PORT_MAX_OFFSET}."; proposed="$current"; }
    fi
    [[ -z "$blocked" ]] || PM_CAN_APPLY=0
    PM_TARGETS+=("$proposed")
    fl_pm_reserve "$d" "$proposed"
    rows="${rows}${sep}{\"path\":$(fl_json_str "$d"),\"name\":$(fl_json_str "$FL_BENCH_NAME"),\"site\":$(fl_json_str "$FL_SITE"),\"mode\":$(fl_json_str "$mode"),\"current\":$(fl_pm_ports_json "$current"),\"proposed\":$(fl_pm_ports_json "$proposed"),\"conflicts\":$(fl_pm_strings_json "$conflicts"),\"blocked\":$(fl_json_str "$blocked"),\"service_installed\":$(fl_json_bool "$installed")}"; sep=,
  done
  # Config and ownership changes invalidate approval even if the proposed ports
  # happen to remain equal. Never include configuration contents in JSON.
  evidence="$(while IFS= read -r d; do printf '%s\n' "$d"; cksum "$d/sites/common_site_config.json" "$(fl_bench_state_file_for "$d")" 2>/dev/null || true; done < <({ fl_known_benches; printf '%s\n' "${PM_PATHS[@]}"; } | LC_ALL=C sort -u))"
  PM_TOKEN="$( { printf '%s\n%s' "$rows" "$evidence"; cksum "$FL_STATE_FILE" "$HOME"/Library/LaunchAgents/com.benchbar.*.plist 2>/dev/null || true; } | shasum -a 256 | awk '{print $1}')"
  PM_JSON="{\"schema_version\":1,\"token\":\"$PM_TOKEN\",\"entries\":[$rows],\"can_apply\":$(fl_json_bool "$PM_CAN_APPLY") }"
}
fl_pm_check() {
  PM_TAKEN=""; PM_SOFT=""; fl_pm_known_reservations
  PM_CONFLICTS="$(fl_pm_conflicts "$(fl_pm_current)")"
}
fl_cmd_ports() {
  local sub="${1:-}" token mode i d current offset
  [[ "$#" == 0 ]] || shift
  case "$sub" in
    plan) fl_pm_build "$@" || return 1; printf '%s\n' "$PM_JSON" ;;
    check)
      fl_bench_load "${OPT_BENCH_DIR:-}"; fl_require_bench; fl_pm_check
      printf '{"schema_version":1,"conflicts":%s,"mode":%s}\n' "$(fl_pm_strings_json "$PM_CONFLICTS")" "$(fl_json_str "$(fl_pm_mode "$FL_BENCH_DIR")")" ;;
    mode)
      mode="${1:-}"; [[ "$mode" == automatic || "$mode" == fixed ]] || { fl_fail 'Mode must be automatic or fixed.'; return 1; }
      fl_bench_load "${OPT_BENCH_DIR:-}"; fl_require_bench
      fl_bstate_set PORT_MODE "$mode"; fl_bstate_set PORT_RESERVATION "$(fl_pm_current)"
      fl_ok "Port mode: $mode. Existing ports are unchanged." ;;
    apply)
      token="${1:-}"; [[ "$#" == 0 ]] || shift
      [[ "${FL_ASSUME_YES:-0}" == 1 ]] || { fl_fail 'Review ports plan, then pass its token with --yes.'; return 1; }
      fl_pm_build "$@" || return 1
      [[ "$token" == "$PM_TOKEN" ]] || { fl_fail 'The port plan changed. Review a fresh preview before applying.'; return 1; }
      [[ "$PM_CAN_APPLY" == 1 ]] || { fl_fail 'The port plan contains blocked benches. Nothing was changed.'; return 1; }
      # Resolve every selected bench's profile/tools before the first write.
      # Adopt deliberately cannot install missing honcho into an existing env.
      for d in "${PM_PATHS[@]}"; do
        fl_bench_load "$d"; fl_context_init "$d" "" ""
        [[ -n "$FL_HONCHO" ]] || { fl_fail "Honcho is missing for $d. Install it before setting up management; nothing was changed."; return 1; }
      done
      for ((i=0; i<${#PM_PATHS[@]}; i++)); do
        d="${PM_PATHS[$i]}"; fl_bench_load "$d"; current="$(fl_pm_current)"; offset=""
        if [[ "$current" != "${PM_TARGETS[$i]}" ]]; then read -r offset _ <<<"${PM_TARGETS[$i]}"; offset=$((offset - FL_PORT_BASE_WEB)); fi
        if fl_pm_running || [[ -n "$(fl_pm_conflicts "${PM_TARGETS[$i]}")" ]]; then
          fl_fail "Ports or running state changed for $d. Review a fresh plan; earlier completed benches remain configured."; return 1
        fi
        fl_info "Setting up $((i + 1))/${#PM_PATHS[@]}: $d"
        # Do not let adopt silently pick a different block from the approved
        # batch. The entire selection was validated under this same lock.
        if ! FL_PORT_PLAN_APPROVED=1 OPT_PORT_OFFSET="$offset" cmd_adopt "$d"; then
          fl_fail "Setup failed: $d. Earlier completed benches remain configured; review a fresh plan to continue."; return 1
        fi
        OPT_JSON=0 fl_cmd_register "$d"
        fl_bstate_set PORT_MODE "$(fl_pm_mode "$d")"
        fl_bstate_set PORT_RESERVATION "$(fl_pm_current)"
        fl_ok "Completed: $d"
      done ;;
    *) fl_fail 'Usage: benchbar ports plan|apply|check|mode'; return 1 ;;
  esac
}
