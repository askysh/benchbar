#!/usr/bin/env bash
#
# ui.sh: terminal output for benchbar.
#
# Colors come from tput and are disabled when stdout is not a TTY, when
# NO_COLOR is set, or when FL_PLAIN=1. Every status line is also appended
# to the run log (FL_LOG_FILE) as plain text so the log stays greppable.
#
# Compatible with macOS /bin/bash 3.2: no associative arrays, no mapfile.

# Every ${var//pattern/replacement} in this code base means bash 3.2's: the
# replacement is text. bash 5.2 turns patsub_replacement on by default, which
# reads an & or a backslash in the replacement (an expanded variable
# included) as the match or an escape; off, so a value with an & in it
# (&amp;, a path) renders the same on every bash. bash 3.2 does not know the
# option and says so on stderr, hence the silence.
shopt -u patsub_replacement 2>/dev/null || true

FL_TTY=0
FL_UTF8=0
FL_COLS=80
FL_LOG_FILE="${FL_LOG_FILE:-}"
FL_SPINNER_PID=""
FL_SPINNER_TAIL_LINES=3
FL_STEP_LABELS=()
FL_STEP_STATUS=()
FL_STEP_SECS=()
FL_STEP_CURRENT=-1
FL_STEP_START=0
FL_RUN_START="${SECONDS}"
# the message of the last fl_die, for the done line of a JSON stream
FL_DIE_MESSAGE=""

fl_ui_init() {
  local cols
  FL_TTY=0
  if [[ -t 1 && -z "${NO_COLOR:-}" && "${FL_PLAIN:-0}" != "1" && "${TERM:-dumb}" != "dumb" ]]; then
    FL_TTY=1
  fi
  FL_UTF8=0
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8*|*utf-8*|*UTF8*|*utf8*) FL_UTF8=1 ;;
  esac
  if [[ "$FL_TTY" == "1" ]]; then
    cols="$(tput cols 2>/dev/null || true)"
    [[ -n "$cols" && "$cols" -gt 40 ]] && FL_COLS="$cols"
    FL_BOLD="$(tput bold 2>/dev/null || true)"
    FL_DIM="$(tput dim 2>/dev/null || true)"
    FL_RED="$(tput setaf 1 2>/dev/null || true)"
    FL_GREEN="$(tput setaf 2 2>/dev/null || true)"
    FL_YELLOW="$(tput setaf 3 2>/dev/null || true)"
    FL_BLUE="$(tput setaf 4 2>/dev/null || true)"
    FL_CYAN="$(tput setaf 6 2>/dev/null || true)"
    FL_RESET="$(tput sgr0 2>/dev/null || true)"
    FL_EL="$(tput el 2>/dev/null || true)"
  else
    FL_BOLD=""; FL_DIM=""; FL_RED=""; FL_GREEN=""; FL_YELLOW=""; FL_BLUE=""; FL_CYAN=""; FL_RESET=""; FL_EL=""
  fi
  if [[ "$FL_TTY" == "1" && "$FL_UTF8" == "1" ]]; then
    FL_G_OK="✔"; FL_G_FAIL="✖"; FL_G_WARN="!"; FL_G_PEND="○"; FL_G_RUN="●"; FL_G_SKIP="-"; FL_G_SAME="="
    FL_SPINNER_FRAMES="⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏"
    FL_B_H="─"; FL_B_V="│"; FL_B_TL="┌"; FL_B_TR="┐"; FL_B_BL="└"; FL_B_BR="┘"
  else
    FL_G_OK="+"; FL_G_FAIL="x"; FL_G_WARN="!"; FL_G_PEND="."; FL_G_RUN=">"; FL_G_SKIP="-"; FL_G_SAME="="
    FL_SPINNER_FRAMES="| / - \\"
    FL_B_H="-"; FL_B_V="|"; FL_B_TL="+"; FL_B_TR="+"; FL_B_BL="+"; FL_B_BR="+"
  fi
}
fl_ui_init

# ---------------------------------------------------------------- logging

# fl_log_init DIR: this run's log, DIR/<date>-<time>-<pid>.log. The pid
# keeps two runs started in the same second (the app's and a terminal's)
# from sharing one file, and the same stamp names this run's backup folder
# (FL_BACKUP_STAMP, templates.sh), so a log and its backups match.
fl_log_init() {
  local dir="$1" stamp
  [[ "${FL_DRY_RUN:-0}" == "1" ]] && return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  stamp="$(date +%Y%m%d-%H%M%S)-$$"
  FL_LOG_FILE="${dir}/${stamp}.log"
  # noclobber: a file of that name already exists only when the pid came
  # round again inside the second; then the next suffix
  if ! ( set -o noclobber; : >"$FL_LOG_FILE" ) 2>/dev/null; then
    FL_LOG_FILE="${dir}/${stamp}-1.log"
    ( set -o noclobber; : >"$FL_LOG_FILE" ) 2>/dev/null || FL_LOG_FILE=""
  fi
  [[ -n "${FL_BACKUP_STAMP:-}" ]] || FL_BACKUP_STAMP="$stamp"
  # the phase scripts are child processes: they log to the same file and
  # back up into the same folder
  export FL_LOG_FILE FL_BACKUP_STAMP
}

# fl_redact_url_v VAR TEXT: TEXT with the user:password (or :password) in
# front of every URL's host replaced by ***, into VAR. An app URL with a
# token in it must not reach the run log, the terminal or FL_LAST_COMMAND.
# No process when TEXT has no "://...@" in it, which is nearly every line.
FL_REDACT_URL_SED='s#://[^/@[:space:]]+@#://***@#g'
fl_redact_url_v() {
  case "$2" in
    *://*@*) printf -v "$1" '%s' "$(printf '%s\n' "$2" | sed -E "$FL_REDACT_URL_SED")" ;;
    *) printf -v "$1" '%s' "$2" ;;
  esac
}
fl_redact_url() { local r; fl_redact_url_v r "$1"; printf '%s' "$r"; }

fl_log() {
  [[ -n "$FL_LOG_FILE" ]] || return 0
  local msg="$*"
  fl_redact_url_v msg "$msg"
  printf '%s %s\n' "$(date '+%H:%M:%S')" "$msg" >>"$FL_LOG_FILE" 2>/dev/null || true
}

# fl_log_file_append FILE: a command's captured output into the run log,
# URL credentials masked (git names the URL it could not reach)
fl_log_file_append() {
  [[ -n "$FL_LOG_FILE" && -f "$1" ]] || return 0
  sed -E "$FL_REDACT_URL_SED" "$1" >>"$FL_LOG_FILE" 2>/dev/null || true
}

# fl_tail_indented FILE: the last 40 lines of a command's output for the
# terminal, indented, URL credentials masked
fl_tail_indented() {
  tail -n 40 "$1" | sed -E -e "$FL_REDACT_URL_SED" -e 's/^/     /'
}

fl_strip_ansi() {
  sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\x1b([AB]//g'
}

# a word for a POSIX shell, in single quotes
fl_sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# ---------------------------------------------------------------- JSON

# fl_json_escape_v VAR TEXT: TEXT with backslashes and quotes escaped and
# control characters (terminal colors in logs) dropped, as a JSON string
# needs; in bash, the same bytes `sed | tr -d '\000-\037'` gave. The control
# characters are listed one by one: a range in bash 3.2 follows the locale.
FL_JSON_CTRL=$'\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037'
# a whole terminal control sequence: ESC [ parameters (0x30-0x3F)
# intermediates (0x20-0x2F) final byte (0x40-0x7E). The sets are spelled
# out and tested by containment: a bracket range in a pattern or a regex
# follows the locale's collation, and under en_US.UTF-8 "[@-~]" is not the
# ASCII run it is under C (launchd runs the CLI in C, Terminal in UTF-8)
FL_JSON_CSI_PARAM='0123456789:;<=>?'
FL_JSON_CSI_INTER=' !"#$%&'"'"'()*+,-./'
FL_JSON_CSI_FINAL='@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstuvwxyz{|}~'
# fl__json_csi_len_v VAR TEXT: how many characters the control sequence at the
# start of TEXT spans (0 when TEXT does not start with ESC [)
fl__json_csi_len_v() {
  # the locals carry names no caller uses: printf -v "$1" must reach the caller's variable
  local __csi_s="$2" __csi_k=2 __csi_c
  [[ "$__csi_s" == $'\033['* ]] || { printf -v "$1" 0; return 0; }
  while __csi_c="${__csi_s:$__csi_k:1}"; [[ -n "$__csi_c" && "$FL_JSON_CSI_PARAM" == *"$__csi_c"* ]]; do __csi_k=$((__csi_k + 1)); done
  while __csi_c="${__csi_s:$__csi_k:1}"; [[ -n "$__csi_c" && "$FL_JSON_CSI_INTER" == *"$__csi_c"* ]]; do __csi_k=$((__csi_k + 1)); done
  __csi_c="${__csi_s:$__csi_k:1}"
  [[ -n "$__csi_c" && "$FL_JSON_CSI_FINAL" == *"$__csi_c"* ]] && __csi_k=$((__csi_k + 1))
  printf -v "$1" '%s' "$__csi_k"
}
fl_json_escape_v() {
  local __e="$2" __o="" __p __n
  __e="${__e//\\/\\\\}"
  __e="${__e//\"/\\\"}"
  # cut at each control character: bash 3.2's ${x//[set]/} is quadratic in
  # the string's length, and a colored 10 KB log line took 20 seconds. A
  # color code goes as a whole (ESC [ 3 1 m), not only its ESC: "[31m" left
  # behind is not a word anyone wrote, and readers would have to guess it.
  while [[ "$__e" == *[$FL_JSON_CTRL]* ]]; do
    __p="${__e%%["$FL_JSON_CTRL"]*}"
    __o="${__o}${__p}"
    __e="${__e:${#__p}}"
    fl__json_csi_len_v __n "$__e"
    if [[ "$__n" -gt 0 ]]; then __e="${__e:$__n}"; else __e="${__e:1}"; fi
  done
  printf -v "$1" '%s' "${__o}${__e}"
}

fl_json_escape() {
  local e
  fl_json_escape_v e "$1"
  printf '%s' "$e"
}

# fl_json_str_v VAR VALUE, fl_json_num_v and fl_json_bool_v put the JSON
# for VALUE into VAR without the subshell of "$(fl_json_str ...)": status and
# list build their documents with them, dozens of values per call.
fl_json_str_v() {
  local __s="$2"
  if [[ -z "$__s" ]]; then printf -v "$1" 'null'; return 0; fi
  fl_json_escape_v __s "$__s"
  printf -v "$1" '"%s"' "$__s"
}

fl_json_num_v() {
  case "$2" in
    ''|-|*[!0-9-]*) printf -v "$1" 'null' ;;
    *) printf -v "$1" '%s' "$2" ;;
  esac
}

fl_json_bool_v() {
  if [[ "$2" == "1" || "$2" == "yes" || "$2" == "true" ]]; then printf -v "$1" 'true'; else printf -v "$1" 'false'; fi
}

fl_json_str() { local j; fl_json_str_v j "$1"; printf '%s' "$j"; }
fl_json_num() { local j; fl_json_num_v j "$1"; printf '%s' "$j"; }
fl_json_bool() { local j; fl_json_bool_v j "$1"; printf '%s' "$j"; }

# ---------------------------------------------------------------- JSON lines
#
# install --json and adopt --json (docs/json-schema.md) stream one JSON
# object per line on fd 3, the command's real stdout; the human text goes
# to the run's log. FL_JSONL=1 turns the events on, in benchbar and in the
# phase scripts it starts (they inherit fd 3 and the variable).

FL_JSONL="${FL_JSONL:-0}"
# the step a phase script's sections belong to (system_deps, bench_site);
# set for the phase script's process only, so benchbar's own fl_section
# calls stay out of the stream
FL_JSONL_PARENT="${FL_JSONL_PARENT:-}"
# the id of the step or section that runs now (progress lines name it)
FL_JSONL_CUR=""
# the open section of a phase script: id, heading, start, log line, warned
FL_JSONL_SEC_ID=""
FL_JSONL_SEC_NAME=""
FL_JSONL_SEC_START=0
FL_JSONL_SEC_LOG=0
FL_JSONL_SEC_WARN=0

# fl_jsonl EVENT [,"field":value...]: one line on fd 3. A closed fd 3 (a
# command that was started without it) never ends the run.
fl_jsonl() {
  [[ "$FL_JSONL" == "1" ]] || return 0
  # a dry run streams the plan and done only (FL_JSONL_QUIET)
  [[ "${FL_JSONL_QUIET:-0}" != "1" || "$1" == "done" ]] || return 0
  { printf '{"schema_version":%d,"cli_version":"%s","event":"%s"%s}\n' "${FL_SCHEMA_VERSION:-1}" "${FL_JSONL_VERSION:-${FL_VERSION:-0}}" "$1" "${2:-}" >&3; } 2>/dev/null || true
}

# fl_log_lines_v VAR: how many lines the run log has now (0 without one)
fl_log_lines_v() {
  local __n=0
  if [[ -n "${FL_LOG_FILE:-}" && -f "$FL_LOG_FILE" ]]; then __n="$(wc -l <"$FL_LOG_FILE" 2>/dev/null | tr -d ' ')"; fi
  printf -v "$1" '%s' "${__n:-0}"
}

# The most telling line the step wrote to the log since line $1: its last
# [FAIL], else its last [WARN] or skip note, else nothing.
fl_log_step_message() {
  local from="$1" text
  [[ -n "${FL_LOG_FILE:-}" && -f "$FL_LOG_FILE" ]] || return 0
  text="$(tail -n +"$((from + 1))" "$FL_LOG_FILE" 2>/dev/null)"
  local line
  line="$(printf '%s\n' "$text" | grep -E '\[FAIL\]' | tail -n1)"
  [[ -n "$line" ]] || line="$(printf '%s\n' "$text" | grep -E '\[WARN\]' | tail -n1)"
  [[ -n "$line" ]] || line="$(printf '%s\n' "$text" | grep -E 'skipped' | grep -v -E '(^|[0-9:] )step [0-9]+ ' | tail -n1)"
  printf '%s' "$line" | sed 's/^[0-9][0-9]:[0-9][0-9]:[0-9][0-9] //'
}

# fl_jsonl_step N ID PARENT NAME STATUS [SECS [MESSAGE [COMMAND]]]: a step
# line; N, PARENT, SECS, MESSAGE and COMMAND may be empty (null or absent)
fl_jsonl_step() {
  [[ "$FL_JSONL" == "1" ]] || return 0
  local n p f msg="${7:-}"
  fl_json_num_v n "$1"
  fl_json_str_v p "$3"
  f=",\"n\":${n},\"id\":$(fl_json_str "$2"),\"parent\":${p},\"name\":$(fl_json_str "$4"),\"status\":\"$5\""
  [[ -z "${6:-}" ]] || f="${f},\"secs\":$6"
  [[ -z "$msg" ]] || f="${f},\"message\":$(fl_json_str "${msg:0:1000}")"
  [[ -z "${8:-}" ]] || f="${f},\"command\":$(fl_json_str "$8")"
  [[ "$5" != "running" ]] || FL_JSONL_CUR="$2"
  fl_jsonl step "$f"
}

# the privileged steps that were skipped, for the done line: {"id","command"},...
FL_JSONL_SKIPPED=""
FL_SKIP_COMMAND="${FL_SKIP_COMMAND:-}"
fl_jsonl_skipped_add() {
  [[ -n "${2:-}" ]] || return 0
  FL_JSONL_SKIPPED="${FL_JSONL_SKIPPED}${FL_JSONL_SKIPPED:+,}{\"id\":$(fl_json_str "$1"),\"command\":$(fl_json_str "$2")}"
}

# fl_jsonl_progress LABEL ELAPSED: a progress line for the step that runs
# now; the size of the file in FL_PROGRESS_FILE is the bytes of a download
fl_jsonl_progress() {
  [[ "$FL_JSONL" == "1" ]] || return 0
  local bytes=""
  if [[ -n "${FL_PROGRESS_FILE:-}" && -f "$FL_PROGRESS_FILE" ]]; then
    bytes="$(stat -f %z "$FL_PROGRESS_FILE" 2>/dev/null || stat -c %s "$FL_PROGRESS_FILE" 2>/dev/null || true)"
  fi
  fl_jsonl progress ",\"step\":$(fl_json_str "$FL_JSONL_CUR"),\"label\":$(fl_json_str "$1"),\"elapsed\":$2,\"bytes\":$(fl_json_num "$bytes"),\"total\":null"
}

# fl_jsonl_section_end STATUS: closes the open section of a phase script
fl_jsonl_section_end() {
  [[ -n "$FL_JSONL_SEC_ID" ]] || return 0
  local status="$1" msg=""
  if [[ "$status" != "done" ]]; then msg="$(fl_log_step_message "$FL_JSONL_SEC_LOG")"; fi
  fl_jsonl_step "" "$FL_JSONL_SEC_ID" "$FL_JSONL_PARENT" "$FL_JSONL_SEC_NAME" "$status" "$((SECONDS - FL_JSONL_SEC_START))" "$msg"
  FL_JSONL_SEC_ID=""
}

# fl_jsonl_section_begin HEADING: ends the section before (done, or warning
# when it printed a [WARN] or [FAIL] line) and begins this one. Only in a
# phase script (FL_JSONL_PARENT set).
fl_jsonl_section_begin() {
  [[ "$FL_JSONL" == "1" && -n "$FL_JSONL_PARENT" ]] || return 0
  local id
  if [[ "$FL_JSONL_SEC_WARN" == "1" ]]; then fl_jsonl_section_end warning; else fl_jsonl_section_end done; fi
  id="$(printf '%s' "$1" | tr '[:upper:] ' '[:lower:]_')"
  FL_JSONL_SEC_ID="$id"; FL_JSONL_SEC_NAME="$1"; FL_JSONL_SEC_START="$SECONDS"; FL_JSONL_SEC_WARN=0
  fl_log_lines_v FL_JSONL_SEC_LOG
  fl_jsonl_step "" "$id" "$FL_JSONL_PARENT" "$1" running
}

# fl_jsonl_section_exit CODE: the EXIT trap of a phase script closes the
# last section: done on 0, warning on 2 (manual steps pending), else failed
fl_jsonl_section_exit() {
  [[ -n "$FL_JSONL_SEC_ID" ]] || return 0
  case "$1" in
    0) fl_jsonl_section_end done ;;
    2) fl_jsonl_section_end warning ;;
    *) fl_jsonl_section_end failed ;;
  esac
}

# ---------------------------------------------------------------- status lines

fl_section() {
  fl_spinner_pause
  fl_jsonl_section_begin "$1"
  printf '\n%s%s %s%s\n' "$FL_BOLD$FL_BLUE" "==========" "$1 ==========" "$FL_RESET"
  fl_log "== $1 =="
}

fl_status_line() {
  local color="$1" label="$2" msg="$3"
  fl_spinner_pause
  case "$label" in WARN|FAIL) FL_JSONL_SEC_WARN=1 ;; esac
  printf '  %s[%s]%s %s\n' "$color" "$label" "$FL_RESET" "$msg"
  fl_log "[$label] $msg"
}

fl_ok()   { fl_status_line "$FL_GREEN" "OK" "$1"; }
fl_warn() { fl_status_line "$FL_YELLOW" "WARN" "$1"; }
fl_fail() { fl_status_line "$FL_RED" "FAIL" "$1"; }
fl_info() {
  fl_spinner_pause
  printf '  %s..%s %s\n' "$FL_DIM" "$FL_RESET" "$1"
  fl_log ".. $1"
}
fl_note() {
  fl_spinner_pause
  printf '     %s%s%s\n' "$FL_DIM" "$1" "$FL_RESET"
  fl_log "   $1"
}
fl_fix() {
  fl_spinner_pause
  printf '     %sfix:%s %s\n' "$FL_CYAN" "$FL_RESET" "$1"
  fl_log "   fix: $1"
}

# fl_see URL: the documentation for the line above, under its fix: line
fl_see() {
  fl_spinner_pause
  printf '     %ssee:%s %s\n' "$FL_DIM" "$FL_RESET" "$1"
  fl_log "   see: $1"
}

fl_die() {
  local msg hint
  fl_spinner_stop
  # a hint may quote the command that failed, URL and token included
  fl_redact_url_v msg "$1"
  fl_redact_url_v hint "${2:-Fix the above and re-run.}"
  FL_DIE_MESSAGE="$msg"
  fl_fail "$msg"
  printf '\n%sAborting.%s %s\n' "$FL_RED$FL_BOLD" "$FL_RESET" "$hint"
  fl_log "ABORT: ${2:-}"
  exit "${3:-1}"
}

# ---------------------------------------------------------------- time

fl_fmt_secs() {
  local s="$1"
  if [[ "$s" -ge 3600 ]]; then
    printf '%dh %02dm' $((s / 3600)) $(((s % 3600) / 60))
  elif [[ "$s" -ge 60 ]]; then
    printf '%dm %02ds' $((s / 60)) $((s % 60))
  else
    printf '%ds' "$s"
  fi
}

# ---------------------------------------------------------------- spinner

# fl_spinner_start LABEL [TAIL_FILE]
# Draws an animated line while a long command runs. With TAIL_FILE the last
# few lines of that file are shown under the spinner and refreshed live.
fl__spinner_loop() {
  local label="$1" tail_file="$2" i=0 frames frame width n line start shown
  # shellcheck disable=SC2206
  frames=($FL_SPINNER_FRAMES)
  n=${#frames[@]}
  width=$((FL_COLS - 6))
  start="$SECONDS"
  trap 'exit 0' TERM
  while :; do
    frame="${frames[$((i % n))]}"
    printf '\r  %s%s%s %s %s(%s)%s%s' "$FL_CYAN" "$frame" "$FL_RESET" "$label" "$FL_DIM" "$(fl_fmt_secs $((SECONDS - start)))" "$FL_RESET" "$FL_EL"
    if [[ -n "$tail_file" ]]; then
      printf '\n'
      shown=0
      if [[ -s "$tail_file" ]]; then
        while IFS= read -r line; do
          printf '    %s%s%s%s\n' "$FL_DIM" "$line" "$FL_RESET" "$FL_EL"
          shown=$((shown + 1))
        done < <(tail -n "$FL_SPINNER_TAIL_LINES" "$tail_file" 2>/dev/null | fl_strip_ansi | tr -d '\r' | cut -c1-"$width")
      fi
      while [[ "$shown" -lt "$FL_SPINNER_TAIL_LINES" ]]; do printf '%s\n' "$FL_EL"; shown=$((shown + 1)); done
      tput cuu $((FL_SPINNER_TAIL_LINES + 1)) 2>/dev/null || true
    fi
    i=$((i + 1))
    sleep 0.15
  done
}

# fl_spinner_start LABEL [TAIL_FILE]
# Draws an animated line while a long command runs. With TAIL_FILE the last
# few lines of that file are shown under the spinner and refreshed live.
fl_spinner_start() {
  local label="$1" tail_file="${2:-}"
  [[ "$FL_TTY" == "1" ]] || { printf '  %s %s\n' "$FL_G_RUN" "$label"; return 0; }
  fl_spinner_stop
  FL_SPINNER_TAIL="$tail_file"
  fl__spinner_loop "$label" "$tail_file" &
  FL_SPINNER_PID="$!"
}

fl_spinner_clear_area() {
  [[ "$FL_TTY" == "1" ]] || return 0
  printf '\r%s' "$FL_EL"
  if [[ -n "${FL_SPINNER_TAIL:-}" ]]; then
    local k=0
    while [[ "$k" -lt "$FL_SPINNER_TAIL_LINES" ]]; do printf '\n%s' "$FL_EL"; k=$((k + 1)); done
    tput cuu "$FL_SPINNER_TAIL_LINES" 2>/dev/null || true
    printf '\r'
  fi
}

fl_spinner_stop() {
  [[ -n "$FL_SPINNER_PID" ]] || return 0
  kill "$FL_SPINNER_PID" 2>/dev/null || true
  wait "$FL_SPINNER_PID" 2>/dev/null || true
  FL_SPINNER_PID=""
  fl_spinner_clear_area
  FL_SPINNER_TAIL=""
}

# Called before printing a normal line so it never lands on top of a spinner.
fl_spinner_pause() {
  [[ -n "$FL_SPINNER_PID" ]] || return 0
  fl_spinner_stop
}

# ---------------------------------------------------------------- boxes and tables

fl_box() {
  local title="$1" width=0 line pad inner
  shift
  fl_spinner_pause
  for line in "$@"; do [[ "${#line}" -gt "$width" ]] && width="${#line}"; done
  [[ "${#title}" -gt "$width" ]] && width="${#title}"
  inner=$((width + 2))
  [[ "$inner" -gt $((FL_COLS - 2)) ]] && inner=$((FL_COLS - 2))
  printf '%s%s' "$FL_BOLD" "$FL_B_TL"
  if [[ -n "$title" ]]; then
    printf '%s %s ' "$FL_B_H" "$title"
    pad=$((inner - ${#title} - 3))
  else
    pad="$inner"
  fi
  while [[ "$pad" -gt 0 ]]; do printf '%s' "$FL_B_H"; pad=$((pad - 1)); done
  printf '%s%s\n' "$FL_B_TR" "$FL_RESET"
  for line in "$@"; do
    fl_log "| $line"
    [[ "${#line}" -gt $((inner - 2)) ]] && line="$(printf '%s' "$line" | cut -c1-$((inner - 5)))..."
    printf '%s%s%s %-*s %s%s%s\n' "$FL_BOLD" "$FL_B_V" "$FL_RESET" $((inner - 2)) "$line" "$FL_BOLD" "$FL_B_V" "$FL_RESET"
  done
  printf '%s%s' "$FL_BOLD" "$FL_B_BL"
  pad="$inner"
  while [[ "$pad" -gt 0 ]]; do printf '%s' "$FL_B_H"; pad=$((pad - 1)); done
  printf '%s%s\n' "$FL_B_BR" "$FL_RESET"
}

fl_header() {
  local tool="$1" mode="$2" profile="$3" bench="$4" site="$5"
  printf '\n'
  fl_box "$tool" \
    "mode     $mode" \
    "profile  $profile" \
    "bench    $bench" \
    "site     $site"
  fl_log "start: $tool mode=$mode profile=$profile bench=$bench site=$site"
}

# fl_table ROW... where ROW is "col1|col2|col3"; first row is the heading.
fl_table() {
  local row ncols=0 i w widths=() cells
  fl_spinner_pause
  for row in "$@"; do
    IFS='|' read -r -a cells <<<"$row"
    [[ "${#cells[@]}" -gt "$ncols" ]] && ncols="${#cells[@]}"
    i=0
    for w in "${cells[@]}"; do
      if [[ -z "${widths[$i]:-}" || "${#w}" -gt "${widths[$i]}" ]]; then widths[i]="${#w}"; fi
      i=$((i + 1))
    done
  done
  local first=1
  for row in "$@"; do
    IFS='|' read -r -a cells <<<"$row"
    printf '  '
    i=0
    for w in "${cells[@]}"; do
      if [[ "$first" == "1" ]]; then printf '%s%-*s%s  ' "$FL_BOLD" "${widths[$i]}" "$w" "$FL_RESET"; else printf '%-*s  ' "${widths[$i]}" "$w"; fi
      i=$((i + 1))
    done
    printf '\n'
    fl_log "  $row"
    first=0
  done
}

# ---------------------------------------------------------------- numbered steps

# Under --json a step with an id is announced on the stream: FL_STEP_IDS has
# one id per label (fl_steps_ids), FL_STEP_PARENT is the parent of every
# step (the repair engine inside install), FL_STEP_NUMBERED 0 leaves n null.
FL_STEP_IDS=()
FL_STEP_PARENT=""
FL_STEP_NUMBERED=1
FL_STEP_LOG_FROM=0
fl_steps_reset() { FL_STEP_LABELS=(); FL_STEP_STATUS=(); FL_STEP_SECS=(); FL_STEP_IDS=(); FL_STEP_PARENT=""; FL_STEP_NUMBERED=1; FL_STEP_CURRENT=-1; FL_RUN_START="$SECONDS"; }

# fl_steps_ids [-n] [-p PARENT] ID...: the ids of the steps just defined
fl_steps_ids() {
  FL_STEP_NUMBERED=1
  while [[ "${1:-}" == -* ]]; do
    case "$1" in
      -n) FL_STEP_NUMBERED=0; shift ;;
      -p) FL_STEP_PARENT="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  FL_STEP_IDS=("$@")
}

fl_steps_define() {
  local label
  fl_steps_reset
  for label in "$@"; do
    FL_STEP_LABELS+=("$label"); FL_STEP_STATUS+=("pending"); FL_STEP_SECS+=("0")
  done
}

# fl_steps_push / fl_steps_pop: keep a command's own steps while a nested
# run (the repair engine inside install) defines and prints its own. One level.
fl_steps_push() {
  FL_SAVED_LABELS=(${FL_STEP_LABELS[@]+"${FL_STEP_LABELS[@]}"})
  FL_SAVED_STATUS=(${FL_STEP_STATUS[@]+"${FL_STEP_STATUS[@]}"})
  FL_SAVED_SECS=(${FL_STEP_SECS[@]+"${FL_STEP_SECS[@]}"})
  FL_SAVED_IDS=(${FL_STEP_IDS[@]+"${FL_STEP_IDS[@]}"})
  FL_SAVED_PARENT="$FL_STEP_PARENT"; FL_SAVED_NUMBERED="$FL_STEP_NUMBERED"
  FL_SAVED_CURRENT="$FL_STEP_CURRENT"; FL_SAVED_START="$FL_STEP_START"; FL_SAVED_RUN_START="$FL_RUN_START"
}
fl_steps_pop() {
  FL_STEP_LABELS=(${FL_SAVED_LABELS[@]+"${FL_SAVED_LABELS[@]}"})
  FL_STEP_STATUS=(${FL_SAVED_STATUS[@]+"${FL_SAVED_STATUS[@]}"})
  FL_STEP_SECS=(${FL_SAVED_SECS[@]+"${FL_SAVED_SECS[@]}"})
  FL_STEP_IDS=(${FL_SAVED_IDS[@]+"${FL_SAVED_IDS[@]}"})
  FL_STEP_PARENT="$FL_SAVED_PARENT"; FL_STEP_NUMBERED="$FL_SAVED_NUMBERED"
  FL_STEP_CURRENT="$FL_SAVED_CURRENT"; FL_STEP_START="$FL_SAVED_START"; FL_RUN_START="$FL_SAVED_RUN_START"
}

fl_steps_print_plan() {
  local i=0
  fl_spinner_pause
  printf '\n%sSteps%s\n' "$FL_BOLD" "$FL_RESET"
  while [[ "$i" -lt "${#FL_STEP_LABELS[@]}" ]]; do
    printf '  %s %d. %s\n' "$FL_G_PEND" $((i + 1)) "${FL_STEP_LABELS[$i]}"
    i=$((i + 1))
  done
  printf '\n'
}

fl_step_glyph() {
  case "$1" in
    done) printf '%s%s%s' "$FL_GREEN" "$FL_G_OK" "$FL_RESET" ;;
    unchanged) printf '%s%s%s' "$FL_GREEN" "$FL_G_SAME" "$FL_RESET" ;;
    skipped) printf '%s%s%s' "$FL_DIM" "$FL_G_SKIP" "$FL_RESET" ;;
    failed) printf '%s%s%s' "$FL_RED" "$FL_G_FAIL" "$FL_RESET" ;;
    warning) printf '%s%s%s' "$FL_YELLOW" "$FL_G_WARN" "$FL_RESET" ;;
    running) printf '%s%s%s' "$FL_CYAN" "$FL_G_RUN" "$FL_RESET" ;;
    *) printf '%s' "$FL_G_PEND" ;;
  esac
}

# fl_step_json STATUS INDEX [SECS [DETAIL [COMMAND]]]: the stream's line for
# step INDEX, when it has an id. The message of a failed, skipped or warning
# step is the CLI's own [FAIL] or [WARN] line, so terminal and stream agree.
fl_step_json() {
  [[ "$FL_JSONL" == "1" && -n "${FL_STEP_IDS[$2]:-}" ]] || return 0
  local n="" msg="" cmd="${5:-}"
  [[ "$FL_STEP_NUMBERED" != "1" ]] || n=$(($2 + 1))
  case "$1" in
    failed|skipped|warning) msg="$(fl_log_step_message "$FL_STEP_LOG_FROM")"; msg="${msg:-${4:-}}" ;;
  esac
  # a step that skipped itself says what to run by hand (FL_SKIP_COMMAND)
  if [[ "$1" == "skipped" ]]; then
    cmd="${cmd:-$FL_SKIP_COMMAND}"
    fl_jsonl_skipped_add "${FL_STEP_IDS[$2]}" "$cmd"
  else
    cmd=""
  fi
  fl_jsonl_step "$n" "${FL_STEP_IDS[$2]}" "$FL_STEP_PARENT" "${FL_STEP_LABELS[$2]}" "$1" "${3:-}" "$msg" "$cmd"
}

# fl_step_begin INDEX: announces a step whose output streams to the terminal.
fl_step_begin() {
  local i="$1"
  FL_STEP_CURRENT="$i"
  FL_STEP_START="$SECONDS"
  FL_STEP_STATUS[i]="running"
  FL_SKIP_COMMAND=""
  fl_log_lines_v FL_STEP_LOG_FROM
  fl_spinner_pause
  printf '\n%s%s %d. %s%s\n' "$FL_BOLD" "$(fl_step_glyph running)" $((i + 1)) "${FL_STEP_LABELS[$i]}" "$FL_RESET"
  fl_log "step $((i + 1)) start: ${FL_STEP_LABELS[$i]}"
  fl_step_json running "$i"
}

# fl_step_end STATUS [DETAIL [COMMAND]]: COMMAND is for the stream only
fl_step_end() {
  local status="$1" detail="${2:-}" i="$FL_STEP_CURRENT" secs
  [[ "$i" -ge 0 ]] || return 0
  secs=$((SECONDS - FL_STEP_START))
  FL_STEP_STATUS[i]="$status"
  FL_STEP_SECS[i]="$secs"
  fl_spinner_pause
  printf '  %s %d. %s: %s%s %s(%s)%s\n' "$(fl_step_glyph "$status")" $((i + 1)) "${FL_STEP_LABELS[$i]}" "$status" "${detail:+ ($detail)}" "$FL_DIM" "$(fl_fmt_secs "$secs")" "$FL_RESET"
  fl_log "step $((i + 1)) $status ${detail} ($(fl_fmt_secs "$secs"))"
  fl_step_json "$status" "$i" "$secs" "$detail" "${3:-}"
  FL_STEP_CURRENT=-1
}

# fl_step_run INDEX FUNCTION [ARGS]: runs a quiet step behind a spinner. The
# function sets FL_STEP_RESULT to done, unchanged, skipped or warning; a
# non-zero exit means failed. Its output is captured and replayed afterwards
# so [WARN] and [FAIL] lines are never lost.
fl_step_run() {
  local i="$1" fn="$2" out code=0 label
  shift 2
  label="${FL_STEP_LABELS[$i]}"
  FL_STEP_CURRENT="$i"
  FL_STEP_START="$SECONDS"
  FL_STEP_STATUS[i]="running"
  FL_STEP_RESULT="done"
  out="$(mktemp "${TMPDIR:-/tmp}/benchbar-step.XXXXXX")"
  fl_log "step $((i + 1)) start: $label"
  fl_log_lines_v FL_STEP_LOG_FROM
  fl_step_json running "$i"
  fl_spinner_start "$((i + 1)). $label" "$out"
  "$fn" "$@" >"$out" 2>&1 || code=$?
  fl_spinner_stop
  fl_log_file_append "$out"
  if [[ "$code" -ne 0 ]]; then
    fl_step_end failed
    fl_tail_indented "$out"
  else
    fl_step_end "$FL_STEP_RESULT"
    grep -E '^[[:space:]]*([^[:space:]]*\[(WARN|FAIL)\]|fix:)' "$out" 2>/dev/null | sed 's/^/   /' || true
  fi
  rm -f "$out"
  return "$code"
}

fl_steps_summary() {
  local i=0 rows=() total
  rows+=("#|Step|Status|Time")
  while [[ "$i" -lt "${#FL_STEP_LABELS[@]}" ]]; do
    rows+=("$((i + 1))|${FL_STEP_LABELS[$i]}|${FL_STEP_STATUS[$i]}|$(fl_fmt_secs "${FL_STEP_SECS[$i]}")")
    i=$((i + 1))
  done
  total=$((SECONDS - FL_RUN_START))
  printf '\n%sSummary%s\n' "$FL_BOLD" "$FL_RESET"
  fl_table "${rows[@]}"
  printf '  total %s\n' "$(fl_fmt_secs "$total")"
  fl_log "total $(fl_fmt_secs "$total")"
}

fl_steps_counts() {
  # prints "N unchanged, N to update, N to repair" style counts from a status list
  local unchanged=0 update=0 repair=0 s
  for s in "$@"; do
    case "$s" in
      unchanged) unchanged=$((unchanged + 1)) ;;
      update) update=$((update + 1)) ;;
      repair) repair=$((repair + 1)) ;;
    esac
  done
  printf '%d unchanged, %d to update, %d to repair' "$unchanged" "$update" "$repair"
}

# ---------------------------------------------------------------- prompts

fl_confirm() {
  local prompt="$1" answer
  fl_spinner_pause
  if [[ "${FL_ASSUME_YES:-0}" == "1" ]]; then
    fl_info "auto-confirmed: ${prompt}"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    fl_warn "Not a terminal and --yes not given; treating '${prompt}' as no."
    return 1
  fi
  if [[ "$FL_TTY" == "1" ]] && command -v gum >/dev/null 2>&1; then
    gum confirm "$prompt" && return 0
    return 1
  fi
  read -r -p "  ${prompt} [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

fl_ask() {
  local __varname="$1" __prompt="$2" __default="${3:-}" __answer
  fl_spinner_pause
  if [[ -n "${!__varname:-}" ]]; then
    fl_redact_url_v __answer "${!__varname}"
    fl_info "using env-provided ${__varname}=${__answer}"
    return 0
  fi
  if [[ "$FL_TTY" == "1" ]] && command -v gum >/dev/null 2>&1; then
    __answer="$(gum input --prompt "  ${__prompt}: " --value "$__default" </dev/tty)" || __answer="$__default"
    printf -v "$__varname" '%s' "${__answer:-$__default}"
    return 0
  fi
  # no terminal (an agent, a pipe): the default is the answer; without one,
  # say what to pass instead of letting read end the run silently
  if [[ ! -t 0 ]]; then
    [[ -n "$__default" ]] || fl_die "Cannot ask for ${__varname}: there is no terminal to type it in." \
      "Pass it in the environment (${__varname}='...' before the command), or run the command in a terminal"
    printf -v "$__varname" '%s' "$__default"
    fl_info "no terminal: ${__prompt}: ${__default} (the default)"
    return 0
  fi
  if [[ -n "$__default" ]]; then
    read -r -p "  ${__prompt} [${__default}]: " __answer
    printf -v "$__varname" '%s' "${__answer:-$__default}"
  else
    read -r -p "  ${__prompt}: " __answer
    printf -v "$__varname" '%s' "$__answer"
  fi
}

fl_ask_secret() {
  local __varname="$1" __prompt="$2" __answer __confirm
  fl_spinner_pause
  if [[ -n "${!__varname:-}" ]]; then
    fl_info "using env-provided ${__varname} (hidden)"
    return 0
  fi
  # no terminal: read hits end of input, and under set -e the run would
  # end right here without a word
  [[ -t 0 ]] || fl_die "Cannot ask for ${__varname}: there is no terminal to type it in." \
    "Pass it in the environment (${__varname}='...' before the command), or run the command in a terminal"
  while true; do
    read -r -s -p "  ${__prompt}: " __answer || fl_die "No ${__varname} given (end of input)." "Pass ${__varname}='...' before the command"
    printf '\n'
    [[ -n "$__answer" ]] || { fl_warn "empty value; retry"; continue; }
    read -r -s -p "  confirm ${__prompt}: " __confirm || fl_die "No ${__varname} given (end of input)." "Pass ${__varname}='...' before the command"
    printf '\n'
    [[ "$__answer" == "$__confirm" ]] && { printf -v "$__varname" '%s' "$__answer"; return 0; }
    fl_warn "values do not match; retry"
  done
}
