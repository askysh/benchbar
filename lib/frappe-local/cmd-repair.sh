#!/usr/bin/env bash
#
# cmd-repair.sh: the body of "benchbar repair". Moved out of the entry point as it was
# (CORE-18, issue 151). The engine is repair.sh; fl_repair_done, the done line of
# repair --json, stays in the entry point for now because the exit trap calls it
# on a lean start too. A lean start does not load this file.

# repair --json: events on stdout (docs/json-schema.md), the human text in
# the run's log. Without --yes or --dry-run nothing is applied: a reader
# that cannot answer the question gets the plan and exit code 1.
cmd_repair() {
  local code=0
  # the events start first: a missing bench is a done line with exit 1, not silence
  if [[ "$OPT_JSON" == "1" ]]; then
    # fd 4 keeps the real stderr: a refusal says why there too (the app summarizes it)
    exec 4>&2 3>&1 1>>"${FL_LOG_FILE:-/dev/null}" 2>&1
    FL_JSON_EVENTS=1
    FL_PLAIN=1; fl_ui_init
    # the question would be invisible (the text goes to the log): without
    # --yes it is answered no
    [[ "$FL_ASSUME_YES" == "1" ]] || exec 0</dev/null
  fi
  fl_sudo_env_preflight
  fl_plan_apply_parse repair
  fl_context_init "$OPT_BENCH_DIR" "$OPT_SITE" "$OPT_PROFILE"
  fl_require_bench
  fl_require_plain_bench
  fl_header "benchbar repair" "$(fl_mode_name)" "$(fl_profile_display)" "$FL_BENCH_DIR" "$FL_SITE"
  FL_ENGINE_TOKEN_KIND=repair fl_repair_engine "Repair" || code=$?
  return "$code"
}
