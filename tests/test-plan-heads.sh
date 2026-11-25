#!/usr/bin/env bash
# APP-13 (#153): the approval token of app add and lock apply covers the HEAD
# of the apps already in the bench, so a plan approved before an app's checkout
# moved is refused as stale and nothing runs.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=tests/lib/apps-fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apps-fixtures.sh"

BENCH="$HOME/frappe-bench"
make_fake_bench "$BENCH" macdev
rmdir "$BENCH/apps/erpnext"
printf 'frappe 15.0.0\n' >"$BENCH/sites/macdev/installed_apps"
# frappe as a real clone, like bench init leaves it
make_app_remote frappe
mv "$BENCH/apps/frappe" "$TMP_DIR/frappe-fake"
git clone -q --origin upstream --branch version-15 "file://$REMOTES/frappe.git" "$BENCH/apps/frappe"
printf 'frappe\n' >"$BENCH/sites/apps.txt"
make_app_remote acme_crm
make_app_remote acme_tools
add_policy acme_crm main
add_policy acme_tools main
run_fm app add acme_crm --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"

# ---- app add: a present app that moves after the plan makes the token stale
run_fm app add acme_tools --dry-run --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
run_fm app add acme_tools --dry-run --json --bench-dir "$BENCH"
assert_eq "$TOKEN" "$(printf '%s' "$OUT" | jget - 'd["token"]')" "(token stable while nothing moves)"
git -C "$BENCH/apps/acme_crm" commit -q --allow-empty -m "moved after the plan"
reset_calls
run_fm app add acme_tools --apply "$TOKEN" --yes --json --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "The app add plan changed"
assert_calls_not_contain '^bench (get-app|build|--site macdev install-app)'
run_fm app add acme_tools --dry-run --json --bench-dir "$BENCH"
NEW="$(printf '%s' "$OUT" | jget - 'd["token"]')"
[[ "$TOKEN" != "$NEW" ]] || fail "the moved HEAD did not change the token"

# ---- lock apply: a behind app is fast forwarded; its HEAD is part of the token
git -C "$BENCH/apps/acme_crm" commit -q --allow-empty -m "third"
run_fm lock write --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
CRM="$BENCH/apps/acme_crm"
C2="$(git -C "$CRM" rev-parse HEAD~1)"
git -C "$CRM" reset -q --hard HEAD~2
run_fm lock apply --dry-run --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
LTOKEN="$(printf '%s' "$OUT" | sed -n 's/.*"token":"\([0-9a-f]*\)".*/\1/p')"
assert_eq "64" "${#LTOKEN}"
# still behind the lock, but at another commit: the plan text is the same, the token is not
git -C "$CRM" reset -q --hard "$C2"
run_fm lock apply --dry-run --json --bench-dir "$BENCH"
LNEW="$(printf '%s' "$OUT" | sed -n 's/.*"token":"\([0-9a-f]*\)".*/\1/p')"
[[ "$LTOKEN" != "$LNEW" ]] || fail "a moved HEAD did not change the lock apply token"
printf 'test-plan-heads: ok\n'
