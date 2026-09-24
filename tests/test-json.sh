#!/usr/bin/env bash
# The versioned JSON contract (docs/json-schema.md): list, status, doctor,
# and the state.json that up, down and restart write.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/dev/frappe-bench"
OTHER="$HOME/dev/second"
make_fake_bench "$BENCH"
make_fake_bench "$OTHER" secondsite
sed -i '' 's/"webserver_port": 8000/"webserver_port": 8001/; s/"socketio_port": 9000/"socketio_port": 9001/' "$OTHER/sites/common_site_config.json"
state="$BENCH/logs/.benchbar/state.json"

# status_field EXPR: runs status --json for $BENCH and evaluates EXPR on it
status_field() {
  run_fm status --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
  printf '%s' "$OUT" | jget - "$1"
}

# ---- list
run_fm service --yes --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
run_fm list --json
assert_eq "0" "$CODE" "$OUT"
assert_eq "1" "$(printf '%s' "$OUT" | jget - 'd["schema_version"]')"
assert_eq "0.3.0" "$(printf '%s' "$OUT" | jget - 'd["cli_version"]')"
assert_eq "$BENCH" "$(printf '%s' "$OUT" | jget - 'd["default_bench"]')"
assert_eq "2" "$(printf '%s' "$OUT" | jget - 'len(d["benches"])')"
printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
b = {x["name"]: x for x in d["benches"]}
first, second = b["frappe-bench"], b["second"]
assert first["default"] is True and second["default"] is False, d
assert first["label"] == "com.benchbar.frappe-bench", first
assert first["site"] == "macdev" and second["site"] == "secondsite", d
assert second["ports"] == {"web": 8001, "socketio": 9001, "redis_queue": 11000, "redis_cache": 13000}, second
assert second["web_url"] == "http://secondsite:8001", second
assert first["service_installed"] is True and second["service_installed"] is False, d
assert first["state_file"].endswith("/frappe-bench/logs/.benchbar/state.json"), first
assert d["benches"][0]["name"] == "frappe-bench", "the remembered bench comes first"
' || fail "list --json content"
run_fm list
assert_contains "$OUT" "frappe-bench (default)"
assert_contains "$OUT" "secondsite"

# ---- status: every state
# stopped by hand (service writes a manual flag for a bench that was not running)
assert_eq "stopped manual None None" "$(status_field 'd["state"], d["stop_reason"], d["pid"], d["web_ping_code"]' | tr -d "(),'")"
assert_eq "1 0.3.0 com.benchbar.frappe-bench http://macdev:8000" \
  "$(status_field 'd["schema_version"], d["cli_version"], d["label"], d["web_url"]' | tr -d "(),'")"
assert_eq "$BENCH frappe-bench macdev" "$(status_field 'd["bench"], d["name"], d["site"]' | tr -d "(),'")"
# the frappe-mac 0.2.0 fields are still there
assert_eq "manual yes" "$(status_field 'd["stop_flag"], d["loaded"]' | tr -d "(),'")"

printf 'crash\n' >"$BENCH/logs/.bench-stopped"
assert_eq "paused crash" "$(status_field 'd["state"], d["stop_reason"]' | tr -d "(),'")"
printf 'broken\n' >"$BENCH/logs/.bench-stopped"
assert_eq "paused broken" "$(status_field 'd["state"], d["stop_reason"]' | tr -d "(),'")"
rm -f "$BENCH/logs/.bench-stopped"
assert_eq "stopped None" "$(status_field 'd["state"], d["stop_reason"]' | tr -d "(),'")"

# the runner recorded a crash and launchd will retry
mkdir -p "$BENCH/logs/.benchbar"
printf '{"schema_version":1,"state":"crashed","stop_reason":"crash","pid":null,"started_at":"2026-09-23T10:00:00Z","last_exit_code":3}\n' >"$state"
assert_eq "crashed crash 3 2026-09-23T10:00:00Z" "$(status_field 'd["state"], d["stop_reason"], d["last_exit_code"], d["started_at"]' | tr -d "(),'")"

# processes up but the site does not answer yet
set_agent com.benchbar.frappe-bench running 4242 0
add_proc 4242 "honcho start -f Procfile.lean"
assert_eq "starting 4242 None" "$(status_field 'd["state"], d["pid"], d["web_ping_code"]' | tr -d "(),'")"
export MOCK_CURL_CODE=200
assert_eq "running 4242 200 None" "$(status_field 'd["state"], d["pid"], d["web_ping_code"], d["stop_reason"]' | tr -d "(),'")"
assert_eq "True True running" "$(status_field 'd["agent_loaded"], d["processes_running"], d["agent_state"]' | tr -d "(),'")"
export MOCK_CURL_CODE=000

# ---- up, down and restart write state.json
: >"$MOCK_PROCS"; rm -f "$state"
printf 'manual\n' >"$BENCH/logs/.bench-stopped"
export MOCK_KICKSTART_PING=200
run_fm up --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
assert_eq "starting cli" "$(jget "$state" 'd["state"], d["source"]' | tr -d "(),'")"
[[ "$(jget "$state" 'd["started_at"]')" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]] || fail "started_at must be ISO 8601 UTC"
run_fm down --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
assert_eq "stopped manual" "$(jget "$state" 'd["state"], d["stop_reason"]' | tr -d "(),'")"
run_fm restart --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
assert_eq "starting" "$(jget "$state" 'd["state"]')"
unset MOCK_KICKSTART_PING
[[ -z "$(find "$BENCH/logs/.benchbar" -name '.state.json.*')" ]] || fail "no temp files may be left behind"
run_fm down --dry-run --bench-dir "$BENCH"
assert_eq "starting" "$(jget "$state" 'd["state"]')" "(dry-run must not write state.json)"

# ---- doctor
run_fm doctor --json --bench-dir "$BENCH"
printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["schema_version"] == 1 and d["cli_version"] == "0.3.0", d
assert d["name"] == "frappe-bench", d
for c in d["checks"]:
    assert set(["id", "level", "message", "fix_command"]) <= set(c), c
    assert c["level"] in ("ok", "warn", "fail"), c
    assert c["status"] == c["level"], "0.2.0 alias"
    assert c["fix_command"] is None or isinstance(c["fix_command"], str), c
    if c["level"] == "ok":
        assert c["fix_command"] is None, c
assert any(c["id"] == "agent" for c in d["checks"])
assert set(d["summary"]) == {"ok", "warn", "fail"}
' || fail "doctor --json content"

# ---- strings with quotes and backslashes stay valid JSON
QUOTED="$HOME/dev/we\"ird"
make_fake_bench "$QUOTED" odd
run_fm status --json --bench-dir "$QUOTED"
assert_eq "$QUOTED" "$(printf '%s' "$OUT" | jget - 'd["bench"]')"

# ---- the app's fixtures (macos/BenchBarTests/Fixtures) have exactly the keys the CLI prints
FIX="$ROOT/macos/BenchBarTests/Fixtures"
run_fm status --json --bench-dir "$BENCH"
printf '%s' "$OUT" | python3 -c '
import json, sys
live = json.load(sys.stdin)
fixture = json.load(open(sys.argv[1]))
assert set(live) == set(fixture), ("status keys drifted", set(live) ^ set(fixture))
assert set(live["ports"]) == set(fixture["ports"])
' "$FIX/status-running.json" || fail "status --json and the app fixture disagree"
run_fm list --json
printf '%s' "$OUT" | python3 -c '
import json, sys
live = json.load(sys.stdin); fixture = json.load(open(sys.argv[1]))
assert set(live) == set(fixture)
assert set(live["benches"][0]) == set(fixture["benches"][0]), set(live["benches"][0]) ^ set(fixture["benches"][0])
' "$FIX/list.json" || fail "list --json and the app fixture disagree"
run_fm doctor --json --bench-dir "$BENCH"
printf '%s' "$OUT" | python3 -c '
import json, sys
live = json.load(sys.stdin); fixture = json.load(open(sys.argv[1]))
assert set(live) == set(fixture), set(live) ^ set(fixture)
assert set(live["checks"][0]) == set(fixture["checks"][0])
' "$FIX/doctor.json" || fail "doctor --json and the app fixture disagree"

printf 'test-json: ok\n'
