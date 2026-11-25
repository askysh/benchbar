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
# the wait loop of fl_run_long and fl_run_with_timeout: milliseconds of pauses
# so far, and the second of the last look at the command's state
FL_RUN_POLLED_MS=0
FL_RUN_STATE_AT=0

# fl_run_bg_group LOG COMMAND...: starts COMMAND in the background as the
# leader of its own process group, output to LOG (stderr too, unless
# FL_RUN_ERR_FILE names a file for it). bash 3.2 (macOS) has no setsid, so
# job control (set -m) does it: a background job started under job control
# gets a process group of its own. Sets FL_RUN_PID and FL_RUN_PGID. The
# command does not get fd 3, the JSON stream of install and adopt: bench,
# brew and npm must not write into it, and a daemon they start must not
# keep it open.
fl_run_bg_group() {
  local log="$1" err="${FL_RUN_ERR_FILE:-}"
  shift
  set -m
  # bash's parent side of the fork also calls setpgid and, when the child has
  # exec'd first, prints "child setpgid (N to N): Operation not permitted" on
  # its own stderr (the child already made the group, so it is harmless). The
  # group's stderr keeps the parent's quiet: the command's own output goes to
  # LOG or ERR below, never through it.
  {
    if [[ -n "$err" ]]; then
      "$@" </dev/null >"$log" 2>"$err" 3>&- &
    else
      "$@" </dev/null >"$log" 2>&1 3>&- &
    fi
  } 2>/dev/null
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

# fl_run_group_alive PGID: a process of the group is still running (a zombie
# the shell has not reaped yet is not: kill -0 would count it)
fl_run_group_alive() {
  ps -A -o pgid= -o stat= 2>/dev/null | awk -v g="$1" '$1 == g && $2 !~ /^Z/ { f = 1 } END { exit !f }'
}

# fl_run_group_kill: TERM to the group, then up to FL_KILL_GRACE seconds
# (default 10, tenths allowed as 0.3) for it to go, polled every tenth of a
# second and not a moment longer than the group needs; what is left gets KILL;
# then the group is forgotten. A Ctrl-C during brew, yarn or bench init gets
# the time those tools need to clean up behind them (a half written keg or
# node_modules is a repair for the next run). The wait is bounded by the clock
# as well as by the count: a loaded machine stretches each poll, never the grace.
fl_run_group_kill() {
  [[ -n "$FL_RUN_PGID" ]] || return 0
  local grace="${FL_KILL_GRACE:-10}" whole frac ticks waited=0 t0="$SECONDS"
  fl_run_group_stop TERM
  whole="${grace%%.*}"; frac=0
  case "$grace" in *.*) frac="${grace#*.}"; frac="${frac:0:1}" ;; esac
  [[ "$whole" =~ ^[0-9]+$ ]] || whole=0
  [[ "$frac" =~ ^[0-9]$ ]] || frac=0
  ticks=$((10#$whole * 10 + frac))
  while [[ "$waited" -lt "$ticks" ]] && fl_run_group_alive "$FL_RUN_PGID"; do
    sleep 0.1
    waited=$((waited + 1))
    [[ $((SECONDS - t0)) -le $((10#$whole + 1)) ]] || break
  done
  if fl_run_group_alive "$FL_RUN_PGID"; then fl_run_group_stop KILL; fi
  wait "$FL_RUN_PGID" || true
  FL_RUN_PGID=""
} 2>/dev/null # the shell reports a command a signal ended ("Terminated: 15") on its own stderr

# Background jobs a command runs side by side with the shell (the profile
# check pool): their pids are in FL_BG_PIDS, so a signal to benchbar can stop
# them too. A job is a subshell that stops its own process group on TERM
# (fl_bg_job_stop); FL_BG_DIR is the temp folder the pool leaves behind.
FL_BG_PIDS=()
FL_BG_DIR=""

# fl_bg_job_stop: the TERM trap of a background job's subshell: its running
# command's group goes down with it (the job table knows a command that
# FL_RUN_PGID was not set for yet). Later TERM, INT and HUP are ignored while
# it works: benchbar sends a job TERM twice (fl_on_signal, then
# fl_bg_stop_all) and a terminal's INT comes on top, and a second signal under
# the default action ended the job before its git group was stopped.
fl_bg_job_stop() {
  local job
  trap '' TERM INT HUP
  for job in $(jobs -p 2>/dev/null); do
    kill -TERM -- "-${job}" 2>/dev/null || kill -TERM "$job" 2>/dev/null || true
  done
  fl_run_group_kill
  exit 143
}

# fl_bg_stop_all: TERM to every registered background job and wait for it
# (each one has stopped its own group by then), then drop its temp folder
fl_bg_stop_all() {
  local p
  for p in ${FL_BG_PIDS[@]+"${FL_BG_PIDS[@]}"}; do kill -TERM "$p" 2>/dev/null || true; done
  for p in ${FL_BG_PIDS[@]+"${FL_BG_PIDS[@]}"}; do wait "$p" 2>/dev/null || true; done
  FL_BG_PIDS=()
  [[ -z "$FL_BG_DIR" ]] || rm -rf "$FL_BG_DIR"
  FL_BG_DIR=""
}

# fl_tmp_new_v VAR PREFIX: a temp file for this run, removed by the exit trap
# (fl_tmp_cleanup) however the run ends, a signal included
FL_TMP_FILES=()
fl_tmp_new_v() {
  local __f
  __f="$(mktemp "${TMPDIR:-/tmp}/${2}.XXXXXX")" || return 1
  FL_TMP_FILES+=("$__f")
  printf -v "$1" '%s' "$__f"
}

# fl_tmp_done FILE: removes a temp file the run made and forgets it
fl_tmp_done() {
  local f="$1" i
  rm -f "$f"
  [[ "${#FL_TMP_FILES[@]}" -gt 0 ]] || return 0
  for i in "${!FL_TMP_FILES[@]}"; do
    [[ "${FL_TMP_FILES[$i]}" != "$f" ]] || unset "FL_TMP_FILES[$i]"
  done
  return 0
}

fl_tmp_cleanup() {
  local f
  for f in ${FL_TMP_FILES[@]+"${FL_TMP_FILES[@]}"}; do rm -f "$f"; done
  FL_TMP_FILES=()
}

# fl_on_signal NAME: benchbar (or a phase script) got TERM, INT or HUP. The
# running command's group and the foreground child get the same signal, so
# nothing keeps writing into the bench after the run says it ended, and
# then the EXIT trap releases the lock (after, never before).
fl_on_signal() {
  local sig="$1" code=143
  # a background job of a doctor run is forked and its pid not kept yet: the
  # signal waits for that (fl_par_group_off sends it again), so no job is missed
  if [[ -n "${FL_PAR_STARTING:-}" ]]; then FL_SIG_DEFERRED="$sig"; return 0; fi
  case "$sig" in INT) code=130 ;; HUP) code=129 ;; esac
  trap - TERM INT HUP
  fl_spinner_stop 2>/dev/null || true
  # the background jobs of a doctor run (facts.sh): each is a group of its own,
  # stopped and waited for here, quietly, before anything else is printed
  if declare -F fl_par_stop >/dev/null; then fl_par_stop; fi
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
  fl_bg_stop_all
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
  # BENCHBAR_SUDO=env: the one script that runs sudo reads the password once
  # from fd 8 (sudo-env.sh); it is never in its environment or its arguments
  case "$script" in
    */00-linux-system-deps.sh)
      if fl_sudo_env_has_password; then
        FL_SUDO_PW_FD=8 "$script" "$@" <&0 8< <(fl__sudo_env_emit) &
      else
        "$script" "$@" <&0 &
      fi ;;
    *) "$script" "$@" <&0 & ;;
  esac
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

# fl_run_poll_pause: the pause between two looks at a running command, in
# FL_RUN_POLLED_MS (the caller sets it to 0 before its loop). A command that
# ends at once is seen within 20 ms and one of a few seconds within 100 ms; a
# long one is polled twice a second. A fixed "sleep 1" made every command
# cost a full second however short it was (40 percent of the mocked suite's
# pull and app tests, and up to a second per bench command for a person).
fl_run_poll_pause() {
  if [[ "$FL_RUN_POLLED_MS" -lt 100 ]]; then sleep 0.02; FL_RUN_POLLED_MS=$((FL_RUN_POLLED_MS + 20))
  elif [[ "$FL_RUN_POLLED_MS" -lt 3000 ]]; then sleep 0.1; FL_RUN_POLLED_MS=$((FL_RUN_POLLED_MS + 100))
  else sleep 0.5; FL_RUN_POLLED_MS=$((FL_RUN_POLLED_MS + 500)); fi
}

# fl_run_stopped PID: the command waits for the terminal (state T). Asked at
# most once a second (FL_RUN_STATE_AT holds the second of the last look, the
# caller sets it to $SECONDS before its loop), so the quick polls above start
# no ps, and a command that ends within its first second starts none at all.
fl_run_stopped() {
  local state
  [[ "$SECONDS" != "$FL_RUN_STATE_AT" ]] || return 1
  FL_RUN_STATE_AT="$SECONDS"
  state="$(ps -o state= -p "$1" 2>/dev/null)" || return 1
  state="${state#"${state%%[![:space:]]*}"}"
  [[ "$state" == T* ]]
}

# fl_run_long LABEL COMMAND...: runs a slow command with a spinner and a
# rolling tail of its output. On failure prints the last 40 lines and the
# path of the full log.
fl_run_long() {
  local label="$1" log pid code=0 start last_progress
  shift
  fl_redact_url_v FL_LAST_COMMAND "$*"
  FL_LAST_COMMAND="${FL_LAST_COMMAND#fl_in_bench }"
  if [[ "$FL_DRY_RUN" == "1" ]]; then
    fl_info "dry-run: ${FL_LAST_COMMAND}"
    return 0
  fi
  fl_tmp_new_v log benchbar-cmd
  fl_log "run: $* (log follows)"
  start="$SECONDS"
  last_progress="$SECONDS"
  fl_run_bg_group "$log" "$@"
  pid="$FL_RUN_PID"
  fl_spinner_start "$label" "$log"
  # in its own group the command cannot read the terminal: one that tries
  # (a password prompt) is stopped by SIGTTIN, and would wait for ever
  FL_RUN_POLLED_MS=0; FL_RUN_STATE_AT="$SECONDS"
  while kill -0 "$pid" 2>/dev/null; do
    if fl_run_stopped "$pid"; then
      fl_run_group_kill
      fl_spinner_stop
      fl_fail "${label} stopped while waiting for input."
      fl_info "Run the command manually if it needs an interactive answer: ${FL_LAST_COMMAND}"
      fl_log_file_append "$log"
      fl_tmp_done "$log"
      return 125
    fi
    # a progress line for the JSON stream every FL_PROGRESS_SECS (10)
    if [[ "$FL_JSONL" == "1" && $((SECONDS - last_progress)) -ge "${FL_PROGRESS_SECS:-10}" ]]; then
      last_progress="$SECONDS"
      fl_jsonl_progress "$label" $((SECONDS - start))
    fi
    fl_run_poll_pause
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
  fl_tmp_done "$log"
  return "$code"
}

# fl_run_with_timeout SECS LABEL COMMAND...: like fl_run_long with a deadline
# (exit 124 at the deadline) and the same progress line for the JSON stream
# every FL_PROGRESS_SECS, so a long bench init is not silent there.
fl_run_with_timeout() {
  local timeout_seconds="$1" label="$2" log pid start elapsed code last_progress
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

  fl_tmp_new_v log benchbar-cmd
  fl_log "run: $* (timeout ${timeout_seconds}s)"
  fl_run_bg_group "$log" "$@"
  pid="$FL_RUN_PID"
  start="$SECONDS"
  last_progress="$SECONDS"
  fl_spinner_start "$label" "$log"

  FL_RUN_POLLED_MS=0; FL_RUN_STATE_AT="$SECONDS"
  while kill -0 "$pid" >/dev/null 2>&1; do
    if fl_run_stopped "$pid"; then
      # the whole group: the stopped process may be a grandchild's parent
      fl_run_group_kill
      fl_spinner_stop
      fl_fail "${label} stopped while waiting for input."
      fl_info "Run the command manually if it needs an interactive answer: ${FL_LAST_COMMAND}"
      fl_log_file_append "$log"
      fl_tmp_done "$log"
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
      fl_tmp_done "$log"
      return 124
    fi
    if [[ "$FL_JSONL" == "1" && $((SECONDS - last_progress)) -ge "${FL_PROGRESS_SECS:-10}" ]]; then
      last_progress="$SECONDS"
      fl_jsonl_progress "$label" "$elapsed"
    fi
    fl_run_poll_pause
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
  fl_tmp_done "$log"
  return "$code"
}

# fl_run_capture_timeout SECS OUT ERR COMMAND...: COMMAND with stdin closed,
# stdout to OUT and stderr to ERR, in a process group of its own. At the
# deadline the whole group gets TERM, then KILL after FL_KILL_GRACE
# (fl_run_group_kill), so neither a child nor a command that ignores TERM
# runs on; exit 124. FL_RUN_PGID is put back afterwards: a signal that
# arrives later still reaches the right group.
# The deadline is the clock's, not a count of polls: a command that is still
# running after its first 20 ms poll gets a `sleep` of the rest as its timer,
# because a poll that a loaded machine stretches from 100 ms to 400 ms would
# stretch the deadline with it (the first CI run of this took 4 s for 1 s).
# A command that ends within that poll starts no timer.
fl_run_capture_timeout() {
  local secs="$1" out="$2" saved_pgid="$FL_RUN_PGID" pid waited=0 code=0 timer="" left expired=0
  local FL_RUN_ERR_FILE="$3"
  shift 3
  FL_RUN_PGID=""
  fl_run_bg_group "$out" "$@"
  pid="$FL_RUN_PID"
  # a quick command is noticed within 20 ms; a slow one is polled every 100 ms
  while kill -0 "$pid" 2>/dev/null; do
    if [[ -n "$timer" ]]; then
      kill -0 "$timer" 2>/dev/null || expired=1
    elif [[ "$waited" -ge $((secs * 1000)) ]]; then
      expired=1
    elif [[ "$waited" -ge 20 ]]; then
      left=$((secs * 1000 - waited))
      printf -v left '%d.%03d' $((left / 1000)) $((left % 1000))
      sleep "$left" >/dev/null 2>&1 3>&- &
      timer="$!"
    fi
    if [[ "$expired" -eq 1 ]]; then
      fl_run_group_kill
      printf 'timed out after %ss\n' "$secs" >>"$FL_RUN_ERR_FILE"
      FL_RUN_PGID="$saved_pgid"
      fl__timer_stop "$timer"
      return 124
    fi
    if [[ "$waited" -lt 100 ]]; then sleep 0.02; waited=$((waited + 20)); else sleep 0.1; waited=$((waited + 100)); fi
  done
  wait "$pid" || code=$?
  FL_RUN_PGID="$saved_pgid"
  fl__timer_stop "$timer"
  return "$code"
}

# fl__timer_stop PID: ends the timer of fl_run_capture_timeout, quietly
fl__timer_stop() {
  [[ -n "$1" ]] || return 0
  { kill "$1" && wait "$1"; } 2>/dev/null || true
}

# ---------------------------------------------------------------- git over the network
#
# One place for every read of a remote (preflight, plan, profile check, lock):
# git never prompts, ssh never waits for a password and gives up connecting
# after FL_GIT_CONNECT_SECS, and the whole call dies with its process group
# after the timeout (ssh included), so nothing is left running.

FL_GIT_CONNECT_SECS="${FL_GIT_CONNECT_SECS:-5}"
FL_GR_CODE=0     # exit code of the last fl_git_timed (fl_git_remote_run, the plan, profiles): 124 after a timeout
FL_GR_ERR=""     # its first line of stderr (without warnings), "timed out after Ns" on 124
FL_GR_OUT=""     # its stdout
FL_GR_DEFAULT="" # fl_git_remote_default: the branch HEAD points at

# fl_git_ext_off: sets FL_GIT_EXT_OFF to the three GIT_CONFIG_* assignments that
# turn the ext:: transport off (it runs a program), after any the caller set
FL_GIT_EXT_OFF=()
fl_git_ext_off() {
  local n="${GIT_CONFIG_COUNT:-0}"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  FL_GIT_EXT_OFF=("GIT_CONFIG_COUNT=$((n + 1))" "GIT_CONFIG_KEY_${n}=protocol.ext.allow" "GIT_CONFIG_VALUE_${n}=never")
}

# fl_git_ssh_command [DIR]: the ssh command for git over ssh: the user's own
# (GIT_SSH_COMMAND, else core.sshCommand as git sees it in DIR) or plain ssh,
# then our options. ssh takes the first value of an option, so a BatchMode or
# ConnectTimeout the user set stays; a key, a config file or a proxy they set
# is kept (setting GIT_SSH_COMMAND replaces core.sshCommand for git).
fl_git_ssh_command() {
  local base="${GIT_SSH_COMMAND:-}"
  [[ -n "$base" ]] || base="$(git ${1:+-C "$1"} config --get core.sshCommand 2>/dev/null || true)"
  printf '%s -o BatchMode=yes -o ConnectTimeout=%s' "${base:-ssh}" "$FL_GIT_CONNECT_SECS"
}

# git with your own keys and tokens, never a question, and never the ext::
# transport even when the user's git config allows it
fl_git_net() {
  local dir="" a=("$@")
  while [[ "${a[0]:-}" == "-C" || "${a[0]:-}" == "-c" ]]; do
    [[ "${a[0]}" == "-C" ]] && dir="${a[1]:-}"
    a=("${a[@]:2}")
  done
  fl_git_ext_off
  env GIT_TERMINAL_PROMPT=0 GIT_LFS_SKIP_SMUDGE=1 GIT_SSH_COMMAND="$(fl_git_ssh_command "$dir")" "${FL_GIT_EXT_OFF[@]}" git "$@"
}

# fl_git_timed SECS OUT COMMAND...: COMMAND (fl_git_net, or a function built on
# it) with stdout in the file OUT and a deadline: its whole process group ends
# after SECS. Sets FL_GR_CODE (124 after a timeout) and FL_GR_ERR (the first
# line of stderr without warnings, "timed out after Ns" on 124), puts stderr in
# the log, and returns FL_GR_CODE. The one place a network git call gets its
# deadline and its error line.
fl_git_timed() {
  local secs="$1" out="$2" err
  shift 2
  err="$(mktemp "${TMPDIR:-/tmp}/benchbar-gitnet.XXXXXX")"
  FL_GR_CODE=0
  # the shell tells "Terminated" of a job it killed on a timeout: not a line for the user
  { fl_run_capture_timeout "$secs" "$out" "$err" "$@" || FL_GR_CODE=$?; } 2>/dev/null
  fl_log_file_append "$err"
  if [[ "$FL_GR_CODE" == "124" ]]; then
    FL_GR_ERR="timed out after ${secs}s"
  else
    FL_GR_ERR="$(grep -v '^[[:space:]]*$' "$err" 2>/dev/null | grep -v '^warning:' | awk 'NR==1' || true)"
  fi
  rm -f "$err"
  return "$FL_GR_CODE"
}

# fl_git_remote_run SECS GIT_ARGS...: fl_git_net with a deadline; sets
# FL_GR_CODE, FL_GR_OUT and FL_GR_ERR, and puts git's stderr in the log
fl_git_remote_run() {
  local secs="$1" out
  shift
  out="$(mktemp "${TMPDIR:-/tmp}/benchbar-gitnet.XXXXXX")"
  fl_git_timed "$secs" "$out" fl_git_net "$@" || true
  FL_GR_OUT="$(cat "$out" 2>/dev/null || true)"
  rm -f "$out"
  return 0
}

# fl_git_in DIR GIT_ARGS...: git in a clone that talks to its remote (fetch),
# with the clone deadline (FL_GIT_CLONE_TIMEOUT, 120 s) and the helpers' error
# in FL_GR_ERR; returns FL_GR_CODE (124 after a timeout)
fl_git_in() {
  local dir="$1"
  shift
  fl_git_remote_run "${FL_GIT_CLONE_TIMEOUT:-120}" -C "$dir" "$@"
  return "$FL_GR_CODE"
}

# fl_git_remote_ref REPO REF [SECS]: is REF a branch or tag of REPO?
# Returns FL_GR_CODE: 0 found, 2 not there, 124 timeout, else git's own code.
fl_git_remote_ref() {
  fl_git_remote_run "${3:-${FL_GIT_TIMEOUT:-30}}" ls-remote --exit-code --heads --tags -- "$1" "refs/heads/$2" "refs/tags/$2"
  return "$FL_GR_CODE"
}

# fl_git_remote_tip REPO REF [SECS]: the commit of branch or tag REF of REPO in
# FL_GR_TIP (nothing when it is not there); returns FL_GR_CODE. A tag gives
# the commit it points at (the peeled line), not the tag object.
FL_GR_TIP=""
fl_git_remote_tip() {
  FL_GR_TIP=""
  fl_git_remote_run "${3:-${FL_GIT_TIMEOUT:-30}}" ls-remote --exit-code --heads --tags -- "$1" "refs/heads/$2" "refs/tags/$2" "refs/tags/$2^{}"
  [[ "$FL_GR_CODE" == "0" ]] || return "$FL_GR_CODE"
  FL_GR_TIP="$(printf '%s\n' "$FL_GR_OUT" | awk -v h="refs/heads/$2" -v t="refs/tags/$2" -v p="refs/tags/$2^{}" \
    '$2 == h {a = $1} $2 == t {b = $1} $2 == p {c = $1} END {print (a != "" ? a : (c != "" ? c : b))}')"
  return 0
}

# fl_git_remote_default REPO [SECS]: the branch HEAD points at, in FL_GR_DEFAULT
# (nothing when unknown); returns FL_GR_CODE
fl_git_remote_default() {
  FL_GR_DEFAULT=""
  fl_git_remote_run "${2:-${FL_GIT_TIMEOUT:-30}}" ls-remote --symref -- "$1" HEAD
  [[ "$FL_GR_CODE" == "0" ]] && FL_GR_DEFAULT="$(printf '%s\n' "$FL_GR_OUT" | awk '$1 == "ref:" && $3 == "HEAD" && !f {sub(/^refs\/heads\//, "", $2); print $2; f = 1}')"
  return "$FL_GR_CODE"
}

# fl_git_remote_heads REPO [SECS]: the branch names of REPO, one per line (at most 20)
fl_git_remote_heads() {
  fl_git_remote_run "${2:-${FL_GIT_TIMEOUT:-30}}" ls-remote --heads -- "$1"
  [[ "$FL_GR_CODE" == "0" ]] && printf '%s\n' "$FL_GR_OUT" | sed 's#.*refs/heads/##' | awk 'NR<=20 && NF'
  return 0
}

# fl_on_error [COMMAND]: the ERR trap. benchbar sets it with errtrace (set -E), as
# trap 'fl_on_error "$BASH_COMMAND"' ERR, so it fires for a command that fails inside a
# function too, and names it with the file and the function it ran in. The phase
# scripts set it without arguments, as before (the top level only).
fl_on_error() {
  local code="$?" cmd="${1-}" first word where file
  [[ "$code" -eq 0 ]] && return 0
  # errtrace hands the trap to every command substitution and subshell: a failure in
  # one is the caller's to report (`x="$(grep a b)" || true` is not an error), and an
  # exit trap that is already running keeps set -e's own behaviour
  [[ "${FL_EXITING:-0}" != "1" ]] || return 0
  [[ -z "$cmd" || "$BASH_SUBSHELL" -eq 0 ]] || return 0
  # a section that turned errexit off (`set +e; ( ... ); rc=$?; set -e`) collects its
  # failures and decides for itself. The ERR trap fires there all the same (bash 4 and
  # later even for the subshell's own exit status), so errexit being off is the mark of
  # a handled failure. Commands in an `if`, `||` or `&&` context never reach the trap.
  [[ -z "$cmd" || "$-" == *e* ]] || return 0
  # exit code 2 means "the MariaDB root password is unknown" and only an
  # explicit fl_die ... 2 may produce it; a command that happened to exit 2
  # (grep, awk, a usage error) is an ordinary failure
  [[ "$code" -eq 2 ]] && code=1
  fl_spinner_stop
  # a function that returned non zero on purpose (its own message came first), or a
  # wrapper that runs "$@": the last fl_run command is the best name there is
  first="${cmd%% *}"
  word=0
  case "$first" in "") ;; '"$'*|'$'*) ;; *) declare -F "$first" >/dev/null 2>&1 || word=1 ;; esac
  # a run with --json prints JSON on stdout and nothing else
  if [[ "${OPT_JSON:-0}" == "1" ]]; then exec 1>&2; fi
  if [[ "$word" == "1" ]]; then
    # where: the file and function of the failing line (bash 3.2 gives the line of
    # the function's first line inside one, so "near")
    file="${BASH_SOURCE[1]-}"
    file="${file#"${SCRIPT_DIR:-/}"/}"
    where="${file}${FUNCNAME[1]:+ in ${FUNCNAME[1]}}${BASH_LINENO[0]:+ near line ${BASH_LINENO[0]}}"
    fl_redact_url_v cmd "$cmd"
    FL_DIE_MESSAGE="${FL_DIE_MESSAGE:-Command failed (exit ${code}): ${cmd}${where:+ (${where})}}"
    fl_fail "Command failed (exit ${code}): ${cmd}${where:+ (${where})}"
    if [[ -n "${FL_LOG_FILE:-}" ]]; then fl_note "full log: ${FL_LOG_FILE}"; fi
  # nothing to name: the command already said why it ended (a verify pass
  # with warnings), so a "[FAIL] Last command failed" line would only mislead
  elif [[ -n "${FL_LAST_COMMAND:-}" ]]; then
    fl_fail "Last command failed with exit code ${code}: ${FL_LAST_COMMAND}"
    if [[ -n "${FL_LOG_FILE:-}" ]]; then fl_note "full log: ${FL_LOG_FILE}"; fi
  fi
  exit "$code"
}
