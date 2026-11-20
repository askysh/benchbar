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
  local m
  # each form counts only as a number (GNU stat -f prints file system text)
  m="$(stat -c %Y "$1" 2>/dev/null)" || true
  [[ "$m" =~ ^[0-9]+$ ]] || m="$(stat -f %m "$1" 2>/dev/null)" || true
  [[ "$m" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$m"
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
#    "size_bytes","with_files","encrypted","partial","complete"}
# path is the database file (the one a restore needs), else the first file.
# complete is false for a partial set, one without a database file and one
# with an empty part; fl_backup_set_check reads the files themselves.
fl_backup_set_json() {
  local dir="$1" stamp="$2" f name db="" pub="" priv="" conf="" size=0 bytes enc=0 partial=0 first="" mtime complete=1
  for f in "$dir/${stamp}"-*; do
    [[ -f "$f" ]] || continue
    name="${f##*/}"
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
    # a part with no bytes is a set that cannot be restored (the cheap half of
    # fl_backup_set_check; the listing must not read every dump)
    [[ "${bytes:-0}" -gt 0 ]] || complete=0
  done
  [[ -n "$db" && "$partial" == "0" ]] || complete=0
  mtime="$(fl_file_mtime "${db:-$first}")"
  printf '{"stamp":%s,"time":%s,"path":%s,"database":%s,"files":%s,"private_files":%s,"config":%s,"size_bytes":%s,"with_files":%s,"encrypted":%s,"partial":%s,"complete":%s}' \
    "$(fl_json_str "$stamp")" "$(fl_json_str "$(fl_iso_from_epoch "$mtime")")" "$(fl_json_str "${db:-$first}")" \
    "$(fl_json_str "$db")" "$(fl_json_str "$pub")" "$(fl_json_str "$priv")" "$(fl_json_str "$conf")" "$size" \
    "$(fl_json_bool "$([[ -n "$pub" || -n "$priv" ]] && printf 1 || printf 0)")" "$(fl_json_bool "$enc")" "$(fl_json_bool "$partial")" "$(fl_json_bool "$complete")"
}

# ------------------------------------------------- keep older backups

# bench's backup (and with it site restore, site drop, pull --replace and app
# update, which take one first) runs frappe's delete_temp_backups, which
# removes every file in the site's private/backups older than
# keep_backups_for_hours (23 by default). A safety net from Monday would be
# gone on Wednesday, so benchbar keeps what is there: before bench runs, every
# file of the folder gets a second name under the state backups
# (<stamp>/kept-sets/<site>/, a hard link on the same volume, else a copy) and
# after it a file that went is put back. It never changes the site's config
# and never deletes a backup. benchbar prunes nothing in a site's backup
# folder: those files are the site's to remove.
#
# While bench runs, the kept copy may be the only copy. So:
#   - a run that is cut short (Ctrl-C, TERM, HUP) puts the files back in its
#     exit trap (fl_backups_keep_on_exit);
#   - a run that is killed without a trap, a put back that failed and a site
#     drop that found no archive leave the folder behind. Such a folder is never
#     pruned (fl_state_prune), the next fl_backups_keep_begin puts back what is
#     missing, and until then doctor warns (kept_backups; repair puts back).
# Each kept folder holds ".from", the folder its files came from.
FL_KEEP_DIR=""
FL_KEEP_COUNT=0
FL_KEEP_RESTORED=0
FL_KEEP_LEFT=0

# fl_kept_root: the folder that holds <stamp>/kept-sets
fl_kept_root() { printf '%s' "${FL_BACKUP_ROOT:-${FL_STATE_DIR}/backups}"; }

# fl_kept_dirs [BENCH_DIR]: every kept folder that still holds a file, one per
# line; with BENCH_DIR only those whose files came from that bench
fl_kept_dirs() {
  local d f from
  for d in "$(fl_kept_root)"/*/kept-sets/*; do
    [[ -d "$d" && ! -L "$d" ]] || continue
    if [[ -n "${1:-}" ]]; then
      from=""
      if [[ -f "${d}/.from" ]]; then IFS= read -r from <"${d}/.from" || true; fi
      case "$from" in "${1}"/*) ;; *) continue ;; esac
    fi
    for f in "$d"/*; do
      [[ -f "$f" ]] || continue
      printf '%s\n' "$d"
      break
    done
  done
}

# fl_kept_target KDIR: the folder the files of KDIR go back to: where they came
# from, else (a site that bench drop-site moved) the newest archived folder of
# the site next to it. Empty when there is none.
fl_kept_target() {
  local kdir="$1" from="" site base a
  if [[ -f "${kdir}/.from" ]]; then IFS= read -r from <"${kdir}/.from" || true; fi
  [[ -n "$from" ]] || from="$(fl_site_backup_dir "${kdir##*/}")"
  if [[ -d "$from" ]]; then printf '%s' "$from"; return 0; fi
  # <bench>/sites/<site>/private/backups -> <bench>/archived/sites/<site>*/private/backups
  case "$from" in
    */sites/*/private/backups)
      base="${from%/sites/*/private/backups}"
      site="${from#"${base}"/sites/}"; site="${site%/private/backups}"
      a="$(FL_BENCH_DIR="$base" fl_site_archive_latest "$site")"
      if [[ -n "$a" && -d "${a}/private/backups" ]]; then printf '%s' "${a}/private/backups"; fi ;;
  esac
  return 0
}

# fl_kept_put_back KDIR TARGET: puts back into TARGET each file of KDIR that is
# not there and drops the kept copy of each file that is (the same file: the
# same inode or the same bytes). A file that could not go back stays. Adds to
# FL_KEEP_RESTORED and FL_KEEP_LEFT. Removes KDIR (and the folders above it
# that are empty) when nothing is left.
fl_kept_put_back() {
  local kdir="$1" target="$2" f name left=0
  for f in "$kdir"/*; do
    [[ -f "$f" ]] || continue
    name="${f##*/}"
    if [[ -e "${target}/${name}" ]]; then
      if [[ "$f" -ef "${target}/${name}" ]] || cmp -s "$f" "${target}/${name}" 2>/dev/null; then
        rm -f "$f"
      else
        # a different file of the same name: neither is deleted
        left=$((left + 1))
        fl_warn "${name} in ${target} differs from the kept copy in ${kdir}; both stay"
      fi
      continue
    fi
    if [[ -d "$target" ]] && { ln "$f" "${target}/${name}" 2>/dev/null || cp -p "$f" "${target}/${name}" 2>/dev/null; }; then
      FL_KEEP_RESTORED=$((FL_KEEP_RESTORED + 1))
      fl_log "kept: ${name} was deleted by bench's backup and is back in ${target}"
      rm -f "$f"
    else
      left=$((left + 1))
    fi
  done
  FL_KEEP_LEFT=$((FL_KEEP_LEFT + left))
  [[ "$left" == "0" ]] || return 1
  rm -f "${kdir}/.from"
  rmdir "$kdir" "$(dirname "$kdir")" "$(dirname "$(dirname "$kdir")")" 2>/dev/null || true
  return 0
}

# fl_backups_recover [BENCH_DIR]: puts back what a run that did not finish left
# in the kept folders (not the run's own, FL_KEEP_DIR). One [WARN] line and one
# changed[] entry for what was put back, a [WARN] line for what could not be.
# Always returns 0: a leftover must not stop the backup that is about to run.
fl_backups_recover() {
  local kdir target site
  [[ "${FL_DRY_RUN:-0}" != "1" ]] || return 0
  while IFS= read -r kdir; do
    [[ -n "$kdir" && "$kdir" != "${FL_KEEP_DIR:-}" ]] || continue
    site="${kdir##*/}"
    target="$(fl_kept_target "$kdir")"
    if [[ -z "$target" ]]; then
      fl_warn "older backups of ${site} are only in ${kdir}: their folder is gone and no archived folder was found; copy them out by hand"
      continue
    fi
    FL_KEEP_RESTORED=0; FL_KEEP_LEFT=0
    fl_kept_put_back "$kdir" "$target" || true
    if [[ "$FL_KEEP_RESTORED" -gt 0 ]]; then
      fl_warn "a run that did not finish left older backups of ${site} only in ${kdir}: ${FL_KEEP_RESTORED} file(s) are back in ${target}"
      fl_changed backups "$site" "put back ${FL_KEEP_RESTORED} older backup file(s) into ${target} (a run was cut short)"
    fi
    if [[ "$FL_KEEP_LEFT" -gt 0 ]]; then
      fl_warn "${FL_KEEP_LEFT} older backup file(s) of ${site} could not be put back into ${target}; they stay in ${kdir}"
    fi
  done < <(fl_kept_dirs "${1:-}")
  FL_KEEP_RESTORED=0; FL_KEEP_LEFT=0
  return 0
}

# fl_backups_keep_begin SITE: first puts back what an earlier run left, then
# sets FL_KEEP_DIR (empty when there was nothing to keep). Returns 1, with a
# [FAIL] line, when a file could not be kept: bench's backup must not run then
# (and nothing of the new kept folder stays).
fl_backups_keep_begin() {
  local site="$1" dir f name need=0 avail copies=()
  FL_KEEP_DIR=""; FL_KEEP_COUNT=0; FL_KEEP_RESTORED=0; FL_KEEP_LEFT=0
  [[ "${FL_DRY_RUN:-0}" != "1" ]] || return 0
  fl_backups_recover
  dir="$(fl_site_backup_dir "$site")"
  [[ -d "$dir" ]] || return 0
  FL_KEEP_DIR="$(fl_kept_root)/$(fl_backup_stamp)/kept-sets/${site}"
  mkdir -p "$FL_KEEP_DIR" 2>/dev/null || { fl_fail "could not make ${FL_KEEP_DIR}"; FL_KEEP_DIR=""; return 1; }
  printf '%s\n' "$dir" >"${FL_KEEP_DIR}/.from"
  for f in "$dir"/*; do
    [[ -f "$f" ]] || continue
    name="${f##*/}"
    [[ -e "${FL_KEEP_DIR}/${name}" ]] && continue
    if ln "$f" "${FL_KEEP_DIR}/${name}" 2>/dev/null; then
      FL_KEEP_COUNT=$((FL_KEEP_COUNT + 1))
    else
      # no hard link (another volume): a real copy, which needs the room
      copies+=("$f")
      need=$((need + $(wc -c <"$f" | tr -d '[:space:]')))
    fi
  done
  if [[ "${#copies[@]}" -gt 0 ]]; then
    # the free space is read once and compared with the whole size
    avail="$(df -k "$FL_KEEP_DIR" 2>/dev/null | awk 'NR == 2 { print $4 }')"
    if [[ "$avail" =~ ^[0-9]+$ && $((avail * 1024)) -lt "$need" ]]; then
      fl_fail "not enough free space to keep the older backups of ${site} while bench takes a new one: $(fl_fmt_bytes "$need") needed in ${FL_KEEP_DIR}, $(fl_fmt_bytes $((avail * 1024))) free"
      fl_backups_keep_end >/dev/null 2>&1 || true
      return 1
    fi
    for f in "${copies[@]}"; do
      name="${f##*/}"
      if ! cp -p "$f" "${FL_KEEP_DIR}/${name}" 2>/dev/null; then
        fl_fail "could not keep ${f} in ${FL_KEEP_DIR}"
        fl_backups_keep_end >/dev/null 2>&1 || true
        return 1
      fi
      FL_KEEP_COUNT=$((FL_KEEP_COUNT + 1))
    done
  fi
  return 0
}

# fl_backups_keep_end [DIR]: a file that bench's backup deleted goes back into
# DIR (default: the folder the files came from; site drop passes the archived
# one) and the kept copy goes. A file that could not go back stays in the
# state backups, with a [WARN] line, and is never pruned. Sets FL_KEEP_RESTORED
# to the number put back.
fl_backups_keep_end() {
  local target="${1-}" kdir="$FL_KEEP_DIR"
  FL_KEEP_RESTORED=0; FL_KEEP_LEFT=0
  FL_KEEP_DIR=""
  [[ -n "$kdir" && -d "$kdir" ]] || return 0
  [[ -n "$target" ]] || target="$(fl_kept_target "$kdir")"
  if [[ -z "$target" ]]; then
    fl_warn "older backups of ${kdir##*/} are only in ${kdir}: their folder is gone and no archived folder was found"
    return 0
  fi
  fl_kept_put_back "$kdir" "$target" && return 0
  fl_warn "${FL_KEEP_LEFT} older backup file(s) that bench's backup deleted could not be put back into ${target}; they are in ${kdir}"
  return 0
}

# fl_backups_keep_on_exit: the EXIT trap of benchbar. A run that was cut short
# between begin and end (a signal ends the shell through exit) puts the files
# back now; one that is killed outright is picked up by the next begin.
fl_backups_keep_on_exit() {
  [[ -n "${FL_KEEP_DIR:-}" ]] || return 0
  fl_backups_keep_end >/dev/null 2>&1 || true
  return 0
}

# ------------------------------------------------- integrity

# fl_backup_file_check FILE: 0 when FILE can be read to its end; else 1 and
# FL_BACKUP_PROBLEM says what is wrong, naming the file. An encrypted file
# cannot be read without its key: only its size is checked.
fl_backup_file_check() {
  local f="$1" name="${1##*/}"
  FL_BACKUP_PROBLEM=""
  if [[ ! -f "$f" || ! -r "$f" ]]; then FL_BACKUP_PROBLEM="${name} cannot be read"; return 1; fi
  if [[ ! -s "$f" ]]; then FL_BACKUP_PROBLEM="${name} is empty"; return 1; fi
  case "$name" in *-enc.*) return 0 ;; esac
  case "$name" in
    *.sql.gz|*.tgz|*.tar.gz)
      gzip -t "$f" >/dev/null 2>&1 || { FL_BACKUP_PROBLEM="${name} is not a complete gzip file (a backup cut short, or a disk that filled up)"; return 1; } ;;
  esac
  case "$name" in
    *.tar|*.tgz|*.tar.gz)
      tar -tf "$f" >/dev/null 2>&1 || { FL_BACKUP_PROBLEM="${name} is not a readable tar archive"; return 1; } ;;
  esac
  return 0
}

# fl_backup_set_check DIR FILE...: the files that are named (the database dump,
# the file archives), read from DIR. 1 with FL_BACKUP_PROBLEM on the first one
# that is empty, cut short or unreadable.
fl_backup_set_check() {
  local dir="$1" f
  shift
  for f in "$@"; do
    [[ -n "$f" ]] || continue
    fl_backup_file_check "${dir}/${f}" || return 1
  done
  return 0
}

# In JSON mode only the JSON goes to stdout (on fd 3); every line of text,
# refusals included, goes to stderr.
fl_site_json_begin() {
  if [[ "$OPT_JSON" == "1" ]]; then fl_json_doc_begin; fi
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
    rows+=("$(fl_backup_field "$set" time)|$(fl_fmt_bytes "$(fl_backup_field "$set" size_bytes)")|$([[ "$(fl_backup_field "$set" with_files)" == "true" ]] && printf yes || printf no)|$(basename "$(fl_backup_field "$set" path)")$([[ "$(fl_backup_field "$set" complete)" == "true" ]] || printf '  (incomplete)')")
  done < <(fl_backup_stamps "$dir")
  if [[ "${#rows[@]}" == "1" ]]; then fl_info "no backups of ${name} yet; take one with: benchbar site backup ${name}"; return 0; fi
  fl_table "${rows[@]}"
  fl_note "folder: ${dir}"
}

# fl_backup_field JSON KEY: one scalar of fl_backup_set_json's flat object.
# A string value is read up to its closing quote (a path may hold a comma);
# a number, true, false or null up to the next comma or brace.
fl_backup_field() {
  local v
  v="$(printf '%s' "$1" | sed -n -E "s/.*\"$2\":\"([^\"]*)\".*/\1/p")"
  if [[ -z "$v" ]]; then v="$(printf '%s' "$1" | sed -n -E "s/.*\"$2\":([^,}\"]*)[,}].*/\1/p")"; fi
  printf '%s' "$v"
}

# fl_site_backup_take NAME [WITH_FILES]: bench --site NAME backup, kept older
# backups put back, and the new set found. Sets FL_BACKUP_TAKEN_STAMP and
# FL_BACKUP_TAKEN_SET (the set's JSON); on a failure returns 1 with
# FL_BACKUP_TAKEN_ERR and FL_BACKUP_TAKEN_HINT. The caller has made the
# bench's Redis available (fl_bench_redis_up) and stops it afterwards.
FL_BACKUP_TAKEN_STAMP=""
FL_BACKUP_TAKEN_SET="null"
FL_BACKUP_TAKEN_ERR=""
FL_BACKUP_TAKEN_HINT=""
fl_site_backup_take() {
  local name="$1" with_files="${2:-0}" dir before args
  FL_BACKUP_TAKEN_STAMP=""; FL_BACKUP_TAKEN_SET="null"; FL_BACKUP_TAKEN_ERR=""; FL_BACKUP_TAKEN_HINT=""
  dir="$(fl_site_backup_dir "$name")"
  args=(bench --site "$name" backup)
  [[ "$with_files" == "1" ]] && args+=(--with-files)
  # what bench writes from now on is the new backup: two backups in one
  # second share a timestamp, and bench then overwrites the older files,
  # so the files' age tells, not their names
  before="$(mktemp "${TMPDIR:-/tmp}/benchbar-backup-start.XXXXXX")"
  # bench's backup deletes the site's backups older than 23 hours: keep them
  if ! fl_backups_keep_begin "$name"; then
    rm -f "$before"
    FL_BACKUP_TAKEN_ERR="The older backups of ${name} could not be kept while bench takes a new one; nothing was backed up."
    FL_BACKUP_TAKEN_HINT="Free space on the volume of ${FL_STATE_DIR}, or move the old backups away."
    return 1
  fi
  if ! fl_bench_run_long "bench --site ${name} backup$([[ "$with_files" == "1" ]] && printf ' --with-files')" "$FL_BENCH_DIR" "${args[@]}"; then
    rm -f "$before"
    fl_backups_keep_end
    FL_BACKUP_TAKEN_ERR="The backup of ${name} failed."
    FL_BACKUP_TAKEN_HINT="Run it by hand to see why: cd ${FL_BENCH_DIR} && ${args[*]}"
    return 1
  fi
  fl_backups_keep_end
  FL_BACKUP_TAKEN_STAMP="$(find "$dir" -maxdepth 1 -type f -newer "$before" -name '[0-9]*_[0-9]*-*' 2>/dev/null | sed -n 's#.*/\([0-9]\{8\}_[0-9]\{6\}\)-.*#\1#p' | sort -r | awk 'NR==1')"
  rm -f "$before"
  if [[ -z "$FL_BACKUP_TAKEN_STAMP" ]]; then
    FL_BACKUP_TAKEN_ERR="bench reported success, but ${dir} has no new backup."
    FL_BACKUP_TAKEN_HINT="Look in ${dir}"
    return 1
  fi
  FL_BACKUP_TAKEN_SET="$(fl_backup_set_json "$dir" "$FL_BACKUP_TAKEN_STAMP")"
}

# site backup NAME [--with-files]: bench --site NAME backup, then the new set.
fl_cmd_site_backup() {
  local name="" with_files=0 json="$OPT_JSON" dir set args
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
    [[ "$json" == "1" ]] && fl_doc_emit 0 "$(printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"site":%s,"dry_run":true,"backup":null}' \
      "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$name")")" plan
    return 0
  fi
  fl_bench_env_exports
  # frappe reads the site's settings through the bench's Redis cache
  fl_bench_redis_up "$FL_BENCH_DIR"
  if ! fl_site_backup_take "$name" "$with_files"; then
    fl_bench_redis_down
    fl_die "$FL_BACKUP_TAKEN_ERR" "$FL_BACKUP_TAKEN_HINT"
  fi
  fl_bench_redis_down
  set="$FL_BACKUP_TAKEN_SET"
  fl_changed backup "$name" "$(fl_backup_field "$set" path)"
  if [[ "$json" == "1" ]]; then
    fl_doc_emit 0 "$(printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"site":%s,"dry_run":false,"backup":%s}' \
      "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$name")" "$set")"
    return 0
  fi
  fl_ok "backup of ${name}: $(fl_backup_field "$set" path) ($(fl_fmt_bytes "$(fl_backup_field "$set" size_bytes)")$([[ "$with_files" == "1" ]] && printf ', with files'))"
  fl_note "folder: ${dir}"
  fl_note "older backups are kept: bench's backup deletes files older than 23 hours there, benchbar puts them back"
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
  local name="$1" place other re
  FL_HOSTS_REMOVED=0; FL_HOSTS_MANUAL=""
  if ! fl_site_name_ok "$name"; then
    fl_warn "no hosts line to remove for sites/${name}: not a valid site name"
    return 0
  fi
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
  # sudo needs a terminal to ask; without one (the app, the non interactive mode) say what to run
  if { [[ ! -t 0 ]] || fl_noninteractive; } && ! fl_sudo_available; then
    FL_HOSTS_MANUAL="$(fl_hosts_manual_removal "$name")"
    fl_warn "the ${FL_HOSTS_FILE} line for ${name} needs sudo; run in Terminal: ${FL_HOSTS_MANUAL}"
    return 0
  fi
  if ! fl_sudo_begin "remove '127.0.0.1 ${name}' from ${FL_HOSTS_FILE}"; then
    FL_HOSTS_MANUAL="$(fl_hosts_manual_removal "$name")"
    fl_warn "skipped without sudo; run: ${FL_HOSTS_MANUAL}"
    return 0
  fi
  fl_backup_file "$FL_HOSTS_FILE" || return 1
  re="$(printf '%s' "$name" | sed 's/\./\\./g')"
  # the one line inside the block goes (fl_hosts_rewrite checks it is one)
  # shellcheck disable=SC2016  # an awk program
  fl_hosts_rewrite -1 '
    $0 == ENVIRON["S"] { inside = 1 }
    $0 == ENVIRON["E"] { inside = 0 }
    inside && $0 ~ ENVIRON["RE"] { next }
    { print }' "S=${FL_HOSTS_START}" "E=${FL_HOSTS_END}" "RE=^[[:space:]]*127\\.0\\.0\\.1[[:space:]]+${re}[[:space:]]*\$" \
    || { FL_HOSTS_MANUAL="$(fl_hosts_manual_removal "$name")"; return 1; }
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
  local name="" confirm="" new_default="" json="$OPT_JSON" plan_doc="" others=() s st t c p sep="" steps=() archive_before archive="" stamp backup="null" code=0 is_default=0 hosts_place bench_default="" default_failed=0
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
  # the only site is never dropped, whatever SITE_NAME or --site says
  [[ "${#others[@]}" -gt 0 ]] || fl_die "${name} is the only site of ${FL_BENCH_DIR}; benchbar does not drop it." \
    "Add another site first (benchbar site add NAME), then drop ${name} with --new-default NAME"
  # the default: the site benchbar uses (FL_SITE) and the one bench uses
  # (currentsite.txt, else default_site); a SITE_NAME override hides neither
  bench_default="$({ tr -d '[:space:]' <"${FL_BENCH_DIR}/sites/currentsite.txt"; } 2>/dev/null || true)"
  [[ -n "$bench_default" ]] || fl_site_config_value_v bench_default default_site
  [[ "$name" == "$FL_SITE" || "$name" == "$bench_default" ]] && is_default=1
  if [[ "$is_default" == "1" ]]; then
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
  steps+=("Back up ${name} with files, drop its database and user, move the folder to archived/sites|bench drop-site ${name}|0")
  [[ -n "$new_default" ]] && steps+=("Make ${new_default} the default site|bench use ${new_default}|0")
  if [[ "$hosts_place" == "block" ]] && ! fl_site_name_elsewhere "$name" >/dev/null; then
    steps+=("Remove '127.0.0.1 ${name}' from ${FL_HOSTS_FILE}|sudo, backup first|1")
  fi
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    if [[ "$json" == "1" ]]; then
      plan_doc="$(printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"site":%s,"dry_run":true,"is_default":%s,"new_default":%s,"default_site":%s,"steps":[' \
        "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$name")" "$(fl_json_bool "$is_default")" "$(fl_json_str "$new_default")" "$(fl_json_str "$FL_SITE")")"
      for st in "${steps[@]}"; do
        IFS='|' read -r t c p <<<"$st"
        plan_doc="${plan_doc}${sep}$(printf '{"title":%s,"command":%s,"needs_password":%s}' "$(fl_json_str "$t")" "$(fl_json_str "$c")" "$(fl_json_bool "$p")")"; sep=","
      done
      fl_doc_emit 0 "${plan_doc}]}" plan
      return 0
    fi
    fl_info "dry-run: benchbar site drop ${name} would:"
    for s in "${steps[@]}"; do fl_note "${s%%|*}   (${s#*|}; ${s##*|})"; done
    return 0
  fi

  fl_header "benchbar site drop" "$(fl_mode_name)" "$FL_PROFILE" "$FL_BENCH_DIR" "$name"
  fl_mariadb_root_password_resolve || fl_die "The MariaDB root password is needed to drop the database of ${name}." \
    "Ask the person for it (do not look for it), then re-run with: MARIADB_ROOT_PASSWORD='...' benchbar site drop ${name} --confirm-site ${name}" 2
  fl_bench_env_exports
  fl_bench_redis_up "$FL_BENCH_DIR"
  archive_before="$(fl_site_archive_latest "$name")"
  # the backup drop-site takes first deletes the site's backups older than 23 hours: keep them
  if ! fl_backups_keep_begin "$name"; then
    fl_bench_redis_down
    fl_die "The older backups of ${name} could not be kept while bench takes the last one; nothing was dropped." "Free space on the volume of ${FL_STATE_DIR}, or move the old backups away."
  fi
  # the password travels on stdin, never on the command line (see FL_PY_FRAPPE_SECRETS)
  FL__DB_PW="$FL_MARIADB_ROOT_PW"
  fl_run_long "bench drop-site ${name}" fl__frappe_with_secrets "$FL_BENCH_DIR" FL__DB_PW -- \
    drop-site "$name" --db-root-password @secret0@ || code=$?
  FL__DB_PW=""
  fl_bench_redis_down
  if [[ "$code" != "0" ]]; then
    fl_backups_keep_end
    fl_die "bench drop-site ${name} failed; the site is still there and stays the default." \
      "When the backup failed, fix that first. Manual command: cd ${FL_BENCH_DIR} && bench drop-site ${name}"
  fi
  # only now, with the site gone, does the default move: a failed drop left
  # the default switched before, with the dropped site still there
  if [[ -n "$new_default" ]]; then
    # in a subshell: fl_cmd_site_default dies on a failed bench use, and the
    # site is already gone, which the message must say
    if (fl_cmd_site_default "$new_default"); then
      # what the subshell recorded is gone with it
      FL_SITE="$new_default"
      fl_changed site "$new_default" "now the default site"
    else
      fl_fail "${name} is dropped, but the default did not move to ${new_default}; currentsite.txt still names ${name}"
      fl_fix "$(fl_fix_cmd cd "$FL_BENCH_DIR" '&&' bench use "$new_default")   (then: ${FL_SELF} site default $(printf '%q' "$new_default") --bench-dir $(printf '%q' "$FL_BENCH_DIR"))"
      default_failed=1
    fi
  fi
  archive="$(fl_site_archive_latest "$name")"
  if [[ -z "$archive" || "$archive" == "$archive_before" || -d "${FL_BENCH_DIR}/sites/${name}" ]]; then
    fl_warn "bench drop-site finished, but no new folder for ${name} is in ${FL_BENCH_DIR}/archived/sites"
    archive=""
  fi
  # the older backups go with the site folder, into the archive
  if [[ -n "$archive" ]]; then fl_backups_keep_end "${archive}/private/backups"; else fl_backups_keep_end; fi
  if [[ -n "$archive" ]]; then
    stamp="$(fl_backup_stamps "${archive}/private/backups" | awk 'NR==1')"
    [[ -n "$stamp" ]] && backup="$(fl_backup_set_json "${archive}/private/backups" "$stamp")"
  fi
  fl_hosts_remove_name "$name" || true
  # a later site of the same name does not inherit the choice
  fl_open_as_set "$name" 0
  # nor does it inherit the generated Administrator password benchbar mcp kept for the person
  rm -f "${FL_STATE_DIR}/site-admin/${name}" 2>/dev/null || true
  fl_changed site "$name" "dropped${archive:+, archived to ${archive}}"
  [[ "$backup" == "null" ]] || fl_changed backup "$name" "$(fl_backup_field "$backup" path)"
  [[ "$FL_HOSTS_REMOVED" != "1" ]] || fl_changed hosts "$name" "line removed"
  [[ -z "$FL_HOSTS_MANUAL" ]] || fl_next_action "$FL_HOSTS_MANUAL" "the hosts line of ${name} needs sudo"

  if [[ "$json" == "1" ]]; then
    fl_site_default_file_v bench_default
    fl_doc_emit "$default_failed" "$(printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"site":%s,"dry_run":false,"dropped":true,"archived_path":%s,"backup":%s,"new_default":%s,"default_site":%s,"hosts_removed":%s,"manual_step":%s}' \
      "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$name")" "$(fl_json_str "$archive")" \
      "$backup" "$(fl_json_str "$new_default")" "$(fl_json_str "${bench_default:-$FL_SITE}")" "$(fl_json_bool "$FL_HOSTS_REMOVED")" "$(fl_json_str "$FL_HOSTS_MANUAL")")"
    return "$default_failed"
  fi
  fl_ok "dropped ${name}"
  if [[ "$backup" != "null" ]]; then
    fl_note "backup: $(fl_backup_field "$backup" path)"
  fi
  [[ -n "$archive" ]] && fl_note "the site folder is in ${archive}"
  return "$default_failed"
}
