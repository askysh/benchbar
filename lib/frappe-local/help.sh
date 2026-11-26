#!/usr/bin/env bash
#
# help.sh: `benchbar COMMAND --help`, from the commands table (lib/frappe-local/commands.sh): fl_cmd_help and the
# wrap it uses. A file of its own, read when a help prints (fl_cmd_help in commands.sh sources it and runs it), so
# that no start parses it (#371).

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
