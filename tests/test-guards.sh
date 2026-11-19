#!/usr/bin/env bash
# The two PreToolUse hooks of .claude/settings.json, run the way Claude Code
# runs them: the tool call as JSON on stdin, exit 2 blocks, 0 lets it through.
#
#   guard-rm.sh      recursive deletes outside the repo, the benchbar log
#                    folders and the temp folder (needs python3)
#   guard-writes.sh  gh writes, schtasks changes (pure bash)
#
# Each case is one command line. The tables are the contract: a change to a
# hook that opens a blocked line or closes an allowed one fails here. The
# commands are only text; nothing in this file runs them.
# shellcheck disable=SC2016  # the case tables hold command text in single quotes
set -euo pipefail

ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
TMP_DIR="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/benchbar-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$TMP_DIR"' EXIT

TAB=$'\t'
FAILS=0
CASES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }

# The fake machine: a repo with a .git folder, a HOME with the state folders
# and a "real bench" the hooks must protect.
export HOME="$TMP_DIR/home"
export TMPDIR="$TMP_DIR/tmp"
unset XDG_STATE_HOME
REPO="$TMP_DIR/repo"
BENCH="$HOME/dev/frappe-bench"
mkdir -p "$REPO/.git" "$REPO/lib" "$TMPDIR" "$BENCH/apps/x" "$HOME/.benchbar/logs" "$HOME/.benchbar/backups" \
  "$HOME/.local/state/benchbar/logs" "$HOME/.local/state/benchbar/backups"
export CLAUDE_PROJECT_DIR="$REPO"
GRAPHQL_READ="$TMP_DIR/read.graphql"
GRAPHQL_RESOLVE="$TMP_DIR/resolve.graphql"
GRAPHQL_DELETE="$TMP_DIR/delete.graphql"
printf 'query { viewer { login } }\n' >"$GRAPHQL_READ"
printf 'mutation { resolveReviewThread(input: {threadId: "x"}) { thread { id } } }\n' >"$GRAPHQL_RESOLVE"
printf 'mutation { deleteRepository(input: {repositoryId: "x"}) { clientMutationId } }\n' >"$GRAPHQL_DELETE"
STUB="$TMP_DIR/stub"
mkdir -p "$STUB"
# the Windows Store python3: on PATH, exits 9009 (9 here) when run
printf '#!/bin/sh\nexit 9\n' >"$STUB/python3"
chmod +x "$STUB/python3"

HAVE_PYTHON=1
python3 -c '' >/dev/null 2>&1 || HAVE_PYTHON=0

# json_input CWD COMMAND: what Claude Code sends, the command JSON escaped
json_input() {
  local c
  c="$(printf '%s' "$2" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$TAB/\\\\t/g" | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }')"
  printf '{"session_id":"t","cwd":"%s","tool_name":"Bash","tool_input":{"command":"%s","description":"test"}}' "$1" "$c"
}

# run HOOK CWD COMMAND [PATH]: sets rc and out (the hook's stderr and stdout)
run() {
  local cmd="$3"
  cmd="${cmd//@REPO@/$REPO}"
  cmd="${cmd//@BENCH@/$BENCH}"
  cmd="${cmd//@HOME@/$HOME}"
  cmd="${cmd//@TMP@/$TMPDIR}"
  cmd="${cmd//@STATE@/$HOME/.local/state/benchbar}"
  cmd="${cmd//@GQL_READ@/$GRAPHQL_READ}"
  cmd="${cmd//@GQL_RESOLVE@/$GRAPHQL_RESOLVE}"
  cmd="${cmd//@GQL_DELETE@/$GRAPHQL_DELETE}"
  rc=0
  out="$(json_input "$2" "$cmd" | PATH="${4:-$PATH}" bash "$ROOT/.claude/$1.sh" 2>&1)" || rc=$?
  CASES=$((CASES + 1))
}

# ok_IN HOOK CWD COMMAND: must pass; no_IN HOOK CWD COMMAND [TEXT]: must exit 2
# and, with TEXT, say it
allow() {
  run "$1" "$2" "$3"
  [[ "$rc" == 0 ]] || fail "$1 should allow (exit $rc): $3"$'\n'"  $out"
}
block() {
  run "$1" "$2" "$3"
  if [[ "$rc" != 2 ]]; then
    fail "$1 should block (exit $rc): $3"
  elif [[ -n "${4:-}" ]]; then
    case "$out" in *"$4"*) ;; *) fail "$1 blocked [$3] without saying [$4]:"$'\n'"  $out" ;; esac
  fi
}
rm_ok() { allow guard-rm "$REPO" "$1"; }
rm_no() { block guard-rm "$REPO" "$1" "${2:-}"; }
rm_ok_in() { allow guard-rm "$1" "$2"; }
rm_no_in() { block guard-rm "$1" "$2" "${3:-}"; }
gw_ok() { allow guard-writes "$REPO" "$1"; }
gw_no() { block guard-writes "$REPO" "$1" "${2:-}"; }

# ---------------------------------------------------------------- guard-rm

if [[ "$HAVE_PYTHON" == 1 ]]; then
  # nothing to look at
  rm_ok 'ls -la'
  rm_ok 'bash tests/run-tests.sh test-doctor'
  rm_ok 'echo platform and guard-rm.sh'
  rm_ok 'python3 tests/foo.py'
  rm_ok 'python3 -c "print(1)"'
  rm_ok 'git status && git log --oneline -3'
  rm_ok 'git commit -m "reset the clean room"'
  rm_ok 'git log --grep reset'

  # recursive rm inside the repo, the temp folder and the logs
  rm_ok 'rm -rf @REPO@/build'
  rm_ok 'rm -rf lib/old'
  rm_ok 'rm -fr @TMP@/x'
  rm_ok 'rm -r @HOME@/.benchbar/logs/old'
  rm_ok 'rm -rf @STATE@/logs/2026'
  rm_ok 'echo $(rm -rf @REPO@/x)'
  rm_ok 'SCR=/tmp/claude-guardtest/w; rm -rf $SCR/x'
  rm_ok 'cd @REPO@ && rm -rf build'
  # no -r: rm names files only, with or without -f
  rm_ok 'rm file.txt'
  rm_ok 'rm -f @BENCH@/x'

  # outside, in every spelling (OPS-15)
  rm_no 'rm -rf @BENCH@' 'outside the repo'
  rm_no 'rm -r @BENCH@' 'outside the repo'
  rm_no 'rm -R @BENCH@'
  rm_no 'rm --recursive @BENCH@'
  rm_no 'rm --recurs @BENCH@'
  rm_no 'rm -fr ~/dev/frappe-bench'
  rm_no 'rm -vr @BENCH@/apps'
  rm_no 'rm -rf -- @BENCH@/sites'
  rm_no 'RM.EXE -rf @BENCH@'
  rm_no "r''m -rf @BENCH@"
  rm_no 'sudo rm -rf @BENCH@'
  rm_no 'nice -n 5 rm -rf @BENCH@'
  rm_no 'echo `rm -rf @BENCH@`' 'outside the repo'
  rm_no 'echo "$(rm -r @BENCH@)"'
  rm_no 'echo ok; echo `rm -r @BENCH@`'
  # the backups are not a log
  rm_no 'rm -rf @HOME@/.benchbar'
  rm_no 'rm -rf @HOME@/.benchbar/backups/x'
  rm_no 'rm -rf @STATE@'
  rm_no 'rm -rf @STATE@/backups'
  rm_no 'rm -rf @HOME@/.benchbar/logs' 'whole allowed root'
  # the repo, but not its history or the whole of it
  rm_no 'rm -rf @REPO@/.git' 'repo history'
  rm_no 'rm -rf .git' 'repo history'
  rm_no 'rm -rf .git/objects' 'repo history'
  rm_no 'rm -rf @REPO@' 'whole allowed root'
  rm_no 'rm -rf @TMP@' 'whole allowed root'
  # what the guard cannot follow
  rm_no 'rm -rf $HOME/x' 'variable target'
  rm_no 'rm -rf @REPO@/{a,b}' 'brace expansion'
  rm_no 'cd @BENCH@ && rm -rf sites' 'outside the repo'
  rm_no 'cd "$X" && rm -rf sites'
  rm_no 'echo x | xargs rm -rf' 'xargs'
  rm_no 'bash -c "rm -rf @BENCH@"' 'nested shell'
  rm_no 'eval "rm -rf x"' 'nested shell'
  rm_no 'find @REPO@ -name x -exec rm -rf {} \;'
  rm_no 'find @REPO@ -name x -exec rm -rf {} +' 'find -exec'
  rm_no 'echo "(" ; rm -rf @REPO@/x' 'quoting'
  rm_no_in "$BENCH" 'rm -rf apps' 'outside the repo'
  rm_no_in "$BENCH/apps/x" 'rm -r ../..' 'outside the repo'

  # git clean and git reset --hard work on a whole tree
  rm_ok 'git clean -n'
  rm_ok 'git clean -nfd'
  rm_ok 'git clean --dry-run -fd'
  rm_ok 'git clean -fd'
  rm_ok 'git -C @REPO@ clean -fdx'
  rm_ok 'git reset --hard origin/next-release'
  rm_ok 'git reset --soft HEAD~1'
  rm_ok 'git reset HEAD file'
  rm_ok_in "$BENCH" 'git status'
  rm_no_in "$BENCH" 'git clean -fdx' 'git clean'
  rm_no_in "$BENCH/apps/x" 'git reset --hard' 'git reset --hard'
  rm_no_in "$BENCH" 'git reset --hard HEAD~3'
  rm_no 'git -C @BENCH@ clean -fdx' 'git clean'
  rm_no 'git -C @BENCH@/apps/x reset --hard' 'git reset --hard'
  rm_no 'git --work-tree=@BENCH@ clean -fd'
  rm_no 'git clean -fd -- ../x' 'outside the repo'
  rm_no 'cd @BENCH@ && git clean -fd'
  rm_no 'echo x | xargs git clean -fd'

  # find -delete, rsync --delete, unlink, shred, rimraf
  rm_ok 'find . -name x'
  rm_ok "find . -name '*.o' -delete"
  rm_ok 'find @REPO@/build -delete'
  rm_ok 'rsync -a src/ dest/'
  rm_ok 'rsync -a --delete src/ @REPO@/dest/'
  rm_ok 'unlink @REPO@/x'
  rm_ok 'shred -u @TMP@/x'
  rm_no 'find @BENCH@ -name x -delete' 'find -delete'
  rm_no 'find @BENCH@ -delete'
  rm_no 'find / -delete'
  rm_no_in "$BENCH" 'find . -delete' 'find -delete'
  rm_no 'rsync -a --delete src/ @BENCH@/' 'rsync --delete'
  rm_no 'rsync -a --delete-after src/ host:/data/' 'destination'
  rm_no 'unlink @BENCH@/x'
  rm_no 'shred -u @BENCH@/x'
  rm_no 'npx rimraf @BENCH@/node_modules'

  # a delete inside an interpreter's code: the guard cannot see the target
  rm_no 'python3 -c "import shutil; shutil.rmtree(x)"'
  rm_no 'python3 -c "import os; os.remove(x)"'
  rm_no 'python3 - <<EOF
import shutil
shutil.rmtree(x)
EOF' 'code'
  rm_no 'node -e "fs.rmSync(x)"'
  rm_no 'perl -e "unlink glob q(*)"'
  rm_no 'ruby -e "FileUtils.rm_rf(x)"'
  rm_no 'powershell -Command "Remove-Item -Recurse x"'
  rm_ok 'python3 tests/foo.py && rm -rf @REPO@/build'

  # a backslash before the command name is how a person skips an alias; the
  # JSON of it is two backslashes, and a \r there must not read as a CR
  rm_no '\rm -rf @BENCH@' 'outside the repo'
  rm_no '\rm -r @BENCH@'
  rm_no 'command \rm -r @BENCH@'
  rm_no '\rsync -a --delete src/ @BENCH@/' 'rsync --delete'
  rm_no 'echo hi;\rm -rf @BENCH@'
  rm_ok '\rm -rf @REPO@/build'
  # a real newline or tab between words still separates them
  rm_no $'echo x\nrm -rf @BENCH@'
  rm_no "echo x;rm${TAB}-rf${TAB}@BENCH@"
  rm_no $'echo x\n\nrm -rf @BENCH@'

  # a command substitution or a backtick as the target: the piece has no
  # operand the guard can read, so it is blocked, not passed
  rm_no 'rm -rf $(cat list)' 'command substitution'
  rm_no 'rm -r $(echo @BENCH@)' 'command substitution'
  rm_no 'rm -r `cat list`' 'command substitution'
  rm_no 'rm -rf @REPO@/x$(echo y)'
  rm_no 'rm -rf @REPO@/a $(cat list)'
  rm_no 'rm $(echo a) -rf @BENCH@'
  rm_no 'rm $(echo a) -R @REPO@/b'
  rm_no 'sudo rm -rf $(cat list)'
  rm_no 'unlink $(cat list)'
  rm_no 'shred -u `cat list`'
  rm_no 'find $(echo @BENCH@) -delete' 'command substitution'
  rm_no 'find `echo @BENCH@` -name x -delete'
  rm_no 'git -C $(echo @BENCH@) clean -fd' 'command substitution'
  rm_no 'git clean -fd $(cat list)'
  rm_no 'git -C `echo @BENCH@` reset --hard'
  rm_no 'rsync -a --delete src/ $(echo @BENCH@)' 'command substitution'
  rm_no 'ls && rm -rf $(cat list)'
  rm_ok 'rm -f $(cat list)'
  rm_ok 'rm -rf @REPO@/x; echo $(date)'
  rm_ok 'rm -rf @REPO@/x && echo `date`'
  rm_ok 'echo `rm -rf @REPO@/x`'
  rm_ok 'find . -name "$(echo x)" -name y'
  rm_ok 'git -C $(echo @REPO@) status'
  rm_ok 'git commit --amend --reset-author -m x'

  # the repo history in any letter case (a Mac volume is case insensitive)
  rm_no 'rm -rf @REPO@/.GIT' 'repo history'
  rm_no 'rm -rf .Git/objects' 'repo history'
  # the text of a delete fed to a shell on stdin
  rm_no 'echo "rm -rf @BENCH@" | sh' 'nested shell'
  rm_no "printf 'rm -rf %s' @BENCH@ | bash" 'nested shell'
  rm_no 'echo rm -rf @REPO@/x | bash -s'
  rm_ok 'echo hello | sh'
  rm_ok 'cat install.sh | bash'
  rm_ok 'echo "rm is a command" | cat'
  # node: a delete that does not spell fs.rm
  rm_no "node -e 'const {rmSync}=require(\"fs\"); rmSync(\"x\",{recursive:true})'"
  rm_no "node -e 'require(\"fs\").rmSync(\"x\")'"
  rm_no "node -e 'require(\"fs\").promises.rm(\"x\")'"
else
  printf 'skip: guard-rm cases need python3\n'
fi

# no python3, or the Windows Store stub: a command that deletes is blocked,
# one that does not is not looked at
run guard-rm "$REPO" 'rm -rf @REPO@/build' "$STUB:$PATH"
[[ "$rc" == 2 ]] || fail "guard-rm without python3 should block rm (exit $rc)"
case "$out" in *python3*) ;; *) fail "guard-rm without python3 should name python3: $out" ;; esac
run guard-rm "$REPO" 'git clean -fd' "$STUB:$PATH"
[[ "$rc" == 2 ]] || fail "guard-rm without python3 should block git clean (exit $rc)"
run guard-rm "$REPO" 'ls -la' "$STUB:$PATH"
[[ "$rc" == 0 ]] || fail "guard-rm without python3 should pass ls (exit $rc)"

# a call that is not JSON is blocked, not let through
rc=0
out="$(printf 'rm -rf x' | bash "$ROOT/.claude/guard-rm.sh" 2>&1)" || rc=$?
if [[ "$HAVE_PYTHON" == 1 ]]; then
  [[ "$rc" == 2 ]] || fail "guard-rm should block input that is not JSON (exit $rc)"
fi

# ------------------------------------------------------------ guard-writes

# not a command, or not a gh write
gw_ok 'ls -la'
gw_ok 'gh api repos/o/r/pulls/1'
gw_ok 'gh api repos/o/r/pulls --paginate --jq .[].number'
gw_ok 'gh api -X GET search/issues -f q=benchbar'
gw_ok 'gh pr view 3 --json state'
gw_ok 'gh run view 123 --log-failed'
# a -F after a pipe is awk's, not gh's (OPS-17)
gw_ok "gh api repos/o/r/pulls --jq '.[] | .title' | awk -F'\\t' '{print \$1}'"
gw_ok 'gh api repos/o/r/pulls --jq .[].title | cut -f1'
# the routes that are always allowed
gw_ok 'gh api -X POST repos/o/r/pulls/5/ccr/comments/abc/resolve'
gw_ok 'gh api --method POST repos/o/r/pulls/5/ccr/comments/abc/resolve'
gw_ok 'gh api -X POST repos/askysh/benchbar/pulls/3/comments/9/replies -F body=@/tmp/b.txt'
gw_ok 'gh api -X POST repos/askysh/benchbar/pulls/3/comments/9/replies -F body=@/tmp/b.txt --silent'
gw_ok 'gh api graphql -F query=@@GQL_READ@'
gw_ok 'gh api graphql -F query=@@GQL_RESOLVE@'
# REST writes to our own two repositories
gw_ok 'gh api -X POST repos/askysh/benchbar/issues -f title=x'
gw_ok 'gh api --method PATCH repos/askysh/homebrew-tap/rulesets/3 --input r.json'
gw_ok 'gh api -X PUT repos/askysh/benchbar/environments/release'
gw_ok 'gh api repos/askysh/benchbar/issues -f title=x'
# gh verbs: the checkout's own repo, or one of ours
gw_ok 'gh pr merge 5 --squash'
gw_ok 'gh pr merge 5 -R askysh/benchbar'
gw_ok 'gh pr comment 5 --repo=askysh/homebrew-tap -b x'
gw_ok 'gh release create v1 --repo askysh/benchbar'
gw_ok 'gh run rerun 9 -R askysh/benchbar'
gw_ok 'gh repo edit askysh/benchbar --description x'
# schtasks
gw_ok 'schtasks /Query'
gw_ok 'schtasks /Create /TN "BenchBar Keepalive" /TR x /SC ONLOGON'

# gh api writes elsewhere
gw_no 'gh api -X POST repos/o/r/issues -f title=x' 'gh api writes'
gw_no 'gh api -X DELETE repos/other/repo/git/refs/heads/x'
gw_no 'gh api repos/other/repo/issues -f title=x'
gw_no 'gh api repos/other/repo/issues --input body.json'
gw_no 'gh api -X POST user/repos -f name=x'
gw_no 'gh api -X POST repos/askysh/benchbar-fork/issues -f a=b'
gw_no 'gh api -X POST repos/askysh/benchbar/issues repos/other/x/issues -f a=b'
gw_no 'gh api repos/askysh/benchbar/pulls && gh api -X DELETE repos/other/r/branches/x'
gw_no 'gh api repos/askysh/benchbar/pulls; gh api -X POST repos/o/r/issues -f a=b'
gw_no 'gh api -XPOST repos/o/r/issues'
gw_no 'gh api -iX DELETE repos/o/r'
gw_no 'gh api --method=PUT repos/o/r/topics'
gw_no 'gh api graphql -f query="mutation { x }"'
gw_no 'gh api graphql -F query=@@GQL_DELETE@'
gw_no 'GH.EXE API -X POST repos/o/r/issues -f a=b'
# gh verbs that name another repository
gw_no 'gh pr merge 5 -R other/repo' 'other than askysh'
gw_no 'gh pr close 5 --repo other/repo'
gw_no 'gh pr merge https://github.com/other/repo/pull/5'
gw_no 'gh issue create --repo=other/repo -t x'
gw_no 'gh release create v1 -R other/repo'
gw_no 'gh run cancel 5 --repo=other/repo'
gw_no 'gh secret set X -R other/repo'
gw_no 'gh repo delete other/thing --yes'
gw_no 'gh repo create newthing --public'
gw_no 'gh repo fork other/x'
gw_no 'gh repo edit other/x --visibility private'
gw_no 'gh pr view 1 && gh pr merge 5 -R other/repo'
# -R, --repo and GH_REPO that come before the verb
gw_ok 'gh -R askysh/benchbar pr merge 5'
gw_ok 'GH_REPO=askysh/benchbar gh pr merge 5'
gw_ok 'GH_REPO=askysh/homebrew-tap gh release create v1'
gw_ok 'gh --repo askysh/benchbar issue close 4'
gw_ok 'gh pr view 5 -R other/repo'
gw_ok 'GH_REPO=other/repo gh pr view 5'
gw_no 'gh -R other/repo pr merge 5' 'other than askysh'
gw_no 'gh --repo other/repo pr merge 5'
gw_no 'gh --repo=other/repo pr close 5'
gw_no 'gh -Rother/repo pr merge 5'
gw_no 'gh --hostname github.com -R other/repo release create v1'
gw_no 'GH_REPO=other/repo gh pr merge 5'
gw_no 'GH_REPO=other/repo gh release create v1'
gw_no 'env GH_REPO=other/repo gh issue create -t x'
gw_no 'export GH_REPO=other/repo; gh pr merge 5'
gw_no 'GH_REPO=$R gh pr merge 5'
gw_no 'GH_REPO= gh pr merge 5'
gw_no 'GH_REPO=other/repo gh api -X POST repos/{owner}/{repo}/issues -f title=x'
# secrets and variables of an organization or of the user are not a repo's
gw_ok 'gh secret set X --body y'
gw_ok 'gh variable set X --repo askysh/benchbar --body y'
gw_no 'gh secret set X --org exponent --body y' 'other than askysh'
gw_no 'gh secret set X -o exponent'
gw_no 'gh variable set X --org=exponent --body y'
gw_no 'gh variable set X -oexponent'
gw_no 'gh secret set X --user'
gw_no 'gh secret delete X --org exponent'
# schtasks
gw_no 'schtasks /Delete /TN x /F' 'schtasks'
gw_no 'schtasks /Change /TN x /DISABLE'
gw_no 'schtasks /Create /TN other /TR x'
gw_no 'SCHTASKS.EXE /DELETE /TN x'
gw_no 'schtasks /Create /TN "BenchBar Keepalive" /TN other /TR x'

# --------------------------------------------------------------- settings

SETTINGS="$ROOT/.claude/settings.json"
if [[ "$HAVE_PYTHON" == 1 ]]; then
  python3 -I - "$SETTINGS" <<'EOF' || fail "settings.json: see the line above"
import json, sys
s = json.load(open(sys.argv[1]))
perm = s["permissions"]
text = json.dumps(s)
def bad(msg):
    print("settings.json: " + msg, file=sys.stderr)
    sys.exit(1)
# risky verbs ask, they are not allowed without a question
for rule in ("Bash(git push *)", "Bash(git tag *)", "Bash(gh pr merge *)", "Bash(gh pr close *)",
             "Bash(gh run rerun *)", "Bash(gh run cancel *)", "Bash(gh run delete *)", "Bash(gh release *)",
             "Bash(sudo *)"):
    if rule not in perm.get("ask", []):
        bad("ask list lacks " + rule)
# the forms that skip "git push" by naming an option first, the REST writes of
# our own repositories that guard-writes.sh lets through, and the repo verbs
for verb in ("push", "tag"):
    for opt in ("-C *", "-c *", "--no-pager"):
        rule = "Bash(git %s %s*)" % (opt, verb)
        if rule not in perm.get("ask", []):
            bad("ask list lacks " + rule)
for rule in ("Bash(gh api * merge*)", "Bash(gh api * git/refs*)", "Bash(gh api -X DELETE repos/askysh/*)",
             "Bash(gh repo delete *)", "Bash(gh repo archive *)", "Bash(gh repo rename *)", "Bash(gh repo edit *)"):
    if rule not in perm.get("ask", []):
        bad("ask list lacks " + rule)
for rule in ("Bash(bench update*)", "Bash(bench restore*)", "Bash(mariadb -u root*)", "Bash(mariadb -uroot*)",
             "Bash(mariadb --user root*)", "Bash(mariadb --user=root*)", "Bash(mysql -uroot*)", "Bash(mysql -u root*)",
             "Bash(mysql --user root*)"):
    if rule not in perm.get("deny", []):
        bad("deny list lacks " + rule)
# the allow list is read only for gh, and names no verb that asks
for rule in perm["allow"]:
    if rule in ("Bash(gh pr *)", "Bash(gh run *)", "Bash(gh release *)", "Bash(git push *)", "Bash(git tag *)") \
            or rule.startswith("Bash(sudo"):
        bad("allow list has " + rule)
# the hooks are wired
hooks = [h["command"] for g in s["hooks"]["PreToolUse"] for h in g["hooks"]]
for name in ("guard-rm.sh", "guard-writes.sh"):
    if not any(name in c for c in hooks):
        bad("hook " + name + " is not wired")
# a public file names no person: no user folder of a real account
import re
if re.search(r"[Uu]sers[\\/]+(?!\*|\.\*|\?)[A-Za-z0-9_.-]+", text):
    bad("a user name in a path")
EOF
fi

printf 'guards: %s cases, %s failed\n' "$CASES" "$FAILS"
[[ "$FAILS" == 0 ]]
