#!/usr/bin/env bash
#
# snapshots-suite.sh: the body of the site snapshot, snapshots and rollback tests, shared by
# test-snapshots (macOS platform) and test-snapshots-2 (use_linux), so the two passes run side
# by side. Defines suite TAG; sources the harness.

# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

# JSON calls: stdout in OUT, stderr in ERR, apart
run_json() {
  set +e
  OUT="$("$FM" "$@" 2>"$MOCK_STATE/stderr")"
  CODE="$?"
  ERR="$(cat "$MOCK_STATE/stderr")"
  set -e
}
# the dump every backup of the mock bench holds: a restore reads the installed apps out of it
SQL="$TMP_DIR/dump.sql"
cat >"$SQL" <<'SQLEOF'
INSERT INTO `tabDefaultValue` VALUES ('a','__default','installed_apps','[\"frappe\",\"erpnext\"]');
SQLEOF
export MOCK_BENCH_BACKUP_DB="$TMP_DIR/dump.sql.gz"
gzip -c "$SQL" >"$MOCK_BENCH_BACKUP_DB"
# line numbers of the first mock call matching a pattern
at() { grep -m1 -n -E -- "$1" "$MOCK_LOG" | cut -d: -f1; }
git_commit() { (cd "$BENCH/apps/$1" && printf '%s\n' "$2" >>README && git add README && git -c user.email=t@example.com -c user.name=t commit -q -m "$2"); }
snap_names() { local d; for d in "$SNAPS"/2026*; do [[ -d "$d" ]] && basename "$d"; done; return 0; }
snap_count() { snap_names | wc -l | tr -d ' '; }
git_head() { git -C "$BENCH/apps/$1" rev-parse HEAD; }

suite() {
  local tag="$1" id1 id2 id3 before plan token n S SNAPS d benv r m undo2 failed3 undo4 part
  BENCH="$HOME/dev/snap-$tag"
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
  # two apps with real commits, so the manifest has something to compare
  export MOCK_GIT_REAL=1
  for d in frappe erpnext; do
    printf '%s\n' "$d" >"$BENCH/apps/$d/README"
    (cd "$BENCH/apps/$d" && git init -q -b version-15 . && git add README && git -c user.email=t@example.com -c user.name=t commit -q -m init)
  done
  # a second site; macdev stays the default
  mkdir -p "$BENCH/sites/acme.localhost"; printf '{"db_name":"_acme","db_password":"acmedbpw"}\n' >"$BENCH/sites/acme.localhost/site_config.json"
  printf '127.0.0.1 macdev acme.localhost\n' >>"$FL_HOSTS_FILE"
  S="$BENCH/sites/acme.localhost"; SNAPS="$S/snapshots"
  reset_calls

  # ---- refusals and an empty list: nothing runs, no lock for the list
  run_json site snapshots acme.localhost --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  assert_eq "1 acme.localhost 0 10" "$(printf '%s' "$OUT" | jget - '"%s %s %d %s" % (d["schema_version"], d["site"], len(d["snapshots"]), d["keep"])')"
  run_fm site snapshots acme.localhost --bench-dir "$BENCH"
  assert_contains "$OUT" "no snapshots of acme.localhost yet"
  run_fm site snapshot nosuch --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "No site 'nosuch'"
  run_fm site snapshot acme.localhost --label 'a"b' --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "no quotes, backslashes or control characters"
  run_fm site snapshot acme.localhost --label 'a\b' --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "no quotes, backslashes or control characters"
  run_fm site snapshot acme.localhost --bogus --bench-dir "$BENCH"
  assert_eq "64" "$CODE" "$OUT"; assert_contains "$OUT" "Unknown option for site snapshot: --bogus"
  run_fm site rollback acme.localhost --bench-dir "$BENCH" --dry-run
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "--to SNAPSHOT names the snapshot"
  run_fm site rollback acme.localhost --to 20200101_000000 --bench-dir "$BENCH" --dry-run
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "no snapshot '20200101_000000' of acme.localhost"
  run_fm site rollback acme.localhost --to latest --bench-dir "$BENCH" --dry-run
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "has no complete snapshot"
  assert_calls_not_contain '^(bench|python benchbar|redis-server)'

  # ---- free space: a snapshot that cannot fit is refused before bench writes anything
  printf '%s' 1 >"$MOCK_STATE/df_avail_kb"
  reset_calls
  run_fm site snapshot acme.localhost --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "not enough free space for a snapshot of acme.localhost"
  assert_calls_not_contain '^(bench|redis-server)'
  assert_eq "0" "$(snap_count)" "(nothing was written)"
  printf '%s' 52428800 >"$MOCK_STATE/df_avail_kb"

  # ---- snapshot: bench's backup with files, moved out of private/backups, with its manifest
  reset_calls
  run_json site snapshot acme.localhost --label "Before upgrade" --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  assert_calls_contain '^bench --site acme.localhost backup --with-files$'
  id1="$(printf '%s' "$OUT" | jget - 'd["snapshot"]["id"]')"
  assert_eq "20260929_100001-before-upgrade" "$id1"
  printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
s = d["snapshot"]
assert d["dry_run"] is False and d["keep"] == 10 and d["over_limit"] == [], d
assert s["label"] == "Before upgrade" and s["with_files"] is True and s["complete"] is True and s["size_bytes"] > 0, s
assert s["time"].endswith("Z") and s["stamp"] == "20260929_100001" and s["before_rollback"] is False, s
assert [a["name"] for a in s["apps"]] == ["frappe", "erpnext"] and s["apps_match"] is True and s["changed_apps"] == [], s
' || fail "the snapshot result"$'\n'"$OUT"
  assert_eq "$(git_head frappe)" "$(printf '%s' "$OUT" | jget - 'd["snapshot"]["apps"][0]["commit"]')" "(the commit of the app)"
  for n in database.sql.gz files.tar private-files.tar site_config_backup.json; do assert_file "$SNAPS/$id1/20260929_100001-acme_localhost-$n"; done
  assert_file "$SNAPS/$id1/manifest.json"
  assert_eq "" "$(ls "$S/private/backups" 2>/dev/null)" "(the files moved: private/backups holds nothing of it)"
  assert_eq "700" "$(stat -c %a "$SNAPS" 2>/dev/null || stat -f %Lp "$SNAPS")" "(only the owner reads the dumps)"
  assert_calls_contain '^redis-cli -p 11000 shutdown save$'
  # a snapshot changes nothing in the site
  assert_eq '{"db_name":"_acme","db_password":"acmedbpw"}' "$(cat "$S/site_config.json")"
  assert_calls_not_contain '^(bench --site acme.localhost (migrate|set-config)|python benchbar-frappe)'
  # the same label in the same second is a second snapshot, never an overwrite
  MOCK_BENCH_BACKUP_STAMP=20260929_100001 run_json site snapshot acme.localhost --label "Before upgrade" --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  assert_eq "20260929_100001-before-upgrade-2" "$(printf '%s' "$OUT" | jget - 'd["snapshot"]["id"]')"
  assert_file "$SNAPS/$id1/20260929_100001-acme_localhost-database.sql.gz"
  rm -rf "$SNAPS/20260929_100001-before-upgrade-2"
  # the text form
  run_fm site snapshot acme.localhost --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
  assert_contains "$OUT" "snapshot 20260929_100003 of acme.localhost"
  assert_contains "$OUT" "put it back with: benchbar site rollback acme.localhost --to 20260929_100003"
  # a failed backup leaves no snapshot folder
  MOCK_BENCH_BACKUP_EXIT=1 run_json site snapshot acme.localhost --json --bench-dir "$BENCH"
  assert_eq "1" "$CODE"; assert_eq "" "$OUT"
  assert_eq "2" "$(snap_count)" "(a failed backup adds nothing)"
  # a dry run runs nothing
  reset_calls
  run_fm site snapshot acme.localhost --dry-run --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"; assert_calls_not_contain '^bench --site'

  # ---- frappe's pruning never touches a snapshot (a later backup deletes what is in private/backups)
  MOCK_BENCH_BACKUP_PRUNE=1 run_json site snapshot acme.localhost --label "second" --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  id2="$(printf '%s' "$OUT" | jget - 'd["snapshot"]["id"]')"
  assert_file "$SNAPS/$id1/20260929_100001-acme_localhost-database.sql.gz"
  assert_file "$SNAPS/$id2/manifest.json"

  # ---- the list: newest first, with the apps compared with the bench
  run_json site snapshots acme.localhost --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  assert_eq "3 True,True,True" "$(printf '%s' "$OUT" | jget - '"%d %s" % (len(d["snapshots"]), ",".join(str(x["apps_match"]) for x in d["snapshots"]))')"
  assert_eq "$id2" "$(printf '%s' "$OUT" | jget - 'd["snapshots"][0]["id"]')" "(newest first)"
  run_fm site snapshots acme.localhost --bench-dir "$BENCH"
  assert_contains "$OUT" "before-upgrade"; assert_contains "$OUT" "same apps"; assert_contains "$OUT" "frappe@$(git_head frappe | cut -c1-7)"
  # an app moves on after the snapshot: allowed, and said
  git_commit erpnext "a new commit"
  run_json site snapshots acme.localhost --json --bench-dir "$BENCH"
  assert_eq "False erpnext" "$(printf '%s' "$OUT" | jget - '"%s %s" % (d["snapshots"][0]["apps_match"], " ".join(d["snapshots"][0]["changed_apps"]))')"
  run_fm site snapshots acme.localhost --bench-dir "$BENCH"
  assert_contains "$OUT" "changed: erpnext"

  # ---- the listing says how much the snapshots hold and how much is free
  run_json site snapshots acme.localhost --json --bench-dir "$BENCH"
  assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["total_bytes"] > 0 and d["free_bytes"] == 52428800 * 1024')"
  run_fm site snapshots acme.localhost --bench-dir "$BENCH"
  assert_contains "$OUT" "the snapshots hold"; assert_contains "$OUT" "are free on this volume"
  # --to latest skips a newer folder that is no snapshot (a cut short one: no manifest, no dump)
  mkdir -p "$SNAPS/20260930_000000-half"; printf 'x' >"$SNAPS/20260930_000000-half/20260930_000000-acme_localhost-files.tar"
  run_json site rollback acme.localhost --to latest --dry-run --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  assert_eq "$id2" "$(printf '%s' "$OUT" | jget - 'd["rollback"]["snapshot"]')" "(the half folder is skipped)"
  assert_contains "$ERR" "skipped incomplete snapshot(s): 20260930_000000-half"
  rm -f "$SNAPS/20260930_000000-half/20260930_000000-acme_localhost-files.tar"; rmdir "$SNAPS/20260930_000000-half"

  # ---- an incomplete snapshot is no plan, chosen by name too: refused before any token, one part at a time
  for part in manifest.json database.sql.gz files.tar private-files.tar site_config_backup.json; do
    d="$SNAPS/20260930_000002-cut"; mkdir -p "$d"; cp "$SNAPS/$id1"/* "$d/"
    rm -f "$d/20260929_100001-acme_localhost-${part}"
    [[ "$part" != manifest.json ]] || rm -f "$d/manifest.json"
    case "$part" in manifest.json) n="the manifest" ;; database.sql.gz) n="the database dump" ;; files.tar) n="the public files" ;; private-files.tar) n="the private files" ;; *) n="site_config" ;; esac
    run_json site rollback acme.localhost --to 20260930_000002-cut --dry-run --json --bench-dir "$BENCH"
    assert_eq "1" "$CODE" "(without ${part}: $OUT$ERR)"
    assert_contains "$ERR" "is incomplete (it lacks ${n})"
    assert_eq "" "$OUT" "(no plan, no token, without ${part})"
    run_json site snapshots acme.localhost --json --bench-dir "$BENCH"
    assert_eq "False" "$(printf '%s' "$OUT" | jget - 'any(x["id"] == "20260930_000002-cut" and x["complete"] for x in d["snapshots"])')" "(listed incomplete without ${part})"
    rm -f "$d"/*; rmdir "$d"
  done
  # the cut short run of the review: the dump and the public files, nothing else
  d="$SNAPS/20260930_000003-half"; mkdir -p "$d"
  cp "$SNAPS/$id1/20260929_100001-acme_localhost-database.sql.gz" "$SNAPS/$id1/20260929_100001-acme_localhost-files.tar" "$d/"
  reset_calls
  run_json site rollback acme.localhost --to 20260930_000003-half --dry-run --json --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT$ERR"; assert_contains "$ERR" "is incomplete"
  MARIADB_ROOT_PASSWORD=rootpw run_fm site rollback acme.localhost --to 20260930_000003-half --apply "$(printf '%064d' 0)" --yes --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "is incomplete"
  assert_calls_not_contain '^(bench|python benchbar|redis-server)'
  # a person can still remove it by name
  run_fm site snapshot drop acme.localhost 20260930_000003-half --yes --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"; assert_no_file "$d"

  # ---- a snapshot that cannot get its manifest or its parts into place leaves nothing that is listed
  mkdir -p "$TMP_DIR/failmv"
  cat >"$TMP_DIR/failmv/mv" <<'MVEOF'
#!/bin/bash
for last; do :; done
case "${FAIL_MV:-}:${last}" in
  manifest:*/manifest.json) exit 1 ;;
  move:*/snapshots/.incomplete-*/*private-files.tar) exit 1 ;;
esac
exec /bin/mv "$@"
MVEOF
  chmod +x "$TMP_DIR/failmv/mv"
  n="$(snap_count)"
  for part in manifest move; do
    FAIL_MV="$part" PATH="$TMP_DIR/failmv:$PATH" run_json site snapshot acme.localhost --json --bench-dir "$BENCH"
    assert_eq "1" "$CODE" "(${part}: $OUT$ERR)"
    assert_eq "$n" "$(snap_count)" "(a failed ${part} adds no snapshot)"
    assert_eq "4" "$(find "$S/private/backups" -type f | wc -l | tr -d ' ')" "(${part}: the set is back where bench wrote it)"
    assert_eq "" "$(find "$SNAPS" -maxdepth 1 -name '.incomplete-*')" "(${part}: no folder is left behind)"
    rm -f "$S/private/backups"/*
  done
  assert_contains "$ERR" "could not move"

  # ---- the space check of a site with no earlier dump: the size of its database, else its files, at least 64 MB
  mkdir -p "$BENCH/sites/dump.localhost"; printf '{"db_name":"_dumpdb","db_password":"x"}\n' >"$BENCH/sites/dump.localhost/site_config.json"
  printf '127.0.0.1 dump.localhost\n' >>"$FL_HOSTS_FILE"
  printf '%s' 60000 >"$MOCK_STATE/df_avail_kb"
  run_fm site snapshot dump.localhost --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "not enough free space for a snapshot of dump.localhost"
  assert_contains "$(cat "$MOCK_STATE/df_args")" "-Pk"
  printf '%s' 209715200 >"$MOCK_STATE/mariadb_size._dumpdb"
  printf '%s' 100000 >"$MOCK_STATE/df_avail_kb"
  run_fm site snapshot dump.localhost --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "(the database in MariaDB is 200 MB: $OUT)"; assert_contains "$OUT" "not enough free space"
  printf '%s' 1000 >"$MOCK_STATE/mariadb_size._dumpdb"
  run_fm site snapshot dump.localhost --bench-dir "$BENCH"
  assert_not_contains "$OUT" "not enough free space" "(a small database fits)"
  rm -f "$MOCK_STATE/mariadb_size._dumpdb"
  printf '%s' 52428800 >"$MOCK_STATE/df_avail_kb"

  # ---- the rollback plan across an app change: read only, with a token, migrate and a warning
  reset_calls
  run_json site rollback acme.localhost --to "$id1" --dry-run --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  plan="$OUT"
  printf '%s' "$plan" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["schema_version"] == 1 and d["can_apply"] is True and d["errors"] == [], d
assert len(d["token"]) == 64 and d["exists"] is True and d["new"] is False, d
assert [s["id"] for s in d["steps"]] == ["snapshot", "restore", "encryption_key", "migrate", "clear_cache", "verify"], [s["id"] for s in d["steps"]]
assert d["steps"][0]["name"] == "Snapshot acme.localhost first (label: before rollback)", d["steps"][0]
assert d["touches"] == ["backup", "database", "files", "site_config"], d["touches"]
assert d["migrate"] is True and d["source"]["restores_files"] is True, d
r = d["rollback"]
assert r["snapshot"] == "'"$id1"'" and r["label"] == "Before upgrade" and r["apps_match"] is False and r["changed_apps"] == ["erpnext"], r
assert r["snapshot_first"] == "before rollback" and r["default_site"] is False, r
assert any("changed since the snapshot (erpnext)" in w for w in d["warnings"]), d["warnings"]
' || fail "the rollback plan"$'\n'"$plan"
  assert_calls_not_contain '^(bench|python benchbar|redis-server|sudo)'
  token="$(printf '%s' "$plan" | jget - 'd["token"]')"
  run_json site rollback acme.localhost --to "$id1" --dry-run --json --bench-dir "$BENCH"
  assert_eq "$token" "$(printf '%s' "$OUT" | jget - 'd["token"]')" "(the same plan twice, the same token)"
  # a name, a stamp, or a start of one name the same snapshot
  run_json site rollback acme.localhost --to 20260929_100001 --dry-run --json --bench-dir "$BENCH"
  assert_eq "$token" "$(printf '%s' "$OUT" | jget - 'd["token"]')"
  run_fm site rollback acme.localhost --to "$id1" --dry-run --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
  assert_contains "$OUT" "Snapshot acme.localhost first (label: before rollback)"
  assert_contains "$OUT" "changed since the snapshot (erpnext)"
  assert_contains "$OUT" "after the restore, because the apps changed"
  # a rollback writes one more snapshot first: without the room the plan cannot be applied
  printf '%s' 1 >"$MOCK_STATE/df_avail_kb"
  run_json site rollback acme.localhost --to "$id1" --dry-run --json --bench-dir "$BENCH"
  assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')"
  assert_contains "$OUT" "not enough free space for a snapshot of acme.localhost"
  printf '%s' 52428800 >"$MOCK_STATE/df_avail_kb"
  # --no-migrate is its own plan, and still warns
  run_json site rollback acme.localhost --to "$id1" --no-migrate --dry-run --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["migrate"]')"
  [[ "$(printf '%s' "$OUT" | jget - 'd["token"]')" != "$token" ]] || fail "a plan without migrate has its own token"
  # the token needs --yes, and apply refuses a dry run flag next to it
  run_fm site rollback acme.localhost --to "$id1" --apply "$token" --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "pass its token with --apply TOKEN --yes"
  assert_calls_not_contain '^(bench|python benchbar|redis-server)'

  # ---- a stale token: the snapshot changed after the plan, nothing runs
  reset_calls
  cp "$SNAPS/$id1/20260929_100001-acme_localhost-database.sql.gz" "$TMP_DIR/db.keep"
  { cat "$TMP_DIR/db.keep"; cat "$TMP_DIR/db.keep"; } >"$SNAPS/$id1/20260929_100001-acme_localhost-database.sql.gz"
  MARIADB_ROOT_PASSWORD=rootpw run_fm site rollback acme.localhost --to "$id1" --apply "$token" --yes --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "plan changed since it was shown"
  assert_contains "$OUT" "Review a fresh plan: benchbar site rollback acme.localhost --to $id1 --dry-run --json"
  assert_calls_not_contain '^(bench|python benchbar|redis-server)'
  cp "$TMP_DIR/db.keep" "$SNAPS/$id1/20260929_100001-acme_localhost-database.sql.gz"
  # a snapshot with a cut short database file is no plan at all
  printf 'not gzip' >"$SNAPS/$id2/20260929_100004-acme_localhost-database.sql.gz"
  run_json site rollback acme.localhost --to "$id2" --dry-run --json --bench-dir "$BENCH"
  assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')"
  assert_contains "$OUT" "not a complete gzip file"
  gzip -c "$ROOT/tests/lib/harness.sh" >"$SNAPS/$id2/20260929_100004-acme_localhost-database.sql.gz"

  # ---- apply across an app change: snapshot first, restore from the snapshot, migrate, verify
  reset_calls
  run_json site rollback acme.localhost --to "$id1" --dry-run --json --bench-dir "$BENCH"
  token="$(printf '%s' "$OUT" | jget - 'd["token"]')"
  MARIADB_ROOT_PASSWORD=rootpw run_json site rollback acme.localhost --to "$id1" --apply "$token" --yes --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["applied"] is True and d["ok"] is True and d["site"] == "acme.localhost", d
assert [s["status"] for s in d["steps"]] == ["done", "done", "skipped", "done", "done", "done"], d["steps"]
assert d["steps"][0]["id"] == "snapshot", d["steps"]
r = d["rollback"]
assert r["snapshot"] == "'"$id1"'" and r["before_rollback"].endswith("-before-rollback"), r
assert r["undo"] == "benchbar site rollback acme.localhost --to " + r["before_rollback"], r
assert d["verify"]["default_site"] == "macdev", d["verify"]
' || fail "the rollback result"$'\n'"$OUT"
  before="$(printf '%s' "$OUT" | jget - 'd["rollback"]["before_rollback"]')"
  n="$(at '^bench --site acme.localhost backup --with-files$')"
  r="$(at '^python benchbar-frappe acme.localhost restore ')"
  m="$(at '^bench --site acme.localhost migrate$')"
  [[ -n "$n" && -n "$r" && -n "$m" && "$n" -lt "$r" && "$r" -lt "$m" ]] || fail "snapshot, restore, migrate in order (${n} ${r} ${m})"$'\n'"$(cat "$MOCK_LOG")"
  assert_calls_contain "^python benchbar-frappe acme.localhost restore --mariadb-root-password [^ ]*/snapshots/${id1}/20260929_100001-acme_localhost-database.sql.gz --with-public-files [^ ]*/snapshots/${id1}/[^ ]*-files.tar --with-private-files [^ ]*/snapshots/${id1}/[^ ]*-private-files.tar$"
  assert_eq "rootpw" "$(cat "$MOCK_STATE/stdin-restore")" "(the root password reaches restore on stdin)"
  ! grep -q -F -- rootpw "$MOCK_LOG" || fail "the root password is in the mock call log"
  assert_not_contains "$OUT$ERR" rootpw
  assert_calls_not_contain '^bench use'
  assert_eq "macdev" "$(tr -d '[:space:]' <"$BENCH/sites/currentsite.txt")" "(the default site never moves)"
  # the state before the rollback is itself a snapshot, with its apps and what it was taken before
  assert_file "$SNAPS/$before/manifest.json"
  assert_eq "$before" "$(cat "$SNAPS/.last-rollback")"
  run_json site snapshots acme.localhost --json --bench-dir "$BENCH"
  assert_eq "$before True $id1" "$(printf '%s' "$OUT" | jget - '"%s %s %s" % (d["snapshots"][0]["id"], d["snapshots"][0]["before_rollback"], d["snapshots"][0]["rollback_of"])')"
  assert_eq "$before" "$(printf '%s' "$OUT" | jget - 'd["last_rollback_snapshot"]')"
  assert_eq "before rollback" "$(printf '%s' "$OUT" | jget - 'd["snapshots"][0]["label"]')"
  run_fm site snapshots acme.localhost --bench-dir "$BENCH"
  assert_contains "$OUT" "(undo point of the last rollback)"
  # the apply left no run behind: a second apply of the same token plans again (the snapshot list moved on, the plan did not)
  # ---- the rollback can be undone: to the before rollback snapshot, apps now the same as its manifest
  reset_calls
  run_json site rollback acme.localhost --to latest --dry-run --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  assert_eq "$before" "$(printf '%s' "$OUT" | jget - 'd["rollback"]["snapshot"]')" "(latest names the newest)"
  assert_eq "True False" "$(printf '%s' "$OUT" | jget - '"%s %s" % (d["rollback"]["apps_match"], d["migrate"])')" "(same apps: no migrate)"
  assert_eq "snapshot restore encryption_key clear_cache verify" "$(printf '%s' "$OUT" | jget - '" ".join(s["id"] for s in d["steps"])')"
  run_fm site rollback acme.localhost --to latest --dry-run --bench-dir "$BENCH"
  assert_contains "$OUT" "not run: the apps are the snapshot's apps"
  token="$(printf '%s' "$(MARIADB_ROOT_PASSWORD=rootpw "$FM" site rollback acme.localhost --to latest --dry-run --json --bench-dir "$BENCH" 2>/dev/null)" | jget - 'd["token"]')"
  MARIADB_ROOT_PASSWORD=rootpw run_json site rollback acme.localhost --to latest --apply "$token" --yes --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  assert_calls_not_contain '^bench --site acme.localhost migrate$'
  assert_calls_contain "^python benchbar-frappe acme.localhost restore --mariadb-root-password [^ ]*/snapshots/${before}/"
  assert_eq "False" "$(printf '%s' "$OUT" | jget - 'any(s["id"] == "migrate" for s in d["steps"])')" "(no migrate step)"
  assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["rollback"]["before_rollback"] != "'"$before"'"')" "(a new before rollback snapshot)"
  assert_eq "$(printf '%s' "$OUT" | jget - 'd["rollback"]["before_rollback"]')" "$(cat "$SNAPS/.last-rollback")"
  undo2="$(cat "$SNAPS/.last-rollback")"
  assert_eq "False" "$([[ -f "$SNAPS/.unfinished-rollbacks" ]] && echo True || echo False)" "(a finished rollback leaves nothing unfinished)"
  # a failed restore says where the snapshot of the current state is
  reset_calls
  run_json site rollback acme.localhost --to "$id1" --dry-run --json --bench-dir "$BENCH"
  token="$(printf '%s' "$OUT" | jget - 'd["token"]')"
  MOCK_FRAPPE_FAIL=restore MARIADB_ROOT_PASSWORD=rootpw run_fm site rollback acme.localhost --to "$id1" --apply "$token" --yes --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"
  assert_contains "$OUT" "acme.localhost was snapshotted first as"
  assert_contains "$OUT" "put that back with: benchbar site rollback acme.localhost --to"
  # the failed run does not move the undo point: the one of the last rollback that finished stays, and the
  # snapshot of the failed run is kept too (protected as an unfinished rollback)
  assert_eq "$undo2" "$(cat "$SNAPS/.last-rollback")" "(the undo point stays where the finished rollback put it)"
  failed3="$(snap_names | grep 'before-rollback' | sort | tail -n 1)"
  [[ "$failed3" != "$undo2" ]] || fail "the failed run took its own before rollback snapshot"
  assert_eq "$failed3" "$(cat "$SNAPS/.unfinished-rollbacks")"
  # both are protected: not on the over limit list, not dropped by name without the person's word
  run_json site snapshots acme.localhost --keep 1 --json --bench-dir "$BENCH"
  assert_eq "True" "$(printf '%s' "$OUT" | jget - '"'"$failed3"'" not in d["over_limit"] and "'"$undo2"'" not in d["over_limit"] and "'"$before"'" in d["over_limit"]')" "(the first undo point is released by the second finished rollback)"
  run_fm site snapshot drop acme.localhost "$failed3" --yes --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "is the undo point of a rollback"
  assert_file "$SNAPS/$failed3/manifest.json"
  # the retry of the same rollback (the restore works now): it takes a snapshot of the half restored site, and
  # that becomes the undo point; the snapshot of the failed run keeps its protection
  reset_calls
  run_json site rollback acme.localhost --to "$id1" --dry-run --json --bench-dir "$BENCH"
  assert_contains "$OUT" "earlier rollback of acme.localhost did not finish"
  token="$(printf '%s' "$OUT" | jget - 'd["token"]')"
  MARIADB_ROOT_PASSWORD=rootpw run_json site rollback acme.localhost --to "$id1" --apply "$token" --yes --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  undo4="$(printf '%s' "$OUT" | jget - 'd["rollback"]["before_rollback"]')"
  assert_eq "$undo4" "$(cat "$SNAPS/.last-rollback")"
  # N4: after a retry the way back is the state before the first attempt, not the half restored site
  assert_eq "benchbar site rollback acme.localhost --to ${failed3}" "$(printf '%s' "$OUT" | jget - 'd["rollback"]["undo"]')" "(the undo names the oldest unfinished snapshot)"
  assert_eq "$failed3" "$(cat "$SNAPS/.unfinished-rollbacks")" "(the real data from before the failed run stays protected)"
  run_json site snapshots acme.localhost --keep 1 --json --bench-dir "$BENCH"
  assert_eq "True" "$(printf '%s' "$OUT" | jget - '"'"$failed3"'" not in d["over_limit"] and "'"$undo4"'" not in d["over_limit"] and "'"$undo2"'" in d["over_limit"]')" "(A ok, B failed, B retried ok: B's undo point and the failed run's snapshot stay, A's is released)"
  # N3: what is held back beyond the limit is said, with its size, in the list and in the prune plan
  run_json site snapshots acme.localhost --keep 1 --json --bench-dir "$BENCH"
  assert_eq "True" "$(printf '%s' "$OUT" | jget - '"'"$failed3"'" in d["held_back"] and d["held_back_bytes"] > 0')" "(the list names the protected snapshots beyond the limit)"
  run_fm site snapshots acme.localhost --keep 1 --bench-dir "$BENCH"
  assert_contains "$OUT" "held back"; assert_contains "$OUT" "$failed3"
  run_fm site snapshot drop acme.localhost --prune --keep 1 --dry-run --bench-dir "$BENCH"
  assert_contains "$OUT" "held back"
  run_json site snapshot drop acme.localhost --prune --keep 1 --dry-run --json --bench-dir "$BENCH"
  assert_eq "True" "$(printf '%s' "$OUT" | jget - '"'"$failed3"'" in d["held_back"]')" "(the prune plan names them too)"
  run_fm site snapshot drop acme.localhost "$failed3" --yes --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_file "$SNAPS/$failed3/manifest.json"
  # a before rollback snapshot that fails stops the run before anything is replaced, and moves nothing
  run_json site rollback acme.localhost --to "$id1" --dry-run --json --bench-dir "$BENCH"
  token="$(printf '%s' "$OUT" | jget - 'd["token"]')"
  reset_calls
  MOCK_BENCH_BACKUP_EXIT=1 MARIADB_ROOT_PASSWORD=rootpw run_fm site rollback acme.localhost --to "$id1" --apply "$token" --yes --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "Nothing was replaced"
  assert_calls_not_contain 'benchbar-frappe acme.localhost restore'
  assert_eq "$undo4" "$(cat "$SNAPS/.last-rollback")" "(the undo point did not move)"
  assert_eq "$failed3" "$(cat "$SNAPS/.unfinished-rollbacks")" "(and nothing was added)"
  # the room is checked again when the token is applied, before anything is replaced
  run_json site rollback acme.localhost --to "$id1" --dry-run --json --bench-dir "$BENCH"
  token="$(printf '%s' "$OUT" | jget - 'd["token"]')"
  printf '%s' 1 >"$MOCK_STATE/df_avail_kb"
  reset_calls
  MARIADB_ROOT_PASSWORD=rootpw run_fm site rollback acme.localhost --to "$id1" --apply "$token" --yes --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "plan changed since it was shown"
  assert_calls_not_contain 'benchbar-frappe acme.localhost restore'
  printf '%s' 52428800 >"$MOCK_STATE/df_avail_kb"

  # ---- the default site: an agent never rolls it back, a person can
  run_fm site snapshot macdev --label "default" --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
  for d in "$BENCH"/sites/macdev/snapshots/*default*; do id3="${d##*/}"; done
  BENCHBAR_NONINTERACTIVE=1 run_json site rollback macdev --to "$id3" --dry-run --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')"
  assert_contains "$OUT" "macdev is the default site of this bench: rolling it back is a person's decision, not an agent's"
  assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["rollback"]["default_site"]')"
  # the agent's own apply is refused too, with the token of that plan
  token="$(printf '%s' "$OUT" | jget - 'd["token"]')"
  reset_calls
  MARIADB_ROOT_PASSWORD=rootpw run_fm --for-agent site rollback macdev --to "$id3" --apply "$token" --yes --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"
  assert_calls_not_contain '^(bench|python benchbar|redis-server)'
  # no terminal and no variable is no person either: a plain shell that left out --for-agent
  run_json site rollback macdev --to "$id3" --dry-run --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')"
  assert_contains "$OUT" "no person at a terminal"
  reset_calls
  MARIADB_ROOT_PASSWORD=rootpw run_fm site rollback macdev --to "$id3" --apply "$token" --yes --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "(--yes with no terminal: $OUT)"
  assert_calls_not_contain '^(bench|python benchbar|redis-server)'
  # a person at a terminal plans it as any site
  run_fm_tty site rollback macdev --to "$id3" --dry-run --json --bench-dir "$BENCH"
  assert_contains "$OUT" '"can_apply":true'
  # and the token applies at a terminal: stdin is pointed at /dev/null before the plan is rebuilt, so the
  # person is decided once, before that
  token="$(printf '%s' "$OUT" | grep -o '"token":"[0-9a-f]\{64\}"' | grep -o '[0-9a-f]\{64\}')"
  reset_calls
  MARIADB_ROOT_PASSWORD=rootpw run_fm_tty site rollback macdev --to "$id3" --apply "$token" --yes --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "(an apply of the default site at a terminal: $OUT)"
  assert_calls_contain "^python benchbar-frappe macdev restore "
  assert_eq "macdev" "$(tr -d '[:space:]' <"$BENCH/sites/currentsite.txt")" "(the default site never moves)"

  # ---- drop is a person's choice: refused for an agent, whatever the flags
  reset_calls
  run_fm --for-agent site snapshot drop acme.localhost "$id1" --yes --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "a person at a terminal"
  BENCHBAR_NONINTERACTIVE=1 run_fm site snapshot drop acme.localhost "$id1" --yes --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "a person at a terminal"
  assert_file "$SNAPS/$id1/manifest.json"
  # what would go is open to an agent (a plan)
  BENCHBAR_NONINTERACTIVE=1 run_json site snapshot drop acme.localhost "$id1" --dry-run --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  assert_eq "$id1" "$(printf '%s' "$OUT" | jget - 'd["would_drop"][0]')"
  assert_file "$SNAPS/$id1/manifest.json"
  # a person without --yes and without a terminal is not asked: nothing goes
  run_fm site snapshot drop acme.localhost "$id1" --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "Cancelled. Nothing was removed"
  assert_file "$SNAPS/$id1/manifest.json"

  # ---- site drop says its snapshots go into the archive with the site
  run_json site drop acme.localhost --confirm-site acme.localhost --dry-run --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["snapshots"]["count"] >= 2 and d["snapshots"]["size_bytes"] > 0')"
  assert_contains "$OUT" "snapshot(s)"
  assert_contains "$OUT" "move into the archive with it"

  # ---- N2: a folder left by a kill holds the backup files that left private/backups: named, with its size
  LEFT="$SNAPS/.incomplete-20260930_010101-killed"
  mkdir -p "$LEFT"
  printf 'data' >"$LEFT/20260930_010101-acme_localhost-database.sql.gz"
  printf '{}' >"$LEFT/manifest.json.tmp"
  m="$(snap_count)"
  run_json site snapshots acme.localhost --json --bench-dir "$BENCH"
  assert_eq "True" "$(printf '%s' "$OUT" | jget - 'len(d["leftovers"]) == 1 and d["leftovers"][0]["size_bytes"] == 6 and "private/backups" in d["leftovers"][0]["move_back"]')" "(the leftover is in the JSON)"
  run_fm site snapshots acme.localhost --bench-dir "$BENCH"
  assert_contains "$OUT" ".incomplete-20260930_010101-killed"; assert_contains "$OUT" "private/backups"
  assert_eq "$m" "$(snap_count)" "(a leftover is no snapshot)"
  rm -f "$LEFT"/*
  rmdir "$LEFT"
  run_json site snapshots acme.localhost --json --bench-dir "$BENCH"
  assert_eq "0" "$(printf '%s' "$OUT" | jget - 'len(d["leftovers"])')" "(none left)"

  # ---- retention: the newest N stay, the rest are named, nothing goes on its own
  n="$(snap_count)"
  run_json site snapshots acme.localhost --keep 2 --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  assert_eq "2" "$(printf '%s' "$OUT" | jget - 'd["keep"]')"
  assert_eq "$((n - 2))" "$(printf '%s' "$OUT" | jget - 'len(d["over_limit"])')" "(all beyond the two newest)"
  assert_eq "$n" "$(snap_count)" "(listing removes nothing)"
  run_fm site snapshots acme.localhost --keep 2 --bench-dir "$BENCH"
  assert_contains "$OUT" "retention keeps the newest 2"; assert_contains "$OUT" "nothing is removed on its own"
  # the undo point of the last rollback is never on the list, though it is old enough
  before="$(cat "$SNAPS/.last-rollback")"
  assert_eq "False" "$(printf '%s' "$(run_json site snapshots acme.localhost --keep 1 --json --bench-dir "$BENCH"; printf '%s' "$OUT")" | jget - '"'"$before"'" in d["over_limit"]')"
  # the prune plan, then the prune (a person: --yes)
  run_json site snapshot drop acme.localhost --prune --keep 2 --dry-run --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["dry_run"] and len(d["would_drop"]) == '"$((n - 2))"' and d["freed_bytes"] > 0')"
  run_json site snapshot drop acme.localhost --prune --keep 2 --yes --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  assert_eq "$((n - 2))" "$(printf '%s' "$OUT" | jget - 'len(d["dropped"])')"
  assert_eq "$((2))" "$(snap_count)"
  assert_file "$SNAPS/$before/manifest.json" "(the undo point stays)"
  run_json site snapshot drop acme.localhost --prune --keep 2 --yes --json --bench-dir "$BENCH"
  assert_eq "0" "$(printf '%s' "$OUT" | jget - 'len(d["dropped"])')" "(a second prune changes nothing)"
  # one by name: the undo point of the last rollback is refused, unless a person says so
  run_fm site snapshot drop acme.localhost "$before" --yes --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "is the undo point of a rollback"; assert_contains "$OUT" "--force-undo-point"
  assert_file "$SNAPS/$before/manifest.json"; assert_file "$SNAPS/.last-rollback"
  run_fm --for-agent site snapshot drop acme.localhost "$before" --force-undo-point --yes --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "a person at a terminal"
  assert_file "$SNAPS/$before/manifest.json"
  run_fm site snapshot drop acme.localhost --prune --force-undo-point --yes --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "--force-undo-point goes with one named snapshot"
  # and its pointer goes with it
  run_fm site snapshot drop acme.localhost "$before" --force-undo-point --yes --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
  assert_no_file "$SNAPS/$before"
  assert_no_file "$SNAPS/.last-rollback"
  run_fm site snapshot drop acme.localhost nosuch --yes --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "no snapshot 'nosuch' of acme.localhost"
  # the bench's state key SNAPSHOT_KEEP is the default limit
  run_fm service --yes --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
  benv=""; for d in "$FL_STATE_DIR"/benches/*.env; do [[ -f "$d" ]] && { benv="$d"; break; }; done
  [[ -n "$benv" ]] || fail "the bench has a state file"
  printf 'SNAPSHOT_KEEP=1
' >>"$benv"
  run_json site snapshots acme.localhost --json --bench-dir "$BENCH"
  assert_eq "1" "$(printf '%s' "$OUT" | jget - 'd["keep"]')"
  printf 'SNAPSHOT_KEEP=bogus
' >>"$benv"
  run_json site snapshots acme.localhost --json --bench-dir "$BENCH"
  assert_eq "10" "$(printf '%s' "$OUT" | jget - 'd["keep"]')" "(a bad value falls back to 10)"
}
