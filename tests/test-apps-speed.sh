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
if [[ " \$* " == *" ls-remote "* ]]; then
  [[ -n "\${SPEED_STARTS:-}" ]] && printf '%s %s\\n' "\$(date +%s)" "\$*" >>"\$SPEED_STARTS"
  if [[ -n "\${SPEED_FAKE_OK:-}" ]]; then printf 'abc123\\trefs/heads/main\\n'; exit 0; fi
fi
if [[ " \$* " == *" ls-remote "* && -n "\${SPEED_SYNC:-}" ]]; then
  : >"\$SPEED_SYNC/started.\$\$"
  for _ in \$(seq 1 40); do
    n=0
    for f in "\$SPEED_SYNC"/started.*; do [[ -e "\$f" ]] && n=\$((n + 1)); done
    [[ \$n -ge 3 ]] && { : >"\$SPEED_SYNC/together.\$\$"; break; }
    sleep 0.2
  done
fi
if [[ " \$* " == *" ls-remote "* && -n "\${SPEED_HANG:-}" && " \$* " == *"\${SPEED_HANG_MATCH:-}"* ]]; then
  sleep 60 &
  printf '%s %s %s\\n' "\$\$" "\$!" "\$(date +%s)" >>"\$SPEED_HANG"
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

# alive PIDFILE MIN_AGE: how many recorded processes ("shell sleep epoch" per
# line, both pids) that started at least MIN_AGE seconds ago still run; kills them
alive_hang_pids() {
  local f="$1" min="$2" sh sl at now n=0 p
  now="$(date +%s)"
  while read -r sh sl at; do
    [[ -n "$sh" && $((now - at)) -ge "$min" ]] || continue
    for p in "$sh" "$sl"; do
      if kill -0 "$p" 2>/dev/null; then n=$((n + 1)); kill "$p" 2>/dev/null || true; fi
    done
  done <"$f"
  printf '%s' "$n"
}

# a hanging ls-remote is cut after FL_PROFILE_NET_SECS and takes its children
# along. Checked while profile check still runs (two repos at a time, so the
# command outlives the first timeouts): a git that only dies when benchbar
# exits is not cut. The first two repos have been timed out for 3 s: no
# process of theirs may be left, though benchbar is still waiting for the rest.
export SPEED_HANG="$TMP_DIR/hang-pids" FL_PROFILE_NET_SECS=1 FL_PROFILE_JOBS=2
: >"$SPEED_HANG"
"$FM" profile check speedprof --json --bench-dir "$BENCH" >"$TMP_DIR/hang.out" 2>"$TMP_DIR/hang.err" &
HANG_PID="$!"
sleep 3
kill -0 "$HANG_PID" 2>/dev/null || fail "profile check ended before the liveness check (test needs it to run)"
LIVE="$(alive_hang_pids "$SPEED_HANG" 2)"
assert_eq "0" "$LIVE" "(a timed out git is still running while profile check runs)"
set +e; wait "$HANG_PID"; CODE="$?"; set -e
OUT="$(cat "$TMP_DIR/hang.out")"; ERR="$(cat "$TMP_DIR/hang.err")"
unset SPEED_HANG FL_PROFILE_NET_SECS FL_PROFILE_JOBS
assert_eq "0" "$CODE" "$OUT $ERR"
assert_eq "0" "$(printf '%s' "$OUT" | grep -o '"reachable":true' | wc -l | tr -d ' ')" "(none answered) $OUT"
assert_contains "$OUT" "timed out after 1s"
assert_not_contains "$ERR" "Terminated" "(the shell's job message is not shown)"
sleep 1
assert_eq "0" "$(alive_hang_pids "$TMP_DIR/hang-pids" 0)" "(a timed out git left a process running)"
assert_eq "6" "$(wc -l <"$TMP_DIR/hang-pids" | tr -d ' ')"

# a slot is refilled when any job ends, not when the oldest one does: the first
# repo hangs for 4 s, two jobs at a time; the other five must start long
# before it is cut (the oldest first pool starts the third repo after 4 s)
export SPEED_HANG="$TMP_DIR/hang-pids2" SPEED_HANG_MATCH="papp_0.git" SPEED_STARTS="$TMP_DIR/starts" FL_PROFILE_NET_SECS=4 FL_PROFILE_JOBS=2 FL_KILL_GRACE=0
: >"$SPEED_HANG"; : >"$SPEED_STARTS"
run_js profile check speedprof --json --bench-dir "$BENCH"
unset SPEED_HANG SPEED_HANG_MATCH SPEED_STARTS FL_PROFILE_NET_SECS FL_PROFILE_JOBS FL_KILL_GRACE
assert_eq "5" "$(printf '%s' "$OUT" | grep -o '"reachable":true' | wc -l | tr -d ' ')" "(the five others answered) $OUT $ERR"
FIRST_AT="$(awk 'index($0, "papp_0.git") {print $1; exit}' "$TMP_DIR/starts")"
LAST_AT="$(awk '{print $1}' "$TMP_DIR/starts" | sort -n | tail -1)"
[[ $((LAST_AT - FIRST_AT)) -le 2 ]] || fail "the last repo was asked $((LAST_AT - FIRST_AT)) s after the first: a free slot waited for the hanging repo"

# INT or TERM to benchbar while the checks run stops the background groups too
export SPEED_HANG="$TMP_DIR/hang-pids3" FL_PROFILE_NET_SECS=30 FL_PROFILE_JOBS=6
: >"$SPEED_HANG"
"$FM" profile check speedprof --json --bench-dir "$BENCH" >"$TMP_DIR/sig.out" 2>"$TMP_DIR/sig.err" &
SIG_PID="$!"
for _ in $(seq 1 50); do [[ "$(wc -l <"$SPEED_HANG" | tr -d ' ')" -ge 6 ]] && break; sleep 0.1; done
assert_eq "6" "$(wc -l <"$SPEED_HANG" | tr -d ' ')" "(all six repos were being asked before the signal)"
kill -TERM "$SIG_PID"
for _ in $(seq 1 60); do kill -0 "$SIG_PID" 2>/dev/null || break; sleep 0.1; done
kill -0 "$SIG_PID" 2>/dev/null && { kill -KILL "$SIG_PID" 2>/dev/null || true; fail "benchbar did not stop on TERM within 6 s"; }
set +e; wait "$SIG_PID"; CODE="$?"; set -e
unset SPEED_HANG FL_PROFILE_NET_SECS FL_PROFILE_JOBS
assert_eq "143" "$CODE" "(TERM ends the run with 143)"
sleep 0.5
assert_eq "0" "$(alive_hang_pids "$TMP_DIR/hang-pids3" 0)" "(a git of the pool outlived the TERM to benchbar)"
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

# a yes kept for a few minutes does not carry install: it asks the network again
# before it plans anything, and a branch deleted in between stops it with a message
git --git-dir="$REMOTES/papp_0.git" branch keepme main
printf 'schema = 1\nbase = "v15-lts"\nsite = "del.localhost"\n\n[[apps]]\nname = "papp_0"\nrepo = "file://%s/papp_0.git"\nbranch = "keepme"\n' "$REMOTES" >"$USER_DIR/delprof.toml"
run_js profile check delprof --json --bench-dir "$BENCH"
assert_eq "1" "$(printf '%s' "$OUT" | grep -o '"reachable":true' | wc -l | tr -d ' ')" "$OUT $ERR"
git --git-dir="$REMOTES/papp_0.git" branch -D keepme >/dev/null
reset_calls
run_js profile check delprof --json --bench-dir "$BENCH"
assert_eq "1" "$(printf '%s' "$OUT" | grep -o '"reachable":true' | wc -l | tr -d ' ')" "(inside the few minutes the kept yes answers: that is the documented window)"
assert_eq "0" "$(grep -c 'ls-remote' "$MOCK_LOG" || true)" "(profile check did not ask again)"
add_proc 900 "mariadbd --datadir=/x"; add_proc 901 "redis-server *:6379"
printf 'mariadb@10.11 started akash file\nredis started akash file\n' >"$MOCK_BREW_SERVICES"
touch "$MOCK_STATE/wkhtml_installed"; printf rootpw >"$MOCK_STATE/mariadb_root_pw"
reset_calls
MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw run_fm install --yes --profile delprof --bench-dir "$HOME/del-bench"
[[ "$CODE" != "0" ]] || fail "install went on although the branch of papp_0 was deleted: $OUT"
assert_contains "$OUT" "Branch/tag 'keepme' not found for papp_0"
assert_contains "$OUT" "Check the app repo"
assert_not_contains "${OUT#*Branch/tag \'keepme\' not found}" "========== PLAN" "(install stops before phase 01 shows its plan)"
assert_calls_not_contain 'bench (init|get-app|new-site)'
assert_calls_contain 'ls-remote .*keepme'

# the cache file keeps no token or user name of a URL and is 0600 (a profile file
# refuses such a URL, but a remote of a bench or a typed URL can carry one)
remember() { bash -c '. "$0/lib/frappe-local/ui.sh"; . "$0/lib/frappe-local/profiles.sh"; "$@"' "$ROOT" "$@"; }
RC_FILE="$FL_STATE_DIR/reach-cache"
: >"$RC_FILE"
chmod 644 "$RC_FILE"
remember fl_profile_reach_remember "https://octo:s3cr3tt0ken@github.com/acme/tokapp.git" main
assert_not_contains "$(cat "$RC_FILE")" "s3cr3tt0ken" "(the cache keeps a token)"
assert_not_contains "$(cat "$RC_FILE")" "octo" "(the cache keeps a user name)"
assert_contains "$(cat "$RC_FILE")" "https://github.com/acme/tokapp.git"
assert_eq "600" "$(stat -f '%Lp' "$RC_FILE" 2>/dev/null || stat -c '%a' "$RC_FILE")" "(the cache is readable by its owner only, an old 0644 file is closed)"
# the same repo with another token is the same answer
remember fl_profile_reach_cached "https://other:0therT0ken@github.com/acme/tokapp.git" main || fail "a kept yes was not found by the URL without its userinfo"
remember fl_profile_reach_cached "https://github.com/acme/tokapp.git" other && fail "another branch is not the same answer"
# a new cache file is created 0600
unlink "$RC_FILE"
remember fl_profile_reach_remember "https://github.com/acme/tokapp.git" main
assert_eq "600" "$(stat -f '%Lp' "$RC_FILE" 2>/dev/null || stat -c '%a' "$RC_FILE")" "(a new cache is created 0600)"

echo "test-apps-speed: ok"
