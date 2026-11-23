#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# lifecycle.sh: the end of a bench's life, and what to clean up after it.
#
#   benchbar bench forget PATH      unregister a bench; its sites, apps and data are never touched
#   benchbar bench remove PATH      forget it, drop its sites' databases (each backed
#                                   up first) and move the folder aside
#   benchbar bench scratch PATH     mark a bench scratch with an expiry (--ttl DAYS), or --clear
#   benchbar bench gc               list the scratch benches that have expired; remove them
#   benchbar db orphans             databases of the frappe shape no site refers to (read only)
#
# forget, remove and gc are plans with a token, as site restore: --dry-run
# --json prints the plan and its token, --apply TOKEN --yes runs exactly that
# plan. remove and gc delete data (databases, then the folder is moved to a
# trash folder next to it), so a person runs them: they are refused under
# BENCHBAR_NONINTERACTIVE, --for-agent and mcp, and without a terminal. An
# agent may read their plans. forget only moves service files aside and edits
# benchbar's own state, so an agent may run it with a plan and its token.
# Nothing here deletes a folder: bench drop-site backs each site up and moves
# it to archived/sites, and the bench folder is renamed into
# <parent>/.benchbar-trash/, which a person empties.

FL_SCRATCH_DEFAULT_DAYS=7
FL_SCRATCH_MAX_DAYS=90

LC_APPLY=0
LC_TOKEN_IN=""
LC_CONFIRM=""
LC_PATH=""
LC_TTL=""
LC_CLEAR=0
LC_ERRORS=()
LC_STEPS=()
LC_PLAN_BODY=""
LC_TOKEN=""
LC_PLAN_JSON=""
LC_CAN_APPLY=0
LC_REGISTERED=0
LC_DEFAULT=0
LC_EXISTS=0
LC_SERVICE=0
LC_RUNNING=0
LC_SITES=()
LC_RESULT_TRASH=""
LC_GC_EXPIRED=()
LC_GC_PENDING=()
LC_GC_SKIPPED=()

# the tests' clock (FL_NOW), only under FL_TESTING=1; freshness.sh does the same
fl_lc_now() { if [[ "${FL_TESTING:-}" == "1" && -n "${FL_NOW:-}" ]]; then printf '%s' "$FL_NOW"; else date +%s; fi; }

fl_lc_parse() {
  LC_TTL="${OPT_TTL:-}"
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --apply) LC_APPLY=1; LC_TOKEN_IN="${2:-}"; shift 2 || shift ;;
      --apply=*) LC_APPLY=1; LC_TOKEN_IN="${1#*=}"; shift ;;
      --confirm-bench) LC_CONFIRM="${2:-}"; shift 2 || shift ;;
      --confirm-bench=*) LC_CONFIRM="${1#*=}"; shift ;;
      --clear) LC_CLEAR=1; shift ;;
      -*) fl_die "Unknown option for bench: $1" "See: benchbar bench forget|remove|scratch|gc --help" ;;
      *) [[ -z "$LC_PATH" ]] && LC_PATH="$1"; shift ;;
    esac
  done
}

# fl_lc_ttl_days_v VAR [DAYS]: DAYS (default 7) as a whole number of days, 1 to 90
fl_lc_ttl_days_v() {
  local d="${2:-$FL_SCRATCH_DEFAULT_DAYS}"
  [[ "$d" =~ ^[0-9]{1,3}$ ]] && d=$((10#$d)) && [[ "$d" -ge 1 && "$d" -le "$FL_SCRATCH_MAX_DAYS" ]] \
    || fl_die "--ttl takes a whole number of days from 1 to ${FL_SCRATCH_MAX_DAYS}, not '${2:-}'." "Example: benchbar install --scratch --ttl 3"
  printf -v "$1" '%s' "$d"
}

# fl_lc_scratch_mark DIR DAYS WHO: DIR expires DAYS days from now (kept in the bench's own state file, with
# who marked it and when: bench gc shows both in its plan). WHO is install, person or agent.
fl_lc_scratch_mark() {
  local now until
  now="$(fl_lc_now)"; until=$(( now + $2 * 86400 ))
  fl_bstate_set_for "$1" SCRATCH_UNTIL "$until"
  fl_bstate_set_for "$1" SCRATCH_DAYS "$2"
  fl_bstate_set_for "$1" SCRATCH_BY "${3:-person}"
  fl_bstate_set_for "$1" SCRATCH_AT "$now"
}

# fl_lc_benches_all: every bench benchbar knows, and every one it was told to forget whose folder is still
# there (its sites and databases are still somebody's: orphan and hosts lists must not claim them)
fl_lc_benches_all() {
  local d
  fl_known_benches
  [[ -f "${FL_STATE_DIR}/forgotten/benches.txt" ]] || return 0
  while IFS= read -r d || [[ -n "$d" ]]; do
    if [[ -n "$d" ]] && fl_is_bench_dir "$d"; then printf '%s\n' "$d"; fi
  done <"${FL_STATE_DIR}/forgotten/benches.txt"
}

# fl_lc_known_bench DIR: DIR is one of the benches benchbar knows
fl_lc_known_bench() {
  local d
  while IFS= read -r d; do fl_same_path "$d" "$1" && return 0; done < <(fl_known_benches)
  return 1
}

# fl_lc_dev PATH: the device number of PATH (GNU stat, else BSD)
fl_lc_dev() { stat -c %d "$1" 2>/dev/null || stat -f %d "$1" 2>/dev/null; }

# fl_lc_is_mount DIR: DIR is a mount point (another device than its parent): a rename would copy and delete
fl_lc_is_mount() {
  if [[ "${FL_TESTING:-}" == "1" && "|${FL_TEST_MOUNTPOINTS:-}|" == *"|$1|"* ]]; then return 0; fi
  [[ -d "$1" ]] || return 1
  [[ "$(fl_lc_dev "$1")" != "$(fl_lc_dev "${1%/*}")" ]]
}

# ---------------------------------------------------------------- the facts

# fl_lc_registered DIR: DIR is in the list "benchbar register" keeps
fl_lc_registered() {
  local d
  while IFS= read -r d; do [[ -n "$d" ]] && fl_same_path "$d" "$1" && return 0; done < <(fl_registered_benches)
  return 1
}

# fl_lc_sites_load DIR: LC_SITES, one "name|db_name" per site folder of DIR
fl_lc_sites_load() {
  local f s db
  LC_SITES=()
  for f in "$1"/sites/*/site_config.json; do
    [[ -f "$f" ]] || continue
    s="${f%/site_config.json}"; s="${s##*/}"
    fl_site_file_value_v db "$f" db_name
    LC_SITES+=("${s}|${db}")
  done
}

# fl_lc_facts: what benchbar knows about FL_BENCH_DIR
fl_lc_facts() {
  local dir="$FL_BENCH_DIR"
  LC_REGISTERED=0; LC_DEFAULT=0; LC_EXISTS=0; LC_SERVICE=0; LC_RUNNING=0
  fl_lc_registered "$dir" && LC_REGISTERED=1
  fl_same_path "$(fl_state_get BENCH_DIR 2>/dev/null || true)" "$dir" && LC_DEFAULT=1
  if fl_is_bench_dir "$dir"; then LC_EXISTS=1; fi
  if [[ -f "$(fl_agent_plist_path)" || -f "$(fl_runner_path)" || -f "$(fl_procfile_path)" || -n "$(fl_agents_for_dir "$dir")" ]]; then LC_SERVICE=1; fi
  if [[ "$LC_EXISTS" == "1" ]] && fl_pm_running; then LC_RUNNING=1; fi
  fl_lc_sites_load "$dir"
}

# ---------------------------------------------------------------- plan

# fl_lc_plan ACTION: forget or remove FL_BENCH_DIR. Sets LC_PLAN_JSON, LC_TOKEN, LC_CAN_APPLY.
fl_lc_plan() {
  local action="$1" dir="$FL_BENCH_DIR" s sites_json="" sep="" st steps_json="" ssep="" id name others trash_in=""
  LC_ERRORS=(); LC_STEPS=(); LC_CAN_APPLY=0
  fl_lc_facts
  if [[ "$LC_REGISTERED" != "1" && "$LC_DEFAULT" != "1" && "$LC_SERVICE" != "1" ]]; then
    LC_ERRORS+=("${dir} is not registered, not the default bench and has no service, so benchbar has nothing to ${action}; a bench that is only found by looking in the usual folders stays in benchbar list as long as its folder exists")
  fi
  if [[ "$action" == "remove" ]]; then
    [[ "$LC_EXISTS" == "1" ]] || LC_ERRORS+=("no bench folder at ${dir}; benchbar bench forget ${dir} takes its service and registration away")
    [[ "$LC_DEFAULT" != "1" ]] || LC_ERRORS+=("${dir} is the default bench; benchbar does not remove it. Make another bench the default first (benchbar install --make-default --bench-dir OTHER), or forget it")
    if [[ "${#LC_SITES[@]}" -gt 0 ]] && ! fl_port_listening 3306; then
      LC_ERRORS+=("MariaDB is not running (nothing listens on 3306), so the databases of the sites cannot be dropped; start it: $(fl_pull_mariadb_start_hint)")
    fi
    trash_in="$(fl_lc_trash_parent "$dir")"
    if fl_lc_is_mount "$dir"; then
      LC_ERRORS+=("${dir} is a mount point (another volume than ${dir%/*}): moving it would copy and delete the data, which benchbar never does; unmount it or move its contents by hand")
    fi
  fi
  [[ "$LC_RUNNING" != "1" ]] || LC_STEPS+=("stop|Stop the bench's processes")
  if [[ "$action" == "remove" ]]; then
    for s in ${LC_SITES[@]+"${LC_SITES[@]}"}; do
      LC_STEPS+=("site|Back up ${s%%|*} with its files, drop its database ${s#*|} and move the site folder to archived/sites (bench drop-site)$(fl_snap_phrase "$dir" "${s%%|*}")")
    done
  fi
  [[ "$LC_SERVICE" != "1" ]] || LC_STEPS+=("service|Remove the background service: agent, runner and Procfile.lean, each backed up first")
  LC_STEPS+=("registry|Take ${dir} out of benchbar's list and set its settings aside in ${FL_STATE_DIR}/forgotten")
  [[ "$LC_DEFAULT" != "1" ]] || LC_STEPS+=("default|Clear the default bench; no other bench becomes the default on its own")
  others="$(fl_uninstall_other_services)"
  [[ "$LC_SERVICE" != "1" ]] || LC_STEPS+=("helpers|$([[ "$others" == "0" ]] && printf 'Remove the shell helper block (no other bench has a service)' || printf 'Keep the shell helper block (%s other bench(es) still have a service)' "$others")")
  [[ "$action" != "remove" ]] || LC_STEPS+=("trash|Move the bench folder to ${trash_in}/ (nothing is deleted)")
  for s in ${LC_SITES[@]+"${LC_SITES[@]}"}; do
    fl_snap_summary "$dir" "${s%%|*}"
    sites_json="${sites_json}${sep}{\"name\":$(fl_json_str "${s%%|*}"),\"db_name\":$(fl_json_str "${s#*|}")$([[ "$FL_SNAP_COUNT" -eq 0 ]] || printf ',"snapshots":{"count":%s,"size_bytes":%s}' "$FL_SNAP_COUNT" "$FL_SNAP_BYTES")}"; sep=","
  done
  for st in ${LC_STEPS[@]+"${LC_STEPS[@]}"}; do
    id="${st%%|*}"; name="${st#*|}"
    steps_json="${steps_json}${ssep}{\"id\":$(fl_json_str "$id"),\"name\":$(fl_json_str "$name")}"; ssep=","
  done
  [[ "${#LC_ERRORS[@]}" == "0" ]] && LC_CAN_APPLY=1
  LC_PLAN_BODY="$(printf '"action":%s,"bench":%s,"exists":%s,"registered":%s,"default":%s,"running":%s,"service":%s,"sites":[%s],"trash_in":%s,"keeps":[%s],"steps":[%s],"errors":%s,"can_apply":%s' \
    "$(fl_json_str "$action")" "$(fl_json_str "$dir")" "$(fl_json_bool "$LC_EXISTS")" "$(fl_json_bool "$LC_REGISTERED")" "$(fl_json_bool "$LC_DEFAULT")" \
    "$(fl_json_bool "$LC_RUNNING")" "$(fl_json_bool "$LC_SERVICE")" "$sites_json" "$(fl_json_str "$trash_in")" \
    "$([[ "$action" == "forget" ]] && printf '"the bench folder with its sites and apps","the databases","the hosts lines"' || printf '"the hosts lines","the backups (they are in the moved folder, under archived/sites)"')" \
    "$steps_json" "$(fl_json_str_array ${LC_ERRORS[@]+"${LC_ERRORS[@]}"})" "$(fl_json_bool "$LC_CAN_APPLY")")"
  LC_TOKEN="$(printf '%s\n' "$LC_PLAN_BODY" | shasum -a 256 | awk '{print $1}')"
  LC_PLAN_JSON="$(printf '{"schema_version":%d,"cli_version":"%s","dry_run":true,%s,"token":"%s"}' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$LC_PLAN_BODY" "$LC_TOKEN")"
}

fl_lc_print_plan() {
  local action="$1" st i=1 e
  printf '\n'
  fl_box "bench ${action}" "bench    ${FL_BENCH_DIR}" \
    "sites    ${#LC_SITES[@]}$([[ "$action" == "remove" ]] && printf ' (each is backed up, then its database is dropped)')" \
    "kept     $([[ "$action" == "forget" ]] && printf 'the folder with its sites and apps, the databases and the hosts lines (benchbar'"'"'s own service files in it go, each backed up first)' || printf 'the hosts lines; the folder is moved, not deleted')"
  printf '\n%sSteps%s\n' "$FL_BOLD" "$FL_RESET"
  for st in ${LC_STEPS[@]+"${LC_STEPS[@]}"}; do printf '  %s %d. %s\n' "$FL_G_PEND" "$i" "${st#*|}"; i=$((i + 1)); done
  for e in ${LC_ERRORS[@]+"${LC_ERRORS[@]}"}; do fl_fail "$e"; done
  return 0
}

# fl_lc_trash_parent DIR: where a removed bench goes, on the same volume (a rename, never a copy)
fl_lc_trash_parent() { printf '%s/.benchbar-trash' "${1%/*}"; }

# fl_lc_person_gate WHAT: removing data is a person's decision (a terminal, or the app's own claim)
fl_lc_person_gate() {
  [[ -t 0 ]] && ! fl_noninteractive && return 0
  fl_person_env_ok BENCHBAR_NONINTERACTIVE 0 && return 0
  fl_die "${1} deletes data and needs a person at a terminal, and this run has none.${FL_PERSON_WHY:+ $FL_PERSON_WHY}" \
    "Read the plan: benchbar ${2} --dry-run --json. Then a person runs it in a terminal."
}

# ---------------------------------------------------------------- the steps

# fl_lc_registry_remove DIR: DIR leaves registered-benches.txt
fl_lc_registry_remove() {
  local file="${FL_STATE_DIR}/registered-benches.txt" tmp d
  [[ -f "$file" ]] || return 0
  tmp="$(mktemp "${FL_STATE_DIR}/registered.XXXXXX")"
  while IFS= read -r d || [[ -n "$d" ]]; do
    [[ -n "$d" ]] && ! fl_same_path "$d" "$1" && printf '%s\n' "$d"
  done <"$file" >"$tmp" || true
  mv "$tmp" "$file"
}

# fl_lc_forget_run: the service, the list, the settings, the default (FL_BENCH_DIR; confirmed by the caller)
fl_lc_forget_run() {
  local dir="$FL_BENCH_DIR" dest f
  if [[ "$LC_SERVICE" == "1" ]]; then fl_cmd_uninstall_service confirmed || return 1; fi
  fl_lc_registry_remove "$dir"
  # remembered, so that the orphan and hosts lists do not take the sites of this folder for leftovers
  mkdir -p "${FL_STATE_DIR}/forgotten" && printf '%s\n' "$dir" >>"${FL_STATE_DIR}/forgotten/benches.txt"
  fl_bench_state_migrate "$dir"
  dest="${FL_STATE_DIR}/forgotten/$(fl_backup_stamp)"
  for f in "$(fl_bench_state_file_for "$dir")" "$(fl_bench_state_file_old "$dir")"; do
    [[ -f "$f" ]] || continue
    fl_bench_owns_old_file "$dir" || [[ "$f" != "$(fl_bench_state_file_old "$dir")" ]] || continue
    if ! { mkdir -p "$dest" && mv "$f" "$dest/"; }; then fl_fail "could not move ${f} to ${dest}/"; return 1; fi
    fl_ok "moved ${f} to ${dest}/"
  done
  if [[ "$LC_DEFAULT" == "1" ]]; then
    fl_kv_del "$FL_STATE_FILE" BENCH_DIR
    fl_warn "${dir} was the default bench; there is none now (benchbar install --make-default or adopt names one)"
  fi
  fl_changed bench "$dir" "forgotten"
}

# fl_lc_backup_first NAME: bench --site NAME backup --with-files, then every part of the new set read to its
# end. 1 (with a [FAIL] line) when the backup failed or the set is not whole: nothing is dropped then.
# bench's backup deletes the site's backups older than 23 hours: the caller keeps them (fl_backups_keep_begin).
fl_lc_backup_first() {
  local name="$1" dir before stamp set f
  dir="$(fl_site_backup_dir "$name")"
  before="$(mktemp "${TMPDIR:-/tmp}/benchbar-backup-start.XXXXXX")"
  if ! fl_bench_run_long "bench --site ${name} backup --with-files" "$FL_BENCH_DIR" bench --site "$name" backup --with-files; then
    rm -f "$before"; fl_fail "the backup of ${name} failed; nothing was dropped"; return 1
  fi
  stamp="$(find "$dir" -maxdepth 1 -type f -newer "$before" -name '[0-9]*_[0-9]*-*' 2>/dev/null | sed -n 's#.*/\([0-9]\{8\}_[0-9]\{6\}\)-.*#\1#p' | sort -r | awk 'NR==1')"
  rm -f "$before"
  if [[ -z "$stamp" ]]; then fl_fail "bench reported the backup of ${name} done, but ${dir} has no new backup; nothing was dropped"; return 1; fi
  set="$(fl_backup_set_json "$dir" "$stamp")"
  for f in database files private_files; do
    case "$(fl_backup_field "$set" "$f")" in
      ""|null) fl_fail "the backup ${stamp} of ${name} has no ${f} part; nothing was dropped"; return 1 ;;
    esac
    fl_backup_file_check "$(fl_backup_field "$set" "$f")" || { fl_fail "the backup ${stamp} of ${name} cannot be used: ${FL_BACKUP_PROBLEM}; nothing was dropped"; return 1; }
  done
  fl_ok "backed up ${name} (${stamp}, with files) in ${dir}"
}

# fl_lc_drop_sites: every site of FL_BENCH_DIR: its older backups kept, a backup with files taken and read
# BEFORE anything is dropped, then bench drop-site (database, folder to archived/sites), and the archive checked.
# Stops at the first failure with nothing moved and the sites after it untouched.
fl_lc_drop_sites() {
  local s name archive archive_before stamp code snap_n=0 snap_b=0
  [[ "${#LC_SITES[@]}" -gt 0 ]] || return 0
  fl_mariadb_root_password_resolve || fl_die "The MariaDB root password is needed to drop the databases of ${FL_BENCH_DIR}." \
    "Ask the person for it (do not look for it), then re-run with: MARIADB_ROOT_PASSWORD='...' benchbar bench remove ..." 2
  fl_bench_env_exports
  fl_bench_redis_up "$FL_BENCH_DIR"
  for s in "${LC_SITES[@]}"; do
    name="${s%%|*}"; code=0
    fl_snap_summary "$FL_BENCH_DIR" "$name"; snap_n="$FL_SNAP_COUNT"; snap_b="$FL_SNAP_BYTES"
    archive_before="$(fl_site_archive_latest "$name")"
    # the backups of drop-site and of the first backup delete the site's backups older than 23 hours: keep them
    if ! fl_backups_keep_begin "$name"; then
      fl_bench_redis_down
      fl_die "The older backups of ${name} could not be kept while bench takes a new one; nothing was dropped or moved." "Free space on the volume of ${FL_STATE_DIR}, or move the old backups away."
    fi
    if ! fl_lc_backup_first "$name"; then
      fl_backups_keep_end; fl_bench_redis_down
      fl_die "No usable backup of ${name}: nothing was dropped and nothing was moved." "Run it by hand to see why: cd ${FL_BENCH_DIR} && bench --site ${name} backup --with-files"
    fi
    FL__DB_PW="$FL_MARIADB_ROOT_PW"
    fl_run_long "bench drop-site ${name}" fl__frappe_with_secrets "$FL_BENCH_DIR" FL__DB_PW -- \
      drop-site "$name" --db-root-password @secret0@ || code=$?
    FL__DB_PW=""
    if [[ "$code" != "0" ]]; then
      fl_backups_keep_end; fl_bench_redis_down
      fl_die "bench drop-site ${name} failed; ${name} and the sites after it are still there, nothing was moved." "Fix what the output says, then plan again."
    fi
    archive="$(fl_site_archive_latest "$name")"
    if [[ -z "$archive" || "$archive" == "$archive_before" || -d "${FL_BENCH_DIR}/sites/${name}" ]]; then
      fl_backups_keep_end; fl_bench_redis_down
      fl_die "bench drop-site ${name} finished, but no new folder for it is in ${FL_BENCH_DIR}/archived/sites (or sites/${name} is still there); the bench folder stays where it is." "Look in ${FL_BENCH_DIR}/archived/sites before doing anything else."
    fi
    # the older backups go with the site folder, into the archive
    fl_backups_keep_end "${archive}/private/backups"
    stamp="$(fl_backup_stamps "${archive}/private/backups" | awk 'NR==1')"
    if [[ -z "$stamp" ]]; then
      fl_bench_redis_down
      fl_die "${name} was dropped but no backup of it is in ${archive}/private/backups; the bench folder stays where it is." "Look there before doing anything else."
    fi
    fl_changed site "$name" "dropped, backups in ${archive}/private/backups"
    fl_ok "dropped ${name} (database ${s#*|}); backups in ${archive}/private/backups"
    [[ "$snap_n" -eq 0 ]] || fl_note "its ${snap_n} snapshot(s) ($(fl_fmt_bytes "$snap_b")) are in ${archive}/snapshots"
  done
  fl_bench_redis_down
}

# fl_lc_trash_move: the bench folder, renamed into <parent>/.benchbar-trash/NAME-STAMP
fl_lc_trash_move() {
  local dir="$FL_BENCH_DIR" parent dest n=0 base
  parent="$(fl_lc_trash_parent "$dir")"
  base="${dir##*/}-$(date +%Y%m%d-%H%M%S)"
  dest="${parent}/${base}"
  while [[ -e "$dest" ]]; do n=$((n + 1)); dest="${parent}/${base}-${n}"; done
  # this run's own lock of the bench goes first, or the folder would carry it into the trash
  if [[ "$(cat "${dir}/.benchbar.lock/pid" 2>/dev/null)" == "$$" ]]; then rm -rf "${dir}/.benchbar.lock"; fi
  if ! { mkdir -p "$parent" && mv "$dir" "$dest"; }; then fl_fail "could not move ${dir} to ${dest}"; return 1; fi
  LC_RESULT_TRASH="$dest"
  fl_changed bench "$dir" "moved to ${dest}"
  fl_ok "moved ${dir} to ${dest} (benchbar never deletes it; remove it yourself when you are sure)"
}

# fl_lc_remove_run: stop, drop the sites, forget, move (FL_BENCH_DIR; confirmed by the caller)
fl_lc_remove_run() {
  [[ "$LC_RUNNING" != "1" ]] || fl_cmd_down || true
  fl_lc_drop_sites
  fl_lc_forget_run || return 1
  fl_lc_trash_move
}

# ---------------------------------------------------------------- bench forget and remove

fl_lc_result_json() {
  printf '{"schema_version":%d,"cli_version":"%s","dry_run":false,"action":%s,"bench":%s,"done":true,"trash_path":%s}' \
    "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$1")" "$(fl_json_str "$2")" "$(fl_json_str "$LC_RESULT_TRASH")"
}

# fl_cmd_bench_retire ACTION: forget or remove PATH
fl_cmd_bench_retire() {
  local action="$1" json="${OPT_JSON:-0}" q
  fl_site_json_begin
  [[ -n "$LC_PATH" ]] || fl_die "Usage: benchbar bench ${action} PATH [--dry-run [--json] | --apply TOKEN --yes [--json]]"
  if [[ "$LC_APPLY" == "1" ]]; then
    [[ "${FL_DRY_RUN:-0}" != "1" ]] || fl_die "--apply runs the plan; --dry-run shows it. Pass one of them."
    [[ "$LC_TOKEN_IN" =~ ^[0-9a-f]{64}$ ]] || fl_die "--apply needs the token of a plan." "benchbar bench ${action} ${LC_PATH} --dry-run --json prints it"
    [[ "${FL_ASSUME_YES:-0}" == "1" ]] || fl_die "Review the plan (--dry-run --json), then pass its token with --apply TOKEN --yes."
  elif [[ "$json" == "1" && "${FL_DRY_RUN:-0}" != "1" ]]; then
    fl_die "--json shows the plan only; add --dry-run (then --apply TOKEN --yes to run it)." "benchbar bench ${action} ${LC_PATH} --dry-run --json"
  fi
  if [[ "$action" == "remove" && "${FL_DRY_RUN:-0}" != "1" ]]; then fl_lc_person_gate "benchbar bench remove" "bench remove ${LC_PATH}"; fi
  [[ "$LC_APPLY" != "1" ]] || exec 0</dev/null
  fl_lc_plan "$action"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    if [[ "$json" == "1" ]]; then fl_doc_emit 0 "$LC_PLAN_JSON" plan; return 0; fi
    fl_header "benchbar bench ${action}" "dry-run" "$FL_PROFILE" "$FL_BENCH_DIR" ""
    fl_lc_print_plan "$action"
    printf '\n'
    [[ "$LC_CAN_APPLY" == "1" ]] || { fl_fail "this plan cannot be applied; nothing was changed"; return 1; }
    fl_info "dry-run: nothing was changed"
    return 0
  fi
  fl_header "benchbar bench ${action}" "$(fl_mode_name)" "$FL_PROFILE" "$FL_BENCH_DIR" ""
  if [[ "$LC_APPLY" == "1" && "$LC_TOKEN_IN" != "$LC_TOKEN" ]]; then
    fl_die "The bench ${action} plan changed since it was shown (the list, the default bench, the service or the sites). Nothing was changed." \
      "Review a fresh plan: benchbar bench ${action} ${LC_PATH} --dry-run --json, then pass its token."
  fi
  fl_lc_print_plan "$action"
  [[ "$LC_CAN_APPLY" == "1" ]] || fl_die "The plan cannot be applied (see above). Nothing was changed." "Fix what is listed, then plan again."
  if [[ "$action" == "remove" ]]; then
    [[ "$LC_CONFIRM" == "${FL_BENCH_DIR##*/}" ]] || fl_die "Refusing to remove ${FL_BENCH_DIR}: --confirm-bench must repeat the folder name exactly." \
      "benchbar bench remove ${LC_PATH} --confirm-bench ${FL_BENCH_DIR##*/} --apply TOKEN --yes"
  fi
  if [[ "$LC_APPLY" != "1" ]]; then
    q="Forget ${FL_BENCH_NAME}? Its folder is not touched."
    [[ "$action" != "remove" ]] || q="Back up and drop the sites of ${FL_BENCH_NAME}, then move its folder aside?"
    fl_confirm "$q" || { fl_warn "Cancelled. Nothing was changed."; return 1; }
  fi
  if [[ "$action" == "remove" ]]; then fl_lc_remove_run || return 1; else fl_lc_forget_run || return 1; fi
  [[ "$LC_DEFAULT" != "1" ]] || fl_next_action "benchbar adopt PATH --make-default" "name a new default bench"
  [[ "$action" != "forget" ]] || fl_next_action "benchbar site hosts --prune" "its sites' hosts lines were kept (sudo; only lines of sites no bench has)"
  [[ "$json" != "1" ]] || fl_doc_emit 0 "$(fl_lc_result_json "$action" "$FL_BENCH_DIR")"
  fl_ok "${FL_BENCH_DIR}: ${action} done"
}

# ---------------------------------------------------------------- scratch and gc

# bench scratch PATH [--ttl DAYS] | --clear
fl_cmd_bench_scratch() {
  local days until who
  fl_site_json_begin
  [[ -n "$LC_PATH" ]] || fl_die "Usage: benchbar bench scratch PATH [--ttl DAYS] | --clear"
  fl_is_bench_dir "$FL_BENCH_DIR" || fl_die "No bench at ${FL_BENCH_DIR}." "Check the path (benchbar list shows the benches)."
  if [[ "$LC_CLEAR" == "1" ]]; then
    if [[ "${FL_DRY_RUN:-0}" != "1" ]]; then fl_bstate_del SCRATCH_UNTIL; fl_bstate_del SCRATCH_DAYS; fl_changed bench "$FL_BENCH_DIR" "no longer scratch"; fi
    fl_ok "${FL_BENCH_DIR} is not a scratch bench"
    [[ "${OPT_JSON:-0}" != "1" ]] || fl_doc_emit 0 "$(printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"scratch":false,"scratch_until":null}' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")")"
    return 0
  fi
  fl_lc_ttl_days_v days "$LC_TTL"
  until=$(( $(fl_lc_now) + days * 86400 ))
  # marking is what makes a later gc remove the bench: it asks (an agent must pass --yes) and gc shows who marked it
  if [[ "${FL_DRY_RUN:-0}" != "1" ]]; then
    fl_confirm "Mark ${FL_BENCH_NAME} scratch for ${days} day(s)? bench gc then removes it, with its databases." || { fl_warn "Cancelled. Nothing was changed."; return 1; }
    # the app and the tray have no terminal, but a person clicked; BENCHBAR_CALLER is a label, which is all gc shows
    [[ -n "${FL_CALLER:-}" ]] || fl_caller_resolve
    case "${FL_CALLER:-}" in
      app|tray) who=person ;;
      *) if fl_noninteractive || [[ ! -t 0 ]]; then who=agent; else who=person; fi ;;
    esac
    fl_lc_scratch_mark "$FL_BENCH_DIR" "$days" "$who"
  fi
  if ! fl_lc_known_bench "$FL_BENCH_DIR"; then
    fl_warn "benchbar does not know ${FL_BENCH_DIR} (not registered, no service): bench gc only looks at known benches, so it will not collect this one"
    fl_next_action "benchbar register ${FL_BENCH_DIR}" "so that bench gc sees it"
  fi
  [[ "${FL_DRY_RUN:-0}" == "1" ]] || fl_changed bench "$FL_BENCH_DIR" "scratch for ${days} day(s)"
  fl_ok "${FL_BENCH_DIR} is a scratch bench for ${days} day(s); benchbar bench gc removes it after that (never the default bench)"
  [[ "${OPT_JSON:-0}" != "1" ]] || fl_doc_emit 0 "$(printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"scratch":true,"ttl_days":%s,"scratch_until":%s}' \
    "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$days" "$until")"
}

# fl_lc_gc_load: LC_GC_EXPIRED, LC_GC_PENDING, LC_GC_SKIPPED: "path|until|sites|why|marked by|marked at"
fl_lc_gc_load() {
  local d until now row dflt n by at
  LC_GC_EXPIRED=(); LC_GC_PENDING=(); LC_GC_SKIPPED=()
  now="$(fl_lc_now)"
  dflt="$(fl_state_get BENCH_DIR 2>/dev/null || true)"
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    until="$(fl_bstate_get_for "$d" SCRATCH_UNTIL 2>/dev/null || true)"
    [[ "$until" =~ ^[0-9]+$ ]] || continue
    n=0; for row in "$d"/sites/*/site_config.json; do [[ -f "$row" ]] && n=$((n + 1)); done
    by="$(fl_bstate_get_for "$d" SCRATCH_BY 2>/dev/null || true)"
    at="$(fl_bstate_get_for "$d" SCRATCH_AT 2>/dev/null || true)"
    [[ "$at" =~ ^[0-9]+$ ]] || at=0
    row="${d}|${until}|${n}|"
    if [[ -n "$dflt" ]] && fl_same_path "$dflt" "$d"; then row="${d}|${until}|${n}|it is the default bench"; LC_GC_SKIPPED+=("${row}|${by:-unknown}|${at}")
    elif [[ "$until" -le "$now" ]]; then LC_GC_EXPIRED+=("${row}|${by:-unknown}|${at}")
    else LC_GC_PENDING+=("${row}|${by:-unknown}|${at}"); fi
  done < <(fl_known_benches)
}

fl_lc_gc_rows_json_v() {
  local __var="$1" __r __out="" __sep="" __u __iso __at __atiso
  shift
  for __r in "$@"; do
    __u="$(printf '%s' "$__r" | cut -d'|' -f2)"
    __iso="$(fl_iso_from_epoch "$__u" 2>/dev/null || true)"
    __at="$(printf '%s' "$__r" | cut -d'|' -f6)"
    __atiso=""; [[ "$__at" == "0" ]] || __atiso="$(fl_iso_from_epoch "$__at" 2>/dev/null || true)"
    __out="${__out}${__sep}{\"bench\":$(fl_json_str "${__r%%|*}"),\"scratch_until\":${__u},\"scratch_until_iso\":$(fl_json_str "$__iso"),\"sites\":$(printf '%s' "$__r" | cut -d'|' -f3),\"why\":$(fl_json_str "$(printf '%s' "$__r" | cut -d'|' -f4)"),\"marked_by\":$(fl_json_str "$(printf '%s' "$__r" | cut -d'|' -f5)"),\"marked_at\":$(fl_json_str "$__atiso")}"; __sep=","
  done
  printf -v "$__var" '%s' "$__out"
}

# bench gc [--dry-run [--json] | --apply TOKEN --yes [--json]]
fl_cmd_bench_gc() {
  local json="${OPT_JSON:-0}" ex pe sk body d row code=0 done_n=0 removed="" sep=""
  fl_site_json_begin
  if [[ "$LC_APPLY" == "1" ]]; then
    [[ "${FL_DRY_RUN:-0}" != "1" ]] || fl_die "--apply runs the plan; --dry-run shows it. Pass one of them."
    [[ "$LC_TOKEN_IN" =~ ^[0-9a-f]{64}$ ]] || fl_die "--apply needs the token of a plan." "benchbar bench gc --dry-run --json prints it"
    [[ "${FL_ASSUME_YES:-0}" == "1" ]] || fl_die "Review the plan (--dry-run --json), then pass its token with --apply TOKEN --yes."
  elif [[ "$json" == "1" && "${FL_DRY_RUN:-0}" != "1" ]]; then
    fl_die "--json shows the plan only; add --dry-run (then --apply TOKEN --yes to run it)." "benchbar bench gc --dry-run --json"
  fi
  if [[ "${FL_DRY_RUN:-0}" != "1" ]]; then fl_lc_person_gate "benchbar bench gc" "bench gc"; fi
  fl_lc_gc_load
  fl_lc_gc_rows_json_v ex ${LC_GC_EXPIRED[@]+"${LC_GC_EXPIRED[@]}"}
  fl_lc_gc_rows_json_v pe ${LC_GC_PENDING[@]+"${LC_GC_PENDING[@]}"}
  fl_lc_gc_rows_json_v sk ${LC_GC_SKIPPED[@]+"${LC_GC_SKIPPED[@]}"}
  body="$(printf '"action":"gc","expired":[%s],"pending":[%s],"skipped":[%s],"can_apply":true' "$ex" "$pe" "$sk")"
  LC_TOKEN="$(printf '%s\n' "$body" | shasum -a 256 | awk '{print $1}')"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    if [[ "$json" == "1" ]]; then
      fl_doc_emit 0 "$(printf '{"schema_version":%d,"cli_version":"%s","dry_run":true,%s,"token":"%s"}' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$body" "$LC_TOKEN")" plan
      return 0
    fi
    fl_header "benchbar bench gc" "dry-run" "" "" ""
    for row in ${LC_GC_EXPIRED[@]+"${LC_GC_EXPIRED[@]}"}; do fl_note "expired: ${row%%|*} (marked scratch by $(printf '%s' "$row" | cut -d'|' -f5) at $(fl_iso_from_epoch "$(printf '%s' "$row" | cut -d'|' -f6)" 2>/dev/null || printf unknown))"; done
    for row in ${LC_GC_PENDING[@]+"${LC_GC_PENDING[@]}"}; do fl_note "scratch, not yet: ${row%%|*}"; done
    for row in ${LC_GC_SKIPPED[@]+"${LC_GC_SKIPPED[@]}"}; do fl_note "kept: ${row%%|*} ($(printf '%s' "$row" | cut -d'|' -f4))"; done
    if [[ "${#LC_GC_EXPIRED[@]}" -gt 0 ]]; then fl_info "dry-run: benchbar bench gc would remove ${#LC_GC_EXPIRED[@]} bench(es) (benchbar bench remove, each)"
    else fl_info "no scratch bench has expired"; fi
    return 0
  fi
  fl_header "benchbar bench gc" "$(fl_mode_name)" "" "" ""
  if [[ "$LC_APPLY" == "1" && "$LC_TOKEN_IN" != "$LC_TOKEN" ]]; then
    fl_die "The gc plan changed since it was shown (a scratch bench expired, was removed or was marked). Nothing was changed." "Review a fresh plan: benchbar bench gc --dry-run --json, then pass its token."
  fi
  if [[ "${#LC_GC_EXPIRED[@]}" == "0" ]]; then fl_ok "no scratch bench has expired; nothing to do"; return 0; fi
  for row in "${LC_GC_EXPIRED[@]}"; do fl_note "will remove: ${row%%|*} ($(printf '%s' "$row" | cut -d'|' -f3) site(s), marked scratch by $(printf '%s' "$row" | cut -d'|' -f5))"; done
  if [[ "$LC_APPLY" != "1" ]]; then fl_confirm "Back up, drop and move aside these ${#LC_GC_EXPIRED[@]} scratch bench(es)?" || { fl_warn "Cancelled. Nothing was changed."; return 1; }; fi
  for row in "${LC_GC_EXPIRED[@]}"; do
    d="${row%%|*}"
    fl_section "$d"
    fl_context_init "$d" "" ""
    fl_lc_plan remove
    if [[ "$LC_CAN_APPLY" != "1" ]]; then
      fl_fail "skipped ${d}: ${LC_ERRORS[*]}"; code=1; continue
    fi
    fl_lc_remove_run || { code=1; break; }
    done_n=$((done_n + 1)); removed="${removed}${sep}$(fl_json_str "$d")"; sep=","
  done
  [[ "$json" != "1" ]] || fl_doc_emit "$code" "$(printf '{"schema_version":%d,"cli_version":"%s","dry_run":false,"action":"gc","removed":[%s]}' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$removed")"
  fl_ok "gc removed ${done_n} of ${#LC_GC_EXPIRED[@]} expired scratch bench(es)"
  return "$code"
}

fl_cmd_bench() {
  local sub="${1:-}"
  shift || true
  fl_lc_parse "$@"
  case "$sub" in
    forget|remove) fl_cmd_bench_retire "$sub" ;;
    scratch) fl_cmd_bench_scratch ;;
    gc) fl_cmd_bench_gc ;;
    *) fl_die "Unknown bench command: ${sub:-}" "Use: benchbar bench forget PATH | remove PATH | scratch PATH [--ttl DAYS] | gc" ;;
  esac
}

# ---------------------------------------------------------------- db orphans

# fl_lc_db_referenced: the database names every site of every known bench uses, one per line
fl_lc_db_referenced() {
  local d f db
  while IFS= read -r d; do
    for f in "$d"/sites/*/site_config.json; do
      [[ -f "$f" ]] || continue
      fl_site_file_value_v db "$f" db_name
      [[ -z "$db" ]] || printf '%s\n' "$db"
    done
  done < <(fl_lc_benches_all)
}

# fl_lc_db_archived NAME: the archived site folder whose site_config.json names database NAME, if any
fl_lc_db_archived() {
  local d f db
  while IFS= read -r d; do
    for f in "$d"/archived/sites/*/site_config.json; do
      [[ -f "$f" ]] || continue
      fl_site_file_value_v db "$f" db_name
      [[ "$db" == "$1" ]] && { printf '%s' "${f%/site_config.json}"; return 0; }
    done
  done < <(fl_lc_benches_all)
  return 1
}

FL_LC_ORPHAN_NOTE="A database listed here may belong to a bench or a program benchbar does not know (another bench folder it was never told of, another user, a restore in progress). benchbar does not drop them: check the name, back one up (mariadb-dump) and drop it yourself."

# db orphans [--json]: databases of frappe's shape (an underscore and 16 hex digits) that no site of any
# bench benchbar knows refers to. Read only: benchbar never drops them (a person backs one up and drops it).
fl_cmd_db_orphans() {
  local json="${OPT_JSON:-0}" bin dbs db ref rows="" sep="" n=0 checked=0 arch
  fl_site_json_begin
  fl_mariadb_root_password_resolve || fl_die "The MariaDB root password is needed to list the databases." \
    "Ask the person for it (do not look for it), then re-run with: MARIADB_ROOT_PASSWORD='...' benchbar db orphans" 2
  bin="$(fl_mariadb_client)"
  [[ -n "$bin" ]] || fl_die "No mariadb client found." "Run: benchbar doctor"
  dbs="$(MYSQL_PWD="$FL_MARIADB_ROOT_PW" "$bin" -u root --connect-timeout=2 -sNe "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME LIKE '\\_%'" 2>/dev/null)" \
    || fl_die "MariaDB did not answer the list of databases." "Is it running? Run: benchbar doctor"
  ref="$(fl_lc_db_referenced)"
  while IFS= read -r db; do
    [[ "$db" =~ ^_[0-9a-f]{16}$ ]] || continue
    checked=$((checked + 1))
    case $'\n'"$ref"$'\n' in *$'\n'"$db"$'\n'*) continue ;; esac
    arch="$(fl_lc_db_archived "$db" || true)"
    rows="${rows}${sep}{\"name\":$(fl_json_str "$db"),\"archived_site\":$(fl_json_str "$arch")}"; sep=","
    n=$((n + 1))
    [[ "$json" == "1" ]] || fl_note "${db}${arch:+   (the archived site folder ${arch} names it)}"
  done <<<"$dbs"
  if [[ "$json" == "1" ]]; then
    fl_doc_emit 0 "$(printf '{"schema_version":%d,"cli_version":"%s","read_only":true,"checked":%d,"note":%s,"orphans":[%s]}' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$checked" "$(fl_json_str "$FL_LC_ORPHAN_NOTE")" "$rows")"
    return 0
  fi
  if [[ "$n" == "0" ]]; then fl_ok "no orphan database among ${checked} of frappe's shape"
  else fl_info "${n} database(s) of ${checked} have no site in any bench benchbar knows. ${FL_LC_ORPHAN_NOTE}"; fi
}

# ---------------------------------------------------------------- site hosts --prune

# site hosts --prune: the lines "127.0.0.1 NAME" inside benchbar's block of the hosts file whose NAME is
# a site of no bench benchbar knows. One backup, one sudo rewrite. macOS only: Linux has no hosts block.
fl_cmd_site_hosts_prune() {
  local stale=() n known="" d f names="" manual
  if fl_is_linux; then fl_ok "nothing to prune: benchbar does not edit ${FL_HOSTS_FILE} on Linux"; return 0; fi
  while IFS= read -r d; do
    for f in "$d"/sites/*/site_config.json; do [[ -f "$f" ]] && { f="${f%/site_config.json}"; known="${known} ${f##*/} "; }; done
  done < <(fl_lc_benches_all)
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    fl_site_name_ok "$n" || continue
    case "$known" in *" ${n} "*) continue ;; esac
    stale+=("$n"); names="${names} ${n}"
  done < <(awk -v s="$FL_HOSTS_START" -v e="$FL_HOSTS_END" '$0 == s { inside = 1; next } $0 == e { inside = 0; next } inside && NF == 2 && $1 == "127.0.0.1" { print $2 }' "$FL_HOSTS_FILE" 2>/dev/null)
  if [[ "${#stale[@]}" == "0" ]]; then fl_ok "unchanged: every line in benchbar's block of ${FL_HOSTS_FILE} belongs to a site"; return 0; fi
  fl_info "${#stale[@]} line(s) in benchbar's block of ${FL_HOSTS_FILE} name no site of any bench: ${stale[*]}"
  manual="sudo sed -i .bak $(for n in "${stale[@]}"; do printf -- "-e '/^127\\\\.0\\\\.0\\\\.1[[:space:]][[:space:]]*%s[[:space:]]*\$/d' " "${n//./\\\\.}"; done)${FL_HOSTS_FILE}"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then fl_info "dry-run: would remove them (sudo, backup first)"; return 0; fi
  if fl_noninteractive || [[ ! -t 0 ]] || fl_sudo_gui; then fl_note "run in Terminal to remove them: ${manual}"; return 0; fi
  fl_confirm "Remove these ${#stale[@]} line(s) from ${FL_HOSTS_FILE} with sudo?" || { fl_note "kept; to remove them later: ${manual}"; return 0; }
  fl_sudo_begin "remove ${#stale[@]} stale line(s) from ${FL_HOSTS_FILE}" || { fl_warn "skipped without sudo; run: ${manual}"; return 0; }
  fl_backup_file "$FL_HOSTS_FILE" || return 1
  # shellcheck disable=SC2016  # an awk program
  fl_hosts_rewrite "$((-${#stale[@]}))" '
    $0 == ENVIRON["S"] { inside = 1 }
    $0 == ENVIRON["E"] { inside = 0 }
    inside && NF == 2 && $1 == "127.0.0.1" && index(ENVIRON["NAMES"], " " $2 " ") { next }
    { print }' "S=${FL_HOSTS_START}" "E=${FL_HOSTS_END}" "NAMES=${names} " || { fl_note "to remove them: ${manual}"; return 1; }
  fl_changed hosts "${stale[*]}" "lines removed"
  fl_ok "removed ${#stale[@]} line(s) from ${FL_HOSTS_FILE} (backup: ${FL_LAST_BACKUP:-none})"
}
