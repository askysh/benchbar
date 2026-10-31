#!/usr/bin/env bash
# The agent contracts (0.9), part 3 of 3: the MCP server, every command with --json, refusals that end the stream, and the second and third review.
# shellcheck source=tests/lib/agent-contracts-fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/agent-contracts-fixtures.sh"
make_second_bench
make_log_bench
ADMIN_PASSWORD=adminpw stream site add newsite --json --yes --bench-dir "$BENCH"
# the log as part 2 leaves it: two lines, one with a secret
printf '10:00:01 web.1 | password=hunter2 ok\n10:00:02 web.1 | fine\n' >"$LB/logs/bench.log"

# ---------------------------------------------------------------- 7. the MCP server

FAKE="$TMP_DIR/fake-benchbar-contracts"
cat >"$FAKE" <<SH
#!/usr/bin/env bash
# records what the server runs and with which environment
printf '%s|%s\n' "\$*" "\${BENCHBAR_NONINTERACTIVE:-unset}" >>"$TMP_DIR/mcp-argv.log"
case "\$*" in
  "up --plain --json"*) printf '%s\n' '{"schema_version":1,"cli_version":"x","event":"step","id":"start_service","status":"done"}' '{"schema_version":1,"cli_version":"x","event":"done","exit":0,"changed":[{"kind":"process","name":"b","detail":"started"}],"warnings":[],"next_actions":[],"state_after":null}'; echo "[OK] bench is up" >&2; exit 0 ;;
  "list --json") printf '{"benches":[]}\n'; exit 0 ;;
  *) printf '{"state":"running"}\n'; exit 0 ;;
esac
SH
chmod +x "$FAKE"
INIT='{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}'
mcp_call() { printf '%s\n' "$INIT" "$1" | BENCHBAR_MCP_CLI="$FAKE" "$FM" mcp 2>/dev/null | tail -n +2; }
: >"$TMP_DIR/mcp-argv.log"
R="$(mcp_call '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"benchbar_status","arguments":{}}}')"
assert_contains "$(cat "$TMP_DIR/mcp-argv.log")" "status --json --ping|1" "(status pings every site; the CLI is told nothing can be asked)"
R="$(mcp_call '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"benchbar_up","arguments":{}}}')"
assert_contains "$(cat "$TMP_DIR/mcp-argv.log")" "up --plain --json|1"
assert_contains "$(cat "$TMP_DIR/mcp-argv.log")" "status --json --ping|1" "(the status after an action pings too)"
assert_eq "0 [OK] bench is up True" "$(printf '%s' "$R" | jget - '" ".join(str(x) for x in (d["result"]["structuredContent"]["exit_code"], d["result"]["structuredContent"]["output"], d["result"]["structuredContent"]["result"]["changed"][0]["kind"] == "process"))')" "(the result keeps its fields; the done line is added)"
: >"$TMP_DIR/mcp-argv.log"
R="$(mcp_call '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"benchbar_logs_tail","arguments":{"since":"2026-10-29T00:00:03Z","since_restart":true,"lines":5}}}')"
assert_contains "$(cat "$TMP_DIR/mcp-argv.log")" "logs --json --no-follow -n5 --since 2026-10-29T00:00:03Z --since-restart"
# the real CLI through the real server: times come through, and a size cap drops lines and times together
R="$(printf '%s\n' "$INIT" '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"benchbar_logs_tail","arguments":{"bench":"'"$LB"'","lines":10}}}' | "$FM" mcp 2>/dev/null | tail -n +2)"
assert_eq "2 2 True" "$(printf '%s' "$R" | jget - '"%d %d %s" % (len(d["result"]["structuredContent"]["lines"]), len(d["result"]["structuredContent"]["ts"]), d["result"]["structuredContent"]["mtime"] is not None)')"
for i in $(seq 1 400); do printf '10:00:%02d web.1 | filler line number %d to make this log bigger\n' $((i % 60)) "$i"; done >"$LB/logs/bench.log"
R="$(printf '%s\n' "$INIT" '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"benchbar_logs_tail","arguments":{"bench":"'"$LB"'","lines":400}}}' | BENCHBAR_MCP_MAX_BYTES=6000 "$FM" mcp 2>/dev/null | tail -n +2)"
assert_eq "True True" "$(printf '%s' "$R" | jget - 'str(d["result"]["structuredContent"].get("truncated")) + " " + str(len(d["result"]["structuredContent"]["lines"]) == len(d["result"]["structuredContent"]["ts"]) < 400)')"

# ---------------------------------------------------------------- 2b. every command with --json: JSON and nothing else

# the commands that print one document: one line, parses, and a refusal leaves stdout empty
for c in "status" "list" "doctor" "site list" "site backups newsite" "logs --no-follow" "where" "app list --no-sites" "ports check" "profile list" "commands" "doctor --prerequisites"; do
  # shellcheck disable=SC2086
  run_json $c --json --bench-dir "$BENCH"
  assert_eq "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "$c: one line (exit $CODE)"
  assert_eq "ok" "$(printf '%s' "$OUT" | jget - '"ok" if isinstance(d, dict) else "no"')" "$c"
done
for c in "status" "doctor" "logs --no-follow" "site list" "app list"; do
  # shellcheck disable=SC2086
  run_json $c --json --bench-dir "$HOME/no-such-bench"
  assert_eq "1" "$CODE" "$c"; assert_eq "" "$OUT" "$c: a refusal under --json leaves stdout empty"
  assert_contains "$ERR" "No bench at"
done
# every dry run with --json: the plan alone (a stream: plan, then done), never text on stdout
# site add's dry run is its plan with a token, one document like app update's;
# --jsonl makes it the stream
run_json site add dryrunsite --dry-run --json --bench-dir "$BENCH"
assert_eq "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "site add --dry-run --json: one line"
[[ "$(printf '%s' "$OUT" | jget - 'd["token"]')" =~ ^[0-9a-f]{64}$ ]] || fail "site add plan without a token: $OUT"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["dry_run"]')" "(the plan document says it is a dry run)"
ADMIN_PASSWORD=pw stream site add dryrunsite --dry-run --jsonl --bench-dir "$BENCH"
assert_eq "plan done" "$(sx '" ".join(x["event"] for x in e)')"
stream adopt "$B2" --dry-run --json --bench-dir "$B2"
assert_eq "plan done" "$(sx '" ".join(x["event"] for x in e)')"
stream install --dry-run --json --bench-dir "$HOME/dry-install" --site dry.localhost
assert_eq "plan done" "$(sx '" ".join(x["event"] for x in e)')"
stream ports apply 0000 --dry-run --json --yes --bench-dir "$BENCH" -- "$BENCH"
assert_eq "done 1" "$(sx '"%s %s" % (e[-1]["event"], e[-1]["exit"])')" "(a refused ports apply still ends with its done line)"
run_events repair --json --dry-run --bench-dir "$BENCH"
assert_eq "plan" "$(ev '" ".join(x["event"] for x in e)')"

# ---------------------------------------------------------------- 8. refusals end the stream; honest changed[]; ack; repair

rm -rf "$MOCK_STATE/keychain"
unset MARIADB_ROOT_PASSWORD
export BENCHBAR_NONINTERACTIVE=1
n_logs="$(logs_now)"; reset_calls
# install --json --yes without ADMIN_PASSWORD: the stream ends with a done naming it, nothing else happened
stream install --json --yes --bench-dir "$HOME/noni2" --site noni2.localhost
assert_eq "1" "$CODE" "$(cat "$STREAM.err")"
assert_eq "done" "$(sx '" ".join(x["event"] for x in e)')"
assert_eq "1 ['ADMIN_PASSWORD']" "$(sx '"%s %s" % (e[-1]["exit"], e[-1]["missing"])')"
assert_contains "$(sx 'e[-1]["error"]')" "ADMIN_PASSWORD"
assert_calls_not_contain '^(bench|brew install|brew services|launchctl)'
assert_no_file "$FL_STATE_DIR/lock"; assert_eq "$n_logs" "$(logs_now)" "(no log)"; assert_no_file "$HOME/noni2"
# site add --for-agent with nothing: every missing input, exit 2 because the MariaDB password is one of them
stream site add noni3 --for-agent --bench-dir "$BENCH"
assert_eq "2" "$CODE"
assert_eq "done 2" "$(sx '"%s %s" % (e[-1]["event"], e[-1]["exit"])')"
assert_eq "True" "$(sx '{"ADMIN_PASSWORD", "MARIADB_ROOT_PASSWORD", "--yes"} <= set(e[-1]["missing"])')"
assert_eq "$n_logs" "$(logs_now)"; assert_no_file "$FL_STATE_DIR/lock"
# a one document command under --json: the one document, with exit, error and missing
mkdir -p "$BENCH/sites/dropme3"; printf '{}\n' >"$BENCH/sites/dropme3/site_config.json"
run_json site drop dropme3 --confirm-site dropme3 --json --bench-dir "$BENCH"
assert_eq "2" "$CODE"
assert_eq "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
assert_eq "2 ['MARIADB_ROOT_PASSWORD']" "$(printf '%s' "$OUT" | jget - '"%s %s" % (d["exit"], d["missing"])')"
assert_contains "$(printf '%s' "$OUT" | jget - 'd["error"]')" "MARIADB_ROOT_PASSWORD"
assert_calls_not_contain '^bench '
# the plain refusal is exit 2 too (AGENTS.md)
run_fm site add noni3 --bench-dir "$BENCH"
assert_eq "2" "$CODE" "$OUT"
unset BENCHBAR_NONINTERACTIVE

# repair --json with no bench: a done line with exit 1 and an error, not silence
run_events repair --json --yes --bench-dir "$HOME/no-such-bench"
assert_eq "1" "$CODE"
assert_eq "done 1" "$(ev '"%s %s" % (e[-1]["event"], e[-1]["exit"])')"
assert_contains "$(ev 'e[-1]["error"]')" "No bench"

# changed[] says only what changed: an app already on the site is not a change
export MARIADB_ROOT_PASSWORD=rootpw
ADMIN_PASSWORD=pw stream site add appsite1 --apps erpnext --json --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$(cat "$STREAM.err")"
assert_eq "app site" "$(sx '" ".join(sorted(set(x["kind"] for x in e[-1]["changed"] if x["kind"] in ("site", "app"))))')"
ADMIN_PASSWORD=pw stream site add appsite1 --apps erpnext --json --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$(cat "$STREAM.err")"
assert_eq "[]" "$(sx '[x for x in e[-1]["changed"] if x["kind"] in ("site", "app")]')" "(a second run changes nothing)"

# doctor --ack under --json: one small document, under the lock, and an ack does not adopt a bench
mkdir -p "$HOME/Applications/CleanMyMac X.app"
run_json doctor --ack cleanmymac --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$ERR"
assert_eq "1" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
assert_eq "ack cleanmymac True 0" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in (d["action"], d["check"], "cleanmymac" in d["acked"], d["exit"]))')"
assert_eq "state" "$(printf '%s' "$OUT" | jget - 'd["changed"][0]["kind"]')"
run_json doctor --unack cleanmymac --json --bench-dir "$BENCH"
assert_eq "unack []" "$(printf '%s' "$OUT" | jget - '"%s %s" % (d["action"], d["acked"])')"
HOLD=$$   # a live process: this test shell
mkdir -p "$FL_STATE_DIR/lock"; printf '%s\n' "$HOLD" >"$FL_STATE_DIR/lock/pid"
run_fm doctor --ack cleanmymac --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "Another benchbar run is active"
run_fm doctor --bench-dir "$BENCH"
assert_not_contains "$OUT" "Another benchbar run"
rm -rf "$FL_STATE_DIR/lock"
NA2="$HOME/elsewhere/na2-bench"; make_fake_bench "$NA2" na2-site
run_fm doctor --ack cleanmymac --bench-dir "$NA2"
assert_eq "0" "$CODE" "$OUT"
run_fm status --json --bench-dir "$NA2"
assert_eq "not_adopted" "$(printf '%s' "$OUT" | jget - 'd["state"]')" "(an ack alone does not make a bench known)"
rm -rf "$HOME/Applications/CleanMyMac X.app"

# ---------------------------------------------------------------- 9. second review

# repair --dry-run --json with the app's arguments on a missing bench: a reason on stderr, a done line on stdout
run_events repair --dry-run --json --bench-dir "$HOME/no-such-bench-either"
assert_eq "1" "$CODE"
assert_eq "done 1" "$(ev '"%s %s" % (e[-1]["event"], e[-1]["exit"])')"
assert_contains "$(ev 'e[-1]["error"]')" "No bench"
assert_contains "$(cat "$STREAM.err")" "No bench" "(the app summarizes stderr and stdout: the reason is there)"
# a dry run that works is still the plan alone
run_events repair --dry-run --json --bench-dir "$BENCH"
assert_eq "plan" "$(ev '" ".join(x["event"] for x in e)')"

# a stream refusal: state_after is null, and the reason is on stderr too
export BENCHBAR_NONINTERACTIVE=1
rm -rf "$MOCK_STATE/keychain"; unset MARIADB_ROOT_PASSWORD
stream site add refused1 --json --bench-dir "$BENCH"
assert_eq "None" "$(sx 'e[-1]["state_after"]')"
assert_contains "$(cat "$STREAM.err")" "[FAIL] Cannot start, missing:"
unset BENCHBAR_NONINTERACTIVE
# without the mode: neither password known is exit 2 too (a missing ADMIN_PASSWORD came first and said 1)
run_fm site add refused2 --bench-dir "$BENCH" </dev/null
assert_eq "2" "$CODE" "$OUT"
export MARIADB_ROOT_PASSWORD=rootpw
run_fm site add refused2 --bench-dir "$BENCH" </dev/null
assert_eq "1" "$CODE" "$OUT"

# a key-value lock born in the future (the clock stepped back) is broken, not waited on for good
(
  set +e
  # shellcheck source=lib/frappe-local/ui.sh
  . "$ROOT/lib/frappe-local/ui.sh"
  # shellcheck source=lib/frappe-local/state.sh
  . "$ROOT/lib/frappe-local/state.sh"
  mkdir -p "$TMP_DIR/kv.d"; : >"$TMP_DIR/kv.d/f"; mkdir "$TMP_DIR/kv.d/f.lck"
  touch -t 203501010000 "$TMP_DIR/kv.d/f.lck"
  fl__kv_lock "$TMP_DIR/kv.d/f" >/dev/null 2>&1 &
  waiter=$!
  n=0
  while kill -0 "$waiter" 2>/dev/null && [[ "$n" -lt 400 ]]; do sleep 0.1; n=$((n + 1)); done
  if kill -0 "$waiter" 2>/dev/null; then kill "$waiter" 2>/dev/null; echo hung >"$TMP_DIR/kv.result"; else echo broken >"$TMP_DIR/kv.result"; fi
)
assert_eq "broken" "$(cat "$TMP_DIR/kv.result")" "(a lock from the future is broken)"

# ---------------------------------------------------------------- 10. third review

# the non interactive mode never lets sudo prompt: a hosts line that needs a
# password is skipped with its command, as under --json, and sudo -v never runs
cp "$FL_HOSTS_FILE" "$TMP_DIR/hosts.keep"
grep -v ' macdev$' "$TMP_DIR/hosts.keep" >"$FL_HOSTS_FILE"
rm -f "$MOCK_STATE/sudo_cred"; reset_calls
BENCHBAR_NONINTERACTIVE=1 run_fm repair --yes --bench-dir "$BENCH"
assert_calls_not_contain '^sudo -v' "(BENCHBAR_NONINTERACTIVE=1 repair must not prompt for sudo)"
assert_contains "$OUT" "cannot ask for one"
assert_eq "0" "$(grep -c ' macdev$' "$FL_HOSTS_FILE" || true)" "(the hosts step was skipped)"
reset_calls
stream --for-agent repair --yes --bench-dir "$BENCH"
assert_calls_not_contain '^sudo -v' "(--for-agent repair must not prompt for sudo)"
assert_eq "done" "$(ev 'e[-1]["event"]')"
cp "$TMP_DIR/hosts.keep" "$FL_HOSTS_FILE"; touch "$MOCK_STATE/sudo_cred"

# warnings[] and next_actions[] say what is still wrong after the verify pass,
# not what the plan found before the run fixed it
mv "$BENCH/Procfile.lean" "$TMP_DIR/Procfile.lean.aside"
run_events repair --yes --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$(cat "$STREAM.err")"
assert_eq "done 0 True" "$(ev '"%s %s %s" % (e[-1]["event"], e[-1]["exit"], any(c["name"] == "write_procfile" for c in e[-1]["changed"]))')"
assert_eq "[]" "$(ev '[w for w in e[-1]["warnings"] if "Procfile" in w]')" "(a fixed problem is not a warning)"
assert_eq "[]" "$(ev '[a for a in e[-1]["next_actions"] if "repair" in a["command"]]')" "(nothing left for repair to do)"

# site drop --new-default: the default's move is in changed[] too (it ran in a subshell)
mkdir -p "$BENCH/sites/dropdef"; printf '{}\n' >"$BENCH/sites/dropdef/site_config.json"
run_fm site default dropdef --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
stream site drop dropdef --confirm-site dropdef --new-default macdev --jsonl --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$(cat "$STREAM.err")"
assert_eq "True" "$(sx '{"kind": "site", "name": "macdev", "detail": "now the default site"} in e[-1]["changed"]')" "$(cat "$STREAM")"
assert_eq "macdev macdev" "$(sx '"%s %s" % (e[-1]["default_site"], e[-1]["state_after"]["site"])')" "$(cat "$STREAM")"

# site add NEW --dry-run: nothing was created, and the done line of the stream says it was a dry run
# (--json is the one document plan, which claims nothing either)
ADMIN_PASSWORD=pw stream site add drynew --dry-run --jsonl --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$(cat "$STREAM.err")"
assert_eq "False True" "$(sx '"%s %s" % (e[-1].get("created", False), e[-1].get("dry_run"))')" "$(cat "$STREAM")"
run_json site add drynew --dry-run --json --bench-dir "$BENCH"
assert_eq "0 False" "$CODE $(printf '%s' "$OUT" | jget - 'd.get("created", False)')" "$OUT"
assert_no_file "$BENCH/sites/drynew"

printf 'test-agent-contracts-3: ok\n'
