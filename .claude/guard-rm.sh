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
word_rm='(^|[^A-Za-z0-9_.-])rm([^A-Za-z0-9_.-]|$)'
[[ $input =~ $word_rm ]] || exit 0
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
if not re.search(r"(^|[^\w.-])rm([^\w.-]|$)", text):
    sys.exit(0)
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
        return m.group(0) if value is None else value
    out = re.sub(r"\$\{(\w+)\}|\$(\w+)", lookup, word)
    if "$" in out or "`" in out or re.search(r"\s", out):
        return None
    return os.path.expanduser(out)
def in_scratchpad(path):
    # The resolved path only: a symlink inside the scratchpad may lead out.
    if not os.path.isabs(path) or (re.search(r"[*?\[]", path) and ".." in path):
        return False
    return re.match(r"^(/private)?/tmp/claude-[A-Za-z0-9._-]+/.", os.path.realpath(path)) is not None
def block(msg):
    print("Blocked: " + msg, file=sys.stderr)
    sys.exit(2)
word_rm = re.compile(r"(^|[^\w.-])rm([^\w.-]|$)")
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
        for w in plain:
            name, value = w.split("=", 1)
            assigned[name] = expand(value)
            assignments[name] = assignments.get(name, 0) + 1
        continue
    via_xargs = False
    while words and (words[0] in ("sudo", "command", "env", "exec", "then", "do", "else", "elif",
                                  "if", "while", "until", "!", "{", "time", "nohup", "nice", "xargs")
                     or "=" in words[0]):
        via_xargs = via_xargs or words[0] == "xargs"
        words = words[1:]
    if not words:
        continue
    if os.path.basename(words[0]) in ("bash", "sh", "zsh", "dash", "ksh", "eval") and \
            any(word_rm.search(w) for w in words[1:]):
        block("rm inside a nested shell or eval; run it directly so the guard can check it.")
    if words[0] in ("cd", "pushd", "popd"):
        dest = words[1] if len(words) > 1 and words[0] != "popd" else None
        if dest is None or dest == "-" or "$" in dest or "`" in dest:
            new = [None]
        else:
            dest = os.path.expanduser(dest)
            new = [dest if os.path.isabs(dest) else (os.path.join(c, dest) if c else None) for c in cwds]
        certain = before in (";", "\n", "&&") and after == "&&"
        cwds = new if certain else cwds + new
        continue
    if os.path.basename(words[0]) != "rm":
        continue
    flags = "".join(w.lstrip("-") for w in words[1:] if w.startswith("-") and not w.startswith("--"))
    longs = [w for w in words[1:] if w.startswith("--")]
    recursive = "r" in flags or "R" in flags or "--recursive" in longs
    force = "f" in flags or "--force" in longs
    if not (recursive and force):
        continue
    if via_xargs:
        block("rm -rf through xargs takes its targets from input the guard cannot see.")
    for target in (w for w in words[1:] if not w.startswith("-")):
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
