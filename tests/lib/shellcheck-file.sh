#!/usr/bin/env bash
# Usage: shellcheck-file.sh FILE. Runs shellcheck -x over one file, with a deadline and a memory cap.
#
# The -x option of shellcheck follows every sourced file, so one process over benchbar needs about 4 GB and
# 30 s, and the pool run-tests.sh runs several at a time. Five CI runs on 2026-11-25 and 26 sat
# in that step until the job's timeout and left no log at all. One file per process, so a stuck
# or runaway one names itself:
#   SC_FILE_TIMEOUT  seconds per file (default 180; the slowest file takes about 30)
#   SC_MEM_KB        virtual memory cap per process in KB (default 8000000), used when the
#                    platform enforces it and shellcheck still starts under it. The cap is on
#                    virtual memory, and the runtime maps more than the 4 GB it keeps resident,
#                    so it stays well above that; the pool in run-tests.sh bounds the total
#   SHELLCHECK_CMD   the shellcheck to run (default shellcheck)
# Exit: shellcheck's own, 124 after the deadline, 1 after a crash or a memory stop, 2 on bad input.
# A wrapper that is stopped by a signal stops its shellcheck first.
set -uo pipefail

file="${1:?usage: shellcheck-file.sh FILE}"
cmd="${SHELLCHECK_CMD:-shellcheck}"
limit="${SC_FILE_TIMEOUT:-180}"
kb="${SC_MEM_KB:-8000000}"
[[ "$limit" =~ ^[1-9][0-9]*$ ]] || { printf 'shellcheck: SC_FILE_TIMEOUT must be a number of seconds, got %s\n' "$limit" >&2; exit 2; }
[[ "$kb" =~ ^[1-9][0-9]*$ ]] || { printf 'shellcheck: SC_MEM_KB must be a number of KB, got %s\n' "$kb" >&2; exit 2; }

capped=0
if ( ulimit -v "$kb" 2>/dev/null && "$cmd" --version >/dev/null 2>&1 ); then capped=1; fi

if [[ "$capped" == 1 ]]; then
  ( ulimit -v "$kb"; exec "$cmd" -x "$file" ) &
else
  "$cmd" -x "$file" &
fi
pid=$!
trap 'kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null; exit 143' INT TERM HUP

# SECONDS, not a count of sleeps: the time each check takes counts too
start=$SECONDS
while kill -0 "$pid" 2>/dev/null; do
  if [[ $((SECONDS - start)) -ge "$limit" ]]; then
    printf 'shellcheck: %s still running after %ss; stopped\n' "$file" "$limit" >&2
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    exit 124
  fi
  sleep 0.2
done
code=0
wait "$pid" || code=$?
# 0 clean, 1 findings (shellcheck printed them with the file name); anything else is not a verdict
if [[ "$code" -gt 1 ]]; then
  printf 'shellcheck: %s ended with status %s (killed or out of memory; cap %s KB)\n' "$file" "$code" "$kb" >&2
  exit 1
fi
exit "$code"
