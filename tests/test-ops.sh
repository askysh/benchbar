#!/usr/bin/env bash
# Operation handles (askysh/benchbar#180): every run that changes things has an op_id (in its stream and
# in a record under ops/), benchbar op status, list and wait read the records, a run that died is
# interrupted, the records are pruned, --background starts a long command detached, and the MCP server
# returns the op_id and reads the records.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH" macdev
printf 'port 11000\n' >"$BENCH/config/redis_queue.conf"; printf 'port 13000\n' >"$BENCH/config/redis_cache.conf"
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
export MARIADB_ROOT_PASSWORD=rootpw
mkdir -p "$BENCH/sites/bbtest.localhost"; printf '{}\n' >"$BENCH/sites/bbtest.localhost/site_config.json"
OPS="$FL_STATE_DIR/ops"
# the FL_OP_WAIT_POLL seam: op wait looks every tenth of a second in these tests
export FL_OP_WAIT_POLL=0.1

# JSON calls: stdout in OUT, stderr in ERR, apart
run_json() {
  set +e
  OUT="$("$FM" "$@" 2>"$MOCK_STATE/stderr")"
  CODE="$?"
  ERR="$(cat "$MOCK_STATE/stderr")"
  set -e
}
# rec_field ID EXPR: a field of an op's record on disk
rec_field() { jget "$OPS/$1.json" "$2"; }
# fake_op ID STATE PID [EXIT]: a record as the CLI writes it
fake_op() {
  mkdir -p "$OPS"
  printf '{"schema_version":1,"cli_version":"%s","op_id":"%s","state":"%s","command":"app add","bench":"%s","site":null,"pid":%s,"started_at":"2026-11-19T10:00:00Z","updated_at":"2026-11-19T10:03:12Z","finished_at":%s,"step":{"id":"build","name":"Build assets","status":"running"},"progress":{"label":"yarn build","elapsed":42,"bytes":null},"exit":%s,"log":null,"output":null,"background":false}\n' \
    "$VER" "$1" "$2" "$BENCH" "$3" "$([[ -n "${4:-}" ]] && printf '"2026-11-19T10:03:12Z"' || printf null)" "${4:-null}" >"$OPS/$1.json"
}

# ---- 1. a run that changes things has an op_id and a record, in every mode
run_fm site backup bbtest.localhost --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_not_contains "$OUT" "op-2" "(the text form prints no handle: its output did not change)"
run_json op list --json
assert_eq "0" "$CODE" "$OUT$ERR"
ID1="$(printf '%s' "$OUT" | jget - 'd["ops"][0]["op_id"]')"
[[ "$ID1" =~ ^op-[0-9]{8}-[0-9]{6}-[0-9]+(-[0-9]+)?$ ]] || fail "op id has the wrong form: $ID1"
assert_eq "site backup done 0 $BENCH" "$(rec_field "$ID1" 'd["command"] + " " + d["state"] + " " + str(d["exit"]) + " " + d["bench"]')"
assert_eq "True" "$(rec_field "$ID1" 'd["started_at"].endswith("Z") and d["finished_at"].endswith("Z") and d["pid"] > 0 and d["background"] is False and d["schema_version"] == 1')"
LOG1="$(rec_field "$ID1" 'd["log"]')"
assert_file "$LOG1" "(the record names the run's log)"

# a --json document carries the op_id next to the done fields
run_json site backup bbtest.localhost --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
ID2="$(printf '%s' "$OUT" | jget - 'd["op_id"]')"
assert_eq "done 0" "$(rec_field "$ID2" 'd["state"] + " " + str(d["exit"])')"
[[ "$ID1" != "$ID2" ]] || fail "two runs share an op id"

# a stream carries it in every line: plan, steps and done
run_json service --json --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "True" "$(printf '%s' "$OUT" | python3 -c '
import json, sys
lines = [json.loads(l) for l in sys.stdin.read().splitlines()]
ids = {l.get("op_id") for l in lines}
assert len(lines) >= 2 and len(ids) == 1 and None not in ids, (ids, lines)
assert lines[-1]["event"] == "done", lines[-1]
print(True)')" "$OUT"
ID3="$(printf '%s' "$OUT" | tail -n 1 | jget - 'd["op_id"]')"
assert_eq "service done" "$(rec_field "$ID3" 'd["command"] + " " + d["state"]')"
# --jsonl wraps a document command the same way
run_json site backup bbtest.localhost --jsonl --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "True" "$(printf '%s' "$OUT" | python3 -c '
import json, sys
lines = [json.loads(l) for l in sys.stdin.read().splitlines()]
assert len({l.get("op_id") for l in lines}) == 1 and lines[-1]["event"] == "done" and lines[-1]["op_id"], lines
print(True)')" "$OUT"

# a failure is a failed record with its exit
MOCK_BENCH_BACKUP_EXIT=1 run_json site backup bbtest.localhost --json --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
run_json op status --json
assert_eq "0" "$CODE" "$OUT"
assert_eq "failed 1 site backup" "$(printf '%s' "$OUT" | jget - 'd["ops"][0]["state"] + " " + str(d["ops"][0]["exit"]) + " " + d["ops"][0]["command"]')"

# a dry run and a read are no operations
before="$(find "$OPS" -name 'op-*.json' | wc -l | tr -d ' ')"
run_json service --dry-run --json --bench-dir "$BENCH"
run_json status --json --bench-dir "$BENCH"
run_json doctor --json --bench-dir "$BENCH"
run_json op list --json
assert_eq "$before" "$(find "$OPS" -name 'op-*.json' | wc -l | tr -d ' ')" "(a dry run, a status and a doctor leave no record)"

# ---- 2. op status: one operation, the newest, and the text
run_json op status "$ID1" --json
assert_eq "0" "$CODE" "$OUT"
assert_eq "$ID1 done site backup False" "$(printf '%s' "$OUT" | jget - 'd["op_id"] + " " + d["state"] + " " + d["command"] + " " + str("result" in d)')"
run_fm op status "$ID1"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "$ID1  benchbar site backup  done (exit 0)"
assert_contains "$OUT" "bench     $BENCH"
run_fm op status
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "$ID1"
run_json op status op-20200101-000000-1 --json
assert_eq "1" "$CODE"
assert_contains "$ERR" "No operation op-20200101-000000-1"
run_json op status '../../etc/passwd' --json
assert_eq "1" "$CODE"
assert_contains "$ERR" "Not an op id"
# an unknown flag is a usage error since 0.9.0 (exit 64)
run_json op status --bogus
assert_eq "64" "$CODE"; assert_contains "$OUT$ERR" "Unknown option for op status: --bogus"
run_json op frobnicate
assert_eq "1" "$CODE"
assert_contains "$OUT$ERR" "Unknown subcommand"
# polling needs no bench and no other library: it works from a folder that is no bench
run_json commands --json
assert_eq "True" "$(printf '%s' "$OUT" | jget - '[c["name"] for c in d["commands"] if c["name"].startswith("op ")] == ["op status", "op list", "op wait"] and all(not c["mutating"] for c in d["commands"] if c["name"].startswith("op "))')"

# ---- 3. a run that died without a done line is interrupted; one that runs is running
sleep 120 &
LIVE=$!
trap 'kill "$LIVE" 2>/dev/null || true; cd /; { rm -r "$TMP_DIR"; } 2>/dev/null || true' EXIT
sleep 0 & DEAD=$!; wait "$DEAD" || true
fake_op op-20260101-000001-11 running "$LIVE"
fake_op op-20260101-000002-12 running "$DEAD"
fake_op op-20260101-000003-13 "done" "$DEAD" 0
fake_op op-20260101-000004-14 failed "$DEAD" 3
fake_op op-20260101-000005-15 starting null
fake_op op-20260101-000006-16 starting null
touch -t 202601010000 "$OPS/op-20260101-000006-16.json"
assert_eq "running" "$(run_json op status op-20260101-000001-11 --json; printf '%s' "$OUT" | jget - 'd["state"]')" "(its pid is alive)"
assert_eq "interrupted" "$(run_json op status op-20260101-000002-12 --json; printf '%s' "$OUT" | jget - 'd["state"]')" "(its pid is gone and there is no done line)"
assert_eq "running" "$(rec_field op-20260101-000002-12 'd["state"]')" "(the record on disk is not rewritten by a reader)"
assert_eq "starting" "$(run_json op status op-20260101-000005-15 --json; printf '%s' "$OUT" | jget - 'd["state"]')" "(a launch that is a moment old)"
assert_eq "interrupted" "$(run_json op status op-20260101-000006-16 --json; printf '%s' "$OUT" | jget - 'd["state"]')" "(a launch that never took over)"
run_fm op status op-20260101-000001-11
assert_contains "$OUT" "step      build: Build assets (running)"
assert_contains "$OUT" "progress  yarn build (42s)"
run_json op list --running --json
assert_eq "op-20260101-000001-11 op-20260101-000005-15" "$(printf '%s' "$OUT" | jget - '" ".join(sorted(o["op_id"] for o in d["ops"] if o["op_id"].startswith("op-2026010")))')" "(only the ones that run now)"
run_json op list --limit 2 --json
assert_eq "2" "$(printf '%s' "$OUT" | jget - 'len(d["ops"])')"
run_json op list --limit 0
assert_eq "1" "$CODE"
run_fm op list
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "interrupted"

# ---- 4. op wait
run_json op wait op-20260101-000003-13 --json
assert_eq "0" "$CODE" "$OUT"
assert_eq "done" "$(printf '%s' "$OUT" | jget - 'd["state"]')"
run_json op wait op-20260101-000004-14 --json
assert_eq "1" "$CODE" "(a failed run: exit 1)"
assert_eq "failed 3" "$(printf '%s' "$OUT" | jget - 'd["state"] + " " + str(d["exit"])')"
run_json op wait op-20260101-000002-12 --json
assert_eq "1" "$CODE" "(an interrupted run: exit 1)"
assert_eq "interrupted" "$(printf '%s' "$OUT" | jget - 'd["state"]')"
run_json op wait op-20260101-000001-11 --timeout 1 --json
assert_eq "1" "$CODE" "$OUT"
assert_eq "running True" "$(printf '%s' "$OUT" | jget - 'd["state"] + " " + str(d["timed_out"])')" "(gave up waiting, the run goes on)"
run_json op wait
assert_eq "1" "$CODE"; assert_contains "$OUT$ERR" "needs an op id"
run_json op wait op-20260101-000003-13 --timeout soon
assert_eq "1" "$CODE"; assert_contains "$OUT$ERR" "number of seconds"
run_fm op wait op-20260101-000003-13
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "done (exit 0)"
# a record that ends while op wait looks at it
fake_op op-20260101-000007-17 running "$LIVE"
( sleep 1; fake_op op-20260101-000007-17 "done" "$DEAD" 0 ) &
SUB=$!
run_json op wait op-20260101-000007-17 --timeout 30 --json
assert_eq "0 done" "$CODE $(printf '%s' "$OUT" | jget - 'd["state"]')" "$OUT"
wait "$SUB"

# ---- 5. the records are pruned: the newest FL_KEEP_OPS stay, and a run that still runs
rm -rf "$OPS"
for n in 1 2 3 4 5; do fake_op "op-20200101-00000$n-$n" "done" "$DEAD" 0; printf '{"event":"done"}\n' >"$OPS/op-20200101-00000$n-$n.jsonl"; done
fake_op op-20190101-000000-9 running "$LIVE"
FL_KEEP_OPS=2 run_json site backup bbtest.localhost --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'any(c["kind"] == "pruned" and "operation records" in c["detail"] for c in d["changed"])')" "$OUT"
assert_no_file "$OPS/op-20200101-000001-1.json"
assert_no_file "$OPS/op-20200101-000001-1.jsonl" "(the output file goes with its record)"
assert_no_file "$OPS/op-20200101-000003-3.json"
assert_file "$OPS/op-20200101-000005-5.json" "(the newest stay)"
assert_file "$OPS/op-20190101-000000-9.json" "(a run that still runs is never pruned)"
assert_eq "3" "$(find "$OPS" -name 'op-*.json' | wc -l | tr -d ' ')" "(the new run, the newest of the others and the running one)"

# ---- 6. --background: refused before it starts, or started detached with an op_id at once
rm -rf "$OPS"
run_json up --background --json --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT$ERR" "cannot run with --background"
run_json site restore bbtest.localhost --from 20260929_100001 --background --json --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT$ERR" "--yes"
run_json site backup bbtest.localhost --background --dry-run --json --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT$ERR" "dry run"
run_json mariadb-password --background
assert_eq "1" "$CODE"; assert_contains "$OUT$ERR" "cannot run with --background"
run_json share setup --background
[[ "$CODE" != "0" ]] || fail "share setup --background must be refused: $OUT$ERR"
assert_eq "0" "$(find "$OPS" -name 'op-*.json' 2>/dev/null | wc -l | tr -d ' ')" "(a refusal is not an operation)"
ADMIN_PASSWORD=pw BENCHBAR_SUDO_PASSWORD=x BENCHBAR_SUDO=env run_json install --background --yes --json --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT$ERR" "BENCHBAR_SUDO_PASSWORD"

MOCK_BENCH_BACKUP_SLEEP=3 run_json site backup bbtest.localhost --background --yes --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT$ERR"
BG="$(printf '%s' "$OUT" | jget - 'd["op_id"]')"
assert_eq "site backup True" "$(printf '%s' "$OUT" | jget - 'd["command"] + " " + str(d["background"])')"
assert_eq "benchbar op wait $BG" "$(printf '%s' "$OUT" | jget - 'd["next_actions"][0]["command"]')"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["state"] == "running" and d["pid"] > 0 and d["exit"] == 0 and d["output"].endswith("/ops/" + "'"$BG"'" + ".jsonl")')" "(the launcher waited for the lock: running, not starting)"
# it returned once the run held its lock: the run is still going (it sleeps 3 seconds), and op status follows it
run_json op status "$BG" --json
assert_eq "0" "$CODE" "$OUT"
assert_eq "running" "$(printf '%s' "$OUT" | jget - 'd["state"]')" "$OUT"
assert_eq "$BENCH bbtest.localhost" "$(printf '%s' "$OUT" | jget - 'd["bench"] + " " + str(d["site"])')" "(the record names the site the command works on, not the default site)"
run_json op wait "$BG" --timeout 60 --json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "done 0 True" "$(printf '%s' "$OUT" | jget - 'd["state"] + " " + str(d["exit"]) + " " + str(d["background"])')" "$OUT"
# the done line of the run comes back as result: its own fields, the same op_id
assert_eq "done $BG 0 True" "$(printf '%s' "$OUT" | jget - 'd["result"]["event"] + " " + d["result"]["op_id"] + " " + str(d["result"]["exit"]) + " " + str("backup" in d["result"])')" "$OUT"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["pid"] > 0 and d["log"] is not None and d["output"].endswith(".jsonl")')"
assert_file "$OPS/$BG.jsonl"
# the text form of the launch
MOCK_BENCH_BACKUP_SLEEP=0 run_fm site backup bbtest.localhost --background --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "Started in the background ("
assert_contains "$OUT" "benchbar op wait op-"
BG2="$(printf '%s' "$OUT" | sed -n 's/^Started in the background ([a-z]*): \(op-[0-9-]*\).*/\1/p')"
run_json op wait "$BG2" --timeout 60 --json
assert_eq "done" "$(printf '%s' "$OUT" | jget - 'd["state"]')" "$OUT"
# a detached run that fails ends failed, and says why in its result
MOCK_BENCH_BACKUP_SLEEP=1 MOCK_BENCH_BACKUP_EXIT=1 run_json site backup bbtest.localhost --background --yes --json --bench-dir "$BENCH"
BG3="$(printf '%s' "$OUT" | jget - 'd["op_id"]')"
run_json op wait "$BG3" --timeout 60 --json
assert_eq "1" "$CODE" "$OUT"
assert_eq "failed 1" "$(printf '%s' "$OUT" | jget - 'd["state"] + " " + str(d["result"]["exit"])')" "$OUT"
# a secret in the environment reaches the detached run, and never its record, its output or the run's log
ADMIN_PASSWORD=adminpw-0451 MOCK_BENCH_BACKUP_SLEEP=1 run_json site backup bbtest.localhost --background --yes --json --bench-dir "$BENCH"
run_json op wait "$(printf '%s' "$OUT" | jget - 'd["op_id"]')" --timeout 60 --json
assert_eq "0" "$CODE" "$OUT"
for secret in rootpw adminpw-0451; do
  assert_eq "False" "$(grep -rqs -- "$secret" "$OPS" "$FL_STATE_DIR/logs" && echo True || echo False)" "($secret is in no record, output or run log)"
done

# ---- 6b. the lock is held by a live run: the launcher says so, with the run's message and exit code, and starts nothing
mkdir -p "$FL_STATE_DIR/lock"; printf '%s\n' "$LIVE" >"$FL_STATE_DIR/lock/pid"
run_json site backup bbtest.localhost --background --yes --json --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT$ERR"
assert_contains "$OUT$ERR" "Another benchbar run is active"
assert_not_contains "$OUT" '"state":"starting"' "(not an exit 0 with state starting)"
run_json op list --limit 1 --json
LK="$(printf '%s' "$OUT" | jget - 'd["ops"][0]["op_id"]')"
assert_eq "failed 1 $BENCH bbtest.localhost" "$(printf '%s' "$OUT" | jget - 'd["ops"][0]["state"] + " " + str(d["ops"][0]["exit"]) + " " + str(d["ops"][0]["bench"]) + " " + str(d["ops"][0]["site"])')" "(the refused attempt is recorded, with its bench and site)"
run_fm site backup bbtest.localhost --background --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "Another benchbar run is active"
# in front, the refusal is the run's own, and its record names the bench and the site as well
run_json site backup bbtest.localhost --json --bench-dir "$BENCH"
assert_eq "1" "$CODE"
run_json op list --limit 1 --json
assert_eq "failed 1 $BENCH bbtest.localhost False" "$(printf '%s' "$OUT" | jget - 'd["ops"][0]["state"] + " " + str(d["ops"][0]["exit"]) + " " + str(d["ops"][0]["bench"]) + " " + str(d["ops"][0]["site"]) + " " + str(d["ops"][0]["background"])')"
rm -f "$FL_STATE_DIR/lock/pid"; rmdir "$FL_STATE_DIR/lock"

# ---- 6c. a record whose pid another process now holds is interrupted, and op wait does not hang on it
# LIVE is alive: a record with its pid and its real start time is running, one with another start time is a reused pid
# the start time as the CLI reads it (/proc on Linux, ps -o lstart= on macOS)
if [[ -r /proc/self/stat ]]; then
  LIVE_START="$(sed 's/^.*) //' "/proc/$LIVE/stat" | awk '{print $20}')"
else
  LIVE_START="$(ps -o lstart= -p "$LIVE" | sed 's/^ *//; s/ *$//')"
fi
[[ -n "$LIVE_START" ]] || fail "could not read the start time of $LIVE"
fake_op op-20260102-000001-21 running "$LIVE"
sed_inplace "s/\"pid\":$LIVE,/\"pid\":$LIVE,\"pid_start\":\"$LIVE_START\",/" "$OPS/op-20260102-000001-21.json"
fake_op op-20260102-000002-22 running "$LIVE"
sed_inplace "s/\"pid\":$LIVE,/\"pid\":$LIVE,\"pid_start\":\"12345\",/" "$OPS/op-20260102-000002-22.json"
assert_eq "running" "$(run_json op status op-20260102-000001-21 --json; printf '%s' "$OUT" | jget - 'd["state"]')" "(the pid and its start time are the run's)"
assert_eq "interrupted" "$(run_json op status op-20260102-000002-22 --json; printf '%s' "$OUT" | jget - 'd["state"]')" "(the pid is alive but it is another process)"
run_json op wait op-20260102-000002-22 --timeout 20 --json
assert_eq "1 interrupted" "$CODE $(printf '%s' "$OUT" | jget - 'd["state"]')" "(op wait returns at once, no timeout needed)"
# a real run's record carries the start time of its own process
run_json site backup bbtest.localhost --json --bench-dir "$BENCH"
assert_eq "True" "$(jget "$OPS/$(printf '%s' "$OUT" | jget - 'd["op_id"]').json" 'bool(d["pid_start"])')"

# ---- 6d. a finished record does not keep its last step running
run_json service --json --yes --bench-dir "$BENCH"
SV="$(printf '%s' "$OUT" | tail -n 1 | jget - 'd["op_id"]')"
assert_eq "True" "$(rec_field "$SV" '(d["step"] is None or d["step"]["status"] != "running") and d["progress"] is None')" "(a done run has no running step)"

# no record of a run that ended (done or failed) keeps a step or a progress line running
python3 -I -c '
import glob, json, sys
for f in glob.glob(sys.argv[1] + "/op-2026111*.json"):
    d = json.load(open(f))
    if d["state"] in ("done", "failed"):
        assert d["step"] is None or d["step"]["status"] != "running", (f, d["step"])
        assert d["progress"] is None, (f, d["progress"])
' "$OPS" || fail "a finished record keeps a running step"

# ---- 7. the MCP server: op_id in an action's result, the read only op status tool
BENCHBAR_MCP_APPLY_DELAY=0
export BENCHBAR_MCP_APPLY_DELAY
INIT='{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}'
mcp() { printf '%s\n' "$INIT" '{"jsonrpc":"2.0","method":"notifications/initialized"}' "$@" | "$FM" mcp 2>/dev/null | tail -n +2; }
call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$1" "$2" "$3"; }
R="$(mcp "$(call 1 benchbar_site_backup '{"site":"bbtest.localhost","bench":"'"$BENCH"'"}')")"
assert_eq "False" "$(printf '%s' "$R" | jget - 'd["result"]["isError"]')" "$R"
MID="$(printf '%s' "$R" | jget - 'd["result"]["structuredContent"]["op_id"]')"
assert_eq "$MID" "$(printf '%s' "$R" | jget - 'd["result"]["structuredContent"]["result"]["op_id"]')" "(the op_id is at the top of the result and in the done line)"
R="$(mcp "$(call 1 benchbar_op_status '{"op_id":"'"$MID"'"}')" "$(call 2 benchbar_op_status '{}')" "$(call 3 benchbar_op_status '{"op_id":"--help"}')" "$(call 4 benchbar_op_status '{"op_id":"op-1"}')" "$(call 5 benchbar_op_status '{"op_id":"op-20200101-000000-77"}')" "$(call 6 benchbar_op_status '{"op_id":"'"$MID"'\n"}')")"
printf '%s' "$R" | python3 -c '
import json, sys
by = {json.loads(l)["id"]: json.loads(l) for l in sys.stdin.read().splitlines()}
bad = lambda m: "error" in m or m["result"]["isError"]
one = by[1]["result"]
assert not one["isError"] and one["structuredContent"]["state"] == "done" and one["structuredContent"]["command"] == "site backup", one
assert one["content"][0]["text"].startswith("Data from the bench (operation records"), one["content"][0]["text"][:120]
assert len(by[2]["result"]["structuredContent"]["ops"]) >= 3, by[2]   # without an op_id: the newest operations
assert bad(by[3]) and bad(by[4]) and bad(by[5]), (by[3], by[4], by[5])
assert bad(by[6]) and "not valid" in by[6]["result"]["content"][0]["text"], by[6]   # a trailing newline is not an op id   # an option, a short id and an unknown id' || fail "benchbar_op_status replies: $R"
assert_eq "True" "$(mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | jget - 'any(t["name"] == "benchbar_op_status" and t["annotations"]["readOnlyHint"] is True for t in d["result"]["tools"])')"
assert_eq "True" "$(mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | jget - 'all("background" in t["inputSchema"]["properties"] for t in d["result"]["tools"] if t["name"] in ("benchbar_app_add", "benchbar_site_restore")) and not any("background" in t["inputSchema"]["properties"] for t in d["result"]["tools"] if t["name"] in ("benchbar_site_add", "benchbar_up"))')"

printf 'ok\n'
