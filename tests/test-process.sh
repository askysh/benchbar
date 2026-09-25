#!/usr/bin/env bash
# Scoped process matching: benchdown must not kill "bench migrate" or "bench console".
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/frappe-bench"
OTHER="$HOME/other-bench"
make_fake_bench "$BENCH"
make_fake_bench "$OTHER" other
mkdir -p "$HOME/Library/LaunchAgents"

# service installed so "down" has an agent to talk to
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"

add_proc 100 "honcho start -f Procfile.lean"
add_proc 101 "$BENCH/env/bin/python -m frappe.utils.bench_helper frappe serve --port 8000"
add_proc 102 "$BENCH/env/bin/python -m frappe.utils.bench_helper frappe worker"
add_proc 103 "$BENCH/env/bin/python -m frappe.utils.bench_helper frappe schedule"
add_proc 104 "node apps/frappe/socketio.js"
add_proc 200 "$BENCH/env/bin/python -m frappe.utils.bench_helper frappe --site macdev migrate"
add_proc 201 "$BENCH/env/bin/python -m frappe.utils.bench_helper frappe --site macdev console"
add_proc 202 "$OTHER/env/bin/python -m frappe.utils.bench_helper frappe serve --port 8100"
add_proc 203 "$BENCH/env/bin/python -m frappe.utils.bench_helper frappe --site macdev execute frappe.ping"
add_proc 300 "redis-server config/redis_queue.conf"
add_listener 8000 101 python
add_listener 11000 300 redis-server
add_listener 3306 400 mariadbd

reset_calls
run_fm down --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "stopped"
assert_eq "manual" "$(cat "$BENCH/logs/.bench-stopped")"

for pid in 100 101 102 103 104; do
  ! grep -q "^${pid} " "$MOCK_PROCS" || fail "pid ${pid} should have been stopped"
done
for pid in 200 201 202 203; do
  grep -q "^${pid} " "$MOCK_PROCS" || fail "pid ${pid} (user command or other bench) must survive benchdown"
done
assert_calls_contain '^launchctl kill SIGTERM gui/[0-9]+/com.benchbar.frappe-bench$'
assert_calls_not_contain 'tcp:3306'

# ---- two benches: honcho and socketio look the same in both, the working folder decides
: >"$MOCK_PROCS"; : >"$MOCK_STATE/killed"
add_proc 500 "/x/bin/python /x/bin/honcho start -f Procfile.lean" "$BENCH"
add_proc 501 "node apps/frappe/socketio.js" "$BENCH"
add_proc 600 "/x/bin/python /x/bin/honcho start -f Procfile.lean" "$OTHER"
add_proc 601 "node apps/frappe/socketio.js" "$OTHER"
add_proc 602 "$OTHER/env/bin/python -m frappe.utils.bench_helper frappe worker" "$OTHER"
run_fm status --json --bench-dir "$OTHER"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["processes_running"]')"
run_fm down --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
for pid in 500 501; do ! grep -q "^${pid} " "$MOCK_PROCS" || fail "pid ${pid} of this bench should have been stopped"; done
for pid in 600 601 602; do grep -q "^${pid} " "$MOCK_PROCS" || fail "pid ${pid} of the other bench must survive benchdown"; done
# the stopped bench does not look running because the other one runs
run_fm status --json --bench-dir "$BENCH"
assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["processes_running"]')"
assert_eq "stopped" "$(printf '%s' "$OUT" | jget - 'd["state"]')"

# "down" while nothing runs is fine and idempotent
: >"$MOCK_PROCS"
run_fm down --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"

printf 'test-process: ok\n'
