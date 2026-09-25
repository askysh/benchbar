#!/usr/bin/env bash
# benchbar mcp: the stdio handshake (initialize, tools/list, tools/call),
# read tools that return the CLI's JSON, an action that returns the fresh
# status, errors that do not end the session; and logs --json.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/frappe-bench"
make_fake_bench "$BENCH"
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
cat >"$BENCH/logs/bench.log" <<'LOG'
10:00:01 system | web.1 started (pid=11)
10:00:01 web.1        | * Running on http://127.0.0.1:8000
10:00:02 worker.1     | job done
10:00:03 web.1        | Traceback (most recent call last):
  File "x.py", line 1, in <module>
10:00:04 socketio.1   | listening on 9000
LOG

# ---- logs --json, with and without a process filter
run_fm logs --json --no-follow -n10 --bench-dir "$BENCH"
assert_eq "6" "$(printf '%s' "$OUT" | jget - 'len(d["lines"])')"
run_fm logs --json --no-follow --process web --bench-dir "$BENCH"
assert_eq "3" "$(printf '%s' "$OUT" | jget - 'len(d["lines"])')" "(web lines plus the traceback line under them)"
assert_contains "$OUT" 'File \"x.py\"'
run_fm logs --json --no-follow --process 'web;rm' --bench-dir "$BENCH"
assert_eq "1" "$CODE"

# ---- the MCP session: one request per line, one reply per request
mcp() { printf '%s\n' "$@" | "$FM" mcp 2>/dev/null; }
REPLIES="$(mcp \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"benchbar_list","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"benchbar_logs_tail","arguments":{"bench":"'"$BENCH"'","lines":2,"process":"web"}}}' \
  '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"benchbar_repair","arguments":{}}}' \
  'not json' \
  '{"jsonrpc":"2.0","id":6,"method":"ping"}')"
printf '%s\n' "$REPLIES" | python3 -c '
import json, sys
r = [json.loads(l) for l in sys.stdin if l.strip()]
by = {m.get("id"): m for m in r}
assert len(r) == 7, r                                   # the notification got no reply
i = by[1]["result"]
assert i["protocolVersion"] == "2025-06-18" and i["serverInfo"]["name"] == "benchbar", i
names = [t["name"] for t in by[2]["result"]["tools"]]
assert names == ["benchbar_list", "benchbar_status", "benchbar_doctor", "benchbar_logs_tail", "benchbar_site_list", "benchbar_up", "benchbar_down", "benchbar_restart"], names
assert not any("repair" in n or "install" in n for n in names)
ro = {t["name"]: t["annotations"]["readOnlyHint"] for t in by[2]["result"]["tools"]}
assert ro["benchbar_doctor"] and not ro["benchbar_down"], ro
lst = by[3]["result"]
assert not lst["isError"] and lst["structuredContent"]["benches"][0]["name"] == "frappe-bench", lst
logs = by[4]["result"]["structuredContent"]
assert logs["process"] == "web" and len(logs["lines"]) == 2, logs
assert by[5]["error"]["code"] == -32602, by[5]           # no repair tool
assert by[None]["error"]["code"] == -32700               # a bad line does not end the session
assert by[6]["result"] == {}
' || fail "MCP replies: $REPLIES"

# an unknown protocol version gets the newest one this server speaks
R="$(mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}')"
assert_eq "2025-06-18" "$(printf '%s' "$R" | jget - 'd["result"]["protocolVersion"]')"

# an action returns its output and the fresh status; down on a stopped bench is fine
R="$(mcp '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"benchbar_down","arguments":{"bench":"'"$BENCH"'"}}}')"
assert_eq "False" "$(printf '%s' "$R" | jget - 'd["result"]["isError"]')"
assert_eq "stopped" "$(printf '%s' "$R" | jget - 'd["result"]["structuredContent"]["status"]["state"]')"

printf 'test-mcp: ok\n'
