#!/usr/bin/env bash
#
# help.sh: `benchbar COMMAND --help` and the global help (`benchbar --help`), both from the commands table
# (lib/frappe-local/commands.sh): fl_cmd_help, fl_usage_text, and the wrap they use. A file of its own, read when a
# help prints (fl_cmd_help and usage() in commands.sh source it), so that no start parses it, and no start reads
# the HELP block that fl_usage_text reads (#371).

# fl_wrap_v VAR WIDTH FIRST REST TEXT: TEXT in lines of at most WIDTH characters (a word longer than that stands
# alone, unless it lists alternatives with |: it breaks after one). The first line starts with FIRST, the others with REST;
# the lines are joined by newlines, the last has none.
fl_wrap_v() {
  local __var="$1" __width="$2" __line="$3" __rest="$4" __out="" __word __fresh=1 __glue __piece __rem
  local __words=() __pieces=()
  read -ra __words <<<"$5" || true
  for __word in ${__words[@]+"${__words[@]}"}; do
    __pieces=("$__word")
    # a word that cannot fit on a line of its own, and lists alternatives (setup|users|...), breaks after a |
    if [[ "$__word" == *"|"* && $((${#__rest} + ${#__word})) -gt "$__width" ]]; then
      __pieces=(); __rem="$__word"
      while [[ "$__rem" == *"|"* ]]; do __pieces+=("${__rem%%|*}|"); __rem="${__rem#*|}"; done
      [[ -z "$__rem" ]] || __pieces+=("$__rem")
    fi
    __glue=" "
    for __piece in "${__pieces[@]}"; do
      if [[ "$__fresh" == 1 ]]; then
        __line="${__line}${__piece}"; __fresh=0
      elif [[ $((${#__line} + ${#__glue} + ${#__piece})) -gt "$__width" ]]; then
        __out="${__out}${__line}"$'\n'; __line="${__rest}${__piece}"
      else
        __line="${__line}${__glue}${__piece}"
      fi
      __glue=""
    done
  done
  printf -v "$__var" '%s' "${__out}${__line}"
}

# fl_cmd_help KEY: the table's entry as text, in lines of at most 100 characters. The text under the name is
# the summary and the note of the command (one text; `commands --json` gives it as the summary).
fl_cmd_help() {
  local key="$1" line kind k a b c flags="" envs="" summary="" note="" usage="" tty sudo net mut json w head fname
  while IFS= read -r line; do
    IFS='~' read -r kind k a b c <<<"$line"
    [[ "$k" == "$key" ]] || continue
    case "$kind" in
      cmd) usage="$a"; summary="$b"; IFS='~' read -r _ _ _ _ tty sudo net mut json <<<"$line" ;;
      note) note="$a" ;;
      flag) printf -v fname '%-22s' "${a}${b:+ ${b}}"; fl_wrap_v w 100 "  ${fname} " "                         " "$c"; flags="${flags}${w}"$'\n' ;;
      env) printf -v fname '%-22s' "$a"; fl_wrap_v w 100 "  ${fname} " "                         " "$b"; envs="${envs}${w}"$'\n' ;;
    esac
  done <<<"$FL_CMD_TABLE"
  fl_wrap_v head 100 "benchbar ${key}: " "  " "${summary}${note:+ ${note}}"
  printf '%s\n\n' "$head"
  fl_wrap_v head 100 "Usage: " "       " "$usage"
  printf '%s\n' "$head"
  [[ -z "$flags" ]] || printf '\nOptions:\n%s' "$flags"
  [[ -z "$envs" ]] || printf '\nEnvironment:\n%s' "$envs"
  printf '\nGlobal options: --bench-dir DIR, --site NAME, --json, --jsonl, --for-agent, --plain, -h.\n'
  printf 'Needs: a terminal to ask questions: %s; sudo: %s; the network: %s.\n' "$tty" "$sudo" "$net"
  printf 'Changes things: %s. JSON: %s.\n' "$mut" "$json"
  printf 'All commands: benchbar commands --json\n'
}

# fl_help_block_v VAR: the records of the HELP block of commands.sh (the lines between `: <<'HELP'` and `HELP`)
fl_help_block_v() {
  local LC_ALL=C t head=$'\n: <<\'HELP\'\n' tail=$'\nHELP\n'
  t="$(<"$FL_CMD_FILE")"
  t="${t#*"$head"}"
  printf -v "$1" '%s' "${t%%"$tail"*}"
}

# fl_usage_text: the global help. The HELP block says what is in it and in which order; a command is a label (the
# usage form up to its first " [", or the label of the record) and its short summary, wrapped at 100 columns with
# the text 22 columns in, below the label when that is 20 characters or more. The lines of no command are text.
fl_usage_text() {
  local block line kind sec key label ulab text tilde='~' docs="" w id u s fname indent="                      "
  local p_tilde='{tilde}' p_version='{version}' p_docs='{docs}'
  local LC_ALL=C
  # one pass over the table: the usage form and the summary of every command, in variables named after the key
  while IFS= read -r line; do
    [[ "$line" == cmd~* ]] || continue
    IFS='~' read -r kind key u s _ <<<"$line"
    id="${key//[^A-Za-z0-9]/_}"
    printf -v "__fl_u_${id}" '%s' "$u"
    printf -v "__fl_s_${id}" '%s' "$s"
  done <<<"$FL_CMD_TABLE"
  fl_help_block_v block
  while IFS= read -r line; do
    IFS='~' read -r kind sec key label <<<"$line"
    case "$kind" in
      text)
        text="$key"
        text=${text//$p_tilde/$tilde}
        text=${text//$p_version/$FL_VERSION}
        if [[ "$text" == *"$p_docs"* ]]; then docs="$(fl_docs_url /)"; text=${text//$p_docs/$docs}; fi
        printf '%s\n' "$text" ;;
      help)
        id="${key//[^A-Za-z0-9]/_}"
        fname="__fl_u_${id}"; u="${!fname}"
        fname="__fl_s_${id}"; s="${!fname}"
        u="${u#benchbar }"
        ulab="${u%% \[*}"
        label="${label:-$ulab}"
        if [[ "${#label}" -ge 20 ]]; then
          printf '  %s\n' "$label"
          fl_wrap_v w 100 "$indent" "$indent" "$s"
        else
          printf -v fname '%-20s' "$label"
          fl_wrap_v w 100 "  ${fname}" "$indent" "$s"
        fi
        printf '%s\n' "$w" ;;
    esac
  done <<<"$block"
}
