#!/usr/bin/env bash
# benchbar share setup and share users: the host identity, the hardened and
# demoted copy (share.localhost), the user list, the guards, and signin.py,
# the helper the gateway runs to start and end Frappe sessions in the copy.
# Real /usr/bin/openssl runs; the bench, MariaDB and Frappe are mocks.
# The feature is macOS only (pf, launchd, the Keychain, Homebrew's node), so are its tests; command -p
# reaches the system uname, never the mock. CI's Linux shards leave this test out too (SKIP_TESTS).
if [[ "$(command -p uname -s)" != Darwin ]]; then printf 'test-share: ok (SKIPPED: macOS only)\n'; exit 0; fi
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH" macdev
cp "$ROOT/tests/mocks/frappe-python" "$BENCH/env/bin/python"; chmod +x "$BENCH/env/bin/python"
export MOCK_ENV_PYTHON="$ROOT/tests/mocks/env-python"
export FL_TMUTIL="$ROOT/tests/mocks/bin/tmutil"
printf 'port 11000\n' >"$BENCH/config/redis_queue.conf"; printf 'port 13000\n' >"$BENCH/config/redis_cache.conf"
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
mkdir -p "$MOCK_STATE/keychain"; printf 'rootpw\n' >"$MOCK_STATE/keychain/benchbar-mariadb--root"
mkdir -p "$FL_STATE_DIR/secrets"; printf 'rootpw\n' >"$FL_STATE_DIR/secrets/mariadb-root"; chmod 600 "$FL_STATE_DIR/secrets/mariadb-root"
unset MARIADB_ROOT_PASSWORD ADMIN_PASSWORD
printf '127.0.0.1 macdev share.localhost\n' >>"$FL_HOSTS_FILE"
# real repositories for the apps: the copy's baseline is their HEAD
for app in frappe erpnext; do
  MOCK_GIT_REAL=1 git -C "$BENCH/apps/$app" init -q
  MOCK_GIT_REAL=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com \
    git -C "$BENCH/apps/$app" commit -q --allow-empty -m "$app"
done
# the apps are real repositories now: every git call is the real git
export MOCK_GIT_REAL=1
ERPNEXT_SHA="$(git -C "$BENCH/apps/erpnext" rev-parse HEAD)"

SQL="$TMP_DIR/dump.sql"
printf '%s\n' "INSERT INTO \`tabDefaultValue\` VALUES ('a','__default','installed_apps','[\\\"frappe\\\",\\\"erpnext\\\"]');" >"$SQL"
# make_set SITE STAMP [files|nodb]: a backup set of SITE, the way bench writes one
make_set() {
  local base="$BENCH/sites/$1/private/backups/$2-${1//./_}"
  mkdir -p "$BENCH/sites/$1/private/backups"
  if [[ "${3:-}" != nodb ]]; then gzip -c "$SQL" >"${base}-database.sql.gz"; fi
  printf '{"db_name":"_old","db_password":"olddbpw","encryption_key":"setkey-Zm9vYmFy"}\n' >"${base}-site_config_backup.json"
  if [[ "${3:-}" == files ]]; then printf 'public\n' >"${base}-files.tar"; printf 'private\n' >"${base}-private-files.tar"; fi
}
# what "bench backup" writes for the site: a dump a restore can read
gzip -c "$SQL" >"$TMP_DIR/dump.sql.gz"; export MOCK_BENCH_BACKUP_DB="$TMP_DIR/dump.sql.gz"
OLD=20260901_090000; NEWEST=20260902_090000; NO_DB=20260903_090000
make_set macdev "$OLD"; make_set macdev "$NEWEST"; make_set macdev "$NO_DB" nodb

cat >"$MOCK_STATE/users.json" <<'JSON'
[
 {"name": "Administrator", "full_name": "Administrator", "user_type": "System User", "enabled": 1, "roles": ["System Manager"]},
 {"name": "priya@example.com", "full_name": "Priya Nair", "user_type": "System User", "enabled": 1, "roles": ["NE", "Stock User"]},
 {"name": "a+b@x.com", "full_name": "O'Brien X", "user_type": "System User", "enabled": 1, "roles": ["Sales User"]},
 {"name": "mgr@example.com", "full_name": "Mgr", "user_type": "System User", "enabled": 1, "roles": ["System Manager", "Sales User"]},
 {"name": "auditor@example.com", "full_name": "Auditor", "user_type": "System User", "enabled": 1, "roles": ["Auditor"]},
 {"name": "web@example.com", "full_name": "Web Customer", "user_type": "Website User", "enabled": 1, "roles": ["Customer"]},
 {"name": "gone@example.com", "full_name": "Gone", "user_type": "System User", "enabled": 0, "roles": []}
]
JSON
# a role whose code-capable power comes from DocPerm, not from the fixed names
printf 'Auditor\n' >"$MOCK_STATE/code_roles"

SHARE_DIR="$FL_STATE_DIR/share"
USERS='priya@example.com,a+b@x.com,mgr@example.com'
perm() { if [[ "$STAT_GNU" == "1" ]]; then stat -c %a "$1"; else stat -f %Lp "$1"; fi; }
sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }
spki_of() { /usr/bin/openssl x509 -in "$1" -pubkey -noout | /usr/bin/openssl pkey -pubin -outform der | /usr/bin/shasum -a 256 | awk '{print $1}'; }
# setup ARGS...: a run the way the app makes it (no terminal, BENCHBAR_SUDO=gui after its own alert)
setup() { BENCHBAR_SUDO=gui run_fm share setup --bench-dir "$BENCH" "$@"; }
# jsetup ARGS...: the same with --json: stdout (the stream) in OUT, the text in ERR
jsetup() {
  set +e
  OUT="$(BENCHBAR_SUDO=gui "$FM" share setup --bench-dir "$BENCH" --json "$@" 2>"$MOCK_STATE/stderr")"
  CODE="$?"
  ERR="$(cat "$MOCK_STATE/stderr")"
  set -e
}
# snap_all: the bench, the hosts file and the share folder (when there is one), for "nothing changed"
snap_all() { if [[ -d "$SHARE_DIR" ]]; then snapshot "$BENCH" "$FL_HOSTS_FILE" "$SHARE_DIR"; else snapshot "$BENCH" "$FL_HOSTS_FILE"; fi; }
last_line() { printf '%s\n' "$OUT" | tail -n1; }
default_site() { tr -d '[:space:]' <"$BENCH/sites/currentsite.txt"; }
cfg() { jget "$SHARE_DIR/share.json" "$1"; }
site_conf() { jget "$BENCH/sites/share.localhost/site_config.json" "d.get('$1')"; }

# ---------------------------------------------------------------- the guards: nothing changes
snap="$(snap_all)"
reset_calls
BENCHBAR_NONINTERACTIVE=1 BENCHBAR_SUDO=gui run_fm share setup --users "$USERS" --acknowledge-data --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "a person's decision"
BENCHBAR_SUDO=gui run_fm share setup --users "$USERS" --acknowledge-data --yes --for-agent --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
BENCHBAR_SUDO=gui run_fm share setup --users "$USERS" --acknowledge-data --yes --dry-run --for-agent --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT" "(a dry run is refused too: it lists the data)"
run_fm share setup --users "$USERS" --acknowledge-data --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "needs a person at a terminal"
assert_eq "$snap" "$(snap_all)" "(a refusal changes nothing)"
assert_calls_not_contain '^(bench|python|tmutil|redis-server)'

# ---------------------------------------------------------------- refusals before any change
setup --users "$USERS" --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "real data from macdev"; assert_contains "$OUT" "Customer 3"; assert_contains "$OUT" "Employee 1"; assert_contains "$OUT" "--acknowledge-data"
assert_no_file "$SHARE_DIR" "(no acknowledgement, no identity)"
assert_calls_not_contain 'new-site'
setup --users "$USERS" --acknowledge-data --bench-dir "$BENCH" --from 20260101_000000
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "no complete database backup with the stamp 20260101_000000"
setup --bench-dir "$BENCH" --acknowledge-data
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "--users A,B"
setup --users "web@example.com" --acknowledge-data --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "web@example.com cannot take a seat"
setup --users "Administrator" --acknowledge-data --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "Administrator cannot take a seat"
setup --users "gone@example.com" --acknowledge-data --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "gone@example.com cannot take a seat"
setup --users "nobody@example.com" --acknowledge-data --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "No user 'nobody@example.com' on macdev"
setup --users "$USERS" --acknowledge-data --backup-now --from "$OLD" --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "--backup-now and --from"
setup --users "$USERS" --acknowledge-data --name "x" --bogus --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "Unknown argument for share setup: --bogus"
# not enough disk: the plan's size_gb, twice the set
printf '0' >"$MOCK_STATE/df_avail_kb"
setup --users "$USERS" --acknowledge-data --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "needs about"; assert_contains "$OUT" "GB free"
assert_no_file "$SHARE_DIR"
printf '52428800' >"$MOCK_STATE/df_avail_kb"
# no backup at all, and no --backup-now
mkdir -p "$BENCH/sites/empty.localhost"; printf '{"db_name":"_e"}\n' >"$BENCH/sites/empty.localhost/site_config.json"
setup --site empty.localhost --users "$USERS" --acknowledge-data --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "no backup of empty.localhost: run benchbar site backup empty.localhost or pass --backup-now"
assert_no_file "$SHARE_DIR"
assert_calls_not_contain 'new-site'

# ---------------------------------------------------------------- share users
run_json_users() { set +e; OUT="$("$FM" share users --json --bench-dir "$BENCH" "$@" 2>"$MOCK_STATE/stderr")"; CODE="$?"; ERR="$(cat "$MOCK_STATE/stderr")"; set -e; }
run_json_users
assert_eq "0" "$CODE" "$OUT$ERR"
printf '%s' "$OUT" >"$TMP_DIR/users.out"
assert_eq "True" "$(jget "$TMP_DIR/users.out" '"users" in d and d["schema_version"] == 1')"
assert_eq "True True" "$(jget "$TMP_DIR/users.out" 'next((u["will_demote"], u["selectable"]) for u in d["users"] if u["name"] == "mgr@example.com")' | tr -d "(),'")" "(System Manager is demoted, so the seat is allowed)"
assert_eq "True" "$(jget "$TMP_DIR/users.out" 'next(u["will_demote"] and u["code_capable_roles"] == ["Auditor"] and u["selectable"] for u in d["users"] if u["name"] == "auditor@example.com")')" "(a DocPerm-derived role is code-capable)"
assert_eq "False True" "$(jget "$TMP_DIR/users.out" 'next((u["will_demote"], u["selectable"]) for u in d["users"] if u["name"] == "priya@example.com")' | tr -d "(),'")"
assert_eq "False" "$(jget "$TMP_DIR/users.out" 'next(u["selectable"] for u in d["users"] if u["name"] == "web@example.com")')" "(a Website User takes no seat)"
assert_eq "False" "$(jget "$TMP_DIR/users.out" 'next(u["selectable"] for u in d["users"] if u["name"] == "Administrator")')"
assert_eq "True" "$(jget "$TMP_DIR/users.out" 'all(set(("name", "full_name", "enabled", "user_type", "roles", "code_capable_roles", "will_demote", "selectable")) <= set(u) for u in d["users"])')"
assert_eq "Website User" "$(jget "$TMP_DIR/users.out" 'next(u["user_type"] for u in d["users"] if u["name"] == "web@example.com")')"
run_fm share users --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "priya@example.com"; assert_contains "$OUT" "Will lose"
assert_calls_not_contain '^bench --site .* (set-config|migrate)'

# ---------------------------------------------------------------- the dry run: a plan, no change
snap="$(snap_all)"
reset_calls
jsetup --users "$USERS" --dry-run
assert_eq "0" "$CODE" "$OUT$ERR"
printf '%s\n' "$OUT" | head -n1 >"$TMP_DIR/plan.json"
assert_eq "plan" "$(jget "$TMP_DIR/plan.json" 'd["event"]')"
assert_eq "True" "$(jget "$TMP_DIR/plan.json" 'isinstance(d["size_gb"], (int, float)) and isinstance(d["est_minutes"], int) and isinstance(d["source_age_s"], int) and d["data_classes"]["Customer"] == 3 and d["share_site"] == "share.localhost"')"
assert_eq "$snap" "$(snap_all)" "(a dry run writes nothing)"
assert_calls_not_contain 'new-site|backup|openssl|set-config'
assert_no_file "$SHARE_DIR"

# ---------------------------------------------------------------- the first run
reset_calls
jsetup --users "$USERS" --from latest --name "Lab ${NEWEST:0:4}" --acknowledge-data
assert_eq "0" "$CODE" "$OUT$ERR"
last_line >"$TMP_DIR/done.json"
assert_eq "done" "$(jget "$TMP_DIR/done.json" 'd["event"]')"; assert_eq "0" "$(jget "$TMP_DIR/done.json" 'd["exit"]')"
assert_eq "identity share_site harden baseline config exclude" "$(printf '%s\n' "$OUT" | python3 -c '
import json, sys
seen = []
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "step" and e["status"] == "done" and e.get("parent") in (None, "") and e["id"] in ("identity", "share_site", "harden", "baseline", "config", "exclude"):
        seen.append(e["id"])
print(" ".join(seen))')" "(the steps, in order; the backup step is skipped without --backup-now)"
assert_eq "True" "$(jget "$TMP_DIR/done.json" '{c["kind"] for c in d["changed"]} >= {"identity", "site", "config"}')"
assert_eq "macdev" "$(jget "$TMP_DIR/done.json" 'd["default_site"]')"
assert_eq "benchbar share start" "$(jget "$TMP_DIR/done.json" 'd["next_actions"][0]["command"]')"
assert_eq "True" "$(jget "$TMP_DIR/done.json" 'len(d["restore_token"]) == 64')" "(the restore's plan token)"
# the identity
assert_file "$SHARE_DIR/host.key"; assert_file "$SHARE_DIR/host.crt"; assert_file "$SHARE_DIR/share.json"
assert_eq "700" "$(perm "$SHARE_DIR")"; assert_eq "600" "$(perm "$SHARE_DIR/host.key")"; assert_eq "644" "$(perm "$SHARE_DIR/host.crt")"; assert_eq "600" "$(perm "$SHARE_DIR/share.json")"
assert_eq "sha256:$(spki_of "$SHARE_DIR/host.crt")" "$(cfg 'd["fingerprint"]')" "(the SPKI hash, not the certificate's)"
assert_contains "$(/usr/bin/openssl x509 -in "$SHARE_DIR/host.crt" -noout -subject 2>&1)" "benchbar-share"
assert_contains "$(/usr/bin/openssl ec -in "$SHARE_DIR/host.key" -noout -text 2>&1)" "prime256v1"
# the copy: made beside the site, from the newest complete set, the default site untouched
assert_calls_contain "^bench new-site share.localhost"
assert_contains "$(cat "$MOCK_STATE/restore_args")" "$NEWEST-macdev-database.sql.gz"
assert_calls_contain "benchbar-frappe share.localhost restore"
assert_eq "macdev" "$(default_site)"
assert_eq "macdev" "$(jget "$BENCH/sites/common_site_config.json" 'd["default_site"]')"
assert_calls_not_contain '^bench use'
# the hardening reached the copy
for kv in "developer_mode 0" "server_script_enabled 0" "pause_scheduler 1" "mute_emails 1" "allow_tests 0"; do
  assert_calls_contain "^bench --site share.localhost set-config -p ${kv}\$" "($kv)"
done
assert_calls_not_contain 'allow_error_traceback' "(a System Settings field, set by the helper)"
assert_eq "0 0 1 1 0" "$(site_conf developer_mode) $(site_conf server_script_enabled) $(site_conf pause_scheduler) $(site_conf mute_emails) $(site_conf allow_tests)"
assert_eq "bench-python benchbar-share-harden [share.localhost]" "$(grep '^bench-python benchbar-share-harden' "$MOCK_LOG")" "(the site is the only argument)"
assert_eq "$(printf 'priya@example.com\na+b@x.com\nmgr@example.com')" "$(cat "$MOCK_STATE/stdin-share-harden")" "(the users on stdin, a+b intact)"
assert_calls_not_contain 'bench-python benchbar-share-harden.*(priya|a\+b|mgr)'
assert_eq "3 1 1 2 4" "$(jget "$TMP_DIR/done.json" '" ".join(str(d["hardening"][k]) for k in ("passwords_rotated", "users_demoted", "roles_removed", "users_disabled", "sessions_deleted"))')" "(counts only: mgr@example.com loses System Manager)"
# the config
assert_eq "3" "$(cfg 'd["v"]')"; assert_eq "macdev" "$(cfg 'd["site"]')"; assert_eq "share.localhost" "$(cfg 'd["share_site"]')"
assert_eq "$USERS" "$(cfg '",".join(d["allowed_users"])')"
assert_eq "8001" "$(cfg 'd["web_port"]')"
assert_eq "$NEWEST" "$(cfg 'd["copy_source_stamp"]')"
assert_eq "$ERPNEXT_SHA" "$(cfg 'd["apps_at_copy"]["erpnext"]')"
assert_eq "True" "$(cfg 'bool(d["copy_made"]) and bool(d["created"]) and d["pii_acknowledged_at"].endswith("Z")')"
assert_eq "Lab 2026" "$(cfg 'd["room_label"]')"
assert_eq "True" "$(python3 -c '
import json, re, sys
d = json.load(open(sys.argv[1]))
ok = all(re.fullmatch(r"s_[0-9a-f]{8}", s["seat_id"]) for s in d["seats"]) and [s["user"] for s in d["seats"]] == d["allowed_users"]
ok = ok and d["seats"][0]["full_name"] == "Priya Nair" and d["seats"][0]["roles"] == ["NE", "Stock User"] and d["seats"][1]["full_name"] == "O'"'"'Brien X"
ok = ok and d["seats"][2]["roles"] == ["Sales User"]
print(ok)' "$SHARE_DIR/share.json")" "(seats: opaque id, user, full name, the roles the copy keeps)"
assert_not_contains "$(cat "$SHARE_DIR/share.json")" "pairing_code"
assert_not_contains "$(cat "$SHARE_DIR/share.json")" "room_code"
# excluded from Time Machine, and the copy's folder with it
assert_calls_contain "^tmutil addexclusion ${SHARE_DIR}\$"
assert_calls_contain "^tmutil addexclusion ${BENCH}/sites/share.localhost\$"
# setup does not turn Open as on for the copy
OUT="$("$FM" site open-as status share.localhost --json --bench-dir "$BENCH" 2>/dev/null)"
assert_eq "False False False" "$(printf '%s' "$OUT" | jget - 'd["open_as_enabled"], d["developer_mode"], d["open_as"]' | tr -d "(),'")"
assert_eq "" "$(grep -rl OPEN_AS_SITES "$FL_STATE_DIR" 2>/dev/null || true)" "(no Open as record)"

# ---------------------------------------------------------------- the second run changes nothing
key_sha="$(sha_of "$SHARE_DIR/host.key")"; cfg_sha="$(sha_of "$SHARE_DIR/share.json")"; seats_before="$(cfg 'json.dumps(d["seats"])')"
reset_calls
jsetup --acknowledge-data
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "$key_sha" "$(sha_of "$SHARE_DIR/host.key")" "(the key is byte-identical)"
assert_eq "$cfg_sha" "$(sha_of "$SHARE_DIR/share.json")" "(the config is byte-identical)"
assert_eq "unchanged" "$(printf '%s\n' "$OUT" | python3 -c '
import json, sys
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "step" and e["id"] == "identity" and e["status"] != "running": print(e["status"])')"
assert_eq "unchanged" "$(printf '%s\n' "$OUT" | python3 -c '
import json, sys
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "step" and e["id"] == "config" and e["status"] != "running": print(e["status"])')"
assert_eq "unchanged" "$(printf '%s\n' "$OUT" | python3 -c '
import json, sys
for l in sys.stdin:
    e = json.loads(l)
    if e["event"] == "step" and e["id"] == "share_site" and e["status"] != "running": print(e["status"])')" "(an existing copy is kept without --refresh)"
assert_calls_not_contain 'new-site'
assert_eq "macdev" "$(default_site)"
# another user list needs --refresh: the copy would keep the old people disabled
setup --users "priya@example.com" --acknowledge-data --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "--refresh"
assert_eq "$cfg_sha" "$(sha_of "$SHARE_DIR/share.json")"
# --refresh asks before it replaces the copy; with --yes it restores into share.localhost (backed up first) and keeps the seat ids
setup --users "priya@example.com" --acknowledge-data --refresh --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "Replaces the copy"
reset_calls
jsetup --users "priya@example.com,auditor@example.com" --acknowledge-data --refresh --yes
assert_eq "0" "$CODE" "$OUT$ERR"
assert_calls_not_contain '^bench new-site'
assert_calls_contain "benchbar-frappe share.localhost restore"
assert_eq "priya@example.com,auditor@example.com" "$(cfg '",".join(d["allowed_users"])')"
assert_eq "True" "$(python3 -c '
import json, sys
before = {s["user"]: s["seat_id"] for s in json.loads(sys.argv[2])}
d = json.load(open(sys.argv[1]))
now = {s["user"]: s["seat_id"] for s in d["seats"]}
print(now["priya@example.com"] == before["priya@example.com"] and now["auditor@example.com"] not in before.values())' "$SHARE_DIR/share.json" "$seats_before")" "(a seat keeps its id while its user stays)"
assert_eq "NE|Stock User" "$(cfg '"|".join(d["seats"][0]["roles"])')"
assert_eq "" "$(cfg '"|".join(d["seats"][1]["roles"])')" "(the seat shows the roles the copy keeps: Auditor is removed)"
assert_eq "priya@example.com
auditor@example.com" "$(cat "$MOCK_STATE/stdin-share-harden")"
assert_eq "macdev" "$(default_site)"

# ---------------------------------------------------------------- the pick of the set, and --backup-now
reset_calls
jsetup --users "priya@example.com" --acknowledge-data --refresh --yes --from "$OLD"
assert_eq "0" "$CODE" "$OUT$ERR"
assert_contains "$(cat "$MOCK_STATE/restore_args")" "$OLD-macdev-database.sql.gz"
assert_eq "$OLD" "$(cfg 'd["copy_source_stamp"]')"
reset_calls
jsetup --users "priya@example.com" --acknowledge-data --refresh --yes --backup-now
assert_eq "0" "$CODE" "$OUT$ERR"
assert_calls_contain '^bench --site macdev backup$'
b="$(grep -n -E '^bench --site macdev backup$' "$MOCK_LOG" | head -n1 | cut -d: -f1)"
n="$(grep -n -E 'benchbar-secrets|restore' "$MOCK_LOG" | head -n1 | cut -d: -f1)"
[[ -n "$b" && -n "$n" && "$b" -lt "$n" ]] || fail "the backup comes before the restore ($b, $n)"
assert_contains "$(cfg 'd["copy_source_stamp"]')" "2026"

# ---------------------------------------------------------------- --regenerate-identity
printf '{"v":3,"devices":[{"id":"d_x"}],"blocked":[]}\n' >"$SHARE_DIR/devices.json"; chmod 600 "$SHARE_DIR/devices.json"
key_sha="$(sha_of "$SHARE_DIR/host.key")"; fp_before="$(cfg 'd["fingerprint"]')"; dev_sha="$(sha_of "$SHARE_DIR/devices.json")"
setup --acknowledge-data --regenerate-identity --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "every Mac that joined"
assert_eq "$key_sha" "$(sha_of "$SHARE_DIR/host.key")" "(stopped before changing anything)"
assert_eq "$dev_sha" "$(sha_of "$SHARE_DIR/devices.json")"
setup --acknowledge-data --regenerate-identity --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "every pairing becomes invalid"
assert_eq "False" "$([[ "$(sha_of "$SHARE_DIR/host.key")" == "$key_sha" ]] && echo True || echo False)" "(a new key)"
assert_eq "True" "$(jget "$SHARE_DIR/devices.json" 'd["devices"] == [] and d["blocked"] == []')"
assert_eq "600" "$(perm "$SHARE_DIR/devices.json")"; assert_eq "600" "$(perm "$SHARE_DIR/host.key")"
assert_eq "sha256:$(spki_of "$SHARE_DIR/host.crt")" "$(cfg 'd["fingerprint"]')"
assert_eq "False" "$([[ "$(cfg 'd["fingerprint"]')" == "$fp_before" ]] && echo True || echo False)"

# ---------------------------------------------------------------- the web port, the room label
add_listener 8001 4301 python
BENCHBAR_SUDO=gui run_fm share setup --users "priya@example.com" --acknowledge-data --refresh --yes --bench-dir "$BENCH" --name $'  Lab\xe2\x80\xaeX \xe2\x80\x8b\x07tail  '
assert_eq "0" "$CODE" "$OUT"
assert_eq "8002" "$(cfg 'd["web_port"]')" "(8001 has a listener)"
assert_eq "LabX tail" "$(cfg 'd["room_label"]')" "(control, bidi and zero width characters stripped)"
BENCHBAR_SUDO=gui run_fm share setup --users "priya@example.com" --acknowledge-data --refresh --yes --bench-dir "$BENCH" --name "$(printf 'n%.0s' $(seq 1 60))"
assert_eq "40" "$(cfg 'len(d["room_label"])')"
BENCHBAR_SUDO=gui run_fm share setup --users "priya@example.com" --acknowledge-data --refresh --yes --bench-dir "$BENCH" --name ""
assert_eq "0" "$CODE" "$OUT"
assert_contains "$(cfg 'd["room_label"]')" "'s room"

# ---------------------------------------------------------------- a failed refresh leaves nothing usable
seat_before="$(cfg 'd["seats"][0]["seat_id"]')"
reset_calls
MOCK_SHARE_HARDEN_REFUSE="refused for the test" jsetup --users "priya@example.com" --acknowledge-data --refresh --yes
assert_eq "1" "$CODE" "$OUT$ERR"
assert_no_file "$SHARE_DIR/share.json" "(the old config does not point at the raw copy)"
assert_file "$SHARE_DIR/share.json.prev"
assert_eq "$(grep -c '^redis-server' "$MOCK_LOG")" "$(grep -c '^redis-cli .*shutdown' "$MOCK_LOG")" "(the setup Redis is stopped after a dying helper)"
assert_calls_contain '^redis-cli .*shutdown'
setup --users "priya@example.com" --acknowledge-data --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "nobody knows how it was hardened"
jsetup --users "priya@example.com" --acknowledge-data --refresh --yes
assert_eq "0" "$CODE" "$OUT$ERR"
assert_file "$SHARE_DIR/share.json"; assert_no_file "$SHARE_DIR/share.json.prev"
assert_eq "$seat_before" "$(cfg 'd["seats"][0]["seat_id"]')" "(the seat id survives a failed refresh)"
# the users helper dying stops Redis too
reset_calls
MOCK_SHARE_USERS_FAIL="the users helper broke" setup --users "priya@example.com" --acknowledge-data --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "the users helper broke"
assert_eq "$(grep -c '^redis-server' "$MOCK_LOG")" "$(grep -c '^redis-cli .*shutdown' "$MOCK_LOG")"
# a list cut at the cap is said, not silent
MOCK_SHARE_USERS_TRUNCATED=1 run_fm share users --bench-dir "$BENCH"
assert_contains "$OUT" "more than 5000 users"
MOCK_SHARE_USERS_TRUNCATED=1 setup --users "nobody@example.com" --acknowledge-data --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "stops at 5000"

# ---------------------------------------------------------------- the control socket: stale is removed, live refuses
SOCK="$TMP_DIR/ctl.sock"; export FL_SHARE_CONTROL_SOCK="$SOCK"
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$SOCK"
assert_eq "yes" "$([[ -S "$SOCK" ]] && echo yes)"
setup --users "priya@example.com" --acknowledge-data --bench-dir "$BENCH" --dry-run
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "no longer running"; assert_no_file "$SOCK"
python3 -c '
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(5)
time.sleep(20)' "$SOCK" &
LIVE_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -S "$SOCK" ]] && break; sleep 0.2; done
setup --users "priya@example.com" --acknowledge-data --bench-dir "$BENCH" --dry-run
kill "$LIVE_PID" 2>/dev/null || true; wait "$LIVE_PID" 2>/dev/null || true
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "benchbar share stop"
rm -f "$SOCK"; unset FL_SHARE_CONTROL_SOCK

# ---------------------------------------------------------------- the helper's own refusal leaves no share.json
rm -rf "$SHARE_DIR"; rm -rf "$BENCH/sites/share.localhost"
reset_calls
MOCK_SHARE_HARDEN_REFUSE="a seat still holds a code-capable role" jsetup --users "priya@example.com" --acknowledge-data
assert_eq "1" "$CODE" "$OUT$ERR"
assert_contains "$ERR" "a seat still holds a code-capable role"
assert_contains "$ERR" "not hardened"
assert_no_file "$SHARE_DIR/share.json" "(no config for a copy that is not hardened)"
assert_eq "1" "$(last_line | jget - 'd["exit"]')"
# the copy that is left is not trusted without its share.json: setup asks for --refresh
jsetup --users "priya@example.com" --acknowledge-data
assert_eq "1" "$CODE" "$OUT$ERR"; assert_contains "$ERR" "nobody knows how it was hardened"
rm -rf "$SHARE_DIR" "$BENCH/sites/share.localhost"

# ---------------------------------------------------------------- secrets stay out of the state folder and the log
jsetup --users "$USERS" --acknowledge-data --from latest
assert_eq "0" "$CODE" "$OUT$ERR"
while IFS= read -r secret; do
  [[ -n "$secret" ]] || continue
  if grep -rqF -- "$secret" "$FL_STATE_DIR" 2>/dev/null; then fail "a secret of the helper reached $FL_STATE_DIR"; fi
  case "$OUT$ERR" in *"$secret"*) fail "a secret of the helper reached the output" ;; esac
done <"$MOCK_STATE/harden-secrets"
assert_eq "$SHARE_DIR/host.key" "$(grep -rl 'PRIVATE KEY' "$FL_STATE_DIR" 2>/dev/null | grep -v '/secrets/' || true)" "(the host key is the only key material)"

# ---------------------------------------------------------------- one session body, in signin.py and open --as
assert_eq "1" "$(grep -rn 'login.make_session()' "$ROOT/lib/frappe-local" --include=*.py --include=*.sh | wc -l | tr -d ' ')" "(the minting body exists once)"
assert_eq "1" "$(grep -c 'mint_session(frappe, row)' "$ROOT/lib/frappe-local/open-as.sh")"
assert_eq "1" "$(grep -c 'mint_session(frappe, row)' "$ROOT/lib/frappe-local/share/signin.py")"
assert_eq "1" "$(grep -c 'from session_mint import mint_session' "$ROOT/lib/frappe-local/share/signin.py")"

# signin.py against a stand-in for frappe
FAKE="$TMP_DIR/fakefrappe"
mkdir -p "$FAKE/frappe"
cat >"$FAKE/frappe/__init__.py" <<'PY'
import os, types
from . import utils
class AuthenticationError(Exception):
    pass
ROWS = {
    "priya@example.com": {"name": "priya@example.com", "enabled": 1, "first_name": "Priya", "last_name": "Nair", "user_type": "System User"},
    "Administrator": {"name": "Administrator", "enabled": 1, "first_name": "Admin", "last_name": "", "user_type": "System User"},
    "web@example.com": {"name": "web@example.com", "enabled": 1, "first_name": "Web", "last_name": "", "user_type": "Website User"},
    "gone@example.com": {"name": "gone@example.com", "enabled": 0, "first_name": "Gone", "last_name": "", "user_type": "System User"},
    "refused@example.com": {"name": "refused@example.com", "enabled": 1, "first_name": "R", "last_name": "", "user_type": "System User"},
}
class _Row(dict):
    __getattr__ = dict.get
def note(*parts):
    with open(os.environ["FAKE_LOG"], "a") as f:
        f.write(" ".join(str(p) for p in parts) + "\n")
class _DB:
    def get_value(self, doctype, name, fields, as_dict=False):
        return _Row(ROWS[name]) if name in ROWS else None
    def sql_list(self, query, values=()):
        query % tuple("'%s'" % v for v in values)
        return ["sid-one", "sid-two"] if values == ("priya@example.com",) else []
    def commit(self):
        note("commit")
db = _DB()
session = types.SimpleNamespace(sid="0123456789abcdef0123456789abcdef01234567")
local = types.SimpleNamespace()
def init(site=None):
    note("init", site, os.getcwd())
def connect():
    pass
def destroy():
    note("destroy")
PY
cat >"$FAKE/frappe/utils.py" <<'PY'
def set_request(path="/"):
    pass
PY
cat >"$FAKE/frappe/auth.py" <<'PY'
import frappe
class CookieManager:
    pass
def validate_ip_address(user):
    pass
class LoginManager:
    def run_trigger(self, event):
        frappe.note("trigger", event, self.user)
    def validate_hour(self):
        pass
    def get_user_info(self):
        pass
    def make_session(self):
        if self.user == "refused@example.com":
            raise frappe.AuthenticationError("blocked")
        frappe.note("make_session", self.user, self.full_name)
    def setup_boot_cache(self):
        pass
PY
cat >"$FAKE/frappe/sessions.py" <<'PY'
import frappe
def delete_session(sid=None, user=None, reason="Session Expired"):
    frappe.note("delete_session", sid, user)
PY
signin() { FAKE_LOG="$TMP_DIR/fake.log" PYTHONPATH="$FAKE" BENCHBAR_SITES_DIR="$BENCH/sites" python3 "$ROOT/lib/frappe-local/share/signin.py" "$@"; }
: >"$TMP_DIR/fake.log"
set +e
sid="$(signin share.localhost priya@example.com 2>"$TMP_DIR/signin.err")"; code=$?
set -e
assert_eq "0" "$code"; assert_eq "0123456789abcdef0123456789abcdef01234567" "$sid" "(the sid, and only the sid, on stdout)"
assert_eq "" "$(cat "$TMP_DIR/signin.err")"
assert_contains "$(cat "$TMP_DIR/fake.log")" "init share.localhost $BENCH/sites"
assert_contains "$(cat "$TMP_DIR/fake.log")" "make_session priya@example.com Priya Nair"
assert_contains "$(cat "$TMP_DIR/fake.log")" "destroy"
for refused in Administrator web@example.com gone@example.com nobody@example.com refused@example.com; do
  set +e; out="$(signin share.localhost "$refused" 2>/dev/null)"; code=$?; set -e
  assert_eq "1" "$code" "($refused)"; assert_eq "" "$out" "($refused prints nothing)"
done
set +e; out="$(signin share.localhost 2>/dev/null)"; code=$?; set -e
assert_eq "2" "$code"; assert_eq "" "$out"
: >"$TMP_DIR/fake.log"
set +e; count="$(signin wipe share.localhost priya@example.com 2>/dev/null)"; code=$?; set -e
assert_eq "0" "$code"; assert_eq "2" "$count" "(only a count)"
assert_contains "$(cat "$TMP_DIR/fake.log")" "delete_session sid-one priya@example.com"
assert_contains "$(cat "$TMP_DIR/fake.log")" "delete_session sid-two priya@example.com"
set +e; count="$(signin wipe share.localhost nobody@example.com 2>/dev/null)"; code=$?; set -e
assert_eq "0" "$code"; assert_eq "0" "$count"
set +e; signin wipe share.localhost >/dev/null 2>&1; code=$?; set -e
assert_eq "2" "$code"
# the gateway's argv: python HELPER SITE USER and python HELPER wipe SITE USER, no cwd of its own
(cd / && FAKE_LOG="$TMP_DIR/fake.log" PYTHONPATH="$FAKE" BENCHBAR_SITES_DIR="$BENCH/sites" python3 "$ROOT/lib/frappe-local/share/signin.py" share.localhost priya@example.com >/dev/null)
assert_contains "$(cat "$TMP_DIR/fake.log")" "init share.localhost $BENCH/sites"

# ---------------------------------------------------------------- code-capable roles: DocPerm and Custom DocPerm
roles_snippet="$(bash -c '. "$1/lib/frappe-local/share-site.sh"; printf "%s" "$FL_PY_SHARE_ROLES"' _ "$ROOT")"
assert_contains "$roles_snippet" "def code_capable_roles"
python3 - "$roles_snippet" <<'PY' || fail "code_capable_roles"
import sys
exec(sys.argv[1])
class DB:
    def sql(self, query, values=None, as_dict=False):
        if "tabCustom DocPerm" in query:
            return [{"parent": "DocType", "role": "Only Custom", "write": 1, "create": 0, "submit": 0}]
        return [
            {"parent": "Server Script", "role": "Script Dev", "write": 1, "create": 0, "submit": 0},
            {"parent": "Report", "role": "Viewer", "write": 0, "create": 0, "submit": 0},
            {"parent": "Report", "role": "Report Writer", "write": 0, "create": 1, "submit": 0},
            {"parent": "Workflow", "role": "Submitter", "write": 0, "create": 0, "submit": 1},
            {"parent": "DocType", "role": "Builder", "write": 1, "create": 1, "submit": 0},
            {"parent": "Notification", "role": "All", "write": 1, "create": 0, "submit": 0},
        ]
class F:
    db = DB()
got = set(code_capable_roles(F()))
want = set(FLOOR_ROLES) | {"Script Dev", "Report Writer", "Submitter", "Only Custom"}
assert got == want, (sorted(got ^ want))
assert "Builder" not in got and "Viewer" not in got and "All" not in got
PY


# the real Python of the users, harden and check helpers, under a stand-in frappe whose database applies
# %-parameters the way pymysql does (a format mistake in a query raises)
printf '%s' "$(bash -c '. "$1/lib/frappe-local/share-site.sh"; printf "%s" "$FL_PY_SHARE_USERS"' _ "$ROOT")" >"$TMP_DIR/users_snippet.py"
printf '%s' "$(bash -c '. "$1/lib/frappe-local/share-site.sh"; printf "%s" "$FL_PY_SHARE_HARDEN"' _ "$ROOT")" >"$TMP_DIR/harden_snippet.py"
printf '%s' "$(bash -c '. "$1/lib/frappe-local/share-site.sh"; printf "%s" "$FL_PY_SHARE_CHECK"' _ "$ROOT")" >"$TMP_DIR/check_snippet.py"
printf '%s' "$(bash -c '. "$1/lib/frappe-local/share-site.sh"; printf "%s" "$FL_PY_SHARE_SESSIONS"' _ "$ROOT")" >"$TMP_DIR/sessions_snippet.py"
assert_eq "helpers_stub: ok" "$(python3 "$ROOT/tests/share/helpers_stub.py" "$TMP_DIR/users_snippet.py" "$TMP_DIR/harden_snippet.py" "$TMP_DIR/check_snippet.py" "$TMP_DIR/sessions_snippet.py" 2>&1)"
assert_eq "1" "$(grep -c 'FL_SHARE_USER_CAP=' "$ROOT"/lib/frappe-local/share*.sh | awk -F: '{s += $2} END {print s}')" "(the users cap is defined once)"

# ---------------------------------------------------------------- I2: the MariaDB root password comes first
# pty_answer ANSWERS ARGS...: ARGS run on a terminal (a pty); ANSWERS has lines "PROMPT<TAB>REPLY", typed in
# order as each prompt appears. The output in OUT, the exit code in CODE.
pty_answer() {
  set +e
  OUT="$(python3 -c '
import os, pty, select, sys
answers = [l.rstrip("\n").split("\t", 1) for l in open(sys.argv[1]) if l.strip()]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[2], sys.argv[2:])
seen = b""; out = b""
while True:
    if not select.select([fd], [], [], 120)[0]:
        break
    try:
        d = os.read(fd, 4096)
    except OSError:
        break
    if not d:
        break
    out += d; seen += d
    while answers and answers[0][0].encode() in seen:
        prompt, reply = answers.pop(0)
        seen = seen[seen.index(prompt.encode()) + len(prompt):]
        os.write(fd, (reply + "\n").encode())
sys.stdout.write(out.decode("utf-8", "replace"))
sys.exit(os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]))
' "$@" 2>&1)"
  CODE="$?"
  set -e
}
jsetup --users "priya@example.com" --acknowledge-data --refresh --yes
assert_eq "0" "$CODE" "$OUT$ERR"
# no password anywhere: not in the Keychain, the secret file or the environment
mv "$MOCK_STATE/keychain/benchbar-mariadb--root" "$TMP_DIR/keychain.saved"
mv "$FL_STATE_DIR/secrets/mariadb-root" "$TMP_DIR/secret.saved"
key_before="$(sha_of "$SHARE_DIR/host.key")"; json_before="$(sha_of "$SHARE_DIR/share.json")"
backups_before="$(ls "$BENCH/sites/macdev/private/backups")"
snap="$(snap_all)"; reset_calls
# the app's way (no terminal, --yes --json) and its dry run: refused with exit 2, naming the password
jsetup --users "priya@example.com" --acknowledge-data --refresh --yes --backup-now
assert_eq "2" "$CODE" "$OUT$ERR"; assert_contains "$OUT$ERR" "MARIADB_ROOT_PASSWORD"
assert_not_contains "$OUT$ERR" "may exist but is not hardened"
jsetup --users "priya@example.com" --acknowledge-data --refresh --yes --dry-run
assert_eq "2" "$CODE" "$OUT$ERR"; assert_contains "$OUT$ERR" "MARIADB_ROOT_PASSWORD"
setup --users "priya@example.com" --acknowledge-data --refresh --yes --backup-now --bench-dir "$BENCH"
assert_eq "2" "$CODE" "$OUT"; assert_contains "$OUT" "MARIADB_ROOT_PASSWORD"
# nothing changed: the identity, share.json (not moved aside), no backup taken, nothing restored
assert_eq "$snap" "$(snap_all)" "(a refusal for the password changes nothing)"
assert_eq "$key_before" "$(sha_of "$SHARE_DIR/host.key")"; assert_eq "$json_before" "$(sha_of "$SHARE_DIR/share.json")"
assert_no_file "$SHARE_DIR/share.json.prev"
assert_eq "$backups_before" "$(ls "$BENCH/sites/macdev/private/backups")"
assert_calls_not_contain 'backup|new-site|restore'
# a copy that stays as it is needs no password
setup --users "priya@example.com" --acknowledge-data --bench-dir "$BENCH" --dry-run
assert_eq "0" "$CODE" "$OUT"
# at a terminal the plan says it will ask, and the password typed there makes the copy (and is kept)
printf '' >"$TMP_DIR/answers"
pty_answer "$TMP_DIR/answers" "$FM" share setup --users "priya@example.com" --acknowledge-data --refresh --dry-run --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "asks for the MariaDB root password first"
printf 'Replaces the copy\ty\nMariaDB root password:\trootpw\nconfirm MariaDB root password:\trootpw\n' >"$TMP_DIR/answers"
pty_answer "$TMP_DIR/answers" "$FM" share setup --users "priya@example.com" --acknowledge-data --refresh --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "share.localhost is ready"
assert_not_contains "$OUT" "rootpw" "(the typed password is never echoed)"
assert_eq "rootpw" "$(cat "$MOCK_STATE/keychain/benchbar-mariadb--root")"
assert_file "$SHARE_DIR/share.json"
cp "$TMP_DIR/secret.saved" "$FL_STATE_DIR/secrets/mariadb-root"

# a plain setup never inherits users or label from a stale share.json.prev
rm -rf "$SHARE_DIR"; mkdir -p "$SHARE_DIR"; chmod 700 "$SHARE_DIR"
printf '{\n  "allowed_users": ["stale@example.com"],\n  "room_label": "Stale"\n}\n' >"$SHARE_DIR/share.json.prev"
setup --acknowledge-data --bench-dir "$BENCH" --dry-run
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "--users A,B"

printf 'test-share: ok\n'
