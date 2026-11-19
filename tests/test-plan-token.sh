#!/usr/bin/env bash
# Plan tokens (site add, site restore, app add, ports apply, service --apply):
# keyed with a per install secret, time limited, and refused with their own
# words when stale or expired.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
. "$ROOT/lib/frappe-local/ui.sh"
. "$ROOT/lib/frappe-local/plan-token.sh"

NOW=1800000000
export FL_PLAN_NOW="$NOW"
DATA=$'{"site":"qa.localhost"}\nsites\nmacdev\n'

# ---- the key: made on first use, 0600 in the state folder, never printed
KEY="$FL_STATE_DIR/plan-key"
assert_file "$KEY" "(the harness made one, as a first plan does)"
rm -f "$KEY"
assert_no_file "$KEY"
fl_plan_token_v T1 "$DATA"
assert_file "$KEY"
# shellcheck disable=SC2012  # one known file
assert_eq "-rw-------" "$(ls -ld "$KEY" | cut -c1-10)" "(the key is readable by the owner only)"
[[ "$T1" =~ ^[0-9a-f]{64}$ ]] || fail "a token is 64 hex characters, got [$T1]"
assert_not_contains "$T1" "$(cat "$KEY")"

# ---- keyed: not the plain hash of the plan, the same for the same plan in
# one run, different for another plan
PLAIN="$(printf '%s' "$DATA" | shasum -a 256 | awk '{print $1}')"
PLAIN2="$(printf '%s\n' "$DATA" | shasum -a 256 | awk '{print $1}')"
[[ "$T1" != "$PLAIN" && "$T1" != "$PLAIN2" ]] || fail "the token must not be the unkeyed hash of the plan"
fl_plan_token_v T2 "$DATA"
assert_eq "$T1" "$T2" "(one plan, one token)"
fl_plan_token_v T3 "${DATA}other"
[[ "$T3" != "$T1" ]] || fail "another plan needs another token"

# ---- another install (another key) cannot compute it
cp "$KEY" "$TMP_DIR/key.keep"
printf '%s\n' "0000000000000000000000000000000000000000000000000000000000000001" >"$KEY"
fl_plan_token_v T4 "$DATA"
[[ "$T4" != "$T1" ]] || fail "the token must depend on the install's key"
cp "$TMP_DIR/key.keep" "$KEY"

# ---- check: valid for about an hour, then expired; a changed plan is stale
fl_plan_token_check "$DATA" "$T1"; assert_eq "0" "$?" "(valid at once)"
FL_PLAN_NOW=$((NOW + 3500)); fl_plan_token_check "$DATA" "$T1"; assert_eq "0" "$?" "(valid after 58 minutes)"
FL_PLAN_NOW=$((NOW + 3600 + 700)); code=0; fl_plan_token_check "$DATA" "$T1" || code=$?
assert_eq "2" "$code" "(expired after 72 minutes)"
FL_PLAN_NOW=$((NOW + 30)); code=0; fl_plan_token_check "${DATA}changed" "$T1" || code=$?
assert_eq "1" "$code" "(a changed plan is stale, not expired)"
code=0; fl_plan_token_check "$DATA" "$(printf 'a%.0s' $(seq 1 64))" || code=$?
assert_eq "1" "$code" "(a token that was never issued is stale)"
FL_PLAN_NOW=$((NOW + 86400 * 3)); code=0; fl_plan_token_check "$DATA" "$T1" || code=$?
assert_eq "1" "$code" "(a very old token is only refused)"
export FL_PLAN_NOW="$NOW"

# ---- end to end: an expired token is refused with its own text, and the
# plan token of a site add is not the plain hash of anything
BENCH="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH"
run_fm site add qa-site --dry-run --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
[[ "$TOKEN" =~ ^[0-9a-f]{64}$ ]] || fail "site add plan token: [$TOKEN]"
assert_file "$FL_STATE_DIR/plan-key"
FL_PLAN_NOW=$((NOW + 7200)) ADMIN_PASSWORD=pw run_fm site add qa-site --apply "$TOKEN" --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "token expired"
assert_contains "$OUT" "Nothing was changed"
assert_no_file "$BENCH/sites/qa-site/site_config.json"
# a token from a plan of something else is stale, not expired
ADMIN_PASSWORD=pw run_fm site add other-site --apply "$TOKEN" --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "plan changed"
assert_not_contains "$OUT" "token expired"
