#!/usr/bin/env bash
# The run lock: a live holder refuses, a killed holder's lock is reclaimed,
# an empty lock inside its grace period is not, N reclaimers of one stale
# lock leave exactly one winner, the bench's own lock meets CLIs with
# different state folders, a TERM during fl_run_long ends the grandchild
# before the lock goes, and two runs in one second get their own log and
# backup folders.
# shellcheck disable=SC2016  # the single quoted snippets expand inside the child bash
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# a shell with the lock library and a quiet ui
lockshell() { bash -c '. "$0/lib/frappe-local/ui.sh"; . "$0/lib/frappe-local/lock.sh"; FL_PLAIN=1; fl_ui_init; '"$1" "$ROOT" "${@:2}"; }
LOCK="$FL_STATE_DIR/lock"
# gone PID: true once PID is no process, or a zombie init has not reaped yet
# (a killed orphan under load); waits up to 3 seconds
gone() {
  local i st
  for i in $(seq 1 30); do
    kill -0 "$1" 2>/dev/null || return 0
    st="$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')"
    [[ "$st" == Z* ]] && return 0
    sleep 0.1
  done
  return 1
}

# ---- a live holder refuses, a holder killed with KILL leaves a reclaimable lock
sleep 30 &
HOLDER=$!
mkdir -p "$LOCK"; printf '%s\n' "$HOLDER" >"$LOCK/pid"
set +e; OUT="$(lockshell 'fl_lock_acquire "$1"' "$LOCK" 2>&1)"; CODE=$?; set -e
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "Another benchbar run is active (pid ${HOLDER})"
kill -KILL "$HOLDER"; wait "$HOLDER" 2>/dev/null || true
set +e; OUT="$(lockshell 'fl_lock_acquire "$1" && printf "held by %s\n" "$(cat "$1/pid")"' "$LOCK" 2>&1)"; CODE=$?; set -e
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "Reclaiming stale lock left by pid ${HOLDER}"
assert_contains "$OUT" "held by"
[[ -z "$(ls -d "$LOCK".stale.* 2>/dev/null)" ]] || fail "the renamed stale lock must be removed"
rm -rf "$LOCK"

# ---- an empty lock (pid not written yet) inside the grace period is a run that is starting
mkdir -p "$LOCK"
set +e; OUT="$(lockshell 'fl_lock_acquire "$1"' "$LOCK" 2>&1)"; CODE=$?; set -e
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "Another benchbar run is starting"
[[ -d "$LOCK" ]] || fail "a fresh empty lock must not be reclaimed"
# past the grace period it is stale
set +e; OUT="$(FL_LOCK_GRACE_SECS=0 lockshell 'fl_lock_acquire "$1"' "$LOCK" 2>&1)"; CODE=$?; set -e
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "Reclaiming stale lock left by pid unknown"
rm -rf "$LOCK"

# ---- N runs against one stale lock: exactly one wins, the others are refused by its pid
mkdir -p "$LOCK"; printf '999999\n' >"$LOCK/pid"
WINS="$TMP_DIR/wins"; : >"$WINS"
for i in 1 2 3 4 5 6; do
  lockshell 'if fl_lock_acquire "$1" 2>/dev/null; then printf "%s\n" "$$" >>"$2"; sleep 2; fl_lock_release; fi' "$LOCK" "$WINS" >/dev/null 2>&1 &
done
wait
assert_eq "1" "$(grep -c . "$WINS")" "(one winner among the reclaimers: $(cat "$WINS"))"
assert_no_file "$LOCK" "(the winner released its lock)"
[[ -z "$(ls -d "$LOCK".stale.* 2>/dev/null)" ]] || fail "no stale folder may be left behind"

# ---- the bench's own lock: a CLI with another state folder is refused on the same bench
BENCH="$HOME/frappe-bench"; make_fake_bench "$BENCH"
run_fm service --yes --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
assert_no_file "$BENCH/.benchbar.lock" "(released at exit)"
sleep 30 &
HOLDER=$!
mkdir -p "$BENCH/.benchbar.lock"; printf '%s\n' "$HOLDER" >"$BENCH/.benchbar.lock/pid"
OTHER_STATE="$TMP_DIR/other-state"; mkdir -p "$OTHER_STATE"
FL_STATE_DIR="$OTHER_STATE" FL_STATE_FILE="$OTHER_STATE/state.env" run_fm service --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "Another benchbar run is active on this bench (pid ${HOLDER})"
assert_no_file "$OTHER_STATE/lock" "(the state lock is released on the way out)"
# read only commands never take it
run_fm status --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
run_fm doctor --bench-dir "$BENCH"
kill -KILL "$HOLDER"; wait "$HOLDER" 2>/dev/null || true
rm -rf "$BENCH/.benchbar.lock"
# a dry run takes no lock at all
run_fm service --dry-run --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
assert_no_file "$BENCH/.benchbar.lock"

# ---- TERM during fl_run_long: the grandchild dies with the command, and the
# lock is released only after that (the EXIT trap runs last)
SLOW="$TMP_DIR/slow-with-child"
cat >"$SLOW" <<'SH'
#!/usr/bin/env bash
# a command whose child outlives it unless its process group is signalled
sleep 60 &
printf '%s\n' "$!" >"$1"
wait
SH
chmod +x "$SLOW"
GRANDCHILD="$TMP_DIR/grandchild.pid"; TRACE="$TMP_DIR/trace"; : >"$TRACE"
bash -c '. "$0/lib/frappe-local/ui.sh"; . "$0/lib/frappe-local/run.sh"; . "$0/lib/frappe-local/lock.sh"
  FL_PLAIN=1; fl_ui_init
  fl_lock_acquire "$1"
  trap "fl_lock_release; printf lock-released >>\"$3\"" EXIT
  fl_signal_traps_install
  fl_run_long "slow" "$2" "$4"' "$ROOT" "$LOCK" "$SLOW" "$TRACE" "$GRANDCHILD" >/dev/null 2>&1 &
RUNNER=$!
for _ in $(seq 1 50); do [[ -s "$GRANDCHILD" ]] && break; sleep 0.1; done
[[ -s "$GRANDCHILD" ]] || fail "test setup: the grandchild did not start"
GC="$(cat "$GRANDCHILD")"
kill -0 "$GC" || fail "test setup: grandchild ${GC} not running"
[[ -d "$LOCK" ]] || fail "test setup: the lock is held during the run"
kill -TERM "$RUNNER"
set +e; wait "$RUNNER"; RCODE=$?; set -e
assert_eq "143" "$RCODE" "(a TERM ends the run with 143)"
gone "$GC" || fail "the grandchild (pid ${GC}) must be gone after TERM"
assert_eq "lock-released" "$(cat "$TRACE")"
assert_no_file "$LOCK"

# ---- the phase runner keeps the terminal's stdin (a password can be typed)
# and forwards a signal: an INT to benchbar ends the phase script and its
# command's group, with exit 130
PHASE="$TMP_DIR/phase"
cat >"$PHASE" <<'SH'
#!/usr/bin/env bash
IFS= read -r line
printf 'got=%s\n' "$line"
SH
chmod +x "$PHASE"
OUT="$(printf 'typed\n' | bash -c '. "$0/lib/frappe-local/ui.sh"; . "$0/lib/frappe-local/run.sh"; FL_PLAIN=1; fl_ui_init; fl_signal_traps_install; fl_run_phase_script "$1"' "$ROOT" "$PHASE" 2>&1)"
assert_contains "$OUT" "got=typed"
cat >"$PHASE" <<SH
#!/usr/bin/env bash
. "$ROOT/lib/frappe-local/ui.sh"; . "$ROOT/lib/frappe-local/run.sh"
FL_PLAIN=1; fl_ui_init; fl_signal_traps_install
fl_run_long slow "$SLOW" "\$1"
SH
: >"$GRANDCHILD"
# the test runner starts this test in the background, so SIGINT is ignored
# here and in every child; a terminal does not do that. python resets it to
# the default before starting benchbar's shell, as a terminal would have it.
python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp("bash", ["bash"] + sys.argv[1:])' \
  -c '. "$0/lib/frappe-local/ui.sh"; . "$0/lib/frappe-local/run.sh"; FL_PLAIN=1; fl_ui_init; fl_signal_traps_install; fl_run_phase_script "$1" "$2"' "$ROOT" "$PHASE" "$GRANDCHILD" >/dev/null 2>&1 &
RUNNER=$!
for _ in $(seq 1 50); do [[ -s "$GRANDCHILD" ]] && break; sleep 0.1; done
[[ -s "$GRANDCHILD" ]] || fail "test setup: the grandchild of the phase did not start"
GC="$(cat "$GRANDCHILD")"
kill -INT "$RUNNER"
set +e; wait "$RUNNER"; RCODE=$?; set -e
assert_eq "130" "$RCODE" "(an INT ends the run with 130)"
gone "$GC" || fail "the phase's grandchild (pid ${GC}) must be gone after INT"
pgrep -f "$PHASE" >/dev/null 2>&1 && fail "the phase script must be gone after INT"

# ---- a reclaimer that read a dead pid and then lost the race to another
# reclaimer leaves the new, live lock alone
mkdir -p "$LOCK"; printf '999999\n' >"$LOCK/pid"
# the slow reclaimer: its kill -0 takes 0.7 s, so the quick one replaces the lock first
lockshell 'kill() { local rc=0; builtin kill "$@" || rc=$?; sleep 0.7; return "$rc"; }; (fl_lock_acquire "$1") >/dev/null 2>&1; printf "slow=%s\n" "$?" >>"$2"' "$LOCK" "$WINS" >/dev/null 2>&1 &
SLOWR=$!
sleep 0.2
lockshell 'fl_lock_acquire "$1" >/dev/null 2>&1 || exit 1; printf "quick-holds\n" >>"$2"; sleep 2; fl_lock_release' "$LOCK" "$WINS" >/dev/null 2>&1 &
QUICK=$!
wait "$SLOWR" "$QUICK" 2>/dev/null || true
assert_contains "$(cat "$WINS")" "quick-holds"
assert_contains "$(cat "$WINS")" "slow=1" "(the slow reclaimer is refused by the quick one's live lock)"
assert_no_file "$LOCK" "(the quick holder released its lock, nobody took it away)"
rm -rf "$LOCK" "$LOCK".reclaim

# ---- two runs started in the same second: their own log file and backup folder each
LOGS="$TMP_DIR/logs"
read -r L1 B1 < <(bash -c '. "$0/lib/frappe-local/ui.sh"; . "$0/lib/frappe-local/templates.sh"; fl_log_init "$1"; printf "%s %s\n" "$FL_LOG_FILE" "$(fl_backup_stamp)"' "$ROOT" "$LOGS")
read -r L2 B2 < <(bash -c '. "$0/lib/frappe-local/ui.sh"; . "$0/lib/frappe-local/templates.sh"; fl_log_init "$1"; printf "%s %s\n" "$FL_LOG_FILE" "$(fl_backup_stamp)"' "$ROOT" "$LOGS")
[[ "$L1" != "$L2" ]] || fail "two runs must not share a log file: $L1"
[[ "$B1" != "$B2" ]] || fail "two runs must not share a backup folder: $B1"
assert_eq "$(basename "$L1" .log)" "$B1" "(a run's log and backup folder share one stamp)"
assert_file "$L1"; assert_file "$L2"

# ---- concurrent writers of one key-value file lose no key
KV="$TMP_DIR/kv.env"
for i in 1 2 3 4 5 6 7 8; do
  bash -c '. "$0/lib/frappe-local/ui.sh"; . "$0/lib/frappe-local/state.sh"; fl_kv_set "$1" "KEY$2" "value $2"' "$ROOT" "$KV" "$i" &
done
wait
for i in 1 2 3 4 5 6 7 8; do
  assert_eq "value $i" "$(bash -c '. "$0/lib/frappe-local/ui.sh"; . "$0/lib/frappe-local/state.sh"; fl_kv_get "$1" "KEY$2"' "$ROOT" "$KV" "$i")" "(KEY$i survives the other writers)"
done
[[ -z "$(ls "$KV".* 2>/dev/null)" ]] || fail "no temp file or lock may be left behind: $(ls "$KV".*)"

printf 'test-run-lock: ok\n'
