#!/usr/bin/env bash
#
# run.sh: command execution helpers (dry-run, timeouts, long commands).

FL_DRY_RUN="${FL_DRY_RUN:-0}"
FL_LAST_COMMAND=""
# the process group of the long or timed command that is running now (its
# leader's pid), so a timeout or a signal to benchbar reaches pip, yarn,
# git and every other grandchild, not only the top process
FL_RUN_PGID=""
# the foreground child benchbar is waiting for (a phase script): a signal
# to benchbar is forwarded to it, and it forwards to its own group
FL_RUN_CHILD_PID=""

# fl_run_bg_group LOG COMMAND...: starts COMMAND in the background as the
# leader of its own process group, output to LOG. bash 3.2 (macOS) has no
# setsid, so job control (set -m) does it: a background job started under
# job control gets a process group of its own. Sets FL_RUN_PID and
# FL_RUN_PGID.
fl_run_bg_group() {
  local log="$1"
  shift
  set -m
  "$@" </dev/null >"$log" 2>&1 &
  FL_RUN_PID="$!"
  set +m
  FL_RUN_PGID="$FL_RUN_PID"
}

# fl_run_group_stop SIGNAL: the signal to the whole group of the running
# command (falls back to the leader alone when the group is gone)
fl_run_group_stop() {
  [[ -n "$FL_RUN_PGID" ]] || return 0
  kill "-$1" -- "-${FL_RUN_PGID}" 2>/dev/null || kill "-$1" "$FL_RUN_PGID" 2>/dev/null || true
}

# fl_run_group_kill: TERM to the group, a second for it to go, then KILL;
# then the group is forgotten
fl_run_group_kill() {
  [[ -n "$FL_RUN_PGID" ]] || return 0
  fl_run_group_stop TERM
  sleep 1
  fl_run_group_stop KILL
  wait "$FL_RUN_PGID" 2>/dev/null || true
  FL_RUN_PGID=""
}

# fl_on_signal NAME: benchbar (or a phase script) got TERM, INT or HUP. The
# running command's group and the foreground child get the same signal, so
# nothing keeps writing into the bench after the run says it ended, and
# then the EXIT trap releases the lock (after, never before).
fl_on_signal() {
  local sig="$1" code=143
  case "$sig" in INT) code=130 ;; HUP) code=129 ;; esac
  trap - TERM INT HUP
  fl_spinner_stop 2>/dev/null || true
  # TERM to the child whatever came in: a background child of a shell
  # without job control has SIGINT ignored, so an INT would not reach it
  if [[ -n "$FL_RUN_CHILD_PID" ]]; then
    kill -TERM "$FL_RUN_CHILD_PID" 2>/dev/null || true
    wait "$FL_RUN_CHILD_PID" 2>/dev/null || true
    FL_RUN_CHILD_PID=""
  fi
  # a signal between the start of a command and FL_RUN_PGID being set: the
  # job table still knows the command, and its job is its own group
  if [[ -z "$FL_RUN_PGID" ]]; then
    local job
    for job in $(jobs -p 2>/dev/null); do
      kill -TERM -- "-${job}" 2>/dev/null || kill -TERM "$job" 2>/dev/null || true
    done
  fi
  fl_run_group_kill
  fl_log "stopped by SIG${sig}"
  exit "$code"
}

# fl_run_phase_script SCRIPT ARGS...: runs a phase script (install) as a
# child this shell waits for, so a signal to benchbar is forwarded to it
# (fl_on_signal) instead of leaving it running. The explicit <&0 keeps the
# terminal's stdin: a background job in a shell without job control gets
# /dev/null otherwise, and the script could not ask for a password.
fl_run_phase_script() {
  local script="$1" code=0
  shift
  fl_redact_url_v FL_LAST_COMMAND "${script} $*"
  fl_log "phase: ${script} $*"
  "$script" "$@" <&0 &
  FL_RUN_CHILD_PID="$!"
  wait "$FL_RUN_CHILD_PID" || code=$?
  FL_RUN_CHILD_PID=""
  return "$code"
}

fl_signal_traps_install() {
  trap 'fl_on_signal TERM' TERM
  trap 'fl_on_signal INT' INT
  trap 'fl_on_signal HUP' HUP
}

fl_require_cmd() {
  local cmd="$1" hint="${2:-}"
  command -v "$cmd" >/dev/null 2>&1 || fl_die "Required command '$cmd' not found." "${hint:-Install it and re-run.}"
}

# FL_LAST_COMMAND is what fl_on_error and the failure notes print: it is set
# with the credentials of any URL in the argv replaced (fl_redact_url_v), as
# are the "run:" lines fl_log writes.
fl_run() {
  fl_redact_url_v FL_LAST_COMMAND "$*"
  if [[ "$FL_DRY_RUN" == "1" ]]; then
    fl_info "dry-run: ${FL_LAST_COMMAND}"
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
  fl_redact_url_v FL_LAST_COMMAND "$*"
  FL_LAST_COMMAND="${FL_LAST_COMMAND#fl_in_bench }"
  if [[ "$FL_DRY_RUN" == "1" ]]; then
    fl_info "dry-run: ${FL_LAST_COMMAND}"
    return 0
  fi
  log="$(mktemp "${TMPDIR:-/tmp}/benchbar-cmd.XXXXXX")"
  fl_log "run: $* (log follows)"
  start="$SECONDS"
  fl_run_bg_group "$log" "$@"
  pid="$FL_RUN_PID"
  fl_spinner_start "$label" "$log"
  # in its own group the command cannot read the terminal: one that tries
  # (a password prompt) is stopped by SIGTTIN, and would wait for ever
  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$(ps -o state= -p "$pid" 2>/dev/null | awk '{print $1}')" == T* ]]; then
      fl_run_group_kill
      fl_spinner_stop
      fl_fail "${label} stopped while waiting for input."
      fl_info "Run the command manually if it needs an interactive answer: ${FL_LAST_COMMAND}"
      fl_log_file_append "$log"
      rm -f "$log"
      return 125
    fi
    sleep 1
  done
  wait "$pid" || code="$?"
  FL_RUN_PGID=""
  fl_spinner_stop
  fl_log_file_append "$log"
  if [[ "$code" -ne 0 ]]; then
    fl_fail "${label} failed with exit code ${code} after $(fl_fmt_secs $((SECONDS - start)))"
    fl_note "last 40 lines:"
    fl_tail_indented "$log"
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
  fl_redact_url_v FL_LAST_COMMAND "$*"
  if [[ "$FL_DRY_RUN" == "1" ]]; then
    fl_info "dry-run: ${FL_LAST_COMMAND}"
    return 0
  fi
  if [[ "$timeout_seconds" -le 0 ]]; then
    "$@"
    return $?
  fi

  log="$(mktemp "${TMPDIR:-/tmp}/frappe-local-command.XXXXXX")"
  fl_log "run: $* (timeout ${timeout_seconds}s)"
  fl_run_bg_group "$log" "$@"
  pid="$FL_RUN_PID"
  start="$SECONDS"
  fl_spinner_start "$label" "$log"

  while kill -0 "$pid" >/dev/null 2>&1; do
    state="$(ps -o state= -p "$pid" 2>/dev/null | awk '{print $1}')"
    if [[ "$state" == T* ]]; then
      # the whole group: the stopped process may be a grandchild's parent
      fl_run_group_kill
      fl_spinner_stop
      fl_fail "${label} stopped while waiting for input."
      fl_info "Run the command manually if it needs an interactive answer: ${FL_LAST_COMMAND}"
      fl_log_file_append "$log"
      rm -f "$log"
      return 125
    fi

    elapsed=$((SECONDS - start))
    if [[ "$elapsed" -ge "$timeout_seconds" ]]; then
      fl_run_group_kill
      fl_spinner_stop
      fl_fail "${label} timed out after ${timeout_seconds}s."
      if [[ -s "$log" ]]; then
        fl_info "Last output:"
        fl_tail_indented "$log" || true
      fi
      fl_log_file_append "$log"
      rm -f "$log"
      return 124
    fi
    sleep 1
  done

  code=0
  wait "$pid" || code="$?"
  FL_RUN_PGID=""
  fl_spinner_stop
  fl_log_file_append "$log"
  if [[ "$code" -ne 0 && -s "$log" ]]; then
    fl_fail "${label} failed with exit code ${code}"
    fl_tail_indented "$log"
    if [[ -n "$FL_LOG_FILE" ]]; then fl_note "full log: ${FL_LOG_FILE}"; fi
  elif [[ "$code" -eq 0 ]]; then
    fl_ok "${label} ($(fl_fmt_secs $((SECONDS - start))))"
  fi
  rm -f "$log"
  return "$code"
}

fl_capture() {
  fl_redact_url_v FL_LAST_COMMAND "$*"
  "$@"
}

fl_retry() {
  local attempts="$1" delay="$2"; shift 2
  local i=1
  while true; do
    "$@" && return 0
    [[ "$i" -ge "$attempts" ]] && return 1
    fl_warn "command failed; retry ${i}/${attempts}: $(fl_redact_url "$*")"
    sleep "$delay"
    i=$((i + 1))
  done
}

fl_on_error() {
  local code="$?"
  [[ "$code" -eq 0 ]] && return 0
  # exit code 2 means "the MariaDB root password is unknown" and only an
  # explicit fl_die ... 2 may produce it; a command that happened to exit 2
  # (grep, awk, a usage error) is an ordinary failure
  [[ "$code" -eq 2 ]] && code=1
  fl_spinner_stop
  # nothing to name: the command already said why it ended (a verify pass
  # with warnings), so a "[FAIL] Last command failed" line would only mislead
  if [[ -n "${FL_LAST_COMMAND:-}" ]]; then
    fl_fail "Last command failed with exit code ${code}: ${FL_LAST_COMMAND}"
    if [[ -n "${FL_LOG_FILE:-}" ]]; then fl_note "full log: ${FL_LOG_FILE}"; fi
  fi
  exit "$code"
}
