#!/usr/bin/env bash
#
# lock.sh: one benchbar run at a time. A lock is a directory (mkdir is
# atomic) holding the owner's pid in pid, written through a temp file and
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
FL_LOCK_GRACE_SECS="${FL_LOCK_GRACE_SECS:-5}"
# the first lock of the run (the state folder's); locks a subshell takes
# later (ports setup adopts each bench in one) are listed in its "held"
# file, since a subshell cannot add to the parent's FL_LOCK_DIRS, and the
# parent's release reads that list
FL_LOCK_MAIN=""

fl__lock_write_pid() {
  local dir="$1" tmp
  tmp="$(mktemp "${dir}/.pid.XXXXXX" 2>/dev/null)" || return 1
  printf '%s\n' "$$" >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "${dir}/pid"
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

# fl_lock_acquire [DIR] [WHAT]: takes the lock DIR (default: the state
# folder's) or dies naming the live owner. WHAT names it in messages.
fl_lock_acquire() {
  local dir="${1:-${FL_STATE_DIR}/lock}" what="${2:-}" owner try stale guard now
  [[ "${FL_DRY_RUN:-0}" == "1" ]] && return 0
  mkdir -p "$(dirname "$dir")" 2>/dev/null || true
  for try in 1 2 3 4 5; do
    if mkdir "$dir" 2>/dev/null; then
      fl__lock_write_pid "$dir" || { rmdir "$dir" 2>/dev/null; fl_die "Could not write the lock ${dir}."; }
      FL_LOCK_DIR="$dir"
      FL_LOCK_DIRS="${FL_LOCK_DIRS}${dir}"$'\n'
      if [[ -z "$FL_LOCK_MAIN" ]]; then FL_LOCK_MAIN="$dir"
      elif [[ -d "$FL_LOCK_MAIN" ]]; then printf '%s\n' "$dir" >>"${FL_LOCK_MAIN}/held" 2>/dev/null || true; fi
      return 0
    fi
    if [[ ! -d "$dir" ]]; then
      # a folder that cannot be written never holds a lock: no other run is
      # taking it, so say why instead of retrying
      [[ -w "$(dirname "$dir")" ]] || fl_die "Could not create the lock ${dir}: $(dirname "$dir") is not writable (read only?)." "Make the folder writable, then run again."
      # gone between the mkdir and here (a reclaimer took it away): try again
      continue
    fi
    owner="$(cat "$dir/pid" 2>/dev/null || true)"
    # our own (this run, or a subshell of it, which shares $$): held already
    if [[ "$owner" == "$$" ]]; then
      FL_LOCK_DIRS="${FL_LOCK_DIRS}${dir}"$'\n'
      return 0
    fi
    if [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null; then
      fl_die "Another benchbar run is active${what:+ ${what}} (pid ${owner})." "Wait for it to finish, or remove ${dir} if you are sure it is dead."
    fi
    if [[ -z "$owner" && "$(fl__lock_age "$dir")" -lt "$FL_LOCK_GRACE_SECS" ]]; then
      # made moments ago, pid not written yet: a run that is starting
      fl_die "Another benchbar run is starting${what:+ ${what}} (lock ${dir} is ${FL_LOCK_GRACE_SECS} seconds old at most)." "Try again in a moment."
    fi
    # dead owner, or an empty lock past the grace period: rename it away,
    # under a guard that one reclaimer at a time holds, after reading the
    # pid again: another reclaimer may have replaced the stale lock with a
    # live one of its own in between, and that one must stay.
    guard="${dir}.reclaim"
    if mkdir "$guard" 2>/dev/null; then
      now="$(cat "$dir/pid" 2>/dev/null || true)"
      stale="${dir}.stale.$$"
      if [[ "$now" == "$owner" ]] && mv "$dir" "$stale" 2>/dev/null; then
        fl_warn "Reclaiming stale lock left by pid ${owner:-unknown}"
        rm -rf "$stale"
      fi
      rmdir "$guard" 2>/dev/null || true
    elif [[ -d "$guard" && "$(fl__lock_age "$guard")" -ge "$FL_LOCK_GRACE_SECS" ]]; then
      # a reclaimer that died with the guard
      rmdir "$guard" 2>/dev/null || true
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
