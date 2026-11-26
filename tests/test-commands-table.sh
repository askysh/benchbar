#!/usr/bin/env bash
# The commands table (lib/frappe-local/commands.sh), what its readers rely on (#371):
#   1. a table that cannot be read stops the run with a sentence: commands.sh sourced from a pipe
#      has no file to read the records from, and used to give no record and no error
#   2. a note record (note~KEY~TEXT) stands directly after the cmd record of its key, and a summary
#      (the short part: what `benchbar commands` and the global help print) is at most 200 characters,
#      except the commands in tests/golden/long-summaries.txt (the groups of #371 not done yet)
#   3. the notes about flags that left a summary are still somewhere: tests/golden/dropped-flag-notes.tsv
#      lists each (command, flag, the words of the old note), and the flag has a record of its own
#      (or is a global flag) whose help carries the key words of the note
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# ---- 1. a table that cannot be read
set +e
# (a pipe and /dev/stdin, not a process substitution: bash 3.2 does not source those at all)
# shellcheck disable=SC2016  # the single quotes are for the inner shell
OUT="$(bash -c '. "$0/lib/frappe-local/ui.sh"; cat "$0/lib/frappe-local/commands.sh" | { . /dev/stdin; printf "table:%s\n" "${#FL_CMD_TABLE}"; }' "$ROOT" 2>&1)"
CODE=$?
set -e
[[ "$CODE" != "0" ]] || fail "commands.sh sourced from a pipe went on with no table: $OUT"
assert_contains "$OUT" "commands table could not be read" "(the sentence)"
assert_contains "$OUT" "/dev/stdin" "(says from where it tried)"
assert_not_contains "$OUT" "table:0" "(did not go on)"

# ---- 2 and 3
python3 -I - "$ROOT" <<'PY' || fail "the commands table or its dropped flag notes are not in order (see above)"
import json, re, sys
root = sys.argv[1]
src = open(root + "/lib/frappe-local/commands.sh", encoding="utf-8").read()
table = re.search(r": <<'TABLE'\n(.*?)\nTABLE\n", src, re.S).group(1).split("\n")
errors = []
waiting = {l.strip() for l in open(root + "/tests/golden/long-summaries.txt", encoding="utf-8") if l.strip() and not l.startswith("#")}
cmds, flags, last_cmd = {}, {}, None
for n, line in enumerate(table, 1):
    f = line.split("~")
    if f[0] == "cmd":
        last_cmd = f[1]
        cmds[f[1]] = f
        if len(f[3]) > 200 and f[1] not in waiting:
            errors.append("cmd %s: the summary is %d characters; keep it to 200 and put the rest in a note~%s~ record" % (f[1], len(f[3]), f[1]))
        if len(f[3]) <= 200 and f[1] in waiting:
            errors.append("cmd %s is in tests/golden/long-summaries.txt but its summary is short now: take it out of the list" % f[1])
    elif f[0] == "note":
        if f[1] != last_cmd:
            errors.append("note~%s~ is not directly after the cmd record of %s" % (f[1], f[1]))
        if len(f) != 3 or not f[2]:
            errors.append("note~%s~ is empty or holds a ~ (it has three fields: note, the key, the text)" % f[1])
    elif f[0] == "flag":
        flags.setdefault(f[1], {})[f[2]] = "~".join(f[4:])
        if f[1] != last_cmd:
            errors.append("flag %s %s is not under the cmd record of %s" % (f[1], f[2], f[1]))
gflags = {}
for line in re.search(r"<<'FLAGS'[^\n]*\n(.*?)\nFLAGS\n", src, re.S).group(1).split("\n"):
    for name in line.split("~")[0].split(", "):
        gflags[name] = line
# the notes that left a summary
rows = [l.rstrip("\n").split("\t") for l in open(root + "/tests/golden/dropped-flag-notes.tsv", encoding="utf-8") if l.strip() and not l.startswith("#")]
for key, flag, words in rows:
    if key not in cmds:
        errors.append("dropped note: %s is not a command" % key)
        continue
    have = flags.get(key, {}).get(flag)
    if have is None and flag not in gflags:
        errors.append("dropped note of %s %s: no flag record and no global flag of that name" % (key, flag))
        continue
    text = (have if have is not None else gflags[flag]).lower()
    for w in words.lower().split("|"):
        if w.strip() and w.strip() not in text:
            errors.append("dropped note of %s %s: the flag record does not say %r" % (key, flag, w.strip()))
for e in errors:
    print(e)
sys.exit(1 if errors else 0)
PY
printf 'test-commands-table: ok\n'
