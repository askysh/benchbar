#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# facts.sh: what one doctor run reads again and again, read once.
#
# doctor asks the same questions many times (who listens on 8000, what does
# launchctl say about the agent, what is the branch of an app, what ports does
# a bench's config name) and used to start a program for every answer. Between
# fl_facts_begin and fl_facts_end an answer is kept in a file of a private
# folder, so the next ask, in this shell, in a $(...) or in a background job
# of the same run, reads it with the shell's own read (no program). Outside a
# doctor run FL_FACTS_DIR is empty and every function here answers like the
# code it replaces. Doctor is read only and a run is short, so an answer
# cannot go stale while it is kept; the one place that changes what a kept
# answer says (doctor --fetch) calls fl_facts_forget.
#
# Background jobs of one run (fl_par_*) are bounded by FL_DOCTOR_JOBS.

# never taken from the environment: the folder is the run's own, and
# fl_facts_end deletes it
FL_FACTS_DIR=""
FL_DOCTOR_JOBS="${FL_DOCTOR_JOBS:-6}"
FL_PAR_PIDS=()
# fd 9 is a fifo each job writes one line to when it ends: the run waits on it
# for "any job ended" (bash 3.2 has no wait -n). Empty when there is none.
FL_FACTS_WAKE=""
# nonempty in a background job: it is already a group of its own
FL_IN_JOB=""

# fl_facts_begin: a fresh private folder for this run (none when mktemp cannot make one)
fl_facts_begin() {
  fl_facts_end
  FL_FACTS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/benchbar-facts.XXXXXX" 2>/dev/null)" || FL_FACTS_DIR=""
  if [[ -n "$FL_FACTS_DIR" ]] && ! { true <&9; } 2>/dev/null && mkfifo "${FL_FACTS_DIR}/wake" 2>/dev/null; then
    if exec 9<>"${FL_FACTS_DIR}/wake" 2>/dev/null; then FL_FACTS_WAKE=9; fi
  fi
  return 0
}

# fl_facts_end: the run is over, or was cut short. Every job still running
# (and the children of each, one group per job) gets TERM, then KILL after a
# second, and is waited for, so nothing writes into the folder or outlives the
# run; only then the folder goes. Quiet: bash's notices about killed jobs are
# not printed.
fl_facts_end() {
  fl_par_stop
  if [[ -n "$FL_FACTS_WAKE" ]]; then exec 9<&- 2>/dev/null || true; FL_FACTS_WAKE=""; fi
  # a job stopped a moment ago can still have a write in flight, so a removal that
  # leaves the folder ("directory not empty") is tried again, for up to a second
  local __try=0
  while [[ -n "$FL_FACTS_DIR" && -e "$FL_FACTS_DIR" && "$__try" -lt 10 ]]; do
    rm -rf "$FL_FACTS_DIR" 2>/dev/null || true
    [[ -e "$FL_FACTS_DIR" ]] || break
    sleep 0.1; __try=$((__try + 1))
  done
  FL_FACTS_DIR=""
  FL_PAR_PIDS=()
  return 0
}

# fl_facts_forget PREFIX: drops the kept answers whose key starts with PREFIX
fl_facts_forget() {
  local f p
  [[ -n "$FL_FACTS_DIR" ]] || return 0
  # a key that starts with PREFIX: its k-, q- or h- name begins with it too
  for f in "$FL_FACTS_DIR/k-${1}"* "$FL_FACTS_DIR/q-${1}"* "$FL_FACTS_DIR/h-${1}"*; do [[ ! -e "$f" ]] || rm -f "$f"; done
  return 0
}

# fl_fact_path_v VAR KEY: the file name of KEY, two keys never sharing one.
# A short key of letters, digits, . and - is its own name (k-KEY); any other
# is quoted by printf %q after "_" and "/" are spelled _5f and _2f (q-...);
# one that is still long (a file name holds 255 bytes) keeps its first 100
# bytes and ends in its length and a checksum of the whole key (h-...).
fl_fact_path_v() {
  local __k="$2" __o __h=5381 __i __n
  if [[ "$__k" =~ ^[A-Za-z0-9.-]{0,120}$ ]]; then printf -v "$1" 'k-%s' "$__k"; return 0; fi
  __o="${__k//_/_5f}"; __o="${__o//\//_2f}"
  printf -v __o '%q' "$__o"
  if [[ "${#__o}" -le 200 ]]; then printf -v "$1" 'q-%s' "$__o"; return 0; fi
  for ((__i = 0; __i < ${#__k}; __i++)); do
    printf -v __n '%d' "'${__k:__i:1}"
    __h=$(((__h * 33 + __n) % 4294967296))
  done
  __o="${__o//[^A-Za-z0-9._-]/_}"
  printf -v "$1" 'h-%s~%d~%x' "${__o:0:100}" "${#__k}" "$__h"
}

# fl_memo_v VAR KEY CMD [ARG...]: runs CMD (stdout only, stderr dropped) the
# first time KEY is asked in this run and keeps its output and exit code; VAR
# gets the output, the return value is the exit code. Without a run it just
# runs CMD.
fl_memo_v() {
  local __var="$1" __key="$2" __p __f __out="" __rc=0
  shift 2
  if [[ -z "$FL_FACTS_DIR" ]]; then
    __out="$("$@" 2>/dev/null)" || __rc=$?
    printf -v "$__var" '%s' "$__out"
    return "$__rc"
  fi
  fl_fact_path_v __p "$__key"
  __f="${FL_FACTS_DIR}/${__p}"
  # the .rc file is written last: a file without it is half written, by a job still running
  if [[ -f "${__f}.rc" ]]; then
    IFS= read -r -d '' __out <"$__f" || true
    IFS= read -r __rc <"${__f}.rc" || true
    printf -v "$__var" '%s' "$__out"
    return "${__rc:-0}"
  fi
  "$@" >"$__f" 2>/dev/null || __rc=$?
  printf '%s\n' "$__rc" >"${__f}.rc"
  IFS= read -r -d '' __out <"$__f" || true
  printf -v "$__var" '%s' "$__out"
  return "$__rc"
}

# fl_memo KEY CMD [ARG...]: fl_memo_v, printing the output byte for byte (as the command did)
fl_memo() {
  local __o __rc=0
  if [[ -z "$FL_FACTS_DIR" ]]; then shift; "$@" 2>/dev/null; return; fi
  fl_memo_v __o "$@" || __rc=$?
  printf '%s' "$__o"
  return "$__rc"
}

# ---------------------------------------------------------------- background jobs

# fl_par_wait_slot: waits until fewer than FL_DOCTOR_JOBS jobs of this run are alive
fl_par_wait_slot() {
  local pid alive
  while :; do
    alive=()
    for pid in ${FL_PAR_PIDS[@]+"${FL_PAR_PIDS[@]}"}; do
      if kill -0 "$pid" 2>/dev/null; then alive+=("$pid"); else wait "$pid" 2>/dev/null || true; fi
    done
    FL_PAR_PIDS=(${alive[@]+"${alive[@]}"})
    [[ "${#FL_PAR_PIDS[@]}" -lt "$FL_DOCTOR_JOBS" ]] && return 0
    # the oldest job is the likeliest to end first; waiting for it needs no timer
    wait "${FL_PAR_PIDS[0]}" 2>/dev/null || true
  done
}

# fl_par_add PID: a started background job counts against the bound
fl_par_add() { FL_PAR_PIDS+=("$1"); }

# fl_par_group_on / fl_par_group_off: around "{ CMD & } 2>/dev/null" they make
# the background job the leader of a process group of its own (bash 3.2 has
# no setsid; a job started under job control gets one), so one kill of the
# group reaches the job's children too (brew's ruby, tr, git). The group stays
# after set +m. A job started inside a job is left in the job's group.
#
# The two also bracket the moment a job is forked but its pid is not kept yet:
# a stop signal that lands there would find no job to stop, and the job would
# write into the folder fl_facts_end is deleting (a folder left behind, a
# child left running). fl_on_signal (run.sh) leaves such a signal in
# FL_SIG_DEFERRED; fl_par_group_off sends it again once the pid is kept.
FL_PAR_STARTING=""
FL_SIG_DEFERRED=""
fl_par_group_on() { FL_PAR_STARTING=1; [[ -n "$FL_IN_JOB" ]] || set -m; }
fl_par_group_off() {
  local sig="$FL_SIG_DEFERRED"
  [[ -n "$FL_IN_JOB" ]] || set +m
  FL_PAR_STARTING=""
  FL_SIG_DEFERRED=""
  if [[ -n "$sig" ]]; then kill -s "$sig" "$$" 2>/dev/null || true; fi
  return 0
}

# fl_par_stop: TERM to the group of every job of this run (and of the warming
# of the apps' git), KILL to what is left after a second, and a wait for all
# of them
fl_par_stop() {
  local pid any i=0 live=()
  for pid in ${FL_PAR_PIDS[@]+"${FL_PAR_PIDS[@]}"} ${FL_WARM_PID:-}; do
    # a group exists while any member lives; a pid that is gone is not signalled
    if kill -0 "$pid" 2>/dev/null || kill -0 -- "-$pid" 2>/dev/null; then live+=("$pid"); fi
  done
  [[ "${#live[@]}" -gt 0 ]] || return 0
  {
    for pid in "${live[@]}"; do kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true; done
    while [[ "$i" -lt 10 ]]; do
      any=""
      for pid in "${live[@]}"; do if kill -0 -- "-$pid" 2>/dev/null || kill -0 "$pid" 2>/dev/null; then any=1; fi; done
      [[ -n "$any" ]] || break
      sleep 0.1
      i=$((i + 1))
    done
    for pid in "${live[@]}"; do kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true; done
    for pid in "${live[@]}"; do wait "$pid" 2>/dev/null || true; done
  } 2>/dev/null
  return 0
}

# fl_par_free: forgets the jobs that ended; true when a slot is free. Never waits.
fl_par_free() {
  local pid alive=()
  for pid in ${FL_PAR_PIDS[@]+"${FL_PAR_PIDS[@]}"}; do
    if kill -0 "$pid" 2>/dev/null; then alive+=("$pid"); fi
  done
  FL_PAR_PIDS=(${alive[@]+"${alive[@]}"})
  [[ "${#FL_PAR_PIDS[@]}" -lt "$FL_DOCTOR_JOBS" ]]
}

# fl_par_wait_all: waits for every background job of this run
fl_par_wait_all() {
  local pid
  for pid in ${FL_PAR_PIDS[@]+"${FL_PAR_PIDS[@]}"}; do wait "$pid" 2>/dev/null || true; done
  FL_PAR_PIDS=()
}
