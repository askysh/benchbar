#!/usr/bin/env bash
# CLI core reliability (#149): CORE-1 an unwritable state folder fails with its path instead of
# hanging, CORE-2 a failing command inside a function names itself, CORE-4 a command that changes
# things says which bench it guessed (and an agent is not allowed to guess among several), CORE-9
# no root, CORE-13 the run lock waits briefly and checks the start time of its owner, CORE-14 a
# signal gives children time to stop before KILL.
# shellcheck disable=SC2016  # the single quoted snippets expand inside the child bash
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# watchdog SECS COMMAND...: the command, or exit 124 when it runs longer (no timeout(1) on a Mac)
watchdog() { perl -e 'alarm shift; exec @ARGV' "$@"; }
sh_lib() { bash -c '. "$0/lib/frappe-local/ui.sh"; . "$0/lib/frappe-local/run.sh"; . "$0/lib/frappe-local/lock.sh"; FL_PLAIN=1; fl_ui_init; '"$1" "$ROOT" "${@:2}"; }
gone() {
  local i st
  for i in $(seq 1 50); do
    kill -0 "$1" 2>/dev/null || return 0
    st="$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')"
    [[ "$st" == Z* ]] && return 0
    sleep 0.1
  done
  return 1
}

# ---------------------------------------------------------------- CORE-1: no endless loop
BENCH="$HOME/frappe-bench"; make_fake_bench "$BENCH"
# the folder of a per bench state file is a file: the first write of a value named the path and
# did not hang (it used to end with bash's own "Not a directory", or spin)
rm -rf "$FL_STATE_DIR/benches"; : >"$FL_STATE_DIR/benches"
set +e; OUT="$(watchdog 20 "$FM" ports mode fixed --bench-dir "$BENCH" 2>&1)"; CODE=$?; set -e
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "$FL_STATE_DIR/benches" "(the path)"
assert_contains "$OUT" "not a folder"
rm -f "$FL_STATE_DIR/benches"
# a read only folder with a state file in it (a root owned folder after a sudo run); root itself
# ignores the mode bits, so only a normal user can make this one
if [[ "$(id -u)" != 0 ]]; then
  RO="$TMP_DIR/ro-state"; mkdir -p "$RO"; printf 'A=1\n' >"$RO/kv.env"; chmod 555 "$RO"
  set +e; OUT="$(watchdog 20 bash -c '. "$0/lib/frappe-local/ui.sh"; . "$0/lib/frappe-local/state.sh"; FL_PLAIN=1; fl_ui_init; fl_kv_set "$1" B 2' "$ROOT" "$RO/kv.env" 2>&1)"; CODE=$?; set -e
  chmod 755 "$RO"
  assert_eq "1" "$CODE" "$OUT"
  assert_contains "$OUT" "$RO" "(the path)"
  assert_contains "$OUT" "not writable"
fi

# ---------------------------------------------------------------- CORE-2: a failure in a function is named
# the entrypoint runs with errtrace (set -E), so its ERR trap is inherited into functions
grep -qE '^set -[A-Za-z]*E[A-Za-z]* *|^set -[A-Za-z]*e[A-Za-z]*E' "$FM" || grep -q '^set -E$' "$FM" || fail "benchbar must turn errtrace on (set -E)"
cat >"$TMP_DIR/err.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$1"
. "$SCRIPT_DIR/lib/frappe-local/ui.sh"; . "$SCRIPT_DIR/lib/frappe-local/run.sh"
FL_PLAIN=1; fl_ui_init
trap 'fl_on_error "$BASH_COMMAND"' ERR
step() {
  # a guarded failure says nothing, a failure in a substitution is the caller's
  v="$(false)" || true
  if ! mkdir /nonexistent-benchbar/a/b 2>/dev/null; then :; fi
  w="$(grep -c zz /dev/null || true)"
  mkdir /nonexistent-benchbar/a/b
  echo not-reached
}
step
SH
set +e; OUT="$(bash "$TMP_DIR/err.sh" "$ROOT" 2>&1)"; CODE=$?; set -e
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "[FAIL] Command failed (exit 1): mkdir /nonexistent-benchbar/a/b"
assert_contains "$OUT" "in step" "(the function)"
assert_contains "$OUT" "err.sh" "(the file)"
assert_not_contains "$OUT" "not-reached"
assert_eq "1" "$(grep -c 'Command failed' <<<"$OUT")" "(one line, not one per guarded failure)"
# an exit code 2 of a stray command is still reported as 1
cat >"$TMP_DIR/err2.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
. "$1/lib/frappe-local/ui.sh"; . "$1/lib/frappe-local/run.sh"
FL_PLAIN=1; fl_ui_init
trap 'fl_on_error "$BASH_COMMAND"' ERR
f() { grep -q x /nonexistent-benchbar-file; }
f
SH
set +e; OUT="$(bash "$TMP_DIR/err2.sh" "$ROOT" 2>&1)"; CODE=$?; set -e
assert_eq "1" "$CODE" "$OUT"

# a failure the caller handles stays silent: a loop that collects the exit status of a
# subshell or a function under set +e (uninstall-service --all does), an `if !`, an `||`.
# The ERR trap fires for the first two all the same, so fl_on_error looks at errexit
cat >"$TMP_DIR/err3.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
. "$1/lib/frappe-local/ui.sh"; . "$1/lib/frappe-local/run.sh"
FL_PLAIN=1; fl_ui_init
trap 'fl_on_error "$BASH_COMMAND"' ERR
inner() { mkdir /nonexistent-benchbar/a/b 2>/dev/null; return 3; }
one_bench() { set -e; inner; echo not-reached-in-subshell; }
step() {
  local rc n=0 d
  for d in a b c; do
    set +e
    (one_bench)
    rc=$?
    set -e
    [[ "$rc" == "0" ]] || n=$((n + 1))
  done
  echo "collected ${n} of 3"
  set +e; inner; rc=$?; set -e
  echo "function rc=${rc}"
  if ! (inner); then echo "handled by if"; fi
  v="$(inner)" || v=fallback
  echo "handled by ||: ${v}"
}
step
echo finished
mkdir /nonexistent-benchbar/a/b
echo not-reached
SH
set +e; OUT="$(bash "$TMP_DIR/err3.sh" "$ROOT" 2>&1)"; CODE=$?; set -e
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "collected 3 of 3"
assert_contains "$OUT" "function rc=3"
assert_contains "$OUT" "handled by if"
assert_contains "$OUT" "handled by ||: fallback"
assert_contains "$OUT" "finished"
assert_not_contains "$OUT" "not-reached"
assert_eq "1" "$(grep -c 'Command failed' <<<"$OUT")" "(only the unhandled failure after the handled ones is reported)"
assert_contains "$OUT" "mkdir /nonexistent-benchbar/a/b"

# ---------------------------------------------------------------- CORE-4: a guessed bench is named
mkdir -p "$HOME/dev"
make_fake_bench "$HOME/dev/frappe-bench" other
rm -f "$FL_STATE_FILE"; rm -rf "$FL_STATE_DIR/benches"
# one bench found, the person is told which and why
run_fm down --dry-run
assert_contains "$OUT" "acting on $BENCH" "(a guessed bench is named)"
assert_contains "$OUT" "auto-detected"
# several benches and nobody to ask: agents and scripts must name one
for flag in --for-agent ""; do
  # shellcheck disable=SC2086
  BENCHBAR_NONINTERACTIVE=1 run_fm down --dry-run $flag
  assert_eq "1" "$CODE" "$OUT"
  assert_contains "$OUT" "$BENCH" "(both benches are named)"
  assert_contains "$OUT" "$HOME/dev/frappe-bench"
  assert_contains "$OUT" "--bench-dir"
done
# with the flag, the environment or a remembered bench nothing is guessed
BENCHBAR_NONINTERACTIVE=1 run_fm down --dry-run --bench-dir "$BENCH"
assert_not_contains "$OUT" "auto-detected"; assert_eq "0" "$CODE" "$OUT"
BENCH_DIR="$BENCH" BENCHBAR_NONINTERACTIVE=1 run_fm down --dry-run
assert_not_contains "$OUT" "auto-detected"; assert_eq "0" "$CODE" "$OUT"
# a command that only reads never stops, and says nothing
BENCHBAR_NONINTERACTIVE=1 run_fm status
assert_not_contains "$OUT" "auto-detected"; assert_eq "0" "$CODE" "$OUT"
# the stream of a command that changes things keeps its stdout JSON; the note is on stderr
out="$("$FM" down --dry-run --json 2>/dev/null)" && code=0 || code=$?
assert_eq "0" "$code"; assert_not_contains "$out" "auto-detected"
rm -rf "$HOME/dev/frappe-bench"

# ---------------------------------------------------------------- CORE-9: not as root
FL_EFFECTIVE_UID=0 run_fm status --bench-dir "$BENCH"
assert_eq "64" "$CODE" "$OUT"
assert_contains "$OUT" "Do not run benchbar as root"
assert_contains "$OUT" "asks for sudo itself"
FL_EFFECTIVE_UID=0 run_fm down --dry-run --bench-dir "$BENCH"; assert_eq "64" "$CODE" "$OUT"
FL_EFFECTIVE_UID=0 run_fm --version; assert_eq "0" "$CODE" "(the version needs no account)"
FL_EFFECTIVE_UID=0 run_fm --help; assert_eq "0" "$CODE"
# a client that asked for JSON gets JSON (exit 64, error_id root_refused), on stdout alone
out="$(FL_EFFECTIVE_UID=0 FL_TESTING=1 "$FM" status --json --bench-dir "$BENCH" 2>/dev/null)" && code=0 || code=$?
assert_eq "64" "$code" "$out"
assert_eq "root_refused" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["error_id"])')" "$out"
assert_eq "64" "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["exit"])')" "$out"
assert_contains "$out" "Do not run benchbar as root"
assert_contains "$out" "asks for sudo itself"
out="$(FL_EFFECTIVE_UID=0 FL_TESTING=1 "$FM" down --dry-run --for-agent --bench-dir "$BENCH" 2>/dev/null)" && code=0 || code=$?
assert_eq "64" "$code" "$out"
assert_contains "$out" '"event":"done"'
assert_contains "$out" '"error_id":"root_refused"'
out="$(FL_EFFECTIVE_UID=0 FL_TESTING=1 "$FM" status --jsonl --bench-dir "$BENCH" 2>/dev/null)" && code=0 || code=$?
assert_eq "64" "$code" "$out"
assert_contains "$out" '"event":"done"'
# without a JSON flag it is the text, and the exit is the same
out="$(FL_EFFECTIVE_UID=0 FL_TESTING=1 "$FM" status --bench-dir "$BENCH" 2>&1)" && code=0 || code=$?
assert_not_contains "$out" "error_id"; assert_eq "64" "$code"
# the seam is for the tests: a production run (no FL_TESTING) reads the real uid
out="$(env -u FL_TESTING FL_EFFECTIVE_UID=0 "$FM" status --bench-dir "$BENCH" 2>&1)" && code=0 || code=$?
assert_not_contains "$out" "Do not run benchbar as root"

# ---------------------------------------------------------------- CORE-13: the run lock
LOCK="$TMP_DIR/lock13"
# a holder that lets go after a second: the second run waits and gets it, and says what it waits for
sleep 30 &
HOLDER=$!
mkdir -p "$LOCK"; printf '%s\n' "$HOLDER" >"$LOCK/pid"
sh_lib 'fl__lock_start_v s "$2"; printf "%s" "$s" >"$1/pstart"' "$LOCK" "$HOLDER"
printf 'up \t2026-11-19T10:00:00Z\n' >"$LOCK/info"
# the holder lets go once the second run says it waits (a second at the earliest): on a loaded
# machine the second run can need more than a second to start, and a lock that was gone by
# then was taken with no wait and no message
WAITLOG="$TMP_DIR/lock13.out"; : >"$WAITLOG"
( sleep 1; for _ in $(seq 1 70); do grep -q 'Waiting for' "$WAITLOG" 2>/dev/null && break; sleep 0.1; done; rm -rf "$LOCK" ) &
set +e; FL_LOCK_WAIT_SECS=8 sh_lib 'fl_lock_acquire "$1" && printf "held by %s\n" "$(cat "$1/pid")"' "$LOCK" >"$WAITLOG" 2>&1; CODE=$?; set -e
OUT="$(cat "$WAITLOG")"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "Waiting for benchbar up, started 2026-11-19T10:00:00Z (pid ${HOLDER})"
assert_contains "$OUT" "held by"
rm -rf "$LOCK"
# a holder that stays: the wait ends with the same message as before
mkdir -p "$LOCK"; printf '%s\n' "$HOLDER" >"$LOCK/pid"
sh_lib 'fl__lock_start_v s "$2"; printf "%s" "$s" >"$1/pstart"' "$LOCK" "$HOLDER"
set +e; OUT="$(FL_LOCK_WAIT_SECS=1 sh_lib 'fl_lock_acquire "$1"' "$LOCK" 2>&1)"; CODE=$?; set -e
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "Another benchbar run is active (pid ${HOLDER})"
# a live pid that started at another time is not the holder: the pid came round again
printf '%s' "Mon Jan  1 00:00:00 1990" >"$LOCK/pstart"
set +e; OUT="$(FL_LOCK_WAIT_SECS=0 sh_lib 'fl_lock_acquire "$1" && printf "held by %s\n" "$(cat "$1/pid")"' "$LOCK" 2>&1)"; CODE=$?; set -e
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "Reclaiming stale lock left by pid ${HOLDER}"
rm -rf "$LOCK"
# a lock written by an older benchbar (no start time) is judged by its pid alone, as before
mkdir -p "$LOCK"; printf '%s\n' "$HOLDER" >"$LOCK/pid"
set +e; OUT="$(FL_LOCK_WAIT_SECS=0 sh_lib 'fl_lock_acquire "$1"' "$LOCK" 2>&1)"; CODE=$?; set -e
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "Another benchbar run is active (pid ${HOLDER})"
rm -rf "$LOCK"
# the lock records the start time of its holder
sh_lib 'fl_lock_acquire "$1"; [[ -s "$1/pstart" ]] && printf "pstart ok"' "$LOCK" >"$TMP_DIR/o" 2>&1; assert_contains "$(cat "$TMP_DIR/o")" "pstart ok"
# the start time does not depend on the caller's time zone: a lock taken in one zone still names
# its live owner after the zone (or DST) changes, so a live run is never reclaimed as stale
T_NY="$(TZ=America/New_York sh_lib 'fl__lock_start_v s "$1"; printf "%s" "$s"' "$HOLDER")"
T_IN="$(TZ=Asia/Kolkata sh_lib 'fl__lock_start_v s "$1"; printf "%s" "$s"' "$HOLDER")"
[[ -n "$T_NY" ]] || fail "no start time for the live holder"
assert_eq "$T_NY" "$T_IN" "(the start time must not follow TZ)"
mkdir -p "$LOCK"; printf '%s\n' "$HOLDER" >"$LOCK/pid"
TZ=America/New_York sh_lib 'fl__lock_start_v s "$2"; printf "%s" "$s" >"$1/pstart"' "$LOCK" "$HOLDER"
set +e; OUT="$(TZ=Asia/Kolkata FL_LOCK_WAIT_SECS=0 sh_lib 'fl_lock_acquire "$1"' "$LOCK" 2>&1)"; CODE=$?; set -e
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "Another benchbar run is active (pid ${HOLDER})"
rm -rf "$LOCK"
kill -KILL "$HOLDER"; wait "$HOLDER" 2>/dev/null || true
# a state folder that is a file: the message names that, not a busy lock
: >"$TMP_DIR/afile"
set +e; OUT="$(sh_lib 'fl_lock_acquire "$1"' "$TMP_DIR/afile/lock" 2>&1)"; CODE=$?; set -e
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "$TMP_DIR/afile is not a folder"
assert_not_contains "$OUT" "keeps taking it"

# ---------------------------------------------------------------- CORE-14: signals give children time
# a command that cleans up for a second and a half after TERM is not KILLed after one second
CLEAN="$TMP_DIR/cleaned"; rm -f "$CLEAN"
cat >"$TMP_DIR/graceful.sh" <<'SH'
#!/usr/bin/env bash
trap 'sleep 1.5; echo cleaned >"$1"; exit 0' TERM
: >"$1.ready"
while :; do sleep 0.2; done
SH
chmod +x "$TMP_DIR/graceful.sh"
# the TERM comes once the command has its trap (a loaded machine starts it late, and a TERM
# before the trap ends it with no cleanup)
sh_lib 'FL_KILL_GRACE=8; fl_run_bg_group "$2" "$3" "$4"; w=0; while [[ ! -f "$4.ready" && "$w" -lt 100 ]]; do sleep 0.1; w=$((w + 1)); done; fl_run_group_kill' "$ROOT" "$TMP_DIR/g.log" "$TMP_DIR/graceful.sh" "$CLEAN"
assert_file "$CLEAN" "(the command finished its cleanup before the KILL)"
# the grace is not slept when the group is gone at once
cat >"$TMP_DIR/quick.sh" <<'SH'
#!/usr/bin/env bash
while :; do sleep 0.2; done
SH
chmod +x "$TMP_DIR/quick.sh"
T0=$SECONDS
sh_lib 'FL_KILL_GRACE=10; fl_run_bg_group "$2" "$3"; sleep 0.5; fl_run_group_kill' "$ROOT" "$TMP_DIR/q.log" "$TMP_DIR/quick.sh"
[[ $((SECONDS - T0)) -le 3 ]] || fail "a group that ends at TERM must not be waited for the whole grace ($((SECONDS - T0)) s)"
# one that ignores TERM is KILLed when the grace is over
cat >"$TMP_DIR/stubborn.sh" <<'SH'
#!/usr/bin/env bash
trap '' TERM
printf '%s\n' "$$" >"$1"
while :; do sleep 0.2; done
SH
chmod +x "$TMP_DIR/stubborn.sh"
rm -f "$TMP_DIR/stubborn.pid"
sh_lib 'FL_KILL_GRACE=1; fl_run_bg_group "$2" "$3" "$4"; sleep 0.5; fl_run_group_kill' "$ROOT" "$TMP_DIR/s.log" "$TMP_DIR/stubborn.sh" "$TMP_DIR/stubborn.pid"
gone "$(cat "$TMP_DIR/stubborn.pid")" || fail "a command that ignores TERM must be KILLed after the grace"
# the temp log of a long command is removed when a signal ends the run (the EXIT trap does it)
grep -q 'fl_tmp_cleanup' "$FM" || fail "benchbar's exit trap must remove the temp logs it registered"
SLOWSH="$TMP_DIR/slow14"; printf '#!/usr/bin/env bash\nsleep 60\n' >"$SLOWSH"; chmod +x "$SLOWSH"
mkdir -p "$TMP_DIR/tmp14"
TMPDIR="$TMP_DIR/tmp14" bash -c '. "$0/lib/frappe-local/ui.sh"; . "$0/lib/frappe-local/run.sh"; FL_PLAIN=1; fl_ui_init
  trap fl_tmp_cleanup EXIT; fl_signal_traps_install; FL_KILL_GRACE=0; fl_run_long slow "$1"' "$ROOT" "$SLOWSH" >/dev/null 2>&1 &
RUNNER=$!
for _ in $(seq 1 50); do ls "$TMP_DIR"/tmp14/benchbar-cmd.* >/dev/null 2>&1 && break; sleep 0.1; done
ls "$TMP_DIR"/tmp14/benchbar-cmd.* >/dev/null 2>&1 || fail "test setup: the temp log of fl_run_long is not there"
kill -TERM "$RUNNER"
set +e; wait "$RUNNER"; set -e
if ls "$TMP_DIR"/tmp14/benchbar-cmd.* >/dev/null 2>&1; then fail "the temp log of fl_run_long must be removed after a TERM"; fi
# a command that ends at once is seen at once: the wait starts with 20 ms pauses, never a full
# second (issue 137: a fixed "sleep 1" was 40 percent of the pull and app tests, and up to a second
# on every bench command a person runs), and both runners share the pauses
mkdir -p "$TMP_DIR/bin15"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s"\nexec /bin/sleep "$@"\n' "$TMP_DIR/sleeps15" >"$TMP_DIR/bin15/sleep"; chmod +x "$TMP_DIR/bin15/sleep"
QUICK="$TMP_DIR/quick15"; printf '#!/bin/bash\n/bin/sleep 0.15\n' >"$QUICK"; chmod +x "$QUICK"
for runner in "fl_run_long quick" "fl_run_with_timeout 30 quick"; do
  : >"$TMP_DIR/sleeps15"
  PATH="$TMP_DIR/bin15:$PATH" TMPDIR="$TMP_DIR/tmp14" bash -c '. "$0/lib/frappe-local/ui.sh"; . "$0/lib/frappe-local/run.sh"; FL_PLAIN=1; fl_ui_init
    trap fl_tmp_cleanup EXIT; '"$runner"' "$1"' "$ROOT" "$QUICK" >/dev/null 2>&1 || fail "$runner: a quick command must succeed"
  grep -q -x '0.02' "$TMP_DIR/sleeps15" || fail "$runner: the first pauses of the wait must be 20 ms"$'\n'"$(cat "$TMP_DIR/sleeps15")"
  if grep -q -x -E '1|0\.5' "$TMP_DIR/sleeps15"; then fail "$runner: a command of 150 ms must not be waited on with a long pause"$'\n'"$(cat "$TMP_DIR/sleeps15")"; fi
done

echo "ok"
