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
# a stable id for the failure (sudo_password_wrong), the "error_id" of the done line
FL_ERROR_ID=""
# the fix that goes with that id, for the "fix" of the done line
FL_ERROR_FIX=""

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
    # the color terminals of every Mac and Linux terminal app: the codes are
    # fixed, so no tput process (nine of them, 19 ms) for them. A terminal
    # whose terminfo has no colors (xterm-mono, vt100) asks tput, which then
    # prints nothing for the colors, as before.
    local __fixed=0
    case "${TERM:-}" in
      *mono*) ;;
      xterm*|screen*|tmux*|rxvt*|linux|alacritty|foot*|wezterm) __fixed=1 ;;
    esac
    if [[ "$__fixed" == "1" ]]; then
      local __e=$'\033['
      FL_BOLD="${__e}1m"; FL_DIM="${__e}2m"
      FL_RED="${__e}31m"; FL_GREEN="${__e}32m"; FL_YELLOW="${__e}33m"; FL_BLUE="${__e}34m"; FL_CYAN="${__e}36m"
      FL_RESET="${__e}m"; FL_EL="${__e}K"
    else
      FL_BOLD="$(tput bold 2>/dev/null || true)"
      FL_DIM="$(tput dim 2>/dev/null || true)"
      FL_RED="$(tput setaf 1 2>/dev/null || true)"
      FL_GREEN="$(tput setaf 2 2>/dev/null || true)"
      FL_YELLOW="$(tput setaf 3 2>/dev/null || true)"
      FL_BLUE="$(tput setaf 4 2>/dev/null || true)"
      FL_CYAN="$(tput setaf 6 2>/dev/null || true)"
      FL_RESET="$(tput sgr0 2>/dev/null || true)"
      FL_EL="$(tput el 2>/dev/null || true)"
    fi
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
  fl_state_prune "$dir"
}

# ---------------------------------------------------------------- state limits

# What benchbar writes into its own state folder keeps to a limit, applied at
# the start of every run that makes a log (so a long running bench or a read
# only command never prunes). Only benchbar's own names are touched, the
# newest are kept, and what went is one line in changed[]:
#   run logs            logs/<date>-<time>-<pid>.log        newest 100
#   state backups       backups/<date>-<time>-<pid>/        newest 50 (a folder
#                       that still holds a restore-set copy stays; that copy has
#                       its own limit, the three newest of a bench; so does one
#                       that holds a kept-sets file, which may be the only copy
#                       of a site's older backup: the next backup of the site
#                       puts it back, and doctor warns until then)
#   update checks       update-check.<date>.txt             newest 14
#   temp files          state.env.XXXXXX of a killed writer older than a day
# The limits can be changed with FL_KEEP_RUN_LOGS, FL_KEEP_STATE_BACKUPS and
# FL_KEEP_UPDATE_CHECKS (a number; the tests use small ones). Nothing in a
# bench or in a site's backup folder is ever pruned here.
# shellcheck disable=SC2010  # names this tool made, matched by a strict pattern
fl_state_prune() {
  local logdir="$1" keep_logs keep_bk keep_uc n f d name logs=0 baks=0 checks=0 temps=0 root
  [[ "${FL_DRY_RUN:-0}" != "1" ]] || return 0
  keep_logs="${FL_KEEP_RUN_LOGS:-100}"; [[ "$keep_logs" =~ ^[0-9]+$ && "$keep_logs" -ge 1 ]] || keep_logs=100
  keep_bk="${FL_KEEP_STATE_BACKUPS:-50}"; [[ "$keep_bk" =~ ^[0-9]+$ && "$keep_bk" -ge 1 ]] || keep_bk=50
  keep_uc="${FL_KEEP_UPDATE_CHECKS:-14}"; [[ "$keep_uc" =~ ^[0-9]+$ && "$keep_uc" -ge 1 ]] || keep_uc=14
  # run logs: the names sort by time
  n=0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    n=$((n + 1))
    [[ "$n" -gt "$keep_logs" ]] || continue
    f="${logdir}/${name}"
    [[ -f "$f" && ! -L "$f" && "$f" != "${FL_LOG_FILE:-}" ]] || continue
    rm -f "$f" 2>/dev/null && logs=$((logs + 1))
  done < <(ls -1 "$logdir" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}-[0-9]+(-[0-9]+)?\.log$' | sort -r || true)
  # state backups: whole folders of this tool's own stamps
  root="${FL_BACKUP_ROOT:-${FL_STATE_DIR}/backups}"
  n=0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    n=$((n + 1))
    [[ "$n" -gt "$keep_bk" ]] || continue
    d="${root}/${name}"
    [[ -d "$d" && ! -L "$d" && ! -e "${d}/restore-set" && "$name" != "${FL_BACKUP_STAMP:-}" ]] || continue
    # a kept older backup (site-backups.sh) that was not put back may be the only copy
    [[ -z "$(find "${d}/kept-sets" -type f ! -name '.*' -print -quit 2>/dev/null)" ]] || continue
    rm -rf -- "$d" 2>/dev/null && baks=$((baks + 1))
  done < <(ls -1 "$root" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}-[0-9]+$' | sort -r || true)
  # the update check of every day
  n=0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    n=$((n + 1))
    [[ "$n" -gt "$keep_uc" ]] || continue
    f="${FL_STATE_DIR}/${name}"
    [[ -f "$f" && ! -L "$f" ]] || continue
    rm -f "$f" 2>/dev/null && checks=$((checks + 1))
  done < <(ls -1 "$FL_STATE_DIR" 2>/dev/null | grep -E '^update-check\.[0-9]{8}\.txt$' | sort -r || true)
  # a temp file a killed writer left (state.sh: mktemp state.env.XXXXXX), a day old
  while IFS= read -r f; do
    [[ -n "$f" && -f "$f" && ! -L "$f" ]] || continue
    rm -f "$f" 2>/dev/null && temps=$((temps + 1))
  done < <(find "$FL_STATE_DIR" -maxdepth 3 -type f -name 'state.env.??????' -mmin +1440 2>/dev/null || true)
  [[ $((logs + baks + checks + temps)) -gt 0 ]] || return 0
  fl_log "pruned: ${logs} run logs, ${baks} state backup folders, ${checks} update checks, ${temps} temp files"
  fl_changed pruned "state folder" "removed beyond the limits: ${logs} run logs (keeps ${keep_logs}), ${baks} backup folders (keeps ${keep_bk}), ${checks} update checks (keeps ${keep_uc}), ${temps} old temp files"
  return 0
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

# https://user:token@host/x -> https://host/x (never shown, never written). In
# ui.sh so the phase scripts have it too: the reach cache of profile check needs it.
fl_url_strip_userinfo_v() {
  if [[ "$2" =~ ^(https?://)[^/@]*@(.*)$ ]]; then printf -v "$1" '%s%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; else printf -v "$1" '%s' "$2"; fi
}
fl_url_strip_userinfo() { local u; fl_url_strip_userinfo_v u "$1"; printf '%s' "$u"; }


fl_log() {
  [[ -n "$FL_LOG_FILE" ]] || return 0
  local msg="$*" __ts
  fl_redact_url_v msg "$msg"
  fl_log_stamp_v __ts
  printf '%s %s\n' "$__ts" "$msg" >>"$FL_LOG_FILE" 2>/dev/null || true
}

# fl_log_stamp_v VAR: HH:MM:SS now. One date at the first call, then the
# clock moves with $SECONDS (a fork per log line was 114 forks in one adopt).
FL_LOG_BASE=""
FL_LOG_SECONDS0=0
fl_log_stamp_v() {
  local __h __m __s __t
  if [[ -z "$FL_LOG_BASE" ]]; then
    read -r __h __m __s < <(date '+%H %M %S')
    FL_LOG_BASE=$((10#$__h * 3600 + 10#$__m * 60 + 10#$__s))
    FL_LOG_SECONDS0="$SECONDS"
  fi
  __t=$(((FL_LOG_BASE + SECONDS - FL_LOG_SECONDS0) % 86400))
  printf -v "$1" '%02d:%02d:%02d' $((__t / 3600)) $((__t % 3600 / 60)) $((__t % 60))
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

# fl_has_line TEXT LINE: LINE is a whole line of TEXT (grep -qxF), without a
# pipe. "producer | grep -q" fails under pipefail when grep quits on the first
# match and the producer then gets SIGPIPE (141), so capture the output first.
fl_has_line() {
  case $'\n'"$1"$'\n' in
    *$'\n'"$2"$'\n'*) return 0 ;;
  esac
  return 1
}

# a word for a POSIX shell, in single quotes
fl_sq() { local q="'"; printf "'%s'" "${1//$q/$q\\$q$q}"; }

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
  # nothing to escape (almost every value): no substitutions, no loop
  if [[ "$__e" != *[\\\"$FL_JSON_CTRL]* ]]; then printf -v "$1" '%s' "$__e"; return 0; fi
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

# ---------------------------------------------------------------- the fields of every done

# Every command that changes things ends with the same fields, in its done
# line (a stream) or added to its one document (docs/json-schema.md, "Rules
# for readers"): exit, changed[], warnings[], next_actions[] and state_after.
# They are collected as the run goes: fl_warn lines, fl_fix lines, and the
# fl_changed calls of the code that changed something.
FL_LAST_PROBLEM=""
FL_DONE_WARNINGS=""
FL_DONE_WARNINGS_N=0
FL_DONE_CHANGED=""
FL_DONE_NEXT=""
FL_DONE_NEXT_N=0

# fl_done_warning_add TEXT: one [WARN] line of the run (at most 50, 500 characters each)
fl_done_warning_add() {
  [[ "$FL_DONE_WARNINGS_N" -lt 50 ]] || return 0
  FL_DONE_WARNINGS_N=$((FL_DONE_WARNINGS_N + 1))
  FL_DONE_WARNINGS="${FL_DONE_WARNINGS}${FL_DONE_WARNINGS:+,}$(fl_json_str "${1:0:500}")"
}

# A fix built by fl_fix_cmd (every word shell quoted, one plain command, an optional `cd DIR &&` before
# it) starts with FL_FIXQ, so the code that prints or serializes it knows its words. The mark is the only
# thing that lets an agent run the fix as an argv array (the MCP server returns fix_argv for no other fix):
# a fix written as prose or with an unquoted path says nothing a program can rely on. The mark never
# reaches the output: fl_fix_plain_v takes it off, and fl_json_escape_v drops it as a control character.
# (\034, not \036: the parallel doctor jobs (doctor.sh) end each row they write with \036)
FL_FIXQ=$'\034'

# fl_fix_cmd WORD...: the fix command for WORDs, each quoted with printf %q (a bench path with a space or
# an apostrophe, an app or branch name), marked as quoted. A word that is exactly && stays an operator.
# No ~ and no $ in a word that should expand: a quoted word never expands. A note for a person goes after
# it, three spaces and in parentheses: "$(fl_fix_cmd benchbar up)   (then open the site)".
fl_fix_cmd() {
  local __w __o="$FL_FIXQ" __sep=""
  for __w in "$@"; do
    if [[ "$__w" == "&&" ]]; then __o="${__o}${__sep}&&"; else __o="${__o}${__sep}$(printf '%q' "$__w")"; fi
    __sep=" "
  done
  printf '%s' "$__o"
}

# fl_fix_marked TEXT: whether TEXT is a fix from fl_fix_cmd
fl_fix_marked() { [[ "${1:0:1}" == "$FL_FIXQ" ]]; }

# fl_fix_plain_v VAR TEXT: TEXT without the mark
fl_fix_plain_v() {
  local __t="$2"
  if [[ "${__t:0:1}" == "$FL_FIXQ" ]]; then __t="${__t:1}"; fi
  printf -v "$1" '%s' "$__t"
}

# fl_fix_quoted_json FIX: true when FIX is a marked fix, else false
fl_fix_quoted_json() { if fl_fix_marked "$1"; then printf true; else printf false; fi; }

# fl_next_action COMMAND [WHY]: a fix line or next step, as {"command","why"}; "quoted":true when COMMAND
# came from fl_fix_cmd (and is not cut, which could end it inside a quote)
fl_next_action() {
  [[ "$FL_DONE_NEXT_N" -lt 20 ]] || return 0
  FL_DONE_NEXT_N=$((FL_DONE_NEXT_N + 1))
  local __c __q=""
  fl_fix_plain_v __c "$1"
  if fl_fix_marked "$1" && [[ "${#__c}" -le 500 ]]; then __q=',"quoted":true'; fi
  FL_DONE_NEXT="${FL_DONE_NEXT}${FL_DONE_NEXT:+,}{\"command\":$(fl_json_str "${__c:0:500}"),\"why\":$(fl_json_str "${2:0:500}")${__q}}"
}

# fl_done_mark_v VAR: where warnings[] and next_actions[] stand now, for fl_done_forget
fl_done_mark_v() {
  printf -v "$1" '%s %s %s %s' "$FL_DONE_WARNINGS_N" "${#FL_DONE_WARNINGS}" "$FL_DONE_NEXT_N" "${#FL_DONE_NEXT}"
}

# fl_done_forget FROM TO: drops the warnings and next actions collected between
# two marks (a check print that a later one replaces, the repair engine's plan
# after its verify pass); what came before FROM and after TO stays
fl_done_forget() {
  local fwn fwl fxn fxl twn twl txn txl head tail
  read -r fwn fwl fxn fxl <<<"$1"
  read -r twn twl txn txl <<<"$2"
  head="${FL_DONE_WARNINGS:0:$fwl}"; tail="${FL_DONE_WARNINGS:$twl}"; tail="${tail#,}"
  FL_DONE_WARNINGS="${head}${head:+${tail:+,}}${tail}"
  FL_DONE_WARNINGS_N=$((fwn + FL_DONE_WARNINGS_N - twn))
  head="${FL_DONE_NEXT:0:$fxl}"; tail="${FL_DONE_NEXT:$txl}"; tail="${tail#,}"
  FL_DONE_NEXT="${head}${head:+${tail:+,}}${tail}"
  FL_DONE_NEXT_N=$((fxn + FL_DONE_NEXT_N - txn))
}

# fl_changed KIND NAME [DETAIL]: something this run changed. KIND is site,
# app, service, ports, hosts, backup or process. Not recorded in a dry run.
fl_changed() {
  [[ "${FL_DRY_RUN:-0}" != "1" ]] || return 0
  # a phase script is a child process: it hands its changes to the parent through
  # the file FL_CHANGED_FILE names (install), which fl_changed_fold reads
  if [[ -n "${FL_CHANGED_FILE:-}" && "${FL_CHANGED_OWNER:-}" != "$$" ]]; then
    printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >>"$FL_CHANGED_FILE" 2>/dev/null || true
    return 0
  fi
  FL_DONE_CHANGED="${FL_DONE_CHANGED}${FL_DONE_CHANGED:+,}{\"kind\":\"$1\",\"name\":$(fl_json_str "$2"),\"detail\":$(fl_json_str "${3:-}")}"
}

# fl_changed_fold: what the children recorded joins changed[] (once)
fl_changed_fold() {
  local kind name detail
  [[ -n "${FL_CHANGED_FILE:-}" && "${FL_CHANGED_OWNER:-}" == "$$" && -s "$FL_CHANGED_FILE" ]] || return 0
  while IFS=$'\t' read -r kind name detail; do
    [[ -n "$kind" ]] || continue
    FL_DONE_CHANGED="${FL_DONE_CHANGED}${FL_DONE_CHANGED:+,}{\"kind\":\"${kind}\",\"name\":$(fl_json_str "$name"),\"detail\":$(fl_json_str "$detail")}"
  done <"$FL_CHANGED_FILE"
  : >"$FL_CHANGED_FILE"
}

# fl_done_fields_v VAR [CODE]: `"exit":N,"changed":[..],"warnings":[..],"next_actions":[..],"state_after":{..}`
# (without CODE: no exit, for a done line that has its own)
fl_done_fields_v() {
  local __f="" __tail
  [[ -z "${2:-}" ]] || __f="\"exit\":${2},"
  [[ -z "$FL_ERROR_ID" ]] || __f="${__f}\"error_id\":\"${FL_ERROR_ID}\","
  [[ -z "$FL_NEED_MISSING_JSON" ]] || __f="${__f}\"missing\":[${FL_NEED_MISSING_JSON}],"
  fl_changed_fold
  fl_done_tail_v __tail
  printf -v "$1" '%s"changed":[%s],"warnings":[%s],%s' "$__f" "$FL_DONE_CHANGED" "$FL_DONE_WARNINGS" "$__tail"
}

# fl_done_tail_v VAR: `"next_actions":[..],"state_after":{..}`, for a done that has its
# own changed and warnings (pull). state_after is null in a dry run: nothing changed.
fl_done_tail_v() {
  local __after="null"
  if [[ "${FL_DRY_RUN:-0}" != "1" && "${FL_DONE_NO_BENCH:-0}" != "1" && "${FL_DONE_NO_STATE:-0}" != "1" ]] && declare -F fl_state_after_v >/dev/null; then fl_state_after_v __after; fi
  printf -v "$1" '"next_actions":[%s],"state_after":%s' "$FL_DONE_NEXT" "$__after"
}

# fl_json_doc_begin: a command with a one document --json keeps the document
# on fd 3 (the real stdout) and every line of text on stderr. Under --jsonl
# the stream is open already (benchbar, fl_jsonl_begin_generic).
fl_json_doc_begin() {
  [[ "${FL_JSONL:-0}" != "1" ]] || return 0
  exec 3>&1 1>&2
  FL_PLAIN=1; fl_ui_init
}

# fl_doc_emit CODE DOC [plan]: the end of a command with a one document
# --json. DOC is the document on one line (schema_version and cli_version
# first). Under --json it is printed with the done fields added (a plan:
# as it is); under --jsonl a plan becomes the plan line, a result is kept
# for the done line, which merges it with the done fields.
FL_DOC=""
fl_doc_emit() {
  local code="$1" doc="$2" kind="${3:-result}" f
  if [[ "${FL_JSONL:-0}" == "1" ]]; then
    if [[ "$kind" == "plan" ]]; then
      fl_jsonl plan ",$(fl_doc_rest "$doc")"
      FL_JSONL_PLAN_SENT=1
      [[ "${FL_DRY_RUN:-0}" != "1" ]] || FL_JSONL_QUIET=1
    else
      FL_DOC="$doc"
    fi
    return 0
  fi
  if [[ "$kind" == "plan" ]]; then printf '%s\n' "$doc" >&3; return 0; fi
  fl_done_fields_v f "$code"
  printf '%s,%s}\n' "${doc%\}}" "$f" >&3
}

# fl_doc_rest DOC: the fields after schema_version and cli_version, without braces
fl_doc_rest() {
  local r="${1#\{\"schema_version\":*,\"cli_version\":\"*\",}"
  printf '%s' "${r%\}}"
}

# fl_jsonl_progress LABEL ELAPSED: a progress line for the step that runs
# now; the size of the file in FL_PROGRESS_FILE is the bytes of a download
fl_jsonl_progress() {
  [[ "$FL_JSONL" == "1" ]] || return 0
  local bytes=""
  if [[ -n "${FL_PROGRESS_FILE:-}" && -f "$FL_PROGRESS_FILE" ]]; then
    bytes="$(stat -c %s "$FL_PROGRESS_FILE" 2>/dev/null || stat -f %z "$FL_PROGRESS_FILE" 2>/dev/null || true)"
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
  if [[ "$FL_JSONL_SEC_WARN" == "1" ]]; then fl_jsonl_section_end warning; else fl_jsonl_section_end "done"; fi
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
    0) fl_jsonl_section_end "done" ;;
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
  case "$label" in
    WARN|FAIL) FL_JSONL_SEC_WARN=1; FL_LAST_PROBLEM="$msg" ;;
  esac
  [[ "$label" != "WARN" ]] || fl_done_warning_add "$msg"
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
  local __fx
  fl_fix_plain_v __fx "$1"
  fl_spinner_pause
  printf '     %sfix:%s %s\n' "$FL_CYAN" "$FL_RESET" "$__fx"
  fl_log "   fix: $__fx"
  fl_next_action "$1" "$FL_LAST_PROBLEM"
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
  # a command run with --json prints JSON on stdout and nothing else: its
  # refusal is text on stderr
  if [[ "${OPT_JSON:-0}" == "1" ]]; then exec 1>&2; fi
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
# FL_STEP_QUIET=1: the steps go to the stream and the log only, not to the
# terminal (up, down, restart, which print one line of their own)
FL_STEP_QUIET=0
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
  [[ "$FL_STEP_QUIET" == "1" ]] || printf '\n%s%s %d. %s%s\n' "$FL_BOLD" "$(fl_step_glyph running)" $((i + 1)) "${FL_STEP_LABELS[$i]}" "$FL_RESET"
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
  [[ "$FL_STEP_QUIET" == "1" ]] || printf '  %s %d. %s: %s%s %s(%s)%s\n' "$(fl_step_glyph "$status")" $((i + 1)) "${FL_STEP_LABELS[$i]}" "$status" "${detail:+ ($detail)}" "$FL_DIM" "$(fl_fmt_secs "$secs")" "$FL_RESET"
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

# BENCHBAR_NONINTERACTIVE=1 (benchbar mcp sets it for every CLI it starts,
# --for-agent sets it too): nothing can be asked. A command lists the inputs
# it needs up front (fl_need, then fl_need_check) and is refused before it
# takes the lock or touches a bench; fl_confirm, fl_ask and fl_ask_secret are
# the only places that prompt, and under the mode they stop naming the input
# instead of waiting, reading end of input as "no", or guessing a default.
fl_noninteractive() { [[ "${BENCHBAR_NONINTERACTIVE:-0}" == "1" ]]; }

# fl_person_env_ok NAME VALUE: the one test for "the app says a person is here". A command only a
# person runs (open-as on, open --as --print-url, lan-guard, share) is refused without a terminal;
# the Mac app has none and says so with BENCHBAR_SUDO=gui or BENCHBAR_NONINTERACTIVE=0, after its own
# alert. Any process can set those two, so on macOS the claim counts only when BENCHBAR_APP_PID names
# a process that is above this one in the process tree and runs a BenchBar.app binary (the app sets
# it for every run that makes the claim). Returns 0 when NAME is VALUE and the claim holds, 1
# otherwise; FL_PERSON_WHY then says why a claim that was made did not count, for the refusal.
# Only the paths above call it, and only without a terminal: nothing else pays for the walk.
# On Linux and WSL there is no such check: the Windows tray's process is not visible from inside WSL,
# so the variable is taken as it is. There, and on a Mac for a process that already runs inside the
# app's process tree, it is a safety rail against mistakes, not a boundary (AGENTS.md says so).
# FL_TESTING=1 reads FL_PERSON_SELF_PID (the pid the walk starts from) and FL_PS_CMD (a ps mock).
FL_PERSON_WHY=""
fl_person_env_ok() {
  local name="$1" want="$2" app="${BENCHBAR_APP_PID:-}" pid="$$" ps_cmd=/bin/ps line ppid comm hops=0 why
  FL_PERSON_WHY=""
  [[ "${!name:-}" == "$want" ]] || return 1
  fl_is_linux && return 0
  why="${name}=${want} counts only when the BenchBar app made the run, and"
  if [[ "${FL_TESTING:-}" == "1" ]]; then pid="${FL_PERSON_SELF_PID:-$$}"; ps_cmd="${FL_PS_CMD:-ps}"; fi
  if [[ -z "$app" ]]; then FL_PERSON_WHY="${why} BENCHBAR_APP_PID is not set."; return 1; fi
  if [[ ! "$app" =~ ^[1-9][0-9]{0,9}$ ]]; then FL_PERSON_WHY="${why} BENCHBAR_APP_PID is not a process id."; return 1; fi
  while [[ "$pid" =~ ^[1-9][0-9]*$ && "$hops" -lt 64 ]]; do
    line="$("$ps_cmd" -o ppid=,comm= -p "$pid" 2>/dev/null)" || line=""
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -n "$line" ]] || break
    ppid="${line%%[[:space:]]*}"
    comm="${line#"$ppid"}"; comm="${comm#"${comm%%[![:space:]]*}"}"
    if [[ "$pid" == "$app" ]]; then
      case "$comm" in
        */BenchBar.app/Contents/MacOS/?*) return 0 ;;
      esac
      FL_PERSON_WHY="${why} BENCHBAR_APP_PID=${app} is not a BenchBar.app process."
      return 1
    fi
    pid="$ppid"; hops=$((hops + 1))
  done
  # the app was not met on the way up: say whether it runs at all
  line="$("$ps_cmd" -o ppid=,comm= -p "$app" 2>/dev/null)" || line=""
  if [[ -n "${line//[[:space:]]/}" ]]; then FL_PERSON_WHY="${why} BENCHBAR_APP_PID=${app} is not above this command."
  else FL_PERSON_WHY="${why} BENCHBAR_APP_PID=${app} names no running process."; fi
  return 1
}

# fl_secrets_single_line NAME...: refuses, before any work, a password (the
# variable NAME holds it) that contains a line break. The sudo password
# travels on a pipe and the site's passwords on a standard input, one line
# each, so a second line would be cut off or read as the next answer. Only the
# name is printed, never the value.
fl_secrets_single_line() {
  local n
  for n in "$@"; do
    case "${!n:-}" in
      *$'\n'*)
        FL_ERROR_ID="password_has_newline"
        fl_die "${n} contains a line break, and a password is passed on one line only. Nothing was changed." \
          "Use a password without a line break in ${n} (a password you type or paste in a terminal never has one)." ;;
    esac
  done
}

FL_NEED_LIST=""
# the names alone, as JSON strings: the "missing" field of the refusal
FL_NEED_JSON=""
FL_NEED_MISSING_JSON=""
# fl_need INPUT WHY: the run cannot go on without INPUT (an environment
# variable, a flag, sudo); the caller has already seen it is missing
fl_need() {
  FL_NEED_LIST="${FL_NEED_LIST}${FL_NEED_LIST:+; }$1 ($2)"
  FL_NEED_JSON="${FL_NEED_JSON}${FL_NEED_JSON:+,}$(fl_json_str "$1")"
}
# fl_need_check [always]: refuses once, naming everything fl_need collected, in
# the non interactive mode (or with "always": nothing can be asked here whatever the mode).
# Exit 1, or 2 when the MariaDB root password is among them (AGENTS.md). A stream
# ends with its done line (error, missing); a command with one document under
# --json prints that document with exit and error; else the text, as fl_die.
fl_need_check() {
  local list="$FL_NEED_LIST" names="$FL_NEED_JSON" why="BENCHBAR_NONINTERACTIVE=1: nothing can be asked" code=1 msg f
  FL_NEED_LIST=""; FL_NEED_JSON=""
  [[ -n "$list" ]] || return 0
  [[ "${1:-}" == "always" ]] && why="no terminal to ask in"
  [[ "${1:-}" == "always" ]] || fl_noninteractive || return 0
  case "$names" in *'"MARIADB_ROOT_PASSWORD"'*) code=2 ;; esac
  msg="Cannot start, missing: ${list}."
  FL_NEED_MISSING_JSON="$names"
  if [[ "${FL_JSONL:-0}" == "1" ]]; then
    # the done line comes from the exit trap; no status is computed for a refusal
    FL_DIE_MESSAGE="$msg"
    FL_DONE_NO_STATE=1
    fl_log "ABORT: ${msg}"
    printf '[FAIL] %s\n' "$msg" >&2
    exit "$code"
  fi
  if [[ "${OPT_JSON:-0}" == "1" ]]; then
    printf '%s %s\n' "$msg" "${why}; pass them and run the command again. Nothing was changed." >&2
    FL_DONE_NO_BENCH=1; FL_DONE_NO_STATE=1
    fl_done_fields_v f "$code"
    printf '{"schema_version":%d,"cli_version":"%s",%s,"error":%s}\n' "${FL_SCHEMA_VERSION:-1}" "${FL_VERSION:-0}" "$f" "$(fl_json_str "$msg")"
    exit "$code"
  fi
  fl_die "$msg" "${why}; pass them (flags before the command's arguments, secrets in the environment) and run the command again. Nothing was changed." "$code"
}

fl_confirm() {
  local prompt="$1" answer
  fl_spinner_pause
  if [[ "${FL_ASSUME_YES:-0}" == "1" ]]; then
    fl_info "auto-confirmed: ${prompt}"
    return 0
  fi
  if fl_noninteractive; then
    fl_die "'${prompt}' needs an answer, and BENCHBAR_NONINTERACTIVE=1 says nothing can ask; pass --yes to confirm it." "Pass --yes to confirm it, or run without the mode in a terminal."
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
  if fl_noninteractive; then
    fl_die "Cannot ask for ${__varname}: BENCHBAR_NONINTERACTIVE=1 says nothing can ask." \
      "Pass it in the environment (${__varname}='...' before the command)"
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
  if fl_noninteractive; then
    fl_die "Cannot ask for ${__varname}: BENCHBAR_NONINTERACTIVE=1 says nothing can ask." \
      "Pass it in the environment (${__varname}='...' before the command)"
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

# what one doctor run reads once (fl_memo, fl_memo_v, the background jobs);
# loaded here because every lib file and phase script that may ask for it has ui.sh
# shellcheck source=lib/frappe-local/facts.sh
. "${BASH_SOURCE[0]%/*}/facts.sh"
