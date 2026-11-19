#!/bin/bash
# TEMPORARY debug of process groups on the runner; removed before merge.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
echo "== bash $BASH_VERSION, tty: $(tty 2>&1), stdin: $(ls -l /dev/fd/0 2>&1 | tail -1)"
echo "== 1. set -m job without a terminal"
set -m
{ bash -c 'sleep 60 & sleep 61 & wait' </dev/null >/dev/null 2>&1 & } 2>/dev/null
pid=$!
set +m
sleep 0.5
echo "shell pid $$, job pid $pid"
ps -axo pid,pgid,ppid,command | awk -v p="$pid" -v s="$$" 'NR==1 || $1==p || $2==p || $1==s'
kill -TERM -- "-$pid"; echo "kill -- -pid exit: $?"
sleep 0.5
echo "left after TERM to the group:"; ps -axo pid,pgid,ppid,command | awk -v p="$pid" '$1==p || $2==p'
echo "== 2. perl setpgrp"
perl -e 'setpgrp(0,0); exec @ARGV' bash -c 'sleep 60 & sleep 61 & wait' </dev/null >/dev/null 2>&1 &
pid=$!
sleep 0.5
ps -axo pid,pgid,ppid,command | awk -v p="$pid" 'NR==1 || $1==p || $2==p'
kill -TERM -- "-$pid"; echo "kill -- -pid exit: $?"
sleep 0.5
echo "left:"; ps -axo pid,pgid,ppid,command | awk -v p="$pid" '$1==p || $2==p'
echo "== 3. fl_run_capture_timeout 1s deadline under load"
ncpu="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
hogs=()
for _ in $(seq 1 $((ncpu * 3))); do (while :; do :; done) & hogs+=($!); done
(. "$ROOT/lib/frappe-local/run.sh"
  for i in 1 2; do
    t0="$(now)"
    fl_run_capture_timeout 1 /dev/null /dev/null bash -c 'sleep 60 & wait' || true
    t1="$(now)"
    echo "round $i: deadline 1s took $(perl -e "printf '%.2f', $t1 - $t0")s"
  done
)
kill "${hogs[@]}" 2>/dev/null
echo "== load: $(uptime)"
