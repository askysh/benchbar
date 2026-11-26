#!/usr/bin/env bash
# The commands table (lib/frappe-local/commands.sh), what its readers rely on (#371):
#   1. a table that cannot be read stops the run with a sentence: commands.sh sourced from a pipe
#      has no file to read the records from, and used to give no record and no error
#   2. a note record (note~KEY~TEXT) stands directly after the cmd record of its key, and a summary
#      (the short part: what `benchbar commands` and the global help print) is at most 200 characters,
#      except the commands in tests/golden/long-summaries.txt (the groups of #371 not done yet)
#   3. the notes about flags that left a summary are still somewhere: tests/golden/dropped-flag-notes.tsv
#      lists each (command, flag, the words of the old note, and the flag whose record says it when that is
#      another one), and the record carries those words
#   4. no flag mention is lost: tests/golden/old-help-flags.tsv holds every flag that the old global help named
#      for a command of a group that has been done; each is in the summary or the note of the command, or has a
#      row in the list of 3. (The check is tried on a copy of the list without one row: it has to miss it.)
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# ---- 1. a table that cannot be read
# bash 3.2 does not source a pipe at all (it runs nothing of the file: no table, and no run that goes on with
# an empty one), so there is nothing to check there
if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then
  set +e
  # shellcheck disable=SC2016  # the single quotes are for the inner shell
  OUT="$(bash -c '. "$0/lib/frappe-local/ui.sh"; cat "$0/lib/frappe-local/commands.sh" | { . /dev/stdin; printf "table:%s\n" "${#FL_CMD_TABLE}"; }' "$ROOT" 2>&1)"
  CODE=$?
  set -e
  [[ "$CODE" != "0" ]] || fail "commands.sh sourced from a pipe went on with no table: $OUT"
  assert_contains "$OUT" "commands table could not be read" "(the sentence)"
  assert_contains "$OUT" "/dev/stdin" "(says from where it tried)"
  assert_not_contains "$OUT" "table:0" "(did not go on)"
fi

# ---- 2, 3 and 4
python3 -I - "$ROOT" <<'PY' || fail "the commands table or its dropped flag notes are not in order (see above)"
import re, sys
root = sys.argv[1]
src = open(root + "/lib/frappe-local/commands.sh", encoding="utf-8").read()
table = re.search(r": <<'TABLE'\n(.*?)\nTABLE\n", src, re.S).group(1).split("\n")
waiting = {l.strip() for l in open(root + "/tests/golden/long-summaries.txt", encoding="utf-8") if l.strip() and not l.startswith("#")}


def tsv(path):
    return [l.rstrip("\n").split("\t") for l in open(root + "/tests/golden/" + path, encoding="utf-8") if l.strip() and not l.startswith("#")]


dropped = tsv("dropped-flag-notes.tsv")
old_mentions = tsv("old-help-flags.tsv")
cmds, flags, notes, last_cmd = {}, {}, {}, None
errors = []
for line in table:
    f = line.split("~")
    if f[0] == "cmd":
        last_cmd = f[1]
        cmds[f[1]] = f
        if len(f[3]) > 200 and f[1] not in waiting:
            errors.append("cmd %s: the summary is %d characters; keep it to 200 and put the rest in a note~%s~ record" % (f[1], len(f[3]), f[1]))
        if len(f[3]) <= 200 and f[1] in waiting:
            errors.append("cmd %s is in tests/golden/long-summaries.txt but its summary is short now: take it out of the list" % f[1])
    elif f[0] == "note":
        notes[f[1]] = f[2] if len(f) > 2 else ""
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


def flag_text(key, flag):
    have = flags.get(key, {}).get(flag)
    return have if have is not None else gflags.get(flag)


def check(rows):
    """The notes about flags that left a summary: each row names a flag, the words its record must say and, when a
    note about the flag stands in the record of another flag, that carrier (4th column). Then: every flag that the
    old global help named for a command (old-help-flags.tsv) is in the summary or the note of the command today, or
    has a row."""
    errs = []
    have_row = set()
    for r in rows:
        key, flag, words = r[0], r[1], r[2]
        carrier = r[3] if len(r) > 3 and r[3] else flag
        ckey = key
        if "/" in carrier:
            ckey, carrier = carrier.split("/", 1)
        have_row.add((key, flag))
        if key not in cmds:
            errs.append("dropped note: %s is not a command" % key)
            continue
        text = flag_text(ckey, carrier)
        if text is None:
            errs.append("dropped note of %s %s: no flag record and no global flag %s" % (key, flag, carrier))
            continue
        for w in words.lower().split("|"):
            if w.strip() and w.strip() not in text.lower():
                errs.append("dropped note of %s %s: the record of %s does not say %r" % (key, flag, carrier, w.strip()))
    for key, flag, clause in old_mentions:
        said = (cmds[key][3] if key in cmds else "") + " " + notes.get(key, "")
        if re.search(r"(?<![\w-])" + re.escape(flag) + r"(?![\w-])", said):
            continue
        if (key, flag) not in have_row:
            errs.append("the old help named %s for %s (\"%s\"), and neither its summary, its note nor a row of dropped-flag-notes.tsv carries it" % (flag, key, clause))
    return errs


errors += check(dropped)
# the check has teeth: take a row out of the list, and it must be missed
needed = [r for r in dropped if any(m[0] == r[0] and m[1] == r[1] for m in old_mentions)
          and not re.search(r"(?<![\w-])" + re.escape(r[1]) + r"(?![\w-])", (cmds[r[0]][3] if r[0] in cmds else "") + " " + notes.get(r[0], ""))]
if not needed:
    errors.append("no row of dropped-flag-notes.tsv is needed by old-help-flags.tsv: the list is empty or the check is not run")
else:
    victim = needed[0]
    if not any("neither its summary" in e and victim[0] in e and victim[1] in e for e in check([r for r in dropped if r is not victim])):
        errors.append("the check of old-help-flags.tsv did not miss a row taken out (%s %s)" % (victim[0], victim[1]))
for e in errors:
    print(e)
sys.exit(1 if errors else 0)
PY
printf 'test-commands-table: ok\n'
