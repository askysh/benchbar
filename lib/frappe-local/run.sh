#!/usr/bin/env bash
#
# run.sh: command execution helpers (dry-run, timeouts, long commands).

FL_DRY_RUN="${FL_DRY_RUN:-0}"
FL_LAST_COMMAND=""

fl_require_cmd() {
  local cmd="$1" hint="${2:-}"
  command -v "$cmd" >/dev/null 2>&1 || fl_die "Required command '$cmd' not found." "${hint:-Install it and re-run.}"
}

fl_run() {
  FL_LAST_COMMAND="$*"
  if [[ "$FL_DRY_RUN" == "1" ]]; then
    fl_info "dry-run: $*"
    return 0
  fi
  fl_log "run: $*"
  "$@"
}

# fl_run_long LABEL COMMAND...: runs a slow command with a spinner and a
# rolling tail of its output. On failure prints the last 40 lines and the
# path of the full log.
fl_run_long() {
  local label="$1" log pid code=0 start
  shift
  FL_LAST_COMMAND="$*"
  FL_LAST_COMMAND="${FL_LAST_COMMAND#fl_in_bench }"
  if [[ "$FL_DRY_RUN" == "1" ]]; then
    fl_info "dry-run: ${FL_LAST_COMMAND}"
    return 0
  fi
  log="$(mktemp "${TMPDIR:-/tmp}/benchbar-cmd.XXXXXX")"
  fl_log "run: $* (log follows)"
  start="$SECONDS"
  "$@" </dev/null >"$log" 2>&1 &
  pid="$!"
  fl_spinner_start "$label" "$log"
  wait "$pid" || code="$?"
  fl_spinner_stop
  fl_log_file_append "$log"
  if [[ "$code" -ne 0 ]]; then
    fl_fail "${label} failed with exit code ${code} after $(fl_fmt_secs $((SECONDS - start)))"
    fl_note "last 40 lines:"
    tail -n 40 "$log" | sed 's/^/     /'
    if [[ -n "$FL_LOG_FILE" ]]; then fl_note "full log: ${FL_LOG_FILE}"; fi
    fl_note "command: ${FL_LAST_COMMAND}"
  else
    fl_ok "${label} ($(fl_fmt_secs $((SECONDS - start))))"
  fi
  rm -f "$log"
  return "$code"
}

fl_run_with_timeout() {
  local timeout_seconds="$1" label="$2" log pid start elapsed code state
  shift 2
  FL_LAST_COMMAND="$*"
  if [[ "$FL_DRY_RUN" == "1" ]]; then
    fl_info "dry-run: $*"
    return 0
  fi
  if [[ "$timeout_seconds" -le 0 ]]; then
    "$@"
    return $?
  fi

  log="$(mktemp "${TMPDIR:-/tmp}/frappe-local-command.XXXXXX")"
  fl_log "run: $* (timeout ${timeout_seconds}s)"
  "$@" </dev/null >"$log" 2>&1 &
  pid="$!"
  start="$SECONDS"
  fl_spinner_start "$label" "$log"

  while kill -0 "$pid" >/dev/null 2>&1; do
    state="$(ps -o state= -p "$pid" 2>/dev/null | awk '{print $1}')"
    if [[ "$state" == T* ]]; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      fl_spinner_stop
      fl_fail "${label} stopped while waiting for input."
      fl_info "Run the command manually if it needs an interactive answer: ${FL_LAST_COMMAND}"
      fl_log_file_append "$log"
      rm -f "$log"
      return 125
    fi

    elapsed=$((SECONDS - start))
    if [[ "$elapsed" -ge "$timeout_seconds" ]]; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      fl_spinner_stop
      fl_fail "${label} timed out after ${timeout_seconds}s."
      if [[ -s "$log" ]]; then
        fl_info "Last output:"
        tail -n 40 "$log" | sed 's/^/     /' || true
      fi
      fl_log_file_append "$log"
      rm -f "$log"
      return 124
    fi
    sleep 1
  done

  code=0
  wait "$pid" || code="$?"
  fl_spinner_stop
  fl_log_file_append "$log"
  if [[ "$code" -ne 0 && -s "$log" ]]; then
    fl_fail "${label} failed with exit code ${code}"
    tail -n 40 "$log" | sed 's/^/     /'
    if [[ -n "$FL_LOG_FILE" ]]; then fl_note "full log: ${FL_LOG_FILE}"; fi
  elif [[ "$code" -eq 0 ]]; then
    fl_ok "${label} ($(fl_fmt_secs $((SECONDS - start))))"
  fi
  rm -f "$log"
  return "$code"
}

fl_capture() {
  FL_LAST_COMMAND="$*"
  "$@"
}

fl_retry() {
  local attempts="$1" delay="$2"; shift 2
  local i=1
  while true; do
    "$@" && return 0
    [[ "$i" -ge "$attempts" ]] && return 1
    fl_warn "command failed; retry ${i}/${attempts}: $*"
    sleep "$delay"
    i=$((i + 1))
  done
}

fl_on_error() {
  local code="$?"
  [[ "$code" -eq 0 ]] && return 0
  fl_spinner_stop
  fl_fail "Last command failed with exit code ${code}: ${FL_LAST_COMMAND:-unknown}"
  if [[ -n "${FL_LOG_FILE:-}" ]]; then fl_note "full log: ${FL_LOG_FILE}"; fi
  exit "$code"
}
