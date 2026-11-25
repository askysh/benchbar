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
FL_SNAP_SKIPPED=""

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
  case "$1" in *[[:cntrl:]]*|*'"'*|*\\*) return 1 ;; esac
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
  done | { grep -E '^[0-9]{8}_[0-9]{6}' || true; } | sort -r
}

# fl_snap_last_rollback SITE: the "before rollback" snapshot of the last rollback that finished (its
# verify passed), when it is still there. `.last-rollback` moves only then.
fl_snap_last_rollback() {
  local f id=""
  f="$(fl_snap_dir "$1")/.last-rollback"
  if [[ -f "$f" ]]; then IFS= read -r id <"$f" || true; fi
  [[ "$id" =~ ^[0-9a-z_-]+$ && -d "$(fl_snap_dir "$1")/${id}" ]] && printf '%s' "$id"
  return 0
}

# fl_snap_unfinished SITE: the "before rollback" snapshots of rollbacks that did not finish, one per line,
# the ones still there. `.unfinished-rollbacks` is appended at the snapshot step and a name leaves it only
# when its own rollback ends with a passed verify, or when a person drops the snapshot. Each holds
# the data from before a rollback that failed halfway, so each stays protected.
fl_snap_unfinished() {
  local f id
  f="$(fl_snap_dir "$1")/.unfinished-rollbacks"
  [[ -f "$f" ]] || return 0
  while IFS= read -r id || [[ -n "$id" ]]; do
    [[ "$id" =~ ^[0-9a-z_-]+$ && -d "$(fl_snap_dir "$1")/${id}" ]] && printf '%s\n' "$id"
  done <"$f"
  return 0
}

# fl_snap_is_protected SITE ID: the undo point of the last finished rollback, or a "before rollback"
# snapshot of one that did not finish
fl_snap_is_protected() {
  local open
  [[ "$2" == "$(fl_snap_last_rollback "$1")" ]] && return 0
  open="$(fl_snap_unfinished "$1")"
  case $'\n'"$open"$'\n' in *$'\n'"$2"$'\n'*) return 0 ;; esac
  return 1
}

# fl_snap_list_remove SITE FILE ID: ID leaves a pointer file (the file goes when it empties)
fl_snap_list_remove() {
  local f keep="" line
  f="$(fl_snap_dir "$1")/$2"
  [[ -f "$f" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$line" && "$line" != "$3" ]]; then keep="${keep}${line}"$'\n'; fi
  done <"$f"
  if [[ -z "$keep" ]]; then rm -f "$f"; else printf '%s' "$keep" >"$f"; fi
}

# fl_snap_rollback_started SITE ID: the snapshot a rollback made before it replaces anything is protected
# from this moment (a failed or cut short rollback leaves it, and the earlier undo point, in place)
fl_snap_rollback_started() {
  printf '%s\n' "$2" >>"$(fl_snap_dir "$1")/.unfinished-rollbacks"
}

# fl_snap_rollback_finished SITE ID: the rollback ended with a passed verify: ID is the undo point now (the
# one of the rollback before it is released) and leaves the unfinished list
fl_snap_rollback_finished() {
  printf '%s\n' "$2" >"$(fl_snap_dir "$1")/.last-rollback"
  fl_snap_list_remove "$1" .unfinished-rollbacks "$2"
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
    FL_SNAP_SKIPPED=""
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      if fl_snap_is_complete "$site" "$id"; then hit="$id"; break; fi
      FL_SNAP_SKIPPED="${FL_SNAP_SKIPPED}${FL_SNAP_SKIPPED:+ }${id}"
    done < <(fl_snap_ids "$site")
    if [[ -z "$hit" ]]; then
      FL_SNAP_ERR="${site} has no complete snapshot$([[ -n "$FL_SNAP_SKIPPED" ]] && printf ' (skipped incomplete: %s)' "$FL_SNAP_SKIPPED")."
      FL_SNAP_HINT="benchbar site snapshot ${site} --label TEXT takes one"
      return 1
    fi
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
  v="$(sed -n -E "s/^ \"$2\": \"(.*)\",?\$/\\1/p" "$1" 2>/dev/null | awk 'NR==1')"
  if [[ -z "$v" ]]; then v="$(sed -n -E "s/^ \"$2\": ([^\",]*),?\$/\\1/p" "$1" 2>/dev/null | awk 'NR==1')"; fi
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
    [[ -n "$a" ]] || continue
    fl_app_has_git "$a" || continue
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
  fl_snap_is_complete "$site" "$id" || complete=false
  while IFS='|' read -r name commit branch; do
    [[ -n "$name" ]] || continue
    apps="${apps}${sep}{\"name\":$(fl_json_str "$name"),\"commit\":$(fl_json_str "$commit"),\"branch\":$(fl_json_str "$branch")}"; sep=","
  done < <(fl_snap_apps_list "$m")
  fl_snap_apps_diff "$m" || rc=$?
  case "$rc" in 0) match=true ;; 1) match=false ;; esac
  # shellcheck disable=SC2086  # the app names, split
  chg="$(fl_json_str_array $FL_SNAP_CHANGED)"
  fl_snap_is_protected "$site" "$id" && before=true
  printf '{"id":%s,"site":%s,"label":%s,"time":%s,"stamp":%s,"path":%s,"size_bytes":%s,"db_size_bytes":%s,"with_files":%s,"complete":%s,"rollback_of":%s,"before_rollback":%s,"apps":[%s],"apps_match":%s,"changed_apps":%s}' \
    "$(fl_json_str "$id")" "$(fl_json_str "$site")" "$(fl_json_str "$label")" "$(fl_json_str "$time")" "$(fl_json_str "$stamp")" "$(fl_json_str "$d")" \
    "${size:-0}" "$dbsize" "${files:-false}" "${complete:-false}" "$(fl_json_str "$rb")" "$before" "$apps" "$match" "$chg"
}

# fl_snap_over_limit SITE KEEP: the snapshots beyond the newest KEEP, one per line, never the one
# the last finished rollback made to be undone with, nor one a rollback that did not finish made
fl_snap_over_limit() {
  local id i=0
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    i=$((i + 1))
    [[ "$i" -gt "$2" ]] || continue
    ! fl_snap_is_protected "$1" "$id" || continue
    printf '%s\n' "$id"
  done < <(fl_snap_ids "$1")
}

# fl_snap_dir_bytes DIR: the bytes of the files in DIR (not below it)
fl_snap_dir_bytes() {
  local f b total=0
  for f in "$1"/* "$1"/.[!.]*; do
    [[ -f "$f" ]] || continue
    b="$(wc -c <"$f" | tr -d '[:space:]')"
    total=$((total + ${b:-0}))
  done
  printf '%s' "$total"
}

# fl_snap_held_load SITE KEEP: FL_SNAP_HELD (one snapshot per line) and FL_SNAP_HELD_BYTES, the snapshots
# beyond the newest KEEP that retention holds back because they are undo points. They only leave when a
# person drops them (snapshot drop SNAPSHOT --force-undo-point), so the list says how much they hold.
FL_SNAP_HELD=""
FL_SNAP_HELD_BYTES=0
fl_snap_held_load() {
  local id i=0 b
  FL_SNAP_HELD=""; FL_SNAP_HELD_BYTES=0
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    i=$((i + 1))
    [[ "$i" -gt "$2" ]] || continue
    fl_snap_is_protected "$1" "$id" || continue
    FL_SNAP_HELD="${FL_SNAP_HELD}${id}"$'\n'
    b="$(fl_snap_dir_bytes "$(fl_snap_dir "$1")/${id}")"
    FL_SNAP_HELD_BYTES=$((FL_SNAP_HELD_BYTES + b))
  done < <(fl_snap_ids "$1")
}

# fl_snap_held_note SITE KEEP: a note when retention holds snapshots back (call fl_snap_held_load first)
fl_snap_held_note() {
  local n
  [[ -n "$FL_SNAP_HELD" ]] || return 0
  n="$(printf '%s' "$FL_SNAP_HELD" | wc -l | tr -d ' ')"
  fl_note "${n} snapshot(s) beyond the newest ${2} are held back, $(fl_fmt_bytes "$FL_SNAP_HELD_BYTES"): $(printf '%s' "$FL_SNAP_HELD" | tr '\n' ' ')(undo points of rollbacks; a person frees one with: benchbar site snapshot drop ${1} SNAPSHOT --force-undo-point)"
}

# fl_snap_leftovers SITE: the .incomplete-ID folders a killed snapshot left, as name|bytes lines. They hold the
# backup files that had left private/backups; no list shows them and no rollback reads them.
fl_snap_leftovers() {
  local d
  for d in "$(fl_snap_dir "$1")"/.incomplete-*; do
    [[ -d "$d" && ! -L "$d" ]] || continue
    printf '%s|%s\n' "${d##*/}" "$(fl_snap_dir_bytes "$d")"
  done
}

# fl_snap_move_back SITE NAME: the commands that put the backup set of a leftover folder back
fl_snap_move_back() {
  local d stamp
  d="$(fl_snap_dir "$1")/$2"
  stamp="${2#.incomplete-}"; stamp="${stamp:0:15}"
  printf 'mv -n %q/%s-* %q/ && rm -f %q/manifest.json* && rmdir %q' "$d" "$stamp" "$(fl_site_backup_dir "$1")" "$d" "$d"
}

# fl_snap_leftovers_json SITE: [{"id","path","size_bytes","move_back"}]
fl_snap_leftovers_json() {
  local name bytes sep=""
  printf '['
  while IFS='|' read -r name bytes; do
    [[ -n "$name" ]] || continue
    printf '%s{"id":%s,"path":%s,"size_bytes":%s,"move_back":%s}' "$sep" "$(fl_json_str "$name")" "$(fl_json_str "$(fl_snap_dir "$1")/${name}")" "$bytes" "$(fl_json_str "$(fl_snap_move_back "$1" "$name")")"
    sep=","
  done < <(fl_snap_leftovers "$1")
  printf ']'
}

# fl_snap_leftovers_note SITE: one warning per leftover folder, with its size and the way to put the set back
fl_snap_leftovers_note() {
  local name bytes
  while IFS='|' read -r name bytes; do
    [[ -n "$name" ]] || continue
    fl_warn "${name} ($(fl_fmt_bytes "$bytes")) is left by a snapshot that was cut short; it holds the backup files that left private/backups, and it is no snapshot"
    fl_note "put the set back with: $(fl_snap_move_back "$1" "$name")"
  done < <(fl_snap_leftovers "$1")
}

# fl_snap_undo_point SITE SNAPSHOT: the oldest "before rollback" snapshot of an earlier attempt that did not
# finish at rolling back to this same SNAPSHOT (its manifest says rollback_of), if any: the state from before
# the first attempt, which is what a person wants back after a retry. A failed attempt at another snapshot
# is no part of this chain: going back that far would lose the work done since.
fl_snap_undo_point() {
  local id
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if [[ "$(fl_snap_mfield "$(fl_snap_dir "$1")/${id}/manifest.json" rollback_of)" == "$2" ]]; then printf '%s' "$id"; return 0; fi
  done < <(fl_snap_unfinished "$1")
  return 0
}

# fl_snap_summary BENCH SITE: FL_SNAP_COUNT and FL_SNAP_BYTES, the snapshots of SITE in BENCH and the
# bytes they hold (for the plans of site drop and bench remove: bench drop-site moves them with the site)
FL_SNAP_COUNT=0
FL_SNAP_BYTES=0
fl_snap_summary() {
  local d f b
  FL_SNAP_COUNT=0; FL_SNAP_BYTES=0
  for d in "$1/sites/$2/snapshots"/[0-9]*_[0-9]*; do
    [[ -d "$d" && ! -L "$d" ]] || continue
    FL_SNAP_COUNT=$((FL_SNAP_COUNT + 1))
    for f in "$d"/*; do
      [[ -f "$f" ]] || continue
      b="$(wc -c <"$f" | tr -d '[:space:]')"
      FL_SNAP_BYTES=$((FL_SNAP_BYTES + ${b:-0}))
    done
  done
}

# fl_snap_phrase BENCH SITE: "; its 2 snapshot(s) (4.0 MB) move into the archive with it", or nothing
fl_snap_phrase() {
  fl_snap_summary "$1" "$2"
  [[ "$FL_SNAP_COUNT" -gt 0 ]] || return 0
  printf '; its %s snapshot(s) (%s) move into the archive with it' "$FL_SNAP_COUNT" "$(fl_fmt_bytes "$FL_SNAP_BYTES")"
}

# fl_snap_missing_parts SITE ID: what the folder lacks of a whole snapshot (its manifest, a database dump that
# is not empty, the public and the private files, site_config), as words; nothing when it is whole
fl_snap_missing_parts() {
  local d f out="" db=0 pub=0 priv=0 cfg=0
  d="$(fl_snap_dir "$1")/$2"
  [[ -f "${d}/manifest.json" ]] || out="the manifest"
  for f in "$d"/*-database.sql.gz; do [[ -s "$f" ]] && db=1; done
  for f in "$d"/*-private-files.tar; do [[ -f "$f" ]] && priv=1; done
  for f in "$d"/*-files.tar; do
    case "$f" in *-private-files.tar) ;; *) [[ -f "$f" ]] && pub=1 ;; esac
  done
  for f in "$d"/*-site_config_backup.json; do [[ -f "$f" ]] && cfg=1; done
  [[ "$db" == 1 ]] || out="${out}${out:+, }the database dump"
  [[ "$pub" == 1 ]] || out="${out}${out:+, }the public files"
  [[ "$priv" == 1 ]] || out="${out}${out:+, }the private files"
  [[ "$cfg" == 1 ]] || out="${out}${out:+, }site_config"
  printf '%s' "$out"
}

# fl_snap_is_complete SITE ID: the folder is a snapshot with all of its parts. A rollback takes nothing
# less, however the snapshot was named.
fl_snap_is_complete() {
  local d
  d="$(fl_snap_dir "$1")/$2"
  [[ -d "$d" && ! -L "$d" ]] || return 1
  [[ -z "$(fl_snap_missing_parts "$1" "$2")" ]]
}

# fl_snap_free_bytes SITE: the free bytes on the volume of the site's folder, empty when df does not say.
# -P: one line per volume (POSIX output), so a long device name never wraps the numbers to a second line
fl_snap_free_bytes() {
  local kb
  kb="$(df -Pk "${FL_BENCH_DIR}/sites/$1" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  [[ "$kb" =~ ^[0-9]+$ ]] && printf '%s' "$((kb * 1024))"
  return 0
}

# fl_snap_db_bytes SITE: the size of the site's database in MariaDB (data and indexes, uncompressed: more
# than the gzip dump, the safe side), empty when it cannot be asked. Uses the root password the CLI itself
# uses (the one in hand, the environment, the Keychain or the 0600 file); it is never printed or logged.
fl_snap_db_bytes() {
  local cfg db pw bin n
  cfg="${FL_BENCH_DIR}/sites/$1/site_config.json"
  [[ -r "$cfg" ]] || return 0
  db="$(sed -n 's/.*"db_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$cfg" | awk 'NR==1')"
  [[ "$db" =~ ^[A-Za-z0-9_]+$ ]] || return 0
  pw="${FL_MARIADB_ROOT_PW:-${MARIADB_ROOT_PASSWORD:-}}"
  [[ -n "$pw" ]] || pw="$(fl_keychain_get 2>/dev/null || true)"
  [[ -n "$pw" ]] || return 0
  bin="$(fl_mariadb_client)"
  [[ -n "$bin" ]] || return 0
  n="$(MYSQL_PWD="$pw" "$bin" -u root --connect-timeout=2 -sNe "SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${db}'" 2>/dev/null | awk 'NR==1')" || n=""
  [[ "$n" =~ ^[0-9]+$ ]] && printf '%s' "$n"
  return 0
}

# the dump of a site with no earlier snapshot or backup, when MariaDB cannot be asked: 64 MB
FL_SNAP_DUMP_FLOOR=67108864

# fl_snap_need_bytes SITE: what one more snapshot writes before anything is moved: the public and private
# files (a tar of about their size), the database dump (as big as the largest one the site has: a snapshot,
# or a backup; with none, the size of the database in MariaDB, else the files again, at least 64 MB), and
# 5 percent, at least 1 MB. bench backup writes a whole set first, whatever it moves later.
fl_snap_need_bytes() {
  local site="$1" files=0 dump=0 f b kb sub
  for sub in public/files private/files; do
    [[ -d "${FL_BENCH_DIR}/sites/${site}/${sub}" ]] || continue
    kb="$(du -sk "${FL_BENCH_DIR}/sites/${site}/${sub}" 2>/dev/null | awk '{ print $1 }')"
    [[ "$kb" =~ ^[0-9]+$ ]] && files=$((files + kb * 1024))
  done
  for f in "$(fl_snap_dir "$site")"/*/*-database.sql.gz "$(fl_site_backup_dir "$site")"/*-database.sql.gz; do
    [[ -f "$f" ]] || continue
    b="$(wc -c <"$f" | tr -d '[:space:]')"
    [[ "${b:-0}" -le "$dump" ]] || dump="$b"
  done
  if [[ "$dump" == "0" ]]; then
    dump="$(fl_snap_db_bytes "$site")"
    if [[ ! "$dump" =~ ^[0-9]+$ || "$dump" == "0" ]]; then
      dump="$files"
      [[ "$dump" -ge "$FL_SNAP_DUMP_FLOOR" ]] || dump="$FL_SNAP_DUMP_FLOOR"
    fi
  fi
  b=$((files + dump))
  b=$((b + b / 20))
  [[ "$b" -ge 1048576 ]] || b=1048576
  printf '%s' "$b"
}

# fl_snap_space_check SITE [EXTRA]: 0 when a snapshot fits (or df does not say), else 1 with FL_SNAP_ERR and
# FL_SNAP_HINT. EXTRA is what the run writes after the snapshot (a rollback: the files and the database of
# the snapshot it puts back).
fl_snap_space_check() {
  local site="$1" extra="${2:-0}" need free
  need="$(fl_snap_need_bytes "$site")"
  need=$((need + extra))
  free="$(fl_snap_free_bytes "$site")"
  [[ -n "$free" && "$free" -lt "$need" ]] || return 0
  FL_SNAP_ERR="not enough free space for a snapshot of ${site}: about $(fl_fmt_bytes "$need") are written (its files and a database dump$([[ "$extra" -gt 0 ]] && printf ', then the snapshot put back')), and $(fl_fmt_bytes "$free") are free on the volume of ${FL_BENCH_DIR}/sites/${site}."
  FL_SNAP_HINT="Free some space first (a full disk during the restore leaves the site half restored), or remove old snapshots (a person: benchbar site snapshot drop ${site} --prune). Nothing was written."
  return 1
}

# ------------------------------------------------- taking one

# fl_snap_take SITE LABEL [ROLLBACK_OF]: bench backup --with-files, then its files moved into the
# snapshot folder with the manifest. Sets FL_SNAP_ID and FL_SNAP_JSON; on a failure returns 1 with
# FL_SNAP_ERR and FL_SNAP_HINT, and the backup (when it was made) stays in private/backups. The caller
# has made the bench's Redis available (fl_bench_redis_up) and stops it afterwards.
fl_snap_take() {
  local site="$1" label="$2" rto="${3:-}" bdir sdir id stamp set slug root n=1 f name k moved=() mtime dbfile db_bytes total
  FL_SNAP_ID=""; FL_SNAP_JSON="null"; FL_SNAP_ERR=""; FL_SNAP_HINT=""
  # bench backup writes a whole set before anything moves: it must fit first
  fl_snap_space_check "$site" || return 1
  if ! fl_site_backup_take "$site" 1; then
    FL_SNAP_ERR="$FL_BACKUP_TAKEN_ERR"; FL_SNAP_HINT="$FL_BACKUP_TAKEN_HINT"
    return 1
  fi
  stamp="$FL_BACKUP_TAKEN_STAMP"; set="$FL_BACKUP_TAKEN_SET"
  bdir="$(fl_site_backup_dir "$site")"
  for k in database files private_files config; do
    case "$(fl_backup_field "$set" "$k")" in
      ""|null) FL_SNAP_ERR="the backup ${stamp} of ${site} has no ${k} part, so it is not a snapshot."; FL_SNAP_HINT="Look in ${bdir}"; return 1 ;;
    esac
  done
  if [[ "$(fl_backup_field "$set" encrypted)" == "true" ]]; then
    FL_SNAP_ERR="the backup ${stamp} of ${site} is encrypted, and a restore takes a plain set."
    FL_SNAP_HINT="It stays in ${bdir}; take the snapshot with the encryption of backups off"
    return 1
  fi
  if ! fl_backup_set_check "$bdir" "$(basename "$(fl_backup_field "$set" database)")" "$(basename "$(fl_backup_field "$set" files)")" "$(basename "$(fl_backup_field "$set" private_files)")" "$(basename "$(fl_backup_field "$set" config)")"; then
    FL_SNAP_ERR="${FL_BACKUP_PROBLEM}; no snapshot was made."; FL_SNAP_HINT="Look in ${bdir}"
    return 1
  fi
  slug="$(fl_snap_slug "$label")"
  root="$(fl_snap_dir "$site")"
  id="${stamp}${slug:+-${slug}}"
  while [[ -e "${root}/${id}" || -e "${root}/.incomplete-${id}" ]]; do n=$((n + 1)); id="${stamp}${slug:+-${slug}}-${n}"; done
  # built under a name the list does not show; the folder takes its name last, so a run cut short at any
  # point leaves nothing that looks like a snapshot
  sdir="${root}/.incomplete-${id}"
  if ! mkdir -p "$sdir" 2>/dev/null; then FL_SNAP_ERR="could not make ${sdir}."; FL_SNAP_HINT="Look at the permissions of sites/${site}"; return 1; fi
  chmod 700 "$root" 2>/dev/null || true
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
  if ! fl_snap_manifest_write "${sdir}/manifest.json.tmp" "$id" "$site" "$label" "$stamp" "$mtime" "${db_bytes:-0}" "${total:-0}" "$rto" \
    || ! mv "${sdir}/manifest.json.tmp" "${sdir}/manifest.json" \
    || ! mv "$sdir" "${root}/${id}"; then
    # no manifest, no snapshot: the set goes back where bench wrote it (a plain backup) and the folder is
    # taken away empty, never recursively; whatever cannot go back stays where it is (as .incomplete-ID,
    # which no list shows and no rollback reads) and is named
    rm -f "${sdir}/manifest.json.tmp" "${sdir}/manifest.json"
    for name in ${moved[@]+"${moved[@]}"}; do mv "${sdir}/${name}" "${bdir}/${name}" 2>/dev/null || true; done
    rmdir "$sdir" 2>/dev/null || true
    if [[ -d "$sdir" ]]; then
      FL_SNAP_ERR="could not write the manifest of ${id}; no snapshot was made, and what could not go back to ${bdir} stays in ${sdir}, which is no snapshot."
    else
      FL_SNAP_ERR="could not write the manifest of ${id}; no snapshot was made, and the backup ${stamp} is back in ${bdir}."
    fi
    FL_SNAP_HINT="Look at the permissions and the free space of ${root}"
    return 1
  fi
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
  # protected now, and it becomes the undo point only when the rollback ends with a passed verify
  # (fl_snap_rollback_finished): a retry after a failure must not move the undo point
  # after a retry the way back is the state before the first attempt (the oldest unfinished snapshot), not the
  # half restored site this run just snapshotted
  SR_UNDO_SNAPSHOT="$(fl_snap_undo_point "$SR_TARGET" "$SR_SNAP_ID")"
  [[ -n "$SR_UNDO_SNAPSHOT" ]] || SR_UNDO_SNAPSHOT="$FL_SNAP_ID"
  fl_snap_rollback_started "$SR_TARGET" "$FL_SNAP_ID"
  SR_BEFORE_SNAPSHOT="$FL_SNAP_ID"
  SR_RESULT_EXTRA="$(printf ',"rollback":{"snapshot":%s,"before_rollback":%s,"undo":%s}' "$(fl_json_str "$SR_SNAP_ID")" "$(fl_json_str "$FL_SNAP_ID")" \
    "$(fl_json_str "benchbar site rollback ${SR_TARGET} --to ${SR_UNDO_SNAPSHOT}")")"
  fl_ok "snapshot ${FL_SNAP_ID} of ${SR_TARGET} ($(fl_fmt_bytes "$(fl_backup_field "$FL_SNAP_JSON" size_bytes)")); undo this rollback with: benchbar site rollback ${SR_TARGET} --to ${SR_UNDO_SNAPSHOT}"
  fl_changed snapshot "$SR_TARGET" "$FL_SNAP_ID"
}

# SR_PERSON: 1 when a person is here, decided once by fl_cmd_site_rollback while stdin is still the terminal
# (an applied plan points stdin at /dev/null before the plan is rebuilt, and a terminal test then fails)
SR_PERSON=0

# fl_snap_plan_hook: what only a rollback adds to site restore's plan (called from fl_srestore_plan)
fl_snap_plan_hook() {
  local m="${SR_SNAP_DIR}/manifest.json" bench_default rc=0 match=null label time chg="" word f b put=0 open
  SR_NOTES=(); SR_MIGRATE_TEXT=""; SR_IS_DEFAULT=0; SR_MIGRATE_AUTO=0; SR_PLAN_EXTRA=""
  fl_site_default_file_v bench_default
  if [[ "$SR_TARGET" == "$FL_SITE" || "$SR_TARGET" == "$bench_default" ]]; then
    SR_IS_DEFAULT=1
    # a person: a terminal (or the app's own claim), not only the absence of --for-agent. --yes with no
    # terminal is no person either
    if [[ "$SR_PERSON" != "1" ]]; then
      fl_srestore_err "${SR_TARGET} is the default site of this bench: rolling it back is a person's decision, not an agent's, and this run has no person at a terminal.${FL_PERSON_WHY:+ $FL_PERSON_WHY} Ask the person to run it in a terminal: benchbar site rollback ${SR_TARGET} --to ${SR_SNAP_ID}"
    fi
  fi
  # the snapshot of the current state is written before anything is replaced, then the snapshot is put back
  # (its files extracted, its database imported): both must fit
  for f in "$SR_SNAP_DIR"/*; do
    [[ -f "$f" ]] || continue
    b="$(wc -c <"$f" | tr -d '[:space:]')"; put=$((put + ${b:-0}))
  done
  if ! fl_snap_space_check "$SR_TARGET" "$put"; then fl_srestore_err "${FL_SNAP_ERR} ${FL_SNAP_HINT}"; fi
  # a rollback that did not finish left its snapshot of the site, and it is still the way back
  open="$(fl_snap_unfinished "$SR_TARGET" | tr '\n' ' ')"
  if [[ -n "$open" ]]; then
    word="an earlier rollback of ${SR_TARGET} did not finish; its snapshot of the site before it (${open% }) stays protected, and this rollback adds its own"
    SR_NOTES+=("$word")
    FL_PULL_WARNINGS="${FL_PULL_WARNINGS}${FL_PULL_WARNINGS:+,}$(fl_json_str "$word")"
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
  # before the bench's Redis is started: a snapshot that cannot fit starts nothing
  fl_snap_space_check "$name" || fl_die "$FL_SNAP_ERR" "$FL_SNAP_HINT"
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
  local name="" json="$OPT_JSON" dir id sep="" rows=() set keep over last apps now aname acommit n=0 rc total free
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
  fl_snap_held_load "$name" "$keep"
  last="$(fl_snap_last_rollback "$name")"
  fl_snap_summary "$FL_BENCH_DIR" "$name"
  total="$FL_SNAP_BYTES"
  free="$(fl_snap_free_bytes "$name")"
  if [[ "$json" == "1" ]]; then
    {
    printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"site":%s,"folder":%s,"keep":%s,"snapshots":[' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" \
      "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$name")" "$(fl_json_str "$dir")" "$keep"
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      printf '%s%s' "$sep" "$(fl_snap_json "$name" "$id")"; sep=","
    done < <(fl_snap_ids "$name")
    # shellcheck disable=SC2086  # one name per line
    printf '],"over_limit":%s,"held_back":%s,"held_back_bytes":%s,"leftovers":%s,"last_rollback_snapshot":%s,"total_bytes":%s,"free_bytes":%s}\n' "$(fl_json_str_array $over)" \
      "$(fl_json_str_array $FL_SNAP_HELD)" "$FL_SNAP_HELD_BYTES" "$(fl_snap_leftovers_json "$name")" "$(fl_json_str "$last")" "$total" "${free:-null}"
    } >&3
    return 0
  fi
  rows+=("Snapshot|Label|Size|Apps at the time|The bench now")
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    n=$((n + 1))
    set="$(fl_snap_json "$name" "$id")"
    rc=0; fl_snap_apps_diff "${dir}/${id}/manifest.json" || rc=$?
    case "$rc" in
      0) now="same apps" ;;
      1) now="changed: ${FL_SNAP_CHANGED}" ;;
      *) now="not recorded" ;;
    esac
    [[ "$(fl_backup_field "$set" complete)" == "true" ]] || now="${now} (incomplete)"
    apps=""
    while IFS='|' read -r aname acommit _; do
      [[ -n "$aname" ]] && apps="${apps}${apps:+ }${aname}@${acommit:0:7}"
    done < <(fl_snap_apps_list "${dir}/${id}/manifest.json")
    rows+=("${id}|$(fl_snap_mfield "${dir}/${id}/manifest.json" label)$([[ "$id" == "$last" ]] && printf ' (undo point of the last rollback)')|$(fl_fmt_bytes "$(fl_backup_field "$set" size_bytes)")|${apps:--}|${now}")
  done < <(fl_snap_ids "$name")
  if [[ "$n" == "0" ]]; then
    fl_info "no snapshots of ${name} yet; take one with: benchbar site snapshot ${name} --label TEXT"
    fl_snap_leftovers_note "$name"
    return 0
  fi
  fl_table "${rows[@]}"
  fl_note "folder: ${dir}"
  fl_note "the snapshots hold $(fl_fmt_bytes "$total")${free:+; $(fl_fmt_bytes "$free") are free on this volume}"
  if [[ -n "$over" ]]; then
    fl_note "retention keeps the newest ${keep}; beyond it: $(printf '%s' "$over" | tr '\n' ' ')"
    fl_note "nothing is removed on its own; a person removes them with: benchbar site snapshot drop ${name} --prune"
  fi
  fl_snap_held_note "$name" "$keep"
  fl_snap_leftovers_note "$name"
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
  [[ -z "$FL_SNAP_SKIPPED" ]] || fl_warn "--to latest skipped incomplete snapshot(s): ${FL_SNAP_SKIPPED}"
  # an incomplete snapshot is no plan at all, chosen by name or not: before any token is given
  if ! fl_snap_is_complete "$name" "$FL_SNAP_ID"; then
    fl_die "snapshot ${FL_SNAP_ID} of ${name} is incomplete (it lacks $(fl_snap_missing_parts "$name" "$FL_SNAP_ID")), so it cannot be rolled back to." \
      "benchbar site snapshots ${name} lists them; a person removes this one with: benchbar site snapshot drop ${name} ${FL_SNAP_ID}"
  fi
  SR_ROLLBACK=1
  SR_PERSON=0
  if fl_lease_person_ok; then SR_PERSON=1; fi
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
  fl_snap_list_remove "$1" .unfinished-rollbacks "$2"
  return 0
}

# site snapshot drop SITE SNAPSHOT | --prune [--keep N] [--yes] [--dry-run]
fl_cmd_site_snapshot_drop() {
  local name="" ref="" prune=0 json="$OPT_JSON" ids=() id keep freed=0 set b dropped=() want force=0
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --prune) prune=1; shift ;;
      --force-undo-point) force=1; shift ;;
      --keep) FL_SNAP_KEEP_OPT="${2:-}"; shift 2 || shift ;;
      --keep=*) FL_SNAP_KEEP_OPT="${1#*=}"; shift ;;
      -*) fl_die "Unknown option for site snapshot drop: $1" "Use: benchbar site snapshot drop SITE SNAPSHOT|--prune [--keep N] [--force-undo-point] [--yes] [--dry-run]" ;;
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
    [[ "$force" != "1" ]] || fl_die "--force-undo-point goes with one named snapshot; --prune never removes the undo point of the last rollback." "Use: benchbar site snapshot drop ${name} SNAPSHOT --force-undo-point"
    fl_snap_keep_v keep
    while IFS= read -r id; do [[ -n "$id" ]] && ids+=("$id"); done < <(fl_snap_over_limit "$name" "$keep")
    fl_snap_held_load "$name" "$keep"
  else
    [[ -n "$ref" ]] || fl_die "Name the snapshot to remove, or use --prune." "benchbar site snapshots ${name} lists them"
    fl_snap_resolve "$name" "$ref" || fl_die "$FL_SNAP_ERR" "$FL_SNAP_HINT"
    # the "before rollback" snapshot of the last rollback is what undoes it: a person says so to remove it
    if fl_snap_is_protected "$name" "$FL_SNAP_ID" && [[ "$force" != "1" ]]; then
      fl_die "${FL_SNAP_ID} is the undo point of a rollback of ${name} (the last one that finished, or one that did not): removing it leaves that rollback with no way back." \
        "If you are sure: benchbar site snapshot drop ${name} ${FL_SNAP_ID} --force-undo-point"
    fi
    ids+=("$FL_SNAP_ID")
  fi
  for id in ${ids[@]+"${ids[@]}"}; do
    set="$(fl_snap_json "$name" "$id")"
    b="$(fl_backup_field "$set" size_bytes)"; freed=$((freed + ${b:-0}))
  done
  if [[ "${FL_DRY_RUN:-0}" == "1" || "${#ids[@]}" == "0" ]]; then
    if [[ "$json" == "1" ]]; then
      # shellcheck disable=SC2086
      fl_doc_emit 0 "$(printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"site":%s,"dry_run":%s,"would_drop":%s,"dropped":[],"freed_bytes":%s,"held_back":%s,"held_back_bytes":%s}' \
        "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$name")" "$(fl_json_bool "$([[ "${FL_DRY_RUN:-0}" == "1" ]] && printf 1 || printf 0)")" \
        "$(fl_json_str_array ${ids[@]+"${ids[@]}"})" "$freed" "$(fl_json_str_array $FL_SNAP_HELD)" "$FL_SNAP_HELD_BYTES")" plan
      return 0
    fi
    if [[ "${#ids[@]}" == "0" ]]; then fl_ok "unchanged: no snapshot of ${name} is beyond the newest ${keep:-the limit}"; fl_snap_held_note "$name" "${keep:-0}"; return 0; fi
    fl_info "dry-run: would remove ${#ids[@]} snapshot(s) of ${name} ($(fl_fmt_bytes "$freed")): ${ids[*]}"
    fl_snap_held_note "$name" "${keep:-0}"
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
