#!/usr/bin/env bash
# Every MCP tool names the command it runs (TOOL_COMMAND in lib/frappe-local/mcp.py, #371). The
# names are the keys of the commands table, as `benchbar commands --json` lists them ("name"), so
# one source (the table) says what a command is, and a tool that points at a command that is gone,
# or a command renamed under a tool, fails here. Three checks:
#   1. every tool has an entry, and no entry is left for a tool that is gone
#   2. every entry is "" (a tool that runs no command) or a key of the table, with the labs on
#   3. the argv a tool builds starts with the words of its entry (the tool is asked to build one
#      with sample arguments, so the map is checked against what the tool runs, not against a name)
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# the commands of a lab that is off are not listed: ask with every lab on
BENCHBAR_LABS=lan-rooms,quick-switch run_fm commands --json
assert_eq "0" "$CODE" "$OUT"
printf '%s' "$OUT" >"$TMP_DIR/commands.json"

python3 -I - "$ROOT" "$TMP_DIR/commands.json" <<'PY' || fail "the MCP tools and the commands table disagree (lib/frappe-local/mcp.py TOOL_COMMAND), see above"
import importlib.util, json, sys
root, table_file = sys.argv[1], sys.argv[2]
names = {c["name"] for c in json.load(open(table_file))["commands"]}
spec = importlib.util.spec_from_file_location("benchbar_mcp", root + "/lib/frappe-local/mcp.py")
mcp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mcp)
errors = []
tool_command = getattr(mcp, "TOOL_COMMAND", None)
if not isinstance(tool_command, dict):
    print("mcp.py has no TOOL_COMMAND (tool name -> key of the commands table, or \"\")")
    sys.exit(1)

# 1. one entry per tool
for t in sorted(set(mcp.TOOLS) - set(tool_command)):
    errors.append("%s has no entry in TOOL_COMMAND" % t)
for t in sorted(set(tool_command) - set(mcp.TOOLS)):
    errors.append("TOOL_COMMAND has an entry for %s, which is not a tool" % t)

# 2. every entry is a command of the table
for t, key in sorted(tool_command.items()):
    if key != "" and key not in names:
        errors.append("%s runs %r, which is not a command of the table" % (t, key))

# 3. the argv of the tool starts with the words of its command. Sample arguments by property name,
#    else by type; a tool that needs more says so here (a failure names the tool: add its argument)
SAMPLE = {"token": "0" * 64, "site": "a.localhost", "name": "x", "paths": ["/x"], "path": "/x", "as": "b.localhost",
          "mode": "on", "check": "frappe_version", "lease": "l-0123456789ab", "url_or_name": "erpnext", "to": "snap",
          "to_bench": "/x", "from": "x", "from_bench": "/x", "label": "l", "snapshot": "s",
          "op_id": "op-20261119-101500-4242"}
OVERRIDE = {"benchbar_app_add_plan": {"url_or_name": "erpnext"}, "benchbar_app_add": {"url_or_name": "erpnext", "token": "0" * 64},
            # source and from_dir exclude each other
            "benchbar_pull_plan": {"source": "h:s", "as": "b.localhost"},
            "benchbar_pull": {"source": "h:s", "as": "b.localhost", "token": "0" * 64}}

def sample(key, schema):
    if key in SAMPLE:
        return SAMPLE[key]
    if "enum" in schema:
        return schema["enum"][0]
    return {"integer": 1, "boolean": False, "array": ["x"]}.get(schema.get("type"), "x")

def leading_key(argv):
    for n in (3, 2, 1):
        key = " ".join(argv[:n])
        if len(argv) >= n and key in names:
            return key
    return None

for t, tool in sorted(mcp.TOOLS.items()):
    key = tool_command.get(t)
    props = tool.props if isinstance(tool.props, dict) else {}
    if key == "":
        # a tool that runs no command builds no argv (nothing maps to "" today: this keeps it so)
        try:
            argv = tool.build({k: sample(k, v) for k, v in props.items()})
        except Exception:
            argv = None
        if argv:
            errors.append("%s is mapped to \"\" (it runs no command) but builds the argv %s" % (t, argv[:4]))
        continue
    if not key:
        continue
    args = OVERRIDE.get(t) or {k: sample(k, v) for k, v in props.items()}
    try:
        argv = tool.build(args)
    except Exception as e:
        errors.append("%s: could not build an argv with sample arguments (%s: %s); add them to SAMPLE or OVERRIDE" % (t, type(e).__name__, e))
        continue
    got = leading_key(argv)
    if got != key:
        errors.append("%s is mapped to %r and runs %r (argv starts %s)" % (t, key, got, argv[:4]))

for e in errors:
    print(e)
sys.exit(1 if errors else 0)
PY
