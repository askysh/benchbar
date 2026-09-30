# BenchBar 0.6.0 cost at rest: baseline

Recorded on 2026-09-30 before any 0.6.1 change, on Akash's Mac: BenchBar
0.6.0 running for 11 hours, its window closed (created earlier in this app
session, now offscreen), popover closed, two registered benches with
`frappe-bench` up (site `macdev`, ping 200) and `migration-16` stopped.
Every later phase is measured against the numbers here.

## Snapshot

Output verbatim. The `log show` line was run as `/usr/bin/log` because
zsh's builtin `log` shadows it.

```
$ sw_vers; sysctl -n machdep.cpu.brand_string
ProductName:		macOS
ProductVersion:		27.0
BuildVersion:		26A428
Apple M4
$ benchbar --version
benchbar 0.6.0
BenchBar app 0.6.0 (/Users/akash/Applications/BenchBar.app)
$ ps -eo pid,etime,cputime,%cpu,comm | grep -i benchbar
50662    11:13:14   0:16.92   0.3 /Users/akash/Applications/BenchBar.app/Contents/MacOS/BenchBar
$ /usr/bin/time -l benchbar status --json >/dev/null
        0.93 real         0.41 user         0.45 sys
            49168384  maximum resident set size
                   0  average shared memory size
                   0  average unshared data size
                   0  average unshared stack size
              159914  page reclaims
                 660  page faults
                   0  swaps
                   0  block input operations
                   0  block output operations
                   2  messages sent
                   2  messages received
                 259  signals received
                2731  voluntary context switches
                1982  involuntary context switches
           446211417  instructions retired
           149014509  cycles elapsed
             5046656  peak memory footprint
$ /usr/bin/time -l benchbar list --json >/dev/null
        0.37 real         0.12 user         0.27 sys
             5865472  maximum resident set size
                   0  average shared memory size
                   0  average unshared data size
                   0  average unshared stack size
               84415  page reclaims
                 122  page faults
                   0  swaps
                   0  block input operations
                   0  block output operations
                   1  messages sent
                   2  messages received
                 162  signals received
                 846  voluntary context switches
                1013  involuntary context switches
           425410176  instructions retired
           129734724  cycles elapsed
             4981120  peak memory footprint
$ /usr/bin/log show --predicate 'process == "BenchBar"' --last 30m --style compact | wc -l
      51
```

## Ten minutes at rest

Nothing was opened between the two readings.

```
# window start 2026-09-30T04:54:37Z
$ ps -eo pid,etime,cputime,%cpu,comm | grep -i benchbar
50662    11:14:23   0:17.01   0.0 /Users/akash/Applications/BenchBar.app/Contents/MacOS/BenchBar
# window end 2026-09-30T05:04:37Z
$ ps -eo pid,etime,cputime,%cpu,comm | grep -i benchbar
50662    11:24:23   0:17.72   0.0 /Users/akash/Applications/BenchBar.app/Contents/MacOS/BenchBar
```

**Average CPU at rest: (17.72 s minus 17.01 s) / 600 s = 0.12 percent.**

## What that number leaves out

`ps` reports a process's own CPU time only. The `benchbar` processes the
app starts are its children, and their CPU is not in it, although macOS
bills their energy to BenchBar. `proc_pid_rusage` (RUSAGE_INFO_V6) has the
CPU of every child the app has reaped, including their own children, in
`ri_child_user_time` and `ri_child_system_time`. Read at the same two
moments (a 20 line Swift probe; its `own` matches `ps` to the hundredth):

```
start  own_cpu_s=17.010 child_cpu_s=374.624 pkg_idle_wkups=2764 child_pkg_idle_wkups=8438
end    own_cpu_s=17.723 child_cpu_s=410.905 pkg_idle_wkups=2838 child_pkg_idle_wkups=8780
```

| | CPU in 600 s | average |
|---|---|---|
| BenchBar itself | 0.71 s | 0.12 % |
| its `benchbar` children | 36.28 s | 6.05 % |
| total | 36.99 s | 6.16 % |

Over the app's 11 hour life so far the children used 372.7 s against 17.0 s
of its own: 22 times more.

A 1 second sampler of the app's children saw 31 `benchbar status --json
--bench-dir ...` calls in the ten minutes (16 for frappe-bench, 15 for
migration-16), in pairs every 31 to 32 seconds; the gaps at 04:58 and 05:01
are pairs that finished between two samples, so about 38 ran. That is the
30 second cadence for both benches: the 5 second window poll was not stuck
on in this app session. At about 0.95 s of CPU per call, the stuck case
(a pair every 5 seconds) would cost about 38 percent of a core.

## Cost of one call

Execs counted by running the command with a shim for every program on
PATH (the status path calls nothing by absolute path); forks as the PID
counter delta around an unshimmed run, best of three, an upper bound since
other processes fork too.

| command | execs | forks | biggest |
|---|---|---|---|
| `status --json` (frappe-bench, running) | 212 | 576 | sed 52, awk 31, head 21, tr 19, tail 19, cksum 16, basename 10, lsof 9, shasum 4, launchctl 4, id 4, cut 4, pgrep 3, curl 2, brew 1, pipx 1, uv 1, uname 1 |
| `status --json` (migration-16, stopped) | 198 | 568 | sed 45, awk 33, tr 22, cksum 17, tail 16, head 16, basename 11, lsof 4, launchctl 4, pgrep 3, curl 1, brew 1, pipx 1, uv 1 |
| `list --json` (2 benches) | 119 | 323 | sed 33, tr 20, awk 15, head 12, basename 9, tail 8, cksum 8, lsof 2, curl 1 |

## How every phase measures

The same four readings after each phase, on this Mac, with the phase's
CLI and app running, the window and popover closed and one bench up.

**1. Ten minutes at rest.** Build the probe once, then read it at the
start and the end of ten untouched minutes. Average CPU is each delta
over 600 s: own (the `ps` figure), children, and their total.

```bash
cat >/tmp/rusage.swift <<'SWIFT'
import Darwin
// rusage <pid>: own and reaped-children CPU seconds from proc_pid_rusage
let pid = Int32(CommandLine.arguments[1])!
var info = rusage_info_v6()
let rc = withUnsafeMutablePointer(to: &info) { p -> Int32 in
  p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
}
guard rc == 0 else { print("proc_pid_rusage failed \(errno)"); exit(1) }
var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
func sec(_ t: UInt64) -> Double { Double(t) * Double(tb.numer) / Double(tb.denom) / 1e9 }
print("own_cpu_s=\(sec(info.ri_user_time + info.ri_system_time)) child_cpu_s=\(sec(info.ri_child_user_time + info.ri_child_system_time))")
SWIFT
swiftc -O /tmp/rusage.swift -o /tmp/rusage
ps -eo pid,etime,cputime,%cpu,comm | grep -i benchbar; /tmp/rusage "$(pgrep -x BenchBar)"
sleep 600
ps -eo pid,etime,cputime,%cpu,comm | grep -i benchbar; /tmp/rusage "$(pgrep -x BenchBar)"
```

**2. What the app starts.** A 1 second sampler of the app's direct
children for the same ten minutes (from Phase 3 on, the app also logs one
`.info` line per CLI call):

```bash
app=$(pgrep -x BenchBar); seen=" "
end=$(( $(date +%s) + 600 ))
while [ "$(date +%s)" -lt "$end" ]; do
  for p in $(pgrep -P "$app"); do
    case "$seen" in *" $p "*) continue ;; esac
    seen="$seen$p "; echo "$(date -u +%T) $p $(ps -o command= -p "$p")"
  done
  sleep 1
done
/usr/bin/log show --predicate 'subsystem == "com.akashmishra.benchbar"' --last 10m --style compact | grep -c 'cli:'
```

**3. One call.** `/usr/bin/time -l` on `status --json` and `list --json`,
through the `~/.local/bin/benchbar` link as the app runs it.

**4. Programs per call.** Every program on PATH shimmed to log its name
(the status and list paths call nothing by absolute path), and forks as
the PID counter's delta around an unshimmed run, best of three:

```bash
mkdir -p /tmp/shims && cat >/tmp/shims/_shim <<'SH'
#!/bin/sh
n=${0##*/}; echo "$n" >>"$SPAWN_LOG"; IFS=:
for d in $SPAWN_REAL_PATH; do [ -x "$d/$n" ] && [ ! -d "$d/$n" ] && exec "$d/$n" "$@"; done
exit 127
SH
chmod +x /tmp/shims/_shim
IFS=: read -r -a dirs <<<"$PATH"
for d in "${dirs[@]}"; do for f in "$d"/*; do n=${f##*/}; [ -x "$f" ] && [ ! -e "/tmp/shims/$n" ] && ln -s _shim "/tmp/shims/$n"; done; done
: >/tmp/spawn.log
SPAWN_LOG=/tmp/spawn.log SPAWN_REAL_PATH=$PATH PATH=/tmp/shims:$PATH benchbar status --json >/dev/null
sort /tmp/spawn.log | uniq -c | sort -rn
a=$(sh -c 'echo $$'); benchbar status --json >/dev/null; b=$(sh -c 'echo $$'); echo "forks $((b - a - 1))"
```

`tests/test-status-cost.sh` holds the same budgets under the mocks, so a
change that adds a process to a poll fails the suite.
