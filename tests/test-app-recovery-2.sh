#!/usr/bin/env bash
# Recovery after a partial failure, part 2 of 3: the record of app update after the loop of part 1, doctor's and status's view of it, a moved app, a failing restart, --skip-backup, TERM in a step, an unreadable or unwritable record.
# shellcheck source=tests/lib/recovery-suite.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/recovery-suite.sh"
prime_app_update

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

printf 'test-app-recovery-2 (%s): ok\n' "$RECOVERY_PASS"
