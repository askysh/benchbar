#!/usr/bin/env bash
#
# labs.sh: Labs, the experiments that are off until a person turns one on.
# One global state key, LABS (a space separated list of lab names), owned by
# `benchbar labs`; the app and the MCP server only read it. BENCHBAR_LABS=a,b
# in the environment replaces it (tests and CI). A lab gates the top level
# commands named in its row: while it is off they do not appear in --help or
# `commands --json`, and running one is refused with exit 2.
#
# Records are lines with fields separated by `~` (no field holds one):
#   lab~NAME~TITLE~DESCRIPTION~WARNING~SINCE~COMMANDS
# COMMANDS is a comma separated list of command names, may be empty, and may
# name commands that do not exist yet.

read -r -d '' FL_LAB_TABLE <<'TABLE' || true
lab~lan-rooms~Share with people on the same Wi-Fi~Open a room so colleagues on the office network can browse a hardened copy of a site as a seat you pick.~Installs a pf firewall anchor with sudo and runs a gateway on port 8443. A share stays up until you stop it.~0.9.0~share,lan-guard
lab~quick-switch~Quick Switch panel~A panel on a global keyboard shortcut to open a site as any pinned user.~Registers a system wide hotkey while the app runs.~0.9.0~
TABLE

fl_lab_table() { printf '%s\n' "$FL_LAB_TABLE"; }

# fl_lab_names_v VAR: every known lab name, space separated
fl_lab_names_v() {
  local __l __k __r=""
  while IFS='~' read -r __l __k _; do
    [[ "$__l" == lab ]] && __r="${__r}${__r:+ }${__k}"
  done < <(fl_lab_table)
  printf -v "$1" '%s' "$__r"
}

# fl_lab_known NAME
fl_lab_known() {
  local k n
  while IFS='~' read -r k n _; do
    [[ "$k" == lab && "$n" == "$1" ]] && return 0
  done < <(fl_lab_table)
  return 1
}

# fl_lab_attr_v VAR NAME FIELD: title, description, warning, since or commands of a lab
fl_lab_attr_v() {
  local __k __n __t __d __w __s __c __r=""
  while IFS='~' read -r __k __n __t __d __w __s __c; do
    [[ "$__k" == lab && "$__n" == "$2" ]] || continue
    case "$3" in title) __r="$__t" ;; description) __r="$__d" ;; warning) __r="$__w" ;; since) __r="$__s" ;; commands) __r="$__c" ;; esac
    break
  done < <(fl_lab_table)
  printf -v "$1" '%s' "$__r"
}

# fl_lab_list_v VAR: the enabled lab names in force, space separated: the
# BENCHBAR_LABS override when it is set, else the LABS key of the state file
fl_lab_list_v() {
  local __v
  if [[ -n "${BENCHBAR_LABS+x}" ]]; then __v="${BENCHBAR_LABS//,/ }"; else __v="$(fl_state_get LABS 2>/dev/null || true)"; fi
  printf -v "$1" '%s' "$__v"
}

# fl_lab_on NAME: true when the lab is known and on
fl_lab_on() {
  local list n
  fl_lab_known "$1" || return 1
  fl_lab_list_v list
  for n in $list; do [[ "$n" == "$1" ]] && return 0; done
  return 1
}

# fl_lab_enabled_v VAR: known labs that are on, space separated
fl_lab_enabled_v() {
  local __all __n __r=""
  fl_lab_names_v __all
  for __n in $__all; do fl_lab_on "$__n" && __r="${__r}${__r:+ }${__n}"; done
  printf -v "$1" '%s' "$__r"
}

# fl_lab_set NAME 0|1: writes the LABS key (the state file, never the override)
fl_lab_set() {
  local cur n out=""
  cur="$(fl_state_get LABS 2>/dev/null || true)"
  for n in $cur; do [[ "$n" == "$1" ]] || out="${out}${out:+ }${n}"; done
  [[ "$2" != 1 ]] || out="${out}${out:+ }${1}"
  fl_state_set LABS "$out"
}

# fl_lab_of_cmd CMD: the lab that gates the top level command CMD, or nothing
fl_lab_of_cmd() {
  local k n c cmds x
  while IFS='~' read -r k n _ _ _ _ c; do
    [[ "$k" == lab ]] || continue
    IFS=',' read -r -a cmds <<<"$c"
    for x in ${cmds[@]+"${cmds[@]}"}; do
      [[ "$x" == "$1" ]] && { printf '%s' "$n"; return 0; }
    done
  done < <(fl_lab_table)
  return 0
}

# fl_lab_hidden_v VAR: the commands of every lab that is off, space separated
fl_lab_hidden_v() {
  local __k __n __c __r=""
  while IFS='~' read -r __k __n _ _ _ _ __c; do
    [[ "$__k" == lab && -n "$__c" ]] || continue
    fl_lab_on "$__n" || __r="${__r}${__r:+ }${__c//,/ }"
  done < <(fl_lab_table)
  printf -v "$1" '%s' "$__r"
}

# fl_lab_require NAME [CMD]: refuses (exit 2) while the lab is off
fl_lab_require() {
  fl_lab_on "$1" && return 0
  FL_EXIT2_NOT_PASSWORD=1
  fl_die "benchbar ${2:-${COMMAND:-this command}} is an experiment and it is off." "Turn it on: benchbar labs on $1" 2
}

# fl_lab_gate KEY: the dispatcher's one check; KEY is a command or a table key
fl_lab_gate() {
  local cmd="${1%% *}" lab
  [[ -n "$cmd" ]] || return 0
  lab="$(fl_lab_of_cmd "$cmd")"
  [[ -z "$lab" ]] || fl_lab_require "$lab" "$cmd"
}

# fl_lab_usage_filter: the global help on stdin without the blocks (an entry
# at two spaces and its indented lines) of commands whose lab is off
fl_lab_usage_filter() {
  local hidden
  fl_lab_hidden_v hidden
  if [[ -z "$hidden" ]]; then cat; return 0; fi
  awk -v h=" ${hidden} " '
    /^  [a-z]/ { skip = (index(h, " " $1 " ") > 0) }
    /^[^ ]/ || /^$/ { skip = 0 }
    !skip { print }'
}

# fl_lab_cleanup NAME: what turning the lab off must undo; a problem is a
# warning, the flag turns off anyway
fl_lab_cleanup() {
  case "$1" in
    lan-rooms)
      # the share feature lives in its own change: nothing to undo without it
      if declare -F fl_lab_off_lan_rooms >/dev/null; then
        fl_lab_off_lan_rooms || fl_warn "Could not stop everything lan-rooms started; check it with: benchbar share status"
      fi ;;
    quick-switch) ;;
  esac
  return 0
}

# fl_labs_json: the document of `labs list --json`
fl_labs_json() {
  local k n t d w s c sep="" out="" en cmds x csep arr
  while IFS='~' read -r k n t d w s c; do
    [[ "$k" == lab ]] || continue
    fl_lab_on "$n" && en=true || en=false
    cmds=""; csep=""
    IFS=',' read -r -a arr <<<"$c"
    for x in ${arr[@]+"${arr[@]}"}; do cmds="${cmds}${csep}$(fl_json_str "$x")"; csep=","; done
    out="${out}${sep}{\"name\":$(fl_json_str "$n"),\"title\":$(fl_json_str "$t"),\"description\":$(fl_json_str "$d"),\"warning\":$(fl_json_str "$w"),\"since\":$(fl_json_str "$s"),\"enabled\":${en},\"commands\":[${cmds}]}"
    sep=","
  done < <(fl_lab_table)
  printf '{"schema_version":%d,"labs":[%s]}\n' "${FL_SCHEMA_VERSION:-1}" "$out"
}

# fl_lab_enabled_json_v VAR: ["a","b"] of the enabled labs
fl_lab_enabled_json_v() {
  local __e __n __r="" __s=""
  fl_lab_enabled_v __e
  for __n in $__e; do __r="${__r}${__s}$(fl_json_str "$__n")"; __s=","; done
  printf -v "$1" '[%s]' "$__r"
}

# labs [list] | on NAME | off NAME | status NAME. on and off change benchbar's
# state only. on is a person's decision: refused when nothing can ask
# (BENCHBAR_NONINTERACTIVE=1, so also --for-agent and benchbar mcp). off is
# always allowed and runs the lab's cleanup. status exits 1 for off.
fl_cmd_labs() {
  local action="list" name="" a n state on_now=false t w en
  if [[ "${1:-}" == list || "${1:-}" == on || "${1:-}" == off || "${1:-}" == status ]]; then action="$1"; shift; fi
  for a in "$@"; do
    case "$a" in
      -*) fl_die "Unknown option for labs: $a" "Use: benchbar labs [list] | on NAME | off NAME | status NAME [--yes] [--json]" ;;
      *) [[ -n "$name" ]] || name="$a" ;;
    esac
  done
  if [[ "$action" == list ]]; then
    if [[ "${OPT_JSON:-0}" == "1" ]]; then fl_labs_json; return 0; fi
    local rows=("Lab|State|What it is") all
    fl_lab_names_v all
    for n in $all; do
      fl_lab_on "$n" && state=on || state=off
      fl_lab_attr_v t "$n" title
      rows+=("${n}|${state}|${t}")
    done
    fl_table "${rows[@]}"
    fl_note "Turn one on in a terminal: benchbar labs on NAME"
    return 0
  fi
  fl_lab_names_v n
  [[ -n "$name" ]] || fl_die "benchbar labs ${action} needs a lab name." "Names: ${n}. Example: benchbar labs ${action} quick-switch"
  fl_lab_known "$name" || fl_die "Unknown lab: ${name}" "Names: ${n}"
  fl_lab_on "$name" && on_now=true
  if [[ "$action" == status ]]; then
    if [[ "${OPT_JSON:-0}" == "1" ]]; then
      printf '{"schema_version":%d,"name":%s,"enabled":%s}\n' "${FL_SCHEMA_VERSION:-1}" "$(fl_json_str "$name")" "$on_now"
    else
      fl_ok "${name}: $([[ "$on_now" == true ]] && printf on || printf off)"
    fi
    [[ "$on_now" == true ]]
    return $?
  fi
  if [[ "$action" == on ]]; then
    if fl_noninteractive; then
      FL_EXIT2_NOT_PASSWORD=1
      fl_die "turning on an experiment is a person's decision" "Run it in a terminal: benchbar labs on ${name}" 2
    fi
    if [[ "$on_now" != true && "${FL_DRY_RUN:-0}" != "1" ]]; then
      fl_lab_attr_v w "$name" warning
      fl_lab_attr_v t "$name" title
      fl_info "${t} is an experiment. ${w}"
      fl_confirm "Turn on ${name}?" || fl_die "${name} stays off." "Run again and answer yes, or pass --yes"
    fi
    if [[ "$on_now" == true ]]; then fl_ok "unchanged: ${name} is already on"
    elif [[ "${FL_DRY_RUN:-0}" == "1" ]]; then fl_info "dry-run: would turn on ${name} (benchbar state only)"
    else
      fl_lab_set "$name" 1
      fl_changed lab "$name" "turned on"
      fl_ok "${name} is on (benchbar state only)"
      fl_next_action "benchbar labs off ${name}" "Turn it off again"
    fi
  else
    if [[ "$on_now" != true ]]; then fl_ok "unchanged: ${name} is already off"
    elif [[ "${FL_DRY_RUN:-0}" == "1" ]]; then fl_info "dry-run: would turn off ${name}"
    else
      fl_lab_cleanup "$name"
      fl_lab_set "$name" 0
      fl_changed lab "$name" "turned off"
      fl_ok "${name} is off"
      fl_next_action "benchbar labs on ${name}" "Turn it back on, in a terminal"
    fi
  fi
  fl_lab_on "$name" && en=true || en=false
  if [[ -n "${BENCHBAR_LABS+x}" && "${FL_DRY_RUN:-0}" != "1" ]]; then fl_info "BENCHBAR_LABS is set and overrides the saved list."; fi
  if [[ "${OPT_JSON:-0}" == "1" || "${FL_JSONL:-0}" == "1" ]]; then
    fl_doc_emit 0 "$(printf '{"schema_version":%d,"cli_version":"%s","lab":%s,"enabled":%s}' "${FL_SCHEMA_VERSION:-1}" "${FL_VERSION:-0}" "$(fl_json_str "$name")" "$en")"
  fi
}
