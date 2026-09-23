#!/usr/bin/env bash
# Entrypoint behaviour: help, version, bench detection, up/restart/status, lock.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

run_fm --help; assert_eq "0" "$CODE"; assert_contains "$OUT" "install             Run phase 00"
run_fm; assert_eq "0" "$CODE"; assert_contains "$OUT" "Usage:"
run_fm --version; assert_contains "$OUT" "frappe-mac 0.2.0"
run_fm bogus; assert_eq "1" "$CODE"; assert_contains "$OUT" "Unknown command: bogus"
run_fm --nope; assert_eq "1" "$CODE"; assert_contains "$OUT" "Unknown option"

# no bench anywhere: doctor refuses with a hint
run_fm doctor; assert_eq "1" "$CODE"; assert_contains "$OUT" "No bench at ${HOME}/frappe-bench"

# auto-detection finds ~/dev/frappe-bench
BENCH="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH"
run_fm path; assert_eq "$BENCH" "$OUT"
# state wins over detection once recorded; the flag wins over state
OTHER="$HOME/other"; make_fake_bench "$OTHER" other
run_fm service --yes --bench-dir "$OTHER"; assert_eq "0" "$CODE" "$OUT"
run_fm path; assert_eq "$OTHER" "$OUT"
run_fm path --bench-dir "$BENCH"; assert_eq "$BENCH" "$OUT"
run_fm path --bench-dir "~/dev/frappe-bench"; assert_eq "$BENCH" "$OUT"
BENCH_DIR="$BENCH" run_fm path; assert_eq "$BENCH" "$OUT"

# site detection from the bench
run_fm status --bench-dir "$OTHER"; assert_contains "$OUT" "http://other:8000"
run_fm status --bench-dir "$OTHER" --site custom; assert_contains "$OUT" "http://custom:8000"

# up: arms the flag, kickstarts, waits for the ping
run_fm service --yes --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
printf 'old log line\n' >"$BENCH/logs/bench.log"
export MOCK_KICKSTART_PING=200
run_fm up --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "bench is up: http://macdev:8000"
assert_no_file "$BENCH/logs/.bench-stopped"
assert_calls_contain '^launchctl kickstart gui/[0-9]+/com.frappe-mac.frappe-bench$'
grep -q 'old log line' "$BENCH/logs/bench.previous.log" || fail "previous log must be kept"
[[ ! -s "$BENCH/logs/bench.log" ]] || fail "bench.log must start fresh"

# up when already running is a no-op
reset_calls
run_fm up --bench-dir "$BENCH"
assert_contains "$OUT" "already running"
assert_calls_not_contain '^launchctl kickstart'

# status while running
run_fm status --bench-dir "$BENCH"
assert_contains "$OUT" "state      running, pid 4242"
assert_contains "$OUT" "web ping   200"
assert_contains "$OUT" "[OK] site responds"

# restart uses kickstart -k
reset_calls
run_fm restart --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^launchctl kickstart -k gui/[0-9]+/com.frappe-mac.frappe-bench$'

# down, then up again after a crash pause clears the history
run_fm down --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
printf 'crash\n' >"$BENCH/logs/.bench-stopped"; printf '1\n2\n3\n' >"$BENCH/logs/.bench-starts"
run_fm up --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
[[ ! -s "$BENCH/logs/.bench-starts" ]] || fail "start history must be cleared by up"
unset MOCK_KICKSTART_PING

# up without the service installed explains what to do
NEW="$HOME/new"; make_fake_bench "$NEW" newsite
run_fm up --bench-dir "$NEW"; assert_eq "1" "$CODE"; assert_contains "$OUT" "not installed"

# logs without follow
printf 'line1\nline2\n' >"$BENCH/logs/bench.log"
run_fm logs --no-follow --bench-dir "$BENCH"; assert_contains "$OUT" "line2"
run_fm logs --worker --no-follow --bench-dir "$BENCH"; assert_contains "$OUT" "no log yet"

# lock: a second concurrent mutating run is refused, a stale lock is reclaimed
mkdir -p "$FL_STATE_DIR/lock"; printf '%s\n' "$$" >"$FL_STATE_DIR/lock/pid"
run_fm service --yes --bench-dir "$BENCH"; assert_eq "1" "$CODE"; assert_contains "$OUT" "Another frappe-mac run is active"
printf '999999\n' >"$FL_STATE_DIR/lock/pid"
run_fm service --yes --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "Reclaiming stale lock"
assert_no_file "$FL_STATE_DIR/lock"

# a run log is written for mutating commands
[[ -n "$(ls "$FL_STATE_DIR"/logs/*.log 2>/dev/null)" ]] || fail "run log expected"

# the phase-02 wrapper works
OUT="$("$ROOT/02-background-service.sh" --yes --bench-dir "$BENCH" 2>&1)"; assert_contains "$OUT" "unchanged"

printf 'test-cli: ok\n'
