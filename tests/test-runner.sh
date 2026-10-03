#!/usr/bin/env bash
# The generated runner: crash guard, stop flag, missing honcho, and the
# state.json it writes on every transition.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
. "$ROOT/lib/frappe-local/ui.sh"
. "$ROOT/lib/frappe-local/run.sh"
. "$ROOT/lib/frappe-local/templates.sh"
. "$ROOT/lib/frappe-local/process.sh"

BENCH="$TMP_DIR/bench"
make_fake_bench "$BENCH"
FL_BENCH_DIR="$BENCH"
HONCHO="$MOCK_PIPX_HOME/venvs/frappe-bench/bin/honcho"
runner="$BENCH/benchbar-run.sh"
fl_template_render bench-run.sh "BENCH_DIR=$BENCH" "BENCH_RE=$(fl_regex_escape "$BENCH")" "BENCH_NAME=bench" \
  "HONCHO=$HONCHO" "PORTS=8000,9000,11000,13000" "LABEL=com.benchbar.bench" "MAX_STARTS=3" "WINDOW=600" \
  "SITE=macdev" "WEB_PORT=8000" "CLI_VERSION=9.9.9" >"$runner"
chmod +x "$runner"
bash -n "$runner"

flag="$BENCH/logs/.bench-stopped"; hist="$BENCH/logs/.bench-starts"
state="$BENCH/logs/.benchbar/state.json"
export BENCHBAR_STATE_LOG="$TMP_DIR/transitions.log" BENCHBAR_PING_EVERY=0 BENCHBAR_PING_TRIES=20
: >"$BENCHBAR_STATE_LOG"
# transitions: the state sequence written since the last reset, e.g. "starting stopped"
transitions() { python3 -c 'import json,sys; print(" ".join(json.loads(l)["state"] for l in open(sys.argv[1]) if l.strip()))' "$BENCHBAR_STATE_LOG"; }
reset_transitions() { : >"$BENCHBAR_STATE_LOG"; }

# 1. normal start: leftovers of this bench are cleared, honcho runs
add_proc 111 "$BENCH/env/bin/python -m frappe.utils.bench_helper frappe serve --port 8000"
add_proc 222 "$BENCH/env/bin/python -m frappe.utils.bench_helper frappe --site macdev migrate"
add_proc 333 "node apps/frappe/socketio.js" "$BENCH"
add_proc 444 "node apps/frappe/socketio.js" "$HOME/another-bench"
assert_status 0 "$runner"
grep -q '^444 ' "$MOCK_PROCS" || fail "another bench's socketio must survive this runner's cleanup"
assert_calls_contain '^honcho start -f Procfile.lean$'
grep -q '^222 ' "$MOCK_PROCS" || fail "bench migrate must survive the runner cleanup"
! grep -q '^111 ' "$MOCK_PROCS" || fail "stale serve must be cleared"
! grep -q '^333 ' "$MOCK_PROCS" || fail "stale socketio must be cleared"
assert_eq "1" "$(wc -l <"$hist" | tr -d ' ')"
assert_no_file "$flag"
assert_eq "starting stopped" "$(transitions)" "(honcho exiting 0 is a clean stop)"
assert_eq "1" "$(jget "$state" 'd["schema_version"]')"
assert_eq "9.9.9" "$(jget "$state" 'd["cli_version"]')"
assert_eq "None 0 http://macdev:8000 runner" "$(jget "$state" 'd["stop_reason"], d["last_exit_code"], d["web_url"], d["source"]' | tr -d "(),'")"
[[ -z "$(find "$BENCH/logs/.benchbar" -name '.state.json.*')" ]] || fail "no temp files may be left behind"

# 1b. listeners on the bench's ports: only one whose working folder is this
# bench is cleared. A foreign program, another bench's redis and a process
# whose folder cannot be read stay, and the runner pauses with port_conflict
# instead of starting honcho into ports it cannot bind.
reset_calls; reset_transitions; : >"$hist"; : >"$MOCK_PROCS"; : >"$MOCK_STATE/killed"
add_proc 555 "python3 -m http.server 8000" "$HOME/some-project"
add_proc 666 "redis-server config/redis_queue.conf" "$HOME/another-bench/config/pids"
add_proc 777 "redis-server config/redis_cache.conf" "$BENCH"
add_proc 888 "node server.js"
rm -f "$MOCK_STATE/cwd/888"
add_listener 8000 555 python3
add_listener 11000 666 redis-server
add_listener 13000 777 redis-server
add_listener 9000 888 node
assert_status 0 "$runner"
grep -q '^555 ' "$MOCK_PROCS" || fail "a foreign listener on the web port must survive the runner cleanup"
grep -q '^666 ' "$MOCK_PROCS" || fail "another bench's redis on this bench's port must survive the runner cleanup"
grep -q '^888 ' "$MOCK_PROCS" || fail "a listener whose folder cannot be read must survive the runner cleanup"
! grep -q '^777 ' "$MOCK_PROCS" || fail "this bench's own leftover redis must be cleared"
assert_calls_not_contain '^honcho' "(honcho must not start into held ports)"
assert_calls_not_contain '^mockkill .*(555|666|888)'
assert_eq "port_conflict" "$(cat "$flag")"
assert_eq "paused" "$(transitions)"
assert_eq "paused port_conflict" "$(jget "$state" 'd["state"], d["stop_reason"]' | tr -d "(),'")"
grep -q 'held by processes that are not this bench' "$BENCH/logs/bench.log" || fail "the held ports must be logged"
assert_calls_contain '^osascript .*Another program holds'
: >"$MOCK_LISTEN"; : >"$MOCK_PROCS"; rm -f "$flag"; : >"$hist"

# 2. stop flag: exit 0 without starting anything
reset_calls
printf 'manual\n' >"$flag"
reset_transitions
assert_status 0 "$runner"
assert_calls_not_contain '^honcho'
assert_eq "stopped" "$(transitions)"
assert_eq "manual" "$(jget "$state" 'd["stop_reason"]')"
rm -f "$flag"

# 3. crash guard: three recent starts, a fourth attempt pauses with "crash"
reset_calls
now="$(date +%s)"
printf '%s\n%s\n%s\n' "$((now - 500))" "$((now - 300))" "$((now - 100))" >"$hist"
reset_transitions
assert_status 0 "$runner"
assert_eq "crash" "$(cat "$flag")"
assert_eq "paused" "$(transitions)"
assert_eq "crash" "$(jget "$state" 'd["stop_reason"]')"
assert_calls_contain '^osascript .*Crashed 3 times in 10 minutes'
assert_calls_not_contain '^honcho'
grep -q 'auto-restart paused' "$BENCH/logs/bench.log" || fail "pause must be logged"
[[ ! -s "$hist" ]] || fail "start history must be cleared after the pause"

# 4. old starts outside the window do not count
reset_calls; rm -f "$flag"
printf '%s\n%s\n%s\n' "$((now - 5000))" "$((now - 4000))" "$((now - 3000))" >"$hist"
assert_status 0 "$runner"
assert_calls_contain '^honcho start'
assert_no_file "$flag"
assert_eq "1" "$(wc -l <"$hist" | tr -d ' ')"

# 5. honcho missing: pause with "broken" and notify, never loop
reset_calls; rm -f "$flag"; : >"$hist"
mv "$HONCHO" "$HONCHO.gone"
assert_status 0 "$runner"
assert_eq "broken" "$(cat "$flag")"
assert_calls_contain '^osascript .*honcho is missing'
assert_eq "paused broken" "$(jget "$state" 'd["state"], d["stop_reason"]' | tr -d "(),'")"
mv "$HONCHO.gone" "$HONCHO"

# 6. env missing: same
reset_calls; rm -f "$flag"
mv "$BENCH/env" "$BENCH/env.gone"
assert_status 0 "$runner"
assert_eq "broken" "$(cat "$flag")"
mv "$BENCH/env.gone" "$BENCH/env"

# 7. honcho crashing propagates a non-zero exit so launchd restarts (KeepAlive SuccessfulExit=false)
rm -f "$flag"; : >"$hist"
reset_transitions
MOCK_HONCHO_EXIT=1 assert_status 1 "$runner"
assert_eq "starting crashed" "$(transitions)"
assert_eq "crash 1" "$(jget "$state" 'd["stop_reason"], d["last_exit_code"]' | tr -d "(),'")"
grep -q 'honcho exited with code 1' "$BENCH/logs/bench.log" || fail "the crash exit code must be logged"

# 8. the site answers: starting, then running with the runner pid, then a clean stop
: >"$hist"; reset_transitions
export MOCK_CURL_CODE=200
MOCK_HONCHO_SLEEP=3 assert_status 0 "$runner"
assert_eq "starting running stopped" "$(transitions)"
python3 - "$BENCHBAR_STATE_LOG" <<'PYCHECK' || fail "running must carry the runner pid, started_at and ping 200"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
run = [r for r in rows if r["state"] == "running"][0]
assert isinstance(run["pid"], int) and run["pid"] > 0, run
assert run["web_ping_code"] == 200, run
assert run["started_at"].endswith("Z"), run
assert rows[0]["pid"] == run["pid"], rows
PYCHECK
export MOCK_CURL_CODE=000

# 9. benchdown while running: SIGTERM reaches honcho, the runner records a manual stop and exits 0
: >"$hist"; reset_transitions
MOCK_HONCHO_SLEEP=30 "$runner" &
rpid=$!
for _ in $(seq 1 50); do [[ "$(transitions)" == "starting" ]] && break; sleep 0.1; done
assert_eq "starting" "$(transitions)"
printf 'manual\n' >"$flag"
kill -TERM "$rpid"
set +e; wait "$rpid"; rcode=$?; set -e
assert_eq "0" "$rcode" "(a manual stop must exit 0 so launchd does not restart)"
assert_eq "starting stopped" "$(transitions)"
assert_eq "manual" "$(jget "$state" 'd["stop_reason"]')"
rm -f "$flag"

# 10. SIGTERM without a stop flag (restart, logout) is a stop, not a crash
: >"$hist"; reset_transitions
MOCK_HONCHO_SLEEP=30 MOCK_HONCHO_TERM_EXIT=143 "$runner" &
rpid=$!
for _ in $(seq 1 50); do [[ "$(transitions)" == "starting" ]] && break; sleep 0.1; done
kill -TERM "$rpid"
set +e; wait "$rpid"; rcode=$?; set -e
assert_eq "0" "$rcode"
assert_eq "starting stopped" "$(transitions)"
assert_eq "None" "$(jget "$state" 'd["stop_reason"]')"

# 11. no macOS notification while the BenchBar app runs (it notifies itself)
reset_calls; : >"$flag"; rm -f "$flag"
printf '%s\n%s\n%s\n' "$((now - 50))" "$((now - 40))" "$((now - 30))" >"$hist"
add_proc 999 "BenchBar"
assert_status 0 "$runner"
assert_eq "crash" "$(cat "$flag")"
assert_calls_not_contain '^osascript'

# 12. the heartbeat: rewritten in place while honcho runs (same inode, the
# folder unchanged, so no folder watcher wakes), never through state.json,
# and no more beats once the runner has exited
rm -f "$flag"; : >"$hist"; reset_transitions
hb="$BENCH/logs/.benchbar/heartbeat"
rm -f "$hb"
# ino_mtime PATH: inode and nanosecond mtime
ino_mtime() { python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_ino, s.st_mtime_ns)' "$1"; }
# honcho runs until the checks are done, then stops on TERM as in test 10:
# a fixed honcho lifetime raced the checks on a slow machine (the stopped
# write is a folder change of its own)
BENCHBAR_HEARTBEAT_EVERY=1 MOCK_HONCHO_SLEEP=30 MOCK_HONCHO_TERM_EXIT=143 "$runner" &
rpid=$!
for _ in $(seq 1 50); do [[ "$(transitions)" == "starting" ]] && break; sleep 0.1; done
assert_eq "starting" "$(transitions)"
assert_file "$hb"
file1="$(ino_mtime "$hb")"; dir1="$(ino_mtime "$BENCH/logs/.benchbar")"
beats=" $(cat "$hb") "
for _ in $(seq 1 12); do
  sleep 0.25
  b="$(cat "$hb" 2>/dev/null || true)"
  [[ -n "$b" && "$beats" != *" $b "* ]] && beats="${beats}${b} "
done
[[ "$(printf '%s' "$beats" | wc -w | tr -d ' ')" -ge 3 ]] || fail "the heartbeat must be rewritten while honcho runs (saw:${beats})"
assert_eq "${file1%% *}" "$(ino_mtime "$hb" | cut -d' ' -f1)" "(the heartbeat is written in place, not replaced)"
assert_eq "$dir1" "$(ino_mtime "$BENCH/logs/.benchbar")" "(a beat must not change the folder)"
assert_eq "starting" "$(transitions)" "(honcho still runs while the folder is compared)"
kill -TERM "$rpid"
set +e; wait "$rpid"; rcode=$?; set -e
assert_eq "0" "$rcode"
assert_eq "starting stopped" "$(transitions)" "(the heartbeat never writes state.json)"
last="$(cat "$hb")"
sleep 2.5
assert_eq "$last" "$(cat "$hb")" "(no beats after the runner exited)"

printf 'test-runner: ok\n'
