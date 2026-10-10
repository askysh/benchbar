#!/bin/bash
# PreToolUse hook for Bash: blocks "rm -rf" (any spelling of recursive plus
# force) whose target is outside this repository and the benchbar state
# folders. Permission rules match prefixes and cannot say "outside", so the
# check lives here. Exit 2 blocks the call and shows the reason to Claude.
# Runs on macOS /bin/bash 3.2 too.
input="$(cat)"
case "$input" in *rm*) ;; *) exit 0 ;; esac
# The parsing needs python3. Without it (Git Bash, a Mac without the command
# line tools) a call that mentions rm is blocked rather than let through.
if ! command -v python3 >/dev/null 2>&1; then
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
if "rm" not in text:
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
pieces = re.split(r"(&&|\|\||;|\||\n|\(|\))", text)
for i in range(0, len(pieces), 2):
    part = pieces[i]
    before = pieces[i - 1] if i > 0 else ";"
    after = pieces[i + 1] if i + 1 < len(pieces) else ";"
    try:
        words = shlex.split(part)
    except ValueError:
        continue
    while words and (words[0] in ("sudo", "command", "env", "exec") or "=" in words[0]):
        words = words[1:]
    if not words:
        continue
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
    for target in (w for w in words[1:] if not w.startswith("-")):
        if "$" in target or "`" in target:
            print("Blocked: rm -rf with a variable target (%s); spell the path out." % target, file=sys.stderr)
            sys.exit(2)
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
