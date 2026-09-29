#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# site-backups.sh: backing up a site, listing its backups, dropping it.
#
#   benchbar site backup NAME [--with-files] [--json]
#   benchbar site backups NAME --json
#   benchbar site drop NAME --confirm-site NAME [--new-default OTHER] [--json]
#
# A backup is bench's own (bench --site NAME backup): the files land in
# sites/NAME/private/backups as <YYYYmmdd_HHMMSS>-<site_slug>-database.sql.gz
# and friends, and a "set" is the files that share a timestamp.
#
# drop is bench drop-site, which takes a backup with files first and moves
# the site folder to archived/sites/ (nothing is deleted there); benchbar
# adds the refusals (the exact name typed again, never the default site
# without a new default), the MariaDB password on stdin, and the hosts line.

# fl_file_mtime FILE: seconds since the epoch (BSD stat on macOS, GNU on Linux CI).
fl_file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"
}

# fl_iso_from_epoch SECONDS: 2026-09-29T10:15:00Z
fl_iso_from_epoch() {
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

# The timestamps of every backup set in DIR, newest first.
fl_backup_stamps() {
  local f
  for f in "$1"/*; do
    [[ -f "$f" ]] || continue
    basename "$f"
  done | sed -n 's/^\([0-9]\{8\}_[0-9]\{6\}\)-.*/\1/p' | sort -ru
}

# fl_backup_set_json DIR STAMP: one backup set as a JSON object.
#   {"stamp","time","path","database","files","private_files","config",
#    "size_bytes","with_files","encrypted","partial"}
# path is the database file (the one a restore needs), else the first file.
fl_backup_set_json() {
  local dir="$1" stamp="$2" f name db="" pub="" priv="" conf="" size=0 bytes enc=0 partial=0 first="" mtime
  for f in "$dir/${stamp}"-*; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f")"
    [[ -n "$first" ]] || first="$f"
    case "$name" in
      *-database.sql.gz|*-database-enc.sql.gz) db="$f" ;;
      *-private-files.tar|*-private-files.tgz|*-private-files-enc.tar|*-private-files-enc.tgz) priv="$f" ;;
      *-files.tar|*-files.tgz|*-files-enc.tar|*-files-enc.tgz) pub="$f" ;;
      *-site_config_backup.json|*-site_config_backup-enc.json) conf="$f" ;;
      *) continue ;;
    esac
    case "$name" in *-enc.*) enc=1 ;; esac
    case "$name" in *-partial-database*) partial=1 ;; esac
    bytes="$(wc -c <"$f" | tr -d '[:space:]')"
    size=$((size + ${bytes:-0}))
  done
  mtime="$(fl_file_mtime "${db:-$first}")"
  printf '{"stamp":%s,"time":%s,"path":%s,"database":%s,"files":%s,"private_files":%s,"config":%s,"size_bytes":%s,"with_files":%s,"encrypted":%s,"partial":%s}' \
    "$(fl_json_str "$stamp")" "$(fl_json_str "$(fl_iso_from_epoch "$mtime")")" "$(fl_json_str "${db:-$first}")" \
    "$(fl_json_str "$db")" "$(fl_json_str "$pub")" "$(fl_json_str "$priv")" "$(fl_json_str "$conf")" "$size" \
    "$(fl_json_bool "$([[ -n "$pub" || -n "$priv" ]] && printf 1 || printf 0)")" "$(fl_json_bool "$enc")" "$(fl_json_bool "$partial")"
}

# In JSON mode only the JSON goes to stdout (on fd 3); every line of text,
# refusals included, goes to stderr.
fl_site_json_begin() {
  if [[ "$OPT_JSON" == "1" ]]; then exec 3>&1 1>&2; FL_PLAIN=1; fl_ui_init; fi
  return 0
}

fl_site_backup_dir() { printf '%s/sites/%s/private/backups' "$FL_BENCH_DIR" "$1"; }

# "1.2 MB" for the text output
fl_fmt_bytes() {
  awk -v b="$1" 'BEGIN { if (b >= 1073741824) printf "%.1f GB", b / 1073741824; else if (b >= 1048576) printf "%.1f MB", b / 1048576; else printf "%d KB", (b + 1023) / 1024 }'
}

# site backups NAME: every backup set of the site, newest first. Read only.
fl_cmd_site_backups() {
  local name="" json="$OPT_JSON" dir stamp sep="" rows=() set
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -*) fl_die "Unknown option for site backups: $1" "Use: benchbar site backups NAME [--json]" ;;
      *) [[ -z "$name" ]] && name="$1"; shift ;;
    esac
  done
  fl_site_json_begin
  fl_require_bench
  [[ -n "$name" ]] || fl_die "Usage: benchbar site backups NAME [--json]"
  fl_site_valid_name "$name"
  fl_site_require "$name"
  dir="$(fl_site_backup_dir "$name")"
  if [[ "$json" == "1" ]]; then
    {
    printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"site":%s,"folder":%s,"backups":[' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" \
      "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$name")" "$(fl_json_str "$dir")"
    while IFS= read -r stamp; do
      [[ -n "$stamp" ]] || continue
      printf '%s%s' "$sep" "$(fl_backup_set_json "$dir" "$stamp")"; sep=","
    done < <(fl_backup_stamps "$dir")
    printf ']}\n'
    } >&3
    return 0
  fi
  rows+=("Time|Size|Files|Database")
  while IFS= read -r stamp; do
    [[ -n "$stamp" ]] || continue
    set="$(fl_backup_set_json "$dir" "$stamp")"
    rows+=("$(fl_backup_field "$set" time)|$(fl_fmt_bytes "$(fl_backup_field "$set" size_bytes)")|$([[ "$(fl_backup_field "$set" with_files)" == "true" ]] && printf yes || printf no)|$(basename "$(fl_backup_field "$set" path)")")
  done < <(fl_backup_stamps "$dir")
  if [[ "${#rows[@]}" == "1" ]]; then fl_info "no backups of ${name} yet; take one with: benchbar site backup ${name}"; return 0; fi
  fl_table "${rows[@]}"
  fl_note "folder: ${dir}"
}

# fl_backup_field JSON KEY: one scalar of fl_backup_set_json's flat object.
fl_backup_field() {
  printf '%s' "$1" | sed -n "s/.*\"$2\":\"\{0,1\}\([^\",}]*\)\"\{0,1\}[,}].*/\1/p"
}

# site backup NAME [--with-files]: bench --site NAME backup, then the new set.
fl_cmd_site_backup() {
  local name="" with_files=0 json="$OPT_JSON" dir before stamp set args
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --with-files) with_files=1; shift ;;
      -*) fl_die "Unknown option for site backup: $1" "Use: benchbar site backup NAME [--with-files] [--json]" ;;
      *) [[ -z "$name" ]] && name="$1"; shift ;;
    esac
  done
  fl_site_json_begin
  fl_require_bench
  [[ -n "$name" ]] || fl_die "Usage: benchbar site backup NAME [--with-files] [--json]"
  fl_site_valid_name "$name"
  fl_site_require "$name"
  dir="$(fl_site_backup_dir "$name")"
  args=(bench --site "$name" backup)
  [[ "$with_files" == "1" ]] && args+=(--with-files)
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: cd ${FL_BENCH_DIR} && ${args[*]}  (into ${dir})"
    [[ "$json" == "1" ]] && printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"site":%s,"dry_run":true,"backup":null}\n' \
      "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$name")" >&3
    return 0
  fi
  # what bench writes from now on is the new backup: two backups in one
  # second share a timestamp, and bench then overwrites the older files,
  # so the files' age tells, not their names
  before="$(mktemp "${TMPDIR:-/tmp}/benchbar-backup-start.XXXXXX")"
  fl_bench_env_exports
  # frappe reads the site's settings through the bench's Redis cache
  fl_bench_redis_up "$FL_BENCH_DIR"
  if ! fl_bench_run_long "bench --site ${name} backup$([[ "$with_files" == "1" ]] && printf ' --with-files')" "$FL_BENCH_DIR" "${args[@]}"; then
    rm -f "$before"
    fl_bench_redis_down
    fl_die "The backup of ${name} failed." "Run it by hand to see why: cd ${FL_BENCH_DIR} && ${args[*]}"
  fi
  fl_bench_redis_down
  stamp="$(find "$dir" -maxdepth 1 -type f -newer "$before" -name '[0-9]*_[0-9]*-*' 2>/dev/null | sed -n 's#.*/\([0-9]\{8\}_[0-9]\{6\}\)-.*#\1#p' | sort -r | head -n1)"
  rm -f "$before"
  [[ -n "$stamp" ]] || fl_die "bench reported success, but ${dir} has no new backup." "Look in ${dir}"
  set="$(fl_backup_set_json "$dir" "$stamp")"
  if [[ "$json" == "1" ]]; then
    printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"site":%s,"dry_run":false,"backup":%s}\n' \
      "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$name")" "$set" >&3
    return 0
  fi
  fl_ok "backup of ${name}: $(fl_backup_field "$set" path) ($(fl_fmt_bytes "$(fl_backup_field "$set" size_bytes)")$([[ "$with_files" == "1" ]] && printf ', with files'))"
  fl_note "folder: ${dir}"
}

# ---------------------------------------------------------------- drop

# Another bench benchbar knows has a site with this name: its hosts line
# serves that bench too and stays.
fl_site_name_elsewhere() {
  local d
  while IFS= read -r d; do
    [[ -n "$d" && "$d" != "$FL_BENCH_DIR" ]] || continue
    [[ -f "${d}/sites/$1/site_config.json" ]] && { printf '%s' "$d"; return 0; }
  done < <(fl_known_benches)
  return 1
}

# Where the hosts line for NAME is: "block" (inside benchbar's markers,
# benchbar's to remove), "outside" (someone else's), "" (none).
fl_hosts_line_place() {
  local re
  re="$(printf '%s' "$1" | sed 's/\./\\./g')"
  awk -v s="$FL_HOSTS_START" -v e="$FL_HOSTS_END" -v re="^[[:space:]]*127\\.0\\.0\\.1[[:space:]]+${re}[[:space:]]*$" '
    $0 == s { inside = 1; next }
    $0 == e { inside = 0; next }
    $0 ~ re { print (inside ? "block" : "outside"); exit }' "$FL_HOSTS_FILE" 2>/dev/null
}

fl_hosts_manual_removal() {
  local re
  re="$(printf '%s' "$1" | sed 's/\./\\./g')"
  printf "sudo sed -i '' '/^127\\\\.0\\\\.0\\\\.1[[:space:]][[:space:]]*%s[[:space:]]*$/d' %s" "$re" "$FL_HOSTS_FILE"
}

# fl_hosts_remove_name NAME: removes "127.0.0.1 NAME" from benchbar's block,
# one sudo prompt, a backup first. Sets FL_HOSTS_REMOVED (1/0) and
# FL_HOSTS_MANUAL (the command to run when it could not).
fl_hosts_remove_name() {
  local name="$1" place other tmp re
  FL_HOSTS_REMOVED=0; FL_HOSTS_MANUAL=""
  place="$(fl_hosts_line_place "$name")"
  if [[ -z "$place" ]]; then
    fl_ok "unchanged: ${FL_HOSTS_FILE} has no line for ${name}"
    return 0
  fi
  if other="$(fl_site_name_elsewhere "$name")"; then
    fl_ok "kept the ${FL_HOSTS_FILE} line for ${name}: ${other} has a site with that name"
    return 0
  fi
  if [[ "$place" == "outside" ]]; then
    fl_warn "the ${FL_HOSTS_FILE} line for ${name} is outside benchbar's block; left as it is"
    FL_HOSTS_MANUAL="$(fl_hosts_manual_removal "$name")"
    fl_note "to remove it: ${FL_HOSTS_MANUAL}"
    return 0
  fi
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would remove '127.0.0.1 ${name}' from ${FL_HOSTS_FILE} (sudo, backup first)"
    return 0
  fi
  # sudo needs a terminal to ask; without one (the app) say what to run
  if [[ ! -t 0 ]] && ! fl_sudo_available; then
    FL_HOSTS_MANUAL="$(fl_hosts_manual_removal "$name")"
    fl_warn "the ${FL_HOSTS_FILE} line for ${name} needs sudo; run in Terminal: ${FL_HOSTS_MANUAL}"
    return 0
  fi
  if ! fl_sudo_begin "remove '127.0.0.1 ${name}' from ${FL_HOSTS_FILE}"; then
    FL_HOSTS_MANUAL="$(fl_hosts_manual_removal "$name")"
    fl_warn "skipped without sudo; run: ${FL_HOSTS_MANUAL}"
    return 0
  fi
  fl_backup_file "$FL_HOSTS_FILE"
  re="$(printf '%s' "$name" | sed 's/\./\\./g')"
  tmp="$(mktemp "${TMPDIR:-/tmp}/benchbar-hosts.XXXXXX")"
  awk -v s="$FL_HOSTS_START" -v e="$FL_HOSTS_END" -v re="^[[:space:]]*127\\.0\\.0\\.1[[:space:]]+${re}[[:space:]]*$" '
    $0 == s { inside = 1 }
    $0 == e { inside = 0 }
    inside && $0 ~ re { next }
    { print }' "$FL_HOSTS_FILE" >"$tmp"
  sudo cp "$tmp" "$FL_HOSTS_FILE" || { rm -f "$tmp"; fl_fail "sudo cp failed"; FL_HOSTS_MANUAL="$(fl_hosts_manual_removal "$name")"; return 1; }
  rm -f "$tmp"
  FL_HOSTS_REMOVED=1
  fl_ok "removed '127.0.0.1 ${name}' from ${FL_HOSTS_FILE} (backup: ${FL_LAST_BACKUP:-none})"
}

# The newest archived/sites/NAME* folder (bench adds a number when NAME is taken).
fl_site_archive_latest() {
  local d newest="" newest_t=0 t
  for d in "${FL_BENCH_DIR}/archived/sites/$1" "${FL_BENCH_DIR}/archived/sites/$1"[0-9]*; do
    [[ -d "$d" ]] || continue
    t="$(fl_file_mtime "$d")"
    if [[ "$t" -ge "$newest_t" ]]; then newest="$d"; newest_t="$t"; fi
  done
  printf '%s' "$newest"
}

# site drop NAME --confirm-site NAME [--new-default OTHER]
fl_cmd_site_drop() {
  local name="" confirm="" new_default="" json="$OPT_JSON" others=() s st t c p sep="" steps=() archive_before archive="" stamp backup="null" code=0 is_default=0 hosts_place
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --confirm-site) confirm="${2:-}"; shift 2 ;;
      --confirm-site=*) confirm="${1#*=}"; shift ;;
      --new-default) new_default="${2:-}"; shift 2 ;;
      --new-default=*) new_default="${1#*=}"; shift ;;
      -*) fl_die "Unknown option for site drop: $1" "Use: benchbar site drop NAME --confirm-site NAME [--new-default OTHER] [--json]" ;;
      *) [[ -z "$name" ]] && name="$1"; shift ;;
    esac
  done
  fl_site_json_begin
  fl_require_bench
  [[ -n "$name" ]] || fl_die "Usage: benchbar site drop NAME --confirm-site NAME [--new-default OTHER]"
  fl_site_valid_name "$name"
  fl_site_require "$name"
  [[ "$confirm" == "$name" ]] || fl_die "Refusing to drop ${name}: --confirm-site must repeat the site name exactly." \
    "benchbar site drop ${name} --confirm-site ${name}   (bench takes a backup first)"
  while IFS= read -r s; do [[ -n "$s" && "$s" != "$name" ]] && others+=("$s"); done < <(fl_sites_list)
  [[ "$name" == "$FL_SITE" ]] && is_default=1
  if [[ "$is_default" == "1" ]]; then
    [[ "${#others[@]}" -gt 0 ]] || fl_die "${name} is the only site of ${FL_BENCH_DIR}; benchbar does not drop it." \
      "Add another site first (benchbar site add NAME), then drop ${name} with --new-default NAME"
    [[ -n "$new_default" ]] || fl_die "${name} is the default site; say which site takes its place." \
      "benchbar site drop ${name} --confirm-site ${name} --new-default $(printf '%s' "${others[0]}")   (sites: ${others[*]})"
  elif [[ -n "$new_default" ]]; then
    fl_die "--new-default is only for dropping the default site; ${FL_SITE} stays the default." "Leave out --new-default"
  fi
  if [[ -n "$new_default" ]]; then
    [[ "$new_default" != "$name" ]] || fl_die "--new-default cannot be the site that is dropped."
    fl_site_valid_name "$new_default"
    fl_site_require "$new_default"
  fi
  hosts_place="$(fl_hosts_line_place "$name")"

  # the plan: the app shows it before asking, the terminal before running
  [[ -n "$new_default" ]] && steps+=("Make ${new_default} the default site|bench use ${new_default}|0")
  steps+=("Back up ${name} with files, drop its database and user, move the folder to archived/sites|bench drop-site ${name}|0")
  if [[ "$hosts_place" == "block" ]] && ! fl_site_name_elsewhere "$name" >/dev/null; then
    steps+=("Remove '127.0.0.1 ${name}' from ${FL_HOSTS_FILE}|sudo, backup first|1")
  fi
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    if [[ "$json" == "1" ]]; then
      printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"site":%s,"dry_run":true,"is_default":%s,"new_default":%s,"steps":[' \
        "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$name")" "$(fl_json_bool "$is_default")" "$(fl_json_str "$new_default")" >&3
      for st in "${steps[@]}"; do
        IFS='|' read -r t c p <<<"$st"
        printf '%s{"title":%s,"command":%s,"needs_password":%s}' "$sep" "$(fl_json_str "$t")" "$(fl_json_str "$c")" "$(fl_json_bool "$p")" >&3; sep=","
      done
      printf ']}\n' >&3
      return 0
    fi
    fl_info "dry-run: benchbar site drop ${name} would:"
    for s in "${steps[@]}"; do fl_note "${s%%|*}   (${s#*|}; ${s##*|})"; done
    return 0
  fi

  fl_header "benchbar site drop" "$(fl_mode_name)" "$FL_PROFILE" "$FL_BENCH_DIR" "$name"
  fl_mariadb_root_password_resolve || fl_die "The MariaDB root password is needed to drop the database of ${name}." \
    "Re-run with: MARIADB_ROOT_PASSWORD='...' benchbar site drop ${name} --confirm-site ${name}" 2
  if [[ -n "$new_default" ]]; then fl_cmd_site_default "$new_default"; fi
  fl_bench_env_exports
  fl_bench_redis_up "$FL_BENCH_DIR"
  archive_before="$(fl_site_archive_latest "$name")"
  # the password travels on stdin, never on the command line (see FL_PY_FRAPPE_SECRETS)
  FL__DB_PW="$FL_MARIADB_ROOT_PW"
  fl_run_long "bench drop-site ${name}" fl__frappe_with_secrets "$FL_BENCH_DIR" FL__DB_PW -- \
    drop-site "$name" --db-root-password @secret0@ || code=$?
  FL__DB_PW=""
  fl_bench_redis_down
  if [[ "$code" != "0" ]]; then
    fl_die "bench drop-site ${name} failed; the site is still there." \
      "When the backup failed, fix that first. Manual command: cd ${FL_BENCH_DIR} && bench drop-site ${name}"
  fi
  archive="$(fl_site_archive_latest "$name")"
  if [[ -z "$archive" || "$archive" == "$archive_before" || -d "${FL_BENCH_DIR}/sites/${name}" ]]; then
    fl_warn "bench drop-site finished, but no new folder for ${name} is in ${FL_BENCH_DIR}/archived/sites"
    archive=""
  fi
  if [[ -n "$archive" ]]; then
    stamp="$(fl_backup_stamps "${archive}/private/backups" | head -n1)"
    [[ -n "$stamp" ]] && backup="$(fl_backup_set_json "${archive}/private/backups" "$stamp")"
  fi
  fl_hosts_remove_name "$name" || true

  if [[ "$json" == "1" ]]; then
    printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"site":%s,"dry_run":false,"dropped":true,"archived_path":%s,"backup":%s,"new_default":%s,"hosts_removed":%s,"manual_step":%s}\n' \
      "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$name")" "$(fl_json_str "$archive")" \
      "$backup" "$(fl_json_str "$new_default")" "$(fl_json_bool "$FL_HOSTS_REMOVED")" "$(fl_json_str "$FL_HOSTS_MANUAL")" >&3
    return 0
  fi
  fl_ok "dropped ${name}"
  if [[ "$backup" != "null" ]]; then
    fl_note "backup: $(fl_backup_field "$backup" path)"
  fi
  [[ -n "$archive" ]] && fl_note "the site folder is in ${archive}"
  return 0
}
