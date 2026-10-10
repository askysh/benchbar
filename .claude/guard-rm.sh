#!/bin/bash
# PreToolUse hook for Bash: blocks "rm -rf" (any spelling of recursive plus
# force) whose target is outside this repository and the benchbar state
# folders. Permission rules match prefixes and cannot say "outside", so the
# check lives here. Exit 2 blocks the call and shows the reason to Claude.
# Runs on macOS /bin/bash 3.2 too.
input="$(cat)"
cmd="$(printf '%s' "$input" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null)" || exit 0
case "$cmd" in *rm*) ;; *) exit 0 ;; esac
repo="${CLAUDE_PROJECT_DIR:-$PWD}"
python3 - "$repo" "$HOME" "$cmd" <<'PY'
import os, re, shlex, sys
repo, home = (os.path.realpath(p) for p in sys.argv[1:3])
text = sys.argv[3]
allowed = [repo, os.path.join(home, ".benchbar"), os.path.join(home, ".local/state/benchbar"),
           os.environ.get("TMPDIR", "/tmp")]
if os.environ.get("XDG_STATE_HOME"):
    allowed.append(os.path.join(os.environ["XDG_STATE_HOME"], "benchbar"))
for part in re.split(r"&&|\|\||;|\||\n", text):
    try:
        words = shlex.split(part)
    except ValueError:
        continue
    while words and (words[0] in ("sudo", "command", "env") or "=" in words[0]):
        words = words[1:]
    if not words or os.path.basename(words[0]) != "rm":
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
        path = os.path.realpath(os.path.expanduser(target))
        if not any(path == a or path.startswith(a.rstrip("/") + "/") for a in allowed):
            print("Blocked: rm -rf outside the repo and the benchbar state folders: %s" % path, file=sys.stderr)
            sys.exit(2)
        if path in allowed:
            print("Blocked: rm -rf of a whole allowed root: %s" % path, file=sys.stderr)
            sys.exit(2)
PY
