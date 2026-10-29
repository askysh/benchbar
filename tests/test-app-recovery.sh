#!/usr/bin/env bash
# Recovery after a partial failure: the pending record of app update and of
# the planned app add (a retry runs only the steps that did not finish, the
# record goes when all are done), doctor's and status's view of it, the
# plan's dependency order and its cycle error, and fl_run_capture_timeout
# (a whole process group, TERM ignored). The whole file runs twice, under the
# macOS mocks and under use_linux, side by side.
if [[ -z "${RECOVERY_PASS:-}" ]]; then
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/benchbar-recovery.XXXXXX")"
  RECOVERY_PASS=macos bash "$here/$(basename "${BASH_SOURCE[0]}")" >"$tmp/macos.out" 2>&1 </dev/null &
  p1=$!
  RECOVERY_PASS=linux BENCHBAR_TEST_PLATFORM=linux bash "$here/$(basename "${BASH_SOURCE[0]}")" >"$tmp/linux.out" 2>&1 </dev/null &
  p2=$!
  c1=0; c2=0
  wait "$p1" || c1=$?
  wait "$p2" || c2=$?
  printf '== macos mocks\n'; cat "$tmp/macos.out"
  printf '== use_linux\n'; cat "$tmp/linux.out"
  rm -rf "$tmp"
  [[ "$c1" == "0" && "$c2" == "0" ]] || { printf 'FAIL: test-app-recovery (macos %s, linux %s)\n' "$c1" "$c2" >&2; exit 1; }
  exit 0
fi

# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=tests/lib/apps-fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apps-fixtures.sh"

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
# steps_of OUT: the kinds in the steps of a JSON document, comma separated
steps_of() { printf '%s' "$1" | jget - '",".join(s["kind"] for s in d["steps"])'; }

make_app_remote acme_crm
add_policy acme_crm main
run_fm app add acme_crm --site macdev --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "" "$(pending_file acme_crm)" "(a clean add leaves no record)"

# ---------------------------------------------------------------- app update
# step NAME, the mock variable that fails it, its kind, and which of backup,
# fast forward, python, node, migrate and build the retry must run (1) or not (0)
for spec in \
  "backup MOCK_BENCH_BACKUP_EXIT backup 1 1 1 1 1 1" \
  "fast_forward MOCK_GIT_MERGE_EXIT fast_forward 0 1 1 1 1 1" \
  "python MOCK_BENCH_REQUIREMENTS_PYTHON_EXIT requirements_python 0 0 1 1 1 1" \
  "node MOCK_BENCH_REQUIREMENTS_NODE_EXIT requirements_node 0 0 0 1 1 1" \
  "migrate MOCK_BENCH_MIGRATE_EXIT migrate 0 0 0 0 1 1" \
  "build MOCK_BENCH_BUILD_EXIT build 0 0 0 0 0 1"; do
  read -r label var kind r_backup r_ff r_py r_node r_migrate r_build <<<"$spec"
  push_commits acme_crm 2
  before="$(app_head "$BENCH/apps/acme_crm")"
  want="$(git -C "$REMOTES/acme_crm.git" rev-parse main)"
  reset_calls
  run_with "$var" 1 app update acme_crm --yes --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "${label}: $OUT"
  assert_file "$(pending_file acme_crm)" "(${label}: the failed update leaves a record)"
  assert_eq "app_update $kind $before $want" "$(pending_get acme_crm 'd["op"] + " " + d["failed_step"] + " " + d["from"] + " " + d["to"]')" "$label"
  assert_eq "1" "$(wc -l <"$(pending_file acme_crm)" | tr -d ' ')" "(${label}: one line)"
  assert_contains "$OUT" "benchbar app update acme_crm"
  # nothing after the failed step ran
  if [[ "$kind" == "backup" || "$kind" == "fast_forward" ]]; then assert_eq "0" "$(calls 'setup requirements')" "$label"; fi
  # the plan says what is left, and the code stays where the run left it
  run_fm app update acme_crm --dry-run --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
  assert_eq "$kind" "$(printf '%s' "$OUT" | jget - 'd["pending"]["failed_step"]')" "$label"
  assert_eq "$kind" "$(printf '%s' "$OUT" | jget - 'd["steps"][0]["kind"]')" "(${label}: the plan starts at the failed step)"
  # the retry: only what is left, exit 0, the record gone
  reset_calls
  run_fm app update acme_crm --yes --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "${label}: $OUT"
  assert_eq "$r_backup" "$(calls '^bench --site macdev backup$')" "${label}: backup"
  assert_eq "$r_ff" "$(calls 'merge --ff-only')" "${label}: fast forward"
  assert_eq "$r_py" "$(calls '^bench setup requirements --python acme_crm$')" "${label}: python"
  assert_eq "$r_node" "$(calls '^bench setup requirements --node acme_crm$')" "${label}: node"
  assert_eq "$r_migrate" "$(calls '^bench --site macdev migrate$')" "${label}: migrate"
  assert_eq "$r_build" "$(calls '^bench build --app acme_crm$')" "${label}: build"
  assert_eq "" "$(pending_file acme_crm)" "(${label}: done, no record)"
  assert_eq "$want" "$(app_head "$BENCH/apps/acme_crm")"
  # a second run is a no-op
  reset_calls
  run_fm app update acme_crm --yes --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
  assert_contains "$OUT" "unchanged: acme_crm is up to date"
  assert_calls_not_contain '^bench '
  assert_calls_not_contain 'merge'
done

# ---- a record is the truth even when old == new: the code is at `to`, the migrate did not run
push_commits acme_crm 1
run_with MOCK_BENCH_MIGRATE_EXIT 1 app update acme_crm --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
to="$(pending_get acme_crm 'd["to"]')"
assert_eq "$to" "$(app_head "$BENCH/apps/acme_crm")" "(the fast forward is done)"
# newer commits upstream wait for the next run; the plan counts them
push_commits acme_crm 2
run_fm app update acme_crm --dry-run --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "2" "$(printf '%s' "$OUT" | jget - 'd["newer_commits"]')"
assert_eq "$to" "$(printf '%s' "$OUT" | jget - 'd["to"]')" "(the reviewed range, not the newest)"
assert_eq "migrate,build" "$(steps_of "$OUT")"
assert_eq "macdev|" "$(printf '%s' "$OUT" | jget - '"|".join(s["target"] for s in d["steps"][:1]) + "|"')"
assert_eq "40" "$(printf '%s' "$OUT" | jget - 'len(d["pending"]["to"])')"
run_fm app update acme_crm --dry-run --bench-dir "$BENCH"
assert_contains "$OUT" "Unfinished from the last run"
assert_contains "$OUT" "2 newer commit(s)"

# ---- doctor and status read the record, and only the record
reset_calls
run_fm doctor --json --bench-dir "$BENCH"
assert_eq "warn" "$(printf '%s' "$OUT" | jget - '[c["level"] for c in d["checks"] if c["id"]=="app_update_pending"][0]')" "$OUT"
assert_contains "$(printf '%s' "$OUT" | jget - '[c["message"] for c in d["checks"] if c["id"]=="app_update_pending"][0]')" "stopped at migrate"
assert_contains "$(printf '%s' "$OUT" | jget - '[c["fix_command"] for c in d["checks"] if c["id"]=="app_update_pending"][0]')" "benchbar app update acme_crm"
assert_eq "ok" "$(printf '%s' "$OUT" | jget - '[c["level"] for c in d["checks"] if c["id"]=="app_add_pending"][0]')"
assert_calls_not_contain '^bench (--site|get-app|build|setup|list-apps)'
assert_calls_not_contain '^git (ls-remote|fetch|clone|pull|merge)'
run_fm status --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "app_update acme_crm migrate" "$(printf '%s' "$OUT" | jget - 'd["pending_operations"][0]["op"] + " " + d["pending_operations"][0]["app"] + " " + d["pending_operations"][0]["failed_step"]')"
assert_eq "migrate,build" "$(printf '%s' "$OUT" | jget - '",".join(s["kind"] for s in d["pending_operations"][0]["steps"])')"
assert_eq "$to" "$(printf '%s' "$OUT" | jget - 'd["pending_operations"][0]["to"]')"

# ---- an app moved by hand since the update stopped: refused, naming --discard-pending
git -C "$BENCH/apps/acme_crm" reset -q --hard HEAD~2
reset_calls
run_fm app update acme_crm --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "--discard-pending"
assert_calls_not_contain '^bench --site'
run_fm app update acme_crm --dry-run --bench-dir "$BENCH" --discard-pending
assert_file "$(pending_file acme_crm)" "(a dry run discards nothing)"
run_fm app update acme_crm --yes --discard-pending --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "dropping the unfinished app_update of acme_crm"
assert_eq "" "$(pending_file acme_crm)"
run_fm status --json --bench-dir "$BENCH"
assert_eq "[]" "$(printf '%s' "$OUT" | jget - 'd["pending_operations"]')"

# ---- a restart that fails is retried alone, and skipped once the bench is stopped
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
add_proc 4242 "honcho start -f Procfile.lean" "$BENCH"
add_proc 4243 "node apps/frappe/socketio.js" "$BENCH"
export MOCK_CURL_CODE=000
push_commits acme_crm 1
reset_calls
run_fm app update acme_crm --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_eq "restart" "$(pending_get acme_crm 'd["failed_step"]')" "$OUT"
assert_eq "restart" "$(pending_get acme_crm '",".join(s["kind"] for s in d["steps"])')"
export MOCK_CURL_CODE=200
reset_calls
run_fm app update acme_crm --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "0" "$(calls '^bench ')" "(the retry runs the restart and no bench command)"
assert_eq "" "$(pending_file acme_crm)"
# the same, and the bench is stopped before the retry: the restart is skipped
push_commits acme_crm 1
export MOCK_CURL_CODE=000
run_fm app update acme_crm --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
: >"$MOCK_PROCS"; : >"$MOCK_LISTEN"
reset_calls
run_fm app update acme_crm --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "1. Restart: skipped (not running)"
assert_eq "" "$(pending_file acme_crm)"
export MOCK_CURL_CODE=000

# ---------------------------------------------------------------- planned app add
make_app_remote acme_site
add_policy acme_site main
plan_json() { run_fm app add "$@" --dry-run --json --bench-dir "$BENCH"; }
apply_json() { run_fm app add "$@" --apply "$AP_TOKEN" --yes --json --bench-dir "$BENCH"; }
plan_json acme_site --site macdev
assert_eq "0" "$CODE" "$OUT"
AP_TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
assert_eq "clone,build,install,restart" "$(steps_of "$OUT")"
assert_eq "None" "$(printf '%s' "$OUT" | jget - 'd["reason"]')"
assert_eq "['acme_site']" "$(printf '%s' "$OUT" | jget - 'd["order"]')"
# a failed build: no install on a site whose assets were never built, no restart
reset_calls
run_with MOCK_BENCH_BUILD_EXIT 1 app add acme_site --site macdev --apply "$AP_TOKEN" --yes --json --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_calls_contain '^bench build --app acme_site$'
assert_calls_not_contain 'install-app'
assert_eq "app_add build" "$(pending_get acme_site 'd["op"] + " " + d["failed_step"]')"
assert_eq "build,install,restart" "$(pending_get acme_site '",".join(s["kind"] for s in d["steps"])')"
doc="$(printf '%s\n' "$OUT" | grep '"applied"' | tail -n1)"
assert_eq "done failed skipped skipped" "$(printf '%s' "$doc" | jget - '" ".join(s["status"] for s in d["steps"])')"
assert_eq "after failed build" "$(printf '%s' "$doc" | jget - 'd["steps"][2]["reason"]')"
run_fm doctor --json --bench-dir "$BENCH"
assert_eq "app_add_pending" "$(printf '%s' "$OUT" | jget - '[c["id"] for c in d["checks"] if c["id"].endswith("_pending") and c["level"]=="warn"][0]')"
# the next plan: the build and the install are steps again, with the reason
plan_json acme_site --site macdev
assert_eq "0" "$CODE" "$OUT"
assert_eq "build,install,restart" "$(steps_of "$OUT")"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["changes"]')"
assert_contains "$(printf '%s' "$OUT" | jget - 'd["reason"]')" "stopped at build"
AP_TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
reset_calls
apply_json acme_site --site macdev
assert_eq "0" "$CODE" "$OUT"
assert_eq "0" "$(calls 'get-app')" "(already cloned)"
assert_eq "1" "$(calls '^bench build --app acme_site$')"
assert_eq "1" "$(calls '^bench --site macdev install-app acme_site$')"
assert_eq "" "$(pending_file acme_site)"
plan_json acme_site --site macdev
assert_eq "[]" "$(printf '%s' "$OUT" | jget - '[s["kind"] for s in d["steps"]]')"
assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["changes"]')"
assert_eq "None" "$(printf '%s' "$OUT" | jget - 'd["reason"]')"

# a failed install: the build stays done, only the install is left
make_app_remote acme_shop
add_policy acme_shop main
plan_json acme_shop --site macdev
AP_TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
run_with MOCK_BENCH_INSTALL_APP_EXIT 1 app add acme_shop --site macdev --apply "$AP_TOKEN" --yes --json --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_eq "install" "$(pending_get acme_shop '",".join(s["kind"] for s in d["steps"])')"
plan_json acme_shop
assert_eq "install" "$(steps_of "$OUT")" "(the site comes from the record)"
AP_TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
reset_calls
apply_json acme_shop
assert_eq "0" "$CODE" "$OUT"
assert_eq "0" "$(calls 'get-app|bench build')"
assert_eq "1" "$(calls '^bench --site macdev install-app acme_shop$')"
assert_eq "" "$(pending_file acme_shop)"

# a clone that fails is rolled back and leaves no record: the app is simply absent
make_app_remote acme_bad
add_policy acme_bad main
plan_json acme_bad --site macdev
AP_TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
run_with MOCK_BENCH_GET_APP_EARLY_EXIT 1 app add acme_bad --site macdev --apply "$AP_TOKEN" --yes --json --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_eq "" "$(pending_file acme_bad)"
[[ ! -d "$BENCH/apps/acme_bad" ]] || fail "the failed clone was rolled back"
# get-app that cloned and listed the app, then failed: the folder stays (benchbar
# does not edit sites/), and the record keeps the build for the next plan
run_with MOCK_BENCH_GET_APP_EXIT 1 app add acme_bad --site macdev --apply "$AP_TOKEN" --yes --json --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_eq "build,restart" "$(pending_get acme_bad '",".join(s["kind"] for s in d["steps"])')"
plan_json acme_bad --site macdev
assert_eq "build,install,restart" "$(steps_of "$OUT")"

# ---------------------------------------------------------------- dependency order
make_app_remote dep_b
make_app_remote dep_c dep_b
make_app_remote dep_top dep_b dep_c
for n in dep_b dep_c dep_top; do add_policy "$n" main; done
plan_json dep_top
assert_eq "0" "$CODE" "$OUT"
assert_eq "['dep_b', 'dep_c', 'dep_top']" "$(printf '%s' "$OUT" | jget - 'd["order"]')"
assert_eq "dep_b,dep_c,dep_top" "$(printf '%s' "$OUT" | jget - '",".join(s["name"].replace("Clone ", "") for s in d["steps"] if s["kind"].startswith("clone"))')"
AP_TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
reset_calls
apply_json dep_top
assert_eq "0" "$CODE" "$OUT"
assert_eq "dep_b dep_c dep_top" "$(grep '^bench get-app' "$MOCK_LOG" | sed 's#.*/\([a-z_]*\)\.git$#\1#' | tr '\n' ' ' | sed 's/ $//')"
assert_eq "frappe acme_crm acme_site acme_shop acme_bad dep_b dep_c dep_top" "$(tr '\n' ' ' <"$BENCH/sites/apps.txt" | sed 's/ $//')"

# a cycle is refused and named
make_app_remote cyc_a cyc_b
make_app_remote cyc_b cyc_a
add_policy cyc_a main
add_policy cyc_b main
plan_json cyc_a
assert_eq "0" "$CODE" "$OUT"
assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')"
assert_contains "$(printf '%s' "$OUT" | jget - '" ".join(d["errors"])')" "required_apps cycle: cyc_b -> cyc_a -> cyc_b"
AP_TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
reset_calls
apply_json cyc_a
assert_eq "1" "$CODE"; assert_contains "$OUT" "required_apps cycle"
assert_calls_not_contain '^bench get-app'

# the plain app add (asks once, same plan and loop) leaves and finishes the same record
make_app_remote acme_plain
add_policy acme_plain main
run_with MOCK_BENCH_BUILD_EXIT 1 app add acme_plain --site macdev --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "Install on macdev: skipped (after failed build)"
assert_eq "build,install,restart" "$(pending_get acme_plain '",".join(s["kind"] for s in d["steps"])')"
reset_calls
run_fm app add acme_plain --site macdev --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "0" "$(calls 'get-app')" "(already cloned)"
assert_eq "1" "$(calls '^bench --site macdev install-app acme_plain$')"
assert_eq "" "$(pending_file acme_plain)"

# ---------------------------------------------------------------- fl_run_capture_timeout
# a child that ignores TERM and a grandchild that does too: both die, 124,
# within the deadline plus the grace
cat >"$TMP_DIR/stubborn.sh" <<'SH'
#!/bin/bash
trap '' TERM
( trap '' TERM; printf '%s\n' "$BASHPID" >"$1.grandchild"; while :; do sleep 1; done ) &
printf '%s\n' "$$" >"$1.child"
while :; do sleep 1; done
SH
chmod +x "$TMP_DIR/stubborn.sh"
cat >"$TMP_DIR/captest.sh" <<SH
set -euo pipefail
. "$ROOT/lib/frappe-local/run.sh"
FL_KILL_GRACE=0.3
FL_RUN_PGID=4242
code=0
start="\$SECONDS"
fl_run_capture_timeout 1 "$TMP_DIR/cap.out" "$TMP_DIR/cap.err" "$TMP_DIR/stubborn.sh" "$TMP_DIR/pids" || code=\$?
printf '%s %s %s\n' "\$code" "\$((SECONDS - start))" "\$FL_RUN_PGID"
code=0
printf 'out\n' >"$TMP_DIR/ok.in"
fl_run_capture_timeout 5 "$TMP_DIR/cap2.out" "$TMP_DIR/cap2.err" bash -c 'echo to-out; echo to-err >&2; exit 3' || code=\$?
printf '%s\n' "\$code"
SH
result="$(bash "$TMP_DIR/captest.sh")"
read -r code secs pgid <<<"$(printf '%s\n' "$result" | head -n1)"
assert_eq "124 4242" "$code $pgid" "$result"
[[ "$secs" -le 3 ]] || fail "fl_run_capture_timeout took ${secs}s for a 1s deadline"
assert_eq "3" "$(printf '%s\n' "$result" | tail -n1)"
assert_eq "to-out" "$(cat "$TMP_DIR/cap2.out")" "(stdout to OUT only)"
assert_eq "to-err" "$(cat "$TMP_DIR/cap2.err")" "(stderr to ERR only)"
assert_contains "$(cat "$TMP_DIR/cap.err")" "timed out after 1s"
for who in child grandchild; do
  pid="$(cat "$TMP_DIR/pids.$who")"
  # a zombie nobody has reaped yet (its parent was killed) is dead
  state="$(ps -o state= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  if kill -0 "$pid" 2>/dev/null && [[ "$state" != Z* ]]; then fail "the ${who} (pid ${pid}, state ${state}) survived fl_run_capture_timeout"; fi
done

printf 'test-app-recovery (%s): ok\n' "$RECOVERY_PASS"
