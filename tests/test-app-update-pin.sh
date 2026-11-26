#!/usr/bin/env bash
# app update, pinned byte for byte (issue 146): the exit code, stdout, stderr and mock calls of
# every way the command ends, in tests/golden/app-update.txt. A change that only moves code
# (splitting fl_cmd_app_update into steps) leaves the file as it is. PIN_UPDATE=1 rewrites it.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=tests/lib/apps-fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apps-fixtures.sh"
# shellcheck source=tests/lib/pin.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/pin.sh"
fail() { printf "FAIL (line %s): %s\n" "${BASH_LINENO[1]}" "$*" >&2; exit 1; }

BENCH="$HOME/frappe-bench"
make_fake_bench "$BENCH" macdev
printf 'frappe\n' >"$BENCH/sites/apps.txt"
rmdir "$BENCH/apps/erpnext"
printf 'frappe 15.0.0\n' >"$BENCH/sites/macdev/installed_apps"
make_app_remote acme_crm
add_policy acme_crm main
APP="$BENCH/apps/acme_crm"
"$FM" app add acme_crm --site macdev --yes --bench-dir "$BENCH" >/dev/null 2>&1 || fail "setup: app add"
B=(--bench-dir "$BENCH")
pdir() {
  local e
  e="$(find "$FL_STATE_DIR/benches" -maxdepth 1 -name 'frappe-bench-*' 2>/dev/null | awk 'NR==1')"
  [[ -z "$e" ]] || printf '%s.pending' "${e%.*}"
}
pfile() { printf '%s/acme_crm.json' "$(pdir)"; }
# the app's commit and its record, after a run
pstate() {
  pin_state "$1 head" "$(git -C "$APP" rev-parse --short HEAD)"
  if [[ -n "$(pdir)" && -f "$(pfile)" ]]; then pin_state "$1 record" "$(cat "$(pfile)")"; else pin_state "$1 record" none; fi
}
run() { local n="$1"; shift; pin_run "$n" "$@"; pstate "$n"; }
# an app_update record, as benchbar writes it
write_rec() {
  [[ -n "$(pdir)" ]] || fail "write_rec: no bench state file: $(find "$FL_STATE_DIR" | sed -n "1,20p")"
  mkdir -p "$(pdir)"
  printf '%s\n' "$1" >"$(pfile)"
}
drop_rec() { local f; f="$(pfile)"; [[ ! -e "$f" ]] || unlink "$f"; }
local_commit() { pin_date; printf 'local\n' >"$APP/acme_crm/local.txt"; git -C "$APP" add -A; git -C "$APP" commit -q -m "local work"; }

# ---- usage and refusals before any work
run "unknown option" app update acme_crm --bogus "${B[@]}"
run "no app" app update "${B[@]}"
run "apply, bad token" app update acme_crm --apply nope --yes "${B[@]}"
TOK0="$(printf '%064d' 0)"
run "apply, no --yes" app update acme_crm --apply "$TOK0" "${B[@]}"
run "apply with dry run" app update acme_crm --apply "$TOK0" --dry-run --yes "${B[@]}"
run "apply with discard" app update acme_crm --apply "$TOK0" --discard-pending --yes "${B[@]}"
run "apply=TOKEN form, no --yes" app update acme_crm "--apply=$TOK0" "${B[@]}"
run "not a git app" app update nosuch --yes "${B[@]}"
run "discard with json" app update acme_crm --discard-pending --json "${B[@]}"

# ---- discard: no record, a record (dry run, real), an unreadable one
run "discard, nothing to drop" app update acme_crm --discard-pending "${B[@]}"
write_rec '{"schema_version":1,"op":"app_update","app":"acme_crm","branch":"main","from":"","to":"","steps":[{"kind":"migrate","target":"macdev","name":"Migrate macdev"},{"kind":"build","target":"acme_crm","name":"Build"}],"failed_step":"migrate","reason":"boom","url":"","started_at":"2026-10-29T10:00:00Z","updated_at":"2026-10-29T10:00:00Z"}'
run "discard, dry run" app update acme_crm --discard-pending --dry-run "${B[@]}"
run "discard, real" app update acme_crm --discard-pending "${B[@]}"
write_rec 'not json'
run "discard unreadable, dry run" app update acme_crm --discard-pending --dry-run "${B[@]}"
run "update with unreadable record" app update acme_crm --yes "${B[@]}"
run "discard unreadable, real" app update acme_crm --discard-pending "${B[@]}"

# ---- the app is not in a state to update
printf "# edited
" >>"$APP/acme_crm/__init__.py"
run "dirty tree" app update acme_crm --yes "${B[@]}"
git -C "$APP" checkout -q -- .
git -C "$APP" checkout -q --detach
run "detached head" app update acme_crm --yes "${B[@]}"
git -C "$APP" checkout -q main
REM="$(git -C "$APP" remote | awk 'NR==1')"
URL="$(git -C "$APP" remote get-url "$REM")"
git -C "$APP" remote remove "$REM"
run "no remote" app update acme_crm --yes "${B[@]}"
git -C "$APP" remote add "$REM" "$URL"
git -C "$APP" fetch -q "$REM"
git -C "$APP" branch -q --set-upstream-to="$REM/main" main

# ---- up to date, and ahead of the remote
run "up to date" app update acme_crm --yes "${B[@]}"
run "up to date, dry run" app update acme_crm --dry-run "${B[@]}"
run "up to date, dry run json" app update acme_crm --dry-run --json "${B[@]}"
local_commit
run "ahead, text" app update acme_crm --yes "${B[@]}"
run "ahead, dry run json" app update acme_crm --dry-run --json "${B[@]}"
git -C "$APP" reset -q --hard HEAD~1

# ---- a plan: new commits upstream
pin_commit "$WORK/acme_crm" acme_crm 2
run "plan, text" app update acme_crm --dry-run "${B[@]}"
run "plan, json" app update acme_crm --dry-run --json "${B[@]}"
TOK="$(printf '%s' "$PIN_STDOUT" | jget - 'd["token"]')"
run "plan, skip backup, text" app update acme_crm --dry-run --skip-backup "${B[@]}"
run "plan, skip backup, json" app update acme_crm --dry-run --skip-backup --json "${B[@]}"
run "cancelled at the prompt" app update acme_crm "${B[@]}"
use_mocks_without uv
run "no uv, dry run" app update acme_crm --dry-run "${B[@]}"
run "no uv, real run" app update acme_crm --yes "${B[@]}"
use_all_mocks
run "apply, token of another plan" app update acme_crm --apply "$TOK0" --yes "${B[@]}"
FL_PLAN_NOW=$((FL_PLAN_NOW + 7200)) run "apply, expired token" app update acme_crm --apply "$TOK" --yes "${B[@]}"
# a diverged tree: a local commit and a different one upstream
local_commit
run "diverged" app update acme_crm --yes "${B[@]}"
git -C "$APP" reset -q --hard HEAD~1
run "plan again" app update acme_crm --dry-run --json "${B[@]}"
TOK="$(printf '%s' "$PIN_STDOUT" | jget - 'd["token"]')"
pin_commit "$WORK/acme_crm" acme_crm 1
run "apply, stale token" app update acme_crm --apply "$TOK" --yes "${B[@]}"
run "plan with the third commit" app update acme_crm --dry-run --json "${B[@]}"
TOK="$(printf '%s' "$PIN_STDOUT" | jget - 'd["token"]')"
run "apply, good token, json" app update acme_crm --apply "$TOK" --yes --json "${B[@]}"
run "after apply, up to date" app update acme_crm --yes "${B[@]}"

# ---- failures at each step, then the retry that finishes them
for spec in "backup MOCK_BENCH_BACKUP_EXIT" "fast_forward MOCK_GIT_MERGE_EXIT" "python MOCK_BENCH_REQUIREMENTS_PYTHON_EXIT" \
  "node MOCK_BENCH_REQUIREMENTS_NODE_EXIT" "migrate MOCK_BENCH_MIGRATE_EXIT" "build MOCK_BENCH_BUILD_EXIT"; do
  read -r label var <<<"$spec"
  pin_commit "$WORK/acme_crm" acme_crm 1
  export "$var=1"
  run "fails at ${label}" app update acme_crm --yes "${B[@]}"
  unset "$var"
  run "pending after ${label}, text" app update acme_crm --dry-run "${B[@]}"
  run "pending after ${label}, json" app update acme_crm --dry-run --json "${B[@]}"
  run "retry after ${label}" app update acme_crm --yes "${B[@]}"
done
pin_commit "$WORK/acme_crm" acme_crm 1
MOCK_BENCH_MIGRATE_EXIT=1 run "fails at migrate, json" app update acme_crm --yes --json "${B[@]}"
run "retry, skip backup" app update acme_crm --yes --skip-backup "${B[@]}"
pin_commit "$WORK/acme_crm" acme_crm 1
MOCK_BENCH_MIGRATE_EXIT=1 run "fails at migrate again" app update acme_crm --yes "${B[@]}"
pin_commit "$WORK/acme_crm" acme_crm 2
run "pending, newer commits upstream" app update acme_crm --dry-run "${B[@]}"
run "pending, skip backup, json plan" app update acme_crm --dry-run --skip-backup --json "${B[@]}"
git -C "$APP" reset -q --hard HEAD~1
run "pending, app moved" app update acme_crm --yes "${B[@]}"
run "pending, discard" app update acme_crm --discard-pending "${B[@]}"
git -C "$APP" pull -q --ff-only "$REM" main
# a record that lists an app add
write_rec '{"schema_version":1,"op":"app_add","app":"acme_crm","branch":"main","from":"","to":"","steps":[],"failed_step":"build","reason":"left over","url":"","started_at":"2026-10-29T10:00:00Z","updated_at":"2026-10-29T10:00:00Z"}'
run "pending app add" app update acme_crm --yes "${B[@]}"
# a record whose only entry is a failed verify
H="$(git -C "$APP" rev-parse HEAD)"
write_rec "{\"schema_version\":1,\"op\":\"app_update\",\"app\":\"acme_crm\",\"branch\":\"main\",\"from\":\"$H\",\"to\":\"$H\",\"steps\":[],\"failed_step\":\"verify\",\"reason\":\"not there\",\"url\":\"\",\"started_at\":\"2026-10-29T10:00:00Z\",\"updated_at\":\"2026-10-29T10:00:00Z\"}"
run "pending, nothing left but verify" app update acme_crm --yes "${B[@]}"
write_rec "{\"schema_version\":1,\"op\":\"app_update\",\"app\":\"acme_crm\",\"branch\":\"main\",\"from\":\"$H\",\"to\":\"$H\",\"steps\":[],\"failed_step\":\"verify\",\"reason\":\"not there\",\"url\":\"\",\"started_at\":\"2026-10-29T10:00:00Z\",\"updated_at\":\"2026-10-29T10:00:00Z\"}"
run "pending, nothing left, json" app update acme_crm --dry-run --json "${B[@]}"
drop_rec

# ---- the record cannot be written, or a step undoes the update
SHIM="$TMP_DIR/shim"; mkdir -p "$SHIM"
REAL_BENCH="$(command -v bench)"
cat >"$SHIM/bench" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"requirements --python"*) [[ "\${PIN_SHIM:-}" != "lock" ]] || chmod 500 "\$PIN_PDIR" ;;
  "build"*) [[ "\${PIN_SHIM:-}" != "undo" ]] || git -C "\$PIN_APP" reset -q --hard HEAD~1 ;;
esac
exec "$REAL_BENCH" "\$@"
SH
chmod +x "$SHIM/bench"
pin_commit "$WORK/acme_crm" acme_crm 1
mkdir -p "$(pdir)"
OLDPATH="$PATH"
PATH="$SHIM:$PATH"
chmod 500 "$(pdir)"
run "record cannot be written first" app update acme_crm --yes "${B[@]}"
chmod 700 "$(pdir)"
PIN_PDIR="$(pdir)" PIN_SHIM=lock run "record cannot be updated" app update acme_crm --yes "${B[@]}"
chmod 700 "$(pdir)"
drop_rec
git -C "$APP" reset -q --hard HEAD~1
PIN_APP="$APP" PIN_SHIM=undo run "verify fails" app update acme_crm --yes "${B[@]}"
PATH="$OLDPATH"

pin_check app-update.txt
echo "test-app-update-pin: ok"
