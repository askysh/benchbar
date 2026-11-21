#!/usr/bin/env bash
# Plain (non-TTY) output keeps the [OK] [WARN] [FAIL] wording and boxes fall back to ASCII.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
. "$ROOT/lib/frappe-local/ui.sh"

out="$(fl_ok "fine"; fl_warn "careful"; fl_fail "broken"; fl_info "note"; fl_fix "do this")"
assert_contains "$out" "[OK] fine"
assert_contains "$out" "[WARN] careful"
assert_contains "$out" "[FAIL] broken"
assert_contains "$out" "fix: do this"
assert_not_contains "$out" $'\033['

out="$(fl_box "Title" "line one" "a longer line two")"
assert_contains "$out" "+- Title"
assert_contains "$out" "| a longer line two |"

out="$(fl_table "A|B" "longer|x")"
assert_contains "$out" "longer  x"

assert_eq "5s" "$(fl_fmt_secs 5)"
assert_eq "2m 05s" "$(fl_fmt_secs 125)"
assert_eq "1h 01m" "$(fl_fmt_secs 3660)"
assert_eq "2 unchanged, 1 to update, 1 to repair" "$(fl_steps_counts unchanged update repair unchanged)"

fl_steps_define "first" "second"
out="$(fl_steps_print_plan)"
assert_contains "$out" "1. first"
assert_contains "$out" "2. second"
fl_step_begin 0; out="$(fl_step_end unchanged)"
assert_contains "$out" "1. first: unchanged"

quiet_step() { echo "[WARN] inner warning"; FL_STEP_RESULT="unchanged"; }
out="$(fl_step_run 1 quiet_step)"
assert_contains "$out" "2. second: unchanged"
assert_contains "$out" "[WARN] inner warning"

failing_step() { echo "boom"; return 3; }
fl_steps_define "third"
set +e; out="$(fl_step_run 0 failing_step)"; code=$?; set -e
assert_eq "3" "$code"
assert_contains "$out" "1. third: failed"
assert_contains "$out" "boom"

# spinner in non-TTY mode prints a single plain line
out="$(fl_spinner_start "working"; fl_spinner_stop)"
assert_contains "$out" "> working"

# confirm without a TTY and without --yes is a no
assert_status 1 fl_confirm "Proceed?" </dev/null
FL_ASSUME_YES=1 fl_confirm "Proceed?" >/dev/null

# logging
fl_log_init "$TMP_DIR/logs"
fl_ok "logged line" >/dev/null
grep -q '\[OK\] logged line' "$TMP_DIR"/logs/*.log || fail "status line was not logged"

# ---- bash 3.2 on a terminal: a printf that a signal interrupted is tried again (ui.sh). The
# first try is made to fail here (a function named builtin stands in for the EINTR); the line
# must still come out, once, and the run must not end. Later bash versions restart the write
# themselves and keep the builtin. Without a terminal there is no function on any bash.
assert_eq "builtin" "$(bash -c '. "$1"; type -t printf' _ "$ROOT/lib/frappe-local/ui.sh" </dev/null 2>/dev/null)" "(no terminal: the builtin)"
# shellcheck disable=SC2016  # the script is for the inner bash
tty_out="$(python3 -I -c 'import os, pty, sys; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))' bash -c '
  set -euo pipefail
  . "$1"
  if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then printf "kind=%s\n" "$(type -t printf)"; exit 0; fi
  tries=0
  builtin() { tries=$((tries + 1)); if [[ "$tries" == 1 ]]; then return 1; fi; command builtin "$@"; }
  printf "said %s\n" once
  unset -f builtin
  printf -v kept "%s" "a value"
  printf "tries=%s kept=%s kind=%s\n" "$tries" "$kept" "$(type -t printf)"
  # a bad argument is not a failed write: printf wrote its output and returns 1. It is not tried
  # again (the output came twice), its message is shown and its status is kept
  code=0; printf "num %d end\n" abc || code=$?
  printf "badcode=%s\n" "$code"
  code=0; printf -v n "%d" abc || code=$?
  printf "vcode=%s n=%s\n" "$code" "$n"' _ "$ROOT/lib/frappe-local/ui.sh" 2>&1)" || fail "a printf that failed once on a terminal ended the run: $tty_out"
if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then
  assert_contains "$tty_out" "kind=builtin"
else
  assert_eq "1" "$(grep -c 'said once' <<<"$tty_out")" "(the line comes out once) $tty_out"
  # three calls: the write that failed, the run with the output thrown away, the write again
  assert_contains "$tty_out" "tries=3 kept=a value kind=function"
  assert_eq "1" "$(grep -c 'num 0 end' <<<"$tty_out")" "(a bad argument prints its output once) $tty_out"
  assert_contains "$tty_out" "invalid number"
  assert_contains "$tty_out" "badcode=1"
  assert_contains "$tty_out" "vcode=1 n=0"
fi

printf 'test-ui: ok\n'
