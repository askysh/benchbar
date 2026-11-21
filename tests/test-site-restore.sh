#!/usr/bin/env bash
# benchbar site restore: a backup set into an existing site (backed up
# first) or a new one, the plan and its token, --no-migrate, the
# --before-migrate hook, the encryption key, the default site, and the
# refusals. Run on the macOS platform here and as Linux in test-site-restore-2.
# shellcheck source=tests/lib/site-restore-suite.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/site-restore-suite.sh"

suite mac fresh.localhost

# ---- a backup set from outside this bench (SVC-4, issue 186): a production set restored as it is keeps
# its integrations live, so site restore has --neutralise (the list pull runs, after the restore and
# before migrate), a person gets a warning in the plan without it, and an agent is refused without it
PROD="$TMP_DIR/prod-sets"
mkdir -p "$PROD"
gzip -c "$SQL" >"$PROD/20260910_101010-erp_example_com-database.sql.gz"
printf '{"db_name":"_prod","db_password":"proddbpw","encryption_key":"%s"}\n' "$SETKEY" >"$PROD/20260910_101010-erp_example_com-site_config_backup.json"
PRODSET="$PROD/20260910_101010-erp_example_com-database.sql.gz"
plan_steps() { printf '%s' "$OUT" | jget - '",".join(s["id"] for s in d["steps"])'; }

# a person, no flag: the plan can be applied and warns, in the text and in warnings[]
run_fm site restore prodcopy.localhost --from "$PRODSET" --new --dry-run --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "[WARN] this backup set is not one of this bench's own"
assert_contains "$OUT" "--neutralise"
run_json site restore prodcopy.localhost --from "$PRODSET" --new --dry-run --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$ERR"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')"
assert_contains "$(printf '%s' "$OUT" | jget - '" | ".join(d["warnings"])')" "not one of this bench's own"
case ",$(plan_steps)," in *,neutralise,*) fail "no neutralise step without the flag: $(plan_steps)" ;; esac
token_plain="$(printf '%s' "$OUT" | jget - 'd["token"]')"

# with --neutralise: the step sits after the restore and the key and before migrate, and nothing warns
run_json site restore prodcopy.localhost --from "$PRODSET" --new --neutralise --dry-run --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$ERR"
case "$(plan_steps)" in *restore,encryption_key,neutralise,*migrate*) ;; *) fail "neutralise must follow the restore and come before migrate: $(plan_steps)" ;; esac
assert_eq "" "$(printf '%s' "$OUT" | jget - '" | ".join(d["warnings"])')"
token_neut="$(printf '%s' "$OUT" | jget - 'd["token"]')"
[[ "$token_plain" != "$token_neut" ]] || fail "the plan token must cover --neutralise"

# an agent (BENCHBAR_NONINTERACTIVE=1, what --for-agent and benchbar mcp set): refused without the flag,
# in the plan already, and at apply; the token of one plan does not run the other
BENCHBAR_NONINTERACTIVE=1 run_json site restore prodcopy.localhost --from "$PRODSET" --new --dry-run --json --bench-dir "$BENCH"
assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')"
assert_contains "$(printf '%s' "$OUT" | jget - '" | ".join(d["errors"])')" "pass --neutralise"
reset_calls
MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw BENCHBAR_NONINTERACTIVE=1 run_json site restore prodcopy.localhost --from "$PRODSET" --new --apply "$token_plain" --yes --json --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_no_file "$BENCH/sites/prodcopy.localhost"
assert_calls_not_contain 'benchbar-frappe prodcopy.localhost restore'
MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw run_json site restore prodcopy.localhost --from "$PRODSET" --new --neutralise --apply "$token_plain" --yes --json --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$ERR" "plan changed"
assert_no_file "$BENCH/sites/prodcopy.localhost"

# the agent with --neutralise: restored, then neutralised (Administrator's login kept), then migrated
reset_calls
MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw BENCHBAR_NONINTERACTIVE=1 run_json site restore prodcopy.localhost --from "$PRODSET" --new --neutralise --apply "$token_neut" --yes --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$ERR"
r="$(at '^python benchbar-frappe prodcopy.localhost restore ')"; n="$(at '^python benchbar-neutralise prodcopy.localhost 1$')"; m="$(at '^bench --site prodcopy.localhost migrate')"
[[ -n "$r" && -n "$n" && -n "$m" && "$r" -lt "$n" && "$n" -lt "$m" ]] || fail "neutralise runs after the restore and before migrate (${r} ${n} ${m})"$'\n'"$(cat "$MOCK_LOG")"
assert_contains "$ERR" "neutralised prodcopy.localhost"
assert_not_contains "$ERR" "keep-secrets" "(the restore's lines do not name a pull flag)"

# a neutralisation that fails stops the run before migrate
reset_calls
run_json site restore prodfail.localhost --from "$PRODSET" --new --neutralise --dry-run --json --bench-dir "$BENCH"
token="$(printf '%s' "$OUT" | jget - 'd["token"]')"
MOCK_NEUTRALISE_FAIL=1 MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw run_json site restore prodfail.localhost --from "$PRODSET" --new --neutralise --apply "$token" --yes --json --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$ERR" "could not neutralise prodfail.localhost"
assert_calls_not_contain '^bench --site prodfail.localhost migrate'

# the bench's own sets are as before: a stamp, and the path of a file in a site's backup folder, for
# an agent too, with no warning and no neutralise step
BENCHBAR_NONINTERACTIVE=1 run_json site restore acme.localhost --from 20260901_090000 --dry-run --json --bench-dir "$BENCH"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')" "$OUT $ERR"
assert_not_contains "$(printf '%s' "$OUT" | jget - '" | ".join(d["warnings"])')" "not one of this bench's own"
BENCHBAR_NONINTERACTIVE=1 run_json site restore acme.localhost --from "$BENCH/sites/acme.localhost/private/backups/20260901_090000-acme_localhost-database.sql.gz" --dry-run --json --bench-dir "$BENCH"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')" "$OUT $ERR"
assert_not_contains "$(printf '%s' "$OUT" | jget - '" | ".join(d["warnings"])')" "not one of this bench's own"
case ",$(plan_steps)," in *,neutralise,*) fail "an own set gets no neutralise step unasked: $(plan_steps)" ;; esac

printf 'test-site-restore: ok\n'
