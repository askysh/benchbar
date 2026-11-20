#!/usr/bin/env bash
# app add, app install and app update when a step fails (#153): a step that
# mutates and then fails is in changed[] with "partial", and a site's database
# is backed up before install-app unless --skip-backup says otherwise.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=tests/lib/apps-fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apps-fixtures.sh"

BENCH="$HOME/frappe-bench"
make_fake_bench "$BENCH" macdev
printf 'frappe\n' >"$BENCH/sites/apps.txt"
rmdir "$BENCH/apps/erpnext"
printf 'frappe 15.0.0\n' >"$BENCH/sites/macdev/installed_apps"
make_app_remote acme_crm
make_app_remote acme_tools
add_policy acme_crm main
add_policy acme_tools main

kinds() { printf '%s' "$OUT" | jget - '" ".join(s["kind"] for s in d["steps"])'; }
# last_done ARGS...: the done event of a streamed run, in DONE
last_done() { set +e; "$FM" "$@" >"$MOCK_STATE/stream" 2>"$MOCK_STATE/stderr"; CODE="$?"; set -e; DONE="$(tail -n 1 "$MOCK_STATE/stream")"; }

# ---- app add --site: a backup of the site comes before install-app (APP-12)
run_fm app add acme_crm --site macdev --dry-run --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "clone build backup install restart" "$(kinds)"
TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
assert_eq "bench --site macdev backup" "$(printf '%s' "$OUT" | jget - '[s["command"] for s in d["steps"] if s["kind"] == "backup"][0]')"
run_fm app add acme_crm --site macdev --skip-backup --dry-run --json --bench-dir "$BENCH"
assert_eq "clone build install restart" "$(kinds)"
assert_contains "$OUT" "--skip-backup: no backup is taken first"
[[ "$(printf '%s' "$OUT" | jget - 'd["token"]')" != "$TOKEN" ]] || fail "--skip-backup is another plan: it has another token"
run_fm app add acme_crm --site macdev --dry-run --bench-dir "$BENCH"
assert_contains "$OUT" "Back up macdev"

# a backup that fails stops the install: nothing touches the site's database
reset_calls
MOCK_BENCH_BACKUP_EXIT=1 last_done app add acme_crm --site macdev --apply "$TOKEN" --yes --jsonl --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$DONE"
assert_calls_contain '^bench --site macdev backup$'
assert_calls_not_contain 'install-app'
assert_eq "app:acme_crm" "$(printf '%s' "$DONE" | jget - '" ".join(x["kind"] + ":" + x["name"] for x in d["changed"])')" "(the clone happened, no backup and no install)"
# the retry takes the backup, then installs
reset_calls
run_fm app add acme_crm --site macdev --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^bench --site macdev backup$'
assert_calls_contain '^bench --site macdev install-app acme_crm$'
b="$(grep -m1 -n 'backup$' "$MOCK_LOG" | cut -d: -f1)"; i="$(grep -m1 -n 'install-app' "$MOCK_LOG" | cut -d: -f1)"
[[ "$b" -lt "$i" ]] || fail "the backup runs before install-app"
# --skip-backup: install-app only
reset_calls
run_fm app add acme_tools --site macdev --skip-backup --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain 'backup$'
assert_calls_contain '^bench --site macdev install-app acme_tools$'

# ---- app install: the same, for an app the bench already has
printf 'frappe 15.0.0\nacme_crm\n' >"$BENCH/sites/macdev/installed_apps"
make_app_remote acme_extra
add_policy acme_extra main
run_fm app add acme_extra --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
run_fm app install acme_extra --site macdev --dry-run --bench-dir "$BENCH"
assert_contains "$OUT" "Back up macdev"
assert_contains "$OUT" "bench --site macdev install-app acme_extra"
reset_calls
MOCK_BENCH_BACKUP_EXIT=1 run_fm app install acme_extra --site macdev --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "the backup of macdev failed; acme_extra was not installed"
assert_calls_not_contain 'install-app'
reset_calls
run_fm app install acme_extra --site macdev --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
b="$(grep -m1 -n 'backup$' "$MOCK_LOG" | cut -d: -f1)"; i="$(grep -m1 -n 'install-app' "$MOCK_LOG" | cut -d: -f1)"
[[ -n "$b" && "$b" -lt "$i" ]] || fail "app install backs up first"
make_app_remote acme_last
add_policy acme_last main
run_fm app add acme_last --yes --bench-dir "$BENCH"
reset_calls
run_fm app install acme_last --site macdev --skip-backup --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain 'backup$'
assert_calls_contain '^bench --site macdev install-app acme_last$'

# ---- a failed install is a change that may have happened (APP-11)
make_app_remote acme_late
add_policy acme_late main
run_fm app add acme_late --site macdev --skip-backup --dry-run --json --bench-dir "$BENCH"
LATE_TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
MOCK_BENCH_INSTALL_APP_EXIT=1 last_done app add acme_late --site macdev --skip-backup --apply "$LATE_TOKEN" --yes --jsonl --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$DONE"
assert_eq "app:acme_late:cloned app:acme_late:partial: install on macdev failed, the site database may have changed" \
  "$(printf '%s' "$DONE" | jget - '" ".join(x["kind"] + ":" + x["name"] + ":" + x["detail"] for x in d["changed"])')"

# ---- a failed migrate of app update says the site may have changed, a failed fast forward says how far it got
push_commits acme_crm 1
MOCK_BENCH_MIGRATE_EXIT=1 last_done app update acme_crm --skip-backup --yes --json --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$DONE"
assert_eq "app site" "$(printf '%s' "$DONE" | jget - '" ".join(sorted(set(x["kind"] for x in d["changed"] if x["kind"] in ("app", "site"))))')"
assert_contains "$DONE" "partial: migrate failed, the database may have changed"

printf 'test-app-partial: ok\n'
