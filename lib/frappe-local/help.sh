#!/usr/bin/env bash
#
# help.sh: `benchbar COMMAND --help` and the global help (`benchbar --help`), both from the commands table
# (lib/frappe-local/commands.sh): fl_cmd_help, fl_usage_text, and the wrap they use. A file of its own, read when a
# help prints (fl_cmd_help and usage() in commands.sh source it), so that no start parses it, and no start reads
# help-layout.txt, the layout of the global help that fl_usage_text reads (#371).

# fl_wrap_v VAR WIDTH FIRST REST TEXT: TEXT in lines of at most WIDTH characters (a word longer than that stands
# alone, unless it lists alternatives with |: it breaks after one). The first line starts with FIRST, the others with REST;
# the lines are joined by newlines, the last has none.
fl_wrap_v() {
  local __var="$1" __width="$2" __line="$3" __rest="$4" __out="" __word __fresh=1 __glue __piece __rem
  local __words=() __pieces=()
  local IFS=$' 	
' __noglob=$-
  set -f
  # shellcheck disable=SC2206  # split on purpose, globbing is off
  __words=($5)
  [[ "$__noglob" == *f* ]] || set +f
  for __word in ${__words[@]+"${__words[@]}"}; do
    if [[ "$__word" != *"|"* ]]; then
      # the usual word: no array, no inner loop (the global help wraps 90 texts)
      if [[ "$__fresh" == 1 ]]; then
        __line="${__line}${__word}"; __fresh=0
      elif [[ $((${#__line} + 1 + ${#__word})) -gt "$__width" ]]; then
        __out="${__out}${__line}"$'
'; __line="${__rest}${__word}"
      else
        __line="${__line} ${__word}"
      fi
      continue
    fi
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

# fl_usage_text: the global help. The cmd records of the table (FL_CMD_TABLE, already in memory) give each command's
# usage form and summary, kept in variables named after the key; help-layout.txt says what is printed and in which
# order. A command is a label (the usage form up to its first " [", or the label of the record) and the short summary,
# wrapped at 100 columns with the text 22 columns in (a text that fits is not wrapped), below the label when that is 20
# characters or more. The lines of no command are text. Both are split into lines by one word splitting at newlines
# (`read` per line cost 280 ms on the table), the output is built in one variable and printed once, and there is no
# here string and no subshell per line.
fl_usage_text() {
  local LC_ALL=C line rest key u s label id fname text w out="" docs="" tilde='~' indent="                      "
  local p_tilde='{tilde}' p_version='{version}' p_docs='{docs}' pad="                    " layout noglob=$-
  local IFS=$'\n'
  set -f
  # shellcheck disable=SC2086  # split on purpose: one record per line, globbing is off
  set -- $FL_CMD_TABLE
  for line in "$@"; do
    [[ "$line" == cmd~* ]] || continue
    rest="${line#cmd~}"; key="${rest%%~*}"; rest="${rest#*~}"; u="${rest%%~*}"; rest="${rest#*~}"; s="${rest%%~*}"
    id="${key//[^A-Za-z0-9]/_}"
    printf -v "__fl_u_${id}" '%s' "$u"
    printf -v "__fl_s_${id}" '%s' "$s"
  done
  layout="$(<"${FL_CMD_FILE%/*}/help-layout.txt")"
  # shellcheck disable=SC2086
  set -- $layout
  for line in "$@"; do
    case "$line" in
      text~*)
        text="${line#text~}"; text="${text#*~}"
        text=${text//$p_tilde/$tilde}
        text=${text//$p_version/$FL_VERSION}
        if [[ "$text" == *"$p_docs"* ]]; then docs="$(fl_docs_url /)"; text=${text//$p_docs/$docs}; fi
        out="${out}${text}"$'\n' ;;
      help~*)
        rest="${line#help~}"; rest="${rest#*~}"; key="${rest%%~*}"
        label=""; [[ "$rest" != *"~"* ]] || label="${rest#*~}"
        id="${key//[^A-Za-z0-9]/_}"
        fname="__fl_u_${id}"; u="${!fname}"
        fname="__fl_s_${id}"; s="${!fname}"
        u="${u#benchbar }"
        label="${label:-${u%% \[*}}"
        if [[ "${#label}" -ge 20 ]]; then
          out="${out}  ${label}"$'\n'
          if [[ $((22 + ${#s})) -le 100 ]]; then w="${indent}${s}"; else fl_wrap_v w 100 "$indent" "$indent" "$s"; fi
        else
          fname="${label}${pad}"; fname="${fname:0:20}"
          if [[ $((22 + ${#s})) -le 100 ]]; then w="  ${fname}${s}"; else fl_wrap_v w 100 "  ${fname}" "$indent" "$s"; fi
        fi
        out="${out}${w}"$'\n' ;;
    esac
  done
  [[ "$noglob" == *f* ]] || set +f
  printf '%s' "$out"
}
