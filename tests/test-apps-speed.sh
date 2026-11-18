#!/usr/bin/env bash
# The speed of app list and profile check (APP-1, APP-2, APP-3, APP-23): git is
# asked a few times per app, not dozens; profile check asks every repo side by
# side, each with its own timeout; a timed out git dies with its process group;
# one answer of a repo is reused for a few minutes.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=tests/lib/apps-fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apps-fixtures.sh"

USER_DIR="$HOME/.config/benchbar/profiles"
mkdir -p "$USER_DIR"
git config --global user.email me@example.com
run_js() { set +e; OUT="$("$FM" "$@" 2>"$TMP_DIR/stderr")"; CODE="$?"; ERR="$(cat "$TMP_DIR/stderr")"; set -e; }

# ---- app list: the git calls do not grow by dozens per app
BENCH="$HOME/bench-speed"
make_fake_bench "$BENCH" macdev
rmdir "$BENCH/apps/erpnext"
printf 'frappe\n' >"$BENCH/sites/apps.txt"
N=10
i=0
while [[ "$i" -lt "$N" ]]; do
  a="speed_$i"
  make_app_remote "$a"
  add_policy "$a" main
  git clone -q --origin upstream --branch main "file://${REMOTES}/${a}.git" "$BENCH/apps/$a"
  printf '%s\n' "$a" >>"$BENCH/sites/apps.txt"
  i=$((i + 1))
done
printf 'x\n' >>"$BENCH/apps/speed_1/pyproject.toml"
git -C "$BENCH/apps/speed_2" checkout -q -b feature-x
push_commits speed_3 2
git -C "$BENCH/apps/speed_3" fetch -q upstream

reset_calls
run_js app list --json --no-sites --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT $ERR"
CALLS="$(grep -c '^git ' "$MOCK_LOG" || true)"
[[ "$CALLS" -le $((N * 6 + 10)) ]] || fail "app list --json made ${CALLS} git calls for $((N + 1)) apps (at most $((N * 6 + 10)))"
assert_eq "true" "$(printf '%s' "$OUT" | jget - 'str(d["apps"][2]["focus"]).lower()')" "(the app on another branch is a focus app)"
assert_eq "feature-x" "$(printf '%s' "$OUT" | jget - 'd["apps"][3]["branch"]')"
assert_eq "2" "$(printf '%s' "$OUT" | jget - 'd["apps"][4]["behind"]')"
reset_calls
run_fm app list --no-sites --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
CALLS="$(grep -c '^git ' "$MOCK_LOG" || true)"
[[ "$CALLS" -le $((N * 6 + 10)) ]] || fail "app list made ${CALLS} git calls (at most $((N * 6 + 10)))"
assert_contains "$OUT" "speed_2"
assert_contains "$OUT" "feature-x"

# ---- profile check: side by side, a timeout per repo, the child dies with its group
# a git in front of the mock (real git behind it): an ls-remote waits until three have started
REAL_GIT=""
for c in /usr/bin/git /opt/homebrew/bin/git /usr/local/bin/git; do [[ -x "$c" ]] && { REAL_GIT="$c"; break; }; done
SHIM="$TMP_DIR/gitshim"
SYNC="$TMP_DIR/sync"
mkdir -p "$SHIM" "$SYNC"
cat >"$SHIM/git" <<SH
#!/bin/bash
if [[ " \$* " == *" ls-remote "* && -n "\${SPEED_SYNC:-}" ]]; then
  : >"\$SPEED_SYNC/started.\$\$"
  for _ in \$(seq 1 40); do
    n=0
    for f in "\$SPEED_SYNC"/started.*; do [[ -e "\$f" ]] && n=\$((n + 1)); done
    [[ \$n -ge 3 ]] && { : >"\$SPEED_SYNC/together.\$\$"; break; }
    sleep 0.2
  done
fi
if [[ " \$* " == *" ls-remote "* && -n "\${SPEED_HANG:-}" ]]; then
  sleep 60 &
  printf '%s\\n' "\$!" >>"\$SPEED_HANG"
  wait
fi
printf "git %s\\n" "\$*" >>"\${MOCK_LOG:-/dev/null}"
exec "$REAL_GIT" "\$@"
SH
chmod +x "$SHIM/git"

{
  printf 'schema = 1\nbase = "v15-lts"\nsite = "speed.localhost"\n'
  i=0
  while [[ "$i" -lt 6 ]]; do
    make_app_remote "papp_$i"
    printf '\n[[apps]]\nname = "papp_%s"\nrepo = "file://%s/papp_%s.git"\nbranch = "main"\n' "$i" "$REMOTES" "$i"
    i=$((i + 1))
  done
} >"$USER_DIR/speedprof.toml"

export FL_PROFILE_REACH_TTL=0
OLD_PATH="$PATH"
export PATH="$SHIM:$PATH" SPEED_SYNC="$SYNC"
run_js profile check speedprof --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT $ERR"
assert_eq "6" "$(printf '%s' "$OUT" | grep -o '"reachable":true' | wc -l | tr -d ' ')" "(every repo is reported) $OUT $ERR"
TOGETHER=0
for f in "$SYNC"/together.*; do [[ -e "$f" ]] && TOGETHER=$((TOGETHER + 1)); done
[[ "$TOGETHER" -ge 3 ]] || fail "the repos were asked one after the other: only ${TOGETHER} ls-remote saw two others running at once"
unset SPEED_SYNC

# a hanging ls-remote is cut after FL_PROFILE_NET_SECS and takes its children along
export SPEED_HANG="$TMP_DIR/hang-pids" FL_PROFILE_NET_SECS=1
: >"$SPEED_HANG"
run_js profile check speedprof --json --bench-dir "$BENCH"
unset SPEED_HANG FL_PROFILE_NET_SECS
assert_eq "0" "$(printf '%s' "$OUT" | grep -o '"reachable":true' | wc -l | tr -d ' ')" "(none answered) $OUT"
assert_contains "$OUT" "timed out after 1s"
assert_not_contains "$ERR" "Terminated" "(the shell's job message is not shown)"
sleep 1
ALIVE=0
while IFS= read -r pid; do
  [[ -n "$pid" ]] || continue
  if kill -0 "$pid" 2>/dev/null; then ALIVE=$((ALIVE + 1)); kill "$pid" 2>/dev/null || true; fi
done <"$TMP_DIR/hang-pids"
assert_eq "0" "$ALIVE" "(a timed out git left a child running)"
assert_eq "6" "$(wc -l <"$TMP_DIR/hang-pids" | tr -d ' ')"
export PATH="$OLD_PATH"

# ---- a yes is kept for a few minutes, a no is asked again
unset FL_PROFILE_REACH_TTL
reset_calls
run_js profile check speedprof --json --bench-dir "$BENCH"
assert_eq "6" "$(printf '%s' "$OUT" | grep -o '"reachable":true' | wc -l | tr -d ' ')"
FIRST="$(grep -c 'ls-remote' "$MOCK_LOG" || true)"
assert_eq "6" "$FIRST" "(the first check asks each repo once)"
reset_calls
run_js profile check speedprof --json --bench-dir "$BENCH"
assert_eq "6" "$(printf '%s' "$OUT" | grep -o '"reachable":true' | wc -l | tr -d ' ')"
assert_eq "0" "$(grep -c 'ls-remote' "$MOCK_LOG" || true)" "(the second check asks nobody)"
# a repo without the branch is not kept as a yes
printf 'schema = 1\nbase = "v15-lts"\n\n[[apps]]\nname = "papp_0"\nrepo = "file://%s/papp_0.git"\nbranch = "nope"\n' "$REMOTES" >"$USER_DIR/nobranch.toml"
run_js profile check nobranch --json --bench-dir "$BENCH"
assert_eq "0" "$(printf '%s' "$OUT" | grep -o '"reachable":true' | wc -l | tr -d ' ')"
reset_calls
run_js profile check nobranch --json --bench-dir "$BENCH"
assert_eq "1" "$(grep -c 'ls-remote' "$MOCK_LOG" || true)" "(a no is asked again)"

echo "test-apps-speed: ok"
