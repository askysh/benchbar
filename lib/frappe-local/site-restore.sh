#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# site-restore.sh: benchbar site restore, a backup set into a site of this bench.
#
#   benchbar site restore TARGET --from STAMP|PATH [--from-site SITE] [--new]
#       [--no-migrate] [--before-migrate SCRIPT] [--with-files]
#       --dry-run [--json] | --apply TOKEN --yes [--json] | --yes
#
# The source is a backup set that site backup (bench backup) made: a STAMP
# from "site backups" (of --from-site, else of TARGET), or the path of its
# database file, or a folder holding sets (the newest). TARGET is a site of
# this bench, which is backed up with its files first, or, with --new, a site
# that is created first (bench new-site, then the restore into it).
#
# The steps are pull's restore steps (pull.sh), not a copy of them: the
# backup of the old site, the quiet scheduler, new-site, restore, the
# encryption key of the set, the hook, migrate, the cache. What this file
# adds is the plan with its token, the source of a local set, the result
# and its own verify. The email of a restored site is not muted and its
# scheduler is not paused: it is the same site, not a copy of production.
#
# --dry-run --json prints the plan with a token; --apply TOKEN --yes runs
# exactly that plan, with no question (the token is a hash of the plan and of
# the bench state it was made against, so a changed backup, site list or hook
# makes it stale), as app add --apply does. A command reports success only
# after the end state was checked: the site answers list-apps and the
# default site is where it was.

SR_TARGET=""
SR_FROM=""
SR_FROM_SITE=""
SR_NEW=0
SR_WITH_FILES=0
SR_APPLY=0
SR_TOKEN_IN=""
SR_ERRORS=()
SR_SET_SITE=""
SR_SET_DIR=""
SR_SET_STAMP=""
SR_SET_JSON="null"
SR_EXISTS=0
SR_HOOK_SHA=""
SR_DEFAULT_BEFORE=""
SR_BACKUP_JSON="null"
SR_BACKUP_STAMP=""
SR_SET_COPY=""
SR_PLAN_BODY=""
SR_NEEDS=""
SR_PLAN_JSON=""
SR_TOKEN=""
SR_CAN_APPLY=0
SR_VERIFY_JSON="null"

fl_srestore_err() { SR_ERRORS+=("$1"); }

fl_srestore_parse() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --from) SR_FROM="${2:-}"; shift 2 || shift ;;
      --from=*) SR_FROM="${1#*=}"; shift ;;
      --from-site) SR_FROM_SITE="${2:-}"; shift 2 || shift ;;
      --from-site=*) SR_FROM_SITE="${1#*=}"; shift ;;
      --before-migrate) FL_PULL_HOOK="${2:-}"; shift 2 || shift ;;
      --before-migrate=*) FL_PULL_HOOK="${1#*=}"; shift ;;
      --apply) SR_APPLY=1; SR_TOKEN_IN="${2:-}"; shift 2 || shift ;;
      --apply=*) SR_APPLY=1; SR_TOKEN_IN="${1#*=}"; shift ;;
      --new) SR_NEW=1; shift ;;
      --no-migrate) FL_PULL_NO_MIGRATE=1; shift ;;
      --with-files) SR_WITH_FILES=1; shift ;;
      -*) fl_die "Unknown option for site restore: $1" "Use: benchbar site restore TARGET --from STAMP|PATH [--from-site SITE] [--new] [--no-migrate] [--before-migrate SCRIPT] [--with-files] --dry-run|--yes" ;;
      *) [[ -z "$SR_TARGET" ]] && SR_TARGET="$1"; shift ;;
    esac
  done
}

# fl_srestore_set_files DIR: the stamp or file picked, as the names in DIR
# that belong to one set; sets FL_PULL_DB and its companions.
fl_srestore_pick() {
  local dir="$1" prefix="$2" names
  names="$(ls -1 "$dir" 2>/dev/null || true)"
  [[ -z "$prefix" ]] || names="$(printf '%s\n' "$names" | awk -v p="$prefix" 'index($0, p) == 1')"
  fl_pull_pick_set "$names"
}

# fl_srestore_resolve_source: FL_PULL_FROM_DIR and the set's file names, or
# errors. Read only.
fl_srestore_resolve_source() {
  local path base dir prefix
  FL_PULL_NO_FILES=1; [[ "$SR_WITH_FILES" == "1" ]] && FL_PULL_NO_FILES=0
  FL_PULL_DB=""; FL_PULL_PUB=""; FL_PULL_PRIV=""; FL_PULL_CONF=""; FL_PULL_FROM_DIR=""
  if [[ -z "$SR_FROM" ]]; then
    fl_srestore_err "--from STAMP|PATH names the backup set to restore (benchbar site backups ${SR_TARGET} lists the stamps)"
    return 1
  fi
  if [[ "$SR_FROM" =~ ^[0-9]{8}_[0-9]{6}$ ]]; then
    SR_SET_SITE="${SR_FROM_SITE:-$SR_TARGET}"
    if [[ -z "$SR_FROM_SITE" && "$SR_NEW" == "1" ]]; then
      fl_srestore_err "--new needs --from-site SITE: ${SR_TARGET} has no backups yet, the stamp ${SR_FROM} is one of another site's"
      return 1
    fi
    if ! fl_site_name_ok "$SR_SET_SITE"; then fl_srestore_err "invalid site name for --from-site: '${SR_SET_SITE}'"; return 1; fi
    dir="$(fl_site_backup_dir "$SR_SET_SITE")"
    if [[ ! -d "$dir" ]]; then fl_srestore_err "no backups of ${SR_SET_SITE} (no folder ${dir})"; return 1; fi
    fl_srestore_pick "$dir" "${SR_FROM}-"
    if [[ -z "$FL_PULL_DB" ]]; then fl_srestore_err "no complete database backup with the stamp ${SR_FROM} in ${dir} (benchbar site backups ${SR_SET_SITE} lists them)"; return 1; fi
  else
    if [[ -n "$SR_FROM_SITE" ]]; then fl_srestore_err "--from-site goes with a stamp; a path names its own folder"; return 1; fi
    path="$SR_FROM"
    case "$path" in /*) ;; '~/'*) path="${HOME}/${path#'~/'}" ;; *) path="${PWD}/${path}" ;; esac
    if [[ -d "$path" ]]; then
      dir="$path"; prefix=""
    elif [[ -f "$path" ]]; then
      dir="$(dirname "$path")"; base="$(basename "$path")"
      if [[ ! "$base" =~ -database(-enc)?\.sql(\.gz)?$ ]]; then fl_srestore_err "${path} is not a database backup (*-database.sql.gz)"; return 1; fi
      prefix="${base%-database*}-"
    else
      fl_srestore_err "no file or folder ${SR_FROM}"
      return 1
    fi
    dir="$(cd "$dir" 2>/dev/null && pwd -P)" || { fl_srestore_err "cannot read ${path}"; return 1; }
    fl_srestore_pick "$dir" "$prefix"
    if [[ -z "$FL_PULL_DB" ]]; then fl_srestore_err "no complete database backup (*-database.sql.gz, not a partial one) for ${SR_FROM}"; return 1; fi
    SR_SET_SITE=""
  fi
  FL_PULL_FROM_DIR="$dir"
  SR_SET_DIR="$dir"
  SR_SET_STAMP="${FL_PULL_DB%%-*}"
  fl_pull_check_set
  if [[ "$FL_PULL_ENCRYPTED" == "1" ]]; then
    fl_srestore_err "the set ${SR_SET_STAMP} is encrypted; site restore takes a plain set (benchbar pull --from-dir ${dir} --as NAME decrypts one)"
    return 1
  fi
  if [[ "$SR_WITH_FILES" == "1" && -z "$FL_PULL_PUB" && -z "$FL_PULL_PRIV" ]]; then
    fl_srestore_err "--with-files: the set ${SR_SET_STAMP} has no files (benchbar site backup NAME --with-files takes one)"
    return 1
  fi
  SR_SET_JSON="$(fl_backup_set_json "$dir" "$SR_SET_STAMP")"
  return 0
}

# fl_srestore_plan: errors, steps, JSON and token, from reads only.
fl_srestore_plan() {
  local sdir s id json_steps="" sep="" touches missing a branch origin why default
  SR_ERRORS=(); SR_EXISTS=0; SR_CAN_APPLY=0; SR_NEEDS=""
  FL_PULL_AS="$SR_TARGET"; FL_PULL_WARNINGS=""; FL_PULL_MISSING=""
  FL_PULL_SITE_CREATE=0; FL_PULL_SITE_EXISTS=0
  FL_PULL_EMIT=0; FL_PULL_CONFIRM_BACKUP=0
  sdir="${FL_BENCH_DIR}/sites/${SR_TARGET}"
  # the target
  if fl_site_incomplete "$FL_BENCH_DIR" "$SR_TARGET" >/dev/null 2>&1; then
    fl_srestore_err "an earlier bench new-site ${SR_TARGET} did not finish; move sites/${SR_TARGET} aside (mv ${sdir} ~/${SR_TARGET}.incomplete), then plan again"
  elif [[ -d "$sdir" && ! -f "${sdir}/site_config.json" ]]; then
    fl_srestore_err "sites/${SR_TARGET} exists but has no site_config.json, so it is no site; move it aside (mv ${sdir} ~/${SR_TARGET}.incomplete), then plan again"
  elif [[ -f "${sdir}/site_config.json" ]]; then
    SR_EXISTS=1
    [[ "$SR_NEW" != "1" ]] || fl_srestore_err "site ${SR_TARGET} already exists; leave out --new to restore into it (it is backed up first)"
  elif [[ "$SR_NEW" != "1" ]]; then
    fl_srestore_err "no site ${SR_TARGET} in ${FL_BENCH_DIR} (sites: $(fl_sites_list | tr '\n' ' ')); --new creates it"
  fi
  [[ "$SR_NEW" == "1" && "$SR_EXISTS" == "0" ]] && FL_PULL_SITE_CREATE=1
  [[ "$SR_EXISTS" == "1" ]] && FL_PULL_SITE_EXISTS=1
  # the source
  fl_srestore_resolve_source || true
  # the database server and its password, judged without trying them
  if [[ "${#SR_ERRORS[@]}" == "0" || -n "$FL_PULL_DB" ]]; then
    fl_port_listening 3306 || fl_srestore_err "MariaDB is not running (nothing listens on 3306); start it: $(fl_pull_mariadb_start_hint)"
    if ! fl_mariadb_root_password_known; then
      SR_NEEDS='"MARIADB_ROOT_PASSWORD"'
      # a run in a terminal asks for it; any other run cannot
      [[ -t 0 && "${FL_ASSUME_YES:-0}" != "1" && "${OPT_JSON:-0}" != "1" && "$SR_APPLY" != "1" ]] \
        || fl_srestore_err "the MariaDB root password is unknown to benchbar; run the command with MARIADB_ROOT_PASSWORD='...' in the environment"
    fi
  fi
  # the hook
  if [[ -n "$FL_PULL_HOOK" ]]; then
    case "$FL_PULL_HOOK" in /*) ;; '~/'*) FL_PULL_HOOK="${HOME}/${FL_PULL_HOOK#'~/'}" ;; *) FL_PULL_HOOK="${PWD}/${FL_PULL_HOOK}" ;; esac
    if [[ ! -f "$FL_PULL_HOOK" ]]; then fl_srestore_err "--before-migrate: no file ${FL_PULL_HOOK}"
    elif [[ ! -x "$FL_PULL_HOOK" ]]; then fl_srestore_err "--before-migrate: ${FL_PULL_HOOK} is not executable (chmod +x)"
    else SR_HOOK_SHA="$(shasum -a 256 "$FL_PULL_HOOK" | awk '{print $1}')"; fi
  fi
  # the apps of the set against this bench
  if [[ -n "$FL_PULL_DB" && "${#SR_ERRORS[@]}" == "0" ]]; then
    FL_PULL_SKIP_APPS=""
    fl_pull_diff_apps >/dev/null
    if [[ -n "$FL_PULL_MISSING" ]]; then
      missing=""
      while IFS='|' read -r a branch origin; do [[ -n "$a" ]] && missing="${missing}${missing:+, }${a}"; done <<<"$FL_PULL_MISSING"
      fl_srestore_err "this bench lacks apps the backup has installed: ${missing} (bench get-app them first; a restored site with a missing app fails at migrate)"
    fi
  fi
  # a backup of a newer frappe than the code here cannot be migrated backwards
  if [[ -n "$FL_PULL_DB" ]]; then
    why="$(fl_pull_frappe_too_new)" || why=""
    [[ -z "$why" ]] || fl_srestore_err "$why; update this bench's apps first (bench update is your call)"
  fi
  # the apps' versions say nothing here: a restore is followed by a migrate
  FL_PULL_NEED_MIGRATE=1

  # the steps, in the order they run (ids are pull.sh's steps, plus verify)
  FL_PULL_STEPS=()
  [[ "$SR_EXISTS" == "1" ]] && FL_PULL_STEPS+=("local_backup|Back up ${SR_TARGET} with its files")
  FL_PULL_QUIESCE=0
  fl_pm_running && ! fl_pull_common_paused && FL_PULL_QUIESCE=1
  [[ "$FL_PULL_QUIESCE" == "1" ]] && FL_PULL_STEPS+=("quiesce|Pause this bench's scheduler during the restore")
  [[ "$FL_PULL_SITE_CREATE" == "1" ]] && FL_PULL_STEPS+=("new_site|Create the site ${SR_TARGET} (bench new-site)")
  FL_PULL_STEPS+=("restore|Restore ${SR_SET_STAMP:-the set} into ${SR_TARGET}$([[ "$FL_PULL_NO_FILES" == "1" ]] || printf ' with its files')")
  # the run skips this step when the set has no key: the plan says so, so plan and run agree
  if [[ "$FL_PULL_HAS_KEY" == "1" ]]; then FL_PULL_STEPS+=("encryption_key|Carry the encryption key of the set over")
  else FL_PULL_STEPS+=("encryption_key|Skip the encryption key (the set has none)"); fi
  [[ "$FL_PULL_QUIESCE" == "1" ]] && FL_PULL_STEPS+=("resume|Resume this bench's scheduler")
  [[ -n "$FL_PULL_HOOK" ]] && FL_PULL_STEPS+=("before_migrate|Run ${FL_PULL_HOOK##*/} (--before-migrate)")
  [[ "$FL_PULL_NO_MIGRATE" == "1" ]] || FL_PULL_STEPS+=("migrate|bench migrate")
  FL_PULL_STEPS+=("clear_cache|Clear caches")
  if [[ "$SR_NEW" == "1" ]] && ! fl_hosts_has_name "$SR_TARGET"; then FL_PULL_STEPS+=("hosts|Hosts line for ${SR_TARGET}"); fi
  FL_PULL_STEPS+=("verify|Verify ${SR_TARGET}")

  touches=""
  case " ${FL_PULL_STEPS[*]} " in *"|Back up "*) touches='"backup",' ;; esac
  touches="${touches}\"database\""
  [[ "$FL_PULL_NO_FILES" == "1" ]] || touches="${touches},\"files\""
  touches="${touches},\"site_config\""
  case " ${FL_PULL_STEPS[*]} " in *"|Hosts line"*) touches="${touches},\"hosts\"" ;; esac
  [[ "$FL_PULL_QUIESCE" != "1" ]] || touches="${touches},\"common_site_config\""
  for s in "${FL_PULL_STEPS[@]}"; do
    id="${s%%|*}"
    json_steps="${json_steps}${sep}{\"id\":$(fl_json_str "$id"),\"name\":$(fl_json_str "${s#*|}"),\"touches\":$(fl_srestore_step_touches "$id")}"; sep=","
  done
  SR_PLAN_BODY="$(printf '"bench":%s,"site":%s,"new":%s,"exists":%s,"source":{"site":%s,"set":%s,"restores_files":%s,"encryption_key":%s},"backup_first":{"will_run":%s,"with_files":true,"folder":%s},"migrate":%s,"before_migrate":%s,"before_migrate_sha256":%s,"touches":[%s],"steps":[%s],"warnings":[%s],"needs":[%s],"errors":%s' \
    "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$SR_TARGET")" "$(fl_json_bool "$SR_NEW")" "$(fl_json_bool "$SR_EXISTS")" \
    "$(fl_json_str "$SR_SET_SITE")" "$SR_SET_JSON" "$(fl_json_bool "$([[ "$FL_PULL_NO_FILES" == "1" ]] && printf 0 || printf 1)")" "$(fl_json_bool "$FL_PULL_HAS_KEY")" \
    "$(fl_json_bool "$SR_EXISTS")" "$(fl_json_str "$(fl_site_backup_dir "$SR_TARGET")")" \
    "$(fl_json_bool "$([[ "$FL_PULL_NO_MIGRATE" == "1" ]] && printf 0 || printf 1)")" "$(fl_json_str "$FL_PULL_HOOK")" "$(fl_json_str "$SR_HOOK_SHA")" \
    "$touches" "$json_steps" "${FL_PULL_WARNINGS}" "$SR_NEEDS" "$(fl_json_str_array ${SR_ERRORS[@]+"${SR_ERRORS[@]}"})")"
  [[ "${#SR_ERRORS[@]}" == "0" ]] && SR_CAN_APPLY=1
  SR_PLAN_BODY="${SR_PLAN_BODY},\"can_apply\":$(fl_json_bool "$SR_CAN_APPLY")"
  # the bench state the plan was made against: the site list, the default
  # site, the hook and the set's files; a change of any makes the token stale
  fl_site_default_file_v default
  s="$(printf 'sites\n%s\ndefault\n%s\nhook\n%s\nset\n%s\nbench-running\n%s\n' "$(fl_sites_list)" "$default" "$SR_HOOK_SHA" "$SR_SET_JSON" "$FL_PULL_QUIESCE")"
  SR_TOKEN="$(printf '%s\n%s\n' "$SR_PLAN_BODY" "$s" | shasum -a 256 | awk '{print $1}')"
  SR_PLAN_JSON="$(printf '{"schema_version":%d,"cli_version":"%s","dry_run":true,%s,"token":"%s"}' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$SR_PLAN_BODY" "$SR_TOKEN")"
}

# fl_srestore_step_touches ID: what a step changes, as a JSON array
fl_srestore_step_touches() {
  case "$1" in
    local_backup) printf '["backup"]' ;;
    new_site) printf '["database","site_config"]' ;;
    restore) if [[ "$FL_PULL_NO_FILES" == "1" ]]; then printf '["database"]'; else printf '["database","files"]'; fi ;;
    encryption_key) printf '["site_config"]' ;;
    quiesce|resume) printf '["common_site_config"]' ;;
    before_migrate) printf '["database"]' ;;
    migrate) printf '["database"]' ;;
    clear_cache) printf '["cache"]' ;;
    hosts) printf '["hosts"]' ;;
    *) printf '[]' ;;
  esac
}

fl_srestore_print_plan() {
  local s i=1 e
  printf '\n'
  fl_box "Restore" \
    "site     ${SR_TARGET} in ${FL_BENCH_DIR}$([[ "$SR_EXISTS" == "1" ]] && printf ' (backed up first)')$([[ "$SR_NEW" == "1" ]] && printf ' (a new site)')" \
    "from     ${SR_SET_STAMP:-?} in ${SR_SET_DIR:-?}$([[ -n "$SR_SET_SITE" ]] && printf ' (a backup of %s)' "$SR_SET_SITE")" \
    "files    $([[ "$FL_PULL_NO_FILES" == "1" ]] && printf 'database only (--with-files restores the uploads)' || printf 'database, public and private files')" \
    "key      $([[ "$FL_PULL_HAS_KEY" == "1" ]] && printf 'encryption_key of the set carried over (never shown)' || printf 'none in the set: stored passwords will not decrypt')" \
    "migrate  $([[ "$FL_PULL_NO_MIGRATE" == "1" ]] && printf 'not run (--no-migrate)' || printf 'after the restore')$([[ -n "$FL_PULL_HOOK" ]] && printf ', %s runs before it' "${FL_PULL_HOOK##*/}")"
  printf '\n%sSteps%s\n' "$FL_BOLD" "$FL_RESET"
  for s in "${FL_PULL_STEPS[@]}"; do
    printf '  %s %d. %s\n' "$FL_G_PEND" "$i" "${s#*|}"
    i=$((i + 1))
  done
  for e in ${SR_ERRORS[@]+"${SR_ERRORS[@]}"}; do fl_fail "$e"; done
  return 0
}

# ---------------------------------------------------------------- steps

fl_srestore_step_verify() {
  local out apps want a code now
  fl_bench_env_exports
  [[ -f "${FL_BENCH_DIR}/sites/${SR_TARGET}/site_config.json" ]] || { fl_fail "sites/${SR_TARGET}/site_config.json is missing"; return 1; }
  out="$(cd "$FL_BENCH_DIR" && bench --site "$SR_TARGET" list-apps 2>>"${FL_LOG_FILE:-/dev/null}")" || { fl_fail "bench --site ${SR_TARGET} list-apps failed"; return 1; }
  apps="$(printf '%s\n' "$out" | awk 'NF { print $1 }' | sort | tr '\n' ' ')"
  case " $apps " in *" frappe "*) ;; *) fl_fail "${SR_TARGET} does not answer list-apps with frappe (got '${apps% }')"; return 1 ;; esac
  fl_ok "${SR_TARGET} answers list-apps: ${apps% }"
  if [[ "$FL_PULL_APPS_KNOWN" == "1" ]]; then
    want="$(printf '%s' "$FL_PULL_R_APPS" | cut -d'|' -f1 | while read -r a; do [[ -n "$a" ]] && printf '%s\n' "$a"; done | sort | tr '\n' ' ' || true)"
    [[ "$apps" == "$want" ]] || fl_pull_warn "apps on ${SR_TARGET} are '${apps% }', the backup had '${want% }'"
  fi
  if [[ "$FL_PULL_HAS_KEY" == "1" ]]; then
    out="$(cd "${FL_BENCH_DIR}/sites" && "${FL_BENCH_DIR}/env/bin/python" -c "$FL_PULL_PY_PROBE" benchbar-probe "$SR_TARGET" 2>>"${FL_LOG_FILE:-/dev/null}" | grep '^benchbar-probe ' | tail -n1 || true)"
    if [[ -n "$out" ]]; then
      # shellcheck disable=SC2086  # "benchbar-probe OK BAD"
      set -- $out
      if [[ "$3" == "0" ]]; then fl_ok "stored passwords decrypt: ${2} of ${2}"
      else fl_pull_warn "${3} of $(($2 + $3)) stored passwords do not decrypt with the site's encryption_key (see docs/troubleshooting.md)"; fi
    else
      fl_warn "the decrypt check did not run; see the log"
    fi
  fi
  # the default site stays where it was
  fl_site_default_file_v now
  if [[ "$now" == "$SR_DEFAULT_BEFORE" ]]; then
    fl_ok "the default site is still ${SR_DEFAULT_BEFORE:-unset}"
  elif [[ -n "$SR_DEFAULT_BEFORE" ]] && (cd "$FL_BENCH_DIR" && bench use "$SR_DEFAULT_BEFORE") >>"${FL_LOG_FILE:-/dev/null}" 2>&1; then
    fl_pull_warn "the restore moved the default site to ${now}; it is back on ${SR_DEFAULT_BEFORE}"
  else
    fl_fail "the default site moved from ${SR_DEFAULT_BEFORE:-unset} to ${now:-unset}"
    return 1
  fi
  code=""
  if fl_pm_running; then
    code="$(fl_site_ping_code_for "$SR_TARGET")"
    if [[ "$code" == "200" ]]; then fl_ok "http://${SR_TARGET}:${FL_WEB_PORT} answers"
    else fl_pull_warn "http://${SR_TARGET}:${FL_WEB_PORT} answered ${code}; run benchrestart"; fi
  else
    fl_info "the bench is stopped; benchup, then open http://${SR_TARGET}:${FL_WEB_PORT}"
  fi
  [[ "$FL_PULL_NO_MIGRATE" != "1" ]] || fl_pull_warn "migrate was skipped (--no-migrate): cd ${FL_BENCH_DIR} && bench --site ${SR_TARGET} migrate"
  # shellcheck disable=SC2086  # the app names, split
  SR_VERIFY_JSON="$(printf '{"apps":%s,"default_site":%s,"answers":%s}' "$(fl_json_str_array $apps)" "$(fl_json_str "$now")" "$(if [[ -z "$code" ]]; then printf null; else fl_json_bool "$([[ "$code" == "200" ]] && printf 1 || printf 0)"; fi)")"
}

# ---------------------------------------------------------------- run

# The result of --apply --json, and of a --yes run with --json.
fl_srestore_result_json() {
  local ok=1 i=0 sep="" out s st
  [[ "$1" == "0" ]] || ok=0
  out="$(printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"site":%s,"token":"%s","applied":true,"ok":%s,"new":%s,"backup":%s,"set_copy":%s,"steps":[' \
    "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$SR_TARGET")" "$SR_TOKEN" "$(fl_json_bool "$ok")" "$(fl_json_bool "$SR_NEW")" "$SR_BACKUP_JSON" "$(fl_json_str "$SR_SET_COPY")")"
  for s in "${FL_PULL_STEPS[@]}"; do
    st="${FL_STEP_STATUS[$i]:-pending}"
    out="${out}${sep}{\"id\":$(fl_json_str "${s%%|*}"),\"name\":$(fl_json_str "${s#*|}"),\"status\":$(fl_json_str "$st")}"; sep=","
    i=$((i + 1))
  done
  # warnings[] comes with the done fields (fl_pull_warn is a fl_warn too)
  printf '%s],"verify":%s}\n' "$out" "$SR_VERIFY_JSON"
}

# fl_srestore_copy_set: when the set is in the target's own backup folder, its
# files go into this run's folder under the state backups (hard links, else
# copies after a free space check), checked by size, and the run goes on with
# that copy. Bench's backup deletes backups older than keep_backups_for_hours in
# that folder, which can hold the set; a set from anywhere else is left where it
# is. The copy stays after the run; the three newest copies of this bench are
# kept. The folders are compared as files (-ef), so a backups folder reached
# through a link is still the target's own.
fl_srestore_copy_set() {
  local root dest f src a b need=0 avail copied=()
  [[ "$SR_SET_DIR" -ef "$(fl_site_backup_dir "$SR_TARGET")" ]] || return 0
  root="${FL_BACKUP_ROOT:-${FL_STATE_DIR}/backups}"
  dest="${root}/$(fl_backup_stamp)/restore-set"
  mkdir -p "$dest" 2>/dev/null || { fl_fail "could not make ${dest}"; return 1; }
  # whose copy it is: the pruning below keeps three per bench, not three in all
  printf '%s\n' "$FL_BENCH_DIR" >"${dest}/.bench" 2>/dev/null || { fl_fail "could not write ${dest}/.bench"; return 1; }
  for f in "$FL_PULL_DB" "$FL_PULL_PUB" "$FL_PULL_PRIV" "$FL_PULL_CONF"; do
    [[ -n "$f" ]] || continue
    [[ "$FL_PULL_NO_FILES" != "1" || "$f" == "$FL_PULL_DB" || "$f" == "$FL_PULL_CONF" ]] || continue
    src="${SR_SET_DIR}/${f}"
    rm -f "${dest}/${f}"
    if ! ln "$src" "${dest}/${f}" 2>/dev/null; then
      # no hard link (another volume): a real copy needs the room
      a="$(wc -c <"$src" | tr -d '[:space:]')"
      need=$((need + a))
      avail="$(df -k "$dest" 2>/dev/null | awk 'NR == 2 { print $4 }')"
      if [[ "$avail" =~ ^[0-9]+$ && $((avail * 1024)) -lt "$need" ]]; then
        fl_srestore_copy_undo "$dest" ${copied[@]+"${copied[@]}"}
        fl_fail "not enough free space for a copy of the set in ${dest}: $(fl_pull_human "$((avail * 1024))") free, $(fl_pull_human "$need") needed"
        return 1
      fi
      cp -p "$src" "${dest}/${f}" 2>/dev/null || { fl_srestore_copy_undo "$dest" ${copied[@]+"${copied[@]}"} "$f"; fl_fail "could not copy ${src} to ${dest}"; return 1; }
    fi
    copied+=("$f")
    a="$(wc -c <"$src" | tr -d '[:space:]')"; b="$(wc -c <"${dest}/${f}" | tr -d '[:space:]')"
    [[ "$a" == "$b" ]] || { fl_srestore_copy_undo "$dest" ${copied[@]+"${copied[@]}"}; fl_fail "the copy of ${f} in ${dest} has another size than the original"; return 1; }
  done
  SR_SET_COPY="$dest"
  FL_PULL_FROM_DIR="$dest"; SR_SET_DIR="$dest"
  fl_info "the set is restored from a copy in ${dest}, so the backup of ${SR_TARGET} cannot prune it"
  fl_srestore_copy_prune "$root" "$dest"
}

# fl_srestore_copy_undo DEST FILE...: a partial copy removed
fl_srestore_copy_undo() {
  local dest="$1" f
  shift
  for f in "$@" .bench; do rm -f "${dest}/${f}"; done
  rmdir "$dest" "$(dirname "$dest")" 2>/dev/null || true
}

# fl_srestore_copy_prune ROOT KEEP: this bench's older restore-set copies beyond
# the three newest (this run's included) go; only files this command made, then
# the folders. Another bench's copies are never touched.
fl_srestore_copy_prune() {
  local root="$1" keep="$2" d n=0 f owner
  # shellcheck disable=SC2012  # folder names this command made
  while IFS= read -r d; do
    [[ -n "$d" && -d "$d" ]] || continue
    owner=""; [[ -r "${d}/.bench" ]] && IFS= read -r owner <"${d}/.bench"
    [[ "$owner" == "$FL_BENCH_DIR" ]] || continue
    n=$((n + 1))
    [[ "$n" -gt 3 && "$d" != "$keep" ]] || continue
    for f in "$d"/* "${d}/.bench"; do [[ -f "$f" ]] && rm -f "$f"; done
    rmdir "$d" "$(dirname "$d")" 2>/dev/null || true
  done < <(ls -1d "${root}"/*/restore-set 2>/dev/null | sort -r)
}

# fl_srestore_verify_backup: the backup taken first is a new set with its
# database and both file archives; no fallback to an older set.
fl_srestore_verify_backup() {
  local dir set f
  dir="$(fl_site_backup_dir "$SR_TARGET")"
  if [[ -z "$SR_BACKUP_STAMP" ]]; then
    fl_fail "bench reported the backup of ${SR_TARGET} done, but no new backup is in ${dir}; nothing was overwritten"
    return 1
  fi
  set="$(fl_backup_set_json "$dir" "$SR_BACKUP_STAMP")"
  for f in database files private_files; do
    case "$(fl_backup_field "$set" "$f")" in
      ""|null)
        fl_fail "the backup ${SR_BACKUP_STAMP} of ${SR_TARGET} has no ${f} part; nothing was overwritten"
        return 1 ;;
    esac
  done
  SR_BACKUP_JSON="$set"
}

# fl_srestore_run: the steps, one after the other; the first failure stops
# the run and the rest stay pending. Returns the exit code.
fl_srestore_run() {
  local i=0 n labels=() ids=() s id code=0 before now
  n="${#FL_PULL_STEPS[@]}"
  for s in "${FL_PULL_STEPS[@]}"; do labels+=("${s#*|}"); ids+=("${s%%|*}"); done
  fl_steps_define "${labels[@]}"
  fl_steps_ids "${ids[@]}"
  fl_site_default_file_v SR_DEFAULT_BEFORE
  # the backup first prunes old files in the target's backup folder, which is
  # where the set may be: restore from a copy of it outside sites/
  if [[ "$SR_EXISTS" == "1" ]]; then fl_srestore_copy_set || { fl_bench_redis_down; return 1; }; fi
  while [[ "$i" -lt "$n" ]]; do
    id="${FL_PULL_STEPS[$i]%%|*}"
    fl_step_begin "$i"
    FL_STEP_RESULT="done"
    case "$id" in
      local_backup) before="$(fl_backup_stamps "$(fl_site_backup_dir "$SR_TARGET")")" ;;
    esac
    case "$id" in
      verify) fl_srestore_step_verify || code=$? ;;
      *) "fl_pull_step_${id}" || code=$? ;;
    esac
    if [[ "$code" == "0" && "$id" == "local_backup" ]]; then
      now="$(fl_backup_stamps "$(fl_site_backup_dir "$SR_TARGET")")"
      SR_BACKUP_STAMP="$(printf '%s\n' "$now" | grep -v -x -F -- "$before" | head -n1 || true)"
      # nothing is overwritten until the backup is there with all its parts
      fl_srestore_verify_backup || code=1
    fi
    if [[ "$code" != "0" ]]; then
      fl_step_end failed
      i=$((i + 1))
      while [[ "$i" -lt "$n" ]]; do FL_STEP_STATUS[i]="skipped"; i=$((i + 1)); done
      fl_bench_redis_down
      return "$code"
    fi
    [[ "$FL_STEP_RESULT" == "warning" ]] && FL_STEP_RESULT="done"
    fl_step_end "$FL_STEP_RESULT"
    i=$((i + 1))
  done
  return 0
}

fl_cmd_site_restore() {
  local json="${OPT_JSON:-0}" code=0 q
  fl_srestore_parse "$@"
  fl_site_json_begin
  fl_require_bench
  fl_require_plain_bench
  [[ -n "$SR_TARGET" ]] || fl_die "Usage: benchbar site restore TARGET --from STAMP|PATH [--from-site SITE] [--new] [--no-migrate] [--before-migrate SCRIPT] [--with-files] --dry-run|--yes"
  fl_site_valid_name "$SR_TARGET"
  if [[ "$SR_APPLY" == "1" ]]; then
    [[ "${FL_DRY_RUN:-0}" != "1" ]] || fl_die "--apply runs the plan; --dry-run shows it. Pass one of them."
    [[ "$SR_TOKEN_IN" =~ ^[0-9a-f]{64}$ ]] || fl_die "--apply needs the token of a plan." "benchbar site restore ${SR_TARGET} --from ... --dry-run --json prints it"
    [[ "${FL_ASSUME_YES:-0}" == "1" ]] || fl_die "Review the plan (--dry-run --json), then pass its token with --apply TOKEN --yes."
  elif [[ "$json" == "1" && "${FL_DRY_RUN:-0}" != "1" ]]; then
    fl_die "--json shows the plan only; add --dry-run (then --apply TOKEN --yes to run it)." "benchbar site restore ${SR_TARGET} --from ... --dry-run --json"
  fi
  # an applied plan never asks: the plan was shown and approved
  [[ "$SR_APPLY" != "1" ]] || exec 0</dev/null
  fl_srestore_plan

  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    if [[ "$json" == "1" ]]; then
      fl_doc_emit 0 "$SR_PLAN_JSON" plan
      return 0
    fi
    fl_header "benchbar site restore" "dry-run" "$FL_PROFILE" "$FL_BENCH_DIR" "$SR_TARGET"
    fl_srestore_print_plan
    printf '\n'
    if [[ "$SR_CAN_APPLY" != "1" ]]; then
      fl_fail "this plan cannot be applied; nothing was changed"
      # an unknown root password is the documented exit 2, as in pull
      case "${SR_ERRORS[*]}" in *"MariaDB root password"*) exit 2 ;; esac
      return 1
    fi
    fl_info "dry-run: nothing was backed up, created or restored"
    return 0
  fi

  fl_header "benchbar site restore" "$(fl_mode_name)" "$FL_PROFILE" "$FL_BENCH_DIR" "$SR_TARGET"
  if [[ "$SR_APPLY" == "1" && "$SR_TOKEN_IN" != "$SR_TOKEN" ]]; then
    fl_die "The site restore plan changed since it was shown (the backup set, the sites, the default site or the hook). Nothing was changed." \
      "Review a fresh plan: benchbar site restore ${SR_TARGET} --from ... --dry-run --json, then pass its token."
  fi
  fl_srestore_print_plan
  if [[ "$SR_CAN_APPLY" != "1" ]]; then
    case "${SR_ERRORS[*]}" in *"MariaDB root password"*) code=2 ;; *) code=1 ;; esac
    fl_die "The plan cannot be applied (see above). Nothing was changed." "Fix what is listed, then plan again: benchbar site restore ${SR_TARGET} --from ... --dry-run" "$code"
  fi
  if [[ "$SR_APPLY" != "1" ]]; then
    q="Restore ${SR_SET_STAMP} into ${SR_TARGET}?"
    [[ "$SR_EXISTS" == "1" ]] && q="Back up ${SR_TARGET}, then replace its data with ${SR_SET_STAMP}?"
    fl_confirm "$q" || { fl_warn "Cancelled. Nothing was changed."; return 1; }
  fi
  # the password is resolved (and tried against the server) before anything changes
  fl_mariadb_root_password_resolve || fl_die "The MariaDB root password is needed for the restore." "Re-run with: MARIADB_ROOT_PASSWORD='...' benchbar site restore ..." 2
  # nothing below may ask a question: frappe's downgrade prompt would hang a terminal
  exec 0</dev/null
  fl_srestore_run || code=$?
  fl_steps_summary
  [[ -z "$SR_SET_COPY" ]] || fl_info "a copy of the backup set is kept in ${SR_SET_COPY}"
  if [[ "$code" != "0" ]]; then
    [[ -z "$SR_BACKUP_STAMP" ]] || fl_info "${SR_TARGET} was backed up first; put that back with: benchbar site restore ${SR_TARGET} --from ${SR_BACKUP_STAMP} --with-files --yes"
    if [[ "${FL_PULL_QUIESCED:-0}" == "1" ]]; then
      fl_warn "the scheduler of every site on this bench stays paused (pause_scheduler in common_site_config.json)"
      fl_fix "cd ${FL_BENCH_DIR} && bench config remove-common-config pause_scheduler"
    fi
    [[ "$json" != "1" ]] || fl_doc_emit "$code" "$(fl_srestore_result_json "$code")"
    return "$code"
  fi
  fl_changed site "$SR_TARGET" "restored from ${SR_SET_STAMP}"
  [[ -z "$SR_BACKUP_STAMP" ]] || fl_changed backup "$SR_TARGET" "$SR_BACKUP_STAMP"
  [[ "$json" != "1" ]] || fl_doc_emit 0 "$(fl_srestore_result_json 0)"
  fl_ok "${SR_TARGET} is restored from ${SR_SET_STAMP}$([[ "$FL_PULL_NO_MIGRATE" == "1" ]] && printf ' (not migrated)'); the default site stays ${SR_DEFAULT_BEFORE:-unset}"
  return 0
}
