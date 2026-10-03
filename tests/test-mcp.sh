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
  '5' \
  '{"jsonrpc":"2.0","id":7,"method":"tools/list","params":"x"}' \
  '{"jsonrpc":"2.0","id":6,"method":"ping"}')"
printf '%s\n' "$REPLIES" | python3 -c '
import json, sys
r = [json.loads(l) for l in sys.stdin if l.strip()]
by = {m.get("id"): m for m in r}
assert len(r) == 9, r                                   # the notification got no reply
i = by[1]["result"]
assert i["protocolVersion"] == "2025-06-18" and i["serverInfo"]["name"] == "benchbar", i
names = [t["name"] for t in by[2]["result"]["tools"]]
assert names == ["benchbar_list", "benchbar_status", "benchbar_doctor", "benchbar_logs_tail", "benchbar_site_list", "benchbar_profile_list", "benchbar_profile_check", "benchbar_up", "benchbar_down", "benchbar_restart", "benchbar_app_add_plan", "benchbar_app_add"], names
assert not any("repair" in n or "install" in n for n in names)
ro = {t["name"]: t["annotations"]["readOnlyHint"] for t in by[2]["result"]["tools"]}
assert ro["benchbar_doctor"] and not ro["benchbar_down"], ro
lst = by[3]["result"]
assert not lst["isError"] and lst["structuredContent"]["benches"][0]["name"] == "frappe-bench", lst
logs = by[4]["result"]["structuredContent"]
assert logs["process"] == "web" and len(logs["lines"]) == 2, logs
assert by[5]["error"]["code"] == -32602, by[5]           # no repair tool
nulls = sorted(m["error"]["code"] for m in r if m.get("id") is None)
assert nulls == [-32700, -32600], nulls                  # bad lines are answered, the session goes on
assert by[7]["error"]["code"] == -32602, by[7]
assert by[6]["result"] == {}
' || fail "MCP replies: $REPLIES"

# ---- the profile read tools: list, and check (name required)
mkdir -p "$HOME/.config/benchbar/profiles"
printf 'base = "v15-lts"\n\n[[apps]]\nname = "gone"\nrepo = "file://%s/nothing.git"\nbranch = "main"\n' "$TMP_DIR" >"$HOME/.config/benchbar/profiles/acme.toml"
REPLIES="$(mcp \
  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"benchbar_profile_list","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"benchbar_profile_check","arguments":{"name":"acme"}}}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"benchbar_profile_check","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"benchbar_profile_check","arguments":{"name":"--help"}}}' \
  '{"jsonrpc":"2.0","id":5,"method":"tools/list"}')"
printf '%s\n' "$REPLIES" | python3 -c '
import json, sys
by = {m["id"]: m for m in (json.loads(l) for l in sys.stdin if l.strip())}
p = by[1]["result"]["structuredContent"]["profiles"]
assert [x["source"] for x in p if x["name"] == "acme"] == ["user"], p
c = by[2]["result"]["structuredContent"]
assert c["name"] == "acme" and c["repos"][0]["reachable"] is False and c["skipped_apps"] == ["gone"], c
assert by[3]["error"]["code"] == -32602, by[3]
assert by[4]["error"]["code"] == -32602, by[4]              # an option is never passed as a name
t = {x["name"]: x for x in by[5]["result"]["tools"]}
assert t["benchbar_profile_check"]["inputSchema"]["required"] == ["name"]
assert t["benchbar_profile_list"]["annotations"]["readOnlyHint"] and t["benchbar_profile_check"]["annotations"]["readOnlyHint"]
' || fail "MCP profile replies: $REPLIES"

# an unknown protocol version gets the newest one this server speaks
R="$(mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}')"
assert_eq "2025-06-18" "$(printf '%s' "$R" | jget - 'd["result"]["protocolVersion"]')"

# an action returns its output and the fresh status; down on a stopped bench is fine
R="$(mcp '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"benchbar_down","arguments":{"bench":"'"$BENCH"'"}}}')"
assert_eq "False" "$(printf '%s' "$R" | jget - 'd["result"]["isError"]')"
assert_eq "stopped" "$(printf '%s' "$R" | jget - 'd["result"]["structuredContent"]["status"]["state"]')"

# an action on a folder benchbar does not know (not in benchbar_list: not
# registered, remembered, discovered under ~ or ~/dev, or given an agent) is
# refused: no stop flag is written into it and nothing of it is signalled
STRAY="$HOME/work/stray-bench"; make_fake_bench "$STRAY" stray
add_proc 6001 "/x/bin/honcho start -f Procfile.lean" "$STRAY"
reset_calls
for tool in benchbar_down benchbar_up benchbar_restart; do
  R="$(mcp '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"'"$tool"'","arguments":{"bench":"'"$STRAY"'"}}}')"
  assert_eq "True" "$(printf '%s' "$R" | jget - 'd["result"]["isError"]')" "($tool on an unknown bench)"
  assert_contains "$(printf '%s' "$R" | jget - 'd["result"]["content"][0]["text"]')" "is not a bench benchbar knows"
done
assert_no_file "$STRAY/logs/.bench-stopped"
grep -q '^6001 ' "$MOCK_PROCS" || fail "the unknown bench's honcho must not be signalled"
assert_calls_not_contain '^(pkill|mockkill|launchctl kill)'
# the same path through a symlink, once registered, is accepted
run_fm register "$STRAY"; assert_eq "0" "$CODE" "$OUT"
ln -s "$STRAY" "$HOME/stray-link"
R="$(mcp '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"benchbar_down","arguments":{"bench":"'"$HOME/stray-link"'"}}}')"
assert_not_contains "$(printf '%s' "$R" | jget - 'd["result"]["content"][0]["text"]')" "is not a bench benchbar knows"
: >"$MOCK_PROCS"

# ---- a timeout ends the CLI and everything it started (its process group):
# a fake benchbar that starts a grandchild (a setup Redis stands in) and hangs
FAKE="$TMP_DIR/fake-benchbar"; GCPID="$TMP_DIR/mcp-grandchild.pid"
cat >"$FAKE" <<SH
#!/usr/bin/env bash
# "status --json" hangs with a child, like a bench command that never ends
case "\$*" in
  "list --json") printf '{"benches":[]}\n'; exit 0 ;;
esac
sleep 60 &
printf '%s\n' "\$!" >"$GCPID"
trap 'kill "\$!" 2>/dev/null; exit 143' TERM
wait
SH
chmod +x "$FAKE"
R="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"benchbar_status","arguments":{}}}' | BENCHBAR_MCP_CLI="$FAKE" BENCHBAR_MCP_TIMEOUT=1 BENCHBAR_MCP_KILL_GRACE=2 "$FM" mcp 2>/dev/null)"
assert_eq "True" "$(printf '%s' "$R" | jget - 'd["result"]["isError"]')" "$R"
assert_contains "$(printf '%s' "$R" | jget - 'd["result"]["content"][0]["text"]')" "did not answer in time (1.0s); it and everything it started were stopped"
[[ -s "$GCPID" ]] || fail "test setup: the fake CLI did not start its child"
sleep 0.5
kill -0 "$(cat "$GCPID")" 2>/dev/null && fail "the grandchild (pid $(cat "$GCPID")) must be gone after the timeout"
# a CLI that ignores TERM is killed after the grace period, with its child
cat >"$FAKE" <<SH
#!/usr/bin/env bash
trap '' TERM
sleep 60 &
printf '%s\n' "\$!" >"$GCPID"
wait
SH
R="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"benchbar_status","arguments":{}}}' | BENCHBAR_MCP_CLI="$FAKE" BENCHBAR_MCP_TIMEOUT=1 BENCHBAR_MCP_KILL_GRACE=1 "$FM" mcp 2>/dev/null)"
assert_eq "True" "$(printf '%s' "$R" | jget - 'd["result"]["isError"]')" "$R"
sleep 0.5
kill -0 "$(cat "$GCPID")" 2>/dev/null && fail "the grandchild of a CLI that ignores TERM must be killed with the group"

# ---- app add over MCP: a read only plan with a token, then the approved plan
# shellcheck source=tests/lib/apps-fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apps-fixtures.sh"
make_app_remote acme_dep
make_app_remote acme_web acme_dep
add_policy acme_dep main
URL="file://${REMOTES}/acme_web.git"
call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$1" "$2" "$3"; }
R="$(mcp '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')"
printf '%s' "$R" | python3 -c '
import json, sys
t = {x["name"]: x for x in json.load(sys.stdin)["result"]["tools"]}
p, a = t["benchbar_app_add_plan"], t["benchbar_app_add"]
assert p["annotations"]["readOnlyHint"] is True and a["annotations"]["readOnlyHint"] is False, (p, a)
assert a["annotations"]["destructiveHint"] is False
assert a["inputSchema"]["required"] == ["url_or_name", "token"], a["inputSchema"]
assert set(p["inputSchema"]["properties"]) == {"url_or_name", "branch", "name", "site", "all_sites", "bench"}, p
assert "OK" in a["description"] and "plan" in a["description"], a["description"]
' || fail "MCP app add tools: $R"
ARGS='{"url_or_name":"'"$URL"'","branch":"main","site":"macdev","bench":"'"$BENCH"'"}'
reset_calls
R="$(mcp "$(call 1 benchbar_app_add_plan "$ARGS")")"
assert_eq "False" "$(printf '%s' "$R" | jget - 'd["result"]["isError"]')" "$R"
assert_eq "acme_web ['acme_dep'] True" "$(printf '%s' "$R" | jget - '" ".join(str(x) for x in [d["result"]["structuredContent"]["app"], d["result"]["structuredContent"]["missing_required"], d["result"]["structuredContent"]["can_apply"]])')"
assert_calls_not_contain '^bench (get-app|build)'
TOKEN="$(printf '%s' "$R" | jget - 'd["result"]["structuredContent"]["token"]')"
# refusals: no token, a value that looks like an option, a stale token
R="$(mcp "$(call 2 benchbar_app_add "$ARGS")" "$(call 3 benchbar_app_add_plan '{"url_or_name":"--yes"}')")"
assert_eq "-32602 -32602" "$(printf '%s\n' "$R" | python3 -c 'import json,sys; print(" ".join(str(json.loads(l)["error"]["code"]) for l in sys.stdin if l.strip()))')"
STALE="$(printf '%s' "$ARGS" | python3 -c 'import json,sys; a=json.load(sys.stdin); a["token"]="0"*64; print(json.dumps(a))')"
R="$(mcp "$(call 4 benchbar_app_add "$STALE")")"
assert_eq "True" "$(printf '%s' "$R" | jget - 'd["result"]["isError"]')"
assert_contains "$(printf '%s' "$R" | jget - 'd["result"]["structuredContent"]["output"]')" "The app add plan changed"
assert_calls_not_contain '^bench (get-app|build)'
# the approved plan: output, the result and a fresh app list
WITH="$(printf '%s' "$ARGS" | python3 -c 'import json,sys; a=json.load(sys.stdin); a["token"]=sys.argv[1]; print(json.dumps(a))' "$TOKEN")"
R="$(mcp "$(call 5 benchbar_app_add "$WITH")")"
assert_eq "False" "$(printf '%s' "$R" | jget - 'd["result"]["isError"]')" "$R"
assert_eq "0 True" "$(printf '%s' "$R" | jget - '" ".join(str(x) for x in [d["result"]["structuredContent"]["exit_code"], d["result"]["structuredContent"]["result"]["ok"]])')"
assert_contains "$(printf '%s' "$R" | jget - '[a["name"] for a in d["result"]["structuredContent"]["apps"]["apps"]]')" "'acme_dep', 'acme_web'"
assert_calls_contain "^bench get-app --skip-assets --branch main file://${REMOTES}/acme_dep.git$"
assert_calls_contain '^bench --site macdev install-app acme_web$'

printf 'test-mcp: ok\n'
