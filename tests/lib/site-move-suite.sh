#!/usr/bin/env bash
#
# site-move-suite.sh: the body of the site move tests, shared by test-site-move (macOS platform) and
# test-site-move-2 (use_linux). Defines suite TAG; sources the harness.

# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
exec </dev/null

run_json() {
  set +e
  OUT="$("$FM" "$@" 2>"$MOCK_STATE/stderr")"
  CODE="$?"
  ERR="$(cat "$MOCK_STATE/stderr")"
  set -e
}
# the dump every backup holds: a restore reads the installed apps out of it
SQL="$TMP_DIR/dump.sql"
printf '%s\n' "INSERT INTO \`tabDefaultValue\` VALUES ('a','__default','installed_apps','[\\\"frappe\\\",\\\"erpnext\\\"]');" >"$SQL"
export MOCK_BENCH_BACKUP_DB="$TMP_DIR/dump.sql.gz"
gzip -c "$SQL" >"$MOCK_BENCH_BACKUP_DB"
# the line number of the Nth mock call matching a pattern
at() { grep -n -E -- "$1" "$MOCK_LOG" | sed -n "${2:-1}p" | cut -d: -f1; }
# add_site BENCH NAME [APP...]: a site folder with its apps (what the mock's list-apps reads)
add_site() {
  local b="$1" s="$2"
  shift 2
  mkdir -p "$b/sites/$s"
  printf '{"db_name":"_%s","db_password":"dbpw"}\n' "${s//[^a-z0-9]/}" >"$b/sites/$s/site_config.json"
  : >"$b/sites/$s/installed_apps"
  while [[ "$#" -gt 0 ]]; do printf '%s 1.0.0\n' "$1" >>"$b/sites/$s/installed_apps"; shift; done
}
# plan SITE [ARGS...]: the move plan into OUT, its token into TOKEN
plan() {
  local s="$1"; shift
  run_json site move "$s" --to-bench "$TGT" --dry-run --json --bench-dir "$SRC" "$@"
  assert_eq "0" "$CODE" "$OUT$ERR"
  TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
}
apply() { local s="$1"; shift; run_json site move "$s" --to-bench "$TGT" --apply "$TOKEN" --yes --json --bench-dir "$SRC" "$@"; }

# fails_at STEP SITE VAR=VALUE: a move of a new site that fails with VAR=VALUE set for the mocks. Asserts the exit,
# the failed step, an error that is the message of what failed, and (before the drop) that the source site is as it was.
# OUT holds the result afterwards.
fails_at() {
  local step="$1" s="$2" kv="$3" before
  add_site "$SRC" "$s" frappe erpnext
  plan "$s"
  assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')" "$OUT"
  before="$(cat "$SRC/sites/$s/site_config.json" "$SRC/sites/$s/installed_apps")"
  reset_calls
  export "${kv?}"
  apply "$s"
  unset "${kv%%=*}"
  assert_eq "1" "$CODE" "$OUT$ERR"
  assert_eq "False $step" "$(printf '%s' "$OUT" | jget - '"%s %s" % (d["moved"], d["failed_step"])')" "$OUT"
  assert_not_contains "$(printf '%s' "$OUT" | jget - 'd["error"]')" "the command exited"
  assert_eq "$before" "$(cat "$SRC/sites/$s/site_config.json" "$SRC/sites/$s/installed_apps")" "(the source site is as it was)"
  if [[ "$step" != "drop" ]]; then
    assert_calls_not_contain "drop-site ${s}"
    assert_no_file "$SRC/archived/sites/$s"
    assert_contains "$(printf '%s' "$OUT" | jget - '" ".join(c["detail"] for c in d["changed"])')" "created in $TGT/sites/$s"
  fi
  rm -rf "$TGT/sites/$s"
}

suite() {
  local tag="$1" UNREG snap b b1 b2 ns rs mg la dr
  SRC="$HOME/dev/move-src-$tag"; TGT="$HOME/dev/move-tgt-$tag"; UNREG="$HOME/elsewhere/move-unreg-$tag"
  make_fake_bench "$SRC" macdev
  make_fake_bench "$TGT" tgtdev
  make_fake_bench "$UNREG" loose
  cp "$ROOT/tests/mocks/frappe-python" "$TGT/env/bin/python"; chmod +x "$TGT/env/bin/python"
  sed_inplace 's/"webserver_port": 8000/"webserver_port": 8001/; s/"socketio_port": 9000/"socketio_port": 9001/' "$TGT/sites/common_site_config.json"
  for b in "$SRC" "$TGT"; do printf 'port 11000\n' >"$b/config/redis_queue.conf"; printf 'port 13000\n' >"$b/config/redis_cache.conf"; done
  printf '3306 111 mariadbd 127.0.0.1\n' >"$MOCK_LISTEN"
  printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
  export MARIADB_ROOT_PASSWORD=rootpw
  if [[ "$FL_PLATFORM" == "linux" ]]; then
    mkdir -p "$TMP_DIR/xbin"; cp "$ROOT/tests/mocks/mariadb" "$TMP_DIR/xbin/mariadb"; chmod +x "$TMP_DIR/xbin/mariadb"
    export FL_MARIADB_BIN="$TMP_DIR/xbin/mariadb"
  fi
  add_site "$SRC" acme.localhost frappe erpnext
  printf '127.0.0.1 macdev\n\n# >>> benchbar >>>\n127.0.0.1 acme.localhost\n# <<< benchbar <<<\n' >>"$FL_HOSTS_FILE"
  run_fm register "$SRC" "$TGT"
  assert_eq "0" "$CODE" "$OUT"
  reset_calls

  # ---- plan errors: can_apply false, each says why, nothing runs
  run_json site move macdev --to-bench "$TGT" --dry-run --json --bench-dir "$SRC"
  assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')" "$OUT$ERR"
  assert_contains "$OUT" "macdev is the default site of $SRC; the default site never moves"
  run_json site move acme.localhost --to-bench "$SRC" --dry-run --json --bench-dir "$SRC"
  assert_contains "$OUT" "the target is the bench the site is in"
  run_json site move acme.localhost --to-bench "$HOME/nowhere" --dry-run --json --bench-dir "$SRC"
  assert_contains "$OUT" "is not a bench folder"
  run_json site move acme.localhost --to-bench "$UNREG" --dry-run --json --bench-dir "$SRC"
  assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')"; assert_contains "$OUT" "is not a bench benchbar knows"
  add_site "$TGT" acme.localhost frappe
  run_json site move acme.localhost --to-bench "$TGT" --dry-run --json --bench-dir "$SRC"
  assert_contains "$OUT" "a site acme.localhost already exists in $TGT; nothing is overwritten"
  rm -rf "$TGT/sites/acme.localhost"
  add_site "$SRC" tgtdev frappe
  run_json site move tgtdev --to-bench "$TGT" --dry-run --json --bench-dir "$SRC"
  assert_contains "$OUT" "tgtdev is the default site of $TGT"
  add_site "$SRC" hrm.localhost frappe erpnext hrms payments
  run_json site move hrm.localhost --to-bench "$TGT" --dry-run --json --bench-dir "$SRC"
  assert_eq "False hrms payments" "$(printf '%s' "$OUT" | jget - '"%s %s" % (d["can_apply"], " ".join(d["missing_apps"]))')"
  assert_contains "$OUT" "lacks apps hrm.localhost has installed: hrms, payments"
  run_fm site move acme.localhost --bench-dir "$SRC" --dry-run
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "Usage: benchbar site move NAME --to-bench PATH"
  run_fm site move nosuch --to-bench "$TGT" --bench-dir "$SRC" --dry-run
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "No site 'nosuch'"
  run_fm site move acme.localhost --to-bench "$TGT" --bogus --bench-dir "$SRC"
  assert_eq "64" "$CODE" "$OUT"; assert_contains "$OUT" "Unknown option for site move: --bogus"
  assert_calls_not_contain '^(bench (--site [^ ]+ (backup|migrate)|drop-site|new-site)|python benchbar)'

  # ---- the plan of a movable site: steps in order, what stays, the port, the token; a dry run changes nothing
  snap="$(snapshot "$SRC/sites" "$TGT/sites" "$FL_HOSTS_FILE")"
  plan acme.localhost
  printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["can_apply"] is True and d["errors"] == [] and d["dry_run"] is True, d
assert [s["id"] for s in d["steps"]] == ["backup", "restore", "migrate", "check", "drop"], d["steps"]
assert d["apps"] == ["frappe", "erpnext"] and d["missing_apps"] == [], d
assert d["hosts"]["port_changes"] is True and d["hosts"]["url_after"].endswith(":8001"), d["hosts"]
assert any("backups of acme.localhost" in w for w in d["stays"]), d["stays"]
' || fail "the plan"$'\n'"$OUT"
  run_json site move acme.localhost --to-bench "$TGT" --no-migrate --dry-run --json --bench-dir "$SRC"
  assert_eq "backup restore check drop" "$(printf '%s' "$OUT" | jget - '" ".join(s["id"] for s in d["steps"])')"
  run_fm site move acme.localhost --to-bench "$TGT" --dry-run --bench-dir "$SRC"
  assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "Back up acme.localhost with its files"; assert_contains "$OUT" "dry-run: nothing was backed up"
  assert_eq "$snap" "$(snapshot "$SRC/sites" "$TGT/sites" "$FL_HOSTS_FILE")" "(a dry run writes nothing)"
  assert_calls_not_contain '^(bench (--site [^ ]+ (backup|migrate)|drop-site|new-site)|python benchbar)'

  # ---- refusals of the apply: no token, a token that is no plan's, no --yes
  run_fm site move acme.localhost --to-bench "$TGT" --apply --yes --bench-dir "$SRC"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "--apply needs the token of a plan"
  run_fm site move acme.localhost --to-bench "$TGT" --apply "$TOKEN" --bench-dir "$SRC"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "pass its token with --apply TOKEN --yes"
  run_fm site move acme.localhost --to-bench "$TGT" --apply "$(printf '%064d' 0)" --yes --bench-dir "$SRC"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "plan changed since it was shown"

  # ---- a stale token: the target gained a site after the plan; nothing ran
  add_site "$TGT" late.localhost frappe
  apply acme.localhost
  assert_eq "1" "$CODE" "$OUT$ERR"; assert_contains "$ERR" "plan changed since it was shown"
  assert_calls_not_contain '^(bench (--site [^ ]+ backup|drop-site|new-site)|python benchbar)'
  rm -rf "$TGT/sites/late.localhost"

  # ---- a lease on the target bench held by another caller: the plan says so, the apply is refused
  plan acme.localhost
  set +e; OUT="$(BENCHBAR_NONINTERACTIVE=1 BENCHBAR_CALLER=agent-x "$FM" lease take --bench "$TGT" --bench-dir "$SRC" --for 10 --json 2>/dev/null)"; CODE="$?"; set -e
  assert_eq "0" "$CODE" "$OUT"
  run_json site move acme.localhost --to-bench "$TGT" --dry-run --json --bench-dir "$SRC"
  assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')"
  assert_contains "$OUT" "is leased by agent-x"
  apply acme.localhost
  assert_eq "1" "$CODE" "$OUT$ERR"; assert_contains "$ERR" "is leased by agent-x"
  assert_calls_not_contain '^(bench (--site [^ ]+ backup|drop-site|new-site)|python benchbar)'
  rm -f "$FL_STATE_DIR/leases.tsv"

  # ---- a failed check leaves the source as it was: the restored site has other apps than the one that left
  add_site "$SRC" gamma.localhost frappe erpnext hrms
  mkdir -p "$TGT/apps/hrms"
  plan gamma.localhost
  assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')" "$OUT"
  snap="$(cat "$SRC/sites/gamma.localhost/site_config.json" "$SRC/sites/gamma.localhost/installed_apps")"
  reset_calls
  apply gamma.localhost
  assert_eq "1" "$CODE" "$OUT$ERR"
  assert_eq "False check" "$(printf '%s' "$OUT" | jget - '"%s %s" % (d["moved"], d["failed_step"])')" "$OUT"
  assert_eq "done done done failed skipped" "$(printf '%s' "$OUT" | jget - '" ".join(s["status"] for s in d["steps"])')"
  assert_calls_contain '^bench --site gamma.localhost migrate$'
  assert_calls_not_contain 'drop-site gamma'
  assert_eq "$snap" "$(cat "$SRC/sites/gamma.localhost/site_config.json" "$SRC/sites/gamma.localhost/installed_apps")" "(the source site is as it was)"
  assert_no_file "$SRC/archived/sites/gamma.localhost"
  assert_file "$TGT/sites/gamma.localhost/site_config.json" "(the partial copy is named for cleanup)"
  assert_contains "$(cat "$FL_STATE_DIR"/logs/*.log)" "was not touched"
  assert_contains "$OUT" "site drop gamma.localhost --confirm-site gamma.localhost --bench-dir $TGT"
  rm -rf "$TGT/sites/gamma.localhost"

  # ---- a running source bench: its writes after the first backup would be lost, so the plan cannot be applied
  add_site "$SRC" run.localhost frappe erpnext
  add_proc 4243 "honcho start -f Procfile.lean" "$SRC"
  run_json site move run.localhost --to-bench "$TGT" --dry-run --json --bench-dir "$SRC"
  assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')" "$OUT"
  assert_eq "Stop the bench first: benchbar down --bench-dir $SRC" "$(printf '%s' "$OUT" | jget - 'd["errors"][0]')"
  assert_eq "benchbar down --bench-dir $SRC" "$(printf '%s' "$OUT" | jget - 'd["next_actions"][0]["command"]')"
  TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
  reset_calls
  apply run.localhost
  assert_eq "1" "$CODE" "$OUT$ERR"; assert_contains "$ERR$OUT" "Stop the bench first"
  assert_calls_not_contain '^(bench (--site [^ ]+ backup|drop-site|new-site)|python benchbar)'
  : >"$MOCK_PROCS"
  run_json site move run.localhost --to-bench "$TGT" --dry-run --json --bench-dir "$SRC"
  assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')" "(stopped, the plan can be applied)"

  # ---- every other failure point: restore, migrate and the second backup leave the source as it was; a failed
  # drop-site says the site is in both benches and how to finish. VAR=VALUE is what the mocks are told to do.
  fails_at restore frg.localhost MOCK_FRAPPE_FAIL=restore
  fails_at migrate fmg.localhost MOCK_BENCH_MIGRATE_EXIT=1
  fails_at drop fbk.localhost MOCK_BENCH_BACKUP_FAIL_AFTER="$(( $(cat "$MOCK_STATE/backup_n") + 1 ))"
  assert_contains "$OUT" "No usable backup of fbk.localhost"
  assert_not_contains "$(cat "$MOCK_LOG")" "drop-site fbk"
  assert_file "$SRC/sites/fbk.localhost/site_config.json"
  assert_no_file "$SRC/archived/sites/fbk.localhost"
  fails_at drop fdr.localhost MOCK_DROP_SITE_EXIT=1
  assert_calls_contain '^bench drop-site fdr.localhost '
  assert_file "$SRC/sites/fdr.localhost/site_config.json" "(drop-site failed: the site is still here)"
  assert_contains "$(cat "$FL_STATE_DIR"/logs/*.log)" "fdr.localhost is now in both benches"
  assert_contains "$(cat "$FL_STATE_DIR"/logs/*.log)" "site drop fdr.localhost --confirm-site fdr.localhost --bench-dir $SRC"
  assert_contains "$(printf '%s' "$OUT" | jget - 'd["error"]')" "bench drop-site fdr.localhost failed"

  # ---- the move: backup, restore, migrate, check, then the drop in the source
  plan acme.localhost
  reset_calls
  apply acme.localhost
  assert_eq "0" "$CODE" "$OUT$ERR"
  printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["ok"] is True and d["moved"] is True and d["site"] == "acme.localhost", d
assert d["op_id"].startswith("op-") and d["exit"] == 0, d
assert [s["status"] for s in d["steps"]] == ["done"] * 5, d["steps"]
assert d["address"].endswith(":8001") and d["verify"]["apps"] == ["erpnext", "frappe"], d
assert d["archived_path"].endswith("/archived/sites/acme.localhost") and d["backup"]["with_files"] is True, d
assert any(c["kind"] == "site" and "created in " in c["detail"] and "/sites/acme.localhost" in c["detail"] for c in d["changed"]), d["changed"]
assert any("8001" in a["why"] for a in d["next_actions"]), d["next_actions"]
' || fail "the result"$'\n'"$OUT"
  # the order: backup, new-site, restore, migrate, list-apps check, a second backup, drop-site
  b1="$(at '^bench --site acme.localhost backup --with-files$' 1)"; b2="$(at '^bench --site acme.localhost backup --with-files$' 2)"
  ns="$(at '^bench new-site acme.localhost ' 1)"; rs="$(at '^python benchbar-frappe acme.localhost restore ' 1)"
  mg="$(at '^bench --site acme.localhost migrate$' 1)"; la="$(at '^bench --site acme.localhost list-apps$' 1)"; dr="$(at '^bench drop-site acme.localhost ' 1)"
  [[ -n "$b1" && -n "$b2" && -n "$ns" && -n "$rs" && -n "$mg" && -n "$la" && -n "$dr" ]] || fail "a step is missing from the calls"$'\n'"$(cat "$MOCK_LOG")"
  [[ "$b1" -lt "$ns" && "$ns" -lt "$rs" && "$rs" -lt "$mg" && "$mg" -lt "$la" && "$la" -lt "$b2" && "$b2" -lt "$dr" ]] || fail "the order of the steps"$'\n'"$(cat "$MOCK_LOG")"
  assert_no_file "$SRC/sites/acme.localhost"
  assert_file "$SRC/archived/sites/acme.localhost/private/backups/20260929_110000-acme_localhost-database.sql.gz" "(the backups stay)"
  assert_file "$TGT/sites/acme.localhost/site_config.json"
  assert_eq "macdev" "$(tr -d '[:space:]' <"$SRC/sites/currentsite.txt")" "(the default site of the source stays)"
  assert_eq "tgtdev" "$(tr -d '[:space:]' <"$TGT/sites/currentsite.txt")" "(and the one of the target)"
  assert_not_contains "$(cat "$MOCK_LOG")" "rootpw"
  if [[ "$FL_PLATFORM" != "linux" ]]; then
    grep -q '^127.0.0.1 acme.localhost$' "$FL_HOSTS_FILE" || fail "the hosts line of the site stays: the name is the same"
  fi
  run_json site move acme.localhost --to-bench "$TGT" --dry-run --json --bench-dir "$SRC"
  assert_eq "1" "$CODE" "$ERR"; assert_contains "$ERR" "No site 'acme.localhost'"

  # ---- --no-migrate and the text run: no migrate; --yes is the person's confirmation
  add_site "$SRC" delta.localhost frappe erpnext
  reset_calls
  run_fm site move delta.localhost --to-bench "$TGT" --no-migrate --yes --bench-dir "$SRC"
  assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "delta.localhost moved to $TGT"
  assert_calls_not_contain '^bench --site delta.localhost migrate'
  assert_calls_contain '^bench drop-site delta.localhost '
  assert_file "$TGT/sites/delta.localhost/site_config.json"
}
