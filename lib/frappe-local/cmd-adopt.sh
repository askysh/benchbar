#!/usr/bin/env bash
#
# cmd-adopt.sh: the body of "benchbar adopt" and the plan line of adopt --json. Moved
# out of the entry point as they were (CORE-18, issue 151). cmd_adopt is also called by
# port-management.sh (ports setup, ports apply). A lean start does not load this file.

# benchbar adopt PATH: register an existing bench without touching its data.
# Same engine as "service" (only the service group of checks and actions), so
# it never runs migrate, build, update or an env rebuild.
# adopt --json: the plan line, called by the repair engine once it knows the
# actions (FL_ENGINE_PLAN_HOOK). Its steps are the actions, numbered from 1.
fl_adopt_plan_json() {
  local a n=0 pl_steps="" move=false off mode=terminal token token_data code
  [[ "${FL_PM_APPLYING:-0}" != "1" ]] || return 0
  # the token of the plan: its actions and what they are made from (the
  # bench, the port block, the scheduler choice); service --apply TOKEN is
  # refused here, before any action runs, when it no longer matches
  off="${FL_PORT_TARGET:-$((FL_WEB_PORT - FL_PORT_BASE_WEB))}"
  token_data="$(printf '%s\n' "$FL_BENCH_DIR" "$1" "$off" "${FL_SCHEDULER:-}" "$FL_SITE")"
  # a ports plan previews this adopt run and takes the same fields into its own token (port-management.sh)
  if [[ -n "${FL_PM_PLAN_FILE:-}" ]]; then printf '%s\n' "${token_data//$'\n'/|}" >>"$FL_PM_PLAN_FILE" 2>/dev/null || true; fi
  fl_plan_token_v token "$token_data"
  if [[ -n "${FL_SERVICE_APPLY_TOKEN:-}" ]]; then
    code=0; fl_plan_token_check "$token_data" "$FL_SERVICE_APPLY_TOKEN" || code=$?
    case "$code" in
      0) ;;
      2) fl_die "$(fl_plan_token_expired_text)" "Review a fresh plan: benchbar service --dry-run --json --bench-dir ${FL_BENCH_DIR}, then pass its token." ;;
      *) fl_die "The service plan changed since it was shown (its actions, the ports or the scheduler). Nothing was changed." \
        "Review a fresh plan: benchbar service --dry-run --json --bench-dir ${FL_BENCH_DIR}, then pass its token." ;;
    esac
  fi
  for a in $1; do
    n=$((n + 1))
    pl_steps="${pl_steps}${pl_steps:+,}{\"n\":${n},\"id\":\"${a}\",\"name\":$(fl_json_str "$(fl_action_label "$a")"),\"sudo\":$(fl_json_bool "$(fl_action_needs_sudo "$a" && printf 1 || printf 0)"),\"will_run\":true}"
  done
  case " $1 " in *" port_block "*) move=true ;; esac
  fl_sudo_gui && mode=gui
  fl_jsonl plan ",\"bench\":$(fl_json_str "$FL_BENCH_DIR"),\"site\":$(fl_json_str "$FL_SITE"),\"profile\":$(fl_json_str "$FL_PROFILE"),\"port_offset\":$(fl_json_num "$off"),\"ports_move\":${move},\"dry_run\":$(fl_json_bool "$FL_DRY_RUN"),\"sudo_mode\":\"${mode}\",\"steps\":[${pl_steps}],\"token\":\"${token}\",\"log\":$(fl_json_str "${FL_LOG_FILE:-}")"
  FL_JSONL_PLAN_SENT=1
  [[ "$FL_DRY_RUN" != "1" ]] || FL_JSONL_QUIET=1
  export FL_JSONL_QUIET
}

cmd_adopt() {
  local path="${1:-}" bl_line bl_msg bl_fix
  [[ -n "$path" ]] || fl_die "Usage: benchbar adopt <bench path>" "Example: benchbar adopt ~/frappe-bench"
  path="$(fl_abs_path "$path")"
  fl_bench_path_valid "$path"
  fl_is_bench_dir "$path" || fl_die "${path} is not a bench (no sites/common_site_config.json and no apps/frappe)." "Point adopt at the folder that holds apps/, sites/ and env/."
  fl_context_init "$path" "$OPT_SITE" "$OPT_PROFILE"
  fl_require_plain_bench
  # WSL: a bench on the Windows file system is refused here, as install does
  bl_line="$(fl_bench_windows_fs_blocker "$FL_BENCH_DIR")"
  if [[ -n "$bl_line" ]]; then
    IFS='|' read -r FL_ERROR_ID bl_msg bl_fix <<<"$bl_line"
    FL_ERROR_FIX="$bl_fix"
    fl_die "$bl_msg" "$bl_fix"
  fi
  FL_JSONL_BENCH="$FL_BENCH_DIR"; FL_JSONL_SITE="$FL_SITE"
  fl_header "benchbar adopt" "$(fl_mode_name)" "$(fl_profile_display)" "$FL_BENCH_DIR" "$FL_SITE"
  fl_info "adopt only adds the background service files and remembers the bench."
  fl_info "apps/, env/, the sites and the databases are not touched; migrate, build and update never run."
  fl_info "only when another bench uses the same ports (or --port-offset is given) does it move the ports, with bench set-config -g."
  if [[ -z "$FL_HONCHO" ]]; then
    fl_warn "honcho was not found on PATH, in the pipx venv of frappe-bench or in ${FL_BENCH_DIR}/env; adopt does not install into env"
    fl_fix "pipx install honcho   (or: ${FL_SELF} repair, which installs it into the bench env), then benchbar adopt again"
  fi
  fl_ports_plan "$OPT_PORT_OFFSET" || return 1
  # the service group would install honcho into env when it is missing; adopt must not
  if FL_PLAN_CHECKS="port_block" FL_ENGINE_SKIP_ACTIONS="honcho_install honcho_setuptools" FL_ENGINE_PLAN_HOOK=fl_adopt_plan_json \
     fl_repair_engine "Adopt" service; then
    FL_JSONL_URL="$(fl_site_url)"
    fl_pm_remember
    # remembered only now: a cancelled plan must not make this the default bench
    if fl_remember_bench; then
      [[ "$FL_DRY_RUN" == "1" ]] || fl_ok "remembered ${FL_BENCH_DIR} (site ${FL_SITE}) as the default bench"
    else
      [[ "$FL_DRY_RUN" == "1" ]] || fl_ok "remembered ${FL_BENCH_DIR} (site ${FL_SITE}); the default bench stays $(fl_state_get BENCH_DIR) (--make-default changes it)"
    fi
    fl_next_steps_box
    return 0
  fi
  return 1
}
