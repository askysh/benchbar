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
add_proc 104 "node apps/frappe/socketio.js" "$BENCH"
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

# ---- a listener on this bench's port that runs elsewhere is not this bench's
: >"$MOCK_PROCS"; : >"$MOCK_LISTEN"; : >"$MOCK_STATE/killed"
add_proc 700 "python3 -m http.server 8000" "$HOME/some-project"
add_proc 701 "redis-server config/redis_cache.conf" "$BENCH"
add_listener 8000 700 python3
add_listener 13000 701 redis-server
run_fm down --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
grep -q "^700 " "$MOCK_PROCS" || fail "an unrelated server on the bench's web port must survive benchdown"
! grep -q "^701 " "$MOCK_PROCS" || fail "the bench's own redis listener should have been stopped"

# a listener whose folder cannot be read is not proven to be this bench's
: >"$MOCK_PROCS"; : >"$MOCK_LISTEN"; : >"$MOCK_STATE/killed"
add_proc 702 "node server.js"
rm -f "$MOCK_STATE/cwd/702"
add_listener 9000 702 node
run_fm down --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
grep -q "^702 " "$MOCK_PROCS" || fail "a listener with an unreadable folder must survive benchdown"

# the one ownership test: a pid whose folder lsof cannot read is never "ours",
# nor is one running in another folder; honcho and socketio go through it too
: >"$MOCK_PROCS"; mkdir -p "$MOCK_STATE/cwd"
add_proc 801 "/x/bin/honcho start -f Procfile.lean"; rm -f "$MOCK_STATE/cwd/801"
add_proc 802 "/x/bin/honcho start -f Procfile.lean" "$OTHER"
add_proc 803 "/x/bin/honcho start -f Procfile.lean" "$BENCH"
add_proc 804 "node apps/frappe/socketio.js" "$BENCH/sites"
own="$(FL_BENCH_DIR="$BENCH" bash -c '. "$0/lib/frappe-local/process.sh"; printf "801\n802\n803\n804\n" | fl_pids_in_bench | tr "\n" " "' "$ROOT")"
assert_eq "803 804 " "$own" "(only pids whose folder is this bench, or inside it, are this bench's)"
FL_BENCH_DIR="$BENCH" bash -c '. "$0/lib/frappe-local/process.sh"; fl_pid_is_bench_own_strict 801' "$ROOT" && fail "an unreadable folder must not count as this bench's"
FL_BENCH_DIR="$BENCH" bash -c '. "$0/lib/frappe-local/process.sh"; fl_pid_is_bench_own_strict 803' "$ROOT" || fail "a folder inside the bench is this bench's"
# down leaves the honcho with the unreadable folder and the other bench's alone
# (the agent is unloaded here: the launchctl mock's kill would take the
# folderless honcho as the agent's own job)
mv "$MOCK_STATE/agents/com.benchbar.frappe-bench" "$MOCK_STATE/agent.saved"
run_fm down --bench-dir "$BENCH"
mv "$MOCK_STATE/agent.saved" "$MOCK_STATE/agents/com.benchbar.frappe-bench"
assert_eq "0" "$CODE" "$OUT"
grep -q "^801 " "$MOCK_PROCS" || fail "an honcho whose folder cannot be read must survive benchdown"
grep -q "^802 " "$MOCK_PROCS" || fail "the other bench's honcho must survive benchdown"
! grep -q "^803 " "$MOCK_PROCS" || fail "this bench's honcho should have been stopped"
: >"$MOCK_PROCS"

# "down" while nothing runs is fine and idempotent
: >"$MOCK_PROCS"
run_fm down --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"

printf 'test-process: ok\n'
