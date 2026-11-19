#!/usr/bin/env bash
# The person guard of the commands only a person runs (#161, MAC-4): BENCHBAR_SUDO=gui and
# BENCHBAR_NONINTERACTIVE=0 lift the "needs a terminal" refusal of open-as, open --as --print-url,
# lan-guard and share only on macOS, only when BENCHBAR_APP_PID names a running ancestor of this
# CLI that is a BenchBar.app binary (fl_person_env_ok). The ps mock answers the process tree from
# $MOCK_STATE/pstree/PID ("PPID COMM"); FL_PERSON_SELF_PID is the pid the walk starts from (FL_TESTING=1).
# The harness gives every test the app tree: this CLI (4201) under a bash, under BenchBar.app (4200).
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
export BENCHBAR_LABS=lan-rooms
exec </dev/null

BENCH="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH" v16dev
printf 'port 11000\n' >"$BENCH/config/redis_queue.conf"; printf 'port 13000\n' >"$BENCH/config/redis_cache.conf"
printf '127.0.0.1 v16dev\n' >>"$FL_HOSTS_FILE"
printf '{\n "db_name": "_v16dev",\n "developer_mode": 1\n}\n' >"$BENCH/sites/v16dev/site_config.json"
cat >"$MOCK_STATE/users.json" <<'JSON'
[
 {"name": "priya@example.com", "full_name": "Priya Nair", "user_type": "System User", "enabled": 1, "roles": ["NE"], "last_login": null}
]
JSON
add_listener 8000 4242 python; add_listener 13000 4243 redis-server

APP=/Applications/BenchBar.app/Contents/MacOS/BenchBar
tree() { # PID "PPID COMM": one process of the mock tree
  printf '%s\n' "$2" >"$MOCK_STATE/pstree/$1"
}
tree_reset() { # the harness tree: this CLI (4201) under 4200, the app, whose parent is launchd
  find "$MOCK_STATE/pstree" -type f -delete
  tree 4200 "1 $APP"; tree 4201 "4200 /bin/bash"
}
open_as_off() { run_fm site open-as off v16dev --bench-dir "$BENCH"; }
open_as_on() { run_fm site open-as on v16dev --yes --bench-dir "$BENCH"; }
refused() { # WHAT: the last run was refused, said who counts, and wrote nothing
  assert_eq "1" "$CODE" "($1) $OUT"
  assert_contains "$OUT" "needs a person at a terminal" "($1)"
  assert_contains "$OUT" "counts only when the BenchBar app made the run" "($1)"
  if grep -rq OPEN_AS_SITES "$FL_STATE_DIR" 2>/dev/null; then fail "($1) a refused run left a record"; fi
}

# ---- the app's own run: BENCHBAR_APP_PID is the app, an ancestor whose executable is BenchBar.app
BENCHBAR_SUDO=gui open_as_on
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "Open as is on for v16dev"
open_as_off

# ---- the same words from a process that is not the app
(
  # no marker at all
  unset BENCHBAR_APP_PID
  BENCHBAR_SUDO=gui open_as_on; refused "no marker"; assert_contains "$OUT" "BENCHBAR_APP_PID is not set"
  # a marker that is not a process id
  BENCHBAR_APP_PID=abc BENCHBAR_SUDO=gui open_as_on; refused "abc"; assert_contains "$OUT" "is not a process id"
  BENCHBAR_APP_PID=0 BENCHBAR_SUDO=gui open_as_on; refused "zero"
  BENCHBAR_APP_PID='4200 4201' BENCHBAR_SUDO=gui open_as_on; refused "two ids"
  # a process that does not run
  BENCHBAR_APP_PID=999 BENCHBAR_SUDO=gui open_as_on; refused "no process"; assert_contains "$OUT" "names no running process"
  # a BenchBar.app that is not above this run (the app is open, the shell is a stranger's)
  tree 4300 "1 $APP"
  BENCHBAR_APP_PID=4300 BENCHBAR_SUDO=gui open_as_on; refused "not an ancestor"; assert_contains "$OUT" "is not above this command"
  # an ancestor that is not the app
  export BENCHBAR_APP_PID=4200
  tree 4200 "1 /usr/bin/python3"
  BENCHBAR_SUDO=gui open_as_on; refused "other executable"; assert_contains "$OUT" "is not a BenchBar.app process"
  tree 4200 "1 /Applications/Other.app/Contents/MacOS/BenchBar"
  BENCHBAR_SUDO=gui open_as_on; refused "other app"
  tree 4200 "1 /Applications/BenchBar.app/Contents/Resources/benchbar"
  BENCHBAR_SUDO=gui open_as_on; refused "a file of the app that is not its binary"
  tree 4200 "1 /tmp/BenchBar.app/Contents/MacOS"
  BENCHBAR_SUDO=gui open_as_on; refused "no file name"
) || exit 1

# ---- a deeper tree: the CLI under a shell under a script under the app; the walk stops at the app
tree_reset
tree 4201 "4202 /bin/bash"; tree 4202 "4203 /usr/bin/env"; tree 4203 "4200 /bin/zsh"
BENCHBAR_SUDO=gui open_as_on
assert_eq "0" "$CODE" "$OUT"
open_as_off
# a loop in the tree ends the walk (a process cannot be its own ancestor, but ps output is not ours)
tree 4201 "4202 /bin/bash"; tree 4202 "4201 /bin/bash"
BENCHBAR_SUDO=gui open_as_on; refused "a loop"
tree_reset

# ---- BENCHBAR_NONINTERACTIVE=0 lifts the print-url refusal only from the app, too
BENCHBAR_SUDO=gui open_as_on; assert_eq "0" "$CODE" "$OUT"
BENCHBAR_NONINTERACTIVE=0 run_fm open --as priya@example.com --print-url --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "sid=mocksid0123456789"
(
  unset BENCHBAR_APP_PID
  BENCHBAR_NONINTERACTIVE=0 run_fm open --as priya@example.com --print-url --json --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_not_contains "$OUT" "mocksid"
  assert_contains "$OUT" "counts only when the BenchBar app made the run"; assert_contains "$OUT" "BENCHBAR_NONINTERACTIVE=0"
  tree 4200 "1 /usr/bin/python3"
  BENCHBAR_NONINTERACTIVE=0 BENCHBAR_APP_PID=4200 run_fm open --as priya@example.com --print-url --json --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_not_contains "$OUT" "mocksid"
) || exit 1
tree_reset
# a terminal is a person: no marker, no tree
(
  unset BENCHBAR_APP_PID
  find "$MOCK_STATE/pstree" -type f -delete
  run_fm_tty open --as priya@example.com --print-url --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "sid=mocksid0123456789"
  open_as_off
  run_fm_tty site open-as on v16dev --yes --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
) || exit 1
tree_reset

# ---- lan-guard and share: the refusal stands without the app, and nothing ran
for env in "BENCHBAR_APP_PID=999" "BENCHBAR_APP_PID="; do
  reset_calls
  set +e; OUT="$(env "$env" BENCHBAR_SUDO=gui "$FM" lan-guard install --yes --bench-dir "$BENCH" 2>&1)"; CODE="$?"; set -e
  assert_eq "1" "$CODE" "($env lan-guard) $OUT"
  assert_contains "$OUT" "counts only when the BenchBar app made the run"; assert_contains "$OUT" "benchbar lan-guard install"
  assert_calls_not_contain '^(sudo|pfctl|osascript)' "($env lan-guard)"
  for sub in "share start" "share setup --users priya@example.com --acknowledge-data --yes" "share code" "share invite" "share teardown --yes"; do
    # shellcheck disable=SC2086  # the words of $sub are the arguments
    set +e; OUT="$(env "$env" BENCHBAR_SUDO=gui "$FM" $sub --bench-dir "$BENCH" 2>&1)"; CODE="$?"; set -e
    assert_eq "1" "$CODE" "($env $sub) $OUT"
    assert_contains "$OUT" "counts only when the BenchBar app made the run" "($env $sub)"
  done
done

# ---- Linux and WSL: the Windows tray's process is not visible from inside WSL, so the variables
# are taken as they are (a safety rail, not a boundary: AGENTS.md says so)
open_as_off
(
  unset BENCHBAR_APP_PID
  FL_PLATFORM=linux BENCHBAR_SUDO=gui open_as_on
  assert_eq "0" "$CODE" "$OUT"
) || exit 1
