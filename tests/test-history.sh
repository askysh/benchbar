#!/usr/bin/env bash
# Action history (askysh/benchbar#185): every run that changes things appends one line to history.jsonl
# (op_id, command line with its secrets as ***, who started it, bench, site, times, exit, what it changed,
# its log), BENCHBAR_CALLER says who, the run log's first line says it too, the file is rotated, and
# benchbar history and the MCP tool benchbar_history read it.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH" macdev
printf 'port 11000\n' >"$BENCH/config/redis_queue.conf"; printf 'port 13000\n' >"$BENCH/config/redis_cache.conf"
run_fm service --yes --bench-dir "$BENCH" </dev/null
assert_eq "0" "$CODE" "$OUT"
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
export MARIADB_ROOT_PASSWORD=rootpw
mkdir -p "$BENCH/sites/bbtest.localhost"; printf '{}\n' >"$BENCH/sites/bbtest.localhost/site_config.json"
HIST="$FL_STATE_DIR/history.jsonl"
export FL_OP_WAIT_POLL=0.1
unset BENCHBAR_CALLER

# no terminal on stdin, whatever runs the suite; JSON calls keep stdout and stderr apart
run_json() {
  set +e
  OUT="$("$FM" "$@" 2>"$MOCK_STATE/stderr" </dev/null)"
  CODE="$?"
  ERR="$(cat "$MOCK_STATE/stderr")"
  set -e
}
run_quiet() { set +e; "$FM" "$@" >/dev/null 2>&1 </dev/null; set -e; }
# last_line: the newest line of the history file
last_line() { tail -n 1 "$HIST"; }
field() { printf '%s' "$1" | jget - "$2"; }

# ---- 1. a run that changes things leaves one line; a read, a dry run and a refusal leave none
rm -f "$HIST"
run_quiet status --json --bench-dir "$BENCH"
run_quiet doctor --json --bench-dir "$BENCH"
run_quiet service --dry-run --json --bench-dir "$BENCH"
run_quiet history --json
assert_no_file "$HIST" "(a status, a doctor, a dry run and history itself write no line)"
run_json site backup bbtest.localhost --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
OP1="$(field "$OUT" 'd["op_id"]')"
assert_eq "1" "$(wc -l <"$HIST" | tr -d ' ')"
L="$(last_line)"
assert_eq "$OP1 site backup 0 script" "$(field "$L" 'd["op_id"] + " " + d["command"] + " " + str(d["exit"]) + " " + d["caller"]')" "$L"
assert_eq "True" "$(field "$L" 'd["argv"] == ["site", "backup", "bbtest.localhost", "--json", "--bench-dir", "'"$BENCH"'"] and d["bench"] == "'"$BENCH"'" and d["site"] == "bbtest.localhost" and d["mcp"] is None and d["started_at"].endswith("Z") and d["ended_at"] >= d["started_at"] and isinstance(d["changed"], list) and d["changed_more"] == 0 and d["log"].endswith(".log")')" "$L"
assert_file "$(field "$L" 'd["log"]')" "(the line names the run's log)"
# 0600, like the MCP audit log
if [[ "$STAT_GNU" == "1" ]]; then MODE="$(stat -c %a "$HIST")"; else MODE="$(stat -f %Lp "$HIST")"; fi
assert_eq "600" "$MODE"

# a failed run is a line with its exit
MOCK_BENCH_BACKUP_EXIT=1 run_quiet site backup bbtest.localhost --json --bench-dir "$BENCH"
assert_eq "1" "$(field "$(last_line)" 'd["exit"]')"
assert_eq "2" "$(wc -l <"$HIST" | tr -d ' ')"

# ---- 2. who started it: BENCHBAR_CALLER, a terminal, --for-agent, the default
BENCHBAR_CALLER=app run_quiet site backup bbtest.localhost --bench-dir "$BENCH"
APPLINE="$(last_line)"
assert_eq "app" "$(field "$APPLINE" 'd["caller"]')"
assert_contains "$(head -n 1 "$(field "$APPLINE" 'd["log"]')")" "run: benchbar site backup bbtest.localhost --bench-dir $BENCH (caller: app, op: $(field "$APPLINE" 'd["op_id"]'))" "(the run log's first line says who and what)"
BENCHBAR_CALLER=tray run_quiet site backup bbtest.localhost --bench-dir "$BENCH"
assert_eq "tray" "$(field "$(last_line)" 'd["caller"]')"
# a value outside the list is ignored, so no text can be put into the history through it
BENCHBAR_CALLER='app"},{"x":"' run_quiet site backup bbtest.localhost --bench-dir "$BENCH"
assert_eq "script" "$(field "$(last_line)" 'd["caller"]')"
BENCHBAR_CALLER=root run_quiet site backup bbtest.localhost --bench-dir "$BENCH"
assert_eq "script" "$(field "$(last_line)" 'd["caller"]')"
assert_not_contains "$(cat "$HIST")" '"x":"'
# --for-agent says agent; an explicit caller (the Mac app asking for JSON) wins over it
run_quiet site backup bbtest.localhost --for-agent --bench-dir "$BENCH"
assert_eq "agent" "$(field "$(last_line)" 'd["caller"]')"
BENCHBAR_CALLER=app run_quiet site backup bbtest.localhost --for-agent --bench-dir "$BENCH"
assert_eq "app" "$(field "$(last_line)" 'd["caller"]')"
# a person at a terminal
run_fm_tty site backup bbtest.localhost --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "terminal" "$(field "$(last_line)" 'd["caller"]')"
assert_contains "$(head -n 1 "$(field "$(last_line)" 'd["log"]')")" "(caller: terminal, op: "

# ---- 3. the command line never holds a secret (the rules of the MCP audit log)
run_quiet site backup bbtest.localhost --password hunter2 --api-key=k123tail --apply tok777 'FOO_SECRET=abc999' 'https://bob:pw555@example.com/r.git?token=zz888&x=1' --bench-dir "$BENCH"
SECRETLINE="$(last_line)"
assert_eq "True" "$(field "$SECRETLINE" 'd["argv"] == ["site", "backup", "bbtest.localhost", "--password", "***", "--api-key=***", "--apply", "***", "FOO_SECRET=***", "https://***@example.com/r.git?token=***&x=1", "--bench-dir", "'"$BENCH"'"]')" "$SECRETLINE"
for s in hunter2 k123tail tok777 abc999 pw555 zz888; do
  assert_not_contains "$(cat "$HIST")" "$s" "(the history)"
  assert_not_contains "$(cat "$(field "$SECRETLINE" 'd["log"]')")" "$s" "(the run log)"
done
assert_contains "$(head -n 1 "$(field "$SECRETLINE" 'd["log"]')")" "--password *** --api-key=*** --apply ***"
# a very long word is cut, and a very long line keeps its first words
LONG="$(printf 'a%.0s' $(seq 1 400))"
run_quiet site backup bbtest.localhost "$LONG" --bench-dir "$BENCH"
assert_eq "True" "$(field "$(last_line)" 'any(w.endswith("... [cut]") and len(w) < 230 for w in d["argv"])')"
run_quiet site backup $(seq 1 60) --bench-dir "$BENCH"
assert_eq "True" "$(field "$(last_line)" 'len(d["argv"]) == 41 and d["argv"][-1] == "..."')"

# ---- 4. the changes of a run (from its done line), kept compact
rm -f "$HIST"
run_json site backup bbtest.localhost --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
DONE_KINDS="$(field "$OUT" '",".join(sorted(c["kind"] + ":" + c["name"] for c in d["changed"]))')"
HIST_KINDS="$(field "$(last_line)" '",".join(sorted(c["kind"] + ":" + c["name"] for c in d["changed"]))')"
assert_eq "$DONE_KINDS" "$HIST_KINDS" "(the history's changed[] is the done line's, as kind and name)"
assert_not_contains "$(last_line)" '"detail"' "(the detail stays in the done line and the log)"

# ---- 5. benchbar history: newest first, limit, since, bench, text and JSON
rm -f "$HIST"
OLD='{"op_id":"op-20250101-100000-11","command":"app add","argv":["app","add","x"],"caller":"terminal","mcp":null,"bench":"/other/bench","site":null,"started_at":"2025-01-01T10:00:00Z","ended_at":"2025-01-01T10:05:00Z","exit":0,"changed":[{"kind":"app","name":"x"}],"changed_more":0,"cli_version":"0.9.0","log":null}'
printf '%s\n' "$OLD" >"$HIST"
printf 'half a line of a killed writer\n{"op_id":"op-2025' >>"$HIST"
printf '\n' >>"$HIST"
for n in 1 2 3; do run_quiet site backup "s$n.localhost" --bench-dir "$BENCH"; done
run_json history --json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "True" "$(field "$OUT" 'd["schema_version"] == 1 and len(d["history"]) == 4 and [h["argv"][2] for h in d["history"][:3]] == ["s3.localhost", "s2.localhost", "s1.localhost"] and d["history"][3]["op_id"] == "op-20250101-100000-11"')" "$OUT"
assert_eq "$(field "$OUT" 'd["history"][0]["op_id"]')" "$(field "$(last_line)" 'd["op_id"]')" "(the newest first)"
assert_eq "2" "$(field "$("$FM" history --json --limit 2 </dev/null)" 'len(d["history"])')"
assert_eq "2" "$(field "$("$FM" history --json --limit=2 </dev/null)" 'len(d["history"])')"
assert_eq "3" "$(field "$("$FM" history --json --since 1h </dev/null)" 'len(d["history"])')" "(since 1h leaves the old one out)"
assert_eq "4" "$(field "$("$FM" history --json --since 2024-12-31 </dev/null)" 'len(d["history"])')"
assert_eq "4" "$(field "$("$FM" history --json --since 2025-01-01T10:00:00Z </dev/null)" 'len(d["history"])')"
assert_eq "3" "$(field "$("$FM" history --json --bench "$BENCH" </dev/null)" 'len(d["history"])')"
assert_eq "3" "$(field "$("$FM" history --json --bench "$BENCH/" </dev/null)" 'len(d["history"])')" "(a trailing slash)"
assert_eq "3" "$(field "$("$FM" history --json --bench-dir "$BENCH" </dev/null)" 'len(d["history"])')"
assert_eq "1" "$(field "$("$FM" history --json --bench /other/bench </dev/null)" 'len(d["history"])')" "(a bench that is gone from the disk still matches by its text)"
assert_eq "0" "$(field "$("$FM" history --json --bench /nowhere </dev/null)" 'len(d["history"])')"
run_json history --limit 0
assert_eq "1" "$CODE"; assert_contains "$OUT$ERR" "--limit takes a number from 1 to 1000"
run_json history --since yesterday
assert_eq "1" "$CODE"; assert_contains "$OUT$ERR" "--since takes a time"
run_json history --nope
assert_eq "1" "$CODE"; assert_contains "$OUT$ERR" "Unknown option for history: --nope"
run_fm history </dev/null
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "Started"
assert_contains "$OUT" "benchbar site backup"
assert_contains "$OUT" "script"
assert_contains "$OUT" "benchbar app add"
rm -f "$HIST"
run_fm history </dev/null
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "No runs recorded yet."
assert_eq "True" "$(field "$("$FM" history --json </dev/null)" 'd["history"] == []')"
# --for-agent asks for the document
assert_eq "True" "$(field "$("$FM" history --for-agent </dev/null)" 'd["history"] == []')"

# ---- 6. rotation: past the limit the file moves to .old.1, three older ones stay, the reader sees all
rm -f "$HIST" "$HIST".old.*
export FL_HISTORY_MAX=1500
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do run_quiet site backup "r$n.localhost" --bench-dir "$BENCH"; done
assert_file "$HIST.old.1"; assert_file "$HIST.old.2"; assert_file "$HIST.old.3"
assert_no_file "$HIST.old.4" "(three old files at most)"
if [[ "$STAT_GNU" == "1" ]]; then MODE="$(stat -c %a "$HIST.old.1")"; else MODE="$(stat -f %Lp "$HIST.old.1")"; fi
assert_eq "600" "$MODE" "(the rotated file keeps its mode)"
assert_eq "True" "$(field "$("$FM" history --json --limit 1000 </dev/null)" '(lambda ws: len(ws) > 6 and ws[0] == "r20.localhost" and ws == sorted(ws, key=lambda w: -int(w[1:-10])))([h["argv"][2] for h in d["history"]])')" "(newest first across the files)"
unset FL_HISTORY_MAX

# ---- 7. a detached run keeps the caller of its launcher and the command line without --background
rm -f "$HIST"
BENCHBAR_CALLER=app MOCK_BENCH_BACKUP_SLEEP=0 run_json site backup bbtest.localhost --background --yes --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT$ERR"
BG="$(field "$OUT" 'd["op_id"]')"
run_json op wait "$BG" --timeout 60 --json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "$BG app" "$(field "$(last_line)" 'd["op_id"] + " " + d["caller"]')"
assert_eq "True" "$(field "$(last_line)" 'd["argv"] == ["site", "backup", "bbtest.localhost", "--yes", "--json", "--bench-dir", "'"$BENCH"'"]')" "$(last_line)"
# no terminal behind a detached run, and none is claimed for it
run_json site backup bbtest.localhost --background --yes --json --bench-dir "$BENCH"
BG2="$(field "$OUT" 'd["op_id"]')"
run_json op wait "$BG2" --timeout 60 --json
assert_eq "script" "$(field "$(last_line)" 'd["caller"]')"

# ---- 8. the MCP server: the caller, the tool and the client in the history; op_id in the audit log; the read tool
BENCHBAR_MCP_APPLY_DELAY=0
export BENCHBAR_MCP_APPLY_DELAY
INIT='{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test-client","version":"1.2"}}}'
mcp() { printf '%s\n' "$INIT" '{"jsonrpc":"2.0","method":"notifications/initialized"}' "$@" | "$FM" mcp 2>/dev/null | tail -n +2; }
call() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$1" "$2" "$3"; }
rm -f "$HIST" "$FL_STATE_DIR/mcp-calls.jsonl"
R="$(mcp "$(call 1 benchbar_site_backup '{"site":"bbtest.localhost","bench":"'"$BENCH"'"}')")"
assert_eq "False" "$(field "$R" 'd["result"]["isError"]')" "$R"
MID="$(field "$R" 'd["result"]["structuredContent"]["op_id"]')"
ML="$(last_line)"
assert_eq "$MID mcp benchbar_site_backup test-client 1.2" "$(field "$ML" 'd["op_id"] + " " + d["caller"] + " " + d["mcp"]["tool"] + " " + d["mcp"]["client"]')" "$ML"
assert_eq "$MID" "$(field "$(tail -n 1 "$FL_STATE_DIR/mcp-calls.jsonl")" 'd["op_id"]')" "(the audit log names the run it started)"
assert_eq "benchbar_site_backup" "$(field "$(tail -n 1 "$FL_STATE_DIR/mcp-calls.jsonl")" 'd["tool"]')"
# a tool or client text outside the pattern is not kept
BENCHBAR_CALLER=mcp BENCHBAR_MCP_TOOL='x"y' BENCHBAR_MCP_CLIENT=$'bad\nclient' run_quiet site backup bbtest.localhost --bench-dir "$BENCH"
assert_eq "True" "$(field "$(last_line)" 'd["caller"] == "mcp" and d["mcp"] is None')" "$(last_line)"
R="$(mcp "$(call 1 benchbar_history '{}')" "$(call 2 benchbar_history '{"limit":1,"bench":"'"$BENCH"'"}')" "$(call 3 benchbar_history '{"limit":0}')" "$(call 4 benchbar_history '{"since":"yesterday"}')" "$(call 5 benchbar_history '{"since":"1h"}')")"
printf '%s' "$R" | python3 -c '
import json, sys
by = {json.loads(l)["id"]: json.loads(l) for l in sys.stdin.read().splitlines()}
bad = lambda m: "error" in m or m["result"]["isError"]
one = by[1]["result"]
assert not one["isError"] and len(one["structuredContent"]["history"]) >= 2, one
assert one["content"][0]["text"].startswith("Data from the bench (command lines"), one["content"][0]["text"][:120]
assert any(h["caller"] == "mcp" and h["mcp"] and h["mcp"]["tool"] == "benchbar_site_backup" for h in one["structuredContent"]["history"]), one
assert len(by[2]["result"]["structuredContent"]["history"]) == 1, by[2]
assert bad(by[3]) and bad(by[4]), (by[3], by[4])
assert not bad(by[5]), by[5]' || fail "benchbar_history replies: $R"
# the call itself changes nothing: no line for the history tool
N0="$(wc -l <"$HIST" | tr -d ' ')"
mcp "$(call 1 benchbar_history '{}')" >/dev/null
assert_eq "$N0" "$(wc -l <"$HIST" | tr -d ' ')" "(reading the history is no run)"
assert_eq "True" "$(mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | jget - 'any(t["name"] == "benchbar_history" and t["annotations"]["readOnlyHint"] is True for t in d["result"]["tools"])')"
assert_eq "True" "$(mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | jget - 'all("since" in t["inputSchema"]["properties"] for t in d["result"]["tools"] if t["name"] == "benchbar_history")')"

printf 'ok\n'
