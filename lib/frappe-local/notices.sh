#!/usr/bin/env bash
#
# notices.sh: one time notices after an update, for the defaults that changed.
#
# Every new default of a release has a switch back, an upgrade note and a
# notice that shows once after the update (issue 188). The table below is
# the one list: the terminal prints the notices once, `status --json` carries
# them as notices[] until they are dismissed, and `benchbar notices` lists and
# dismisses them (the Mac app shows them as a banner, its Dismiss runs
# `benchbar notices --dismiss ID`).
#
# State (the global state file, three keys):
#   LAST_VERSION     the version of the CLI that ran last
#   NOTICES          the notices that are active, space separated ids
#   NOTICES_SHOWN    the ids the terminal printed already
# A run whose version differs from LAST_VERSION, coming from below a notice's
# SINCE, makes that notice active. Versions are compared without their
# prerelease part (0.9.0-rc.1 counts as 0.9.0 for SINCE), so an update from
# 0.8.3 to an rc activates the notices and the final release adds nothing; a
# recorded version that is newer than the running one (two CLIs of different
# versions share the state folder) is left as it is: no write, no notice. A state folder that has content but no
# LAST_VERSION is an install of 0.8.3 or older (they never wrote one); an empty
# or missing one is a fresh install, which gets no notice. Any command records
# the change (so the app's first status call counts), only a human command
# prints. The common path, the version has not changed, reads the state file
# once and starts no process.
#
# Records are lines with fields separated by `~` (no field holds one):
#   notice~ID~SINCE~TITLE~TEXT~SWITCH_BACK~DOC
# DOC is a path of the documentation site.

read -r -d '' FL_NOTICE_TABLE <<'TABLE' || true
notice~listen-local~0.9.0~The bench now listens on this computer only~The web server and socketio of a bench now accept connections from this computer only (127.0.0.1). Before, they listened on every interface, so anyone on your Wi-Fi could reach the dev server and its debugger. A bench that is running keeps listening on every interface until its service files are rewritten: run `benchbar repair` once per bench (`benchbar doctor` shows `Procfile.lean is outdated`). Repair may restart a running bench itself; if it did not, run `benchbar restart`. If you open the bench from a phone or another PC by this computer's address, run `benchbar listen all` to switch back; `benchbar listen local` undoes it. On Windows, http://SITE.localhost:8000 keeps working.~benchbar listen all~/whats-new/#the-bench-listens-on-this-computer-only
notice~unknown-flags~0.9.0~An option a command does not take is now an error~An option a command does not take now stops the run with exit 64 and changes nothing. Before, it was ignored and the command ran: `benchbar repair --dry-rn --yes` ran for real. If a script of yours passes options a command never read, remove them. To go back for now, set BENCHBAR_LENIENT_FLAGS=1: an unknown option is then a warning on stderr and the command runs, as before. A flag that needs a value and has none stays an error.~BENCHBAR_LENIENT_FLAGS=1~/whats-new/#unknown-options-are-errors
notice~pull-neutralise~0.9.0~benchbar pull now neutralises the copy~benchbar pull now neutralises the copy: integrations are switched off and stored passwords are deleted, except the Administrator login. A copy you already pulled keeps what it has until you pull again with --replace. Add --keep-secrets to keep production's integrations and passwords in the copy, as before.~benchbar pull --keep-secrets~/whats-new/#pull-neutralises-the-copy
TABLE

# the state of this run, read once by fl_notices_load
FL_NOTICES_LAST=""
FL_NOTICES_ACTIVE=""
FL_NOTICES_SHOWN=""
FL_NOTICES_LOADED=0
# this run began with no state at all: a fresh install, recorded at its end
FL_NOTICES_FRESH=0

# fl_notices_load: LAST_VERSION, NOTICES and NOTICES_SHOWN of the state file,
# in one pass of the bash read builtin (no process)
fl_notices_load() {
  local line v
  FL_NOTICES_LAST=""; FL_NOTICES_ACTIVE=""; FL_NOTICES_SHOWN=""; FL_NOTICES_LOADED=1
  [[ -f "$FL_STATE_FILE" && -r "$FL_STATE_FILE" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      LAST_VERSION=*) fl_kv_decode_v v "${line#LAST_VERSION=}"; FL_NOTICES_LAST="$v" ;;
      NOTICES=*) fl_kv_decode_v v "${line#NOTICES=}"; FL_NOTICES_ACTIVE="$v" ;;
      NOTICES_SHOWN=*) fl_kv_decode_v v "${line#NOTICES_SHOWN=}"; FL_NOTICES_SHOWN="$v" ;;
    esac
  done <"$FL_STATE_FILE"
  return 0
}

# fl_notice_attr_v VAR ID FIELD: since, title, text, switch or doc of a notice
fl_notice_attr_v() {
  local __k __i __s __t __x __w __d __r=""
  while IFS='~' read -r __k __i __s __t __x __w __d; do
    [[ "$__k" == notice && "$__i" == "$2" ]] || continue
    case "$3" in since) __r="$__s" ;; title) __r="$__t" ;; text) __r="$__x" ;; switch) __r="$__w" ;; doc) __r="$__d" ;; esac
    break
  done <<<"$FL_NOTICE_TABLE"
  printf -v "$1" '%s' "$__r"
}

# fl_notice_known ID
fl_notice_known() {
  local k i
  while IFS='~' read -r k i _; do
    [[ "$k" == notice && "$i" == "$1" ]] && return 0
  done <<<"$FL_NOTICE_TABLE"
  return 1
}

# fl_notice_has LIST ID: ID is a word of the space separated LIST
fl_notice_has() { [[ " $1 " == *" $2 "* ]]; }

# fl_notice_without_v VAR LIST ID: LIST without the word ID
fl_notice_without_v() {
  local __w __r=""
  for __w in $2; do [[ "$__w" == "$3" ]] || __r="${__r}${__r:+ }${__w}"; done
  printf -v "$1" '%s' "$__r"
}

# fl_notices_since_lt FROM SINCE: the version FROM came from is below SINCE,
# without the prerelease part of either (selfupdate.sh's fl_version_lt, which
# is the one that wins in every start, orders 0.9.0-rc.1 below 0.9.0: not what
# a SINCE test wants)
fl_notices_since_lt() {
  local a="${1#v}" b="${2#v}"
  fl_version_lt "${a%%[-+]*}" "${b%%[-+]*}"
}

# fl_notices_state_exists: the state folder holds something from an earlier
# run (a state file with content, the list of registered benches or a bench's
# own file), so an empty LAST_VERSION means an install of 0.8.3 or older, not
# a fresh one
fl_notices_state_exists() {
  [[ -s "$FL_STATE_FILE" || -e "${FL_STATE_DIR}/registered-benches.txt" || -d "${FL_STATE_DIR}/benches" ]]
}

# fl_notices_sync: records a change of version and activates the notices whose
# SINCE is above the version this one came from. Quiet, never fails the
# command, no process when the version has not changed. Writes nothing in a
# dry run, and nothing where the state folder cannot be written.
fl_notices_sync() {
  [[ "${FL_DRY_RUN:-0}" != "1" ]] || return 0
  fl_notices_load
  [[ "$FL_NOTICES_LAST" != "${FL_VERSION:-0}" ]] || return 0
  local prev="$FL_NOTICES_LAST" k i s active="$FL_NOTICES_ACTIVE"
  # recorded by a newer CLI (the app's, say, next to a Homebrew one): nothing to record or activate
  if [[ -n "$prev" ]] && fl_version_lt "${FL_VERSION:-0}" "$prev"; then return 0; fi
  if [[ -z "$prev" ]]; then
    # no version recorded: a fresh install has nothing to be told. It writes
    # nothing now (a refusal or a read leaves no state behind): fl_notices_on_exit
    # records the version when the run itself made the state
    if fl_notices_state_exists; then prev="0.0.0"; else FL_NOTICES_FRESH=1; return 0; fi
  fi
  if [[ -d "$FL_STATE_DIR" ]]; then [[ -w "$FL_STATE_DIR" ]] || return 0; fi
  while IFS='~' read -r k i s _; do
    [[ "$k" == notice ]] || continue
    if fl_notices_since_lt "$prev" "$s" && ! fl_notice_has "$active" "$i" && ! fl_notice_has "$FL_NOTICES_SHOWN" "$i"; then
      active="${active}${active:+ }${i}"
    fi
  done <<<"$FL_NOTICE_TABLE"
  # kept in memory for this run (status --json and the print read them); written by
  # fl_notices_on_exit only when the run ends well, so a refused command writes nothing
  FL_NOTICES_PENDING=1
  FL_NOTICES_LAST="${FL_VERSION:-0}"; FL_NOTICES_ACTIVE="$active"
  return 0
}

# fl_notices_on_exit: a run that began with no state and made state of its
# own (install, register, adopt) was the first run of a fresh install: it
# records the version, so the next run is not taken for an update from 0.8.
# Whatever the exit code: install writes state (PIPX_BIN_DIR, BENCH_BIN,
# RC_FILE) well before it can fail, and a state folder with content and no
# LAST_VERSION reads as 0.8.3. A run that made no state (a refusal, a read)
# records nothing. Called by the exit trap.
fl_notices_on_exit() {
  # an update seen at the start (fl_notices_sync): its notices and version, once the run ended well
  if [[ "${FL_NOTICES_PENDING:-0}" == "1" && "${1:-1}" == "0" && "${FL_DRY_RUN:-0}" != "1" ]]; then
    FL_NOTICES_PENDING=0
    # the notices go first: a run that stops between the two writes shows them twice at worst
    fl_state_set NOTICES "$FL_NOTICES_ACTIVE" 2>/dev/null || return 0
    fl_state_set LAST_VERSION "$FL_NOTICES_LAST" 2>/dev/null || true
    return 0
  fi
  [[ "$FL_NOTICES_FRESH" == "1" && "${FL_DRY_RUN:-0}" != "1" ]] || return 0
  FL_NOTICES_FRESH=0
  fl_notices_state_exists || return 0
  [[ -w "$FL_STATE_DIR" ]] || return 0
  fl_state_set LAST_VERSION "${FL_VERSION:-0}" 2>/dev/null || true
  return 0
}

# fl_notices_print_once: the active notices the terminal has not printed, on
# stderr, then recorded as shown. Called for a human command only.
fl_notices_print_once() {
  [[ "${FL_DRY_RUN:-0}" != "1" ]] || return 0
  # a terminal only: a pipe or a file (a script's 2>log, cron) must not use up the one print,
  # so it is not recorded as shown and the next run in a terminal prints it
  [[ -t 2 ]] || return 0
  local id title text sw doc fresh="" shown="$FL_NOTICES_SHOWN" first=1
  for id in $FL_NOTICES_ACTIVE; do
    fl_notice_has "$shown" "$id" && continue
    fl_notice_known "$id" || continue
    if [[ "$first" == 1 ]]; then
      printf '\nBenchBar 0.9.0 changes some defaults. Each has a way back. This is shown once.\n' >&2
      first=0
    fi
    fl_notice_attr_v title "$id" title
    fl_notice_attr_v text "$id" text
    fl_notice_attr_v sw "$id" switch
    fl_notice_attr_v doc "$id" doc
    printf '\n  %s\n    %s\n    Switch back: %s\n    More: %s\n' "$title" "$text" "$sw" "$(fl_docs_url "$doc")" >&2
    fresh="${fresh}${fresh:+ }${id}"
  done
  [[ -n "$fresh" ]] || return 0
  printf '\n  List them again: benchbar notices. Hide them in the BenchBar app too: benchbar notices --all\n\n' >&2
  fl_state_set NOTICES_SHOWN "${shown}${shown:+ }${fresh}" || true
  FL_NOTICES_SHOWN="${shown}${shown:+ }${fresh}"
  return 0
}

# fl_notices_run: the dispatcher's one call. Records the version change, and
# prints for a person (stderr is a terminal): not --json, --jsonl or --for-agent, not
# BENCHBAR_NONINTERACTIVE (so not benchbar mcp either), and not for the
# commands whose output a script reads or that name the notices themselves.
fl_notices_run() {
  fl_notices_sync || true
  [[ "${OPT_JSON:-0}" != "1" && "${OPT_JSONL:-0}" != "1" && "${OPT_FOR_AGENT:-0}" != "1" ]] || return 0
  ! fl_noninteractive || return 0
  case "$COMMAND" in path|where|commands|help|mcp|notices|docs|mariadb-password) return 0 ;; esac
  [[ -n "$FL_NOTICES_ACTIVE" ]] || return 0
  fl_notices_print_once || true
  return 0
}

# fl_notices_json_v VAR [ALL]: the array of notices that are active (every
# notice of the table with ALL=1), each {id, title, text, switch_back, doc,
# since}. The doc is a full URL. Reads the state file once when this run has
# not (status runs the sync first, so this is a read of what it loaded).
fl_notices_json_v() {
  local __id __out="" __sep="" j_t j_x j_w j_d j_s __ids="" __k __i
  [[ "$FL_NOTICES_LOADED" == "1" ]] || fl_notices_load
  if [[ "${2:-0}" == "1" ]]; then
    while IFS='~' read -r __k __i _; do [[ "$__k" == notice ]] && __ids="${__ids}${__ids:+ }${__i}"; done <<<"$FL_NOTICE_TABLE"
  else
    __ids="$FL_NOTICES_ACTIVE"
  fi
  for __id in $__ids; do
    fl_notice_known "$__id" || continue
    fl_notice_attr_v j_t "$__id" title; fl_notice_attr_v j_x "$__id" text
    fl_notice_attr_v j_w "$__id" switch; fl_notice_attr_v j_d "$__id" doc; fl_notice_attr_v j_s "$__id" since
    __out="${__out}${__sep}{\"id\":$(fl_json_str "$__id"),\"title\":$(fl_json_str "$j_t"),\"text\":$(fl_json_str "$j_x"),\"switch_back\":$(fl_json_str "$j_w"),\"doc\":$(fl_json_str "$(fl_docs_url "$j_d")"),\"since\":$(fl_json_str "$j_s")}"
    __sep=","
  done
  printf -v "$1" '[%s]' "$__out"
}

# benchbar notices [--json] [--dismiss ID | --all]: lists the active notices,
# or dismisses one (or every one). A dismissal is benchbar's own note, like
# doctor --ack: no lock of the run, nothing else changes. An id that is
# known but not active is already dismissed: unchanged, exit 0.
fl_cmd_notices() {
  local a prev="" dismiss="" all=0 id rest j
  for a in "$@"; do
    if [[ "$prev" == "--dismiss" ]]; then dismiss="$a"; prev=""; continue; fi
    case "$a" in
      --dismiss) prev="--dismiss" ;;
      --dismiss=*) dismiss="${a#*=}" ;;
      --all) all=1 ;;
      --json) ;;
      *) fl_die "Unknown option for notices: $a" "Use: benchbar notices [--json] [--dismiss ID | --all]" ;;
    esac
  done
  [[ "$prev" != "--dismiss" ]] || fl_die "notices --dismiss needs a notice id." "Example: benchbar notices --dismiss listen-local"
  [[ "$all" == 0 || -z "$dismiss" ]] || fl_die "Use --dismiss ID or --all, not both." "benchbar notices --all"
  if [[ -n "$dismiss" ]] && ! fl_notice_known "$dismiss"; then
    local names=""
    while IFS='~' read -r a id _; do [[ "$a" == notice ]] && names="${names}${names:+, }${id}"; done <<<"$FL_NOTICE_TABLE"
    fl_die "Unknown notice: ${dismiss}" "Ids: ${names}"
  fi
  # an update seen at the start of this run is in memory until the run ends (fl_notices_on_exit)
  [[ "${FL_NOTICES_PENDING:-0}" == "1" ]] || fl_notices_load
  if [[ "$all" == 1 ]]; then
    [[ -z "$FL_NOTICES_ACTIVE" ]] || fl_state_set NOTICES ""
    FL_NOTICES_ACTIVE=""
  elif [[ -n "$dismiss" ]]; then
    if fl_notice_has "$FL_NOTICES_ACTIVE" "$dismiss"; then
      fl_notice_without_v rest "$FL_NOTICES_ACTIVE" "$dismiss"
      fl_state_set NOTICES "$rest"
      FL_NOTICES_ACTIVE="$rest"
    fi
  fi
  fl_notices_json_v j
  if [[ "${OPT_JSON:-0}" == "1" ]]; then
    printf '{"schema_version":%d,"cli_version":"%s","notices":%s}\n' "${FL_SCHEMA_VERSION:-1}" "${FL_VERSION:-0}" "$j"
    return 0
  fi
  if [[ "$all" == 1 || -n "$dismiss" ]]; then fl_ok "notices dismissed: ${dismiss:-all}"; fi
  if [[ -z "$FL_NOTICES_ACTIVE" ]]; then
    fl_info "No notices. Each default that changed in 0.9.0 and its way back: $(fl_docs_url /whats-new/)"
    return 0
  fi
  local title sw d
  for id in $FL_NOTICES_ACTIVE; do
    fl_notice_attr_v title "$id" title; fl_notice_attr_v sw "$id" switch; fl_notice_attr_v d "$id" doc
    printf '%s: %s\n  switch back: %s\n  more: %s\n' "$id" "$title" "$sw" "$(fl_docs_url "$d")"
  done
  fl_note "Dismiss one: benchbar notices --dismiss ID. All: benchbar notices --all"
}
