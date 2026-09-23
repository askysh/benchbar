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

printf 'test-ui: ok\n'
