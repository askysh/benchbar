#!/bin/bash
# PreToolUse hook for Bash: blocks "rm -rf" (any spelling of recursive plus
# force) whose target is outside this repository and the benchbar state
# folders. Permission rules match prefixes and cannot say "outside", so the
# check lives here. Exit 2 blocks the call and shows the reason to Claude.
# Runs on macOS /bin/bash 3.2 too.
input="$(cat)"
# Only "rm" as a word counts here, so "platform" or "guard-rm.sh" does not
# need python3. Anything after it but a name character counts, so rm'' and
# a tab (\t in the JSON) still reach the parser.
# Git Bash runs rm.exe too, and Windows finds RM as rm, so case and a .exe
# suffix do not matter.
word_rm='(^|[^A-Za-z0-9_.-])rm(\.exe)?([^A-Za-z0-9_.-]|$)'
# JSON escapes for whitespace count as spaces; quotes and backslashes join
# word fragments in the shell (r''m, r\m), so they are dropped.
flat="$(printf '%s' "$input" | sed -e 's/\\[tnr]/ /g' | tr -d "'\"\\\\")"
shopt -s nocasematch
[[ $flat =~ $word_rm ]] || exit 0
shopt -u nocasematch
# The parsing needs python3. Without it (Git Bash, a Mac without the command
# line tools) a call that mentions rm is blocked rather than let through.
# Running it, not just finding it, catches the Windows Store stub, which is
# on PATH but exits 9009; any exit but 0 or 2 would let the call through.
if ! python3 -c '' >/dev/null 2>&1; then
  echo "Blocked: the rm guard needs python3 to check this command; install python3 or run it yourself." >&2
  exit 2
fi
repo="${CLAUDE_PROJECT_DIR:-$PWD}"
printf '%s' "$input" | python3 -c '
import json, os, re, shlex, sys
repo, home = (os.path.realpath(p) for p in sys.argv[1:3])
try:
    data = json.load(sys.stdin)
except ValueError:
    print("Blocked: the rm guard could not read the tool call.", file=sys.stderr)
    sys.exit(2)
text = data.get("tool_input", {}).get("command", "") or ""
word_rm = re.compile(r"(^|[^\w.-])rm(\.exe)?([^\w.-]|$)", re.I)
# quotes and backslashes join word fragments (r''m is rm)
if not word_rm.search(re.sub(r"[\"\x27\\]", "", text)):
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
allowed = [repo, os.path.join(home, ".benchbar"), os.path.join(home, ".local/state/benchbar"),
           os.environ.get("TMPDIR", "/tmp")]
if os.environ.get("XDG_STATE_HOME"):
    allowed.append(os.path.join(os.environ["XDG_STATE_HOME"], "benchbar"))
allowed = [os.path.realpath(a) for a in allowed]
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
pieces =re.split(r"(&&|\|\||;|\||\n|\(|\))", text)
for i in range(0, len(pieces), 2):
    part = pieces[i]
    before = pieces[i - 1] if i > 0 else ";"
    after = pieces[i + 1] if i + 1 < len(pieces) else ";"
    try:
        words = shlex.split(part)
    except ValueError:
        # The split above cuts quoted text at ; | ( and ), so a piece can be
        # unbalanced. A command that mentions rm and cannot be followed is
        # blocked rather than skipped.
        block("the rm guard cannot follow the quoting in this command; run the rm on its own line.")
    if not words:
        continue
    plain = words[1:] if words[0] in ("export", "local", "readonly") else words
    if plain and all(re.match(r"^\w+=", w) for w in plain):
        # Only an assignment sure to run counts: one after && || | or inside
        # ( ) may not happen (or not in this shell), so the value is unknown.
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
    if base(words[0]) in ("bash", "sh", "zsh", "dash", "ksh", "eval") and \
            any(word_rm.search(w) for w in words[1:]):
        block("rm inside a nested shell or eval; run it directly so the guard can check it.")
    if base(words[0]) == "find" and any(base(w) == "rm" for w in words[1:]):
        block("find -exec rm deletes paths the guard cannot see; list them first, then rm them by name.")
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
    at = next((k for k, w in enumerate(words) if base(w) == "rm"), None)
    if at is None:
        continue
    via_xargs = via_xargs or any(base(w) == "xargs" for w in words[:at])
    words = words[at:]
    flags = "".join(w.lstrip("-") for w in words[1:] if w.startswith("-") and not w.startswith("--"))
    longs = [w for w in words[1:] if w.startswith("--")]
    # GNU takes any unambiguous prefix of a long option (--recurs, --for)
    recursive = "r" in flags or "R" in flags or any(len(w) > 2 and "--recursive".startswith(w) for w in longs)
    force = "f" in flags or any(len(w) > 2 and "--force".startswith(w) for w in longs)
    if not (recursive and force):
        continue
    if via_xargs:
        block("rm -rf through xargs takes its targets from input the guard cannot see.")
    for target in (w for w in words[1:] if not w.startswith("-")):
        # bash expands {a,b} and {1..3} before rm runs; the literal text the
        # guard resolves is not what gets deleted.
        if re.search(r"\{[^}]*(,|\.\.)[^}]*\}", target):
            block("rm -rf with a brace expansion (%s); list the paths one by one." % target)
        if "$" in target or "`" in target:
            # A variable target is let through only when it resolves, from
            # the environment or a literal assignment earlier in the
            # command, to a path inside a /tmp/claude-* session scratchpad.
            path = expand(target)
            if path is None or not in_scratchpad(path):
                print("Blocked: rm -rf with a variable target (%s); spell the path out." % target, file=sys.stderr)
                sys.exit(2)
            continue
        target = os.path.expanduser(target)
        if os.path.isabs(target):
            candidates = [target]
        elif None in cwds:
            print("Blocked: rm -rf of a relative path after a cd the guard cannot follow (%s); use an absolute path." % target, file=sys.stderr)
            sys.exit(2)
        else:
            candidates = [os.path.join(c, target) for c in cwds]
        for path in (os.path.realpath(c) for c in candidates):
            if not any(path == a or path.startswith(a.rstrip("/") + "/") for a in allowed):
                print("Blocked: rm -rf outside the repo and the benchbar state folders: %s" % path, file=sys.stderr)
                sys.exit(2)
            if path in allowed:
                print("Blocked: rm -rf of a whole allowed root: %s" % path, file=sys.stderr)
                sys.exit(2)
' "$repo" "$HOME"
# A crash in the check would exit 1, which lets the call through: block it.
rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
  echo "Blocked: the rm guard failed (exit $rc) while checking this command." >&2
  rc=2
fi
exit "$rc"
