#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# share.sh: benchbar share, a hardened copy of a site for colleagues on the
# same network to use in a room.
#
#   benchbar share setup [--site S] [--from STAMP|latest] [--backup-now] [--users A,B]
#       [--name LABEL] [--refresh] [--regenerate-identity] [--acknowledge-data]
#       [--dry-run] [--yes] [--json]
#   benchbar share users [--site S] [--json]
#
# setup makes the host identity (a P-256 key and certificate under
# $FL_STATE_DIR/share, mode 0700) and share.localhost, a copy of the site
# restored from a backup set and then hardened and demoted (share-site.sh).
# share.json, written last, is what the gateway starts from; a copy without it
# cannot be shared. It never moves the bench's default site. The copy holds
# the site's real data: setup refuses until that is acknowledged, and, like
# site open-as on, only a person can run it (a terminal, or the app after its
# own alert with BENCHBAR_SUDO=gui; never BENCHBAR_NONINTERACTIVE, --for-agent
# or mcp).
#
# share.json is written one key to a line, so the shell can read it back
# without a JSON parser: keep that layout.

FL_SHARE_MAX_SEATS=50
FL_SHARE_MAX_LABEL=40

fl_share_dir() { printf '%s/share' "$FL_STATE_DIR"; }
fl_share_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

fl_share_dir_ensure() {
  local dir
  dir="$(fl_share_dir)"
  (umask 077; mkdir -p "$dir")
  chmod 700 "$dir"
}

# fl_share_require_stopped: refuses while a share answers on its control
# socket; a socket nothing answers on (a crash left it) is removed
fl_share_require_stopped() {
  local sock="${FL_SHARE_CONTROL_SOCK:-$(fl_share_dir)/control.sock}"
  [[ -e "$sock" ]] || return 0
  if [[ -x /usr/bin/nc ]] && ! /usr/bin/nc -U -w 1 "$sock" </dev/null >/dev/null 2>&1; then
    rm -f "$sock"
    fl_info "removed the control socket of a share that is no longer running"
    return 0
  fi
  fl_die "Sharing is on, so the copy is in use." "Run benchbar share stop first, then run this again."
}

# the config to read: share.json; a --refresh falls back to the one it set aside (its seat ids and
# dates carry over), a plain run never reads that stale file
fl_share_cfg_file() {
  local d
  d="$(fl_share_dir)"
  if [[ -f "${d}/share.json" || "${SH_REFRESH:-0}" != 1 ]]; then printf '%s/share.json' "$d"; else printf '%s/share.json.prev' "$d"; fi
}

# fl_share_cfg_raw_v VAR KEY: the JSON text of a top level key of share.json
# (empty without the file or the key)
fl_share_cfg_raw_v() {
  local __file __v=""
  __file="$(fl_share_cfg_file)"
  [[ ! -f "$__file" ]] || __v="$(sed -n "s/^  \"$2\": \(.*\)\$/\1/p" "$__file" | awk 'NR == 1')"
  printf -v "$1" '%s' "${__v%,}"
}

# fl_share_cfg_str_v VAR KEY: a string key of share.json without its quotes
fl_share_cfg_str_v() {
  local __raw
  fl_share_cfg_raw_v __raw "$2"
  __raw="${__raw#\"}"
  printf -v "$1" '%s' "${__raw%\"}"
}

# fl_share_fingerprint_v VAR CERT: sha256:<hex of the SHA-256 of the certificate's SPKI, DER>
fl_share_fingerprint_v() {
  local __h
  __h="$(/usr/bin/openssl x509 -in "$2" -pubkey -noout | /usr/bin/openssl pkey -pubin -outform der | /usr/bin/shasum -a 256 | awk '{print $1}')"
  [[ "$__h" =~ ^[0-9a-f]{64}$ ]] || { fl_fail "could not read the public key of $2"; return 1; }
  printf -v "$1" 'sha256:%s' "$__h"
}

# fl_share_clean_label_v VAR TEXT: printable text of at most 40 characters:
# control, bidirectional and zero width characters are dropped (a label is
# shown to colleagues, so it must not be able to reorder or hide text)
fl_share_clean_label_v() {
  local __s
  fl__share_strip_v __s "$2"
  __s="${__s#"${__s%%[![:space:]]*}"}"
  __s="${__s%"${__s##*[![:space:]]}"}"
  printf -v "$1" '%s' "${__s:0:FL_SHARE_MAX_LABEL}"
}

fl__share_strip_v() {
  local LC_ALL=C __w="$2" __b __seq
  __w="${__w//[[:cntrl:]]/}"
  # U+200B..U+200F, U+202A..U+202E, U+2060, U+2066..U+2069, U+FEFF, U+061C: as UTF-8 bytes
  for __b in 8b 8c 8d 8e 8f aa ab ac ad ae; do
    printf -v __seq '%b' "\\xe2\\x80\\x${__b}"
    __w="${__w//"$__seq"/}"
  done
  for __b in a0 a6 a7 a8 a9; do
    printf -v __seq '%b' "\\xe2\\x81\\x${__b}"
    __w="${__w//"$__seq"/}"
  done
  printf -v __seq '\xef\xbb\xbf'; __w="${__w//"$__seq"/}"
  printf -v __seq '\xd8\x9c'; __w="${__w//"$__seq"/}"
  printf -v "$1" '%s' "$__w"
}

# fl_share_pick_web_port_v VAR [PRIOR]: the first port above the bench's own
# web port, up to 8099, that no other bench uses and nothing listens on; PRIOR
# (share.json's) is kept while it still qualifies
fl_share_pick_web_port_v() {
  local __var="$1" prior="${2:-}" taken p
  taken="$(fl_ports_taken_by_others)"
  # shellcheck disable=SC2153  # FL_WEB_PORT is the bench's, set by fl_context_init
  for p in ${prior:+"$prior"} $(seq $((FL_WEB_PORT + 1)) 8099); do
    [[ "$p" =~ ^[0-9]+$ && "$p" -gt "$FL_WEB_PORT" && "$p" -le 8099 ]] || continue
    [[ $'\n'"$taken" != *$'\n'"${p} "* ]] || continue
    [[ -z "$(fl_port_listener_pid "$p")" ]] || continue
    printf -v "$__var" '%s' "$p"
    return 0
  done
  fl_die "No free port from $((FL_WEB_PORT + 1)) to 8099 for the share's web process." "Stop what listens on those ports, then run this again."
}

# fl_share_gb_v VAR BYTES: gigabytes with two decimals, at least 0.01
fl_share_gb_v() {
  printf -v "$1" '%s' "$(awk -v b="$2" 'BEGIN { g = b / 1073741824; if (g < 0.01) g = 0.01; printf "%.2f", g }')"
}

# ---------------------------------------------------------------- share users

fl_cmd_share_users() {
  local site="$FL_SITE" a result doc u n e t r c table=()
  for a in "$@"; do
    case "$a" in
      -*) fl_die "Unknown option for share users: $a" "Use: benchbar share users [--site NAME] [--json]" ;;
      *) fl_die "share users takes no argument: $a" "Use: benchbar share users [--site NAME] [--json]" ;;
    esac
  done
  fl_site_json_begin
  fl_require_bench
  [[ -n "$site" ]] || fl_die "This bench has no default site." "Pass --site NAME (benchbar site list shows them)"
  fl_site_valid_name "$site"
  fl_site_require "$site"
  if [[ "$OPT_JSON" == "1" ]]; then
    fl_share_probe_v result "$site" json
    doc="$(printf '{"schema_version":%d,"cli_version":"%s","site":%s,%s' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$site")" "${result#\{}")"
    FL_DONE_NO_STATE=1
    fl_doc_emit 0 "$doc"
    return 0
  fi
  fl_share_probe_v result "$site" rows
  table=("User|Name|Type|Roles|Will lose")
  while IFS=$'\x1f' read -r u n e t r c; do
    if [[ -z "$u" ]]; then [[ "$n" == truncated && "$e" == 1 ]] && fl_warn "${site} has more than ${FL_SHARE_USER_CAP} users: the list stops there. Name a user with --users to be sure."; continue; fi
    table+=("${u}|${n//|//}|${t}$([[ "$e" == 1 ]] || printf ' (disabled)')|${r//|/, }|${c//|/, }")
  done <<<"$result"
  if [[ "${#table[@]}" == 1 ]]; then fl_info "No user on ${site}."; return 0; fi
  fl_table "${table[@]}"
  fl_note "A seat takes an enabled System User. In the copy a seat loses the roles under Will lose, which can run code or change settings."
}

# ---------------------------------------------------------------- share setup

# the state of one setup run, shared by its steps
SH_SITE=""; SH_STAMP=""; SH_BACKUP_NOW=0; SH_REFRESH=0; SH_REGEN=0; SH_COPY_EXISTS=0; SH_COPY_BUILT=0
SH_USERS=(); SH_SEAT_NAMES=(); SH_SEAT_ROLES=()
SH_LABEL_JSON=""; SH_WEB_PORT=""; SH_APPS_JSON="{}"; SH_HARDEN_JSON=""; SH_RESTORE_TOKEN=""; SH_WITH_FILES=0
SH_PRIOR_USERS=""; SH_FINGERPRINT=""

# fl_share_user_ok NAME: a name that survives a comma separated list, one line of
# stdin and share.json written by the shell
fl_share_user_ok() { [[ "$1" =~ ^[^[:space:][:cntrl:]\",\\]{1,140}$ ]]; }

# fl_share_resolve_users: SH_USERS and, for each, its seat's full name and
# the roles the copy keeps, from the source site; refuses a name that cannot
# take a seat
fl_share_resolve_users() {
  local rows="$1" u line found name full enabled type roles capable r kept role_list=() cut_note=""
  [[ "$rows" != $'\x1ftruncated\x1f1'* ]] || cut_note=" (the list of users stops at ${FL_SHARE_USER_CAP}, so it may be past that)"
  SH_SEAT_NAMES=(); SH_SEAT_ROLES=()
  for u in "${SH_USERS[@]}"; do
    found=0
    while IFS= read -r line; do
      IFS=$'\x1f' read -r name full enabled type roles capable <<<"$line"
      [[ "$name" == "$u" ]] || continue
      found=1
      if [[ "$enabled" != 1 || "$type" != "System User" || "$name" == Administrator ]]; then
        fl_die "${u} cannot take a seat: only an enabled System User can, and not Administrator." "Pick another user (benchbar share users lists them)."
      fi
      kept=""
      IFS='|' read -r -a role_list <<<"$roles"
      for r in ${role_list[@]+"${role_list[@]}"}; do
        [[ "|${capable}|" == *"|${r}|"* ]] || kept="${kept}${kept:+|}${r}"
      done
      SH_SEAT_NAMES+=("$full"); SH_SEAT_ROLES+=("$kept")
      break
    done <<<"$rows"
    [[ "$found" == 1 ]] || fl_die "No user '${u}' on ${SH_SITE}${cut_note}." "benchbar share users lists them."
  done
}

# fl_share_classes_text_v VAR_TEXT VAR_JSON ROWS: "User 5, Customer 3" and {"User":5,...}
fl_share_classes_v() {
  local __t="" __j="" __sep="" __tsep="" class count
  while IFS=$'\x1f' read -r class count; do
    [[ -n "$class" && "$count" =~ ^[0-9]+$ ]] || continue
    __t="${__t}${__tsep}${class} ${count}"; __tsep=", "
    __j="${__j}${__sep}$(fl_json_str "$class"):${count}"; __sep=","
  done <<<"$3"
  printf -v "$1" '%s' "$__t"
  printf -v "$2" '{%s}' "$__j"
}

fl_share_json_array_v() {
  local __var="$1" __out="" __sep="" __x
  shift
  for __x in "$@"; do __out="${__out}${__sep}$(fl_json_str "$__x")"; __sep=","; done
  printf -v "$__var" '[%s]' "$__out"
}

fl_cmd_share_setup() {
  local site="$FL_SITE" from=latest backup_now=0 users_arg="" refresh=0 regen=0 ack=0 name="" name_given=0 u
  local dir src_dir set size_bytes with_files="false" age="null" need_bytes size_gb est_min avail_kb free_gb
  local rows classes_text classes_json users_json steps_json prior_users_raw prior_users_json existing_key=0 i id code
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --from) [[ -n "${2:-}" ]] || fl_die "--from needs a backup stamp or latest." "Example: --from latest"; from="$2"; shift 2 ;;
      --from=*) from="${1#*=}"; shift ;;
      --backup-now) backup_now=1; shift ;;
      --users) [[ -n "${2:-}" ]] || fl_die "--users needs a comma separated list." "Example: --users priya@example.com,sam@example.com"; users_arg="$2"; shift 2 ;;
      --users=*) users_arg="${1#*=}"; shift ;;
      --name) [[ "$#" -ge 2 ]] || fl_die "--name needs a label." "Example: --name \"Priya's room\""; name="$2"; name_given=1; shift 2 ;;
      --name=*) name="${1#*=}"; name_given=1; shift ;;
      --refresh) refresh=1; shift ;;
      --regenerate-identity) regen=1; shift ;;
      --acknowledge-data) ack=1; shift ;;
      *) fl_die "Unknown argument for share setup: $1" "Use: benchbar share setup [--site S] [--from STAMP|latest] [--backup-now] [--users A,B] [--name LABEL] [--refresh] [--regenerate-identity] [--acknowledge-data] [--dry-run] [--yes] [--json]" ;;
    esac
  done
  fl_noninteractive && fl_die "Sharing a site is a person's decision, so nothing run without a terminal can start it." \
    "Run it in a terminal: benchbar share setup"
  [[ -t 0 || "${BENCHBAR_SUDO:-}" == gui ]] || fl_die "Sharing needs a person at a terminal, and this run has none." \
    "Run it in a terminal: benchbar share setup"
  [[ "$backup_now" == 0 || "$from" == latest ]] || fl_die "--backup-now and --from name two different sources." "Pass one of them."
  fl_require_bench
  fl_require_plain_bench
  [[ -n "$site" ]] || fl_die "This bench has no default site." "Pass --site NAME (benchbar site list shows them)"
  fl_site_valid_name "$site"
  fl_site_require "$site"
  [[ "$site" != "$FL_SHARE_SITE" ]] || fl_die "${FL_SHARE_SITE} is the copy; there is nothing to copy from it." "Pass --site with the site to share."
  [[ "$from" == latest || "$from" =~ ^[0-9]{8}_[0-9]{6}$ ]] || fl_die "--from takes a backup stamp (YYYYmmdd_HHMMSS) or latest." "benchbar site backups ${site} lists the stamps."
  fl_share_require_stopped
  dir="$(fl_share_dir)"
  SH_SITE="$site"; SH_BACKUP_NOW="$backup_now"; SH_REFRESH="$refresh"; SH_REGEN="$regen"
  [[ -f "${FL_BENCH_DIR}/sites/${FL_SHARE_SITE}/site_config.json" ]] && SH_COPY_EXISTS=1
  [[ -s "${dir}/host.key" && -s "${dir}/host.crt" ]] && existing_key=1

  # who may sign in: --users, else the people of the last setup
  fl_share_cfg_raw_v prior_users_raw allowed_users
  SH_PRIOR_USERS="$prior_users_raw"
  if [[ -n "$users_arg" ]]; then
    IFS=',' read -r -a SH_USERS <<<"$users_arg"
  elif [[ -n "$prior_users_raw" ]]; then
    prior_users_raw="${prior_users_raw#\[\"}"; prior_users_raw="${prior_users_raw%\"\]}"
    while IFS= read -r u; do SH_USERS+=("$u"); done <<<"${prior_users_raw//\",\"/$'\n'}"
  fi
  [[ "${#SH_USERS[@]}" -gt 0 ]] || fl_die "Choose who may sign in to the copy: --users A,B" "benchbar share users lists them."
  local unique=()
  for u in "${SH_USERS[@]}"; do
    fl_share_user_ok "$u" || fl_die "'${u}' is not a user name setup can carry." "Use the names benchbar share users prints."
    case " ${unique[*]:-} " in *" ${u} "*) continue ;; esac
    unique+=("$u")
  done
  SH_USERS=("${unique[@]}")
  [[ "${#SH_USERS[@]}" -le "$FL_SHARE_MAX_SEATS" ]] || fl_die "A room has at most ${FL_SHARE_MAX_SEATS} seats." "Pick fewer users."
  fl_share_json_array_v users_json "${SH_USERS[@]}"

  fl_header "benchbar share setup" "$(fl_mode_name)" "$FL_PROFILE" "$FL_BENCH_DIR" "$site"
  fl_share_probe_v rows "$site" rows
  fl_share_resolve_users "$rows"
  fl_share_probe_v rows "$site" classes
  fl_share_classes_v classes_text classes_json "$rows"

  # the copy that exists keeps its people: another list needs --refresh
  if [[ "$SH_COPY_EXISTS" == 1 && "$refresh" != 1 ]]; then
    [[ -f "${dir}/share.json" && -n "$SH_PRIOR_USERS" ]] || fl_die "${FL_SHARE_SITE} exists but share.json does not, so nobody knows how it was hardened." \
      "Rebuild it: benchbar share setup --refresh"
    [[ "$SH_PRIOR_USERS" == "$users_json" ]] || fl_die "The people changed since the copy was made; the copy keeps the old ones." \
      "Rebuild the copy with the new list: benchbar share setup --users ... --refresh"
  fi

  # the source set, and what the copy needs
  src_dir="$(fl_site_backup_dir "$site")"
  if [[ "$backup_now" == 1 ]]; then
    fl_share_pick_stamp_v SH_STAMP "$src_dir"
    set=""; [[ -z "$SH_STAMP" ]] || set="$(fl_backup_set_json "$src_dir" "$SH_STAMP")"
    SH_STAMP=""
    if [[ -n "$set" ]]; then size_bytes="$(fl_backup_field "$set" size_bytes)"
    else size_bytes="$(du -sk "${FL_BENCH_DIR}/sites/${site}" 2>/dev/null | awk '{print $1 * 1024}')"; fi
  else
    if [[ "$from" == latest ]]; then
      fl_share_pick_stamp_v SH_STAMP "$src_dir"
      [[ -n "$SH_STAMP" ]] || fl_die "no backup of ${site}: run benchbar site backup ${site} or pass --backup-now" \
        "Then run benchbar share setup again."
    else
      SH_STAMP="$from"
    fi
    set="$(fl_backup_set_json "$src_dir" "$SH_STAMP" 2>/dev/null || true)"
    [[ -n "$set" && "$(fl_backup_field "$set" database)" != null ]] || fl_die "no complete database backup with the stamp ${SH_STAMP} in ${src_dir}" "benchbar site backups ${site} lists them."
    [[ "$(fl_backup_field "$set" encrypted)" == false ]] || fl_die "the set ${SH_STAMP} is encrypted; share setup takes a plain set." "Take a new one: benchbar site backup ${site}"
    size_bytes="$(fl_backup_field "$set" size_bytes)"
    with_files="$(fl_backup_field "$set" with_files)"
    age="$(( $(date +%s) - $(fl_file_mtime "$(fl_backup_field "$set" database)") ))"
  fi
  [[ "$with_files" == true ]] && SH_WITH_FILES=1
  [[ "$size_bytes" =~ ^[0-9]+$ ]] || size_bytes=0
  need_bytes=$((size_bytes * 2))
  fl_share_gb_v size_gb "$need_bytes"
  est_min="$(awk -v b="$size_bytes" 'BEGIN { printf "%d", 2 + b / 1073741824 * 12 + 0.999 }')"
  [[ "$backup_now" != 1 ]] || age=0

  steps_json='["identity","backup","share_site","harden","baseline","config","exclude"]'
  if [[ "${OPT_JSON:-0}" == 1 ]]; then
    fl_doc_emit 0 "$(printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"site":%s,"share_site":%s,"dry_run":%s,"backup_now":%s,"source_stamp":%s,"refresh":%s,"regenerate_identity":%s,"users":%s,"size_gb":%s,"est_minutes":%s,"source_age_s":%s,"data_classes":%s,"steps":%s}' \
      "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$site")" "$(fl_json_str "$FL_SHARE_SITE")" \
      "$(fl_json_bool "${FL_DRY_RUN:-0}")" "$(fl_json_bool "$backup_now")" "$(fl_json_str "$SH_STAMP")" "$(fl_json_bool "$refresh")" "$(fl_json_bool "$regen")" \
      "$users_json" "$size_gb" "$est_min" "$age" "$classes_json" "$steps_json")" plan
  fi
  fl_box "Share setup" \
    "site     ${site} -> ${FL_SHARE_SITE}$([[ "$SH_COPY_EXISTS" == 1 && "$refresh" == 1 ]] && printf ' (replaced)')" \
    "from     $([[ "$backup_now" == 1 ]] && printf 'a backup taken now' || printf '%s (%s old)' "$SH_STAMP" "$(fl_fmt_secs "$age")")" \
    "needs    about ${size_gb} GB free, about ${est_min} min" \
    "people   ${SH_USERS[*]}" \
    "data     ${classes_text:-none counted}"

  if [[ "${FL_DRY_RUN:-0}" == 1 ]]; then
    fl_info "dry-run: nothing was backed up, copied or written"
    return 0
  fi

  avail_kb="$(df -Pk "$FL_BENCH_DIR" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  if [[ "$avail_kb" =~ ^[0-9]+$ && $((avail_kb * 1024)) -lt "$need_bytes" ]]; then
    fl_share_gb_v free_gb "$((avail_kb * 1024))"
    fl_die "Sharing needs about ${size_gb} GB free on the bench's disk, and ${free_gb} GB is free." "Free some space, then run this again."
  fi

  # the copy holds real data: nothing is written until that is acknowledged
  if [[ "$ack" != 1 ]]; then
    if [[ -t 0 && "${OPT_JSON:-0}" != 1 ]]; then
      fl_warn "The copy will hold real data from ${site}: ${classes_text}. People on your network will see it."
      FL_ASSUME_YES=0 fl_confirm "Make a copy of ${site} with its real data for others to use?" || fl_die "Nothing was changed." "Run again and answer yes, or pass --acknowledge-data."
    else
      fl_die "The copy will hold real data from ${site} (${classes_text}); setup stops until that is acknowledged." \
        "Pass --acknowledge-data once you have read what it holds."
    fi
  fi
  if [[ "$SH_COPY_EXISTS" == 1 && "$refresh" == 1 ]]; then
    fl_confirm "Replaces the copy. Anything guests changed in it is lost." || fl_die "Nothing was changed." "Run again and answer yes, or pass --yes."
  fi
  if [[ "$regen" == 1 && "$existing_key" == 1 ]]; then
    fl_warn "A new identity means every Mac that joined must join again: every pairing becomes invalid."
    fl_confirm "Replace the host identity?" || fl_die "Nothing was changed." "Run again and answer yes, or pass --yes."
  fi

  fl_steps_define "Create the host identity" "Take a backup of ${site}" "Make the copy ${FL_SHARE_SITE}" "Harden and demote the copy" \
    "Record the apps at copy time" "Write share.json" "Keep the share out of Time Machine"
  fl_steps_ids identity backup share_site harden baseline config exclude
  fl_share_label_resolve "$name_given" "$name"
  i=0
  for id in identity backup share_site harden baseline config exclude; do
    fl_step_begin "$i"
    FL_STEP_RESULT="done"
    code=0
    "fl_share_step_${id}" || code=$?
    if [[ "$code" != 0 ]]; then
      fl_step_end failed
      [[ "$id" != harden && "$id" != share_site ]] || fl_warn "${FL_SHARE_SITE} may exist but is not hardened: nothing can share it until share setup finishes."
      fl_die "share setup stopped at: ${FL_STEP_LABELS[$i]}." "Fix what is listed above, then run it again."
    fi
    fl_step_end "$FL_STEP_RESULT"
    i=$((i + 1))
  done
  fl_next_action "benchbar share start" "Start sharing the copy on your network"
  [[ "${OPT_JSON:-0}" != 1 ]] || fl_doc_emit 0 "$(fl_share_result_doc)"
  fl_ok "${FL_SHARE_SITE} is ready: ${#SH_USERS[@]} seats, web port ${SH_WEB_PORT}, the default site stays $(fl_share_default_site)"
}

fl_share_default_site() { local d; fl_site_default_file_v d; printf '%s' "$d"; }

# fl_share_label_resolve GIVEN TEXT: SH_LABEL_JSON, the room's label as JSON:
# the one asked for, else the last setup's, else "<full name>'s room"
fl_share_label_resolve() {
  local label full
  if [[ "$1" == 1 ]]; then
    fl_share_clean_label_v label "$2"
  else
    fl_share_cfg_raw_v SH_LABEL_JSON room_label
    [[ -z "$SH_LABEL_JSON" ]] || return 0
  fi
  if [[ -z "${label:-}" ]]; then
    full="$(id -F 2>/dev/null || true)"
    fl_share_clean_label_v full "${full:-${FL_OS_USER:-${USER:-Someone}}}"
    fl_share_clean_label_v label "${full}'s room"
  fi
  fl_json_str_v SH_LABEL_JSON "$label"
}

fl_share_result_doc() {
  local token="null" hardening="null"
  [[ -z "$SH_RESTORE_TOKEN" ]] || token="$(fl_json_str "$SH_RESTORE_TOKEN")"
  [[ "$SH_HARDEN_JSON" =~ ^\{[^{}]*\}$ ]] && hardening="$SH_HARDEN_JSON"
  printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"site":%s,"share_site":%s,"default_site":%s,"web_port":%s,"fingerprint":%s,"room_label":%s,"seats":%s,"restore_token":%s,"hardening":%s}' \
    "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$SH_SITE")" "$(fl_json_str "$FL_SHARE_SITE")" \
    "$(fl_json_str "$(fl_share_default_site)")" "$SH_WEB_PORT" "$(fl_json_str "$SH_FINGERPRINT")" "$SH_LABEL_JSON" "${#SH_USERS[@]}" "$token" "$hardening"
}

# ---------------------------------------------------------------- the steps

fl_share_step_identity() {
  local dir key crt tmpkey tmpcrt
  fl_share_dir_ensure
  dir="$(fl_share_dir)"; key="${dir}/host.key"; crt="${dir}/host.crt"
  if [[ "$SH_REGEN" != 1 && -s "$key" && -s "$crt" ]]; then FL_STEP_RESULT=unchanged; return 0; fi
  tmpkey="${key}.new"; tmpcrt="${crt}.new"
  rm -f "$tmpkey" "$tmpcrt"
  (umask 077; /usr/bin/openssl ecparam -name prime256v1 -genkey -noout -out "$tmpkey") >>"${FL_LOG_FILE:-/dev/null}" 2>&1 \
    || { rm -f "$tmpkey"; fl_fail "openssl could not make the host key"; return 1; }
  (umask 077; /usr/bin/openssl req -new -x509 -key "$tmpkey" -days 3650 -subj /CN=benchbar-share -out "$tmpcrt") >>"${FL_LOG_FILE:-/dev/null}" 2>&1 \
    || { rm -f "$tmpkey" "$tmpcrt"; fl_fail "openssl could not make the host certificate"; return 1; }
  chmod 600 "$tmpkey"; chmod 644 "$tmpcrt"
  mv -f "$tmpkey" "$key"; mv -f "$tmpcrt" "$crt"
  if [[ "$SH_REGEN" == 1 ]]; then
    (umask 077; printf '{"v":3,"devices":[],"blocked":[]}\n' >"${dir}/devices.json.new")
    chmod 600 "${dir}/devices.json.new"; mv -f "${dir}/devices.json.new" "${dir}/devices.json"
    fl_changed identity host "replaced; every pairing is invalid"
  else
    fl_changed identity host "created"
  fi
  fl_share_fingerprint_v SH_FINGERPRINT "$crt" || return 1
  fl_ok "host identity ${SH_FINGERPRINT}"
}

fl_share_step_backup() {
  local src_dir
  if [[ "$SH_BACKUP_NOW" != 1 ]]; then FL_STEP_RESULT=skipped; fl_info "using the backup ${SH_STAMP}"; return 0; fi
  [[ "$SH_COPY_EXISTS" != 1 || "$SH_REFRESH" == 1 ]] || { FL_STEP_RESULT=skipped; return 0; }
  src_dir="$(fl_site_backup_dir "$SH_SITE")"
  OPT_JSON=0 fl_cmd_site_backup "$SH_SITE" || return 1
  fl_share_pick_stamp_v SH_STAMP "$src_dir"
  [[ -n "$SH_STAMP" ]] || { fl_fail "the backup of ${SH_SITE} left no complete set in ${src_dir}"; return 1; }
  fl_info "the copy is made from ${SH_STAMP}"
}

fl_share_step_share_site() {
  local dir
  if [[ "$SH_COPY_EXISTS" == 1 && "$SH_REFRESH" != 1 ]]; then FL_STEP_RESULT=unchanged; return 0; fi
  # from here the copy is raw data until harden finishes: share.json goes aside, and only the config step makes it again
  dir="$(fl_share_dir)"
  if [[ -f "${dir}/share.json" ]]; then mv -f "${dir}/share.json" "${dir}/share.json.prev" || return 1; fi
  fl_share_copy_plan_apply "$SH_SITE" "$SH_STAMP" "$SH_WITH_FILES" || return 1
  SH_COPY_BUILT=1
}

fl_share_step_harden() {
  fl_info "${FL_SHARE_SITE} is not hardened yet: do not use it until share setup finishes."
  fl_share_harden_v SH_HARDEN_JSON "${SH_USERS[@]}" || return 1
  fl_ok "hardened ${FL_SHARE_SITE}: ${#SH_USERS[@]} seats, $(fl_backup_field "$SH_HARDEN_JSON" users_demoted) demoted ($(fl_backup_field "$SH_HARDEN_JSON" roles_removed) roles removed), $(fl_backup_field "$SH_HARDEN_JSON" users_disabled) other users disabled, $(fl_backup_field "$SH_HARDEN_JSON" sessions_deleted) sessions deleted"
}

fl_share_step_baseline() {
  if [[ "$SH_COPY_BUILT" != 1 ]]; then
    fl_share_cfg_raw_v SH_APPS_JSON apps_at_copy
    [[ -n "$SH_APPS_JSON" ]] || fl_share_app_heads_v SH_APPS_JSON || return 1
    FL_STEP_RESULT=unchanged
    return 0
  fi
  fl_share_app_heads_v SH_APPS_JSON || return 1
}

# fl_share_seats_json_v VAR: one seat to a line; a user keeps its seat id while it stays
fl_share_seats_json_v() {
  local __var="$1" __out="" __sep="" i u id line roles_json file
  local role_list=()
  file="$(fl_share_cfg_file)"
  for ((i = 0; i < ${#SH_USERS[@]}; i++)); do
    u="${SH_USERS[$i]}"
    id=""
    if [[ -f "$file" ]]; then
      line="$(grep -F -- "\"user\":$(fl_json_str "$u")," "$file" | awk 'NR == 1' || true)"
      id="${line#*\"seat_id\":\"}"; id="${id%%\"*}"
      [[ "$id" =~ ^s_[0-9a-f]{8}$ ]] || id=""
    fi
    [[ -n "$id" ]] || id="s_$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
    IFS='|' read -r -a role_list <<<"${SH_SEAT_ROLES[$i]}"
    fl_share_json_array_v roles_json ${role_list[@]+"${role_list[@]}"}
    __out="${__out}${__sep}"$'\n'"    {\"seat_id\":$(fl_json_str "$id"),\"user\":$(fl_json_str "$u"),\"full_name\":$(fl_json_str "${SH_SEAT_NAMES[$i]}"),\"roles\":${roles_json}}"
    __sep=","
  done
  printf -v "$__var" '%s' "$__out"
}

fl_share_step_config() {
  local dir file tmp users_json seats_json prior_port copy_made source_stamp ack created now content crt
  dir="$(fl_share_dir)"; file="${dir}/share.json"; crt="${dir}/host.crt"
  now="$(fl_share_now_iso)"
  fl_share_fingerprint_v SH_FINGERPRINT "$crt" || return 1
  fl_share_cfg_str_v prior_port web_port
  fl_share_pick_web_port_v SH_WEB_PORT "$prior_port"
  fl_share_json_array_v users_json "${SH_USERS[@]}"
  fl_share_seats_json_v seats_json
  if [[ "$SH_COPY_BUILT" == 1 ]]; then
    copy_made="$now"; source_stamp="$SH_STAMP"; ack="$now"
  else
    fl_share_cfg_str_v copy_made copy_made; fl_share_cfg_str_v source_stamp copy_source_stamp; fl_share_cfg_str_v ack pii_acknowledged_at
    [[ -n "$ack" ]] || ack="$now"
  fi
  fl_share_cfg_str_v created created
  [[ -n "$created" ]] || created="$now"
  [[ -n "$SH_LABEL_JSON" ]] || fl_json_str_v SH_LABEL_JSON "Room"
  content="$(printf '{\n  "v": 3,\n  "site": %s,\n  "share_site": %s,\n  "allowed_users": %s,\n  "room_label": %s,\n  "seats": [%s\n  ],\n  "web_port": %s,\n  "fingerprint": %s,\n  "copy_made": %s,\n  "copy_source_stamp": %s,\n  "apps_at_copy": %s,\n  "pii_acknowledged_at": %s,\n  "created": %s\n}\n' \
    "$(fl_json_str "$SH_SITE")" "$(fl_json_str "$FL_SHARE_SITE")" "$users_json" "$SH_LABEL_JSON" "$seats_json" "$SH_WEB_PORT" "$(fl_json_str "$SH_FINGERPRINT")" \
    "$(fl_json_str "$copy_made")" "$(fl_json_str "$source_stamp")" "$SH_APPS_JSON" "$(fl_json_str "$ack")" "$(fl_json_str "$created")")"
  if [[ -f "$file" && "$(<"$file")" == "$content" ]]; then FL_STEP_RESULT=unchanged
  else
    tmp="${file}.new"
    if ! { (umask 077; printf '%s\n' "$content" >"$tmp") && chmod 600 "$tmp" && mv -f "$tmp" "$file"; }; then
      fl_fail "could not write ${file}"; return 1
    fi
    fl_changed config "share.json" "written"
  fi
  rm -f "$(fl_share_dir)/share.json.prev"
}

fl_share_step_exclude() {
  local tm="${FL_TMUTIL:-/usr/bin/tmutil}" path warned=0
  if fl_is_linux || [[ ! -x "$tm" ]]; then FL_STEP_RESULT=skipped; fl_info "no Time Machine here"; return 0; fi
  for path in "$(fl_share_dir)" "${FL_BENCH_DIR}/sites/${FL_SHARE_SITE}"; do
    "$tm" addexclusion "$path" >>"${FL_LOG_FILE:-/dev/null}" 2>&1 || { fl_warn "could not keep ${path} out of Time Machine"; warned=1; }
  done
  [[ "$warned" == 0 ]] || FL_STEP_RESULT=warning
}

fl_cmd_share() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    setup) fl_cmd_share_setup "$@" ;;
    users) fl_cmd_share_users "$@" ;;
    preflight) fl_cmd_share_preflight "$@" || exit 1 ;;
    *) fl_die "Usage: benchbar share setup|users|preflight ..." "Example: benchbar share users --site ${FL_SITE:-NAME}" ;;
  esac
}
