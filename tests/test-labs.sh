#!/usr/bin/env bash
# Labs: the list, on and off in the state file, the refusal without a person,
# the gate (hidden from help and commands --json, exit 2 with the hint), the
# labs field of status, the BENCHBAR_LABS override, and the MCP filter.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH" v16dev
unset BENCHBAR_LABS
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT

# stdout alone, for JSON (run_fm folds stderr in)
fm_out() { set +e; OUT="$("$FM" "$@" 2>/dev/null)"; CODE=$?; set -e; }

# ---- list
fm_out labs list --json
assert_eq "0" "$CODE"
assert_eq "lan-rooms quick-switch" "$(printf '%s' "$OUT" | jget - '" ".join(l["name"] for l in d["labs"])')"
assert_eq "[False, False]" "$(printf '%s' "$OUT" | jget - '[l["enabled"] for l in d["labs"]]')"
assert_eq "['share', 'lan-guard'] []" "$(printf '%s' "$OUT" | jget - 'd["labs"][0]["commands"], d["labs"][1]["commands"]')"
assert_eq "1 0.9.0" "$(printf '%s' "$OUT" | jget - 'd["schema_version"], d["labs"][0]["since"]')"
fm_out labs --json
assert_eq "0" "$CODE"; assert_contains "$OUT" '"lan-rooms"'
run_fm labs
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "lan-rooms"; assert_contains "$OUT" "quick-switch"

# ---- on and off write the state
run_fm labs on quick-switch --yes
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "system wide keyboard shortcut"
assert_contains "$(cat "$FL_STATE_FILE")" "LABS=quick-switch"
run_fm labs status quick-switch
assert_eq "0" "$CODE" "$OUT"
run_fm labs status lan-rooms
assert_eq "1" "$CODE" "$OUT"
fm_out labs status lan-rooms --json
assert_eq "1" "$CODE"; assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["enabled"]')"
fm_out labs list --json
assert_eq "[False, True]" "$(printf '%s' "$OUT" | jget - '[l["enabled"] for l in d["labs"]]')"
run_fm labs on quick-switch --yes
assert_contains "$OUT" "unchanged"
run_fm labs on lan-rooms --yes
assert_eq "0" "$CODE" "$OUT"
fm_out labs list --json
assert_eq "[True, True]" "$(printf '%s' "$OUT" | jget - '[l["enabled"] for l in d["labs"]]')"
fm_out labs off quick-switch --json
assert_eq "0" "$CODE"
assert_eq "0 lab turned off" "$(printf '%s' "$OUT" | jget - 'd["exit"], d["changed"][0]["kind"], d["changed"][0]["detail"]')"
assert_eq "quick-switch False" "$(printf '%s' "$OUT" | jget - 'd["lab"], d["enabled"]')"
assert_contains "$(cat "$FL_STATE_FILE")" "LABS=lan-rooms"
assert_eq "LABS=lan-rooms" "$(grep '^LABS=' "$FL_STATE_FILE" | tail -n 1)"
run_fm labs off quick-switch
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "unchanged"

# ---- a lab that is on shows in status --json and commands --json
fm_out status --json --bench-dir "$BENCH"
assert_eq "['lan-rooms']" "$(printf '%s' "$OUT" | jget - 'd["labs"]')"
fm_out commands --json
assert_eq "['lan-rooms'] []" "$(printf '%s' "$OUT" | jget - 'd["labs"], d["gated"]')"
run_fm labs off lan-rooms
assert_eq "0" "$CODE" "$OUT"
fm_out status --json --bench-dir "$BENCH"
assert_eq "[]" "$(printf '%s' "$OUT" | jget - 'd["labs"]')"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "labs: none"
run_fm labs on lan-rooms --yes
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "labs: lan-rooms"
run_fm labs off lan-rooms

# ---- unknown names and bad usage
run_fm labs on nope --yes
assert_eq "1" "$CODE"; assert_contains "$OUT" "Unknown lab: nope"
run_fm labs status nope
assert_eq "1" "$CODE"
run_fm labs on --yes
assert_eq "1" "$CODE"; assert_contains "$OUT" "needs a lab name"
assert_not_contains "$(cat "$FL_STATE_FILE")" "nope"

# ---- turning on is a person's decision
BENCHBAR_NONINTERACTIVE=1 run_fm labs on lan-rooms --yes
assert_eq "2" "$CODE" "$OUT"; assert_contains "$OUT" "turning on an experiment is a person's decision"
run_fm labs on lan-rooms --for-agent
assert_eq "2" "$CODE" "$OUT"; assert_contains "$OUT" "turning on an experiment is a person's decision"
assert_not_contains "$OUT" "MARIADB_ROOT_PASSWORD"
assert_not_contains "$(cat "$FL_STATE_FILE")" "lan-rooms"
# off is allowed for an agent
run_fm labs on quick-switch --yes
run_fm labs off quick-switch --for-agent
assert_eq "0" "$CODE" "$OUT"
assert_not_contains "$(cat "$FL_STATE_FILE")" "LABS=quick-switch"

# ---- the gate: a command of a lab that is off exits 2 with the hint
for c in share lan-guard; do
  run_fm "$c" --bench-dir "$BENCH"
  assert_eq "2" "$CODE" "$OUT"
  assert_contains "$OUT" "benchbar $c is an experiment and it is off."
  assert_contains "$OUT" "Turn it on: benchbar labs on lan-rooms"
  run_fm "$c" --help
  assert_eq "2" "$CODE" "$OUT"; assert_contains "$OUT" "is an experiment and it is off."
done
# with --json the refusal is one JSON document on stdout, exit 2, no password hint
fm_out share --json --bench-dir "$BENCH"
assert_eq "2" "$CODE"
assert_eq "2 True" "$(printf '%s' "$OUT" | jget - 'd["exit"], "experiment" in d["error"]')"
assert_eq "0" "$(printf '%s' "$OUT" | jget - 'len([a for a in d.get("next_actions", []) if "MARIADB" in json.dumps(a)])')"
# on: the gate lets it through (this version has no such command)
BENCHBAR_LABS=lan-rooms run_fm share --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "Unknown command: share"
run_fm status --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"

# ---- BENCHBAR_LABS replaces the saved list
run_fm labs on quick-switch --yes
fm_out labs list --json
assert_eq "[False, True]" "$(printf '%s' "$OUT" | jget - '[l["enabled"] for l in d["labs"]]')"
BENCHBAR_LABS=lan-rooms fm_out labs list --json
assert_eq "[True, False]" "$(printf '%s' "$OUT" | jget - '[l["enabled"] for l in d["labs"]]')"
BENCHBAR_LABS="" fm_out labs list --json
assert_eq "[False, False]" "$(printf '%s' "$OUT" | jget - '[l["enabled"] for l in d["labs"]]')"
BENCHBAR_LABS=lan-rooms,quick-switch fm_out status --json --bench-dir "$BENCH"
assert_eq "['lan-rooms', 'quick-switch']" "$(printf '%s' "$OUT" | jget - 'd["labs"]')"
run_fm labs off quick-switch

# ---- commands --json and the help text with a gated command in the table
# (this version has no share command, so the table gets rows for the test)
cat >"$TMP_DIR/gate.sh" <<'SH'
. "$ROOT/lib/frappe-local/ui.sh"
. "$ROOT/lib/frappe-local/state.sh"
. "$ROOT/lib/frappe-local/labs.sh"
. "$ROOT/lib/frappe-local/commands.sh"
FL_CMD_TABLE="${FL_CMD_TABLE}"$'\n''cmd~share~benchbar share~Share a site.~no~no~no~yes~stream'$'\n''flag~share~--seat~NAME~A seat.'$'\n''cmd~share stop~benchbar share stop~Stop.~no~no~no~yes~stream'
fl_commands_json
printf '%s\n' "  site list    sites" "  share       Share a site." "                  --seat NAME: the seat" "  path        Print it." | fl_lab_usage_filter
SH
bash "$TMP_DIR/gate.sh" >"$TMP_DIR/gate.out"
head -n 1 "$TMP_DIR/gate.out" >"$TMP_DIR/gate.json"; USAGE_OFF="$(tail -n +2 "$TMP_DIR/gate.out")"
assert_eq "[] share lan-rooms" "$(jget "$TMP_DIR/gate.json" 'd["labs"], d["gated"][0]["name"], d["gated"][0]["lab"]' | tr -d "(),'")" "(gated)"
assert_eq "0 1" "$(jget "$TMP_DIR/gate.json" 'len([c for c in d["commands"] if c["name"].startswith("share")]), len(d["gated"])')" "(one gated entry for share and share stop)"
assert_not_contains "$USAGE_OFF" "share"
assert_not_contains "$USAGE_OFF" "--seat"
assert_contains "$USAGE_OFF" "path"
BENCHBAR_LABS=lan-rooms bash "$TMP_DIR/gate.sh" >"$TMP_DIR/gate.out"
head -n 1 "$TMP_DIR/gate.out" >"$TMP_DIR/gate.json"; USAGE_ON="$(tail -n +2 "$TMP_DIR/gate.out")"
assert_eq "lan-rooms|0|share lan-rooms" "$(jget "$TMP_DIR/gate.json" '"|".join([",".join(d["labs"]), str(len(d["gated"])), " ".join([c["name"] + " " + c["lab"] for c in d["commands"] if c["name"] == "share"])])')"
assert_contains "$USAGE_ON" "share"
assert_contains "$USAGE_ON" "--seat"
run_fm --help
assert_contains "$OUT" "labs on NAME"

# ---- the MCP server: a tool of a lab that is off is not listed and not callable
cat >"$TMP_DIR/mcp-lab.py" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "lib", "frappe-local"))
import mcp
names = lambda: [t["name"] for t in mcp.tool_list()["tools"]]
assert "benchbar_list" in names()
mcp.LAB_OF["benchbar_list"] = "lan-rooms"
listed = "benchbar_list" in names()
try:
    mcp.tool_call({"name": "benchbar_list", "arguments": {}})
    called = True
except mcp.RpcError as e:
    called = "unknown tool" not in str(e.args)
print(listed, called)
PY
OUT="$(BENCHBAR="$FM" BENCHBAR_LABS="" python3 -I "$TMP_DIR/mcp-lab.py" 2>&1)"
assert_eq "False False" "$OUT"
OUT="$(BENCHBAR="$FM" BENCHBAR_LABS="lan-rooms" python3 -I "$TMP_DIR/mcp-lab.py" 2>&1)"
assert_contains "$OUT" "True"
echo "test-labs: ok"

# ---- platforms: lan-rooms and quick-switch are macOS only for now
fm_out labs list --json
assert_eq "[['macos'], ['macos']] [True, True]" "$(printf '%s' "$OUT" | jget - '[l["platforms"] for l in d["labs"]], [l["available"] for l in d["labs"]]')"
use_linux
printf 'Linux version 6.8.0-generic (buildd@lcy02) #1 SMP\n' >"$FL_PROC_VERSION"
run_fm labs on quick-switch --yes
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "quick-switch is not available on linux yet"
fm_out labs on lan-rooms --yes --json
assert_eq "1" "$CODE"
fm_out labs list --json
assert_eq "[False, False]" "$(printf '%s' "$OUT" | jget - '[l["available"] for l in d["labs"]]')"
run_fm labs
assert_contains "$OUT" "(not on this platform)"
assert_not_contains "$(cat "$FL_STATE_FILE" 2>/dev/null)" "LABS=quick-switch"
# inside WSL the platform is windows
printf 'Linux version 6.6.0-microsoft-standard-WSL2 (root@build) (gcc) #1 SMP\n' >"$FL_PROC_VERSION"
run_fm labs on quick-switch --yes
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "quick-switch is not available on windows yet"
