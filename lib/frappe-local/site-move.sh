#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# site-move.sh: benchbar site move, a site from this bench to another registered bench.
#
#   benchbar site move NAME --to-bench PATH [--no-migrate]
#       --dry-run [--json] | --apply TOKEN --yes [--json] | --yes
#
# Built from the pieces of site backup, site restore and site drop, not a copy
# of them: a backup with files in this bench (fl_site_backup_take), the same
# set restored into PATH under the same name by site restore's own plan and
# run (site-restore.sh, in a subshell that is the target bench), migrate there,
# a check that NAME answers there, and only then the drop of the source site
# (bench remove's fl_lc_drop_sites: a second backup, bench drop-site, the
# archive checked). The drop is the last step and never runs after a failed
# one: the source site stays as it was and the result says what to clean up.
#
# The plan carries a token (plan-token.sh) as every plan does; --apply plans
# again under the lock and refuses a stale token. A lease on either bench or
# on the site stops the plan (fl_smove_lease_v).

SM_NAME=""
SM_TO=""
SM_TARGET=""
SM_APPLY=0
SM_TOKEN_IN=""
SM_NO_MIGRATE=0
SM_ERRORS=()
SM_STEPS=()
SM_APPS=""
SM_MISSING=""
SM_NEEDS=0
SM_SRC_DEFAULT=""
SM_TGT_DEFAULT=""
SM_SRC_PORT=""
SM_TGT_PORT=""
SM_CAN_APPLY=0
SM_PLAN_BODY=""
SM_PLAN_JSON=""
SM_TOKEN=""
SM_TOKEN_DATA=""
SM_SET_DIR=""
SM_BACKUP_JSON="null"
SM_ARCHIVE=""
SM_FAILED=""
SM_VERIFY_JSON="null"
SM_SOURCE=""
SM_VERIFY_FILE=""

fl_smove_err() { SM_ERRORS+=("$1"); }

fl_smove_parse() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --to-bench) SM_TO="${2:-}"; shift 2 || shift ;;
      --to-bench=*) SM_TO="${1#*=}"; shift ;;
      --apply) SM_APPLY=1; SM_TOKEN_IN="${2:-}"; shift 2 || shift ;;
      --apply=*) SM_APPLY=1; SM_TOKEN_IN="${1#*=}"; shift ;;
      --no-migrate) SM_NO_MIGRATE=1; shift ;;
      -*) fl_die "Unknown option for site move: $1" "Use: benchbar site move NAME --to-bench PATH [--no-migrate] --dry-run --json | --apply TOKEN --yes" ;;
      *) [[ -z "$SM_NAME" ]] && SM_NAME="$1"; shift ;;
    esac
  done
}

# fl_smove_lease_v VAR: the leases (lease.sh) that stand in front of the move: on either bench or on the site
fl_smove_lease_v() {
  FL_LS_CLASS="S"; FL_LS_ALL=0; FL_LS_SITE="$SM_NAME"
  FL_LS_BENCHES="${FL_BENCH_DIR}"$'\n'"${SM_TARGET}"$'\n'
  fl__lease_refusal_v "$1"
}

# fl_smove_default_v VAR BENCH: the default site of BENCH (currentsite.txt, else default_site)
fl_smove_default_v() {
  local __d
  FL_BENCH_DIR="$2" fl_site_default_file_v __d
  [[ -n "$__d" ]] || fl_site_file_value_v __d "${2}/sites/common_site_config.json" default_site
  printf -v "$1" '%s' "$__d"
}

# fl_smove_has_app BENCH APP: the code of APP is in BENCH (apps/APP, or listed in sites/apps.txt)
fl_smove_has_app() {
  [[ -d "${1}/apps/${2}" ]] && return 0
  grep -q -x -F -- "$2" "${1}/sites/apps.txt" 2>/dev/null
}

# fl_smove_plan: errors, steps, JSON and token, from reads only.
fl_smove_plan() {
  local a lease sites_src sites_tgt running json_steps="" sep="" s id missing_json="" touches
  SM_ERRORS=(); SM_STEPS=(); SM_CAN_APPLY=0; SM_APPS=""; SM_MISSING=""; SM_NEEDS=0
  SM_TARGET="$(fl_abs_path "$SM_TO")"
  fl_smove_default_v SM_SRC_DEFAULT "$FL_BENCH_DIR"
  [[ -n "$SM_SRC_DEFAULT" ]] || SM_SRC_DEFAULT="$FL_SITE"
  SM_TGT_DEFAULT=""; SM_SRC_PORT="$FL_WEB_PORT"; SM_TGT_PORT=""
  if [[ "$SM_TARGET" -ef "$FL_BENCH_DIR" ]]; then
    fl_smove_err "the target is the bench the site is in (${FL_BENCH_DIR}); a site moves to another bench"
  elif ! fl_is_bench_dir "$SM_TARGET"; then
    fl_smove_err "${SM_TARGET} is not a bench folder"
  elif ! fl_lc_known_bench "$SM_TARGET"; then
    fl_smove_err "${SM_TARGET} is not a bench benchbar knows (benchbar register ${SM_TARGET}, or benchbar adopt it)"
  else
    fl_smove_default_v SM_TGT_DEFAULT "$SM_TARGET"
    fl_site_file_value_v SM_TGT_PORT "${SM_TARGET}/sites/common_site_config.json" webserver_port
    [[ -n "$SM_TGT_PORT" ]] || SM_TGT_PORT=8000
    if [[ "$SM_NAME" == "$SM_TGT_DEFAULT" ]]; then
      fl_smove_err "${SM_NAME} is the default site of ${SM_TARGET}; nothing there is overwritten, least of all its default site"
    elif [[ -e "${SM_TARGET}/sites/${SM_NAME}" ]]; then
      fl_smove_err "a site ${SM_NAME} already exists in ${SM_TARGET}; nothing is overwritten (move it under another name there, or drop it first)"
    fi
  fi
  if [[ "$SM_NAME" == "$FL_SITE" || "$SM_NAME" == "$SM_SRC_DEFAULT" ]]; then
    fl_smove_err "${SM_NAME} is the default site of ${FL_BENCH_DIR}; the default site never moves (benchbar site default OTHER first, in a terminal)"
  fi
  # the apps the site has installed, against the code in the target
  if SM_APPS="$(fl_site_apps_live "$SM_NAME")"; then
    if [[ -d "$SM_TARGET" ]]; then
      for a in $SM_APPS; do fl_smove_has_app "$SM_TARGET" "$a" || SM_MISSING="${SM_MISSING}${SM_MISSING:+, }${a}"; done
    fi
    [[ -z "$SM_MISSING" ]] || fl_smove_err "${SM_TARGET} lacks apps ${SM_NAME} has installed: ${SM_MISSING} (bench get-app them there first; a restored site with a missing app fails at migrate)"
  else
    fl_smove_err "could not read the apps of ${SM_NAME} (is MariaDB running? benchbar up); the move needs them to check the target bench"
  fi
  fl_port_listening 3306 || fl_smove_err "MariaDB is not running (nothing listens on 3306); start it: $(fl_pull_mariadb_start_hint)"
  if [[ -z "$FL_MARIADB_ROOT_PW" ]] && ! fl_mariadb_root_password_known; then
    SM_NEEDS=1
    [[ -t 0 && "${FL_ASSUME_YES:-0}" != "1" && "${OPT_JSON:-0}" != "1" && "$SM_APPLY" != "1" ]] \
      || fl_smove_err "the MariaDB root password is unknown to benchbar; ask the person for it (do not look for it), then run the command with MARIADB_ROOT_PASSWORD='...' in the environment"
  fi
  fl_smove_lease_v lease
  [[ -z "$lease" ]] || fl_smove_err "${lease}"

  SM_STEPS+=("backup|Back up ${SM_NAME} with its files in ${FL_BENCH_DIR}")
  SM_STEPS+=("restore|Create ${SM_NAME} in ${SM_TARGET} and restore that backup into it (new-site, restore, encryption key)")
  [[ "$SM_NO_MIGRATE" == "1" ]] || SM_STEPS+=("migrate|bench migrate for ${SM_NAME} in ${SM_TARGET}")
  SM_STEPS+=("check|Check that ${SM_NAME} answers in ${SM_TARGET} with the same apps")
  SM_STEPS+=("drop|Back ${SM_NAME} up again and drop it in ${FL_BENCH_DIR} as site drop does (database, folder to archived/sites)")
  for s in "${SM_STEPS[@]}"; do
    id="${s%%|*}"
    case "$id" in
      backup) touches='["backup"]' ;;
      restore) touches='["target database","target files","target site_config"]' ;;
      migrate) touches='["target database"]' ;;
      check) touches='[]' ;;
      *) touches='["source database","source site folder","backup","hosts"]' ;;
    esac
    json_steps="${json_steps}${sep}{\"id\":$(fl_json_str "$id"),\"name\":$(fl_json_str "${s#*|}"),\"touches\":${touches}}"; sep=","
  done
  # shellcheck disable=SC2086  # the app names, split
  SM_PLAN_BODY="$(printf '"bench":%s,"site":%s,"to_bench":%s,"apps":%s,"missing_apps":%s,"default_site":%s,"target_default_site":%s,"migrate":%s,"steps":[%s],"stays":%s,"hosts":%s,"warnings":[],"needs":[%s],"errors":%s' \
    "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$SM_NAME")" "$(fl_json_str "$SM_TARGET")" "$(fl_json_str_array $SM_APPS)" \
    "$(fl_json_str_array ${SM_MISSING//,/})" "$(fl_json_str "$SM_SRC_DEFAULT")" "$(fl_json_str "$SM_TGT_DEFAULT")" \
    "$(fl_json_bool "$([[ "$SM_NO_MIGRATE" == "1" ]] && printf 0 || printf 1)")" "$json_steps" \
    "$(fl_json_str_array "the backups of ${SM_NAME} (they go with its folder to ${FL_BENCH_DIR}/archived/sites/${SM_NAME}, the second backup included)" "a copy of the first backup set in ${FL_BACKUP_ROOT}")" \
    "$(printf '{"line":"kept (same name)","url_before":%s,"url_after":%s,"port_changes":%s}' "$(fl_json_str "http://${SM_NAME}:${SM_SRC_PORT}")" "$(fl_json_str "http://${SM_NAME}:${SM_TGT_PORT:-?}")" "$(fl_json_bool "$([[ "$SM_SRC_PORT" != "${SM_TGT_PORT:-}" ]] && printf 1 || printf 0)")")" \
    "$([[ "$SM_NEEDS" == "1" ]] && printf '"MARIADB_ROOT_PASSWORD"')" "$(fl_json_str_array ${SM_ERRORS[@]+"${SM_ERRORS[@]}"})")"
  [[ "${#SM_ERRORS[@]}" == "0" ]] && SM_CAN_APPLY=1
  SM_PLAN_BODY="${SM_PLAN_BODY},\"can_apply\":$(fl_json_bool "$SM_CAN_APPLY")"
  sites_src="$(fl_sites_list)"
  sites_tgt=""; [[ ! -d "$SM_TARGET" ]] || sites_tgt="$(FL_BENCH_DIR="$SM_TARGET" fl_sites_list)"
  running=0; fl_pm_running && running=1
  SM_TOKEN_DATA="$(printf 'site move\n%s\nsrc-sites\n%s\ntgt-sites\n%s\ndefaults\n%s\n%s\napps\n%s\nrunning\n%s\n' "$SM_PLAN_BODY" "$sites_src" "$sites_tgt" "$SM_SRC_DEFAULT" "$SM_TGT_DEFAULT" "$SM_APPS" "$running")"
  fl_plan_token_v SM_TOKEN "$SM_TOKEN_DATA"
  SM_PLAN_JSON="$(printf '{"schema_version":%d,"cli_version":"%s","dry_run":true,%s,"token":"%s"}' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$SM_PLAN_BODY" "$SM_TOKEN")"
}

fl_smove_print_plan() {
  local s i=1 e
  printf '\n'
  fl_box "Move a site" \
    "site     ${SM_NAME}" \
    "from     ${FL_BENCH_DIR}" \
    "to       ${SM_TARGET}" \
    "apps     ${SM_APPS:-unknown}" \
    "address  http://${SM_NAME}:${SM_SRC_PORT} becomes http://${SM_NAME}:${SM_TGT_PORT:-?} (the hosts line is for the name and stays)" \
    "stays    the backups of ${SM_NAME}: in archived/sites of ${FL_BENCH_DIR} and a copy of the first set under ${FL_BACKUP_ROOT}"
  printf '\n%sSteps%s\n' "$FL_BOLD" "$FL_RESET"
  for s in "${SM_STEPS[@]}"; do
    printf '  %s %d. %s\n' "$FL_G_PEND" "$i" "${s#*|}"
    i=$((i + 1))
  done
  for e in ${SM_ERRORS[@]+"${SM_ERRORS[@]}"}; do fl_fail "$e"; done
  return 0
}

# ---------------------------------------------------------------- steps

# fl_smove_in_target FUNC: FUNC in a subshell that is the target bench (its ports, its lock, its Redis);
# what it sets is gone with it, the exit code is its answer
fl_smove_in_target() {
  local code=0
  # the Redis a step started is stopped before the subshell ends: its record of it goes with it
  ( c=0; fl_context_init "$SM_TARGET" "" ""; "$@" || c=$?; fl_bench_redis_down; exit "$c" ) || code=$?
  return "$code"
}

# fl_smove_stage_set SET: the four files of the set, as a second name (a hard link, else a copy) in this run's
# folder of the state backups, which is where site restore takes a set of its own from (fl_srestore_dir_is_own)
fl_smove_stage_set() {
  local set="$1" dest f src
  dest="${FL_BACKUP_ROOT}/$(fl_backup_stamp)/move-set"
  mkdir -p "$dest" 2>/dev/null || { fl_fail "could not make ${dest}"; return 1; }
  for f in database files private_files config; do
    src="$(fl_backup_field "$set" "$f")"
    case "$src" in ""|null) continue ;; esac
    ln -f "$src" "${dest}/${src##*/}" 2>/dev/null || cp -p "$src" "${dest}/${src##*/}" 2>/dev/null \
      || { fl_fail "could not keep a copy of ${src##*/} in ${dest}"; return 1; }
  done
  SM_SET_DIR="$dest"
}

fl_smove_step_backup() {
  local f
  fl_bench_env_exports
  fl_bench_redis_up "$FL_BENCH_DIR"
  if ! fl_site_backup_take "$SM_NAME" 1; then
    fl_bench_redis_down
    fl_fail "$FL_BACKUP_TAKEN_ERR"; fl_fix "$FL_BACKUP_TAKEN_HINT"
    return 1
  fi
  fl_bench_redis_down
  SM_BACKUP_JSON="$FL_BACKUP_TAKEN_SET"
  for f in database files private_files; do
    case "$(fl_backup_field "$SM_BACKUP_JSON" "$f")" in
      ""|null) fl_fail "the backup ${FL_BACKUP_TAKEN_STAMP} of ${SM_NAME} has no ${f} part"; return 1 ;;
    esac
    fl_backup_file_check "$(fl_backup_field "$SM_BACKUP_JSON" "$f")" || { fl_fail "the backup ${FL_BACKUP_TAKEN_STAMP} cannot be used: ${FL_BACKUP_PROBLEM}"; return 1; }
  done
  fl_smove_stage_set "$SM_BACKUP_JSON" || return 1
  fl_ok "backed up ${SM_NAME} (${FL_BACKUP_TAKEN_STAMP}, with files); a copy is kept in ${SM_SET_DIR}"
}

# the target bench: site restore's plan and run for a new site, with its migrate, cache and verify steps left
# to the steps of the move
fl_smove_target_restore() {
  local err s keep=()
  SR_TARGET="$SM_NAME"; SR_FROM="$SM_SET_DIR"; SR_NEW=1; SR_WITH_FILES=1; SR_APPLY=1
  SR_STEP_PARENT=restore
  FL_PULL_NO_MIGRATE=1
  fl_srestore_plan
  # shellcheck disable=SC2153  # site-restore.sh's own globals
  if [[ "$SR_CAN_APPLY" != "1" ]]; then
    for err in ${SR_ERRORS[@]+"${SR_ERRORS[@]}"}; do fl_fail "$err"; done
    return 1
  fi
  for s in "${FL_PULL_STEPS[@]}"; do
    case "${s%%|*}" in migrate|clear_cache|verify|hosts) ;; *) keep+=("$s") ;; esac
  done
  FL_PULL_STEPS=("${keep[@]}")
  fl_srestore_execute
}

fl_smove_step_restore() { fl_smove_in_target fl_smove_target_restore; }

fl_smove_target_migrate() {
  FL_PULL_AS="$SM_NAME"; FL_PULL_NEED_MIGRATE=1
  fl_pull_step_migrate
}

fl_smove_step_migrate() { fl_smove_in_target fl_smove_target_migrate; }

# the site in the target answers list-apps with the apps it had, and over HTTP when that bench runs (a warning only:
# a running bench may need benchrestart for a site it did not know)
fl_smove_target_check() {
  local out apps want code
  FL_PULL_AS="$SM_NAME"
  fl_bench_env_exports
  [[ -n "$FL_SETUP_REDIS_PORTS" ]] || fl_bench_redis_up "$FL_BENCH_DIR"
  out="$(cd "$FL_BENCH_DIR" && bench --site "$SM_NAME" list-apps 2>>"${FL_LOG_FILE:-/dev/null}")" \
    || { fl_fail "bench --site ${SM_NAME} list-apps failed in ${FL_BENCH_DIR}"; return 1; }
  apps="$(printf '%s\n' "$out" | awk 'NF { print $1 }' | sort | tr '\n' ' ')"
  want="$(tr ' ' '\n' <<<"$SM_APPS" | awk 'NF' | sort | tr '\n' ' ')"
  case " $apps " in *" frappe "*) ;; *) fl_fail "${SM_NAME} does not answer list-apps with frappe in ${FL_BENCH_DIR} (got '${apps% }')"; return 1 ;; esac
  if [[ "$apps" != "$want" ]]; then
    fl_fail "the apps of ${SM_NAME} in ${FL_BENCH_DIR} are '${apps% }', in ${SM_SOURCE} they were '${want% }'"
    return 1
  fi
  fl_ok "${SM_NAME} answers list-apps in ${FL_BENCH_DIR}: ${apps% }"
  fl_pull_step_clear_cache
  code=""
  if fl_pm_running; then
    code="$(fl_site_ping_code_for "$SM_NAME")"
    if [[ "$code" == "200" ]]; then fl_ok "http://${SM_NAME}:${FL_WEB_PORT} answers"
    else fl_warn "http://${SM_NAME}:${FL_WEB_PORT} answered ${code}; run benchrestart in ${FL_BENCH_DIR}"; fi
  else
    fl_info "the bench ${FL_BENCH_DIR} is stopped; benchup there, then open http://${SM_NAME}:${FL_WEB_PORT}"
  fi
  # shellcheck disable=SC2086  # the app names, split
  printf '%s\n' "$(printf '{"apps":%s,"answers":%s}' "$(fl_json_str_array $apps)" "$(if [[ -z "$code" ]]; then printf null; else fl_json_bool "$([[ "$code" == "200" ]] && printf 1 || printf 0)"; fi)")" >"${SM_VERIFY_FILE}"
}

fl_smove_step_check() { fl_smove_in_target fl_smove_target_check; }

# the source: bench remove's drop of one site (a second backup with files read to its end, bench drop-site, the
# archive and its backups checked), in a subshell because its refusals end the shell they run in
fl_smove_drop() {
  local db
  fl_site_file_value_v db "${FL_BENCH_DIR}/sites/${SM_NAME}/site_config.json" db_name
  LC_SITES=("${SM_NAME}|${db}")
  fl_lc_drop_sites
}

fl_smove_step_drop() {
  local code=0
  ( fl_smove_drop ) || code=$?
  [[ "$code" == "0" ]] || return "$code"
  SM_ARCHIVE="$(fl_site_archive_latest "$SM_NAME")"
  fl_changed site "$SM_NAME" "dropped in ${FL_BENCH_DIR}${SM_ARCHIVE:+, archived to ${SM_ARCHIVE}}"
  # the name is in the target now, so site drop's rule keeps the hosts line (macOS) and Linux has none
  fl_hosts_remove_name "$SM_NAME" || true
}

# ---------------------------------------------------------------- run

fl_smove_run() {
  local i=0 n="${#SM_STEPS[@]}" labels=() ids=() s id code=0
  for s in "${SM_STEPS[@]}"; do labels+=("${s#*|}"); ids+=("${s%%|*}"); done
  fl_steps_define "${labels[@]}"
  fl_steps_ids "${ids[@]}"
  while [[ "$i" -lt "$n" ]]; do
    id="${ids[$i]}"
    fl_step_begin "$i"
    FL_STEP_RESULT="done"
    "fl_smove_step_${id}" || code=$?
    if [[ "$code" != "0" ]]; then
      fl_step_end failed
      SM_FAILED="$id"
      i=$((i + 1))
      while [[ "$i" -lt "$n" ]]; do FL_STEP_STATUS[i]="skipped"; i=$((i + 1)); done
      return "$code"
    fi
    [[ "$FL_STEP_RESULT" == "warning" ]] && FL_STEP_RESULT="done"
    fl_step_end "$FL_STEP_RESULT"
    i=$((i + 1))
  done
  return 0
}

# fl_smove_failure_note: what stands after a step failed, and what to clean up
fl_smove_failure_note() {
  local drop_cmd="${FL_SELF} site drop ${SM_NAME} --confirm-site ${SM_NAME} --bench-dir ${SM_TARGET} --dry-run --json"
  case "$SM_FAILED" in
    backup) fl_info "nothing was changed in ${FL_BENCH_DIR} or ${SM_TARGET}" ;;
    drop)
      fl_warn "${SM_NAME} is now in both benches: the copy in ${SM_TARGET} passed its check, and the drop in ${FL_BENCH_DIR} did not finish"
      fl_info "the backups are in ${FL_BENCH_DIR}/sites/${SM_NAME}/private/backups; look at the output above, then drop ${SM_NAME} in ${FL_BENCH_DIR} with: ${FL_SELF} site drop ${SM_NAME} --confirm-site ${SM_NAME} --bench-dir ${FL_BENCH_DIR} --dry-run --json"
      fl_next_action "${FL_SELF} site drop ${SM_NAME} --confirm-site ${SM_NAME} --bench-dir ${FL_BENCH_DIR} --dry-run --json" "finish the move: drop the source copy after reading the plan" ;;
    *)
      fl_info "${SM_NAME} in ${FL_BENCH_DIR} was not touched and is still the site to use"
      if [[ -e "${SM_TARGET}/sites/${SM_NAME}" ]]; then
        fl_warn "a partial copy of ${SM_NAME} is in ${SM_TARGET}; nothing was dropped there. Look at it, then remove it with the plan of: ${drop_cmd}"
        fl_next_action "$drop_cmd" "plan the removal of the partial copy of ${SM_NAME} in ${SM_TARGET} (it is backed up first), then move again"
      fi ;;
  esac
}

fl_smove_result_json() {
  local ok=1 i=0 sep="" out s st
  [[ "$1" == "0" ]] || ok=0
  out="$(printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"site":%s,"to_bench":%s,"token":"%s","applied":true,"ok":%s,"moved":%s,"failed_step":%s,"backup":%s,"archived_path":%s,"address":%s,"steps":[' \
    "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$SM_NAME")" "$(fl_json_str "$SM_TARGET")" "$SM_TOKEN" \
    "$(fl_json_bool "$ok")" "$(fl_json_bool "$ok")" "$(fl_json_str "$SM_FAILED")" "$SM_BACKUP_JSON" "$(fl_json_str "$SM_ARCHIVE")" \
    "$(fl_json_str "http://${SM_NAME}:${SM_TGT_PORT:-?}")")"
  for s in "${SM_STEPS[@]}"; do
    st="${FL_STEP_STATUS[$i]:-pending}"
    out="${out}${sep}{\"id\":$(fl_json_str "${s%%|*}"),\"name\":$(fl_json_str "${s#*|}"),\"status\":$(fl_json_str "$st")}"; sep=","
    i=$((i + 1))
  done
  printf '%s],"verify":%s}\n' "$out" "$SM_VERIFY_JSON"
}

fl_cmd_site_move() {
  local json="${OPT_JSON:-0}" code=0 e
  fl_smove_parse "$@"
  fl_site_json_begin
  fl_require_bench
  fl_require_plain_bench
  [[ -n "$SM_NAME" && -n "$SM_TO" ]] || fl_die "Usage: benchbar site move NAME --to-bench PATH [--no-migrate] --dry-run --json | --apply TOKEN --yes"
  fl_site_valid_name "$SM_NAME"
  fl_site_require "$SM_NAME"
  if [[ "$SM_APPLY" == "1" ]]; then
    [[ "${FL_DRY_RUN:-0}" != "1" ]] || fl_die "--apply runs the plan; --dry-run shows it. Pass one of them."
    [[ "$SM_TOKEN_IN" =~ ^[0-9a-f]{64}$ ]] || fl_die "--apply needs the token of a plan." "benchbar site move ${SM_NAME} --to-bench ${SM_TO} --dry-run --json prints it"
    [[ "${FL_ASSUME_YES:-0}" == "1" ]] || fl_die "Review the plan (--dry-run --json), then pass its token with --apply TOKEN --yes."
  elif [[ "$json" == "1" && "${FL_DRY_RUN:-0}" != "1" ]]; then
    fl_die "--json shows the plan only; add --dry-run (then --apply TOKEN --yes to run it)." "benchbar site move ${SM_NAME} --to-bench ${SM_TO} --dry-run --json"
  fi
  [[ "$SM_APPLY" != "1" ]] || exec 0</dev/null
  fl_smove_plan

  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    if [[ "$json" == "1" ]]; then
      fl_doc_emit 0 "$SM_PLAN_JSON" plan
      return 0
    fi
    fl_header "benchbar site move" "dry-run" "$FL_PROFILE" "$FL_BENCH_DIR" "$SM_NAME"
    fl_smove_print_plan
    printf '\n'
    if [[ "$SM_CAN_APPLY" != "1" ]]; then
      fl_fail "this plan cannot be applied; nothing was changed"
      case "${SM_ERRORS[*]}" in *"MariaDB root password"*) exit 2 ;; esac
      return 1
    fi
    fl_info "dry-run: nothing was backed up, restored or dropped"
    return 0
  fi

  fl_header "benchbar site move" "$(fl_mode_name)" "$FL_PROFILE" "$FL_BENCH_DIR" "$SM_NAME"
  if [[ "$SM_APPLY" == "1" ]]; then
    code=0; fl_plan_token_check "$SM_TOKEN_DATA" "$SM_TOKEN_IN" || code=$?
    case "$code" in
      0) code=0 ;;
      2) fl_die "$(fl_plan_token_expired_text)" "Review a fresh plan: benchbar site move ${SM_NAME} --to-bench ${SM_TO} --dry-run --json, then pass its token." ;;
      *) fl_die "The site move plan changed since it was shown (the sites, the default sites, the apps or a lease). Nothing was changed." \
        "Review a fresh plan: benchbar site move ${SM_NAME} --to-bench ${SM_TO} --dry-run --json, then pass its token." ;;
    esac
  fi
  fl_smove_print_plan
  if [[ "$SM_CAN_APPLY" != "1" ]]; then
    case "${SM_ERRORS[*]}" in *"MariaDB root password"*) code=2 ;; *) code=1 ;; esac
    fl_die "The plan cannot be applied (see above). Nothing was changed." "Fix what is listed, then plan again: benchbar site move ${SM_NAME} --to-bench ${SM_TO} --dry-run" "$code"
  fi
  if [[ "$SM_APPLY" != "1" ]]; then
    fl_confirm "Move ${SM_NAME} from ${FL_BENCH_DIR} to ${SM_TARGET}? (it is dropped here once the copy checks out; its backups stay)" || { fl_warn "Cancelled. Nothing was changed."; return 1; }
  fi
  # the password is resolved (and tried against the server) before anything changes
  fl_mariadb_root_password_resolve || fl_die "The MariaDB root password is needed for the move." \
    "Ask the person for it (do not look for it), then re-run with: MARIADB_ROOT_PASSWORD='...' benchbar site move ..." 2
  exec 0</dev/null
  SM_SOURCE="$FL_BENCH_DIR"
  SM_VERIFY_FILE="$(mktemp "${TMPDIR:-/tmp}/benchbar-move-verify.XXXXXX")"
  fl_smove_run || code=$?
  fl_steps_summary
  if [[ -s "$SM_VERIFY_FILE" ]]; then SM_VERIFY_JSON="$(cat "$SM_VERIFY_FILE")"; fi
  rm -f "$SM_VERIFY_FILE"
  [[ "$code" == "0" ]] || fl_smove_failure_note
  if [[ "$code" != "0" ]]; then
    [[ "$json" != "1" ]] || fl_doc_emit "$code" "$(fl_smove_result_json "$code")"
    return "$code"
  fi
  fl_changed site "$SM_NAME" "moved to ${SM_TARGET}"
  [[ "$SM_BACKUP_JSON" == "null" ]] || fl_changed backup "$SM_NAME" "$(fl_backup_field "$SM_BACKUP_JSON" path)"
  e="the site answers on port ${SM_TGT_PORT:-?} of ${SM_TARGET} now (it was ${SM_SRC_PORT}): http://${SM_NAME}:${SM_TGT_PORT:-?}"
  fl_next_action "${FL_SELF} up --bench-dir ${SM_TARGET}" "$e"
  [[ "$json" != "1" ]] || fl_doc_emit 0 "$(fl_smove_result_json 0)"
  fl_ok "${SM_NAME} moved to ${SM_TARGET}; its backups are in ${SM_ARCHIVE:-${FL_BENCH_DIR}/archived/sites}"
  fl_note "$e"
  return 0
}
