#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# snapshots.sh: save the state of a site, and put it back.
#
#   benchbar site snapshot SITE [--label TEXT] [--json]
#   benchbar site snapshots SITE [--keep N] [--json]
#   benchbar site rollback SITE --to SNAPSHOT [--no-migrate] --dry-run --json | --apply TOKEN --yes
#   benchbar site snapshot drop SITE SNAPSHOT|--prune [--keep N] [--yes]   (a person only)
#
# A snapshot is bench's own backup with files (database, public and private
# files, site_config), moved at once out of sites/SITE/private/backups, where
# frappe's delete_temp_backups removes everything older than 23 hours, into
# sites/SITE/snapshots/<YYYYmmdd_HHMMSS>[-label]/ next to a manifest.json (time,
# label, the apps of the bench with their commits, sizes). Nothing prunes that
# folder: benchbar never removes a snapshot on its own (see "retention" below).
#
# A rollback is site restore's plan, token and run (site-restore.sh, SR_ROLLBACK=1)
# with the snapshot as the source, a snapshot of the current state first (label
# "before rollback", so a rollback can itself be undone), and migrate only when the
# snapshot's app commits differ from the bench's.
#
# Retention: the newest N snapshots are kept (N is the bench state key SNAPSHOT_KEEP,
# else --keep, else 10). `site snapshots` says which are beyond N; only a person's
# `site snapshot drop SITE --prune` removes them, and never the "before rollback"
# snapshot of the last rollback.

FL_SNAP_KEEP_DEFAULT=10
FL_SNAP_KEEP_OPT=""
FL_SNAP_ID=""
FL_SNAP_JSON="null"
FL_SNAP_ERR=""
FL_SNAP_HINT=""
FL_SNAP_CHANGED=""

# fl_snap_dir SITE: the folder that holds the snapshots of SITE
fl_snap_dir() { printf '%s/sites/%s/snapshots' "$FL_BENCH_DIR" "$1"; }

# fl_snap_slug LABEL: the part of the folder name that says what it is
fl_snap_slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' | cut -c1-40 | sed 's/-$//'
}

# fl_snap_label_ok LABEL: text without control characters, quotes or backslashes
# (the manifest is read back line by line), at most 120 characters
fl_snap_label_ok() {
  [[ "${#1}" -le 120 ]] || return 1
  case "$1" in *[[:cntrl:]]*|*'"'*|*'\'*) return 1 ;; esac
  return 0
}

# fl_snap_keep_v VAR: how many snapshots the retention rule keeps
fl_snap_keep_v() {
  local __v="$FL_SNAP_KEEP_OPT"
  [[ -n "$__v" ]] || __v="$(fl_bstate_get SNAPSHOT_KEEP 2>/dev/null || true)"
  [[ "$__v" =~ ^[1-9][0-9]{0,3}$ ]] || __v="$FL_SNAP_KEEP_DEFAULT"
  printf -v "$1" '%s' "$__v"
}

# fl_snap_ids SITE: the snapshot names, newest first
fl_snap_ids() {
  local d
  for d in "$(fl_snap_dir "$1")"/[0-9]*_[0-9]*; do
    [[ -d "$d" && ! -L "$d" ]] || continue
    basename "$d"
  done | grep -E '^[0-9]{8}_[0-9]{6}' | sort -r
}

# fl_snap_last_rollback SITE: the "before rollback" snapshot of the last rollback, when it is still there
fl_snap_last_rollback() {
  local f id=""
  f="$(fl_snap_dir "$1")/.last-rollback"
  if [[ -f "$f" ]]; then IFS= read -r id <"$f" || true; fi
  [[ "$id" =~ ^[0-9a-z_-]+$ && -d "$(fl_snap_dir "$1")/${id}" ]] && printf '%s' "$id"
  return 0
}

# fl_snap_resolve SITE REF: FL_SNAP_ID from a name, a unique start of one (the stamp) or "latest"
fl_snap_resolve() {
  local site="$1" ref="$2" dir id n=0 hit=""
  FL_SNAP_ID=""; FL_SNAP_ERR=""; FL_SNAP_HINT=""
  if [[ ! "$ref" =~ ^[0-9a-z_-]+$ ]]; then
    FL_SNAP_ERR="'${ref}' is not the name of a snapshot."; FL_SNAP_HINT="benchbar site snapshots ${site} lists them"; return 1
  fi
  dir="$(fl_snap_dir "$site")"
  if [[ "$ref" == "latest" ]]; then
    hit="$(fl_snap_ids "$site" | awk 'NR==1')"
    [[ -n "$hit" ]] || { FL_SNAP_ERR="${site} has no snapshots yet."; FL_SNAP_HINT="benchbar site snapshot ${site} --label TEXT takes one"; return 1; }
    FL_SNAP_ID="$hit"; return 0
  fi
  if [[ -d "${dir}/${ref}" && ! -L "${dir}/${ref}" ]]; then FL_SNAP_ID="$ref"; return 0; fi
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    case "$id" in "${ref}"*) n=$((n + 1)); hit="$id" ;; esac
  done < <(fl_snap_ids "$site")
  if [[ "$n" == "1" ]]; then FL_SNAP_ID="$hit"; return 0; fi
  if [[ "$n" == "0" ]]; then FL_SNAP_ERR="no snapshot '${ref}' of ${site}."; else FL_SNAP_ERR="'${ref}' matches ${n} snapshots of ${site}."; fi
  FL_SNAP_HINT="benchbar site snapshots ${site} lists them"
  return 1
}

# ------------------------------------------------- the manifest

# fl_snap_mfield FILE KEY: one value of the manifest (a line ` "KEY": VALUE,`)
fl_snap_mfield() {
  local v
  v="$(sed -n -E "s/^ \"$2\": \"(.*)\",?\$/\\1/p" "$1" 2>/dev/null | head -n 1)"
  if [[ -z "$v" ]]; then v="$(sed -n -E "s/^ \"$2\": ([^\",]*),?\$/\\1/p" "$1" 2>/dev/null | head -n 1)"; fi
  printf '%s' "$v"
}

# fl_snap_apps_list FILE: name|commit|branch of each app the manifest names
fl_snap_apps_list() {
  sed -n -E 's/^ *\{"name": "([^"]*)", "commit": "([^"]*)", "branch": "([^"]*)"\},?$/\1|\2|\3/p' "$1" 2>/dev/null
}

# fl_snap_bench_apps: name|commit|branch of the git apps of this bench, as the manifest records them
fl_snap_bench_apps() {
  local a
  while IFS= read -r a; do
    [[ -n "$a" ]] && fl_app_has_git "$a" || continue
    printf '%s|%s|%s\n' "$a" "$(fl_app_commit "$a")" "$(fl_app_branch "$a")"
  done < <(fl_apps_all)
}

# fl_snap_apps_diff FILE: 0 when the bench's apps are the snapshot's (same names, same commits), 1 when
# they differ (FL_SNAP_CHANGED names them), 2 when the manifest has no app list
fl_snap_apps_diff() {
  local name commit branch cur seen=" " n=0 changed="" a
  FL_SNAP_CHANGED=""
  while IFS='|' read -r name commit branch; do
    [[ -n "$name" ]] || continue
    n=$((n + 1)); seen="${seen}${name} "
    cur="$(fl_app_commit "$name")"
    [[ "$cur" == "$commit" ]] || changed="${changed}${changed:+ }${name}"
  done < <(fl_snap_apps_list "$1")
  [[ "$n" -gt 0 ]] || return 2
  while IFS= read -r a; do
    [[ -n "$a" ]] || continue
    case "$seen" in *" ${a} "*) ;; *) fl_app_has_git "$a" && changed="${changed}${changed:+ }${a}" ;; esac
  done < <(fl_apps_all)
  FL_SNAP_CHANGED="$changed"
  [[ -z "$changed" ]]
}

# fl_snap_manifest_write FILE ID SITE LABEL STAMP TIME DB_BYTES BYTES ROLLBACK_OF
fl_snap_manifest_write() {
  local file="$1" name commit branch sep=""
  {
    printf '{\n'
    printf ' "snapshot_version": 1,\n'
    printf ' "id": %s,\n' "$(fl_json_str "$2")"
    printf ' "site": %s,\n' "$(fl_json_str "$3")"
    printf ' "label": %s,\n' "$(fl_json_str "$4")"
    printf ' "stamp": %s,\n' "$(fl_json_str "$5")"
    printf ' "time": %s,\n' "$(fl_json_str "$6")"
    printf ' "db_size_bytes": %s,\n' "$7"
    printf ' "size_bytes": %s,\n' "$8"
    printf ' "rollback_of": %s,\n' "$(fl_json_str "$9")"
    printf ' "apps": [\n'
    while IFS='|' read -r name commit branch; do
      [[ -n "$name" ]] || continue
      printf '%s  {"name": %s, "commit": %s, "branch": %s}' "$sep" "$(fl_json_str "$name")" "$(fl_json_str "$commit")" "$(fl_json_str "$branch")"
      sep=$',\n'
    done < <(fl_snap_bench_apps)
    printf '\n ]\n}\n'
  } >"$file"
}

# fl_snap_json SITE ID: one snapshot as a JSON object
#   {"id","site","label","time","stamp","path","size_bytes","db_size_bytes","with_files","complete",
#    "rollback_of","before_rollback","apps":[{name,commit,branch}],"apps_match","changed_apps"}
# apps_match is true, false (the bench's apps changed since) or null (the snapshot lists none).
fl_snap_json() {
  local site="$1" id="$2" d m stamp set size=0 dbsize=0 files=false complete=false time label rb apps="" sep="" name commit branch rc=0 match=null chg="" before=false
  d="$(fl_snap_dir "$site")/${id}"; m="${d}/manifest.json"
  stamp="${id:0:15}"
  set=""
  if compgen -G "${d}/${stamp}-*" >/dev/null; then set="$(fl_backup_set_json "$d" "$stamp")"; fi
  if [[ -n "$set" ]]; then
    size="$(fl_backup_field "$set" size_bytes)"; files="$(fl_backup_field "$set" with_files)"; complete="$(fl_backup_field "$set" complete)"
    dbsize="$(fl_snap_mfield "$m" db_size_bytes)"
    [[ "$dbsize" =~ ^[0-9]+$ ]] || dbsize=0
  fi
  time="$(fl_snap_mfield "$m" time)"
  [[ -n "$time" || -z "$set" ]] || time="$(fl_backup_field "$set" time)"
  label="$(fl_snap_mfield "$m" label)"
  rb="$(fl_snap_mfield "$m" rollback_of)"
  [[ -f "$m" ]] || complete=false
  while IFS='|' read -r name commit branch; do
    [[ -n "$name" ]] || continue
    apps="${apps}${sep}{\"name\":$(fl_json_str "$name"),\"commit\":$(fl_json_str "$commit"),\"branch\":$(fl_json_str "$branch")}"; sep=","
  done < <(fl_snap_apps_list "$m")
  fl_snap_apps_diff "$m" || rc=$?
  case "$rc" in 0) match=true ;; 1) match=false ;; esac
  # shellcheck disable=SC2086  # the app names, split
  chg="$(fl_json_str_array $FL_SNAP_CHANGED)"
  [[ "$(fl_snap_last_rollback "$site")" == "$id" ]] && before=true
  printf '{"id":%s,"site":%s,"label":%s,"time":%s,"stamp":%s,"path":%s,"size_bytes":%s,"db_size_bytes":%s,"with_files":%s,"complete":%s,"rollback_of":%s,"before_rollback":%s,"apps":[%s],"apps_match":%s,"changed_apps":%s}' \
    "$(fl_json_str "$id")" "$(fl_json_str "$site")" "$(fl_json_str "$label")" "$(fl_json_str "$time")" "$(fl_json_str "$stamp")" "$(fl_json_str "$d")" \
    "${size:-0}" "$dbsize" "${files:-false}" "${complete:-false}" "$(fl_json_str "$rb")" "$before" "$apps" "$match" "$chg"
}

# fl_snap_over_limit SITE KEEP: the snapshots beyond the newest KEEP, one per line, never the one
# the last rollback made to be undone with
fl_snap_over_limit() {
  local id i=0 protected
  protected="$(fl_snap_last_rollback "$1")"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    i=$((i + 1))
    [[ "$i" -gt "$2" && "$id" != "$protected" ]] || continue
    printf '%s\n' "$id"
  done < <(fl_snap_ids "$1")
}

# ------------------------------------------------- taking one

# fl_snap_take SITE LABEL [ROLLBACK_OF]: bench backup --with-files, then its files moved into the
# snapshot folder with the manifest. Sets FL_SNAP_ID and FL_SNAP_JSON; on a failure returns 1 with
# FL_SNAP_ERR and FL_SNAP_HINT, and the backup (when it was made) stays in private/backups. The caller
# has made the bench's Redis available (fl_bench_redis_up) and stops it afterwards.
fl_snap_take() {
  local site="$1" label="$2" rto="${3:-}" bdir sdir id stamp set slug root n=1 f name k moved=() mtime dbfile db_bytes total
  FL_SNAP_ID=""; FL_SNAP_JSON="null"; FL_SNAP_ERR=""; FL_SNAP_HINT=""
  if ! fl_site_backup_take "$site" 1; then
    FL_SNAP_ERR="$FL_BACKUP_TAKEN_ERR"; FL_SNAP_HINT="$FL_BACKUP_TAKEN_HINT"
    return 1
  fi
  stamp="$FL_BACKUP_TAKEN_STAMP"; set="$FL_BACKUP_TAKEN_SET"
  bdir="$(fl_site_backup_dir "$site")"
  for k in database files private_files; do
    case "$(fl_backup_field "$set" "$k")" in
      ""|null) FL_SNAP_ERR="the backup ${stamp} of ${site} has no ${k} part, so it is not a snapshot."; FL_SNAP_HINT="Look in ${bdir}"; return 1 ;;
    esac
  done
  if [[ "$(fl_backup_field "$set" encrypted)" == "true" ]]; then
    FL_SNAP_ERR="the backup ${stamp} of ${site} is encrypted, and a restore takes a plain set."
    FL_SNAP_HINT="It stays in ${bdir}; take the snapshot with the encryption of backups off"
    return 1
  fi
  if ! fl_backup_set_check "$bdir" "$(basename "$(fl_backup_field "$set" database)")" "$(basename "$(fl_backup_field "$set" files)")" "$(basename "$(fl_backup_field "$set" private_files)")"; then
    FL_SNAP_ERR="${FL_BACKUP_PROBLEM}; no snapshot was made."; FL_SNAP_HINT="Look in ${bdir}"
    return 1
  fi
  slug="$(fl_snap_slug "$label")"
  root="$(fl_snap_dir "$site")"
  id="${stamp}${slug:+-${slug}}"
  while [[ -e "${root}/${id}" ]]; do n=$((n + 1)); id="${stamp}${slug:+-${slug}}-${n}"; done
  sdir="${root}/${id}"
  mkdir -p "$sdir" 2>/dev/null && chmod 700 "$root" 2>/dev/null || { FL_SNAP_ERR="could not make ${sdir}."; FL_SNAP_HINT="Look at the permissions of sites/${site}"; return 1; }
  # a rename inside sites/SITE: no copy, no second set of bytes
  for f in "$bdir/${stamp}"-*; do
    [[ -f "$f" ]] || continue
    name="${f##*/}"
    if mv "$f" "${sdir}/${name}" 2>/dev/null; then
      moved+=("$name")
    else
      for name in ${moved[@]+"${moved[@]}"}; do mv "${sdir}/${name}" "${bdir}/${name}" 2>/dev/null || true; done
      rmdir "$sdir" 2>/dev/null || true
      FL_SNAP_ERR="could not move ${f##*/} into ${sdir}; the backup is back in ${bdir}."; FL_SNAP_HINT="Look at the permissions of ${root}"
      return 1
    fi
  done
  dbfile="$(fl_backup_field "$set" database)"
  db_bytes="$(wc -c <"${sdir}/$(basename "$dbfile")" | tr -d '[:space:]')"
  total="$(fl_backup_field "$set" size_bytes)"
  mtime="$(fl_backup_field "$set" time)"
  fl_snap_manifest_write "${sdir}/manifest.json" "$id" "$site" "$label" "$stamp" "$mtime" "${db_bytes:-0}" "${total:-0}" "$rto"
  FL_SNAP_ID="$id"
  FL_SNAP_JSON="$(fl_snap_json "$site" "$id")"
}

# the step a rollback takes before it replaces anything (site-restore.sh runs fl_pull_step_<id>)
fl_pull_step_snapshot() {
  fl_bench_env_exports
  # frappe reads the site's settings through the bench's Redis cache (a stopped bench has none running)
  [[ -n "$FL_SETUP_REDIS_PORTS" ]] || fl_bench_redis_up "$FL_BENCH_DIR"
  if ! fl_snap_take "$SR_TARGET" "before rollback" "$SR_SNAP_ID"; then
    fl_fail "${FL_SNAP_ERR} Nothing was replaced."
    [[ -z "$FL_SNAP_HINT" ]] || fl_fix "$FL_SNAP_HINT"
    return 1
  fi
  printf '%s\n' "$FL_SNAP_ID" >"$(fl_snap_dir "$SR_TARGET")/.last-rollback"
  SR_BEFORE_SNAPSHOT="$FL_SNAP_ID"
  SR_RESULT_EXTRA="$(printf ',"rollback":{"snapshot":%s,"before_rollback":%s,"undo":%s}' "$(fl_json_str "$SR_SNAP_ID")" "$(fl_json_str "$FL_SNAP_ID")" \
    "$(fl_json_str "benchbar site rollback ${SR_TARGET} --to ${FL_SNAP_ID}")")"
  fl_ok "snapshot ${FL_SNAP_ID} of ${SR_TARGET} ($(fl_fmt_bytes "$(fl_backup_field "$FL_SNAP_JSON" size_bytes)")); undo this rollback with: benchbar site rollback ${SR_TARGET} --to ${FL_SNAP_ID}"
  fl_changed snapshot "$SR_TARGET" "$FL_SNAP_ID"
}

# fl_snap_plan_hook: what only a rollback adds to site restore's plan (called from fl_srestore_plan)
fl_snap_plan_hook() {
  local m="${SR_SNAP_DIR}/manifest.json" bench_default rc=0 match=null label time chg="" word
  SR_NOTES=(); SR_MIGRATE_TEXT=""; SR_IS_DEFAULT=0; SR_MIGRATE_AUTO=0; SR_PLAN_EXTRA=""
  fl_site_default_file_v bench_default
  if [[ "$SR_TARGET" == "$FL_SITE" || "$SR_TARGET" == "$bench_default" ]]; then
    SR_IS_DEFAULT=1
    if fl_noninteractive; then
      fl_srestore_err "${SR_TARGET} is the default site of this bench: rolling it back is a person's decision, not an agent's. Ask the person to run it in a terminal: benchbar site rollback ${SR_TARGET} --to ${SR_SNAP_ID}"
    fi
  fi
  fl_snap_apps_diff "$m" || rc=$?
  case "$rc" in
    0)
      match=true
      # the data of a snapshot made with these apps needs no migrate with them (--no-migrate keeps its own wording)
      if [[ "$FL_PULL_NO_MIGRATE" != "1" ]]; then FL_PULL_NO_MIGRATE=1; SR_MIGRATE_AUTO=1; SR_MIGRATE_TEXT="not run: the apps are the snapshot's apps, so the schema matches"; fi ;;
    1)
      match=false
      word="the bench's apps changed since the snapshot (${FL_SNAP_CHANGED}); its data goes into the bench's current code"
      SR_NOTES+=("$word")
      FL_PULL_WARNINGS="${FL_PULL_WARNINGS}${FL_PULL_WARNINGS:+,}$(fl_json_str "$word")"
      if [[ "$FL_PULL_NO_MIGRATE" == "1" ]]; then SR_MIGRATE_TEXT="not run (--no-migrate), though the apps changed since the snapshot (${FL_SNAP_CHANGED})"
      else SR_MIGRATE_TEXT="after the restore, because the apps changed since the snapshot (${FL_SNAP_CHANGED})"; fi ;;
    *) [[ "$FL_PULL_NO_MIGRATE" == "1" ]] || SR_MIGRATE_TEXT="after the restore (the snapshot lists no apps to compare)" ;;
  esac
  label="$(fl_snap_mfield "$m" label)"; time="$(fl_snap_mfield "$m" time)"
  # shellcheck disable=SC2086  # the app names, split
  chg="$(fl_json_str_array $FL_SNAP_CHANGED)"
  SR_PLAN_EXTRA="$(printf '"rollback":{"snapshot":%s,"label":%s,"time":%s,"snapshot_first":"before rollback","apps_match":%s,"changed_apps":%s,"default_site":%s}' \
    "$(fl_json_str "$SR_SNAP_ID")" "$(fl_json_str "$label")" "$(fl_json_str "$time")" "$match" "$chg" "$(fl_json_bool "$SR_IS_DEFAULT")")"
}

# ------------------------------------------------- commands

# site snapshot SITE [--label TEXT]   (and: site snapshot drop ...)
fl_cmd_site_snapshot() {
  local name="" label="" json="$OPT_JSON" set keep over
  if [[ "${1:-}" == "drop" ]]; then shift; fl_cmd_site_snapshot_drop "$@"; return; fi
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --label) label="${2:-}"; shift 2 || shift ;;
      --label=*) label="${1#*=}"; shift ;;
      -*) fl_die "Unknown option for site snapshot: $1" "Use: benchbar site snapshot SITE [--label TEXT] [--json]" ;;
      *) [[ -z "$name" ]] && name="$1"; shift ;;
    esac
  done
  fl_site_json_begin
  fl_require_bench
  [[ -n "$name" ]] || fl_die "Usage: benchbar site snapshot SITE [--label TEXT] [--json]"
  fl_site_valid_name "$name"
  fl_site_require "$name"
  fl_snap_label_ok "$label" || fl_die "The label may be 120 characters, with no quotes, backslashes or control characters." "Use: benchbar site snapshot ${name} --label \"before the upgrade\""
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: cd ${FL_BENCH_DIR} && bench --site ${name} backup --with-files, then its files move into $(fl_snap_dir "$name")/"
    [[ "$json" == "1" ]] && fl_doc_emit 0 "$(printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"site":%s,"dry_run":true,"snapshot":null}' \
      "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$name")")" plan
    return 0
  fi
  fl_bench_env_exports
  # frappe reads the site's settings through the bench's Redis cache
  fl_bench_redis_up "$FL_BENCH_DIR"
  if ! fl_snap_take "$name" "$label"; then
    fl_bench_redis_down
    fl_die "$FL_SNAP_ERR" "$FL_SNAP_HINT"
  fi
  fl_bench_redis_down
  set="$FL_SNAP_JSON"
  fl_changed snapshot "$name" "$FL_SNAP_ID"
  fl_snap_keep_v keep
  over="$(fl_snap_over_limit "$name" "$keep")"
  if [[ "$json" == "1" ]]; then
    # shellcheck disable=SC2086  # one name per line
    fl_doc_emit 0 "$(printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"site":%s,"dry_run":false,"snapshot":%s,"keep":%s,"over_limit":%s}' \
      "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$name")" "$set" "$keep" "$(fl_json_str_array $over)")"
    return 0
  fi
  fl_ok "snapshot ${FL_SNAP_ID} of ${name} ($(fl_fmt_bytes "$(fl_backup_field "$set" size_bytes)"), with files)"
  fl_note "folder: $(fl_snap_dir "$name")/${FL_SNAP_ID}"
  fl_note "put it back with: benchbar site rollback ${name} --to ${FL_SNAP_ID} --dry-run --json, then --apply TOKEN --yes"
  [[ -z "$over" ]] || fl_note "$(printf '%s\n' "$over" | wc -l | tr -d ' ') snapshot(s) are beyond the newest ${keep}; nothing is removed on its own (benchbar site snapshots ${name} says which)"
}

# site snapshots SITE [--keep N]: newest first. Read only.
fl_cmd_site_snapshots() {
  local name="" json="$OPT_JSON" dir id sep="" rows=() set keep over last apps n=0 rc
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --keep) FL_SNAP_KEEP_OPT="${2:-}"; shift 2 || shift ;;
      --keep=*) FL_SNAP_KEEP_OPT="${1#*=}"; shift ;;
      -*) fl_die "Unknown option for site snapshots: $1" "Use: benchbar site snapshots SITE [--keep N] [--json]" ;;
      *) [[ -z "$name" ]] && name="$1"; shift ;;
    esac
  done
  fl_site_json_begin
  fl_require_bench
  [[ -n "$name" ]] || fl_die "Usage: benchbar site snapshots SITE [--keep N] [--json]"
  fl_site_valid_name "$name"
  fl_site_require "$name"
  dir="$(fl_snap_dir "$name")"
  fl_snap_keep_v keep
  over="$(fl_snap_over_limit "$name" "$keep")"
  last="$(fl_snap_last_rollback "$name")"
  if [[ "$json" == "1" ]]; then
    {
    printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"site":%s,"folder":%s,"keep":%s,"snapshots":[' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" \
      "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$name")" "$(fl_json_str "$dir")" "$keep"
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      printf '%s%s' "$sep" "$(fl_snap_json "$name" "$id")"; sep=","
    done < <(fl_snap_ids "$name")
    # shellcheck disable=SC2086  # one name per line
    printf '],"over_limit":%s,"last_rollback_snapshot":%s}\n' "$(fl_json_str_array $over)" "$(fl_json_str "$last")"
    } >&3
    return 0
  fi
  rows+=("Snapshot|Label|Size|Apps")
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    n=$((n + 1))
    set="$(fl_snap_json "$name" "$id")"
    rc=0; fl_snap_apps_diff "${dir}/${id}/manifest.json" || rc=$?
    case "$rc" in
      0) apps="same as the bench" ;;
      1) apps="bench changed: ${FL_SNAP_CHANGED}" ;;
      *) apps="not recorded" ;;
    esac
    [[ "$(fl_backup_field "$set" complete)" == "true" ]] || apps="${apps} (incomplete)"
    rows+=("${id}|$(fl_snap_mfield "${dir}/${id}/manifest.json" label)$([[ "$id" == "$last" ]] && printf ' (undo point of the last rollback)')|$(fl_fmt_bytes "$(fl_backup_field "$set" size_bytes)")|${apps}")
  done < <(fl_snap_ids "$name")
  if [[ "$n" == "0" ]]; then fl_info "no snapshots of ${name} yet; take one with: benchbar site snapshot ${name} --label TEXT"; return 0; fi
  fl_table "${rows[@]}"
  fl_note "folder: ${dir}"
  if [[ -n "$over" ]]; then
    fl_note "retention keeps the newest ${keep}; beyond it: $(printf '%s' "$over" | tr '\n' ' ')"
    fl_note "nothing is removed on its own; a person removes them with: benchbar site snapshot drop ${name} --prune"
  fi
}

# site rollback SITE --to SNAPSHOT [--no-migrate] --dry-run --json | --apply TOKEN --yes
fl_cmd_site_rollback() {
  local name="" to="" rargs=()
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --to) to="${2:-}"; shift 2 || shift ;;
      --to=*) to="${1#*=}"; shift ;;
      --no-migrate) rargs+=(--no-migrate); shift ;;
      --apply) rargs+=(--apply "${2:-}"); shift 2 || shift ;;
      --apply=*) rargs+=("$1"); shift ;;
      -*) fl_die "Unknown option for site rollback: $1" "Use: benchbar site rollback SITE --to SNAPSHOT [--no-migrate] --dry-run --json, then --apply TOKEN --yes" ;;
      *) [[ -z "$name" ]] && name="$1"; shift ;;
    esac
  done
  fl_site_json_begin
  fl_require_bench
  fl_require_plain_bench
  [[ -n "$name" ]] || fl_die "Usage: benchbar site rollback SITE --to SNAPSHOT [--no-migrate] --dry-run --json, then --apply TOKEN --yes"
  fl_site_valid_name "$name"
  [[ -n "$to" ]] || fl_die "--to SNAPSHOT names the snapshot to go back to (benchbar site snapshots ${name} lists them; latest is the newest)."
  fl_site_require "$name"
  fl_snap_resolve "$name" "$to" || fl_die "$FL_SNAP_ERR" "$FL_SNAP_HINT"
  SR_ROLLBACK=1
  SR_SNAP_ID="$FL_SNAP_ID"
  SR_SNAP_DIR="$(fl_snap_dir "$name")/${FL_SNAP_ID}"
  fl_cmd_site_restore "$name" --from "$SR_SNAP_DIR" --with-files ${rargs[@]+"${rargs[@]}"}
}

# fl_snap_remove SITE ID: the files of one snapshot, then its folder. A person's decision (the callers
# refuse an agent); never a recursive delete: a folder with anything else in it stays.
fl_snap_remove() {
  local dir f
  dir="$(fl_snap_dir "$1")/$2"
  [[ -d "$dir" && ! -L "$dir" ]] || return 1
  for f in "$dir"/*; do
    [[ -f "$f" && ! -L "$f" ]] && rm -f "$f"
  done
  rmdir "$dir" 2>/dev/null || { fl_warn "${dir} holds more than a snapshot's files; it stays"; return 1; }
  if [[ "$(cat "$(fl_snap_dir "$1")/.last-rollback" 2>/dev/null || true)" == "$2" ]]; then rm -f "$(fl_snap_dir "$1")/.last-rollback"; fi
  return 0
}

# site snapshot drop SITE SNAPSHOT | --prune [--keep N] [--yes] [--dry-run]
fl_cmd_site_snapshot_drop() {
  local name="" ref="" prune=0 json="$OPT_JSON" ids=() id keep freed=0 set b dropped=() want
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --prune) prune=1; shift ;;
      --keep) FL_SNAP_KEEP_OPT="${2:-}"; shift 2 || shift ;;
      --keep=*) FL_SNAP_KEEP_OPT="${1#*=}"; shift ;;
      -*) fl_die "Unknown option for site snapshot drop: $1" "Use: benchbar site snapshot drop SITE SNAPSHOT|--prune [--keep N] [--yes] [--dry-run]" ;;
      *) if [[ -z "$name" ]]; then name="$1"; elif [[ -z "$ref" ]]; then ref="$1"; fi; shift ;;
    esac
  done
  fl_site_json_begin
  fl_require_bench
  [[ -n "$name" ]] || fl_die "Usage: benchbar site snapshot drop SITE SNAPSHOT|--prune [--keep N] [--yes] [--dry-run]"
  fl_site_valid_name "$name"
  fl_site_require "$name"
  # the plan is open to an agent; removing is a person's decision (the preflight refuses first, this is the second lock)
  if [[ "${FL_DRY_RUN:-0}" != "1" ]] && fl_noninteractive; then
    fl_die "Removing a snapshot is a person's decision, not an agent's." "Read what would go with --dry-run, then ask the person to run benchbar site snapshot drop ${name} ... in a terminal"
  fi
  if [[ "$prune" == "1" ]]; then
    [[ -z "$ref" ]] || fl_die "--prune takes no snapshot name: it removes the ones beyond the newest N." "Use: benchbar site snapshot drop ${name} --prune [--keep N]"
    fl_snap_keep_v keep
    while IFS= read -r id; do [[ -n "$id" ]] && ids+=("$id"); done < <(fl_snap_over_limit "$name" "$keep")
  else
    [[ -n "$ref" ]] || fl_die "Name the snapshot to remove, or use --prune." "benchbar site snapshots ${name} lists them"
    fl_snap_resolve "$name" "$ref" || fl_die "$FL_SNAP_ERR" "$FL_SNAP_HINT"
    ids+=("$FL_SNAP_ID")
  fi
  for id in ${ids[@]+"${ids[@]}"}; do
    set="$(fl_snap_json "$name" "$id")"
    b="$(fl_backup_field "$set" size_bytes)"; freed=$((freed + ${b:-0}))
  done
  if [[ "${FL_DRY_RUN:-0}" == "1" || "${#ids[@]}" == "0" ]]; then
    if [[ "$json" == "1" ]]; then
      # shellcheck disable=SC2086
      fl_doc_emit 0 "$(printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"site":%s,"dry_run":%s,"would_drop":%s,"dropped":[],"freed_bytes":%s}' \
        "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$name")" "$(fl_json_bool "$([[ "${FL_DRY_RUN:-0}" == "1" ]] && printf 1 || printf 0)")" \
        "$(fl_json_str_array ${ids[@]+"${ids[@]}"})" "$freed")" plan
      return 0
    fi
    if [[ "${#ids[@]}" == "0" ]]; then fl_ok "unchanged: no snapshot of ${name} is beyond the newest ${keep:-the limit}"; return 0; fi
    fl_info "dry-run: would remove ${#ids[@]} snapshot(s) of ${name} ($(fl_fmt_bytes "$freed")): ${ids[*]}"
    return 0
  fi
  want="Remove ${#ids[@]} snapshot(s) of ${name} (${ids[*]}), $(fl_fmt_bytes "$freed")? This cannot be undone."
  fl_confirm "$want" || { fl_warn "Cancelled. Nothing was removed."; return 1; }
  for id in "${ids[@]}"; do
    if fl_snap_remove "$name" "$id"; then dropped+=("$id"); fl_changed snapshot "$name" "removed ${id}"; fi
  done
  if [[ "$json" == "1" ]]; then
    fl_doc_emit 0 "$(printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"site":%s,"dry_run":false,"dropped":%s,"freed_bytes":%s}' \
      "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$name")" "$(fl_json_str_array ${dropped[@]+"${dropped[@]}"})" "$freed")"
    return 0
  fi
  fl_ok "removed ${#dropped[@]} snapshot(s) of ${name}: ${dropped[*]:-none}"
}
