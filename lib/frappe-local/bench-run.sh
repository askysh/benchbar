#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# bench-run.sh: benchbar run, the safe runner for bench commands.
#
#   benchbar run [--site S] [--timeout SECS] [--dry-run | --apply TOKEN --yes]
#       -- COMMAND [FLAGS]
#
# Runs one command of the allow list below as `bench [--site S] COMMAND ...`
# in the right bench, with the bench's own environment (the exports the
# console uses), under a deadline, its output in the run log, and the usual
# result: the done fields, plus the bench's own exit code and the tail of its
# output. A command that changes things goes through the plan and its token
# (the same rule as site restore): --dry-run --json prints the plan with a
# token, --apply TOKEN --yes runs exactly that plan. A command that only
# reads runs at once. Anything not on the list is refused with exit 64 and
# the list; the list is code, not a file a run could widen.
#
# Exit codes: 64 a refusal of the arguments (not on the list, a flag it does
# not take, no plan for a change); otherwise the bench command's own code
# (124 at the deadline), except 2 and 64, which benchbar keeps for itself and
# which are reported as 1 (command_exit has the real one).

# NAME~CHANGES~SITE~REDIS~BACKUP~TIMEOUT~TOUCHES~FLAGS~SUMMARY
# CHANGES: the command writes (it needs a plan). SITE: it needs --site or the
# default site. REDIS: it needs the bench's Redis (a changing run starts the
# setup Redis when the bench is stopped; a read only run says so instead).
# BACKUP: a database backup of the site is taken first. TIMEOUT: the default
# deadline in seconds. FLAGS: a comma list; NAME= takes a value. No command
# takes a positional word.
read -r -d '' FL_RUN_TABLE <<'TABLE' || true
migrate~yes~yes~yes~yes~1800~database,site_config~--skip-failing,--skip-search-index~bench migrate: patches, schema sync and fixtures of the site, after a backup of it.
clear-cache~yes~yes~yes~no~120~cache~~bench clear-cache: the site's cache.
clear-website-cache~yes~yes~yes~no~120~cache~~bench clear-website-cache: the site's website cache.
build~yes~no~no~no~1800~assets~--app=~bench build: the JS and CSS bundles of the bench, all apps or one with --app.
run-tests~yes~yes~yes~no~1800~database~--app=,--module=,--doctype=,--test=,--case=,--failfast~bench run-tests on a site. It writes test records into that site's database: use a throwaway site.
doctor~no~yes~yes~no~120~~~bench doctor: the site's workers and queued jobs. Needs the bench's Redis.
list-apps~no~yes~no~no~60~~--format=~bench list-apps: the apps installed on a site.
version~no~no~no~no~60~~~bench version: the apps of the bench and their versions.
TABLE

FL_RUN_MAX_TIMEOUT=7200
FL_RUN_TAIL_LINES=60
FL_RUN_TAIL_CHARS=8000
# the index in ARGS of the first word after "--" (the argument loop of benchbar sets it)
FL_RUN_SEP=""

RUN_CMD=""
RUN_ARGS=()
RUN_ARGV=()
RUN_SITE=""
RUN_APPLY=0
RUN_TOKEN_IN=""
RUN_TIMEOUT=0
RUN_EXECUTES=1
RUN_CHANGES="no"
RUN_NEEDS_SITE="no"
RUN_REDIS="no"
RUN_BACKUP="no"
RUN_DEFAULT_TIMEOUT=60
RUN_TOUCHES=""
RUN_FLAGS=""
RUN_SUMMARY=""
RUN_ERRORS=()
RUN_WARNINGS=()
RUN_CAN_APPLY=0
RUN_PLAN_BODY=""
RUN_PLAN_JSON=""
RUN_TOKEN=""
RUN_CODE=0
RUN_TIMED_OUT=0
RUN_RAN=0
RUN_ELAPSED=0
RUN_TAIL=""
RUN_TAIL_CUT=0
RUN_BACKUP_JSON="null"

# fl_run_names: the allowed commands, one per line
fl_run_names() { printf '%s\n' "$FL_RUN_TABLE" | awk -F'~' 'NF > 1 { print $1 }'; }

# fl_run_lookup NAME: loads the row of NAME into RUN_*; 1 when it is not listed
fl_run_lookup() {
  local name
  while IFS='~' read -r name RUN_CHANGES RUN_NEEDS_SITE RUN_REDIS RUN_BACKUP RUN_DEFAULT_TIMEOUT RUN_TOUCHES RUN_FLAGS RUN_SUMMARY; do
    [[ "$name" == "$1" ]] && return 0
  done <<<"$FL_RUN_TABLE"
  return 1
}

# fl_run_flag_kind FLAG: value or bool when the loaded command takes FLAG; 1 when not
fl_run_flag_kind() {
  local f flags
  IFS=',' read -r -a flags <<<"$RUN_FLAGS"
  for f in ${flags[@]+"${flags[@]}"}; do
    case "$f" in
      "$1=") printf value; return 0 ;;
      "$1") printf bool; return 0 ;;
    esac
  done
  return 1
}

# fl_run_why_never NAME: why a command that people ask for is not on the list
fl_run_why_never() {
  case "$1" in
    update) printf 'bench update pulls, migrates and restarts every app; it runs only when a person asks for it by name' ;;
    drop-site|reinstall|restore|new-site|archive-site) printf 'it deletes or replaces a site; use benchbar site drop, site restore or site add, which back up first' ;;
    set-admin-password|set-user-password|add-system-manager) printf 'it sets a login; a person does that' ;;
    console|shell|mariadb|db-console|jupyter) printf 'it is interactive or a shell into the site; a person runs benchbar console or benchbar db' ;;
    execute|add-to-hosts|remove-app|uninstall-app|install-app|get-app|setup|config|set-config) printf 'it runs arbitrary code or edits the bench and its config; use the benchbar command for it (app add, service, ...)' ;;
    *) printf 'it is not on the allow list' ;;
  esac
}

# fl_run_refuse WHY HINT: a refusal, exit 64, naming what is allowed
fl_run_refuse() {
  local names=() list
  read -r -a names <<<"$(fl_run_names | tr '\n' ' ')"
  list="${names[*]}"
  if [[ "${FL_JSONL:-0}" == "1" ]]; then
    FL_DOC="$(printf '{"schema_version":%d,"cli_version":"%s","refused":true,"allowed":%s}' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str_array "${names[@]}")")"
  fi
  fl_die "$1" "${2:+$2 }Allowed commands: ${list}." 64
}

# fl_run_value_ok VALUE: a flag's value is a plain word (a module path, a
# DocType name with spaces), never an option and never a path
fl_run_value_ok() {
  local re='^[A-Za-z0-9_][A-Za-z0-9_. :-]{0,199}$'
  [[ "$1" =~ $re ]]
}

# fl_run_prepare: reads the arguments (the ones before "--" are benchbar's,
# the ones after it are the bench command), checks them against the allow
# list and says whether the run changes things. Needs no bench; refuses with 64.
fl_run_prepare() {
  local i=0 n w kind val timeout_in="" usage="Use: benchbar run [--site S] [--timeout SECS] -- COMMAND [FLAGS]"
  RUN_APPLY=0; RUN_TOKEN_IN=""; RUN_ARGS=(); RUN_CMD=""
  [[ -n "$FL_RUN_SEP" ]] || fl_run_refuse "benchbar run needs -- before the bench command." "$usage"
  while [[ "$i" -lt "$FL_RUN_SEP" ]]; do
    w="${ARGS[$i]}"
    case "$w" in
      --timeout|--apply)
        [[ $((i + 1)) -lt "$FL_RUN_SEP" ]] || fl_run_refuse "${w} needs a value." "$usage"
        if [[ "$w" == "--timeout" ]]; then timeout_in="${ARGS[$((i + 1))]}"; else RUN_APPLY=1; RUN_TOKEN_IN="${ARGS[$((i + 1))]}"; fi
        i=$((i + 2)) ;;
      --timeout=*) timeout_in="${w#*=}"; i=$((i + 1)) ;;
      --apply=*) RUN_APPLY=1; RUN_TOKEN_IN="${w#*=}"; i=$((i + 1)) ;;
      *) fl_run_refuse "Unknown option for run: ${w}" "$usage" ;;
    esac
  done
  n="${#ARGS[@]}"
  [[ "$FL_RUN_SEP" -lt "$n" ]] || fl_run_refuse "benchbar run needs a bench command after --." "$usage"
  RUN_CMD="${ARGS[$FL_RUN_SEP]}"
  case "$RUN_CMD" in -*|*[!A-Za-z0-9-]*) fl_run_refuse "'${RUN_CMD}' is not a bench command name." "$usage" ;; esac
  fl_run_lookup "$RUN_CMD" || fl_run_refuse "benchbar run does not run '${RUN_CMD}': $(fl_run_why_never "$RUN_CMD")." ""
  i=$((FL_RUN_SEP + 1))
  while [[ "$i" -lt "$n" ]]; do
    w="${ARGS[$i]}"; val=""; kind=""; i=$((i + 1))
    case "$w" in
      --*=*) val="${w#*=}"; w="${w%%=*}"; kind="$(fl_run_flag_kind "$w")" || kind=""
             [[ "$kind" == "value" ]] || fl_run_refuse "${RUN_CMD} does not take ${w}$([[ "$kind" == bool ]] && printf ' with a value')." "It takes: ${RUN_FLAGS:-no flags}." ;;
      --*) kind="$(fl_run_flag_kind "$w")" || kind=""
           [[ -n "$kind" ]] || fl_run_refuse "${RUN_CMD} does not take ${w}." "It takes: ${RUN_FLAGS:-no flags}."
           if [[ "$kind" == "value" ]]; then
             [[ "$i" -lt "$n" ]] || fl_run_refuse "${w} needs a value." ""
             val="${ARGS[$i]}"; i=$((i + 1))
           fi ;;
      *) fl_run_refuse "${RUN_CMD} takes no argument '${w}'." "It takes: ${RUN_FLAGS:-no flags}." ;;
    esac
    if [[ -n "$val" || "$kind" == "value" ]]; then
      fl_run_value_ok "$val" || fl_run_refuse "The value of ${w} must be a plain word (letters, digits and . _ : - and spaces, not starting with -)." ""
      RUN_ARGS+=("$w" "$val")
    else
      RUN_ARGS+=("$w")
    fi
  done
  RUN_TIMEOUT="$RUN_DEFAULT_TIMEOUT"
  if [[ -n "$timeout_in" ]]; then
    [[ "$timeout_in" =~ ^[0-9]{1,5}$ && "$((10#$timeout_in))" -ge 1 && "$((10#$timeout_in))" -le "$FL_RUN_MAX_TIMEOUT" ]] \
      || fl_run_refuse "--timeout must be 1 to ${FL_RUN_MAX_TIMEOUT} seconds." ""
    RUN_TIMEOUT="$((10#$timeout_in))"
  fi
  [[ "$RUN_NEEDS_SITE" == "yes" || -z "$OPT_SITE" ]] || fl_run_refuse "${RUN_CMD} is not run for a site; leave out --site." ""
  RUN_EXECUTES=1
  [[ "${FL_DRY_RUN:-0}" != "1" ]] || RUN_EXECUTES=0
  if [[ "$RUN_APPLY" == "1" ]]; then
    [[ "$RUN_CHANGES" == "yes" ]] || fl_run_refuse "${RUN_CMD} only reads: there is no plan to apply." "Run it without --apply."
    [[ "$RUN_EXECUTES" == "1" ]] || fl_run_refuse "--apply runs the plan; --dry-run shows it. Pass one of them." ""
    [[ "$RUN_TOKEN_IN" =~ ^[0-9a-f]{64}$ ]] || fl_run_refuse "--apply needs the token of a plan." "benchbar run ... -- ${RUN_CMD} --dry-run --json prints it."
    [[ "${FL_ASSUME_YES:-0}" == "1" ]] || fl_run_refuse "Review the plan (--dry-run --json), then pass its token with --apply TOKEN --yes." ""
  elif [[ "$RUN_CHANGES" == "yes" && "$RUN_EXECUTES" == "1" ]]; then
    if [[ "${OPT_JSON:-0}" == "1" ]]; then
      fl_run_refuse "${RUN_CMD} changes things: a run with --json needs a reviewed plan." "benchbar run ... --dry-run --json -- ${RUN_CMD}, then --apply TOKEN --yes."
    fi
    # a run that cannot ask (an agent, a script with BENCHBAR_NONINTERACTIVE=1) goes through the
    # plan and its token too: a bare --yes is a person's own shortcut at a terminal
    if fl_noninteractive; then
      fl_run_refuse "${RUN_CMD} changes things: without a person to ask, it needs a reviewed plan." "benchbar run ... --dry-run --json -- ${RUN_CMD}, then --apply TOKEN --yes."
    fi
    [[ "${FL_ASSUME_YES:-0}" == "1" ]] || { fl_need "--yes" "to confirm ${RUN_CMD}, which changes things"; fl_need_check; }
  fi
}

# fl_run_plan: errors, steps, JSON and token, from reads only
fl_run_plan() {
  local s steps="" sep="" default cfg="" touches="" t apps redis_down=0
  RUN_ERRORS=(); RUN_WARNINGS=(); RUN_SITE=""; RUN_CAN_APPLY=0
  if [[ "$RUN_NEEDS_SITE" == "yes" ]]; then
    RUN_SITE="${OPT_SITE:-$FL_SITE}"
    if [[ -z "$RUN_SITE" ]]; then
      RUN_ERRORS+=("${RUN_CMD} needs a site and the bench has no default one; pass --site NAME")
    elif ! fl_site_name_ok "$RUN_SITE"; then
      RUN_ERRORS+=("invalid site name '${RUN_SITE}'")
    elif [[ ! -f "${FL_BENCH_DIR}/sites/${RUN_SITE}/site_config.json" ]]; then
      RUN_ERRORS+=("no site ${RUN_SITE} in ${FL_BENCH_DIR} (sites: $(fl_sites_list | tr '\n' ' '))")
    else
      cfg="$(shasum -a 256 "${FL_BENCH_DIR}/sites/${RUN_SITE}/site_config.json" | awk '{print $1}')"
    fi
  fi
  RUN_ARGV=(bench)
  [[ -z "$RUN_SITE" ]] || RUN_ARGV+=(--site "$RUN_SITE")
  RUN_ARGV+=("$RUN_CMD" ${RUN_ARGS[@]+"${RUN_ARGS[@]}"})
  if [[ "$RUN_REDIS" == "yes" ]] && ! fl_port_listening "$FL_REDIS_CACHE_PORT"; then
    redis_down=1
    if [[ "$RUN_CHANGES" == "yes" ]]; then
      RUN_WARNINGS+=("the bench is stopped: benchbar starts its Redis for this run and stops it after")
    else
      RUN_ERRORS+=("${RUN_CMD} needs the bench's Redis and the bench is stopped; start it: ${FL_SELF} up --services-only")
    fi
  fi
  [[ "$RUN_CMD" != "run-tests" ]] || RUN_WARNINGS+=("run-tests writes test records into the database of ${RUN_SITE:-the site}; run it on a throwaway site (benchbar site add), not on one you keep")
  [[ "$RUN_CMD" != "migrate" ]] || ! fl_pm_running 2>/dev/null || RUN_WARNINGS+=("the bench is running: requests it serves while migrate runs can fail")
  if [[ "$RUN_BACKUP" == "yes" && -n "$RUN_SITE" ]]; then
    steps="{\"id\":\"backup\",\"name\":$(fl_json_str "Back up ${RUN_SITE} (database)"),\"touches\":[\"backup\"]}"; sep=","
  fi
  for t in ${RUN_TOUCHES//,/ }; do touches="${touches}${touches:+,}\"${t}\""; done
  steps="${steps}${sep}{\"id\":\"run\",\"name\":$(fl_json_str "${RUN_ARGV[*]}"),\"touches\":[${touches}]}"
  [[ "${#RUN_ERRORS[@]}" == "0" ]] && RUN_CAN_APPLY=1
  RUN_PLAN_BODY="$(printf '"bench":%s,"site":%s,"command":%s,"args":%s,"argv":%s,"summary":%s,"changes":%s,"backup_first":%s,"timeout_s":%d,"touches":[%s],"steps":[%s],"warnings":%s,"errors":%s,"can_apply":%s' \
    "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$RUN_SITE")" "$(fl_json_str "$RUN_CMD")" \
    "$(fl_json_str_array ${RUN_ARGS[@]+"${RUN_ARGS[@]}"})" "$(fl_json_str_array "${RUN_ARGV[@]}")" "$(fl_json_str "$RUN_SUMMARY")" \
    "$(fl_json_bool "$RUN_CHANGES")" "$(fl_json_bool "$([[ "$RUN_BACKUP" == yes && -n "$RUN_SITE" ]] && printf 1 || printf 0)")" "$RUN_TIMEOUT" "$touches" "$steps" \
    "$(fl_json_str_array ${RUN_WARNINGS[@]+"${RUN_WARNINGS[@]}"})" "$(fl_json_str_array ${RUN_ERRORS[@]+"${RUN_ERRORS[@]}"})" "$(fl_json_bool "$RUN_CAN_APPLY")")"
  # the bench state the plan was made against: a change of any makes the token stale
  fl_site_default_file_v default
  apps="$(cat "${FL_BENCH_DIR}/sites/apps.txt" 2>/dev/null || true)"
  s="$(printf 'sites\n%s\ndefault\n%s\napps\n%s\nconfig\n%s\nredis\n%s\n' "$(fl_sites_list)" "$default" "$apps" "$cfg" "$redis_down")"
  RUN_TOKEN="$(printf '%s\n%s\n' "$RUN_PLAN_BODY" "$s" | shasum -a 256 | awk '{print $1}')"
  RUN_PLAN_JSON="$(printf '{"schema_version":%d,"cli_version":"%s","dry_run":true,%s,"token":"%s"}' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$RUN_PLAN_BODY" "$RUN_TOKEN")"
}

fl_run_print_plan() {
  local e w
  printf '\n%sCommand%s\n  cd %s && %s\n' "$FL_BOLD" "$FL_RESET" "$FL_BENCH_DIR" "${RUN_ARGV[*]}"
  printf '  changes things: %s%s; deadline %s\n' "$RUN_CHANGES" "${RUN_TOUCHES:+ (${RUN_TOUCHES//,/, })}" "$(fl_fmt_secs "$RUN_TIMEOUT")"
  [[ "$RUN_BACKUP" != "yes" || -z "$RUN_SITE" ]] || printf '  first: a database backup of %s\n' "$RUN_SITE"
  for w in ${RUN_WARNINGS[@]+"${RUN_WARNINGS[@]}"}; do fl_warn "$w"; done
  for e in ${RUN_ERRORS[@]+"${RUN_ERRORS[@]}"}; do fl_fail "$e"; done
}

# fl_run_bench_command: RUN_ARGV in the bench folder, in a process group of its own, stdin closed, output in
# FL_RUN_OUT; stopped at the deadline (124) or when it waits for input (125). Sets RUN_CODE, RUN_TIMED_OUT.
fl_run_bench_command() {
  local pid start elapsed state last_progress
  RUN_CODE=0; RUN_TIMED_OUT=0
  FL_RUN_OUT="$(mktemp "${TMPDIR:-/tmp}/benchbar-run.XXXXXX")"
  fl_redact_url_v FL_LAST_COMMAND "${RUN_ARGV[*]}"
  fl_log "run: ${RUN_ARGV[*]} (timeout ${RUN_TIMEOUT}s)"
  start="$SECONDS"; last_progress="$SECONDS"
  fl_run_bg_group "$FL_RUN_OUT" fl__in_dir "$FL_BENCH_DIR" "${RUN_ARGV[@]}"
  # shellcheck disable=SC2153  # set by fl_run_bg_group
  pid="$FL_RUN_PID"
  fl_spinner_start "${RUN_ARGV[*]}" "$FL_RUN_OUT"
  while kill -0 "$pid" 2>/dev/null; do
    elapsed=$((SECONDS - start))
    state="$(ps -o state= -p "$pid" 2>/dev/null | awk '{print $1}')"
    if [[ "$state" == T* ]]; then fl_run_group_kill; RUN_CODE=125; break; fi
    if [[ "$elapsed" -ge "$RUN_TIMEOUT" ]]; then fl_run_group_kill; RUN_CODE=124; RUN_TIMED_OUT=1; break; fi
    if [[ "${FL_JSONL:-0}" == "1" && $((SECONDS - last_progress)) -ge "${FL_PROGRESS_SECS:-10}" ]]; then
      last_progress="$SECONDS"
      fl_jsonl_progress "${RUN_ARGV[*]}" "$elapsed"
    fi
    if [[ "$elapsed" -lt 2 ]]; then sleep 0.1; else sleep 0.5; fi
  done
  [[ "$RUN_CODE" != "0" ]] || wait "$pid" || RUN_CODE=$?
  FL_RUN_PGID=""
  fl_elapsed_v RUN_ELAPSED "$start"
  fl_spinner_stop
  fl_log_file_append "$FL_RUN_OUT"
}

# fl_run_collect_tail: the end of the output, for the result: colors and URL credentials removed, lines and total cut
fl_run_collect_tail() {
  local lines
  lines="$(wc -l <"$FL_RUN_OUT" | tr -d ' ')"
  RUN_TAIL="$(tail -n "$FL_RUN_TAIL_LINES" "$FL_RUN_OUT" | fl_strip_ansi | tr -d '\r' | cut -c1-500 | sed -E "$FL_REDACT_URL_SED")"
  RUN_TAIL_CUT=0
  [[ "$lines" -le "$FL_RUN_TAIL_LINES" ]] || RUN_TAIL_CUT=1
  if [[ "${#RUN_TAIL}" -gt "$FL_RUN_TAIL_CHARS" ]]; then RUN_TAIL="${RUN_TAIL:$((${#RUN_TAIL} - FL_RUN_TAIL_CHARS))}"; RUN_TAIL_CUT=1; fi
  rm -f "$FL_RUN_OUT"
}

# fl_run_exit_of CODE: the exit of benchbar run for the bench command's CODE
fl_run_exit_of() {
  case "$1" in 0) printf 0 ;; 2|64) printf 1 ;; *) printf '%s' "$1" ;; esac
}

# fl_run_execute: the planned run: the backup first (migrate), then the command. Returns the bench command's code
# as run exit (fl_run_exit_of), 1 when the backup failed.
fl_run_execute() {
  local ids=() labels=() idx_run=0
  FL_BACKUP_TAKEN_STAMP=""
  RUN_RAN=0; RUN_BACKUP_JSON="null"; RUN_TAIL=""; RUN_TAIL_CUT=0; RUN_CODE=0; RUN_TIMED_OUT=0; RUN_ELAPSED=0
  if [[ "$RUN_BACKUP" == "yes" ]]; then ids+=(backup); labels+=("Back up ${RUN_SITE} (database)"); idx_run=1; fi
  ids+=(run); labels+=("${RUN_ARGV[*]}")
  fl_steps_define "${labels[@]}"
  fl_steps_ids "${ids[@]}"
  # nothing below may ask a question
  exec 0</dev/null
  fl_bench_env_exports
  if [[ "$RUN_REDIS" == "yes" && "$RUN_CHANGES" == "yes" ]]; then fl_bench_redis_up "$FL_BENCH_DIR"; fi
  if [[ "$RUN_BACKUP" == "yes" ]]; then
    fl_step_begin 0
    if ! fl_site_backup_take "$RUN_SITE" 0; then
      fl_step_end failed
      fl_fail "$FL_BACKUP_TAKEN_ERR ${RUN_CMD} was not run."
      fl_bench_redis_down
      FL_DIE_MESSAGE="$FL_BACKUP_TAKEN_ERR ${RUN_CMD} was not run."
      return 1
    fi
    RUN_BACKUP_JSON="$FL_BACKUP_TAKEN_SET"
    fl_changed backup "$RUN_SITE" "$(fl_backup_field "$RUN_BACKUP_JSON" path)"
    fl_step_end "done"
  fi
  fl_step_begin "$idx_run"
  RUN_RAN=1
  fl_run_bench_command
  fl_run_collect_tail
  fl_bench_redis_down
  if [[ "$RUN_CODE" == "0" ]]; then
    fl_step_end "done"
    if [[ "$RUN_CHANGES" == "yes" ]]; then
      if [[ -n "$RUN_SITE" ]]; then fl_changed site "$RUN_SITE" "bench ${RUN_CMD}"; else fl_changed bench "$FL_BENCH_DIR" "bench ${RUN_CMD}"; fi
    fi
    return 0
  fi
  fl_step_end failed
  if [[ "$RUN_TIMED_OUT" == "1" ]]; then FL_DIE_MESSAGE="bench ${RUN_CMD} was stopped after ${RUN_TIMEOUT}s (--timeout)"
  elif [[ "$RUN_CODE" == "125" ]]; then FL_DIE_MESSAGE="bench ${RUN_CMD} was stopped: it waited for input"
  else FL_DIE_MESSAGE="bench ${RUN_CMD} exited with code ${RUN_CODE}"; fi
  fl_fail "${FL_DIE_MESSAGE}"
  [[ -z "$RUN_TAIL" ]] || { fl_note "last lines:"; printf '%s\n' "$RUN_TAIL" | tail -n 40 | sed 's/^/     /'; }
  [[ -z "${FL_LOG_FILE:-}" ]] || fl_note "full output: ${FL_LOG_FILE}"
  if [[ "$RUN_CHANGES" == "yes" ]]; then
    fl_warn "${RUN_CMD} stopped part way; ${RUN_SITE:-the bench} may be half changed"
    if [[ -n "$FL_BACKUP_TAKEN_STAMP" && "$RUN_BACKUP" == "yes" ]]; then
      fl_next_action "${FL_SELF} site restore ${RUN_SITE} --from ${FL_BACKUP_TAKEN_STAMP} --dry-run --json" "Plan putting back the backup taken before the run; show the plan to the person first"
    fi
  fi
  return "$(fl_run_exit_of "$RUN_CODE")"
}

fl_run_result_json() {
  local code="$1"
  printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"site":%s,"command":%s,"args":%s,"argv":%s,"token":%s,"applied":%s,"ok":%s,"ran":%s,"changes":%s,"command_exit":%s,"timed_out":%s,"timeout_s":%d,"elapsed_s":%d,"backup":%s,"output_tail":%s,"output_truncated":%s,"log":%s}' \
    "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$RUN_SITE")" "$(fl_json_str "$RUN_CMD")" \
    "$(fl_json_str_array ${RUN_ARGS[@]+"${RUN_ARGS[@]}"})" "$(fl_json_str_array "${RUN_ARGV[@]}")" \
    "$([[ "$RUN_CHANGES" == yes ]] && fl_json_str "$RUN_TOKEN" || printf null)" "$(fl_json_bool "$RUN_CHANGES")" "$(fl_json_bool "$([[ "$code" == 0 ]] && printf 1 || printf 0)")" \
    "$(fl_json_bool "$RUN_RAN")" "$(fl_json_bool "$RUN_CHANGES")" "$([[ "$RUN_RAN" == 1 ]] && printf '%s' "$RUN_CODE" || printf null)" "$(fl_json_bool "$RUN_TIMED_OUT")" \
    "$RUN_TIMEOUT" "$RUN_ELAPSED" "$RUN_BACKUP_JSON" "$(fl_json_str "$RUN_TAIL")" "$(fl_json_bool "$RUN_TAIL_CUT")" "$(fl_json_str "${FL_LOG_FILE:-}")"
}

fl_cmd_run() {
  local json="${OPT_JSON:-0}" code=0
  fl_site_json_begin
  fl_require_bench
  fl_run_plan
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    if [[ "$json" == "1" ]]; then fl_doc_emit 0 "$RUN_PLAN_JSON" plan; return 0; fi
    fl_header "benchbar run" "dry-run" "$FL_PROFILE" "$FL_BENCH_DIR" "${RUN_SITE:-}"
    fl_run_print_plan
    printf '\n'
    if [[ "$RUN_CAN_APPLY" != "1" ]]; then fl_fail "this plan cannot be applied; nothing was run"; return 1; fi
    fl_info "dry-run: nothing was run"
    return 0
  fi
  fl_header "benchbar run" "$(fl_mode_name)" "$FL_PROFILE" "$FL_BENCH_DIR" "${RUN_SITE:-}"
  if [[ "$RUN_APPLY" == "1" && "$RUN_TOKEN_IN" != "$RUN_TOKEN" ]]; then
    fl_die "The run plan changed since it was shown (the sites, the default site, the apps, the site's config or its arguments). Nothing was run." \
      "Review a fresh plan: benchbar run ... --dry-run --json -- ${RUN_CMD}, then pass its token."
  fi
  fl_run_print_plan
  if [[ "$RUN_CAN_APPLY" != "1" ]]; then
    fl_die "The plan cannot be applied (see above). Nothing was run." "Fix what is listed, then plan again: benchbar run ... --dry-run -- ${RUN_CMD}"
  fi
  if [[ "$RUN_CHANGES" == "yes" && "$RUN_APPLY" != "1" ]]; then
    fl_confirm "Run ${RUN_ARGV[*]}?" || { fl_warn "Cancelled. Nothing was run."; return 1; }
  fi
  fl_run_execute || code=$?
  if [[ "$json" == "1" ]]; then fl_doc_emit "$code" "$(fl_run_result_json "$code")"; fi
  if [[ "$code" == "0" ]]; then
    fl_ok "bench ${RUN_CMD} finished in $(fl_fmt_secs "$RUN_ELAPSED")"
    [[ "$json" == "1" || -z "$RUN_TAIL" ]] || printf '%s\n' "$RUN_TAIL" | tail -n 40
  fi
  return "$code"
}
