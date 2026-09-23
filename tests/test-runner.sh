#!/usr/bin/env bash
# The generated runner: crash guard, stop flag, missing honcho.
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
runner="$BENCH/frappe-mac-run.sh"
fl_template_render bench-run.sh "BENCH_DIR=$BENCH" "BENCH_RE=$(fl_regex_escape "$BENCH")" "BENCH_NAME=bench" \
  "HONCHO=$HONCHO" "PORTS=8000,9000,11000,13000" "LABEL=com.benchbar.bench" "MAX_STARTS=3" "WINDOW=600" >"$runner"
chmod +x "$runner"
bash -n "$runner"

flag="$BENCH/logs/.bench-stopped"; hist="$BENCH/logs/.bench-starts"

# 1. normal start: leftovers of this bench are cleared, honcho runs
add_proc 111 "$BENCH/env/bin/python -m frappe.utils.bench_helper frappe serve --port 8000"
add_proc 222 "$BENCH/env/bin/python -m frappe.utils.bench_helper frappe --site macdev migrate"
add_proc 333 "node apps/frappe/socketio.js"
assert_status 0 "$runner"
assert_calls_contain '^honcho start -f Procfile.lean$'
grep -q '^222 ' "$MOCK_PROCS" || fail "bench migrate must survive the runner cleanup"
! grep -q '^111 ' "$MOCK_PROCS" || fail "stale serve must be cleared"
! grep -q '^333 ' "$MOCK_PROCS" || fail "stale socketio must be cleared"
assert_eq "1" "$(wc -l <"$hist" | tr -d ' ')"
assert_no_file "$flag"

# 2. stop flag: exit 0 without starting anything
reset_calls
printf 'manual\n' >"$flag"
assert_status 0 "$runner"
assert_calls_not_contain '^honcho'
rm -f "$flag"

# 3. crash guard: three recent starts, a fourth attempt pauses with "crash"
reset_calls
now="$(date +%s)"
printf '%s\n%s\n%s\n' "$((now - 500))" "$((now - 300))" "$((now - 100))" >"$hist"
assert_status 0 "$runner"
assert_eq "crash" "$(cat "$flag")"
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
mv "$HONCHO.gone" "$HONCHO"

# 6. env missing: same
reset_calls; rm -f "$flag"
mv "$BENCH/env" "$BENCH/env.gone"
assert_status 0 "$runner"
assert_eq "broken" "$(cat "$flag")"
mv "$BENCH/env.gone" "$BENCH/env"

# 7. honcho crashing propagates a non-zero exit so launchd restarts (KeepAlive SuccessfulExit=false)
rm -f "$flag"; : >"$hist"
MOCK_HONCHO_EXIT=1 assert_status 1 "$runner"

printf 'test-runner: ok\n'
