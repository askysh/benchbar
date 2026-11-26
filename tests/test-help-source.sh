#!/usr/bin/env bash
# The global help is printed from the commands table (#371). What the table cannot give is data in
# lib/frappe-local/help-layout.txt, a file that only a help reads (it was a second here document in commands.sh, which
# every start sources: 2 to 4 ms per start):
#   sec~ID~TITLE            a section of the help, in print order
#   help~SECTION~KEY[~LABEL] a command of the section, in print order; LABEL only where the usage form cut before its first " [" is not the label
#   text~SECTION~LINE        a line that belongs to no command (a heading, a blank line, an option, the footer), as printed
# This test holds:
#   1. the layout file is there, its sections are in order and every record names a section that exists
#   2. every help key is a command of the table, once; every command of the table is in the help or on the
#      list tests/golden/not-in-global-help.txt, so that a new command cannot be forgotten
#   3. the Options lines of the text records name every global flag, and no flag that does not exist
#   4. no line of the global help is over 100 columns, with the experiments off and on
#   5. nothing reads the layout at a start that is not a help: commands.sh has no record of it, the table the readers
#      loop over has none, and the function that reads it is not loaded (--version, status and path stay as fast as before)
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

COMMANDS_SH="$ROOT/lib/frappe-local/commands.sh"

# ---- 1 to 3
python3 -I - "$ROOT" <<'PY' || fail "lib/frappe-local/help-layout.txt is not in order (see above)"
import re, sys
root = sys.argv[1]
src = open(root + "/lib/frappe-local/commands.sh", encoding="utf-8").read()
errors = []
tm = re.search(r": <<'TABLE'\n(.*?)\nTABLE\n", src, re.S)
try:
    layout = open(root + "/lib/frappe-local/help-layout.txt", encoding="utf-8").read()
except OSError:
    print("lib/frappe-local/help-layout.txt is missing (the layout of the global help)")
    sys.exit(1)
hm = ["\n".join(l for l in layout.split("\n") if not l.startswith("#")).strip("\n")]
for word in ("HELP\x27", "\nsec~", "\nhelp~", "\ntext~"):
    if word in src:
        errors.append("lib/frappe-local/commands.sh holds a record or a block of the global help layout (%r): it belongs in help-layout.txt, which no start reads" % word)
keys = []
gflag_text = re.search(r"<<'FLAGS'[^\n]*\n(.*?)\nFLAGS\n", src, re.S).group(1).split("\n")
gflags = []
for line in gflag_text:
    gflags += [w for w in line.split("~")[0].split(", ") if w]
table_flags = set()
for line in tm.group(1).split("\n"):
    f = line.split("~")
    if f[0] == "cmd":
        keys.append(f[1])
    elif f[0] == "flag":
        table_flags.add(f[2])
secs, helps, texts = [], [], []
cur = None
for line in hm[0].split("\n"):
    f = line.split("~", 3 if line.startswith("help~") else 2)
    kind = f[0]
    if kind == "sec":
        if len(f) != 3 or not f[1] or not f[2]:
            errors.append("sec record without an id and a title: %s" % line)
            continue
        if f[1] in secs:
            errors.append("section %s twice" % f[1])
        secs.append(f[1]); cur = f[1]
    elif kind in ("help", "text"):
        if len(f) < 3 and kind == "help":
            errors.append("help record without a key: %s" % line)
            continue
        sec = f[1]
        if sec != cur:
            errors.append("%s record of section %s is not under its sec record (the section before it is %s): %s" % (kind, sec, cur, line))
        (helps if kind == "help" else texts).append(f[1:] if kind == "help" else (f[1], f[2] if len(f) > 2 else ""))
    else:
        errors.append("unknown record in help-layout.txt: %s" % line)
seen = set()
for h in helps:
    key = h[1]
    if key not in keys:
        errors.append("help record of %s: not a command of the table" % key)
    if key in seen:
        errors.append("help record of %s twice" % key)
    seen.add(key)
    if len(h) > 2 and not h[2]:
        errors.append("help record of %s has an empty label" % key)
exempt = [l.strip() for l in open(root + "/tests/golden/not-in-global-help.txt", encoding="utf-8") if l.strip() and not l.startswith("#")]
for key in exempt:
    if key not in keys:
        errors.append("tests/golden/not-in-global-help.txt names %s, which is not a command of the table" % key)
    if key in seen:
        errors.append("%s is in the global help and on tests/golden/not-in-global-help.txt: take it off the list" % key)
for key in keys:
    if key not in seen and key not in exempt:
        errors.append("command %s is neither in the global help (help~SECTION~%s in help-layout.txt) nor on tests/golden/not-in-global-help.txt" % (key, key))
# the Options lines
opt = [t[1] for t in texts if t[0] == "options"]
named = set()
for line in opt:
    m = re.match(r"^  (-\S.*?)(?:  +\S|$)", line)
    if m:
        named.update(w.strip() for w in m.group(1).split(","))
for g in gflags:
    if g not in named and not any(g in n.split() for n in named):
        errors.append("the Options lines do not name the global flag %s (fl_cmd_global_flags)" % g)
known = set(gflags) | table_flags | {"--version", "-y", "--yes", "--scratch", "--ttl"}
for n in named:
    for w in n.split():
        w = w.rstrip(",")
        if w.startswith("-") and w not in known:
            errors.append("the Options lines name %s, which no command and no global flag has" % w)
for e in errors:
    print(e)
sys.exit(1 if errors else 0)
PY

# ---- 4. no line over 100 columns
for labs in "" "lan-rooms,quick-switch"; do
  OUT="$(BENCHBAR_LABS="$labs" FL_LABS_ANY_PLATFORM=1 "$FM" --help 2>&1)"
  wide="$(printf '%s\n' "$OUT" | awk 'length($0) > 100 { printf "%d: %s\n", length($0), substr($0, 1, 50) }')"
  [[ -z "$wide" ]] || fail "global help lines over 100 columns (labs: ${labs:-none}): $wide"
done

# ---- 5. a start that is not a help reads nothing of the block
[[ "$(grep -c -x TABLE "$COMMANDS_SH")" == 1 ]] || fail "lib/frappe-local/commands.sh has no or more than one line that is just TABLE (fl_cmd_load)"
# shellcheck disable=SC2016  # the single quotes are for the inner shell
loaded="$(bash -c '. "$0/lib/frappe-local/ui.sh"; . "$0/lib/frappe-local/commands.sh"; printf "%s\n" "$FL_CMD_TABLE" | grep -c -E "^(sec|help|text)~"; declare -F fl_usage_text | wc -l' "$ROOT" 2>&1 | tr '\n' ' ')"
assert_eq "0 0 " "$loaded" "(after a start, the table has no layout record and the function that reads the layout is not loaded)"
