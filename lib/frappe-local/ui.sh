#!/usr/bin/env bash
#
# ui.sh: terminal output for benchbar.
#
# Colors come from tput and are disabled when stdout is not a TTY, when
# NO_COLOR is set, or when FL_PLAIN=1. Every status line is also appended
# to the run log (FL_LOG_FILE) as plain text so the log stays greppable.
#
# Compatible with macOS /bin/bash 3.2: no associative arrays, no mapfile.

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

fl_log_init() {
  local dir="$1" stamp
  [[ "${FL_DRY_RUN:-0}" == "1" ]] && return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  stamp="$(date +%Y%m%d-%H%M%S)"
  FL_LOG_FILE="${dir}/${stamp}.log"
  : >"$FL_LOG_FILE" 2>/dev/null || FL_LOG_FILE=""
  # the phase scripts are child processes: they log to the same file
  export FL_LOG_FILE
}

fl_log() {
  [[ -n "$FL_LOG_FILE" ]] || return 0
  printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >>"$FL_LOG_FILE" 2>/dev/null || true
}

fl_log_file_append() {
  [[ -n "$FL_LOG_FILE" && -f "$1" ]] || return 0
  cat "$1" >>"$FL_LOG_FILE" 2>/dev/null || true
}

fl_strip_ansi() {
  sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\x1b([AB]//g'
}

# ---------------------------------------------------------------- status lines

fl_section() {
  fl_spinner_pause
  printf '\n%s%s %s%s\n' "$FL_BOLD$FL_BLUE" "==========" "$1 ==========" "$FL_RESET"
  fl_log "== $1 =="
}

fl_status_line() {
  local color="$1" label="$2" msg="$3"
  fl_spinner_pause
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

fl_die() {
  fl_spinner_stop
  fl_fail "$1"
  printf '\n%sAborting.%s %s\n' "$FL_RED$FL_BOLD" "$FL_RESET" "${2:-Fix the above and re-run.}"
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

fl_steps_reset() { FL_STEP_LABELS=(); FL_STEP_STATUS=(); FL_STEP_SECS=(); FL_STEP_CURRENT=-1; FL_RUN_START="$SECONDS"; }

fl_steps_define() {
  local label
  fl_steps_reset
  for label in "$@"; do
    FL_STEP_LABELS+=("$label"); FL_STEP_STATUS+=("pending"); FL_STEP_SECS+=("0")
  done
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

# fl_step_begin INDEX: announces a step whose output streams to the terminal.
fl_step_begin() {
  local i="$1"
  FL_STEP_CURRENT="$i"
  FL_STEP_START="$SECONDS"
  FL_STEP_STATUS[i]="running"
  fl_spinner_pause
  printf '\n%s%s %d. %s%s\n' "$FL_BOLD" "$(fl_step_glyph running)" $((i + 1)) "${FL_STEP_LABELS[$i]}" "$FL_RESET"
  fl_log "step $((i + 1)) start: ${FL_STEP_LABELS[$i]}"
}

# fl_step_end STATUS [DETAIL]
fl_step_end() {
  local status="$1" detail="${2:-}" i="$FL_STEP_CURRENT" secs
  [[ "$i" -ge 0 ]] || return 0
  secs=$((SECONDS - FL_STEP_START))
  FL_STEP_STATUS[i]="$status"
  FL_STEP_SECS[i]="$secs"
  fl_spinner_pause
  printf '  %s %d. %s: %s%s %s(%s)%s\n' "$(fl_step_glyph "$status")" $((i + 1)) "${FL_STEP_LABELS[$i]}" "$status" "${detail:+ ($detail)}" "$FL_DIM" "$(fl_fmt_secs "$secs")" "$FL_RESET"
  fl_log "step $((i + 1)) $status ${detail} ($(fl_fmt_secs "$secs"))"
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
  fl_spinner_start "$((i + 1)). $label" "$out"
  "$fn" "$@" >"$out" 2>&1 || code=$?
  fl_spinner_stop
  fl_log_file_append "$out"
  if [[ "$code" -ne 0 ]]; then
    fl_step_end failed
    tail -n 40 "$out" | sed 's/^/     /'
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
    fl_info "using env-provided ${__varname}=${!__varname}"
    return 0
  fi
  if [[ "$FL_TTY" == "1" ]] && command -v gum >/dev/null 2>&1; then
    __answer="$(gum input --prompt "  ${__prompt}: " --value "$__default" </dev/tty)" || __answer="$__default"
    printf -v "$__varname" '%s' "${__answer:-$__default}"
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
  while true; do
    read -r -s -p "  ${__prompt}: " __answer; printf '\n'
    [[ -n "$__answer" ]] || { fl_warn "empty value; retry"; continue; }
    read -r -s -p "  confirm ${__prompt}: " __confirm; printf '\n'
    [[ "$__answer" == "$__confirm" ]] && { printf -v "$__varname" '%s' "$__answer"; return 0; }
    fl_warn "values do not match; retry"
  done
}
