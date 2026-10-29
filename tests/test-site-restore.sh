#!/usr/bin/env bash
# benchbar site restore: a backup set into an existing site (backed up
# first) or a new one, the plan and its token, --no-migrate, the
# --before-migrate hook, the encryption key, the default site, and the
# refusals. Run on the macOS platform and again as Linux (use_linux).
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

SETKEY="setkey-Zm9vYmFyYmF6"
SQL="$TMP_DIR/dump.sql"
cat >"$SQL" <<'SQL'
INSERT INTO `tabDefaultValue` VALUES ('a','__default','installed_apps','[\"frappe\",\"erpnext\"]');
SQL
HOOK="$TMP_DIR/hook.sh"
cat >"$HOOK" <<'HOOK'
#!/bin/bash
printf 'hook ran\n' >>"$MOCK_LOG"
{ printf 'cwd=%s\n' "$PWD"; env; } >"$MOCK_STATE/hook_env"
# HOOK_MOVE_DEFAULT=site: something that moves the default site
[[ -z "${HOOK_MOVE_DEFAULT:-}" ]] || printf '%s\n' "$HOOK_MOVE_DEFAULT" >sites/currentsite.txt
exit "${HOOK_EXIT:-0}"
HOOK
chmod +x "$HOOK"

# JSON calls: stdout in OUT, stderr in ERR, apart
run_json() {
  set +e
  OUT="$("$FM" "$@" 2>"$MOCK_STATE/stderr")"
  CODE="$?"
  ERR="$(cat "$MOCK_STATE/stderr")"
  set -e
}
conf_get() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$BENCH/sites/$1/site_config.json" "$2"; }
# make_set SITE STAMP [files]: a backup set of SITE, the way bench writes one
make_set() {
  local base="$BENCH/sites/$1/private/backups/$2-${1//./_}"
  mkdir -p "$BENCH/sites/$1/private/backups"
  gzip -c "$SQL" >"${base}-database.sql.gz"
  printf '{"db_name":"_old","db_password":"olddbpw","encryption_key":"%s"}\n' "$SETKEY" >"${base}-site_config_backup.json"
  if [[ "${3:-}" == "files" ]]; then printf 'public files\n' >"${base}-files.tar"; printf 'private files\n' >"${base}-private-files.tar"; fi
}
default_site() { tr -d '[:space:]' <"$BENCH/sites/currentsite.txt"; }
# line numbers of the first mock call matching a pattern
at() { grep -n -E -- "$1" "$MOCK_LOG" | head -n1 | cut -d: -f1; }

suite() {
  local tag="$1" fresh="$2" plan token snap n r m h
  BENCH="$HOME/dev/restore-$tag"
  make_fake_bench "$BENCH" macdev
  cp "$ROOT/tests/mocks/frappe-python" "$BENCH/env/bin/python"; chmod +x "$BENCH/env/bin/python"
  printf 'port 11000\n' >"$BENCH/config/redis_queue.conf"; printf 'port 13000\n' >"$BENCH/config/redis_cache.conf"
  printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
  mkdir -p "$MOCK_STATE/keychain"; printf 'rootpw\n' >"$MOCK_STATE/keychain/benchbar-mariadb--root"
  mkdir -p "$FL_STATE_DIR/secrets"; printf 'rootpw\n' >"$FL_STATE_DIR/secrets/mariadb-root"; chmod 600 "$FL_STATE_DIR/secrets/mariadb-root"
  unset MARIADB_ROOT_PASSWORD ADMIN_PASSWORD
  if [[ "$FL_PLATFORM" == "linux" ]]; then
    # the MariaDB client the apt package puts on PATH
    mkdir -p "$TMP_DIR/xbin"; cp "$ROOT/tests/mocks/mariadb" "$TMP_DIR/xbin/mariadb"; chmod +x "$TMP_DIR/xbin/mariadb"
    export FL_MARIADB_BIN="$TMP_DIR/xbin/mariadb"
  fi
  # a second site with two sets, one of them with files; the default stays macdev
  mkdir -p "$BENCH/sites/acme.localhost"; printf '{"db_name":"_acme","db_password":"acmedbpw"}\n' >"$BENCH/sites/acme.localhost/site_config.json"
  make_set acme.localhost 20260901_090000
  make_set acme.localhost 20260902_090000 files
  printf '127.0.0.1 macdev acme.localhost\n' >>"$FL_HOSTS_FILE"
  local SET1=20260901_090000 SET2=20260902_090000
  reset_calls

  # ---- refusals: nothing runs
  run_fm site restore acme.localhost --bench-dir "$BENCH" --dry-run
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "--from STAMP|PATH names the backup set"
  run_json site restore acme.localhost --from 20260101_000000 --dry-run --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')" "(a plan with errors is printed, not applicable)"
  assert_contains "$OUT" "no complete database backup with the stamp 20260101_000000"
  run_fm site restore nosuch --from "$SET1" --from-site acme.localhost --dry-run --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "no site nosuch in $BENCH"; assert_contains "$OUT" "--new creates it"
  run_fm site restore acme.localhost --from "$SET1" --new --from-site acme.localhost --dry-run --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "site acme.localhost already exists; leave out --new"
  run_fm site restore "$fresh" --from "$SET1" --new --dry-run --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "--new needs --from-site SITE"
  run_fm site restore acme.localhost --from "$SET1" --with-files --dry-run --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "--with-files: the set ${SET1} has no files"
  run_fm site restore acme.localhost --from "$SET1" --before-migrate "$TMP_DIR/nosuch.sh" --dry-run --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "--before-migrate: no file"
  printf '#!/bin/sh\n' >"$TMP_DIR/noexec.sh"
  run_fm site restore acme.localhost --from "$SET1" --before-migrate "$TMP_DIR/noexec.sh" --dry-run --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "is not executable"
  run_fm site restore acme.localhost --from "$SET1" --json --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "--json shows the plan only; add --dry-run"
  run_fm site restore acme.localhost --from "$SET1" --apply --yes --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "--apply needs the token of a plan"
  run_fm site restore acme.localhost --from "$SET1" --apply abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789 --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "pass its token with --apply TOKEN --yes"
  run_fm site restore acme.localhost --from "$SET1" --bogus --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "Unknown option for site restore: --bogus"
  # an encrypted set is not taken
  mkdir -p "$TMP_DIR/enc"; printf 'x' >"$TMP_DIR/enc/20260903_090000-acme_localhost-database-enc.sql.gz"
  run_fm site restore acme.localhost --from "$TMP_DIR/enc" --dry-run --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "is encrypted"
  # a half made target is no site
  mkdir -p "$BENCH/sites/halfmade"
  run_fm site restore halfmade --from "$SET1" --from-site acme.localhost --dry-run --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "sites/halfmade exists but has no site_config.json"
  rmdir "$BENCH/sites/halfmade"
  assert_calls_not_contain '^(bench|python benchbar|redis-server)'

  # ---- the plan into an existing site: read only, with a token
  reset_calls
  snap="$(snapshot "$BENCH" "$FL_HOSTS_FILE" "$FL_STATE_DIR")"
  run_json site restore acme.localhost --from "$SET2" --with-files --dry-run --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  plan="$OUT"
  printf '%s' "$plan" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["schema_version"] == 1 and d["can_apply"] is True and d["errors"] == [], d
assert len(d["token"]) == 64 and d["new"] is False and d["exists"] is True, d
assert [s["id"] for s in d["steps"]] == ["local_backup", "restore", "encryption_key", "migrate", "clear_cache", "verify"], [s["id"] for s in d["steps"]]
assert d["touches"] == ["database", "files", "site_config"], d["touches"]
assert d["backup_first"]["will_run"] is True and d["backup_first"]["with_files"] is True, d
assert d["source"]["set"]["stamp"] == "20260902_090000" and d["source"]["restores_files"] is True and d["source"]["encryption_key"] is True, d["source"]
assert d["migrate"] is True and d["before_migrate"] is None, d
' || fail "the site restore plan"$'\n'"$plan"
  assert_eq "$snap" "$(snapshot "$BENCH" "$FL_HOSTS_FILE" "$FL_STATE_DIR")" "(a plan writes nothing)"
  assert_calls_not_contain '^(bench|python benchbar|redis-server|sudo)'
  token="$(printf '%s' "$plan" | jget - 'd["token"]')"
  # the same plan twice, the same token
  run_json site restore acme.localhost --from "$SET2" --with-files --dry-run --json --bench-dir "$BENCH"
  assert_eq "$token" "$(printf '%s' "$OUT" | jget - 'd["token"]')"
  # a different plan, a different token
  run_json site restore acme.localhost --from "$SET2" --dry-run --json --bench-dir "$BENCH"
  [[ "$(printf '%s' "$OUT" | jget - 'd["token"]')" != "$token" ]] || fail "a plan without files has its own token"
  run_fm site restore acme.localhost --from "$SET2" --with-files --dry-run --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "Back up acme.localhost with its files"; assert_contains "$OUT" "dry-run: nothing was backed up, created or restored"

  # ---- a stale token: a changed hook, a changed set or a new site makes it stale, and nothing runs
  reset_calls
  run_json site restore acme.localhost --from "$SET1" --before-migrate "$HOOK" --dry-run --json --bench-dir "$BENCH"
  token="$(printf '%s' "$OUT" | jget - 'd["token"]')"
  cp "$HOOK" "$TMP_DIR/hook.good"; printf '# changed\n' >>"$HOOK"
  run_fm site restore acme.localhost --from "$SET1" --before-migrate "$HOOK" --apply "$token" --yes --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "plan changed since it was shown"
  assert_calls_not_contain '^(bench|python benchbar|redis-server)'
  cp "$TMP_DIR/hook.good" "$HOOK"; chmod +x "$HOOK"
  # and a site that appears after the plan
  run_json site restore acme.localhost --from "$SET1" --dry-run --json --bench-dir "$BENCH"
  token="$(printf '%s' "$OUT" | jget - 'd["token"]')"
  mkdir -p "$BENCH/sites/late.localhost"; printf '{}\n' >"$BENCH/sites/late.localhost/site_config.json"
  run_fm site restore acme.localhost --from "$SET1" --apply "$token" --yes --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "plan changed since it was shown"
  assert_calls_not_contain '^(bench|python benchbar|redis-server)'
  rm -rf "$BENCH/sites/late.localhost"
  # the set itself rewritten after the plan
  run_json site restore acme.localhost --from "$SET1" --dry-run --json --bench-dir "$BENCH"
  token="$(printf '%s' "$OUT" | jget - 'd["token"]')"
  printf 'more\n' >>"$BENCH/sites/acme.localhost/private/backups/${SET1}-acme_localhost-site_config_backup.json"
  gzip -c "$SQL" >"$BENCH/sites/acme.localhost/private/backups/${SET1}-acme_localhost-database.sql.gz.tmp"
  cat "$BENCH/sites/acme.localhost/private/backups/${SET1}-acme_localhost-database.sql.gz.tmp" "$BENCH/sites/acme.localhost/private/backups/${SET1}-acme_localhost-database.sql.gz.tmp" >"$BENCH/sites/acme.localhost/private/backups/${SET1}-acme_localhost-database.sql.gz"
  rm -f "$BENCH/sites/acme.localhost/private/backups/${SET1}-acme_localhost-database.sql.gz.tmp"
  run_fm site restore acme.localhost --from "$SET1" --apply "$token" --yes --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "plan changed since it was shown"
  assert_calls_not_contain '^(bench|python benchbar|redis-server)'
  make_set acme.localhost "$SET1"

  # ---- apply: backup first, restore with the files, the key of the set, migrate, verify
  reset_calls
  run_json site restore acme.localhost --from "$SET2" --with-files --dry-run --json --bench-dir "$BENCH"
  token="$(printf '%s' "$OUT" | jget - 'd["token"]')"
  MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw run_json site restore acme.localhost --from "$SET2" --with-files --apply "$token" --yes --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["applied"] is True and d["ok"] is True and d["site"] == "acme.localhost" and d["new"] is False, d
assert [s["status"] for s in d["steps"]] == ["done"] * 6, d["steps"]
assert d["backup"]["with_files"] is True and d["backup"]["stamp"] not in ("20260901_090000", "20260902_090000"), d["backup"]
assert "frappe" in d["verify"]["apps"] and d["verify"]["default_site"] == "macdev", d["verify"]
' || fail "the site restore result"$'\n'"$OUT"
  b="$(at '^bench --site acme.localhost backup --with-files$')"
  r="$(at '^python benchbar-frappe acme.localhost restore ')"
  m="$(at '^bench --site acme.localhost migrate$')"
  [[ -n "$b" && -n "$r" && -n "$m" && "$b" -lt "$r" && "$r" -lt "$m" ]] || fail "backup, restore, migrate in order (${b} ${r} ${m})"$'\n'"$(cat "$MOCK_LOG")"
  assert_calls_contain "^python benchbar-frappe acme.localhost restore --mariadb-root-password [^ ]*/20260902_090000-acme_localhost-database.sql.gz --with-public-files [^ ]*-files.tar --with-private-files [^ ]*-private-files.tar$"
  assert_eq "rootpw" "$(cat "$MOCK_STATE/stdin-restore")" "(the root password reaches restore on stdin)"
  assert_eq "$SETKEY" "$(conf_get acme.localhost encryption_key)" "(the key of the set)"
  assert_eq "" "$(conf_get acme.localhost mute_emails)" "(a restored site is not a copy: email is not muted)"
  assert_eq "" "$(conf_get acme.localhost pause_scheduler)"
  assert_eq "macdev" "$(default_site)" "(the default site never moves)"
  assert_calls_not_contain '^bench use'
  assert_calls_not_contain "^bench (--site acme.localhost )?(set-config|disable-scheduler)"
  assert_calls_contain '^bench --site acme.localhost clear-cache$'
  assert_calls_contain '^redis-server config/redis_queue.conf --daemonize yes$'
  assert_calls_contain '^redis-cli -p 11000 shutdown save$'
  ! grep -q -F -- rootpw "$MOCK_LOG" || fail "the root password is in the mock call log"
  ! grep -q -F -- adminpw "$MOCK_LOG" || fail "the Administrator password is in the mock call log"
  ! grep -r -q -F -- rootpw "$FL_STATE_DIR/logs" 2>/dev/null || fail "the root password is in the run log"
  assert_not_contains "$OUT$ERR" rootpw
  compgen -G "$BENCH/sites/acme.localhost/private/backups/*-files.tar" >/dev/null || fail "the backup taken first has files"

  # ---- the same through the text form: --yes needs no token
  reset_calls
  run_fm site restore acme.localhost --from "$SET1" --yes --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
  assert_contains "$OUT" "acme.localhost is restored from ${SET1}"
  assert_contains "$OUT" "the default site stays macdev"
  assert_calls_not_contain '^python benchbar-frappe acme.localhost restore .*--with-public-files'
  # without --yes and without a terminal nothing is asked and nothing runs
  reset_calls
  run_fm site restore acme.localhost --from "$SET1" --bench-dir "$BENCH" </dev/null
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "Cancelled. Nothing was changed."
  assert_calls_not_contain '^(bench|python benchbar|redis-server)'

  # ---- --no-migrate: the restore ends before migrate
  reset_calls
  run_json site restore acme.localhost --from "$SET1" --no-migrate --dry-run --json --bench-dir "$BENCH"
  assert_eq "False" "$(printf '%s' "$OUT" | jget - '"migrate" in [s["id"] for s in d["steps"]]')"
  assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["migrate"]')"
  token="$(printf '%s' "$OUT" | jget - 'd["token"]')"
  run_json site restore acme.localhost --from "$SET1" --no-migrate --apply "$token" --yes --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  assert_calls_contain '^python benchbar-frappe acme.localhost restore '
  assert_calls_not_contain 'migrate$'
  assert_contains "$ERR" "migrate was skipped (--no-migrate)"
  assert_eq "True" "$(printf '%s' "$OUT" | jget - 'any("--no-migrate" in w for w in d["warnings"])')"

  # ---- --before-migrate: after the restore, before migrate, no secret in its environment
  reset_calls; rm -f "$MOCK_STATE/hook_env"
  run_json site restore acme.localhost --from "$SET1" --before-migrate "$HOOK" --dry-run --json --bench-dir "$BENCH"
  assert_eq "restore encryption_key before_migrate migrate" "$(printf '%s' "$OUT" | jget - '" ".join(s["id"] for s in d["steps"] if s["id"] in ("restore","encryption_key","before_migrate","migrate"))')"
  token="$(printf '%s' "$OUT" | jget - 'd["token"]')"
  export ACME_API_TOKEN=tok1 MY_PASSWORD=pw1 DB_SECRET=s1 SSH_PASSPHRASE=pp1 STRIPE_KEY=k1 KEEP_ME=kept
  MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw run_json site restore acme.localhost --from "$SET1" --before-migrate "$HOOK" --apply "$token" --yes --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  r="$(at '^python benchbar-frappe acme.localhost restore ')"; h="$(at '^hook ran$')"; m="$(at '^bench --site acme.localhost migrate$')"
  [[ -n "$r" && -n "$h" && -n "$m" && "$r" -lt "$h" && "$h" -lt "$m" ]] || fail "restore, hook, migrate in order (${r} ${h} ${m})"$'\n'"$(cat "$MOCK_LOG")"
  assert_file "$MOCK_STATE/hook_env"
  grep -q "^cwd=$BENCH\$" "$MOCK_STATE/hook_env" || fail "the hook runs in the bench folder"
  grep -q '^BENCHBAR_SITE=acme.localhost$' "$MOCK_STATE/hook_env" || fail "BENCHBAR_SITE"
  grep -q "^BENCHBAR_BENCH=$BENCH\$" "$MOCK_STATE/hook_env" || fail "BENCHBAR_BENCH"
  grep -q '^BENCHBAR_DB_NAME=_mock[0-9]*$' "$MOCK_STATE/hook_env" || fail "BENCHBAR_DB_NAME is the site's database"$'\n'"$(cat "$MOCK_STATE/hook_env")"
  grep -q '^KEEP_ME=kept$' "$MOCK_STATE/hook_env" || fail "the rest of the environment stays"
  for v in MARIADB_ROOT_PASSWORD ADMIN_PASSWORD ACME_API_TOKEN MY_PASSWORD DB_SECRET SSH_PASSPHRASE STRIPE_KEY; do
    ! grep -q "^${v}=" "$MOCK_STATE/hook_env" || fail "${v} is in the hook's environment"
  done
  for v in rootpw adminpw tok1 pw1 s1 pp1 k1; do
    ! grep -q -F -- "=${v}" "$MOCK_STATE/hook_env" || fail "the value ${v} is in the hook's environment"
  done
  # a failing hook stops before migrate: the restore is done, nothing after it
  reset_calls
  HOOK_EXIT=3 run_json site restore acme.localhost --from "$SET1" --before-migrate "$HOOK" --apply "$token" --yes --json --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT$ERR"
  assert_calls_contain '^python benchbar-frappe acme.localhost restore '
  assert_calls_contain '^hook ran$'
  assert_calls_not_contain 'migrate$'
  assert_calls_not_contain 'clear-cache$'
  assert_contains "$ERR" "the --before-migrate script failed; acme.localhost is restored but not migrated"
  assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["ok"]')"
  assert_eq "done done failed skipped skipped skipped" "$(printf '%s' "$OUT" | jget - '" ".join(s["status"] for s in d["steps"][1:])')" "$(printf '%s' "$OUT" | jget - '[s["id"] + ":" + s["status"] for s in d["steps"]]')"
  assert_calls_contain '^redis-cli -p 11000 shutdown save$' "(the Redis this run started is stopped when it fails)"
  unset ACME_API_TOKEN MY_PASSWORD DB_SECRET SSH_PASSPHRASE STRIPE_KEY KEEP_ME
  # a hook that moves the default site: the end check puts it back
  reset_calls
  HOOK_MOVE_DEFAULT=acme.localhost run_json site restore acme.localhost --from "$SET1" --before-migrate "$HOOK" --apply "$token" --yes --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  assert_eq "macdev" "$(default_site)" "(the default site is put back)"
  assert_calls_contain '^bench use macdev$'
  assert_contains "$ERR" "moved the default site to acme.localhost; it is back on macdev"

  # ---- a new site: created, then restored into; the key of the set; no backup step
  reset_calls
  run_json site restore "$fresh" --from "$SET2" --from-site acme.localhost --new --with-files --dry-run --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
ids = [s["id"] for s in d["steps"]]
assert d["can_apply"] is True and d["new"] is True and d["exists"] is False, d
assert ids[0] == "new_site" and "local_backup" not in ids and ids[-1] == "verify", ids
assert d["backup_first"]["will_run"] is False, d["backup_first"]
assert d["source"]["site"] == "acme.localhost", d["source"]
' || fail "the plan for a new site"$'\n'"$OUT"
  token="$(printf '%s' "$OUT" | jget - 'd["token"]')"
  assert_calls_not_contain '^(bench|python benchbar|redis-server)'
  assert_no_file "$BENCH/sites/$fresh"
  MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw run_json site restore "$fresh" --from "$SET2" --from-site acme.localhost --new --with-files --apply "$token" --yes --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["ok"] and d["new"] and d["backup"] is None')"
  n="$(at "^bench new-site ${fresh} ")"; r="$(at "^python benchbar-frappe ${fresh} restore ")"
  [[ -n "$n" && -n "$r" && "$n" -lt "$r" ]] || fail "new-site before the restore (${n} ${r})"$'\n'"$(cat "$MOCK_LOG")"
  assert_calls_not_contain "^bench --site ${fresh} backup"
  assert_eq "rootpw" "$(sed -n 1p "$MOCK_STATE/stdin-new-site")" "(the root password reaches new-site on stdin)"
  assert_eq "adminpw" "$(sed -n 2p "$MOCK_STATE/stdin-new-site")" "(ADMIN_PASSWORD is the new site's Administrator password)"
  assert_eq "$SETKEY" "$(conf_get "$fresh" encryption_key)" "(the key of the set, not the one new-site made)"
  assert_eq "macdev" "$(default_site)" "(a new site does not become the default)"
  assert_calls_not_contain '^bench (use|set-config)'
  run_fm site list --bench-dir "$BENCH"
  assert_contains "$OUT" "$fresh"
  ! grep -q -F -- rootpw "$MOCK_LOG" || fail "the root password is in the mock call log"
  ! grep -q -F -- adminpw "$MOCK_LOG" || fail "the Administrator password is in the mock call log"
  if [[ "$tag" == "mac" ]]; then grep -q "^127.0.0.1 ${fresh}\$" "$FL_HOSTS_FILE" || fail "the hosts line of the new site"; fi
  # a generated Administrator password: 24 letters and digits, never shown
  reset_calls
  run_fm site restore "${fresh%%.*}2.localhost" --from "$SET1" --from-site acme.localhost --new --yes --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
  assert_eq "24" "$(sed -n 2p "$MOCK_STATE/stdin-new-site" | tr -d '\n' | wc -c | tr -d ' ')" "(a generated password)"
  assert_not_contains "$OUT" "$(sed -n 2p "$MOCK_STATE/stdin-new-site")"
  assert_eq "macdev" "$(default_site)"
  # a new-site that fails: the restore never starts, the marker stays
  reset_calls
  MOCK_BENCH_NEW_SITE_EXIT=1 run_fm site restore broken.localhost --from "$SET1" --from-site acme.localhost --new --yes --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"
  assert_calls_not_contain 'benchbar-frappe broken.localhost restore'
  assert_file "$BENCH/logs/.benchbar/creating-broken.localhost" "(the marker stays after a failed new-site)"
  rm -f "$BENCH/logs/.benchbar/creating-broken.localhost"
  # the stamp of another site is not the target's own
  run_fm site restore "$fresh" --from "$SET2" --new --from-site nosuch --dry-run --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "no backups of nosuch"

  # ---- the source as a path: the database file, or a folder
  reset_calls
  run_fm site restore acme.localhost --from "$BENCH/sites/acme.localhost/private/backups/${SET1}-acme_localhost-database.sql.gz" --yes --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
  assert_calls_contain "^python benchbar-frappe acme.localhost restore --mariadb-root-password [^ ]*/${SET1}-acme_localhost-database.sql.gz\$"
  mkdir -p "$TMP_DIR/downloaded"; cp "$BENCH"/sites/acme.localhost/private/backups/${SET2}-* "$TMP_DIR/downloaded/"
  reset_calls
  run_fm site restore acme.localhost --from "$TMP_DIR/downloaded" --with-files --yes --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
  assert_calls_contain "^python benchbar-frappe acme.localhost restore --mariadb-root-password [^ ]*/downloaded/${SET2}-acme_localhost-database.sql.gz --with-public-files"
  assert_file "$TMP_DIR/downloaded/${SET2}-acme_localhost-database.sql.gz" "(the folder is left as it was)"

  # ---- the end state is checked: a restore that leaves no apps fails verify
  reset_calls
  : >"$TMP_DIR/empty.sql"; gzip -c "$TMP_DIR/empty.sql" >"$BENCH/sites/acme.localhost/private/backups/20260904_090000-acme_localhost-database.sql.gz"
  run_json site restore acme.localhost --from 20260904_090000 --dry-run --json --bench-dir "$BENCH"
  token="$(printf '%s' "$OUT" | jget - 'd["token"]')"
  run_json site restore acme.localhost --from 20260904_090000 --yes --json --apply "$token" --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT$ERR"
  assert_contains "$ERR" "does not answer list-apps with frappe"
  assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["ok"]')"
  rm -f "$BENCH"/sites/acme.localhost/private/backups/20260904_090000-*

  # ---- a running bench: its scheduler is paused for the restore and resumed
  add_proc 4242 "honcho start -f Procfile.lean" "$BENCH"
  reset_calls
  run_fm site restore acme.localhost --from "$SET1" --yes --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
  assert_contains "$OUT" "Pause this bench's scheduler during the restore"
  q="$(at 'set-config -g -p pause_scheduler 1$')"; r="$(at '^python benchbar-frappe acme.localhost restore ')"; u="$(at 'config remove-common-config pause_scheduler$')"
  [[ -n "$q" && -n "$r" && -n "$u" && "$q" -lt "$r" && "$r" -lt "$u" ]] || fail "pause, restore, resume (${q} ${r} ${u})"
  : >"$MOCK_PROCS"

  # ---- the root password: unknown to benchbar is said in the plan and refused (exit 2) on apply
  rm -f "$MOCK_STATE/keychain/benchbar-mariadb--root" "$FL_STATE_DIR/secrets/mariadb-root"
  reset_calls
  run_json site restore acme.localhost --from "$SET1" --dry-run --json --bench-dir "$BENCH"
  assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')"
  assert_contains "$OUT" "MariaDB root password is unknown to benchbar"
  run_fm site restore acme.localhost --from "$SET1" --yes --bench-dir "$BENCH"
  assert_eq "2" "$CODE" "$OUT"
  assert_calls_not_contain '^(bench|python benchbar|redis-server)'
  printf 'rootpw\n' >"$MOCK_STATE/keychain/benchbar-mariadb--root"; printf 'rootpw\n' >"$FL_STATE_DIR/secrets/mariadb-root"
  # MariaDB down
  sed_inplace '/^3306 /d' "$MOCK_LISTEN"
  run_fm site restore acme.localhost --from "$SET1" --dry-run --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "MariaDB is not running"
  printf '3306 111 mariadbd 127.0.0.1\n' >>"$MOCK_LISTEN"

  # ---- the default site itself can be restored into; it stays the default
  make_set macdev 20260905_090000
  reset_calls
  run_fm site restore macdev --from 20260905_090000 --yes --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
  assert_eq "macdev" "$(default_site)"
}

suite mac fresh.localhost

# the same on Linux: the password file in place of the Keychain, no hosts line
use_linux
suite linux fresh.localhost

printf 'test-site-restore: ok\n'
