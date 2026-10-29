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
# the discard drops the record and stops: even with --yes no step, no merge, no fetch
pdir="$(dirname "$(pending_file acme_crm)")"
[[ "$pdir" == "$FL_STATE_DIR"/benches/*.pending ]] || fail "the record folder is not in the state folder: $pdir"
head_before="$(app_head "$BENCH/apps/acme_crm")"
reset_calls
run_fm app update acme_crm --yes --discard-pending --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "dropping the unfinished app_update of acme_crm"
assert_eq "" "$(pending_file acme_crm)"
assert_calls_not_contain '^bench '
assert_calls_not_contain 'merge|fetch'
assert_eq "$head_before" "$(app_head "$BENCH/apps/acme_crm")" "(the discard moves nothing)"
# with no record there is nothing to discard, and still nothing runs
reset_calls
run_fm app update acme_crm --yes --discard-pending --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "no unfinished update or add of acme_crm to discard"
assert_calls_not_contain '^bench |merge|fetch'
# the discard prints text only: --json with it is refused, never a text line on a JSON stdout
run_fm app update acme_crm --dry-run --json --discard-pending --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "leave out --json"
# a record folder holding only a temp file of a failed write: doctor reports no record
mkdir -p "$pdir"
: >"${pdir}/acme_crm.json.tmp.999"
run_fm doctor --json --bench-dir "$BENCH"
assert_not_contains "$OUT" "pending record of *"
assert_not_contains "$OUT" "app update * --discard-pending"
rm -f "${pdir}/acme_crm.json.tmp.999"
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
# in the stream the restart is one step of app update's own: restart's step
# lines (restart_service, wait_site, numbered from 1 again) stay out of it
push_commits acme_crm 1
set +e; "$FM" app update acme_crm --yes --json --bench-dir "$BENCH" >"$TMP_DIR/au.jsonl" 2>"$TMP_DIR/au.err" </dev/null; CODE=$?; set -e
assert_eq "0" "$CODE" "$(cat "$TMP_DIR/au.err")"
au_steps() { python3 -I -c '
import json, sys
e = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(eval(sys.argv[2]))' "$TMP_DIR/au.jsonl" "$1"; }
assert_eq "[]" "$(au_steps '[x["id"] for x in e if x["event"] == "step" and x["id"] in ("restart_service", "wait_site")]')" "$(cat "$TMP_DIR/au.jsonl")"
assert_eq "['running', 'done']" "$(au_steps '[x["status"] for x in e if x["event"] == "step" and x["id"].startswith("restart")]')" "$(cat "$TMP_DIR/au.jsonl")"
assert_eq "1" "$(au_steps 'len([x for x in e if x["event"] == "done"])')"
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

# ---- after the fast forward, `from` is no longer a place the app may be: the
# `git reset --hard` we print for the way back leaves a record that refuses
push_commits acme_crm 1
from="$(app_head "$BENCH/apps/acme_crm")"
run_with MOCK_BENCH_MIGRATE_EXIT 1 app update acme_crm --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
git -C "$BENCH/apps/acme_crm" reset -q --hard "$from"
reset_calls
run_fm app update acme_crm --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "--discard-pending"
assert_calls_not_contain '^bench '
# --discard-pending works even on a dirty tree or a detached HEAD
printf 'local\n' >>"$BENCH/apps/acme_crm/acme_crm/__init__.py"
reset_calls
run_fm app update acme_crm --yes --discard-pending --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "dropping the unfinished app_update of acme_crm"
assert_not_contains "$OUT" "has local changes"
assert_eq "" "$(pending_file acme_crm)"
assert_calls_not_contain '^bench |merge'
# the discard looks only at benchbar's own record: a name that is a path reaches nothing
printf 'keep\n' >"$TMP_DIR/decoy.json"
run_fm app update "../../../../${TMP_DIR#/}/decoy" --discard-pending --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_file "$TMP_DIR/decoy.json"
git -C "$BENCH/apps/acme_crm" checkout -q -- .
# a record whose only entry is a failed verify: re-verified, never a loop
to="$(git -C "$REMOTES/acme_crm.git" rev-parse main)"
git -C "$BENCH/apps/acme_crm" merge -q --ff-only "$to"
write_record acme_crm '' '"verify"'
sed_inplace 's/"op":"app_add"/"op":"app_update"/; s/"from":""/"from":"'"$from"'"/; s/"to":""/"to":"'"$to"'"/' "$(pending_file acme_crm)"
run_fm app update acme_crm --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "" "$(pending_file acme_crm)"
write_record acme_crm '' '"verify"'
sed_inplace 's/"op":"app_add"/"op":"app_update"/; s/"from":""/"from":"'"$from"'"/; s/"to":""/"to":"'"$to"'"/' "$(pending_file acme_crm)"
git -C "$BENCH/apps/acme_crm" reset -q --hard "$from"
run_fm app update acme_crm --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "--discard-pending"
run_fm app update acme_crm --yes --discard-pending --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "" "$(pending_file acme_crm)"

# ---- --skip-backup on a retry leaves the backups in the record out
push_commits acme_crm 1
run_with MOCK_BENCH_BACKUP_EXIT 1 app update acme_crm --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
reset_calls
run_fm app update acme_crm --skip-backup --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "0" "$(calls 'backup$')"
assert_eq "1" "$(calls '^bench --site macdev migrate$')"
assert_eq "" "$(pending_file acme_crm)"

# ---- a TERM to the CLI in the middle of a step: the record still holds that step
push_commits acme_crm 1
export MOCK_BENCH_MIGRATE_SLEEP=30
reset_calls
"$FM" app update acme_crm --yes --bench-dir "$BENCH" >"$TMP_DIR/term.out" 2>&1 </dev/null &
cli=$!
for _ in $(seq 1 100); do grep -q -E '^bench --site macdev migrate$' "$MOCK_LOG" && break; sleep 0.2; done
grep -q -E '^bench --site macdev migrate$' "$MOCK_LOG" || fail "the migrate started: $(cat "$TMP_DIR/term.out")"
kill -TERM "$cli"
wait "$cli" || true
unset MOCK_BENCH_MIGRATE_SLEEP
assert_eq "migrate,build" "$(pending_get acme_crm '",".join(s["kind"] for s in d["steps"])')"
reset_calls
run_fm app update acme_crm --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "1" "$(calls '^bench --site macdev migrate$')"
assert_eq "0" "$(calls 'merge --ff-only|backup$')"
assert_eq "" "$(pending_file acme_crm)"

# ---- a record that cannot be read (cut short): kept, nothing runs from it, --discard-pending is the way out
push_commits acme_crm 1
run_with MOCK_BENCH_MIGRATE_EXIT 1 app update acme_crm --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
cut="$(pending_file acme_crm)"
head -c 90 "$cut" >"$cut.cut"; mv "$cut.cut" "$cut"
reset_calls
run_fm app update acme_crm --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "cannot be read"; assert_contains "$OUT" "--discard-pending"
assert_calls_not_contain '^bench '
assert_file "$cut" "(the cut record is kept)"
run_fm doctor --json --bench-dir "$BENCH"
assert_contains "$(printf '%s' "$OUT" | jget - '" ".join(c["message"] for c in d["checks"] if c["id"]=="app_update_pending")')" "cannot be read"
run_fm app update acme_crm --yes --discard-pending --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "" "$(pending_file acme_crm)"

# ---- a record that cannot be written: nothing runs, since a stop could not be finished
dir="$(pending_dir_for)"
mkdir -p "$(dirname "$dir")"; printf 'in the way\n' >"$dir"
push_commits acme_crm 1
reset_calls
run_fm app update acme_crm --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "could not write the pending record"
assert_calls_not_contain '^bench (--site macdev (backup|migrate)|setup|build)'
assert_calls_not_contain 'merge --ff-only'
unlink "$dir"

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
# does not edit sites/), and the record keeps the requirements the failed pip
# install did not get to and the build for the next plan
run_with MOCK_BENCH_GET_APP_EXIT 1 app add acme_bad --site macdev --apply "$AP_TOKEN" --yes --json --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_eq "requirements_python,build,restart" "$(pending_get acme_bad '",".join(s["kind"] for s in d["steps"])')"
plan_json acme_bad --site macdev
assert_eq "requirements_python,build,install,restart" "$(steps_of "$OUT")"
AP_TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
# a failed requirements step skips the build, the install and the restart, and the record keeps them
reset_calls
run_with MOCK_BENCH_REQUIREMENTS_PYTHON_EXIT 1 app add acme_bad --site macdev --apply "$AP_TOKEN" --yes --json --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_calls_not_contain 'build --app|install-app'
doc="$(printf '%s\n' "$OUT" | grep '"applied"' | tail -n1)"
assert_eq "failed skipped skipped skipped" "$(printf '%s' "$doc" | jget - '" ".join(s["status"] for s in d["steps"])')"
assert_eq "after failed requirements_python" "$(printf '%s' "$doc" | jget - 'd["steps"][1]["reason"]')"
assert_eq "requirements_python,build,install,restart" "$(pending_get acme_bad '",".join(s["kind"] for s in d["steps"])')"
plan_json acme_bad --site macdev
AP_TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
reset_calls
apply_json acme_bad --site macdev
assert_eq "0" "$CODE" "$OUT"
r="$(grep -n 'setup requirements --python acme_bad' "$MOCK_LOG" | head -n1 | cut -d: -f1)"
b="$(grep -n 'build --app acme_bad' "$MOCK_LOG" | head -n1 | cut -d: -f1)"
i="$(grep -n 'install-app acme_bad' "$MOCK_LOG" | head -n1 | cut -d: -f1)"
[[ -n "$r" && -n "$b" && -n "$i" && "$r" -lt "$b" && "$b" -lt "$i" ]] || fail "requirements, build, install in that order: $r $b $i"
assert_eq "" "$(pending_file acme_bad)"

# an app_add record with nothing left to run (the install was done by hand): the
write_record acme_crm '{"kind":"install","target":"macdev","name":"Install on macdev"}' '"install"'
[[ -n "$(pending_file acme_crm)" ]] || fail "the hand written record is found"
run_fm app add acme_crm --site macdev --dry-run --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "its record would be removed"
assert_file "$(pending_file acme_crm)" "(a dry run removes nothing)"
run_fm app add acme_crm --site macdev --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "the unfinished app add of acme_crm is complete"
assert_eq "" "$(pending_file acme_crm)"
write_record acme_crm '{"kind":"install","target":"macdev","name":"Install on macdev"}' '"install"'
plan_json acme_crm --site macdev
AP_TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
apply_json acme_crm --site macdev
assert_eq "0" "$CODE" "$OUT"
assert_eq "" "$(pending_file acme_crm)"
# a record that names a site that is gone is cleared too
write_record acme_crm '{"kind":"install","target":"nosuchsite","name":"Install on nosuchsite"}' '"install"'
run_fm app add acme_crm --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "" "$(pending_file acme_crm)"

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

# an app already in the bench between two to clone passes the order through:
# pres_x requires pres_p (in the bench), pres_p requires pres_y (not), so
# pres_y goes before pres_x
make_app_remote pres_y
make_app_remote pres_p
make_app_remote pres_x pres_p
make_app_remote pres_top pres_y pres_x
for n in pres_y pres_p pres_x pres_top; do add_policy "$n" main; done
run_fm app add pres_p --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
sed_inplace 's/required_apps = \[\]/required_apps = ["pres_y"]/' "$BENCH/apps/pres_p/pres_p/hooks.py"
plan_json pres_top
assert_eq "0" "$CODE" "$OUT"
assert_eq "['pres_y', 'pres_x', 'pres_top']" "$(printf '%s' "$OUT" | jget - 'd["order"]')"

# an app that requires itself is a cycle of one
make_app_remote selfy selfy
add_policy selfy main
plan_json selfy
assert_eq "0" "$CODE" "$OUT"
assert_contains "$(printf '%s' "$OUT" | jget - '" ".join(d["errors"])')" "required_apps cycle: selfy -> selfy"
assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')"

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
