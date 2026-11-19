#!/usr/bin/env bash
# Linux parity, part 1 (#176): the crash notification of the runner on a
# desktop (notify-send through the user's session bus), nothing extra in WSL
# (the tray toasts from the state record) and on a headless server (the
# record and the log are all there is); and the profiles Linux can install.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
use_linux
export USER=tester
desktop_kernel() { printf 'Linux version 6.8.0-generic (buildd@lcy02) #1 SMP PREEMPT_DYNAMIC\n' >"$FL_PROC_VERSION"; }
wsl_kernel() { printf 'Linux version 6.6.0-microsoft-standard-WSL2 (root@build) (gcc) #1 SMP\n' >"$FL_PROC_VERSION"; }

BENCH="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH" linuxdev.localhost
runner="$BENCH/benchbar-run.sh"
flag="$BENCH/logs/.bench-stopped"; hist="$BENCH/logs/.bench-starts"
state="$BENCH/logs/.benchbar/state.json"

# the user's session bus: a socket in XDG_RUNTIME_DIR (a systemd user unit has
# that variable; a headless server has no such socket)
export XDG_RUNTIME_DIR="$TMP_DIR/run-user"
mkdir -p "$XDG_RUNTIME_DIR"
make_bus() { no_bus; (cd "$XDG_RUNTIME_DIR" && python3 -c 'import socket; socket.socket(socket.AF_UNIX).bind("bus")'); }
no_bus() { rm -f "$XDG_RUNTIME_DIR/bus"; }
unset DBUS_SESSION_BUS_ADDRESS

# trip: three starts inside the window, so the next run pauses with "crash"
# (the guard allows MAX_STARTS, the one after pauses) and says so
trip() {
  local now
  now="$(date +%s)"
  rm -f "$flag"
  printf '%s\n%s\n%s\n' "$((now - 50))" "$((now - 40))" "$((now - 30))" >"$hist"
  reset_calls
  : >"$MOCK_PROCS"
  assert_status 0 "$runner"
  assert_eq "crash" "$(cat "$flag")"
}
paused_crash() { assert_eq "paused crash" "$(jget "$state" 'd["state"], d["stop_reason"]' | tr -d "(),'")" "${1:-}"; }

# ---- a desktop: the runner shows the crash through notify-send
desktop_kernel
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
bash -n "$runner"
! grep -q 'osascript' "$runner" || fail "the Linux runner has no osascript"
make_bus
trip
assert_calls_contain '^notify-send .*Crashed 3 times in 10 minutes\. Auto-restart paused'
assert_calls_contain "^bus=unix:path=${XDG_RUNTIME_DIR}/bus\$" "(the call goes to the user's session bus)"
assert_calls_contain '^notify-send .*BenchBar: frappe-bench' "(the notification names the bench)"
paused_crash "(the record is written first, for status and the tray)"
# a session bus address the unit already has is used as it is
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus,guid=abc"
trip
assert_calls_contain "^bus=unix:path=${XDG_RUNTIME_DIR}/bus,guid=abc\$"
unset DBUS_SESSION_BUS_ADDRESS
# the other pauses notify too (here a missing bench env)
reset_calls; rm -f "$flag"; : >"$hist"
mv "$BENCH/env/bin/python" "$BENCH/env/bin/python.away"
assert_status 0 "$runner"
mv "$BENCH/env/bin/python.away" "$BENCH/env/bin/python"
assert_calls_contain '^notify-send .*The bench env is missing'
rm -f "$flag"

# ---- a headless server: no session bus, so no notification and no error;
# the record and the log still say what happened
no_bus
trip
assert_calls_not_contain '^notify-send'
paused_crash "(headless: the record is all there is)"
grep -q 'auto-restart paused' "$BENCH/logs/bench.log" || fail "the pause must be logged"
# a desktop without notify-send installed
make_bus
use_mocks_without notify-send
trip
use_all_mocks
paused_crash
# a notify-send that fails never changes the exit or the record
MOCK_NOTIFY_EXIT=1 trip
assert_calls_contain '^notify-send '
paused_crash

# ---- WSL: the tray reads the record and shows the toast, so the runner adds none
wsl_kernel
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
! grep -q 'notify-send' "$runner" || fail "the WSL runner leaves the toast to the tray"
make_bus
trip
assert_calls_not_contain '^notify-send'
paused_crash
set +e; OUT="$("$FM" status --json --bench-dir "$BENCH" 2>/dev/null)"; CODE=$?; set -e
assert_eq "paused crash" "$(printf '%s' "$OUT" | jget - 'd["state"], d["stop_reason"]' | tr -d "(),'")" "(status reports the crash on Linux, the tray's toast source)"

printf 'test-linux-parity: ok\n'
