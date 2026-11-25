#!/usr/bin/env bash
# The one helper every network git call goes through (issue 146, APP-23): fl_git_timed gives a
# command a deadline that ends its whole process group, a "timed out after Ns" message and the first
# line of stderr without warnings; fl_git_remote_run, the plan's clone and fetch calls and the
# profile code (fl_profile_timed) are built on it, so they all keep the user's ssh command and the
# same deadline.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=lib/frappe-local/ui.sh
. "$ROOT/lib/frappe-local/ui.sh"
# shellcheck source=lib/frappe-local/run.sh
. "$ROOT/lib/frappe-local/run.sh"
# shellcheck source=lib/frappe-local/profiles.sh
. "$ROOT/lib/frappe-local/profiles.sh"

FL_LOG_FILE="$TMP_DIR/run.log"
: >"$FL_LOG_FILE"
OUT_FILE="$TMP_DIR/out"

# ---------------------------------------------------------------- the helper itself
noisy() { printf 'to stdout\n'; printf 'warning: ignore me\n\nfatal: boom\n' >&2; return 3; }
code=0
fl_git_timed 5 "$OUT_FILE" noisy || code=$?
assert_eq "3" "$code" "(the command's own exit code is returned)"
assert_eq "3" "$FL_GR_CODE"
assert_eq "fatal: boom" "$FL_GR_ERR" "(the first line of stderr that is not a warning)"
assert_eq "to stdout" "$(cat "$OUT_FILE")" "(stdout goes to the file)"
assert_contains "$(cat "$FL_LOG_FILE")" "fatal: boom" "(stderr goes to the run log)"

fine() { printf 'ok\n'; }
code=0
fl_git_timed 5 "$OUT_FILE" fine || code=$?
assert_eq "0" "$code"
assert_eq "" "$FL_GR_ERR"

# a deadline ends the command and what it started; the message names the seconds
PIDFILE="$TMP_DIR/child.pid"
slow() { sleep 60 & printf '%s' "$!" >"$PIDFILE"; wait; }
code=0
fl_git_timed 1 "$OUT_FILE" slow || code=$?
assert_eq "124" "$code" "(a timeout is 124)"
assert_eq "124" "$FL_GR_CODE"
assert_eq "timed out after 1s" "$FL_GR_ERR"
kid="$(cat "$PIDFILE" 2>/dev/null || true)"
sleep 1
if [[ -n "$kid" ]] && kill -0 "$kid" 2>/dev/null; then kill "$kid" 2>/dev/null || true; fail "the child of a timed out command was left running"; fi

# ---------------------------------------------------------------- the callers keep the ssh rule and the deadline
SHIM="$TMP_DIR/shim"
mkdir -p "$SHIM"
REAL_GIT=""
for c in /usr/bin/git /opt/homebrew/bin/git /usr/local/bin/git; do [[ -x "$c" ]] && { REAL_GIT="$c"; break; }; done
# ls-remote and fetch print the ssh command they were given, or sleep when SHIM_SLEEP is set
cat >"$SHIM/git" <<SH
#!/bin/bash
case " \$* " in
  *" ls-remote "*|*" fetch "*)
    [[ -z "\${SHIM_SLEEP:-}" ]] || exec sleep "\$SHIM_SLEEP"
    printf '%s\n' "\${GIT_SSH_COMMAND:-}"; exit 0 ;;
esac
exec "$REAL_GIT" "\$@"
SH
chmod +x "$SHIM/git"
PATH="$SHIM:$PATH"
unset GIT_SSH_COMMAND
git config --global user.email me@example.com
git config --global core.sshCommand "ssh -i /keys/work"
WANT="ssh -i /keys/work -o BatchMode=yes -o ConnectTimeout=${FL_GIT_CONNECT_SECS}"

fl_git_remote_run 5 ls-remote x
assert_eq "$WANT" "$FL_GR_OUT" "(fl_git_remote_run: core.sshCommand kept, no prompt)"
fl_profile_timed 5 "$OUT_FILE" fl_profile_git_net ls-remote x
assert_eq "$WANT" "$(cat "$OUT_FILE")" "(the profile code: the same ssh command)"
fl_git_timed 5 "$OUT_FILE" fl_git_net -C "$TMP_DIR" fetch --quiet origin
assert_eq "$WANT" "$(cat "$OUT_FILE")" "(the plan's calls: the same ssh command)"

export SHIM_SLEEP=60
fl_git_remote_run 1 ls-remote x
assert_eq "124" "$FL_GR_CODE"
assert_eq "timed out after 1s" "$FL_GR_ERR" "(fl_git_remote_run)"
code=0
fl_profile_timed 1 "$OUT_FILE" fl_profile_git_net ls-remote x || code=$?
assert_eq "124" "$code"
assert_eq "timed out after 1s" "$FL_PROFILE_ERR" "(fl_profile_timed)"
unset SHIM_SLEEP

# the profile code strips git's "fatal:" prefix from the message
cat >"$SHIM/git" <<'SH'
#!/bin/bash
printf 'fatal: repository not found\n' >&2
exit 128
SH
code=0
fl_profile_timed 5 "$OUT_FILE" fl_profile_git_net ls-remote x || code=$?
assert_eq "128" "$code"
assert_eq "repository not found" "$FL_PROFILE_ERR"
fl_git_remote_run 5 ls-remote x
assert_eq "fatal: repository not found" "$FL_GR_ERR" "(the shared message keeps the prefix)"

echo "git-timed: ok"
