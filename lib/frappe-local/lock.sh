#!/usr/bin/env bash
#
# lock.sh: one benchbar run at a time. A lock is a directory (made by
# fl_mkdir_excl: mkdir alone is not atomic on every Linux) holding the
# owner's pid in pid, written through a temp file and
# rename so it is either absent or complete. Two locks are taken: the state
# folder's (every install kind has its own state folder) and the bench's
# own, <bench>/.benchbar.lock, so a Homebrew CLI, the app's CLI and a git
# checkout that all work on one bench meet on the same lock.
#
# A stale lock (its owner is dead) is reclaimed by renaming it away: only
# one of several reclaimers wins the rename, the others try again against
# the lock that winner makes, and nobody removes a lock another run just
# made. A lock whose pid is not written yet is a run between its mkdir and
# its pid write: it is left alone for FL_LOCK_GRACE_SECS before it counts
# as stale.

FL_LOCK_DIR=""
FL_LOCK_DIRS=""
# how long a run waits for a live holder before it gives up (the app and a terminal, or the
# app and the login agent, start within the same second): 8 seconds; a test seam, like the grace
if [[ "${FL_TESTING:-}" == "1" ]]; then FL_LOCK_WAIT_SECS="${FL_LOCK_WAIT_SECS:-8}"; else FL_LOCK_WAIT_SECS=8; fi
# a test seam: a production run (no FL_TESTING=1) always waits 5 seconds
if [[ "${FL_TESTING:-}" == "1" ]]; then FL_LOCK_GRACE_SECS="${FL_LOCK_GRACE_SECS:-5}"; else FL_LOCK_GRACE_SECS=5; fi
# the first lock of the run (the state folder's); locks a subshell takes
# later (ports setup adopts each bench in one) are listed in its "held"
# file, since a subshell cannot add to the parent's FL_LOCK_DIRS, and the
# parent's release reads that list
FL_LOCK_MAIN=""
# the subshell level ($BASH_SUBSHELL) the main lock was taken at. A subshell
# of the run shares $$ and so passes the pid checks: its fl_lock_release
# (restart inside app update, which lets go before its ping wait) would drop
# the parent's locks for the rest of the run, so a deeper level keeps them
FL_LOCK_LEVEL=""

# fl__lock_start_v VAR PID: when the process started ("Thu Nov 19 10:00:00 2026", as ps
# prints it, in UTC), nothing for a process that is gone. A pid alone is not an identity: after
# a crash the number comes round again and any live process can have it. ps prints local time:
# TZ=UTC keeps a time zone or DST change (or another TZ in a second shell) from making the
# live owner's start time differ from the one the lock recorded.
fl__lock_start_v() {
  local __s
  __s="$(TZ=UTC LC_ALL=C ps -o lstart= -p "$2" 2>/dev/null)" || __s=""
  __s="${__s//  / }"
  printf -v "$1" '%s' "${__s# }"
}

# fl__lock_owner_alive DIR PID: PID is alive and is the process that took the lock: its start
# time is the one the lock recorded (a lock of an older benchbar has none: the pid decides)
fl__lock_owner_alive() {
  local dir="$1" pid="$2" recorded now
  kill -0 "$pid" 2>/dev/null || return 1
  [[ -r "${dir}/pstart" ]] || return 0
  IFS= read -r recorded <"${dir}/pstart" || true
  [[ -n "$recorded" ]] || return 0
  fl__lock_start_v now "$pid"
  # ps cannot say (a restricted /proc, no ps): the pid decides
  [[ -n "$now" ]] || return 0
  [[ "$now" == "$recorded" ]]
}

fl__lock_write_pid() {
  local dir="$1" tmp start
  # the start time first: a reader that sees the pid finds it
  fl__lock_start_v start "$$"
  if [[ -n "$start" ]]; then printf '%s\n' "$start" >"${dir}/pstart" 2>/dev/null || true; fi
  tmp="$(mktemp "${dir}/.pid.XXXXXX" 2>/dev/null)" || return 1
  printf '%s\n' "$$" >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "${dir}/pid" || return 1
  # what holds the lock and since when, for the line that reclaims it once the
  # holder is dead (the command word and its subcommand only, never an argument)
  printf '%s %s\t%s\n' "${COMMAND:-benchbar}" "${ARGS[0]:-}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${dir}/info" 2>/dev/null || true
}

# fl__lock_info DIR: "benchbar site add, started 2026-10-29T10:00:00Z" from the
# lock's info file, nothing without one
fl__lock_info() {
  local line cmd when
  [[ -r "${1}/info" ]] || return 0
  IFS= read -r line <"${1}/info" || true
  cmd="${line%%$'\t'*}"; when="${line#*$'\t'}"
  cmd="${cmd% }"
  [[ -n "$cmd" ]] || return 0
  printf 'benchbar %s' "$cmd"
  [[ "$when" == "$line" || -z "$when" ]] || printf ', started %s' "$when"
}

# age in seconds of a path, from its mtime (BSD and GNU stat)
fl__lock_age() {
  local m
  # each form counts only as a number: on Linux, GNU stat -f prints file
  # system text and fails, and joined with the -c output the age read 0
  m="$(stat -f %m "$1" 2>/dev/null)" || true
  [[ "$m" =~ ^[0-9]+$ ]] || m="$(stat -c %Y "$1" 2>/dev/null)" || true
  [[ "$m" =~ ^[0-9]+$ ]] || { printf '0'; return 0; }
  printf '%s' "$(( $(date +%s) - m ))"
}

# fl_mkdir_excl DIR: makes the folder DIR as a lock; of several runs that make it at once, one wins.
# The exit code of mkdir does not say which. uutils coreutils (the coreutils of Ubuntu 25.10 and
# later) looks for the folder first and, when another process makes it between that look and its
# own mkdir, reports success all the same: two runs held one lock and a lease was lost although
# its take said ok (issue 138). The winner is the run whose claim file goes in first: bash's
# noclobber opens it with O_EXCL, which no coreutils is between. A run that lost the claim does not
# hold the folder and leaves it alone. Returns 0 held, 1 held by another run (or gone again), 2 the
# claim cannot be written (no space, no inodes, no permission): a folder that is there with no claim
# in it after a second try is not a race, and the caller says so instead of waiting for nobody.
fl_mkdir_excl() {
  mkdir "$1" 2>/dev/null || return 1
  ( set -o noclobber; : >"${1}/claim" ) 2>/dev/null && return 0
  [[ -d "$1" && ! -e "${1}/claim" ]] || return 1
  # a folder another run made a moment ago, before its own claim: the claim is still free
  ( set -o noclobber; : >"${1}/claim" ) 2>/dev/null && return 0
  [[ -d "$1" && ! -e "${1}/claim" ]] || return 1
  return 2
}

# fl_rmdir_excl DIR: lets go of a folder fl_mkdir_excl made: its claim, then the folder
fl_rmdir_excl() {
  rm -f "${1}/claim" 2>/dev/null
  rmdir "$1" 2>/dev/null
}

# fl_lock_acquire [DIR] [WHAT]: takes the lock DIR (default: the state
# folder's) or dies naming the live owner. WHAT names it in messages.
fl_lock_acquire() {
  local dir="${1:-${FL_STATE_DIR}/lock}" what="${2:-}" owner try stale guard now held_by
  local deadline="" told=0 parent busy rc
  [[ "${FL_DRY_RUN:-0}" == "1" ]] && return 0
  parent="$(dirname "$dir")"
  mkdir -p "$parent" 2>/dev/null || true
  # a file where the state folder belongs is not a lock that is busy
  [[ -d "$parent" ]] || fl_die "Could not create the lock ${dir}: ${parent} is not a folder." "Move ${parent} away, or point FL_STATE_DIR at a folder, then run again."
  try=0
  while [[ "$try" -lt 5 ]]; do
    try=$((try + 1))
    rc=0; fl_mkdir_excl "$dir" || rc=$?
    if [[ "$rc" == 2 ]]; then
      # the folder is there and takes no claim: nobody holds it, and waiting would not help
      rmdir "$dir" 2>/dev/null || true
      fl_die "Could not write the lock ${dir}." "Check the free space and the owner of ${parent} (df -h ${parent}; ls -ld ${parent}), then run again."
    fi
    if [[ "$rc" == 0 ]]; then
      fl__lock_write_pid "$dir" || { fl_rmdir_excl "$dir"; fl_die "Could not write the lock ${dir}."; }
      FL_LOCK_DIR="$dir"
      FL_LOCK_DIRS="${FL_LOCK_DIRS}${dir}"$'\n'
      if [[ -z "$FL_LOCK_MAIN" ]]; then FL_LOCK_MAIN="$dir"; FL_LOCK_LEVEL="$BASH_SUBSHELL"
      elif [[ -d "$FL_LOCK_MAIN" ]]; then printf '%s\n' "$dir" >>"${FL_LOCK_MAIN}/held" 2>/dev/null || true; fi
      return 0
    fi
    if [[ ! -d "$dir" ]]; then
      # a folder that cannot be written never holds a lock: no other run is
      # taking it, so say why instead of retrying
      [[ -w "$parent" ]] || fl_die "Could not create the lock ${dir}: ${parent} is not writable (read only?)." "Make the folder writable, then run again."
      # gone between the mkdir and here (a reclaimer took it away): try again
      continue
    fi
    owner="$(cat "$dir/pid" 2>/dev/null || true)"
    # our own (this run, or a subshell of it, which shares $$): held already
    if [[ "$owner" == "$$" ]]; then
      FL_LOCK_DIRS="${FL_LOCK_DIRS}${dir}"$'\n'
      return 0
    fi
    # a live holder, or a run between its mkdir and its pid write: wait a few seconds for it
    # (the app and a terminal, or the app and the login agent, start in the same second)
    busy=""
    if [[ -n "$owner" ]] && fl__lock_owner_alive "$dir" "$owner"; then busy=active
    elif [[ -z "$owner" && "$(fl__lock_age "$dir")" -lt "$FL_LOCK_GRACE_SECS" ]]; then busy=starting; fi
    if [[ -n "$busy" ]]; then
      [[ -n "$deadline" ]] || deadline=$((SECONDS + FL_LOCK_WAIT_SECS))
      if [[ "$SECONDS" -ge "$deadline" ]]; then
        if [[ "$busy" == active ]]; then
          fl_die "Another benchbar run is active${what:+ ${what}} (pid ${owner})." "Wait for it to finish, or remove ${dir} if you are sure it is dead."
        fi
        fl_die "Another benchbar run is starting${what:+ ${what}} (lock ${dir} is ${FL_LOCK_GRACE_SECS} seconds old at most)." "Try again in a moment."
      fi
      if [[ "$told" == 0 && "$FL_LOCK_WAIT_SECS" -gt 0 ]]; then
        told=1
        held_by="$(fl__lock_info "$dir")"
        printf 'Waiting for %s%s to finish (up to %s seconds)...\n' "${held_by:-another benchbar run}" "${owner:+ (pid ${owner})}" "$FL_LOCK_WAIT_SECS" >&2
      fi
      sleep 0.25
      # waiting is not a try: the tries count races for a stale lock
      try=$((try - 1))
      continue
    fi
    # dead owner, or an empty lock past the grace period: rename it away,
    # under a guard that one reclaimer at a time holds, after reading the
    # pid again: another reclaimer may have replaced the stale lock with a
    # live one of its own in between, and that one must stay.
    guard="${dir}.reclaim"
    if fl_mkdir_excl "$guard"; then
      now="$(cat "$dir/pid" 2>/dev/null || true)"
      stale="${dir}.stale.$$"
      held_by="$(fl__lock_info "$dir")"
      if [[ "$now" == "$owner" ]] && mv "$dir" "$stale" 2>/dev/null; then
        fl_warn "Reclaiming stale lock left by pid ${owner:-unknown}${held_by:+ (${held_by})}"
        rm -rf "$stale"
      fi
      fl_rmdir_excl "$guard" || true
    elif [[ -d "$guard" && "$(fl__lock_age "$guard")" -ge "$FL_LOCK_GRACE_SECS" ]]; then
      # a reclaimer that died with the guard
      fl_rmdir_excl "$guard" || true
    else
      sleep 0.2
    fi
  done
  fl_die "Could not take the lock ${dir} after ${try} tries." "Another benchbar run keeps taking it; wait for it, or remove ${dir} if you are sure none runs."
}

# fl_lock_release: lets go of every lock this run holds (the EXIT trap, and
# up before its ping wait)
fl_lock_release() {
  local dir list="$FL_LOCK_DIRS"
  # a subshell below the one that took the locks: they stay with their taker
  [[ -z "$FL_LOCK_LEVEL" || "$BASH_SUBSHELL" -le "$FL_LOCK_LEVEL" ]] || return 0
  # locks taken in subshells of this run, listed in the main lock's held file
  if [[ -n "$FL_LOCK_MAIN" && -f "${FL_LOCK_MAIN}/held" ]]; then
    list="$(cat "${FL_LOCK_MAIN}/held" 2>/dev/null)"$'\n'"$list"
  fi
  [[ -n "${list//[[:space:]]/}" ]] || return 0
  # the main lock last: its held file is read above
  while IFS= read -r dir; do
    [[ -n "$dir" && "$dir" != "$FL_LOCK_MAIN" ]] || continue
    if [[ "$(cat "$dir/pid" 2>/dev/null)" == "$$" ]]; then rm -rf "$dir"; fi
  done <<<"$list"
  if [[ -n "$FL_LOCK_MAIN" && "$(cat "${FL_LOCK_MAIN}/pid" 2>/dev/null)" == "$$" ]]; then rm -rf "$FL_LOCK_MAIN"; fi
  FL_LOCK_DIRS=""
  FL_LOCK_DIR=""
  FL_LOCK_MAIN=""
  FL_LOCK_LEVEL=""
}

# fl_lock_bench_acquire: the bench's own lock, <bench>/.benchbar.lock, for
# every run that already holds the state lock (a mutating command). Taken
# once the bench is known (fl_context_init); never in a dry run.
FL_BENCH_LOCK_HELD=""
fl_lock_bench_acquire() {
  [[ "${FL_DRY_RUN:-0}" == "1" || -z "$FL_LOCK_DIR" ]] && return 0
  [[ -n "${FL_BENCH_DIR:-}" && -d "$FL_BENCH_DIR" ]] || return 0
  [[ "$FL_BENCH_LOCK_HELD" == "$FL_BENCH_DIR" ]] && return 0
  fl_lock_acquire "${FL_BENCH_DIR}/.benchbar.lock" "on this bench"
  FL_BENCH_LOCK_HELD="$FL_BENCH_DIR"
}
