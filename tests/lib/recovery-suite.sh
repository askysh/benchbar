#!/usr/bin/env bash
#
# recovery-suite.sh: the setup shared by test-app-recovery, -2 and -3. Each
# of them sources this first and then runs its own part of the recovery tests.
#
# The sourcing file runs twice, under the macOS mocks and under use_linux,
# side by side: the first time through this file starts both and exits.
# After it: the harness, the app fixtures, a fake bench with acme_crm added.

RECOVERY_SELF="${BASH_SOURCE[1]}"
RECOVERY_NAME="$(basename "$RECOVERY_SELF" .sh)"
if [[ -z "${RECOVERY_PASS:-}" ]]; then
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/benchbar-recovery.XXXXXX")"
  RECOVERY_PASS=macos bash "$RECOVERY_SELF" >"$tmp/macos.out" 2>&1 </dev/null &
  p1=$!
  RECOVERY_PASS=linux BENCHBAR_TEST_PLATFORM=linux bash "$RECOVERY_SELF" >"$tmp/linux.out" 2>&1 </dev/null &
  p2=$!
  c1=0; c2=0
  wait "$p1" || c1=$?
  wait "$p2" || c2=$?
  printf '== macos mocks\n'; cat "$tmp/macos.out"
  printf '== use_linux\n'; cat "$tmp/linux.out"
  rm -rf "$tmp"
  [[ "$c1" == "0" && "$c2" == "0" ]] || { printf 'FAIL: %s (macos %s, linux %s)\n' "$RECOVERY_NAME" "$c1" "$c2" >&2; exit 1; }
  exit 0
fi

# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
# shellcheck source=tests/lib/apps-fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/apps-fixtures.sh"

# say where an assertion failed (the harness only prints what it expected)
fail() { printf "FAIL (line %s): %s\n" "${BASH_LINENO[1]}" "$*" >&2; exit 1; }
BENCH="$HOME/frappe-bench"
make_fake_bench "$BENCH" macdev
printf 'frappe\n' >"$BENCH/sites/apps.txt"
rmdir "$BENCH/apps/erpnext"
printf 'frappe 15.0.0\n' >"$BENCH/sites/macdev/installed_apps"

# run_with VAR VALUE ARGS...: run_fm with one mock variable set for that run
run_with() {
  local var="$1" val="$2"
  shift 2
  export "$var=$val"
  run_fm "$@"
  unset "$var"
}
# calls PATTERN: how often a mock call matching PATTERN was logged since reset_calls
calls() { grep -c -E "$1" "$MOCK_LOG" || true; }
# pending_file APP: the app's record in the bench's state folder
pending_file() { find "$FL_STATE_DIR/benches" -path "*.pending/$1.json" 2>/dev/null | head -n1; }
pending_get() { jget "$(pending_file "$1")" "$2"; }
pending_dir_for() {
  local e
  e="$(find "$FL_STATE_DIR/benches" -maxdepth 1 -name 'frappe-bench-*.env' | head -n1)"
  # without the bench's state file the path would be relative to the test's folder
  [[ -n "$e" ]] || fail "pending_dir_for: no bench state file in $FL_STATE_DIR/benches"
  printf '%s.pending' "${e%.env}"
}
# write_record APP STEPS_JSON FAILED: an app_add record as benchbar writes it
write_record() {
  mkdir -p "$(pending_dir_for)"
  printf '{"schema_version":1,"op":"app_add","app":"%s","branch":"main","from":"","to":"","steps":[%s],"failed_step":%s,"reason":"left over","started_at":"2026-10-29T10:00:00Z","updated_at":"2026-10-29T10:00:00Z"}\n' \
    "$1" "$2" "$3" >"$(pending_dir_for)/$1.json"
}
# steps_of OUT: the kinds in the steps of a JSON document, comma separated
steps_of() { printf '%s' "$1" | jget - '",".join(s["kind"] for s in d["steps"])'; }

make_app_remote acme_crm
add_policy acme_crm main
run_fm app add acme_crm --site macdev --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "" "$(pending_file acme_crm)" "(a clean add leaves no record)"

# prime_app_update: what the first part of the recovery tests leaves behind for
# the others: commits upstream to step back over, one clean update, no record
prime_app_update() {
  push_commits acme_crm 2
  run_fm app update acme_crm --yes --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
  assert_eq "" "$(pending_file acme_crm)" "(a clean update leaves no record)"
}
