#!/usr/bin/env bash
# benchbar pull: a fake production server (ssh, rsync, scp and gpg mocks
# serve a folder in $MOCK_STATE) copied into new local sites. Nothing here
# connects anywhere.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# never the real tools: a mock that is not executable would let the real ssh run
for m in ssh rsync scp gpg df; do
  [[ "$(command -v "$m")" == "$ROOT/tests/mocks/bin/$m" ]] || fail "the ${m} mock is not first on PATH (is it executable?)"
done

BENCH="$HOME/dev/pull-bench"
make_fake_bench "$BENCH" devsite
printf 'port 11000\n' >"$BENCH/config/redis_queue.conf"; printf 'port 13000\n' >"$BENCH/config/redis_cache.conf"
cp "$ROOT/tests/mocks/frappe-python" "$BENCH/env/bin/python"; chmod +x "$BENCH/env/bin/python"
mkdir -p "$BENCH/apps/erpnext/erpnext" "$BENCH/apps/frappe/.git" "$BENCH/apps/erpnext/.git"
printf '__version__ = "15.41.0"\n' >"$BENCH/apps/frappe/frappe/__init__.py"
printf '__version__ = "15.30.0"\n' >"$BENCH/apps/erpnext/erpnext/__init__.py"
printf 'ref: refs/heads/version-15\n' >"$BENCH/apps/frappe/.git/HEAD"
printf 'ref: refs/heads/develop\n' >"$BENCH/apps/erpnext/.git/HEAD"
# the MariaDB root password is in the (mocked) Keychain, so nothing passes it around
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
mkdir -p "$MOCK_STATE/keychain"; printf 'rootpw\n' >"$MOCK_STATE/keychain/benchbar-mariadb--root"
unset MARIADB_ROOT_PASSWORD ADMIN_PASSWORD

# ---- the fake production server: ~/frappe-bench with erp.example.com
RS="erp.example.com"
RB="$MOCK_STATE/remote/home/frappe-bench"
BK="$RB/sites/$RS/private/backups"
ENC_KEY="prodEncKey-Zm9vYmFyYmF6cXV4"
BACKUP_KEY="prodBackupKey-s3cr3t"
mkdir -p "$BK" "$RB/env/bin"
cp "$ROOT/tests/mocks/frappe-python" "$RB/env/bin/python"; chmod +x "$RB/env/bin/python"
for a in frappe erpnext hrms; do
  mkdir -p "$RB/apps/$a/.git"; printf 'ref: refs/heads/version-15\n' >"$RB/apps/$a/.git/HEAD"
  printf 'https://github.com/frappe/%s.git\n' "$a" >"$RB/apps/$a/.git/origin_url"
done
printf 'https://x-access-token:ghp_SECRETTOKEN@github.com/frappe/hrms.git\n' >"$RB/apps/hrms/.git/origin_url"
printf 'frappe  15.40.0 version-15\nerpnext 15.30.0 version-15\nhrms    15.20.0 version-15\n' >"$RB/sites/$RS/installed_apps"
write_remote_config() {
  python3 - "$RB/sites/$RS/site_config.json" "$@" <<'PY'
import json, sys
conf = {"db_name": "_prod", "db_password": "proddbpw"}
for kv in sys.argv[2:]:
    k, v = kv.split("=", 1)
    conf[k] = v
json.dump(conf, open(sys.argv[1], "w"), indent=1)
PY
}
write_remote_config "encryption_key=$ENC_KEY" "backup_encryption_key=$BACKUP_KEY"
printf '%s' "$ENC_KEY" >"$MOCK_STATE/site_key"
printf '%s' "$BACKUP_KEY" >"$MOCK_STATE/backup_key"
cat >"$MOCK_STATE/dump.sql" <<'SQL'
INSERT INTO `tabDefaultValue` VALUES ('a','__default','installed_apps','[\"frappe\",\"erpnext\",\"hrms\"]');
SQL
gzip -c "$MOCK_STATE/dump.sql" >"$MOCK_STATE/remote_dump.sql.gz"
make_backup_set() {
  # make_backup_set TIMESTAMP [ENC]: a complete set in the server's backup folder
  local base="$BK/$1-erp_example_com" enc="${2:+-enc}"
  cp "$MOCK_STATE/remote_dump.sql.gz" "${base}-database${enc}.sql.gz"
  printf 'public files\n' >"${base}-files${enc}.tar"
  printf 'private files\n' >"${base}-private-files${enc}.tar"
  cp "$RB/sites/$RS/site_config.json" "${base}-site_config_backup${enc}.json"
}
make_backup_set 20260924_020000
make_backup_set 20260925_020000
SRC="prod:$RS"

# every secret of the run: none may reach a command line, a mock call log,
# the output or the run log
assert_no_secrets() {
  local s
  for s in rootpw adminpw "$ENC_KEY" "$BACKUP_KEY" proddbpw ghp_SECRETTOKEN; do
    ! grep -q -F -- "$s" "$MOCK_LOG" || fail "secret ${s} in the mock call log ${1:-}"
    assert_not_contains "$OUT" "$s" "${1:-}"
    ! grep -r -q -F -- "$s" "$FL_STATE_DIR/logs" 2>/dev/null || fail "secret ${s} in the run log ${1:-}"
  done
}
# only the read only commands benchbar may run on the server (and bench backup when asked)
assert_remote_allowlist() {
  local extra="${1:-}" bad
  bad="$(grep '^ssh ' "$MOCK_LOG" | grep -v -E -e 'echo benchbar-ok$' -e 'list-apps$' -e 'rev-parse --abbrev-ref HEAD' \
    -e '&& ls -1$' -e '&& wc -c ' -e 'has encryption_key backup_encryption_key$' -e 'value (encryption_key|backup_encryption_key)$' \
    -e 'command -v rsync$' -e ' -O exit ' ${extra:+-e "$extra"} || true)"
  [[ -z "$bad" ]] || fail "remote commands outside the allowlist:"$'\n'"$bad"
}
pulled_files() { find "$BENCH/.benchbar/pulls" -type f 2>/dev/null | wc -l | tr -d ' '; }
conf_get() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$BENCH/sites/$1/site_config.json" "$2"; }

# ---- refusals before anything happens
run_fm pull --bench-dir "$BENCH"; assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "Usage: benchbar pull HOST:SITE"
run_fm pull "-oProxyCommand=x:$RS" --bench-dir "$BENCH"; assert_eq "1" "$CODE" "$OUT"
run_fm pull "$SRC" --as "Bad_Name" --bench-dir "$BENCH"; assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "Invalid site name"
run_fm pull "$SRC" --skip-app frappe --bench-dir "$BENCH"; assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "frappe cannot be skipped"
touch "$MOCK_STATE/ssh_refused"
run_fm pull "$SRC" --as copy1 --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "No SSH connection to prod"; assert_contains "$OUT" "~/.ssh/config"
rm -f "$MOCK_STATE/ssh_refused"
run_fm pull "$SRC" --remote-bench /srv/nothing --as copy1 --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "No site erp.example.com in /srv/nothing"

# ---- a missing app stops the run with the get-app command, no token shown
reset_calls
run_fm pull "$SRC" --as copy1 --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "bench get-app --branch version-15 https://github.com/frappe/hrms.git"
assert_contains "$OUT" "--skip-app APP"
assert_not_contains "$OUT" "ghp_SECRETTOKEN"
assert_no_file "$BENCH/sites/copy1"
assert_calls_not_contain '^(rsync|scp) '
assert_remote_allowlist

# ---- dry run: reads the server, changes nothing anywhere
reset_calls
snap="$(snapshot "$BENCH" "$FL_HOSTS_FILE" "$FL_STATE_DIR" "$MOCK_STATE/remote")"
run_fm pull "$SRC" --as copy1 --skip-app hrms --dry-run --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "20260925_020000"
assert_contains "$OUT" "nothing is written on prod"
assert_contains "$OUT" "Restore into copy1"
assert_contains "$OUT" "hrms"
assert_eq "$snap" "$(snapshot "$BENCH" "$FL_HOSTS_FILE" "$FL_STATE_DIR" "$MOCK_STATE/remote")" "(dry run)"
assert_calls_not_contain '^(rsync|scp|gpg|sudo) '
assert_calls_not_contain '^python benchbar-frappe'
assert_calls_not_contain '^bench '
assert_calls_not_contain ' backup( --with-files)?$'
assert_remote_allowlist

# ---- the real thing: latest existing backup, key carried, email muted
reset_calls
ADMIN_PASSWORD=adminpw run_fm pull "$SRC" --as copy1 --skip-app hrms --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^rsync -a --partial --append-verify --info=progress2 -e ssh -o BatchMode=yes -o ControlPath=[^ ]*/cm -o ControlMaster=auto -o ControlPersist=60 prod:frappe-bench/sites/erp.example.com/private/backups/20260925_020000-erp_example_com-database.sql.gz '
assert_calls_contain '^python benchbar-frappe copy1 restore --mariadb-root-password [^ ]*/.benchbar/pulls/erp.example.com-20260925_020000/20260925_020000-erp_example_com-database.sql.gz --with-public-files [^ ]*-files.tar --with-private-files [^ ]*-private-files.tar$'
assert_eq "rootpw" "$(cat "$MOCK_STATE/stdin-restore")" "(the root password reaches restore on stdin)"
assert_calls_contain '^redis-server config/redis_queue.conf --daemonize yes$' "(v16 restore needs the bench's Redis)"
assert_calls_contain '^redis-cli -p 11000 shutdown save$'
assert_eq "$ENC_KEY" "$(conf_get copy1 encryption_key)" "(the production key)"
assert_eq "localdbpw" "$(conf_get copy1 db_password)" "(nothing else from production)"
assert_eq "1" "$(conf_get copy1 mute_emails)"
assert_eq "1" "$(conf_get copy1 pause_scheduler)"
assert_eq "http://copy1:8000" "$(conf_get copy1 host_name)"
assert_calls_contain '^bench --site copy1 disable-scheduler$'
assert_calls_contain '^bench --site copy1 remove-from-installed-apps hrms$'
assert_calls_contain '^bench --site copy1 migrate$' "(local frappe is newer than the dump)"
assert_calls_contain '^bench --site copy1 clear-cache$'
assert_calls_contain '^python benchbar-frappe copy1 set-admin-password -$'
assert_eq "adminpw" "$(cat "$MOCK_STATE/stdin-set-admin-password")"
grep -q '^127.0.0.1 copy1$' "$FL_HOSTS_FILE" || fail "hosts line for the copy"
assert_contains "$OUT" "stored passwords decrypt: 5 of 5"
assert_contains "$OUT" "apps on copy1: erpnext frappe"
assert_eq "0" "$(pulled_files)" "(the download is removed afterwards)"
assert_calls_not_contain ' backup( --with-files)?$'
assert_no_file "$MOCK_STATE/remote_backup_taken"
assert_remote_allowlist
assert_no_secrets "(happy path)"
assert_eq "devsite" "$(cat "$BENCH/sites/currentsite.txt")" "(the default site stays)"
# the default: pull again from the last source
run_fm pull --as copy1 --dry-run --bench-dir "$BENCH"
assert_contains "$OUT" "source from the last pull: prod:erp.example.com"

# ---- an existing site: stop, or --replace after a local backup
reset_calls
run_fm pull "$SRC" --as copy1 --skip-app hrms --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "Site copy1 already exists"; assert_contains "$OUT" "--replace"
assert_calls_not_contain '^rsync '
reset_calls
run_fm pull "$SRC" --as copy1 --skip-app hrms --replace --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
b="$(grep -n '^bench --site copy1 backup --with-files$' "$MOCK_LOG" | head -n1 | cut -d: -f1)"
r="$(grep -n '^python benchbar-frappe copy1 restore' "$MOCK_LOG" | head -n1 | cut -d: -f1)"
[[ -n "$b" && -n "$r" && "$b" -lt "$r" ]] || fail "--replace backs the site up before the restore"
assert_no_secrets "(replace)"

# ---- no key on production: a warning, and the probe says so
write_remote_config "backup_encryption_key=$BACKUP_KEY"
run_fm pull "$SRC" --as nokey --skip-app hrms --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "[WARN] production has no encryption_key"
assert_contains "$OUT" "5 of 5 stored passwords do not decrypt"
write_remote_config "encryption_key=$ENC_KEY" "backup_encryption_key=$BACKUP_KEY"

# ---- production frappe newer than the bench: stop before anything
sed_inplace 's/^frappe  15.40.0/frappe  15.50.0/' "$RB/sites/$RS/installed_apps"
reset_calls
run_fm pull "$SRC" --as newer --skip-app hrms --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "Production runs frappe 15.50.0, this bench frappe 15.41.0"
assert_calls_not_contain '^rsync '
sed_inplace 's/^frappe  15.50.0/frappe  15.40.0/' "$RB/sites/$RS/installed_apps"

# ---- not enough disk: stop before the transfer
printf '0\n' >"$MOCK_STATE/df_avail_kb"
reset_calls
run_fm pull "$SRC" --as lowdisk --skip-app hrms --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "Not enough free disk space"
assert_calls_not_contain '^rsync '
rm -f "$MOCK_STATE/df_avail_kb"

# ---- a dropped link: the next run resumes the partial file (old rsync flags)
printf '6' >"$MOCK_STATE/rsync_fail_after"
run_fm pull "$SRC" --as resumed --skip-app hrms --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "the download of 20260925_020000-erp_example_com-database.sql.gz stopped"
assert_contains "$OUT" "the transfer resumes"
assert_file "$BENCH/.benchbar/pulls/erp.example.com-20260925_020000/20260925_020000-erp_example_com-database.sql.gz"
assert_no_file "$BENCH/sites/resumed"
printf '2.6.9' >"$MOCK_STATE/rsync_version"
reset_calls
run_fm pull "$SRC" --as resumed --skip-app hrms --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "6" "$(cat "$MOCK_STATE/rsync_resumed_from")" "(resumed from the partial file)"
assert_calls_contain '^rsync -a --partial --progress -e '
assert_calls_not_contain 'append-verify'
rm -f "$MOCK_STATE/rsync_version"

# ---- no rsync on the server: scp
touch "$MOCK_STATE/remote_no_rsync"
reset_calls
run_fm pull "$SRC" --as scpcopy --skip-app hrms --no-files --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^scp -q -o BatchMode=yes .* prod:frappe-bench/sites/erp.example.com/private/backups/20260925_020000-erp_example_com-database.sql.gz '
assert_calls_not_contain '^rsync '
assert_calls_not_contain '^scp .*files.tar'
rm -f "$MOCK_STATE/remote_no_rsync"

# ---- --new-backup: the site name must be typed, even with --yes
reset_calls
run_fm pull "$SRC" --as fresh --skip-app hrms --new-backup --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "needs the production site name typed"
assert_contains "$OUT" "deletes backup files older than keep_backups_for_hours"
run_fm pull "$SRC" --as fresh --skip-app hrms --new-backup --confirm-site erp.example.org --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "does not match"
assert_no_file "$MOCK_STATE/remote_backup_taken"
assert_calls_not_contain ' backup( --with-files)?$'
assert_no_file "$BENCH/sites/fresh"
printf '20260926_120000' >"$MOCK_STATE/new_backup_ts"
reset_calls
run_fm pull "$SRC" --as fresh --skip-app hrms --new-backup --confirm-site "$RS" --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_file "$MOCK_STATE/remote_backup_taken"
assert_calls_contain "^ssh .* frappe --site 'erp.example.com' backup --with-files$"
grep -q '20260926_120000-erp_example_com-database.sql.gz' "$MOCK_STATE/restore_args" || fail "the new backup is the one restored"
assert_remote_allowlist 'backup --with-files$'
assert_no_secrets "(new backup)"

# ---- an encrypted backup: gpg here, the passphrase on stdin
make_backup_set 20260926_130000 enc
reset_calls
run_fm pull "$SRC" --as enccopy --skip-app hrms --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-fd 0 -o [^ ]*/20260926_130000-erp_example_com-database.sql.gz -d [^ ]*/20260926_130000-erp_example_com-database-enc.sql.gz$'
assert_file "$MOCK_STATE/gpg_passphrase_ok"
grep -q -- '--mariadb-root-password [^ ]*/20260926_130000-erp_example_com-database.sql.gz ' "$MOCK_STATE/restore_args" || fail "restore uses the decrypted dump"
assert_eq "0" "$(pulled_files)" "(downloaded and decrypted files removed)"
assert_no_secrets "(encrypted)"
mkdir -p "$MOCK_STATE/aside"; mv "$BK"/20260926_1* "$MOCK_STATE/aside/"

# ---- --json: one object per line on stdout, ending in done
JOUT="$("$FM" pull "$SRC" --as jsoncopy --skip-app hrms --yes --json --bench-dir "$BENCH" 2>/dev/null)" || fail "pull --json failed"
printf '%s\n' "$JOUT" | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
assert all(e["schema_version"] == 1 for e in events), "schema_version"
kinds = [e["event"] for e in events]
assert kinds[0] == "plan" and kinds[-1] == "done", kinds
plan = events[0]
assert plan["site"] == "jsoncopy" and plan["backup"]["name"].startswith("20260925_020000"), plan
assert {a["app"]: a["status"] for a in plan["apps"]}["hrms"] == "skipped", plan["apps"]
steps = [e for e in events if e["event"] == "step"]
assert [s["n"] for s in steps] == list(range(1, len(plan["steps"]) + 1)), steps
assert all(s["status"] in ("done", "unchanged", "skipped", "failed") for s in steps), steps
assert any(e["event"] == "progress" and e["bytes"] == e["total"] for e in events), "progress"
assert any(e["event"] == "gate" and e["name"] == "apply" and e["answer"] == "yes" for e in events)
done = events[-1]
assert done["exit"] == 0 and done["site"] == "jsoncopy" and done["decrypt"] == {"ok": 5, "failed": 0}, done
' || fail "pull --json events"$'\n'"$JOUT"
set +e; JOUT="$("$FM" pull "$SRC" --as jsonfail --yes --json --bench-dir "$BENCH" 2>/dev/null)"; code=$?; set -e
assert_eq "1" "$code"
assert_eq "1" "$(printf '%s\n' "$JOUT" | tail -n1 | jget - 'd["exit"]')" "(a refusal still ends in done)"

# ---- --from-dir: a backup downloaded by hand, no SSH
DL="$TMP_DIR/download"; mkdir -p "$DL"
cp "$BK"/20260925_020000-* "$DL/"
reset_calls
run_fm pull --from-dir "$DL" --as fromdir --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "bench get-app hrms"
run_fm pull --from-dir "$DL" --as fromdir --skip-app hrms --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain '^(ssh|rsync|scp) '
assert_eq "$ENC_KEY" "$(conf_get fromdir encryption_key)"
assert_file "$DL/20260925_020000-erp_example_com-database.sql.gz" "(the folder is left as it was)"
assert_no_secrets "(from dir)"

# ---- a running bench: its scheduler is paused for the whole bench until
# the copy has its own pause_scheduler and mute_emails, then resumed
add_proc 4242 "honcho start -f Procfile.lean" "$BENCH"
reset_calls
run_fm pull --from-dir "$DL" --as livecopy --skip-app hrms --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "Pause this bench's scheduler during the restore"
q="$(grep -n 'set-config -g -p pause_scheduler 1$' "$MOCK_LOG" | head -n1 | cut -d: -f1)"
r="$(grep -n 'benchbar-frappe livecopy restore' "$MOCK_LOG" | head -n1 | cut -d: -f1)"
p="$(grep -n 'bench --site livecopy set-config -p pause_scheduler 1$' "$MOCK_LOG" | head -n1 | cut -d: -f1)"
u="$(grep -n 'config remove-common-config pause_scheduler$' "$MOCK_LOG" | head -n1 | cut -d: -f1)"
[[ -n "$q" && -n "$r" && -n "$p" && -n "$u" && "$q" -lt "$r" && "$r" -lt "$p" && "$p" -lt "$u" ]] || fail "pause the bench, restore, pause the site, resume the bench (${q} ${r} ${p} ${u})"$'\n'"$(cat "$MOCK_LOG")"
assert_eq "False" "$(python3 -c 'import json,sys; print("pause_scheduler" in json.load(open(sys.argv[1])))' "$BENCH/sites/common_site_config.json")"
assert_eq "1" "$(conf_get livecopy pause_scheduler)"
# a bench paused by hand stays paused: no step touches it
(cd "$BENCH" && bench set-config -g -p pause_scheduler 1)
reset_calls
run_fm pull --from-dir "$DL" --as livecopy2 --skip-app hrms --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain 'remove-common-config'
assert_eq "1" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pause_scheduler"])' "$BENCH/sites/common_site_config.json")"

printf 'test-pull: ok\n'
