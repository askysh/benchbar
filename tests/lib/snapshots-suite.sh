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
git_head() { git -C "$BENCH/apps/$1" rev-parse HEAD; }

suite() {
  local tag="$1" id1 id2 id3 before plan token n S SNAPS d benv r m
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
  run_fm site snapshot acme.localhost --bogus --bench-dir "$BENCH"
  assert_eq "64" "$CODE" "$OUT"; assert_contains "$OUT" "Unknown option for site snapshot: --bogus"
  run_fm site rollback acme.localhost --bench-dir "$BENCH" --dry-run
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "--to SNAPSHOT names the snapshot"
  run_fm site rollback acme.localhost --to 20200101_000000 --bench-dir "$BENCH" --dry-run
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "no snapshot '20200101_000000' of acme.localhost"
  run_fm site rollback acme.localhost --to latest --bench-dir "$BENCH" --dry-run
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "has no snapshots yet"
  assert_calls_not_contain '^(bench|python benchbar|redis-server)'

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
  assert_eq "2" "$(ls "$SNAPS" | grep -c '^2026')" "(a failed backup adds nothing)"
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
  assert_contains "$OUT" "before-upgrade"; assert_contains "$OUT" "same as the bench"
  # an app moves on after the snapshot: allowed, and said
  git_commit erpnext "a new commit"
  run_json site snapshots acme.localhost --json --bench-dir "$BENCH"
  assert_eq "False erpnext" "$(printf '%s' "$OUT" | jget - '"%s %s" % (d["snapshots"][0]["apps_match"], " ".join(d["snapshots"][0]["changed_apps"]))')"
  run_fm site snapshots acme.localhost --bench-dir "$BENCH"
  assert_contains "$OUT" "bench changed: erpnext"

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
  # a failed restore says where the snapshot of the current state is
  reset_calls
  run_json site rollback acme.localhost --to "$id1" --dry-run --json --bench-dir "$BENCH"
  token="$(printf '%s' "$OUT" | jget - 'd["token"]')"
  MOCK_FRAPPE_FAIL=restore MARIADB_ROOT_PASSWORD=rootpw run_fm site rollback acme.localhost --to "$id1" --apply "$token" --yes --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"
  assert_contains "$OUT" "acme.localhost was snapshotted first as"
  assert_contains "$OUT" "put that back with: benchbar site rollback acme.localhost --to"
  assert_eq "$(cat "$SNAPS/.last-rollback")" "$(ls "$SNAPS" | grep 'before-rollback' | sort | tail -n 1)" "(the snapshot of the failed run is the undo point)"

  # ---- the default site: an agent never rolls it back, a person can
  run_fm site snapshot macdev --label "default" --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
  id3="$(ls "$BENCH/sites/macdev/snapshots" | grep default)"
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
  # a person in a terminal plans it as any site
  run_json site rollback macdev --to "$id3" --dry-run --json --bench-dir "$BENCH"
  assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')"

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

  # ---- retention: the newest N stay, the rest are named, nothing goes on its own
  n="$(ls "$SNAPS" | grep -c '^2026')"
  run_json site snapshots acme.localhost --keep 2 --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT$ERR"
  assert_eq "2" "$(printf '%s' "$OUT" | jget - 'd["keep"]')"
  assert_eq "$((n - 2))" "$(printf '%s' "$OUT" | jget - 'len(d["over_limit"])')" "(all beyond the two newest)"
  assert_eq "$n" "$(ls "$SNAPS" | grep -c '^2026')" "(listing removes nothing)"
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
  assert_eq "$((2))" "$(ls "$SNAPS" | grep -c '^2026')"
  assert_file "$SNAPS/$before/manifest.json" "(the undo point stays)"
  run_json site snapshot drop acme.localhost --prune --keep 2 --yes --json --bench-dir "$BENCH"
  assert_eq "0" "$(printf '%s' "$OUT" | jget - 'len(d["dropped"])')" "(a second prune changes nothing)"
  # one by name, and the last rollback's pointer goes with it
  run_fm site snapshot drop acme.localhost "$before" --yes --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
  assert_no_file "$SNAPS/$before"
  assert_no_file "$SNAPS/.last-rollback"
  run_fm site snapshot drop acme.localhost nosuch --yes --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "no snapshot 'nosuch' of acme.localhost"
  # the bench's state key SNAPSHOT_KEEP is the default limit
  run_fm service --yes --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
  benv="$(ls "$FL_STATE_DIR"/benches/*.env 2>/dev/null | head -n 1 || true)"
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
