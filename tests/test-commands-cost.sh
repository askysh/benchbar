#!/usr/bin/env bash
# What `benchbar commands --json` costs, and that it stays the same document.
# The Mac app, the tray, mcp.py and scripts/docs-reference.py read it, and the
# agents' first call is often this one. Two things are held here:
#   1. the budget: how many programs and how many subshells (forks) one run
#      starts. A wall time is not asserted (machines differ); the count is.
#   2. the document: byte for byte what an independent writer (Python, below)
#      makes from the table in commands.sh and the labs in labs.sh, with the
#      Labs off, one on and both on. A faster writer in bash must give the
#      same bytes.
# Lower a budget when a change makes the command cheaper; never raise one.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# the budgets (see the header). Programs: every program benchbar started,
# counted by the shims below (the interpreter itself is not one). Forks:
# the subshells of $(...) and of pipes inside benchbar, counted from the
# xtrace with the process id in PS4 (bash 4 and later, where BASHPID is set).
MAX_PROGRAMS=0
MAX_FORKS=3

# the shims: log "exec NAME" and run the real program, as in test-command-cost
SHIMS="$TMP_DIR/shims"
mkdir -p "$SHIMS"
for n in sed awk tr head tail cut sort uniq grep cat cksum basename dirname id uname shasum date readlink wc mktemp mv rm cp ls stat touch mkdir find xargs sleep python3 perl ruby ps sysctl df getconf hostname sw_vers; do
  real="$(command -v "$n" 2>/dev/null)" || continue
  case "$real" in "$ROOT"/tests/mocks/*) continue ;; esac
  cat >"$SHIMS/$n" <<SHIM
#!/bin/bash
if [[ -z "\${BENCHBAR_TEST_MOCK:-}" ]]; then printf 'exec %s\n' "$n" >>"\$MOCK_LOG"; fi
exec "$real" "\$@"
SHIM
  chmod +x "$SHIMS/$n"
done
execs() { grep -v -c -E '^mockkill ' "$MOCK_LOG" || true; }
summary() { awk '{ print ($1 == "exec") ? $2 : $1 }' "$MOCK_LOG" | sort | uniq -c | sort -rn | awk '{ printf "%s%s %s", (NR > 1 ? ", " : ""), $2, $1 }'; }

# the writer that does not share a line with the one in commands.sh: reads the
# tables and writes the document the way docs/json-schema.md says (a string
# that is empty is null, a yes is true, the commands of a lab that is off are
# left out and named in "gated")
cat >"$TMP_DIR/commands-ref.py" <<'PY'
import json, re, sys

root, on_list, schema, version = sys.argv[1], sys.argv[2].split(","), sys.argv[3], sys.argv[4]
cmds_src = open(root + "/lib/frappe-local/commands.sh", encoding="utf-8").read()
labs_src = open(root + "/lib/frappe-local/labs.sh", encoding="utf-8").read()
table = re.search(r"read -r -d '' FL_CMD_TABLE <<'TABLE' \|\| true\n(.*?)\nTABLE\n", cmds_src, re.S).group(1)
gflags = re.search(r"<<'FLAGS'\n(.*?)\nFLAGS\n", cmds_src, re.S).group(1)
labs = [l.split("~") for l in re.search(r"read -r -d '' FL_LAB_TABLE <<'TABLE' \|\| true\n(.*?)\nTABLE\n", labs_src, re.S).group(1).split("\n") if l.startswith("lab~")]

def s(v):
    return None if v == "" else v

def b(v):
    return v in ("1", "yes", "true")

def row(line, n):
    f = line.split("~", n - 1)
    return f + [""] * (n - len(f))

lab_of = {}
for l in labs:
    for c in l[6].split(","):
        if c:
            lab_of.setdefault(c, l[1])
enabled = [l[1] for l in labs if l[1] in on_list]

commands, gated, cur, skip = [], [], None, False
for line in table.split("\n"):
    kind = line.split("~", 1)[0]
    if kind == "cmd":
        f = line.split("~")
        f += [""] * (9 - len(f))
        word = f[1].split(" ")[0]
        lab = lab_of.get(word)
        skip = lab is not None and lab not in enabled
        if skip:
            if not any(g["name"] == word for g in gated):
                gated.append({"name": word, "lab": lab})
            continue
        cur = {"name": f[1], "usage": s(f[2]), "summary": s(f[3]), "tty": b(f[4]), "sudo": b(f[5]), "network": b(f[6]), "mutating": b(f[7]), "json": s(f[8])}
        if lab is not None:
            cur["lab"] = lab
        cur["flags"] = []
        cur["env"] = []
        commands.append(cur)
    elif kind == "flag" and not skip:
        f = row(line, 5)
        cur["flags"].append({"name": s(f[2]), "value": s(f[3]), "help": s(f[4])})
    elif kind == "env" and not skip:
        f = row(line, 4)
        cur["env"].append({"name": s(f[2]), "help": s(f[3])})

g = []
for line in gflags.split("\n"):
    f = row(line, 3)
    g.append({"name": s(f[0]), "value": s(f[1]), "help": s(f[2])})

doc = {"schema_version": int(schema), "cli_version": version, "labs": enabled, "gated": gated, "global_flags": g, "commands": commands}
sys.stdout.write(json.dumps(doc, ensure_ascii=False, separators=(",", ":")) + "\n")
PY

SCHEMA="$(sed -n 's/^FL_SCHEMA_VERSION=\([0-9]*\).*$/\1/p' "$ROOT"/lib/frappe-local/*.sh "$FM" | head -n 1)"
[[ -n "$SCHEMA" ]] || fail "FL_SCHEMA_VERSION not found"

# document LABS: the document of `commands --json` with BENCHBAR_LABS=LABS
# (FL_LABS_ANY_PLATFORM: both labs can be on, whatever this machine is), and
# the one the writer above makes, compared byte for byte
document() {
  local labs="$1" got want
  got="$(BENCHBAR_LABS="$labs" FL_LABS_ANY_PLATFORM=1 "$FM" commands --json 2>"$TMP_DIR/stderr"; printf x)"
  [[ ! -s "$TMP_DIR/stderr" ]] || fail "commands --json wrote to stderr (labs: ${labs:-none}): $(cat "$TMP_DIR/stderr")"
  want="$(python3 -I "$TMP_DIR/commands-ref.py" "$ROOT" "$labs" "$SCHEMA" "$VER"; printf x)"
  if [[ "$got" != "$want" ]]; then
    printf '%s' "${got%x}" >"$TMP_DIR/got.json"; printf '%s' "${want%x}" >"$TMP_DIR/want.json"
    fail "commands --json differs from the table (labs: ${labs:-none}); first difference: $(cmp "$TMP_DIR/got.json" "$TMP_DIR/want.json" 2>&1 | head -n 1)"
  fi
  # one line, valid JSON
  [[ "$(printf '%s' "${got%x}" | wc -l | tr -d ' ')" == "1" ]] || fail "commands --json is not one line"
  printf '%s' "${got%x}" | python3 -I -c 'import json, sys; json.load(sys.stdin)' || fail "commands --json is not JSON"
}
document ""
document "lan-rooms"
document "lan-rooms,quick-switch"
document "quick-switch,lan-rooms"

# the labs filter really ran: with both off the gated commands are named
off="$(BENCHBAR_LABS="" "$FM" commands --json)"
assert_contains "$off" '"gated":[{"name":"share","lab":"lan-rooms"}'
assert_not_contains "${off#*\"commands\":}" '{"name":"share","usage"'

# ---- the budget: programs
for labs in "" "lan-rooms,quick-switch"; do
  reset_calls
  PATH="$SHIMS:$PATH" BENCHBAR_LABS="$labs" FL_LABS_ANY_PLATFORM=1 "$FM" commands --json >/dev/null 2>&1 </dev/null
  n="$(execs)"
  printf 'commands --json (labs: %s): %s programs (%s)\n' "${labs:-none}" "$n" "$(summary)"
  [[ "$n" -le "$MAX_PROGRAMS" ]] || fail "commands --json started $n programs, budget $MAX_PROGRAMS (labs: ${labs:-none})"$'\n'"$(summary)"
done

# ---- the budget: forks (every process that ran a traced command, the shell
# itself excluded). Bash 3.2 has no BASHPID: the programs above are its budget.
if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then
  for labs in "" "lan-rooms,quick-switch"; do
    PS4='+${BASHPID}:' BENCHBAR_LABS="$labs" FL_LABS_ANY_PLATFORM=1 "$BASH" -x "$FM" commands --json >/dev/null 2>"$TMP_DIR/xtrace" </dev/null
    n="$(grep -a -o -E '^\++[0-9]+:' "$TMP_DIR/xtrace" | tr -d '+:' | sort -u | wc -l | tr -d ' ')"
    n=$((n - 1))
    printf 'commands --json (labs: %s): %s forks\n' "${labs:-none}" "$n"
    [[ "$n" -le "$MAX_FORKS" ]] || fail "commands --json forked $n times, budget $MAX_FORKS (labs: ${labs:-none})"
  done
fi

printf 'test-commands-cost: ok\n'
