#!/usr/bin/env bash
# site backup, site backups and site drop: the refusals, the JSON, the
# backup before a drop, the default site, and the hosts line.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH" macdev
printf 'port 11000\n' >"$BENCH/config/redis_queue.conf"; printf 'port 13000\n' >"$BENCH/config/redis_cache.conf"
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
export MARIADB_ROOT_PASSWORD=rootpw
# two more sites, each in benchbar's hosts block
for s in bbtest.localhost other; do
  mkdir -p "$BENCH/sites/$s"; printf '{}\n' >"$BENCH/sites/$s/site_config.json"
done
printf '127.0.0.1 macdev\n\n# >>> benchbar >>>\n127.0.0.1 bbtest.localhost\n127.0.0.1 other\n# <<< benchbar <<<\n' >>"$FL_HOSTS_FILE"
BK="$BENCH/sites/bbtest.localhost/private/backups"
# JSON calls: stdout in OUT, stderr in ERR, apart
run_json() {
  set +e
  OUT="$("$FM" "$@" 2>"$MOCK_STATE/stderr")"
  CODE="$?"
  ERR="$(cat "$MOCK_STATE/stderr")"
  set -e
}

# ---- backups: none yet, read only, no lock
run_json site backups bbtest.localhost --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "1 bbtest.localhost 0" "$(printf '%s' "$OUT" | jget - '"%s %s %d" % (d["schema_version"], d["site"], len(d["backups"]))')"
run_fm site backups bbtest.localhost --bench-dir "$BENCH"
assert_contains "$OUT" "no backups of bbtest.localhost yet"
run_json site backups nosuch --json --bench-dir "$BENCH"
assert_eq "1" "$CODE"
assert_contains "$ERR" "No site 'nosuch'"

# ---- backup: bench's own command, the new set in JSON, nothing else on stdout
reset_calls
run_json site backup bbtest.localhost --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^bench --site bbtest.localhost backup$'
assert_eq "false $BK/20260929_100001-bbtest_localhost-database.sql.gz False None" \
  "$(printf '%s' "$OUT" | jget - '"%s %s %s %s" % (str(d["dry_run"]).lower(), d["backup"]["path"], d["backup"]["with_files"], d["backup"]["files"])')"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["backup"]["size_bytes"] > 0 and d["backup"]["time"].endswith("Z")')"
# with files: the uploads too
reset_calls
run_json site backup bbtest.localhost --with-files --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^bench --site bbtest.localhost backup --with-files$'
assert_eq "True $BK/20260929_100002-bbtest_localhost-files.tar $BK/20260929_100002-bbtest_localhost-private-files.tar" \
  "$(printf '%s' "$OUT" | jget - '"%s %s %s" % (d["backup"]["with_files"], d["backup"]["files"], d["backup"]["private_files"])')"
# the text form
run_fm site backup bbtest.localhost --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "backup of bbtest.localhost: $BK/20260929_100003-bbtest_localhost-database.sql.gz"
# a failed backup says so and prints no JSON
MOCK_BENCH_BACKUP_EXIT=1 run_json site backup bbtest.localhost --json --bench-dir "$BENCH"
assert_eq "1" "$CODE"
assert_eq "" "$OUT"
# dry run: nothing runs
reset_calls
run_fm site backup bbtest.localhost --dry-run --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain '^bench --site bbtest.localhost backup'

# ---- backups: newest first, with files or not
run_json site backups bbtest.localhost --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "20260929_100003:False 20260929_100002:True 20260929_100001:False" \
  "$(printf '%s' "$OUT" | jget - '" ".join("%s:%s" % (b["stamp"], b["with_files"]) for b in d["backups"])')"
run_fm site backups bbtest.localhost --bench-dir "$BENCH"
assert_contains "$OUT" "20260929_100002-bbtest_localhost-database.sql.gz"

# ---- drop: refusals, nothing touched
snap="$(snapshot "$BENCH/sites" "$FL_HOSTS_FILE")"
run_fm site drop bbtest.localhost --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "--confirm-site must repeat the site name exactly"
run_fm site drop bbtest.localhost --confirm-site bbtest --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "--confirm-site must repeat"
run_fm site drop macdev --confirm-site macdev --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "macdev is the default site"; assert_contains "$OUT" "--new-default"
run_fm site drop macdev --confirm-site macdev --new-default macdev --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "cannot be the site that is dropped"
run_fm site drop macdev --confirm-site macdev --new-default nosuch --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "No site 'nosuch'"
run_fm site drop other --confirm-site other --new-default bbtest.localhost --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "only for dropping the default site"
# in JSON mode a refusal is on stderr, stdout stays empty
run_json site drop other --json --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_eq "" "$OUT"; assert_contains "$ERR" "--confirm-site"
assert_eq "$snap" "$(snapshot "$BENCH/sites" "$FL_HOSTS_FILE")" "(refusals change nothing)"
assert_calls_not_contain 'drop-site'

# ---- drop: the plan
run_json site drop bbtest.localhost --confirm-site bbtest.localhost --dry-run --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "True False 2 True" "$(printf '%s' "$OUT" | jget - '"%s %s %d %s" % (d["dry_run"], d["is_default"], len(d["steps"]), d["steps"][-1]["needs_password"])')"
run_fm site drop bbtest.localhost --confirm-site bbtest.localhost --dry-run --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "bench drop-site bbtest.localhost"
assert_eq "$snap" "$(snapshot "$BENCH/sites" "$FL_HOSTS_FILE")" "(dry run)"

# ---- drop: the real thing, the password on stdin, the backup reported, the hosts line gone
reset_calls
run_json site drop bbtest.localhost --confirm-site bbtest.localhost --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^bench drop-site bbtest.localhost --db-root-password @secret0@$'
assert_eq "rootpw" "$(cat "$MOCK_STATE/stdin-drop-site")"
assert_not_contains "$(cat "$MOCK_LOG")" "rootpw"
assert_not_contains "$(cat "$FL_STATE_DIR"/logs/*.log)" "rootpw"
AR="$BENCH/archived/sites/bbtest.localhost"
assert_eq "True $AR $AR/private/backups/20260929_110000-bbtest_localhost-database.sql.gz True True None" \
  "$(printf '%s' "$OUT" | jget - '"%s %s %s %s %s %s" % (d["dropped"], d["archived_path"], d["backup"]["path"], d["backup"]["with_files"], d["hosts_removed"], d["manual_step"])')"
assert_no_file "$BENCH/sites/bbtest.localhost"
! grep -q 'bbtest.localhost' "$FL_HOSTS_FILE" || fail "the hosts line of the dropped site"
grep -q '^127.0.0.1 other$' "$FL_HOSTS_FILE" || fail "the other site's hosts line stays"
grep -q '^127.0.0.1 macdev$' "$FL_HOSTS_FILE" || fail "a line outside the block stays"
# the older backups went with the folder, untouched
assert_file "$AR/private/backups/20260929_100001-bbtest_localhost-database.sql.gz"

# ---- drop the default site: the new default first; only the line inside the block goes
mkdir -p "$BENCH/sites/macdev/private"
reset_calls
run_fm site drop macdev --confirm-site macdev --new-default other --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^bench use other$'
assert_eq "other" "$(tr -d '[:space:]' <"$BENCH/sites/currentsite.txt")"
assert_contains "$OUT" "removed '127.0.0.1 macdev'"
grep -q '^127.0.0.1 macdev$' "$FL_HOSTS_FILE" || fail "benchbar never edits a hosts line outside its block"
# a site whose only line is outside the block: reported with the command, left alone
mkdir -p "$BENCH/sites/outer"; printf '{}\n' >"$BENCH/sites/outer/site_config.json"
printf '127.0.0.1 outer\n' >>"$FL_HOSTS_FILE"
run_json site drop outer --confirm-site outer --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$ERR" "outside benchbar's block; left as it is"
assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["hosts_removed"]')"
grep -q '^127.0.0.1 outer$' "$FL_HOSTS_FILE" || fail "a line outside the block stays"
# a site name another bench also has: its line stays for that bench
OTHER="$HOME/dev/v16-bench"
make_fake_bench "$OTHER" shared
run_fm register "$OTHER"
mkdir -p "$BENCH/sites/shared"; printf '{}\n' >"$BENCH/sites/shared/site_config.json"
sed_inplace '/^# <<< benchbar <<<$/i\
127.0.0.1 shared
' "$FL_HOSTS_FILE"
run_fm site drop shared --confirm-site shared --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "has a site with that name"
grep -q '^127.0.0.1 shared$' "$FL_HOSTS_FILE" || fail "the other bench's site keeps its hosts line"
run_json site list --json --bench-dir "$BENCH"
assert_eq "other:True" "$(printf '%s' "$OUT" | jget - '" ".join("%s:%s" % (s["name"], s["default"]) for s in d["sites"])')"

# ---- the last site is never dropped
run_fm site drop other --confirm-site other --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "only site"

# ---- without a terminal and without cached sudo (the app): the manual step
mkdir -p "$BENCH/sites/third"; printf '{}\n' >"$BENCH/sites/third/site_config.json"
sed_inplace '/^# <<< benchbar <<<$/i\
127.0.0.1 third
' "$FL_HOSTS_FILE"
grep -q '^127.0.0.1 third$' "$FL_HOSTS_FILE" || fail "test setup: the third site's hosts line"
: >"$MOCK_STATE/sudo_refused"
run_json site drop third --confirm-site third --json --bench-dir "$BENCH" </dev/null
rm -f "$MOCK_STATE/sudo_refused"
assert_eq "0" "$CODE" "$OUT"
assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["hosts_removed"]')"
assert_contains "$(printf '%s' "$OUT" | jget - 'd["manual_step"]')" "sudo sed -i '' '/^127\\.0\\.0\\.1[[:space:]][[:space:]]*third[[:space:]]*\$/d'"

# ---- a failed drop-site (the backup failed): the site stays, the error says so
mkdir -p "$BENCH/sites/fourth"; printf '{}\n' >"$BENCH/sites/fourth/site_config.json"
MOCK_DROP_SITE_EXIT=1 run_fm site drop fourth --confirm-site fourth --bench-dir "$BENCH"
assert_eq "1" "$CODE"
assert_contains "$OUT" "the site is still there"
assert_file "$BENCH/sites/fourth/site_config.json"

# ---- the same name dropped again: bench numbers the archive, benchbar finds it
reset_calls
mkdir -p "$BENCH/sites/bbtest.localhost"; printf '{}\n' >"$BENCH/sites/bbtest.localhost/site_config.json"
run_json site drop bbtest.localhost --confirm-site bbtest.localhost --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "${AR}1" "$(printf '%s' "$OUT" | jget - 'd["archived_path"]')"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["hosts_removed"] is False and d["manual_step"] is None')" "(no line left to remove)"

printf 'test-site-backups: ok\n'
