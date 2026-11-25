#!/usr/bin/env bash
#
# lease.sh: leases on a bench or a site. The run lock (lock.sh) holds for one
# command; a lease holds for many: "I am running tests on site X for 20
# minutes". While it runs, the commands that restart, stop, migrate, drop or
# restore what it covers refuse, naming who holds it and until when, unless
# the caller passes the lease's id (--lease ID). A person at a terminal can
# pass --break-lease instead; an agent, mcp and a run without a person never
# can. Reading is never refused.
#
#   benchbar lease take (--bench PATH | --site NAME) [--for MINUTES] [--note TEXT]
#   benchbar lease release ID | renew ID [--for MINUTES] | list [--bench PATH]
#
# The leases are one small file in the state folder (leases.tsv, format in
# benchstate.sh, which also reads it for status). A lease past its expiry is
# ignored everywhere and dropped by the next write. Writes take a short lock
# folder of their own (leases.lock): taking a lease must work while a long
# command holds the run lock, which is the case a lease is for.
#
# Leases are coordination between cooperating callers, not access control: an
# agent with a shell runs as the same user and can do what the user can. What
# they do is stop accidents. An id is what lets a run change a leased bench, so
# `lease list` shows it only to the lease's own holder (BENCHBAR_CALLER, or the
# login name), a clash names the holder and the end and never an id, status
# and the other readers never show one, and an agent that did not name itself
# cannot take a lease (it would be "agent", like every other one).

FL_LEASE_DEFAULT_MINUTES=30
FL_LEASE_MAX_MINUTES=480
FL_LEASE_MAX_ACTIVE=64
FL_LEASE_ID_RE='^l-[0-9a-f]{12}$'
FL_LEASE_LINES=()
FL_LEASE_NOW=0

# the lease fl__lease_split read (the fields of leases.tsv)
L_ID=""; L_KIND=""; L_BENCH=""; L_SITE=""; L_HOLDER=""; L_SINCE=""; L_SE=""; L_EXP=""; L_EE=""; L_MINS=""; L_NOTE=""

# fl__lease_split LINE: the fields of one line of leases.tsv into L_*; no
# site and no note read as empty
fl__lease_split() {
  IFS=$'\t' read -r L_ID L_KIND L_BENCH L_SITE L_HOLDER L_SINCE L_SE L_EXP L_EE L_MINS L_NOTE <<<"$1"
  [[ "$L_SITE" != "-" ]] || L_SITE=""
  [[ "$L_NOTE" != "-" ]] || L_NOTE=""
  return 0
}

# fl__lease_load: FL_LEASE_LINES gets the active leases (the expired and the
# malformed ones are left out), FL_LEASE_NOW the time they were judged at
fl__lease_load() {
  local f="${FL_STATE_DIR}/leases.tsv" line
  FL_LEASE_LINES=()
  fl_lease_now_v FL_LEASE_NOW
  [[ -f "$f" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    fl__lease_split "$line"
    [[ "$L_ID" =~ $FL_LEASE_ID_RE && ( "$L_KIND" == "bench" || "$L_KIND" == "site" ) && -n "$L_BENCH" && -n "$L_HOLDER" ]] || continue
    [[ "$L_EE" =~ ^[0-9]+$ && "$L_EE" -gt "$FL_LEASE_NOW" && "$L_MINS" =~ ^[0-9]+$ ]] || continue
    FL_LEASE_LINES+=("$line")
  done <"$f"
  return 0
}

# fl__lease_write: FL_LEASE_LINES becomes the file (no file at all when none is left), through a temp file and a rename
fl__lease_write() {
  local f="${FL_STATE_DIR}/leases.tsv" tmp l
  if [[ "${#FL_LEASE_LINES[@]}" -eq 0 ]]; then rm -f "$f"; return 0; fi
  mkdir -p "$FL_STATE_DIR" 2>/dev/null || true
  tmp="$(mktemp "${FL_STATE_DIR}/.leases.XXXXXX")" || return 1
  for l in "${FL_LEASE_LINES[@]}"; do printf '%s\n' "$l"; done >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# fl__lease_lock, fl__lease_unlock: the short lock around a read, change and write of the file. A
# lock folder older than 30 seconds belongs to a run that died inside its few file operations, and
# a waiter takes it away. One waiter at a time does that, under a guard folder (leases.lock.reclaim),
# and it reads the age again under the guard, right before it removes the folder.
# Both folders are made with fl_mkdir_excl (lock.sh), not a bare mkdir: uutils coreutils' mkdir
# (Ubuntu 25.10 and later) also says yes to the run that lost the race to make the folder, so two
# takes held the lock, both read the file before either wrote it, and one lease was lost although
# its take said ok (issue 138, CI on Ubuntu 26.04).
# The lock is never renamed away and put back. That was the first design: a waiter that judged the
# old folder stale could rename a live lock away, and the put back landed inside the new folder,
# which no rmdir could remove any more, so every later take ended with "busy".
# Returns 1 when another run keeps the lock, 2 when the folder takes no claim (no space, no
# permission): nobody holds it then, and fl__lease_lock_or_die says so at once.
fl__lease_lock() {
  local dir="${FL_STATE_DIR}/leases.lock" guard i=0 rc
  guard="${dir}.reclaim"
  mkdir -p "$FL_STATE_DIR" 2>/dev/null || true
  while :; do
    rc=0; fl_mkdir_excl "$dir" || rc=$?
    [[ "$rc" != 0 ]] || return 0
    if [[ "$rc" == 2 ]]; then rmdir "$dir" 2>/dev/null || true; return 2; fi
    if [[ -d "$dir" && "$(fl__lock_age "$dir")" -ge 30 ]]; then
      if fl_mkdir_excl "$guard"; then
        # judged again: since the look above another waiter may have removed the stale folder and a
        # third run taken the lock, and that one is not this run's to remove
        if [[ -d "$dir" && "$(fl__lock_age "$dir")" -ge 30 ]]; then fl_rmdir_excl "$dir" || true; fi
        fl_rmdir_excl "$guard" || true
        continue
      fi
      # a waiter that died with the guard
      if [[ -d "$guard" && "$(fl__lock_age "$guard")" -ge 30 ]]; then fl_rmdir_excl "$guard" || true; fi
    fi
    i=$((i + 1))
    [[ "$i" -le 50 ]] || return 1
    sleep 0.1
  done
}
fl__lease_unlock() { fl_rmdir_excl "${FL_STATE_DIR}/leases.lock" || true; }

# fl__lease_lock_or_die: the lock, or a refusal that says why: busy, or the folder cannot be written
fl__lease_lock_or_die() {
  local rc=0
  fl__lease_lock || rc=$?
  [[ "$rc" != 2 ]] || fl_die "Could not write the lock ${FL_STATE_DIR}/leases.lock." \
    "Check the free space and the owner of ${FL_STATE_DIR} (df -h ${FL_STATE_DIR}; ls -ld ${FL_STATE_DIR}), then try again."
  [[ "$rc" == 0 ]] || fl_die "Another lease command is busy (${FL_STATE_DIR}/leases.lock)." "Try again in a moment."
}

# fl_lease_holder_v VAR: who a lease is held by: BENCHBAR_CALLER (a name the agent or script chose; a mcp
# server sets it per client), else "agent" under BENCHBAR_NONINTERACTIVE, else the login name
fl_lease_holder_v() {
  local __h="${BENCHBAR_CALLER:-}"
  if [[ -n "$__h" ]]; then
    [[ "$__h" =~ ^[A-Za-z0-9][A-Za-z0-9._@:+-]{0,39}$ ]] || fl_die "BENCHBAR_CALLER is not a usable name: it takes 1 to 40 letters, digits or . _ @ : + - and starts with a letter or a digit." \
      "Set it to a name for this agent or script, for example BENCHBAR_CALLER=claude-qa."
  elif fl_noninteractive; then
    __h="agent"
  else
    __h="${FL_OS_USER:-${USER:-${LOGNAME:-}}}"
    __h="${__h//[^A-Za-z0-9._@:+-]/_}"
    __h="${__h:0:40}"
    [[ "$__h" =~ ^[A-Za-z0-9] ]] || __h="person"
  fi
  printf -v "$1" '%s' "$__h"
}

# fl_lease_person_ok: a person is here: not under BENCHBAR_NONINTERACTIVE (--for-agent, mcp), and a
# terminal, or the app saying a person clicked (fl_person_env_ok)
fl_lease_person_ok() {
  fl_noninteractive && return 1
  [[ -t 0 ]] && return 0
  fl_person_env_ok BENCHBAR_NONINTERACTIVE 0
}

# fl__lease_note_v VAR TEXT: a note another agent will read: printable ASCII only (anything else is
# a "?"), no line break, trimmed, at most 120 characters
fl__lease_note_v() {
  local LC_ALL=C __n="${2:-}"
  __n="${__n//[^ -~]/?}"
  __n="${__n#"${__n%%[![:space:]]*}"}"
  __n="${__n%"${__n##*[![:space:]]}"}"
  printf -v "$1" '%s' "${__n:0:120}"
}

# fl__lease_what_v VAR: "bench /path" or "site NAME of /path" for the lease in L_*
fl__lease_what_v() {
  if [[ "$L_KIND" == "site" ]]; then printf -v "$1" 'site %s of %s' "$L_SITE" "$L_BENCH"; else printf -v "$1" 'bench %s' "$L_BENCH"; fi
}

# fl__lease_obj_v VAR SHOW_ID: the lease in L_* as a JSON object; the id only when SHOW_ID is 1
fl__lease_obj_v() {
  local jid="null" jb js jh jn jy
  [[ "${2:-0}" != "1" ]] || fl_json_str_v jid "$L_ID"
  fl_json_str_v jb "$L_BENCH"; fl_json_str_v js "$L_SITE"; fl_json_str_v jh "$L_HOLDER"; fl_json_str_v jn "$L_NOTE"
  fl_json_bool_v jy "${3:-0}"
  printf -v "$1" '{"id":%s,"scope":"%s","bench":%s,"site":%s,"holder":%s,"note":%s,"since":"%s","expires_at":"%s","minutes":%s,"yours":%s}' \
    "$jid" "$L_KIND" "$jb" "$js" "$jh" "$jn" "$L_SINCE" "$L_EXP" "$L_MINS" "$jy"
}

# fl__lease_new_id_v VAR: l- and 12 hex digits that no active lease has
fl__lease_new_id_v() {
  local __id __x __n=0 __l
  while :; do
    __x="$(od -An -N6 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    [[ "$__x" =~ ^[0-9a-f]{12}$ ]] || __x="$(printf '%04x%04x%04x' "$RANDOM" "$RANDOM" "$RANDOM")"
    __id="l-${__x}"
    for __l in ${FL_LEASE_LINES[@]+"${FL_LEASE_LINES[@]}"}; do
      [[ "${__l%%$'\t'*}" != "$__id" ]] || { __id=""; break; }
    done
    [[ -z "$__id" && "$__n" -lt 20 ]] || break
    __n=$((__n + 1))
  done
  printf -v "$1" '%s' "$__id"
}

# fl__lease_minutes_v VAR TEXT: a number of minutes from 1 to the maximum, or a refusal
fl__lease_minutes_v() {
  [[ "$2" =~ ^[0-9]{1,4}$ ]] && [[ "$((10#$2))" -ge 1 && "$((10#$2))" -le "$FL_LEASE_MAX_MINUTES" ]] \
    || fl_die "--for takes a number of minutes from 1 to ${FL_LEASE_MAX_MINUTES}, not '${2}'." "Example: benchbar lease take --site qa1.localhost --for 20"
  printf -v "$1" '%s' "$((10#$2))"
}

# fl__lease_id_check ID: a refusal for a word that is not a lease id
fl__lease_id_check() {
  [[ "${1:-}" =~ $FL_LEASE_ID_RE ]] || fl_die "'${1:-}' is not a lease id (l- and 12 hex digits)." "The id came back from: benchbar lease take"
}

# ---------------------------------------------------------------- lease take, release, renew, list

fl_cmd_lease() {
  local action="${1:-list}"
  [[ "$#" -eq 0 ]] || shift
  case "$action" in
    take) fl_lease_take "$@" ;;
    release) fl_lease_release "$@" ;;
    renew) fl_lease_renew "$@" ;;
    list) fl_lease_list "$@" ;;
    *) fl_die "Unknown lease command: ${action}" "Use: benchbar lease take|release|renew|list. Example: benchbar lease take --site qa1.localhost --for 20 --note 'running tests'" ;;
  esac
}

fl_lease_take() {
  local bench="" mins="$FL_LEASE_DEFAULT_MINUTES" note="" kind site="" holder what id now exp since line clash="" clash_why="" cnt full=0 jobj
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --bench|--for|--note)
        [[ "$#" -ge 2 ]] || fl_die "$1 needs a value." "Use: benchbar lease take (--bench PATH | --site NAME) [--for MINUTES] [--note TEXT]"
        case "$1" in --bench) bench="$2" ;; --for) mins="$2" ;; *) note="$2" ;; esac
        shift 2 ;;
      --bench=*) bench="${1#*=}"; shift ;;
      --for=*) mins="${1#*=}"; shift ;;
      --note=*) note="${1#*=}"; shift ;;
      *) fl_die "Unknown argument for lease take: $1" "Use: benchbar lease take (--bench PATH | --site NAME) [--for MINUTES] [--note TEXT]" ;;
    esac
  done
  [[ -n "$bench" || -n "$OPT_SITE" ]] || fl_die "lease take needs --bench PATH or --site NAME." "Example: benchbar lease take --site qa1.localhost --for 20 --note 'running tests'"
  [[ -z "$bench" || -z "$OPT_SITE" ]] || fl_die "A lease is on a bench or on a site, not both." "A site of another bench: benchbar lease take --site NAME --bench-dir PATH"
  fl__lease_minutes_v mins "$mins"
  fl_bench_detect "${bench:-$OPT_BENCH_DIR}"
  fl_is_bench_dir "$FL_BENCH_DIR" || fl_die "${FL_BENCH_DIR} is not a Frappe bench." "Name a bench: benchbar lease take --bench PATH (benchbar list shows them)"
  case "$FL_BENCH_DIR" in *$'\t'*|*$'\n'*) fl_die "A bench path with a tab or a line break cannot be leased." ;; esac
  if [[ -n "$OPT_SITE" ]]; then
    kind="site"; site="$OPT_SITE"
    fl_site_name_ok "$site" || fl_die "Invalid site name: '${site}'." "Use lowercase letters, digits, '-' and '.' only."
    [[ -f "${FL_BENCH_DIR}/sites/${site}/site_config.json" ]] || fl_die "No site '${site}' in ${FL_BENCH_DIR}." "Sites: benchbar site list"
  else
    kind="bench"
  fi
  fl_lease_holder_v holder
  # an agent that did not name itself would be "agent", like every other one, and could use their leases
  if [[ -z "${BENCHBAR_CALLER:-}" ]] && fl_noninteractive; then
    FL_ERROR_ID="lease_caller_required"
    fl_die "A lease needs a holder name, and this run has none: every agent without BENCHBAR_CALLER would be called ${holder} and share the others' leases." \
      "Set BENCHBAR_CALLER to a name of its own (for example BENCHBAR_CALLER=claude-qa), then take the lease again."
  fi
  fl__lease_note_v note "$note"
  L_KIND="$kind"; L_BENCH="$FL_BENCH_DIR"; L_SITE="$site"
  fl__lease_what_v what
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would take a lease on ${what} for ${mins} minutes as ${holder}"
    return 0
  fi
  fl__lease_lock_or_die
  fl__lease_load
  # a bench lease covers every site of the bench, and a site lease sits under a bench lease: one holder at a time
  for line in ${FL_LEASE_LINES[@]+"${FL_LEASE_LINES[@]}"}; do
    fl__lease_split "$line"
    [[ "$L_BENCH" == "$FL_BENCH_DIR" ]] || continue
    if [[ "$kind" == "bench" || "$L_KIND" == "bench" || "$L_SITE" == "$site" ]]; then clash="$line"; break; fi
  done
  cnt="${#FL_LEASE_LINES[@]}"
  if [[ -z "$clash" && "$cnt" -ge "$FL_LEASE_MAX_ACTIVE" ]]; then full=1; fi
  if [[ -z "$clash" && "$full" == "0" ]]; then
    now="$FL_LEASE_NOW"
    exp=$((now + mins * 60))
    since="$(fl_iso_from_epoch "$now")"
    L_KIND="$kind"; L_BENCH="$FL_BENCH_DIR"; L_SITE="$site"
    fl__lease_new_id_v id
    if [[ -z "$id" ]]; then fl__lease_unlock; fl_die "Could not make a lease id." "Try again."; fi
    FL_LEASE_LINES+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$id" "$kind" "$FL_BENCH_DIR" "${site:--}" "$holder" "$since" "$now" "$(fl_iso_from_epoch "$exp")" "$exp" "$mins" "${note:--}")")
    fl__lease_write || { fl__lease_unlock; fl_die "Could not write ${FL_STATE_DIR}/leases.tsv." "Check that the state folder is writable."; }
  fi
  fl__lease_unlock
  if [[ -n "$clash" ]]; then
    fl__lease_split "$clash"
    fl__lease_what_v what
    clash_why="The ${what} is already leased by ${L_HOLDER} until ${L_EXP}${L_NOTE:+ (${L_NOTE})}."
    FL_ERROR_ID="lease_held"
    # the holder and the end, never the id: it is what lets a run change what the lease covers
    if [[ "$L_HOLDER" == "$holder" ]]; then
      fl_die "${clash_why} You already hold it." "Renew it: benchbar lease renew ID --for ${mins} (benchbar lease list shows the id of your leases)."
    fi
    fl_die "${clash_why}" "Wait until it ends, or ask ${L_HOLDER} to release it."
  fi
  [[ "$full" == "0" ]] || fl_die "There are ${FL_LEASE_MAX_ACTIVE} active leases already." "Release the ones you no longer need: benchbar lease list"
  L_ID="$id"; L_KIND="$kind"; L_BENCH="$FL_BENCH_DIR"; L_SITE="$site"; L_HOLDER="$holder"; L_NOTE="$note"
  L_SINCE="$since"; L_EXP="$(fl_iso_from_epoch "$exp")"; L_MINS="$mins"
  fl_changed lease "$id" "taken"
  fl_ok "lease ${id} taken on ${what} for ${mins} minutes (until ${L_EXP}), held by ${holder}"
  fl_note "Pass it to the commands that change this: --lease ${id}"
  fl_next_action "benchbar lease renew ${id} --for ${mins}" "Keep the lease while the work runs"
  fl_next_action "benchbar lease release ${id}" "Let go of it when the work is done"
  if [[ "${OPT_JSON:-0}" == "1" || "${FL_JSONL:-0}" == "1" ]]; then
    fl__lease_obj_v jobj 1 1
    fl_doc_emit 0 "$(printf '{"schema_version":%d,"cli_version":"%s","lease":%s}' "${FL_SCHEMA_VERSION:-1}" "${FL_VERSION:-0}" "$jobj")"
  fi
}

fl_lease_release() {
  local id="" line keep=() found="" what
  [[ "$#" -eq 1 ]] || fl_die "lease release takes one lease id." "Use: benchbar lease release ID"
  id="$1"
  fl__lease_id_check "$id"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then fl_info "dry-run: would release lease ${id}"; return 0; fi
  fl__lease_lock_or_die
  fl__lease_load
  for line in ${FL_LEASE_LINES[@]+"${FL_LEASE_LINES[@]}"}; do
    if [[ "${line%%$'\t'*}" == "$id" ]]; then found="$line"; else keep+=("$line"); fi
  done
  # a lease that is gone is released: expired and pruned leases end the same way
  FL_LEASE_LINES=(${keep[@]+"${keep[@]}"})
  fl__lease_write || { fl__lease_unlock; fl_die "Could not write ${FL_STATE_DIR}/leases.tsv." "Check that the state folder is writable."; }
  fl__lease_unlock
  if [[ -z "$found" ]]; then
    fl_ok "unchanged: lease ${id} is not active (it expired or was released)"
  else
    fl__lease_split "$found"; fl__lease_what_v what
    fl_changed lease "$id" "released"
    fl_ok "lease ${id} released: ${what}"
  fi
  if [[ "${OPT_JSON:-0}" == "1" || "${FL_JSONL:-0}" == "1" ]]; then
    fl_doc_emit 0 "$(printf '{"schema_version":%d,"cli_version":"%s","released":%s,"lease":%s}' "${FL_SCHEMA_VERSION:-1}" "${FL_VERSION:-0}" "$([[ -n "$found" ]] && printf true || printf false)" "$(fl_json_str "$id")")"
  fi
}

fl_lease_renew() {
  local id="" mins="" line keep=() found="" what exp jobj
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --for) [[ "$#" -ge 2 ]] || fl_die "--for needs a number of minutes."; mins="$2"; shift 2 ;;
      --for=*) mins="${1#*=}"; shift ;;
      -*) fl_die "Unknown argument for lease renew: $1" "Use: benchbar lease renew ID [--for MINUTES]" ;;
      *) [[ -z "$id" ]] || fl_die "lease renew takes one lease id." "Use: benchbar lease renew ID [--for MINUTES]"; id="$1"; shift ;;
    esac
  done
  [[ -n "$id" ]] || fl_die "lease renew needs a lease id." "Use: benchbar lease renew ID [--for MINUTES]"
  fl__lease_id_check "$id"
  [[ -z "$mins" ]] || fl__lease_minutes_v mins "$mins"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then fl_info "dry-run: would renew lease ${id}"; return 0; fi
  fl__lease_lock_or_die
  fl__lease_load
  for line in ${FL_LEASE_LINES[@]+"${FL_LEASE_LINES[@]}"}; do
    if [[ "${line%%$'\t'*}" == "$id" ]]; then found="$line"; else keep+=("$line"); fi
  done
  if [[ -z "$found" ]]; then
    fl__lease_write || true
    fl__lease_unlock
    FL_ERROR_ID="lease_unknown"
    fl_die "Lease ${id} is not active: it expired, or it was released." "Take a new one: benchbar lease take (--bench PATH | --site NAME)"
  fi
  fl__lease_split "$found"
  [[ -n "$mins" ]] || mins="$L_MINS"
  exp=$((FL_LEASE_NOW + mins * 60))
  L_MINS="$mins"; L_EE="$exp"; L_EXP="$(fl_iso_from_epoch "$exp")"
  keep+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$L_ID" "$L_KIND" "$L_BENCH" "${L_SITE:--}" "$L_HOLDER" "$L_SINCE" "$L_SE" "$L_EXP" "$L_EE" "$L_MINS" "${L_NOTE:--}")")
  FL_LEASE_LINES=("${keep[@]}")
  fl__lease_write || { fl__lease_unlock; fl_die "Could not write ${FL_STATE_DIR}/leases.tsv." "Check that the state folder is writable."; }
  fl__lease_unlock
  fl__lease_what_v what
  fl_changed lease "$id" "renewed"
  fl_ok "lease ${id} renewed: ${what} until ${L_EXP}"
  if [[ "${OPT_JSON:-0}" == "1" || "${FL_JSONL:-0}" == "1" ]]; then
    fl__lease_obj_v jobj 1 1
    fl_doc_emit 0 "$(printf '{"schema_version":%d,"cli_version":"%s","lease":%s}' "${FL_SCHEMA_VERSION:-1}" "${FL_VERSION:-0}" "$jobj")"
  fi
}

# lease list [--bench PATH]: the active leases, of every bench or of one. A lease's id is shown to its
# holder only (the holder is whoever BENCHBAR_CALLER names, or the login name); for anyone else it is null
# (the id is what a run passes to change what the lease covers).
fl_lease_list() {
  local bench="" line holder show mine out="" sep="" jobj rows=() target id_text
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --bench) [[ "$#" -ge 2 ]] || fl_die "--bench needs a path."; bench="$2"; shift 2 ;;
      --bench=*) bench="${1#*=}"; shift ;;
      *) fl_die "Unknown argument for lease list: $1" "Use: benchbar lease list [--bench PATH] [--json]" ;;
    esac
  done
  [[ -n "$bench" ]] || bench="$OPT_BENCH_DIR"
  if [[ -n "$bench" ]]; then fl_bench_detect "$bench"; bench="$FL_BENCH_DIR"; fi
  fl_lease_holder_v holder
  fl__lease_load
  rows=("Lease|Scope|Target|Holder|Until|Note")
  for line in ${FL_LEASE_LINES[@]+"${FL_LEASE_LINES[@]}"}; do
    fl__lease_split "$line"
    [[ -z "$bench" || "$L_BENCH" == "$bench" ]] || continue
    mine=0; [[ "$L_HOLDER" != "$holder" ]] || mine=1
    show="$mine"
    fl__lease_obj_v jobj "$show" "$mine"
    out="${out}${sep}${jobj}"; sep=","
    target="$L_BENCH"; [[ "$L_KIND" != "site" ]] || target="${L_SITE} of ${L_BENCH}"
    id_text="-"; [[ "$show" != "1" ]] || id_text="$L_ID"
    rows+=("${id_text}|${L_KIND}|${target}|${L_HOLDER}|${L_EXP}|${L_NOTE//|//}")
  done
  if [[ "${OPT_JSON:-0}" == "1" ]]; then
    printf '{"schema_version":%d,"cli_version":"%s","leases":[%s],"max_minutes":%d}\n' "${FL_SCHEMA_VERSION:-1}" "${FL_VERSION:-0}" "$out" "$FL_LEASE_MAX_MINUTES"
    return 0
  fi
  if [[ "${#rows[@]}" -le 1 ]]; then fl_info "no active leases"; return 0; fi
  fl_table "${rows[@]}"
  fl_note "Only the holder of a lease sees its id (the holder is BENCHBAR_CALLER; yours is ${holder})."
  return 0
}

# ---------------------------------------------------------------- the gate

# What a command that changes a bench must find free, by class:
#   W  the whole bench: a lease on it, or on any site of it, stops the command (restart, down, repair,
#      service, install, adopt, app add and update, lock apply, ports apply)
#   S  one site: a lease on the bench or on that site (site drop, site restore, pull, app install --site)
#   B  the bench itself: a lease on the bench, not one on a site (site add, site default)
# up is not gated (it starts, never interrupts), nor are the reads, backups, console, db, open and watch
# (maintainers/DECISIONS.md). A dry run is a read and passes.
FL_LS_CLASS=""
FL_LS_BENCHES=""
FL_LS_SITE=""
FL_LS_ALL=0

# fl_lease_snapdrop_site: the SITE of "site snapshot drop ..." (ARGS: snapshot drop ...): the first word after
# drop that is no option and no option's value, so "drop --prune SITE" and "drop SITE SNAPSHOT" name the same site
fl_lease_snapdrop_site() {
  local skip=0 i=0 a
  for a in ${ARGS[@]+"${ARGS[@]}"}; do
    i=$((i + 1)); [[ "$i" -gt 2 ]] || continue
    if [[ "$skip" == "1" ]]; then skip=0; continue; fi
    case "$a" in
      --keep) skip=1 ;;
      -*) ;;
      *) printf '%s' "$a"; return 0 ;;
    esac
  done
}

# fl__lease_scope: FL_LS_* for the command being run; returns 1 for a command that no lease stops
fl__lease_scope() {
  local a p as="" prev="" idx
  FL_LS_CLASS=""; FL_LS_BENCHES=""; FL_LS_SITE=""; FL_LS_ALL=0
  case "${COMMAND} ${ARGS[0]:-}" in
    "restart "*|"down "*|"fg "*|"repair "*|"service "*|"install "*|"app add"|"app update"|"lock apply") FL_LS_CLASS="W" ;;
    "uninstall-service "*) FL_LS_CLASS="W"; [[ " ${ARGS[*]:-} " != *" --all "* ]] || FL_LS_ALL=1 ;;
    "adopt "*) FL_LS_CLASS="W" ;;
    "site add"|"site default") FL_LS_CLASS="B" ;;
    "site drop"|"site restore") FL_LS_CLASS="S"; FL_LS_SITE="$(fl_site_arg_name)" ;;
    "site move")
      # the site, and both benches: the one it leaves and the one it goes to
      FL_LS_CLASS="S"; FL_LS_SITE="$(fl_site_arg_name)"
      fl_bench_detect "$OPT_BENCH_DIR"
      FL_LS_BENCHES="${FL_BENCH_DIR}"$'\n'
      for a in ${ARGS[@]+"${ARGS[@]}"}; do
        if [[ "$prev" == "--to-bench" ]]; then FL_LS_BENCHES="${FL_LS_BENCHES}$(fl_abs_path "$a")"$'\n'; fi
        case "$a" in --to-bench=*) FL_LS_BENCHES="${FL_LS_BENCHES}$(fl_abs_path "${a#*=}")"$'\n' ;; esac
        prev="$a"
      done
      return 0 ;;
    "site rollback") FL_LS_CLASS="S"; FL_LS_SITE="$(fl_site_arg_name)" ;;
    "site snapshot")
      # only drop changes what exists; taking a snapshot adds one and never interrupts
      [[ "${ARGS[1]:-}" == "drop" ]] || return 1
      # the site is the first word after drop that is no option: drop --prune SITE names it as well
      FL_LS_CLASS="S"; FL_LS_SITE="$(fl_lease_snapdrop_site)" ;;
    "app install")
      if [[ -n "$OPT_SITE" ]]; then FL_LS_CLASS="S"; FL_LS_SITE="$OPT_SITE"; else FL_LS_CLASS="W"; fi ;;
    "pull "*)
      FL_LS_CLASS="S"
      for a in ${ARGS[@]+"${ARGS[@]}"}; do
        if [[ "$prev" == "--as" ]]; then as="$a"; fi
        case "$a" in --as=*) as="${a#*=}" ;; esac
        prev="$a"
      done
      if [[ -z "$as" && "${ARGS[0]:-}" == *:* ]]; then as="$(printf '%s.local' "${ARGS[0]##*:}" | tr '[:upper:]' '[:lower:]')"; fi
      FL_LS_SITE="$as" ;;
    "run "*)
      # the bench command of benchbar run (after its "--"): the reads of the allow list pass, a change is gated
      case "${ARGS[${FL_RUN_SEP:-0}]:-}" in doctor|list-apps|version|"") return 1 ;; esac
      if [[ -n "$OPT_SITE" ]]; then FL_LS_CLASS="S"; FL_LS_SITE="$OPT_SITE"; else FL_LS_CLASS="W"; fi ;;
    "ports apply"|"ports setup")
      FL_LS_CLASS="W"
      idx=1; [[ "${ARGS[0]}" != "apply" ]] || idx=2
      for ((p = idx; p < ${#ARGS[@]}; p++)); do
        [[ "${ARGS[$p]}" != -* ]] || continue
        FL_LS_BENCHES="${FL_LS_BENCHES}$(fl_abs_path "${ARGS[$p]}")"$'\n'
      done
      return 0 ;;
    *) return 1 ;;
  esac
  if [[ "$FL_LS_ALL" != "1" && -z "$FL_LS_BENCHES" ]]; then
    if [[ "$COMMAND" == "adopt" && -n "${ARGS[0]:-}" ]]; then fl_bench_detect "${ARGS[0]}"; else fl_bench_detect "$OPT_BENCH_DIR"; fi
    FL_LS_BENCHES="$FL_BENCH_DIR"
  fi
  return 0
}

# fl__lease_covers: the lease in L_* is in the way of the command described by FL_LS_*
fl__lease_covers() {
  local b hit=0
  if [[ "$FL_LS_ALL" == "1" ]]; then hit=1
  else
    while IFS= read -r b; do
      if [[ -n "$b" && "$b" == "$L_BENCH" ]]; then hit=1; break; fi
    done <<<"$FL_LS_BENCHES"
  fi
  [[ "$hit" == "1" ]] || return 1
  case "$FL_LS_CLASS" in
    B) [[ "$L_KIND" == "bench" ]] ;;
    S) [[ "$L_KIND" == "bench" || ( -n "$FL_LS_SITE" && "$L_SITE" == "$FL_LS_SITE" ) ]] ;;
    *) return 0 ;;
  esac
}

# fl__lease_refusal_v VAR: one sentence per active lease that stands in front of the command FL_LS_* describes
# (not those whose id was passed with --lease), "" for none. The gate dies with it; a plan (site move) reports it.
fl__lease_refusal_v() {
  local __r="" line what
  fl__lease_load
  for line in ${FL_LEASE_LINES[@]+"${FL_LEASE_LINES[@]}"}; do
    fl__lease_split "$line"
    fl__lease_covers || continue
    [[ " ${OPT_LEASES} " != *" ${L_ID} "* ]] || continue
    fl__lease_what_v what
    __r="${__r}${__r:+ }The ${what} is leased by ${L_HOLDER} until ${L_EXP}${L_NOTE:+ (${L_NOTE})}."
  done
  printf -v "$1" '%s' "$__r"
}

# fl_lease_gate: refuses, before the run lock and any change, a command that a lease stands in front of,
# naming the holder and the end of the lease. --lease ID (repeatable) lets it through for the lease with
# that id; --break-lease lets a person through. With no leases it reads nothing.
fl_lease_gate() {
  local f="${FL_STATE_DIR}/leases.tsv" refused="" given id unknown=""
  [[ "${FL_DRY_RUN:-0}" != "1" && -s "$f" ]] || return 0
  for given in $OPT_LEASES; do fl__lease_id_check "$given"; done
  fl__lease_scope || return 0
  fl__lease_refusal_v refused
  [[ -n "$refused" ]] || return 0
  if [[ "${OPT_BREAK_LEASE:-0}" == "1" ]]; then
    if fl_lease_person_ok; then
      fl_warn "--break-lease: going ahead although ${refused}"
      return 0
    fi
    FL_ERROR_ID="lease_break_refused"
    FL_EXIT2_NOT_PASSWORD=1
    fl_die "--break-lease is a person's decision: it is refused for agents, mcp and a run without a person at a terminal. ${refused}" \
      "Wait until the lease ends, or ask its holder to release it. A person runs the command in a terminal with --break-lease." 2
  fi
  for id in $OPT_LEASES; do
    fl__lease_known "$id" || unknown="${unknown}${unknown:+, }${id}"
  done
  FL_ERROR_ID="lease_held"
  fl_die "${refused}${unknown:+ The lease id you passed (${unknown}) is not active: it expired or was released.} Nothing was changed." \
    "Wait until it ends or ask the holder to release it; the holder passes --lease ID. A person at a terminal can pass --break-lease."
}

# fl__lease_known ID: ID is one of the active leases (FL_LEASE_LINES is loaded)
fl__lease_known() {
  local line
  for line in ${FL_LEASE_LINES[@]+"${FL_LEASE_LINES[@]}"}; do
    [[ "${line%%$'\t'*}" != "$1" ]] || return 0
  done
  return 1
}
