#!/usr/bin/env bash
# benchbar stats: the CPU and memory of a running bench's own processes. The
# set is the one down stops (fl_bench_process_pids) plus its descendants; a
# stopped bench, a bench with no processes and a Redis kept alone by
# up --services-only have resources null. macOS reads one ps table, Linux
# reads /proc in bash (CPU from two samples). Never part of status.
# shellcheck disable=SC2016  # bash -c scripts are quoted on purpose
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/frappe-bench"
OTHER="$HOME/other-bench"
make_fake_bench "$BENCH"
make_fake_bench "$OTHER" other
HONCHO="honcho start -f Procfile.lean"
SIO="node apps/frappe/socketio.js"

# pstable PID PPID CPU RSS: a row of the ps mock's table
pstable() { printf '%s %s %s %s\n' "$@" >>"$MOCK_STATE/pstable"; }
# res EXPR: a Python expression on the document of the last stats --json
res() { printf '%s' "$OUT" | jget - "$1"; }
one_line() { [[ "$(printf '%s' "$OUT" | wc -l | tr -d ' ')" -le 1 ]] || fail "stats --json must be one document on one line: $OUT"; }

# ---- macOS: one ps call; the roots are honcho, socketio and the listeners
add_proc 701 "$HONCHO" "$BENCH"
add_proc 703 "$SIO" "$BENCH"
add_proc 810 "$HONCHO" "$OTHER"
: >"$MOCK_STATE/pstable"
pstable 1 0 0.0 4000
pstable 701 1 0.5 1000        # honcho
pstable 702 701 12.3 20000    # serve, a child of honcho
pstable 703 702 100 5000      # socketio, started by serve
pstable 704 703 0.0 300       # node watch, a child of socketio
pstable 800 1 50.0 99999      # a stranger: never counted
pstable 810 1 40.0 88888      # another bench's honcho: never counted
run_fm stats --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
one_line
assert_eq "True" "$(res 'd["running"]')" "$OUT"
assert_eq "4" "$(res 'd["resources"]["processes"]')" "(honcho, serve, socketio and its child; the strangers stay out) $OUT"
assert_eq "112.8" "$(res 'd["resources"]["cpu_percent"]')" "$OUT"
assert_eq "$(((1000 + 20000 + 5000 + 300) * 1024))" "$(res 'd["resources"]["memory_bytes"]')" "$OUT"
assert_eq "ps" "$(res 'd["resources"]["cpu_source"]')" "$OUT"
assert_eq "None" "$(res 'd["resources"]["window_ms"]')" "$OUT"
assert_eq "12.0" "$(res 'd["resources"]["speed"]["raw"]')" "(112.8 percent is past the top speed) $OUT"
assert_eq "0.35" "$(res 'd["resources"]["speed"]["smoothing_alpha"]')" "$OUT"
case "$(res 'd["resources"]["sampled_at"]')" in 20??-??-??T??:??:??Z) ;; *) fail "sampled_at is not an ISO time: $OUT" ;; esac
assert_eq "$BENCH" "$(res 'd["bench_dir"]')" "$OUT"

# a quiet bench: the CPU keeps its decimal and the speed is 1 + percent / 10
: >"$MOCK_STATE/pstable"
pstable 701 1 0.0 1000
pstable 703 701 3.4 2000
run_fm stats --json --bench-dir "$BENCH"
assert_eq "2" "$(res 'd["resources"]["processes"]')" "$OUT"
assert_eq "3.4" "$(res 'd["resources"]["cpu_percent"]')" "$OUT"
assert_eq "1.34" "$(res 'd["resources"]["speed"]["raw"]')" "$OUT"

# the readable form
run_fm stats --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "3.4% of one core" "$OUT"
assert_contains "$OUT" "processes" "$OUT"

# ---- stopped, and a bench with no processes: resources is null, no ps table needed
: >"$MOCK_PROCS"
run_fm stats --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "False" "$(res 'd["running"]')" "$OUT"
assert_eq "None" "$(res 'd["resources"]')" "$OUT"
run_fm stats --bench-dir "$BENCH"
assert_contains "$OUT" "not running" "$OUT"

# only the bench's own Redis (up --services-only): not a running bench
add_proc 720 "redis-server *:11000" "$BENCH"
add_listener 11000 720 redis-server
run_fm stats --json --bench-dir "$BENCH"
assert_eq "None" "$(res 'd["resources"]')" "(a Redis alone is no serving bench) $OUT"
: >"$MOCK_PROCS"; : >"$MOCK_LISTEN"

# status stays lean: no resources there, and stats is not in its JSON
add_proc 701 "$HONCHO" "$BENCH"
run_fm status --json --bench-dir "$BENCH"
case "$OUT" in *'"resources"'*) fail "status --json must not carry resources: $OUT" ;; esac
: >"$MOCK_PROCS"

# the same command through --for-agent
add_proc 701 "$HONCHO" "$BENCH"
run_fm stats --for-agent --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "2" "$(res 'd["resources"]["processes"]')" "$OUT"
: >"$MOCK_PROCS"

# ---- Linux: /proc in bash, CPU from two samples
use_linux
P="$FL_PROC_DIR"
# mkproc PID PPID TICKS RSS_KB: /proc/PID/stat and status (the command name holds a space and a parenthesis, as real ones can)
mkproc() {
  mkdir -p "$FL_PROC_DIR/$1"
  printf '%s (node (x y)) S %s 1 1 0 -1 4194560 100 0 0 0 %s 0 0 0 20 0 1 0 100 1000 100 18446744073709551615\n' "$1" "$2" "$3" >"$FL_PROC_DIR/$1/stat"
  printf 'Name:\tx\nVmPeak:\t99999 kB\nVmRSS:\t%s kB\nThreads:\t1\n' "$4" >"$FL_PROC_DIR/$1/status"
}
export -f mkproc
printf '1000.00 3000.00\n' >"$P/uptime"
rm -rf "$P"
mkdir -p "$P"
printf '1000.00 3000.00\n' >"$P/uptime"
: >"$MOCK_PROCS"
add_proc 701 "$HONCHO" "$BENCH"
mkproc 1 0 5000 8000
mkproc 701 1 100 2048
mkproc 702 701 400 4096
mkproc 703 702 0 512
mkproc 800 1 9999 77777

# lib_run CODE: the libraries as benchbar loads them, with a sleep that lets 0.5 s pass
# and gives pid 702 25 ticks (half of one core for that half second)
lib_run() {
  SCRIPT_DIR="$ROOT" FL_BENCH_DIR="$BENCH" FL_WEB_PORT=8000 FL_SOCKETIO_PORT=9000 FL_REDIS_QUEUE_PORT=11000 FL_REDIS_CACHE_PORT=13000 FL_LOG_FILE=/dev/null FL_SCHEMA_VERSION=1 \
    bash -c 'for f in ui run platform benchinfo process port-management stats; do . "$SCRIPT_DIR/lib/frappe-local/$f.sh"; done; fl_platform_load
      sleep() { printf "1000.50 3000.00\n" >"$FL_PROC_DIR/uptime"; mkproc 702 701 425 4096; }
      eval "$1"' _ "$1"
}
res_lin="$(lib_run 'fl_stats_resources_v r; printf "%s" "$r"')"
OUT="{\"resources\":${res_lin}}"
assert_eq "3" "$(res 'd["resources"]["processes"]')" "(honcho, its child and the grandchild; the stranger stays out) $OUT"
assert_eq "50.0" "$(res 'd["resources"]["cpu_percent"]')" "(25 ticks in 0.5 s) $OUT"
assert_eq "$(((2048 + 4096 + 512) * 1024))" "$(res 'd["resources"]["memory_bytes"]')" "$OUT"
assert_eq "proc_delta" "$(res 'd["resources"]["cpu_source"]')" "$OUT"
assert_eq "500" "$(res 'd["resources"]["window_ms"]')" "$OUT"
assert_eq "6.0" "$(res 'd["resources"]["speed"]["raw"]')" "(1 + 50 / 10) $OUT"

# a pid that exits between the samples drops out; the rest still count
res_lin="$(lib_run 'sleep() { printf "1000.50 3000.00\n" >"$FL_PROC_DIR/uptime"; rm -rf "$FL_PROC_DIR/703"; }; fl_stats_resources_v r; printf "%s" "$r"')"
OUT="{\"resources\":${res_lin}}"
assert_eq "2" "$(res 'd["resources"]["processes"]')" "$OUT"
assert_eq "0.0" "$(res 'd["resources"]["cpu_percent"]')" "$OUT"

# the whole command, with a short window (the mocks keep every counter still)
mkproc 702 701 400 4096; mkproc 703 702 0 512
printf '1000.00 3000.00\n' >"$P/uptime"
FL_STATS_WINDOW=0.05 run_fm stats --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "True" "$(res 'd["running"]')" "$OUT"
assert_eq "3" "$(res 'd["resources"]["processes"]')" "$OUT"
assert_eq "proc_delta" "$(res 'd["resources"]["cpu_source"]')" "$OUT"

# stopped on Linux
: >"$MOCK_PROCS"
run_fm stats --json --bench-dir "$BENCH"
assert_eq "None" "$(res 'd["resources"]')" "$OUT"
printf 'ok\n'
