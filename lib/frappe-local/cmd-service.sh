#!/usr/bin/env bash
#
# cmd-service.sh: the body of "benchbar service". Moved out of the entry point as it
# was (CORE-18, issue 151). The service files and the engine are service.sh and
# repair.sh. A lean start does not load this file.

cmd_service() {
  local i=0
  # --apply TOKEN: run the plan a dry run showed, refused when it changed since
  # (fl_adopt_plan_json compares, before any action runs)
  FL_SERVICE_APPLY_TOKEN=""
  while [[ "$i" -lt "${#ARGS[@]}" ]]; do
    case "${ARGS[$i]}" in
      --apply) FL_SERVICE_APPLY_TOKEN="${ARGS[$((i + 1))]:-}"; i=$((i + 2)) ;;
      --apply=*) FL_SERVICE_APPLY_TOKEN="${ARGS[$i]#*=}"; i=$((i + 1)) ;;
      # anything else was ignored before; it still is
      *) i=$((i + 1)) ;;
    esac
  done
  if [[ -n "$FL_SERVICE_APPLY_TOKEN" || " ${ARGS[*]:-} " == *" --apply "* ]]; then
    [[ "$FL_SERVICE_APPLY_TOKEN" =~ ^[0-9a-f]{64}$ ]] || fl_die "--apply needs the token of a plan." "benchbar service --dry-run --json prints it"
    [[ "${FL_DRY_RUN:-0}" != "1" ]] || fl_die "--apply runs the plan; --dry-run shows it. Pass one of them."
    [[ "${FL_ASSUME_YES:-0}" == "1" ]] || fl_die "Review the plan (service --dry-run --json), then pass its token with --apply TOKEN --yes."
    # a scheduler choice that comes with a token (the one the dry run was made with) is only
    # kept in memory while the token is checked; it is stored once the run has succeeded
  fi
  fl_context_init "$OPT_BENCH_DIR" "$OPT_SITE" "$OPT_PROFILE"
  fl_require_bench
  fl_require_plain_bench
  fl_header "benchbar service" "$(fl_mode_name)" "$(fl_profile_display)" "$FL_BENCH_DIR" "$FL_SITE"
  # validate a requested block before anything is remembered
  if [[ -n "$OPT_PORT_OFFSET" ]]; then
    fl_ports_plan "$OPT_PORT_OFFSET" || return 1
  fi
  fl_remember_bench || true
  if [[ -n "$FL_SCHEDULER" ]]; then
    # stored now (not in a dry run) and rendered for the plan either way; with a token it is stored
    # only after the plan was checked and the run succeeded (a stale token must change nothing)
    [[ -n "${FL_SERVICE_APPLY_TOKEN:-}" ]] || fl_bstate_set SCHEDULER "$FL_SCHEDULER"
    fl_render_all
  fi
  if FL_PLAN_CHECKS="port_block" FL_ENGINE_PLAN_HOOK=fl_adopt_plan_json fl_repair_engine "Background service" service; then
    fl_pm_remember
    [[ -z "$FL_SCHEDULER" || -z "${FL_SERVICE_APPLY_TOKEN:-}" ]] || fl_bstate_set SCHEDULER "$FL_SCHEDULER"
    if [[ -n "$FL_SCHEDULER" && "${FL_DRY_RUN:-0}" != "1" ]] && fl_bench_is_running; then
      fl_warn "the running bench still uses the old Procfile.lean; run: benchbar restart --bench-dir ${FL_BENCH_DIR}"
    fi
    fl_next_steps_box
    return 0
  fi
  return 1
}
