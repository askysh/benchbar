#!/bin/bash
# PreToolUse hook for Bash: blocks recursive deletes whose target is outside
# this repository, the benchbar log folders and the temp folder. Permission
# rules match prefixes and cannot say "outside", so the check lives here.
# Exit 2 blocks the call and shows the reason to Claude. Runs on macOS
# /bin/bash 3.2 and in Git Bash too.
#
# This is a guard against mistakes, not a security boundary. It reads the
# command text and follows the plain ways to delete (rm -r, unlink, shred,
# rimraf, find -delete, rsync --delete, git clean, git reset --hard, and a
# python, node, perl or ruby one liner that deletes). Anything it cannot
# follow it blocks. A person who wants to get around it can: a script file
# that deletes is not read. It stops a tired agent, not an attacker.
#
# Known limits, left open on purpose because closing them needs a shell
# parser: a name built in a variable (R=rm; $R -rf x), a glob for the name
# (/bin/r?), a hidden file name (.g*) passed to find or rm, a delete word
# put together in an interpreter (python 'r'+'m'), and a script or a makefile
# that deletes. Closed cheaply: \rm, a command substitution or backtick as a
# target, .git in any letter case, text with a delete piped to sh or bash,
# and node's rmSync.
#
# What it checks:
#   rm        a recursive rm (-r, -R, --recursive); force alone is not enough
#             to look, since rm -f names files only
#   unlink, shred, rimraf   every operand
#   find      the start paths of a find with -delete; -exec rm is blocked
#   rsync     the destination of a call with --delete
#   git       the folder a "git clean" or "git reset --hard" works in
#   code      python, node, perl, ruby, php, deno, bun, powershell and cmd
#             calls that mention a delete (rmtree, os.remove, fs.rm, ...)
# Every target must be inside the repo, the benchbar log folders
# (~/.benchbar/logs, ~/.local/state/benchbar/logs) or the temp folder, never a
# whole one of those roots (find and git may work in the repo root), and never
# the repo's .git. The backups next to the logs are not a target.
input="$(cat)"
# Only a delete word counts here, so "platform" or "guard-rm.sh" does not
# need python3. Anything after it but a name character counts, so rm'' and
# a tab (\t in the JSON) still reach the parser. The list is the same as
# TRIG in the python below; tests/test-guards.sh has a case for each entry.
# Git Bash runs rm.exe too, and Windows finds RM as rm, so case and a .exe
# suffix do not matter.
trigger='(^|[^A-Za-z0-9_.-])(rm|unlink|shred|rimraf|rsync)(\.exe)?([^A-Za-z0-9_.-]|$)|rmtree|os\.(remove|unlink|removedirs)|\.unlink\(|fs\.(rm|unlink)|remove-item|(rmdir|rd)[[:space:]]+/s|FileUtils\.rm|File\.delete|rmSync|rmdirSync|unlinkSync|\.(rm|rmdir)\(|git[^;&|]*[[:space:]](clean|reset)([^A-Za-z0-9_.-]|$)|[[:space:]]-delete([^A-Za-z0-9_.-]|$)'
# In the JSON a backslash of the command is two (\rm is \\rm), so those pairs
# go first; only then is \t, \n or \r a whitespace escape and counts as a
# space. Quotes and backslashes join word fragments in the shell (r''m, r\m),
# so they are dropped. A \u escape can spell anything, so it goes to the parser.
flat="$(printf '%s' "$input" | sed -e 's/\\\\//g' -e 's/\\[tnr]/ /g' | tr -d "'\"\\\\")"
if [[ $input != *'\u'* ]]; then
  shopt -s nocasematch
  [[ $flat =~ $trigger ]] || exit 0
  shopt -u nocasematch
fi
# The parsing needs python3. Without it (Git Bash, a Mac without the command
# line tools) a call that mentions a delete is blocked rather than let through.
# Running it, not just finding it, catches the Windows Store stub, which is
# on PATH but exits 9009; any exit but 0 or 2 would let the call through.
if ! python3 -c '' >/dev/null 2>&1; then
  echo "Blocked: the delete guard needs python3 to check this command; install python3 or run it yourself." >&2
  exit 2
fi
repo="${CLAUDE_PROJECT_DIR:-$PWD}"
# shellcheck disable=SC2016  # the python program is one single quoted string
printf '%s' "$input" | python3 -c '
import json, os, re, shlex, sys
repo, home = (os.path.realpath(p) for p in sys.argv[1:3])
try:
    data = json.load(sys.stdin)
except ValueError:
    print("Blocked: the delete guard could not read the tool call.", file=sys.stderr)
    sys.exit(2)
text = data.get("tool_input", {}).get("command", "") or ""
DEL_CMDS = ("rm", "unlink", "shred", "rimraf")
# Keep in step with "trigger" in the bash above.
TRIG = re.compile(r"(^|[^\w.-])(rm|unlink|shred|rimraf|rsync)(\.exe)?([^\w.-]|$)|rmtree|os\.(remove|unlink|removedirs)"
                  r"|\.unlink\(|fs\.(rm|unlink)|remove-item|(rmdir|rd)\s+/s|FileUtils\.rm|File\.delete"
                  r"|rmSync|rmdirSync|unlinkSync|\.(rm|rmdir)\("
                  r"|git[^;&|]*\s(clean|reset)([^\w.-]|$)|\s-delete([^\w.-]|$)", re.I)
# What an interpreter call may not hold from its own start to the end of the command.
code_del = re.compile(r"rmtree|os\.(remove|unlink|removedirs)|\bunlink\b|fs\.(rm|unlink)|rimraf|remove-item"
                      r"|(rmdir|rd)\s+/s|FileUtils\.rm|File\.delete|rmSync|rmdirSync|unlinkSync|\.(rm|rmdir)\(", re.I)
interpreter = re.compile(r"^(python[0-9.]*|py|node|nodejs|perl|ruby|php|deno|bun|pwsh|powershell|cmd)$")
# quotes and backslashes join word fragments (r\x27\x27m is rm)
flat = re.sub(r"[\"\x27\\]", "", text)
if not TRIG.search(flat):
    sys.exit(0)
def base(word):
    # a command name as Windows and Git Bash find it: rm, RM and rm.exe alike
    b = os.path.basename(word).lower()
    return b[:-4] if b.endswith(".exe") else b
# Relative targets resolve against every directory the shell could be in:
# the tool call cwd, then each cd or pushd earlier in the same command. A cd
# replaces the old directory only when it is sure to have run and succeeded
# (it starts a list or follows &&, and && follows it); otherwise both stay
# possible. None stands for a directory the guard cannot know.
cwds = [data.get("cwd") or os.getcwd()]
# Only the logs of the state folders: the backups beside them are what a repair
# can be undone from.
allowed = [repo, os.path.join(home, ".benchbar/logs"), os.path.join(home, ".local/state/benchbar/logs"),
           os.environ.get("TMPDIR", "/tmp")]
if os.environ.get("XDG_STATE_HOME"):
    allowed.append(os.path.join(os.environ["XDG_STATE_HOME"], "benchbar/logs"))
allowed = [os.path.realpath(a) for a in allowed]
# The repo history is not a target, though the repo is.
protected = os.path.join(repo, ".git")
assigned = {}
assignments = {}
def known(name):
    # A name the command also sets some other way (declare, read, for,
    # printf -v, eval) cannot be followed: every mention of it must be a
    # literal assignment the guard saw or a $NAME use.
    mentions = len(re.findall(r"\b%s\b" % re.escape(name), text))
    uses = len(re.findall(r"\$\{?%s\b" % re.escape(name), text))
    return mentions == uses + assignments.get(name, 0)
def expand(word):
    def lookup(m):
        name = m.group(1) or m.group(2)
        if not known(name):
            return m.group(0)
        value = assigned[name] if name in assigned else os.environ.get(name)
        # A glob in a value expands to names the guard cannot see.
        if value is None or re.search(r"[*?\[]", value):
            return m.group(0)
        return value
    out = re.sub(r"\$\{(\w+)\}|\$(\w+)", lookup, word)
    # A changed IFS splits on other characters. A glob may only be in the
    # last component: one before a slash could pass through a symlink, while
    # rm -rf on a symlink itself removes only the link.
    glob = re.search(r"[*?\[]", out)
    if "$" in out or "`" in out or re.search(r"\s", out) or re.search(r"\bIFS\b", text) or \
            (glob and "/" in out[glob.start():]):
        return None
    return os.path.expanduser(out)
def in_scratchpad(path):
    # The resolved path only: a symlink inside the scratchpad may lead out.
    if not os.path.isabs(path):
        return False
    return re.match(r"^(/private)?/tmp/claude-[A-Za-z0-9._-]+/.", os.path.realpath(path)) is not None
def block(msg):
    print("Blocked: " + msg, file=sys.stderr)
    sys.exit(2)
def candidates(target, what, dirs=None):
    # The real paths a target can mean, or None for a variable that resolves
    # into a session scratchpad (fine). A target the guard cannot resolve
    # blocks the call.
    # bash expands {a,b} and {1..3} before the command runs; the literal text
    # the guard resolves is not what gets deleted.
    if re.search(r"\{[^}]*(,|\.\.)[^}]*\}", target):
        block("%s with a brace expansion (%s); list the paths one by one." % (what, target))
    if "$" in target or "`" in target:
        # A variable target is let through only when it resolves, from
        # the environment or a literal assignment earlier in the
        # command, to a path inside a /tmp/claude-* session scratchpad.
        path = expand(target)
        if path is None or not in_scratchpad(path):
            block("%s with a variable target (%s); spell the path out." % (what, target))
        return None
    target = os.path.expanduser(target)
    if os.path.isabs(target):
        found = [target]
    elif None in (dirs or cwds):
        block("%s of a relative path after a cd the guard cannot follow (%s); use an absolute path." % (what, target))
    else:
        found = [os.path.join(c, target) for c in (dirs or cwds)]
    return [os.path.realpath(c) for c in found]
def check(target, what, whole_ok=False, dirs=None):
    for path in candidates(target, what, dirs) or []:
        # any letter case: a Mac volume treats .GIT as .git
        if path.lower() == protected.lower() or path.lower().startswith(protected.lower() + "/"):
            block("%s of the repo history (%s); use git commands." % (what, path))
        if not any(path == a or path.startswith(a.rstrip("/") + "/") for a in allowed):
            block("%s outside the repo, the benchbar log folders and the temp folder: %s" % (what, path))
        if path in allowed and not whole_ok:
            block("%s of a whole allowed root: %s" % (what, path))
def operands_of(words):
    # words after the command: options end at "--", every word after it is a target
    args = words[1:]
    end = args.index("--") if "--" in args else len(args)
    return args[:end], args[end + 1:]
def check_git(words, via_xargs):
    # git [global options] SUBCOMMAND ...: clean and reset --hard work on a
    # whole tree, the one the shell is in, -C names or --work-tree names.
    args = words[1:]
    dirs = list(cwds)
    while args:
        a = args[0]
        if a in ("-C", "--work-tree") and len(args) > 1:
            d = args[1]
            if "$" in d or "`" in d:
                d = expand(d)
                if d is None:
                    block("git with a folder the guard cannot follow; spell the path out.")
            d = os.path.expanduser(d)
            dirs = [None if c is None else os.path.join(c, d) for c in dirs]
            args = args[2:]
        elif a.startswith("--work-tree="):
            d = os.path.expanduser(a.split("=", 1)[1])
            dirs = [None if c is None else os.path.join(c, d) for c in dirs]
            args = args[1:]
        elif a in ("-c", "--git-dir", "--namespace", "--exec-path", "--super-prefix") and len(args) > 1:
            args = args[2:]
        elif a.startswith("-"):
            args = args[1:]
        else:
            break
    if not args:
        return
    sub, rest = args[0], args[1:]
    flags = "".join(w.lstrip("-") for w in rest if w.startswith("-") and not w.startswith("--"))
    longs = [w for w in rest if w.startswith("--")]
    if sub == "clean":
        if "n" in flags or any(len(w) > 4 and "--dry-run".startswith(w) for w in longs):
            return
        what = "git clean"
    elif sub == "reset" and any(re.match(r"^--ha(r(d)?)?$", w) for w in rest):
        what = "git reset --hard"
    else:
        return
    if via_xargs:
        block("%s through xargs; run it directly so the guard can check it." % what)
    if None in dirs:
        block("%s after a cd the guard cannot follow; use -C with an absolute path." % what)
    for d in dirs:
        check(d, what, whole_ok=True, dirs=[d])
    # a pathspec is relative to that tree and may leave it (../..)
    end = rest.index("--") if "--" in rest else len(rest)
    for p in [w for w in rest[:end] if not w.startswith("-")] + rest[end + 1:]:
        check(p, what, whole_ok=True, dirs=dirs)
pieces = re.split(r"(&&|\|\||;|\||\n|\$\(|\(|\)|`)", text)
RECURSIVE = re.compile(r"(^|\s)-[A-Za-z]*[rR]|(^|\s)--rec")
def rest_of_command(i):
    # The text after piece i up to the end of its own command: what a
    # substitution in piece i may be followed by (-r after $(...), -delete).
    depth, tick, out = 0, False, []
    for k in range(i + 1, len(pieces)):
        tok = pieces[k]
        if k % 2:
            if tok in ("$(", "("):
                depth += 1
            elif tok == ")":
                depth = max(0, depth - 1)
            elif tok == "`":
                tick = not tick
            elif depth == 0 and not tick:
                break
        else:
            out.append(tok)
    return " ".join(out)
def check_substitution(words, i):
    # The piece ends where a $( or a backtick opens, so a target it holds is a
    # command substitution: it names paths the guard cannot see.
    head = base(words[0])
    tail = " ".join(words[1:]) + " " + rest_of_command(i)
    what = None
    if head == "find":
        # a start path is before the first option (-H, -L and -P aside)
        if "-delete" in tail.split() and not any(w.startswith("-") and not re.match(r"^-[HLP]$", w) for w in words[1:]):
            what = "find -delete"
    elif head == "git":
        if re.search(r"(^|\s)clean(\s|$)", tail) or \
                (re.search(r"(^|\s)reset(\s|$)", tail) and re.search(r"(^|\s)--ha", tail)):
            what = "git clean or git reset --hard"
    elif head == "rsync":
        if re.search(r"(^|\s)(--del\S*|--remove-source-files)(\s|$)", tail):
            what = "rsync --delete"
    else:
        verb = next((base(w) for w in words if base(w) in DEL_CMDS), None)
        # rm without -r names files only, as everywhere else in this guard
        if verb and (verb != "rm" or RECURSIVE.search(tail)):
            what = "recursive rm" if verb == "rm" else verb
    if what:
        block("%s with a command substitution as a target; the guard cannot see what it names. List the paths first, then name them." % what)
shells = ("bash", "sh", "zsh", "dash", "ksh")
for i in range(0, len(pieces), 2):
    part = pieces[i]
    before = pieces[i - 1] if i > 0 else ";"
    after = pieces[i + 1] if i + 1 < len(pieces) else ";"
    try:
        words = shlex.split(part)
    except ValueError:
        # The split above cuts quoted text at ; | ( and ), so a piece can be
        # unbalanced. A command that mentions a delete and cannot be followed
        # is blocked rather than skipped.
        block("the delete guard cannot follow the quoting in this command; put the delete on its own line.")
    if not words:
        continue
    plain = words[1:] if words[0] in ("export", "local", "readonly") else words
    if plain and all(re.match(r"^\w+=", w) for w in plain):
        # Only an assignment sure to run counts: one after && || | or inside
        # ( ) or backticks may not happen (or not in this shell), so the
        # value is unknown.
        sure = before in (";", "\n")
        for w in plain:
            name, value = w.split("=", 1)
            assigned[name] = expand(value) if sure else None
            assignments[name] = assignments.get(name, 0) + 1
        continue
    via_xargs = False
    while words and (base(words[0]) in ("sudo", "command", "builtin", "env", "exec", "then", "do", "else", "elif",
                                  "if", "while", "until", "!", "{", "time", "nohup", "nice", "xargs")
                     or "=" in words[0]):
        via_xargs = via_xargs or words[0] == "xargs"
        words = words[1:]
    if not words:
        continue
    ticks = pieces[1:i:2].count("`")
    if after == "$(" or (after == "`" and ticks % 2 == 0):
        check_substitution(words, i)
    if base(words[0]) in shells + ("eval",) and \
            any(TRIG.search(w) for w in words[1:]):
        block("a delete inside a nested shell or eval; run it directly so the guard can check it.")
    if base(words[0]) in shells and before == "|":
        # the text before the pipe, back to the start of its own command
        k = max((j for j in range(1, i, 2) if pieces[j] in ("&&", "||", ";", "\n")), default=-1)
        if TRIG.search(re.sub(r"[\"\x27\\]", "", "".join(pieces[k + 1:i]))):
            block("a delete inside a nested shell or eval (text piped to a shell); run it directly so the guard can check it.")
    if interpreter.match(base(words[0])) and \
            code_del.search(re.sub(r"[\"\x27\\]", "", text[len("".join(pieces[:i])):])):
        block("%s with a delete in its code; the guard cannot see what it removes. Put the delete in a script file and run the file." % base(words[0]))
    if base(words[0]) == "find" and any(base(w) in DEL_CMDS for w in words[1:]):
        block("find -exec rm deletes paths the guard cannot see; list them first, then rm them by name.")
    if base(words[0]) == "find" and "-delete" in words[1:]:
        starts = []
        for w in words[1:]:
            if w.startswith("-") or w in ("!", "("):
                if starts or not re.match(r"^-([HLP]|D|O[0-9]?)$", w):
                    break
                continue
            starts.append(w)
        for s in starts or ["."]:
            check(s, "find -delete", whole_ok=True)
        continue
    if base(words[0]) == "rsync" and any(w == "--del" or w.startswith("--delete") or w == "--remove-source-files"
                                           for w in words[1:]):
        opts, operands = operands_of(words)
        dest = ([w for w in opts if not w.startswith("-")] + operands)[-1:]
        if not dest or ":" in dest[0]:
            block("rsync --delete to a destination the guard cannot check; name a local folder.")
        check(dest[0], "rsync --delete")
        continue
    if base(words[0]) == "git":
        check_git(words, via_xargs)
        continue
    if base(words[0]) in ("cd", "pushd", "popd"):
        # Options (-L, -P, -e, -@) come before the folder; "-" alone is the
        # previous folder, which the guard cannot know.
        args = words[1:]
        while args and args[0].startswith("-") and args[0] != "-":
            done = args.pop(0) == "--"
            if done:
                break
        dest = args[0] if args and base(words[0]) != "popd" else None
        if dest is None or dest == "-" or "$" in dest or "`" in dest:
            new = [None]
        else:
            dest = os.path.expanduser(dest)
            new = [dest if os.path.isabs(dest) else (os.path.join(c, dest) if c else None) for c in cwds]
        certain = before in (";", "\n", "&&") and after == "&&"
        cwds = new if certain else cwds + new
        continue
    # Any wrapper with any options can run rm (nice -n 5, sudo -u x,
    # timeout 5, env -i), so rm is checked wherever it is in the command.
    at = next((k for k, w in enumerate(words) if base(w) in DEL_CMDS), None)
    if at is None:
        continue
    verb = base(words[at])
    via_xargs = via_xargs or any(base(w) == "xargs" for w in words[:at])
    words = words[at:]
    opts, operands = operands_of(words)
    if verb == "rm":
        flags = "".join(w.lstrip("-") for w in opts if w.startswith("-") and not w.startswith("--"))
        longs = [w for w in opts if w.startswith("--")]
        # GNU takes any unambiguous prefix of a long option (--recurs)
        recursive = "r" in flags or "R" in flags or any(len(w) > 2 and "--recursive".startswith(w) for w in longs)
        if not recursive:
            continue
        what = "recursive rm"
    else:
        what = verb
    if via_xargs:
        block("%s through xargs takes its targets from input the guard cannot see." % what)
    for target in [w for w in opts if not w.startswith("-")] + operands:
        check(target, what)
' "$repo" "$HOME"
# A crash in the check would exit 1, which lets the call through: block it.
rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
  echo "Blocked: the delete guard failed (exit $rc) while checking this command." >&2
  rc=2
fi
exit "$rc"
