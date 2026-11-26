#!/usr/bin/env bash
# Usage: shellcheck-file.sh FILE. Runs shellcheck -x over one file, with a deadline.
#
# The -x option of shellcheck follows every sourced file: the phase scripts take 2 to 2.5 GB on a
# hosted runner, and benchbar with dataflow analysis 15 GB (so it goes without, below), and the
# pool run-tests.sh runs several at a time. Five CI runs on 2026-11-25 and 26 sat
# in that step until the job's timeout and left no log at all. One file per process, so a stuck
# or runaway one names itself:
#   SC_FILE_TIMEOUT  seconds per file (default 180; the slowest file takes about 30)
#   SHELLCHECK_CMD   the shellcheck to run (default shellcheck)
# No virtual memory cap (ulimit -v): the runtime of shellcheck maps far more than it keeps
# resident, and an 8 GB cap stopped benchbar on a hosted runner. The pool in run-tests.sh bounds
# the memory, and a process the kernel kills for memory ends with a status that is named below.
# Exit: shellcheck's own, 124 after the deadline, 1 after a crash or a kill, 2 on bad input.
# A wrapper that is stopped by a signal stops its shellcheck first.
set -uo pipefail

file="${1:?usage: shellcheck-file.sh FILE}"
cmd="${SHELLCHECK_CMD:-shellcheck}"
limit="${SC_FILE_TIMEOUT:-180}"
[[ "$limit" =~ ^[1-9][0-9]*$ ]] || { printf 'shellcheck: SC_FILE_TIMEOUT must be a number of seconds, got %s\n' "$limit" >&2; exit 2; }

# stop_child: TERM, then KILL when it is still there after a second
pid=""
stop_child() {
  [[ -n "$pid" ]] || return 0
  kill "$pid" 2>/dev/null || return 0
  local i
  for i in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.2; done
  kill -9 "$pid" 2>/dev/null || true
}
# set before the child starts, so no signal falls between the two
trap 'stop_child; exit 130' INT
trap 'stop_child; exit 143' TERM
trap 'stop_child; exit 129' HUP

# benchbar, the entry point, sources every library: with dataflow analysis its check took 15 GB
# on a 16 GB runner and stopped the runner (#396), without it 0.7 GB and 26 s. Its libraries are
# checked one by one with the analysis, so only benchbar's own lines go without it.
opts=()
case "$file" in benchbar | */benchbar) opts=(--extended-analysis=false) ;; esac

"$cmd" -x ${opts[@]+"${opts[@]}"} "$file" &
pid=$!

# SECONDS, not a count of sleeps: the time each check takes counts too. It counts whole
# seconds from a start that is rounded down, so only more than LIMIT of them is LIMIT for sure.
start=$SECONDS
while kill -0 "$pid" 2>/dev/null; do
  if [[ $((SECONDS - start)) -gt "$limit" ]]; then
    printf 'shellcheck: %s still running after %ss; stopped\n' "$file" "$limit" >&2
    stop_child
    wait "$pid" 2>/dev/null || true
    exit 124
  fi
  sleep 0.2
done
code=0
wait "$pid" || code=$?
# 0 clean, 1 findings (shellcheck printed them with the file name); anything else is not a verdict
if [[ "$code" -gt 1 ]]; then
  printf 'shellcheck: %s ended with status %s (killed, out of memory or crashed)\n' "$file" "$code" >&2
  exit 1
fi
exit "$code"
