#!/usr/bin/env bash
# benchbar run (askysh/benchbar#181): the allow list and its refusals (exit 64), a
# read only command that runs at once, a changing command through the plan and
# its token, the bench's own folder and exports, the deadline, the exit code of
# the bench command, the tail of its output, and the result document.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH" macdev
printf 'port 11000\n' >"$BENCH/config/redis_queue.conf"; printf 'port 13000\n' >"$BENCH/config/redis_cache.conf"
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
mkdir -p "$BENCH/sites/bbtest.localhost"; printf '{}\n' >"$BENCH/sites/bbtest.localhost/site_config.json"
printf '127.0.0.1 macdev\n\n# >>> benchbar >>>\n127.0.0.1 bbtest.localhost\n# <<< benchbar <<<\n' >>"$FL_HOSTS_FILE"

# run_json ARGS...: stdout in OUT, stderr in ERR, apart
run_json() {
  set +e
  OUT="$("$FM" "$@" 2>"$MOCK_STATE/stderr")"
  CODE="$?"
  ERR="$(cat "$MOCK_STATE/stderr")"
  set -e
}
R() { run_json run --bench-dir "$BENCH" "$@"; }

# ---- refusals: exit 64, the list in the message, no bench call
reset_calls
R -- update;                                  assert_eq "64" "$CODE" "$OUT$ERR"; assert_contains "$OUT$ERR" "bench update pulls"; assert_contains "$OUT$ERR" "Allowed commands: migrate clear-cache"
R -- console;                                 assert_eq "64" "$CODE"; assert_contains "$OUT$ERR" "interactive"
R -- execute frappe.x;                        assert_eq "64" "$CODE"
R -- drop-site;                               assert_eq "64" "$CODE"
R -- shell;                                   assert_eq "64" "$CODE"
R -- nosuchthing;                             assert_eq "64" "$CODE"; assert_contains "$OUT$ERR" "not on the allow list"
R -- --site x migrate;                        assert_eq "64" "$CODE"
R migrate;                                    assert_eq "64" "$CODE"; assert_contains "$OUT$ERR" "needs -- before"
R --;                                         assert_eq "64" "$CODE"
R --bogus -- version;                         assert_eq "64" "$CODE"
R --timeout 0 -- version;                     assert_eq "64" "$CODE"
R --timeout 99999 -- version;                 assert_eq "64" "$CODE"
R --timeout abc -- version;                   assert_eq "64" "$CODE"
R -- migrate --force;                         assert_eq "64" "$CODE"; assert_contains "$OUT$ERR" "does not take --force"
R -- migrate extra;                           assert_eq "64" "$CODE"
R -- clear-cache --skip-failing;              assert_eq "64" "$CODE"
R -- run-tests --app;                         assert_eq "64" "$CODE"
R -- run-tests --app --failfast;              assert_eq "64" "$CODE"
R -- run-tests --app 'a;b';                   assert_eq "64" "$CODE"
R -- run-tests --failfast=1;                  assert_eq "64" "$CODE"
R --site macdev -- build;                     assert_eq "64" "$CODE"; assert_contains "$OUT$ERR" "leave out --site"
R --apply "$(printf 'a%.0s' $(seq 64))" --yes -- version; assert_eq "64" "$CODE"; assert_contains "$OUT$ERR" "only reads"
R --apply notatoken --yes -- migrate;         assert_eq "64" "$CODE"
R --apply "$(printf 'a%.0s' $(seq 64))" -- migrate; assert_eq "64" "$CODE"; assert_contains "$OUT$ERR" "--apply TOKEN --yes"
assert_calls_not_contain '^bench '
# a refusal under --for-agent is a done line with the list
run_json run --bench-dir "$BENCH" --for-agent -- update
assert_eq "64" "$CODE"
assert_eq "64 True True" "$(printf '%s' "$OUT" | tail -n 1 | jget - '" ".join(str(x) for x in [d["exit"], "migrate" in d["allowed"], d["event"] == "done"])')" "$OUT"
# a change over --json or --for-agent needs a reviewed plan
R --json --site macdev -- clear-cache;        assert_eq "64" "$CODE"; assert_contains "$OUT$ERR" "needs a reviewed plan"
run_json run --bench-dir "$BENCH" --for-agent --site macdev -- migrate; assert_eq "64" "$CODE"
# no --yes without a terminal: the missing input is named, before anything runs
BENCHBAR_NONINTERACTIVE=1 R --site macdev -- clear-cache; assert_eq "1" "$CODE"; assert_contains "$OUT$ERR" "--yes"
assert_calls_not_contain '^bench '

# ---- a read only command runs at once, in the bench folder, with the runner's exports
printf '13000 222 redis-server 127.0.0.1\n' >>"$MOCK_LISTEN"
reset_calls
R --site macdev --json -- doctor
assert_eq "0" "$CODE" "$OUT$ERR"
assert_calls_contain '^bench --site macdev doctor$'
assert_eq "doctor False 0 True macdev" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in [d["command"], d["changes"], d["command_exit"], d["ran"], d["site"]])')"
assert_contains "$(printf '%s' "$OUT" | jget - 'd["output_tail"]')" "doctor cwd=$BENCH ldflags=-L"
assert_eq "None" "$(printf '%s' "$OUT" | jget - 'd["token"]')"
for k in changed warnings next_actions state_after exit; do assert_contains "$OUT" "\"$k\":"; done
# the full output is in the run log
LOGF="$(printf '%s' "$OUT" | jget - 'd["log"]')"
assert_contains "$(cat "$LOGF")" "doctor cwd="
# the bench's Redis must be there for a read: stopped, it is named and nothing runs
: >"$MOCK_LISTEN"; printf '3306 111 mariadbd 127.0.0.1\n' >"$MOCK_LISTEN"
reset_calls
R --site macdev -- doctor
assert_eq "1" "$CODE"; assert_contains "$OUT$ERR" "needs the bench's Redis"
assert_calls_not_contain '^bench '
# no site on a bench command that needs one
R --site nosuch -- list-apps; assert_eq "1" "$CODE"; assert_contains "$OUT$ERR" "no site nosuch"
# version needs no site and no Redis
reset_calls
R --json -- version; assert_eq "0" "$CODE" "$OUT$ERR"
assert_calls_contain '^bench version$'

# ---- a change: the plan, then exactly that plan
reset_calls
R --site macdev --dry-run --json -- migrate --skip-failing
assert_eq "0" "$CODE" "$OUT$ERR"
assert_calls_not_contain '^bench '
assert_eq "migrate True True 1800 ['bench', '--site', 'macdev', 'migrate', '--skip-failing'] True" \
  "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in [d["command"], d["changes"], d["backup_first"], d["timeout_s"], d["argv"], d["can_apply"]])')"
TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
[[ "$TOKEN" =~ ^[0-9a-f]{64}$ ]] || fail "no token: $OUT"
assert_contains "$(printf '%s' "$OUT" | jget - 'd["warnings"]')" "stopped"
# another command, other flags or a changed bench make the token stale
R --site macdev --apply "$TOKEN" --yes --json -- clear-cache
assert_eq "1" "$CODE"; assert_contains "$OUT$ERR" "plan changed"
R --site macdev --apply "$TOKEN" --yes --json -- migrate
assert_eq "1" "$CODE"; assert_contains "$OUT$ERR" "plan changed"
assert_calls_not_contain '^bench '
# the run: a backup first, then migrate, under the lock
R --site macdev --apply "$TOKEN" --yes --json -- migrate --skip-failing
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "backup migrate" "$(grep -E '^bench --site macdev (backup|migrate)' "$MOCK_LOG" | awk '{print $4}' | tr '\n' ' ' | sed 's/ $//')"
assert_eq "True True 0 True" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in [d["backup"]["stamp"] is not None, d["ran"], d["command_exit"], d["ok"]])')"
assert_eq "backup site" "$(printf '%s' "$OUT" | jget - '" ".join(c["kind"] for c in d["changed"])')"
assert_no_file "$FL_STATE_DIR/lock" "(the lock is released)"
# a human, with --yes and no token
reset_calls
run_fm run --bench-dir "$BENCH" --site macdev --yes -- clear-cache
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^bench --site macdev clear-cache$'
assert_calls_not_contain 'backup'
# build takes no site and one app
reset_calls
run_fm run --bench-dir "$BENCH" --yes -- build --app=frappe
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^bench build --app frappe$'

# ---- the lock: a held lock stops a change and not a read
mkdir -p "$FL_STATE_DIR/lock"; printf '%s\n' "$$" >"$FL_STATE_DIR/lock/pid"
reset_calls
run_fm run --bench-dir "$BENCH" --site macdev --yes -- clear-cache
assert_eq "1" "$CODE"; assert_contains "$OUT" "Another benchbar run is active"
assert_calls_not_contain '^bench '
run_fm run --bench-dir "$BENCH" --json -- version
assert_eq "0" "$CODE" "$OUT"
rm -rf "$FL_STATE_DIR/lock"

# ---- the bench command's exit code, the tail of its output, the deadline
export MOCK_BENCH_RUN_TESTS_EXIT=3 MOCK_BENCH_RUN_TESTS_LINES=100
T="$("$FM" run --bench-dir "$BENCH" --site bbtest.localhost --dry-run --json -- run-tests --app frappe --failfast | jget - 'd["token"]')"
R --site bbtest.localhost --apply "$T" --yes --json -- run-tests --app frappe --failfast
assert_eq "3" "$CODE" "$OUT$ERR"
assert_eq "3 3 True True" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in [d["exit"], d["command_exit"], d["output_truncated"], d["ran"]])')"
TAIL="$(printf '%s' "$OUT" | jget - 'd["output_tail"]')"
assert_contains "$TAIL" "line 100"
assert_not_contains "$TAIL" "line 1"$'\n'
assert_contains "$TAIL" "args=--site bbtest.localhost run-tests --app frappe --failfast"
assert_contains "$TAIL" "red fetching"
assert_not_contains "$TAIL" "hunter2"
assert_not_contains "$TAIL" $'\033'
assert_contains "$(printf '%s' "$OUT" | jget - 'd["warnings"]')" "stopped part way"
# exit 2 and 64 are benchbar's own: reported as 1, command_exit keeps the real one
export MOCK_BENCH_RUN_TESTS_EXIT=2 MOCK_BENCH_RUN_TESTS_LINES=0
T="$("$FM" run --bench-dir "$BENCH" --site bbtest.localhost --dry-run --json -- run-tests | jget - 'd["token"]')"
R --site bbtest.localhost --apply "$T" --yes --json -- run-tests
assert_eq "1" "$CODE" "$OUT$ERR"
assert_eq "1 2" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in [d["exit"], d["command_exit"]])')"
# the deadline: the whole group goes, exit 124
export MOCK_BENCH_RUN_TESTS_EXIT=0 MOCK_BENCH_RUN_TESTS_SLEEP=30
T="$("$FM" run --bench-dir "$BENCH" --site bbtest.localhost --timeout 1 --dry-run --json -- run-tests | jget - 'd["token"]')"
START="$SECONDS"
R --site bbtest.localhost --timeout 1 --apply "$T" --yes --json -- run-tests
assert_eq "124" "$CODE" "$OUT$ERR"
[[ $((SECONDS - START)) -lt 15 ]] || fail "the deadline did not stop the command ($((SECONDS - START))s)"
assert_eq "124 True 1" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in [d["command_exit"], d["timed_out"], d["timeout_s"]])')"
unset MOCK_BENCH_RUN_TESTS_SLEEP MOCK_BENCH_RUN_TESTS_EXIT MOCK_BENCH_RUN_TESTS_LINES
# a failing migrate: the backup was taken, the way back is a next action
export MOCK_BENCH_MIGRATE_EXIT=1
T="$("$FM" run --bench-dir "$BENCH" --site macdev --dry-run --json -- migrate | jget - 'd["token"]')"
R --site macdev --apply "$T" --yes --json -- migrate
assert_eq "1" "$CODE" "$OUT$ERR"
assert_contains "$(printf '%s' "$OUT" | jget - '[a["command"] for a in d["next_actions"]]')" "restore macdev --from"
unset MOCK_BENCH_MIGRATE_EXIT
# a failed backup stops before migrate
reset_calls
export MOCK_BENCH_BACKUP_EXIT=1
T="$("$FM" run --bench-dir "$BENCH" --site macdev --dry-run --json -- migrate | jget - 'd["token"]')"
R --site macdev --apply "$T" --yes --json -- migrate
assert_eq "1" "$CODE" "$OUT$ERR"
assert_eq "False None" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in [d["ran"], d["command_exit"]])')"
assert_calls_not_contain 'migrate'
unset MOCK_BENCH_BACKUP_EXIT

# ---- the stream: plan, steps, done
run_json run --bench-dir "$BENCH" --for-agent --site macdev --dry-run -- migrate
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "plan done" "$(printf '%s\n' "$OUT" | python3 -c 'import json,sys; print(" ".join(json.loads(l)["event"] for l in sys.stdin if l.strip()))')"
T="$(printf '%s\n' "$OUT" | head -n 1 | jget - 'd["token"]')"
run_json run --bench-dir "$BENCH" --for-agent --site macdev --apply "$T" --yes -- migrate
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "step step step step done" "$(printf '%s\n' "$OUT" | python3 -c 'import json,sys; print(" ".join(json.loads(l)["event"] for l in sys.stdin if l.strip()))')"
assert_eq "0 migrate 0" "$(printf '%s\n' "$OUT" | tail -n 1 | jget - '" ".join(str(x) for x in [d["exit"], d["command"], d["command_exit"]])')"

# ---- the table: help, commands --json, the docs name every allowed command
run_fm run --help
assert_contains "$OUT" "--timeout"
run_json commands --json
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'any(c["name"] == "run" and c["mutating"] for c in d["commands"])')"
while IFS= read -r c; do
  grep -q "\`$c\`" "$ROOT/docs/reference/cli/run.md" || fail "docs/reference/cli/run.md does not name the allowed command $c"
  grep -q "\"$c\"" "$ROOT/lib/frappe-local/mcp.py" || fail "mcp.py does not offer the allowed command $c"
done < <(awk -F'~' 'NF > 8 && /^[a-z-]+~(yes|no)~/ { print $1 }' "$ROOT/lib/frappe-local/bench-run.sh")

printf 'test-bench-run: ok\n'
