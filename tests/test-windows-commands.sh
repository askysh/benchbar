#!/usr/bin/env bash
# The commands the Windows tray runs through benchbar.exe, on the Linux
# platform with nothing to ask and no terminal (BENCHBAR_NONINTERACTIVE=1,
# stdin from /dev/null, BENCHBAR_SUDO=env): each one prints its documented
# JSON, names a missing input instead of waiting, and reaches for neither a
# terminal, lsof nor /etc/hosts. Every run below has a lsof that fails, as a
# Ubuntu without the package has it.
# shellcheck disable=SC2016,SC2030,SC2031  # the python expressions are single quoted on purpose
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=tests/lib/apps-fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apps-fixtures.sh"
use_linux
export USER=tester

# no lsof on this machine: the Linux layer asks ss and /proc
mkdir -p "$TMP_DIR/nolsof"
printf '#!/bin/sh\necho "lsof: command not found" >&2\nexit 127\n' >"$TMP_DIR/nolsof/lsof"
chmod +x "$TMP_DIR/nolsof/lsof"
export PATH="$TMP_DIR/nolsof:$PATH"

SITE=linuxdev.localhost
BENCH="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH" "$SITE"
cp "$ROOT/tests/mocks/frappe-python" "$BENCH/env/bin/python"; chmod +x "$BENCH/env/bin/python"
printf 'port 11000\n' >"$BENCH/config/redis_queue.conf"; printf 'port 13000\n' >"$BENCH/config/redis_cache.conf"
mkdir -p "$TMP_DIR/xbin"; cp "$ROOT/tests/mocks/mariadb" "$TMP_DIR/xbin/mariadb"; chmod +x "$TMP_DIR/xbin/mariadb"
export FL_MARIADB_BIN="$TMP_DIR/xbin/mariadb"
# the machine's MariaDB and systemd folders, in the test folder: never the
# host's /etc or /run. The utf8mb4 drop-in is in place, so repair has
# nothing to write as root
export FL_MYSQL_CONF_DIR="$MOCK_STATE/mysql-conf.d" FL_SYSTEMD_RUN_DIR="$MOCK_STATE/run-systemd" FL_MARIADB_DATA_DIR="$MOCK_STATE/var-lib-mysql"
export FL_MYSQL_CNF="$MOCK_STATE/my.cnf"
mkdir -p "$FL_MYSQL_CONF_DIR" "$FL_SYSTEMD_RUN_DIR" "$FL_MARIADB_DATA_DIR"
printf '[client-server]\n!includedir %s/\n' "$FL_MYSQL_CONF_DIR" >"$FL_MYSQL_CNF"
printf '[mysqld]\ncharacter-set-server = utf8mb4\ncollation-server = utf8mb4_unicode_ci\n' >"$FL_MYSQL_CONF_DIR/99-frappe.cnf"
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
mkdir -p "$FL_STATE_DIR/secrets"; printf 'rootpw\n' >"$FL_STATE_DIR/secrets/mariadb-root"; chmod 600 "$FL_STATE_DIR/secrets/mariadb-root"
unset MARIADB_ROOT_PASSWORD ADMIN_PASSWORD
# the machine's sudo asks for this password (see the sudo mock); no command below needs root
SECRET='Zq7!pass w0rd#Xk'
printf '%s\n' "$SECRET" >"$MOCK_STATE/sudo_password"
rm -f "$MOCK_STATE/sudo_cred"

# lx ARGS...: the way the tray runs it: no terminal, nothing can be asked, sudo
# through the environment. stdout in OUT, stderr in ERR, the exit code in CODE
lx() {
  set +e
  OUT="$(env BENCHBAR_NONINTERACTIVE=1 BENCHBAR_SUDO=env BENCHBAR_SUDO_PASSWORD="$SECRET" NO_COLOR=1 "$FM" "$@" 2>"$MOCK_STATE/stderr" </dev/null)"
  CODE=$?
  ERR="$(cat "$MOCK_STATE/stderr")"
  set -e
}
all() { printf '%s\n%s' "$OUT" "$ERR"; }
# doc_ok: stdout is exactly one JSON document; a repair run is a stream, one document per line
doc_ok() {
  if [[ "${1%% *}" == "repair" ]]; then
    printf '%s\n' "$OUT" | python3 -c 'import json,sys; [json.loads(l) for l in sys.stdin if l.strip()]' 2>/dev/null || fail "a line of the stream is not JSON: ${1:-}"$'\n'"$OUT"
    return 0
  fi
  printf '%s' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null || fail "stdout is not one JSON document: ${1:-}"$'\n'"$OUT"$'\n'"$ERR"
}
J() { printf '%s' "$OUT" | jget - "$1"; }
# ok ARGS...: lx, exit 0, and a JSON document when the arguments ask for one
ok() {
  lx "$@"
  assert_eq "0" "$CODE" "$(all)"
  case " $* " in *" --json "*) doc_ok "$*" ;; esac
}
# refused MESSAGE ARGS...: lx, exit 1 and the message names the missing input
refused() {
  local msg="$1"
  shift
  lx "$@"
  assert_eq "1" "$CODE" "$(all)"
  assert_contains "$(all)" "$msg"
}
# the only sudo calls are the password check up front (sudo -k, sudo -S -v); no command below runs anything as root
no_root() { ! grep '^sudo ' "$MOCK_LOG" | grep -v -x -e 'sudo -k' -e 'sudo -S -p  -v' | grep -q . || fail "a command ran as root: $(grep '^sudo ' "$MOCK_LOG" | head -n3)"; }
hosts_snap="$(cat "$FL_HOSTS_FILE")"
no_hosts_edit() { assert_eq "$hosts_snap" "$(cat "$FL_HOSTS_FILE")" "(/etc/hosts is never edited on Linux)"; }

ok service --yes --plain --bench-dir "$BENCH"

# ================================================================ site
ok site list --json --bench-dir "$BENCH"
assert_eq "$SITE True True" "$(J '" ".join(str(x) for x in (d["default_site"], d["sites"][0]["default"], d["sites"][0]["hosts_entry"]))')" "(a *.localhost site resolves without a hosts line)"

# add: the plan, then the apply, which needs the Administrator password named
ok site add lin2.localhost --dry-run --json --bench-dir "$BENCH"
assert_eq "False 1 new_site True 64" "$(J '" ".join(str(x) for x in (d["exists"], len(d["steps"]), d["steps"][0]["kind"], d["hosts_entry"], len(d["token"])))')" "(no hosts step: Linux has none)"
assert_not_contains "$OUT" '"kind":"hosts"'
TOKEN="$(J 'd["token"]')"
reset_calls
refused "ADMIN_PASSWORD" site add lin2.localhost --apply "$TOKEN" --yes --plain --bench-dir "$BENCH"
assert_contains "$(all)" "BENCHBAR_NONINTERACTIVE=1"
assert_calls_not_contain '^bench new-site'
# a root password nothing knows: exit 2, named
mv "$FL_STATE_DIR/secrets/mariadb-root" "$TMP_DIR/mariadb-root.keep"
printf 'other' >"$MOCK_STATE/mariadb_root_pw"
ADMIN_PASSWORD=adminpw lx site add lin2.localhost --apply "$TOKEN" --yes --plain --bench-dir "$BENCH"
assert_eq "2" "$CODE" "$(all)"; assert_contains "$(all)" "MARIADB_ROOT_PASSWORD"
assert_calls_not_contain '^bench new-site'
mv "$TMP_DIR/mariadb-root.keep" "$FL_STATE_DIR/secrets/mariadb-root"; printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
# the apply without --yes, and with a token that is not one
ADMIN_PASSWORD=adminpw refused "pass its token with --apply TOKEN --yes" site add lin2.localhost --apply "$TOKEN" --plain --bench-dir "$BENCH"
ADMIN_PASSWORD=adminpw refused "needs the token of a plan" site add lin2.localhost --apply nope --yes --plain --bench-dir "$BENCH"
# the apply creates the site, leaves the default alone, and runs no sudo
ADMIN_PASSWORD=adminpw lx site add lin2.localhost --apply "$TOKEN" --yes --plain --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$(all)"
assert_file "$BENCH/sites/lin2.localhost/site_config.json"
assert_calls_contain '^bench new-site lin2.localhost'
assert_eq "$SITE" "$(tr -d '[:space:]' <"$BENCH/sites/currentsite.txt")" "(a new site is not the default)"
no_root; no_hosts_edit
printf 'frappe 15.0.0\n' >"$BENCH/sites/lin2.localhost/installed_apps"
# the token is spent: the site exists now
refused "plan changed" site add lin2.localhost --apply "$TOKEN" --yes --plain --bench-dir "$BENCH"
# a name that is no *.localhost: the plan says its hosts line is missing and has no step for it
ok site add nodots --dry-run --json --bench-dir "$BENCH"
assert_eq "False 1" "$(J '" ".join(str(x) for x in (d["hosts_entry"], len(d["steps"])))')"

# default
ok site default lin2.localhost --plain --bench-dir "$BENCH"
assert_eq "lin2.localhost" "$(tr -d '[:space:]' <"$BENCH/sites/currentsite.txt")"
ok site default "$SITE" --plain --bench-dir "$BENCH"
lx site default nosuch --plain --bench-dir "$BENCH"; assert_eq "1" "$CODE"; assert_contains "$(all)" "No site 'nosuch'"

# backup, with and without files, and the list
ok site backup lin2.localhost --json --bench-dir "$BENCH"
assert_eq "False False" "$(J '" ".join(str(x) for x in (d["backup"]["with_files"], d["dry_run"]))')"
ok site backup lin2.localhost --with-files --json --bench-dir "$BENCH"
assert_eq "True" "$(J 'd["backup"]["with_files"] and d["backup"]["files"] is not None and d["backup"]["private_files"] is not None')"
ok site backups lin2.localhost --json --bench-dir "$BENCH"
assert_eq "True 2" "$(J '"%s %d" % (d["backups"][0]["with_files"], len(d["backups"]))')"
# a backup set that restores: bench's mock writes a stub, the restore mock reads the installed apps from the dump
printf "INSERT INTO \`tabDefaultValue\` VALUES ('a','__default','installed_apps','[\\\\\"frappe\\\\\"]');\n" | gzip -c >"$BENCH/sites/lin2.localhost/private/backups/20260901_090000-lin2_localhost-database.sql.gz"
printf '{"db_name":"_old","db_password":"olddbpw"}\n' >"$BENCH/sites/lin2.localhost/private/backups/20260901_090000-lin2_localhost-site_config_backup.json"
BACKUP_STAMP=20260901_090000

# hosts: a clean no-op for names that resolve, the command (never an edit) for one that does not
reset_calls
ok site hosts --bench-dir "$BENCH"
assert_contains "$OUT" "unchanged: every site name resolves to this machine"
no_root; no_hosts_edit
mkdir -p "$BENCH/sites/nodots"; printf '{}\n' >"$BENCH/sites/nodots/site_config.json"
ok site hosts --bench-dir "$BENCH"
assert_contains "$OUT" 'printf "127.0.0.1 nodots\n" | sudo tee -a /etc/hosts'
assert_not_contains "$OUT" "unchanged"
ok site hosts --yes --bench-dir "$BENCH"
no_root; no_hosts_edit
rm -rf "$BENCH/sites/nodots"

# restore: the plan names the set, the apply runs it by token
ok site restore lin2.localhost --from "$BACKUP_STAMP" --dry-run --json --bench-dir "$BENCH"
assert_eq "True $BACKUP_STAMP 64" "$(J '" ".join(str(x) for x in (d["can_apply"], d["source"]["set"]["stamp"], len(d["token"])))')"
RTOKEN="$(J 'd["token"]')"
reset_calls
ok site restore lin2.localhost --from "$BACKUP_STAMP" --apply "$RTOKEN" --yes --json --bench-dir "$BENCH"
refused "--from STAMP|PATH names the backup set" site restore lin2.localhost --dry-run --bench-dir "$BENCH"
lx site restore lin2.localhost --from "$BACKUP_STAMP" --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$(all)"
no_root; no_hosts_edit

# drop: refusals, the plan, the apply with the new default
refused "--confirm-site must repeat the site name exactly" site drop lin2.localhost --json --bench-dir "$BENCH"
ok site default lin2.localhost --plain --bench-dir "$BENCH"
refused "say which site takes its place" site drop lin2.localhost --confirm-site lin2.localhost --dry-run --json --bench-dir "$BENCH"
ok site drop lin2.localhost --confirm-site lin2.localhost --new-default "$SITE" --dry-run --json --bench-dir "$BENCH"
assert_eq "True True 2 False" "$(J '" ".join(str(x) for x in (d["dry_run"], d["is_default"], len(d["steps"]), any(s["needs_password"] for s in d["steps"])))')" "(no hosts step, no password)"
ok site drop lin2.localhost --confirm-site lin2.localhost --new-default "$SITE" --json --bench-dir "$BENCH"
assert_eq "True False None $SITE" "$(J '" ".join(str(x) for x in (d["dropped"], d["hosts_removed"], d["manual_step"], d["default_site"]))')"
assert_calls_contain '^bench drop-site lin2.localhost'
no_root; no_hosts_edit
# no root password anywhere: exit 2, named
mkdir -p "$BENCH/sites/lin3.localhost"; printf '{}\n' >"$BENCH/sites/lin3.localhost/site_config.json"
mv "$FL_STATE_DIR/secrets/mariadb-root" "$TMP_DIR/mariadb-root.keep"; printf 'other' >"$MOCK_STATE/mariadb_root_pw"
lx site drop lin3.localhost --confirm-site lin3.localhost --json --bench-dir "$BENCH"
assert_eq "2" "$CODE" "$(all)"; assert_contains "$(all)" "MARIADB_ROOT_PASSWORD"
mv "$TMP_DIR/mariadb-root.keep" "$FL_STATE_DIR/secrets/mariadb-root"; printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
rm -rf "$BENCH/sites/lin3.localhost"

# ================================================================ app
printf 'frappe\n' >"$BENCH/sites/apps.txt"; rmdir "$BENCH/apps/erpnext"
printf 'frappe 15.0.0\n' >"$BENCH/sites/$SITE/installed_apps"
make_app_remote acme_crm; add_policy acme_crm main
reset_calls
ok app list --json --no-sites --bench-dir "$BENCH"
assert_eq "frappe None" "$(J '" ".join(str(x) for x in (d["apps"][0]["name"], d["sites_checked_at"]))')"
assert_eq "[]" "$(J 'd["apps"][0]["sites"]')" "(--no-sites asks bench nothing)"
assert_calls_not_contain 'list-apps'
ok app add acme_crm --dry-run --json --bench-dir "$BENCH"
assert_eq "clone,build,restart True" "$(J '",".join(s["kind"] for s in d["steps"]) + " " + str(d["can_apply"])')"
ATOKEN="$(J 'd["token"]')"
refused "pass its token" app add acme_crm --apply "$ATOKEN" --plain --bench-dir "$BENCH"
ok app add acme_crm --apply "$ATOKEN" --yes --plain --bench-dir "$BENCH"
assert_contains "$(cat "$BENCH/sites/apps.txt")" "acme_crm"
refused "--yes" app install acme_crm --site "$SITE" --plain --bench-dir "$BENCH"
ok app install acme_crm --site "$SITE" --yes --plain --bench-dir "$BENCH"
assert_calls_contain "^bench --site ${SITE} install-app acme_crm"
push_commits acme_crm 2
ok app update acme_crm --dry-run --json --bench-dir "$BENCH"
assert_eq "2 backup,fast_forward" "$(J '"%d %s" % (d["commits_total"], ",".join(s["kind"] for s in d["steps"][:2]))')"
refused "--yes" app update acme_crm --plain --bench-dir "$BENCH"
ok app update acme_crm --yes --plain --bench-dir "$BENCH"
ok app focus --fetch --json --bench-dir "$BENCH"
assert_eq "acme_crm" "$(J '[a["name"] for a in d["apps"] if a["name"] == "acme_crm"][0]')"
ok app focus acme_crm --plain --bench-dir "$BENCH"
assert_contains "$OUT" "focus app (pinned)"
ok app focus acme_crm --auto --plain --bench-dir "$BENCH"
ok app focus --plain --bench-dir "$BENCH"
assert_contains "$OUT" "acme_crm"
ok app unfocus acme_crm --plain --bench-dir "$BENCH"
no_root

# ================================================================ doctor, repair
ok doctor --json --bench-dir "$BENCH"
assert_eq "True" "$(J 'all("fix" in c and "action" in c for c in d["checks"])')"
ok repair --dry-run --json --bench-dir "$BENCH"
assert_eq "plan True" "$(J '"%s %s" % (d["event"], d["dry_run"])')"
# a finding that repair fixes: the Procfile is gone
rm -f "$BENCH/Procfile.lean"
ok repair --dry-run --json --bench-dir "$BENCH"
assert_contains "$OUT" "procfile"
lx repair --json --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$(all)"; assert_contains "$(all)" "--yes"
ok repair --yes --json --bench-dir "$BENCH"
assert_file "$BENCH/Procfile.lean"
printf '%s' "$OUT" | tail -n1 | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["event"]=="done" and d["exit"]==0, d' || fail "repair --yes --json ends with its done line"
no_root

# ================================================================ ports
ok ports plan --json -- "$BENCH"
assert_eq "64 []" "$(J '"%d %s" % (len(d["token"]), d["entries"][0]["conflicts"])')"
PTOKEN="$(J 'd["token"]')"
ok ports apply "$PTOKEN" --yes --plain -- "$BENCH"
ok ports mode fixed --bench-dir "$BENCH" --plain
ok ports check --json --bench-dir "$BENCH"
assert_eq "fixed []" "$(J '"%s %s" % (d["mode"], d["conflicts"])')"
# something else on the bench's port is found with ss and /proc alone
add_listener 8000 7777 OtherApp
ok ports check --json --bench-dir "$BENCH"
assert_contains "$OUT" "8000 has a listener: pid 7777"
ok ports plan --json -- "$BENCH"
assert_contains "$OUT" "7777"
# one pid on IPv4 and IPv6 is one conflict; two pids are two; a hidden owner is a conflict that is never ours
printf '3306 111 mariadbd 127.0.0.1\n8000 7777 OtherApp 127.0.0.1\n8000 7777 OtherApp ::1\n' >"$MOCK_LISTEN"
ok ports check --json --bench-dir "$BENCH"
assert_eq "1" "$(J 'len(d["conflicts"])')" "(127.0.0.1 and ::1 of pid 7777)"
add_listener 8000 7778 ThirdApp
ok ports check --json --bench-dir "$BENCH"
assert_eq "2" "$(J 'len(d["conflicts"])')"
printf '3306 111 mariadbd 127.0.0.1\n8000 - docker-proxy 0.0.0.0\n' >"$MOCK_LISTEN"
ok ports check --json --bench-dir "$BENCH"
assert_contains "$OUT" "8000 has a listener (owner not visible)"
ok ports plan --json -- "$BENCH"
assert_contains "$OUT" "owner not visible"
printf '3306 111 mariadbd 127.0.0.1\n' >"$MOCK_LISTEN"
ok ports check --json --bench-dir "$BENCH"
assert_eq "[]" "$(J 'd["conflicts"]')"
no_root

# ================================================================ service, lock
ok service --yes --plain --with-schedule --bench-dir "$BENCH"
grep -q '^schedule: bench schedule$' "$BENCH/Procfile.lean" || fail "--with-schedule puts the scheduler in Procfile.lean"
ok service --yes --plain --without-schedule --bench-dir "$BENCH"
! grep -q '^schedule:' "$BENCH/Procfile.lean" || fail "--without-schedule takes it out"
# the bench's own Redis is up already (a running bench): the site setup uses it and does not ask lsof whose it is
printf '11000 5101 redis-server 127.0.0.1\n13000 5102 redis-server 127.0.0.1\n' >>"$MOCK_LISTEN"
add_proc 5101 "redis-server *:11000" "$BENCH"; add_proc 5102 "redis-server *:13000" "$BENCH"
ok site backup "$SITE" --json --bench-dir "$BENCH"
# a hidden owner listed before the real one: the real one's folder is still found
printf '3306 111 mariadbd 127.0.0.1\n11000 - redis-server 127.0.0.1\n11000 5101 redis-server ::1\n13000 5102 redis-server 127.0.0.1\n' >"$MOCK_LISTEN"
ok site backup "$SITE" --json --bench-dir "$BENCH"
# another bench's Redis on the port is refused, naming the folder
printf '3306 111 mariadbd 127.0.0.1\n13000 5103 redis-server 127.0.0.1\n' >"$MOCK_LISTEN"
add_proc 5103 "redis-server *:13000" "$HOME/dev/other-bench"
lx site backup "$SITE" --json --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$(all)"; assert_contains "$(all)" "held by another process running in $HOME/dev/other-bench"
printf '3306 111 mariadbd 127.0.0.1\n' >"$MOCK_LISTEN"
# no lockfile: exit 1 and the way to write one, on stderr
lx lock check --json --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_eq "" "$OUT"; assert_contains "$ERR" "benchbar lock write"
git -C "$BENCH/apps/frappe" init -q -b version-15
git -C "$BENCH/apps/frappe" remote add upstream "https://example.com/frappe/frappe.git"
git -C "$BENCH/apps/frappe" commit -q --allow-empty -m frappe
ok lock write --yes --plain --bench-dir "$BENCH"
lx lock check --json --bench-dir "$BENCH"
doc_ok "lock check"
assert_contains "$OUT" '"in_sync"'

# ================================================================ scan, register
mkdir -p "$HOME/dev/scanme"
ok scan "$HOME/dev" --json
assert_eq "$BENCH" "$(J 'd["benches"][0]["path"]')"
ok register --json -- "$BENCH"
assert_eq "True" "$(J 'd["benches"][0]["default"]')"
lx register --json -- "$HOME/dev/scanme"
assert_eq "1" "$CODE" "$(all)"

# ================================================================ profile
ok profile list --json
assert_eq "v15-lts v16-lts" "$(J '" ".join(p["name"] for p in d["profiles"])')"
ok profile create wincrew --from-bench "$BENCH" --yes --plain
assert_file "$HOME/.config/benchbar/profiles/wincrew.toml"
lx profile create wincrew2 --from-bench "$BENCH" --plain
assert_eq "1" "$CODE" "$(all)"; assert_contains "$(all)" "--yes"
assert_no_file "$HOME/.config/benchbar/profiles/wincrew2.toml"
ok profile check wincrew --json
ok profile export wincrew --plan --json --bench-dir "$BENCH"
EDIGEST="$(J 'd["digest"]')"
ok profile export wincrew --expect "$EDIGEST" --out "$TMP_DIR/wincrew.toml" --yes --json --bench-dir "$BENCH"
assert_file "$TMP_DIR/wincrew.toml"
ok profile import "$TMP_DIR/wincrew.toml" --as wincopy --plan --json
IDIGEST="$(J 'd["digest"]')"
lx profile import "$TMP_DIR/wincrew.toml" --as wincopy --json
assert_eq "1" "$CODE" "$(all)"; assert_contains "$(all)" "--yes"
assert_no_file "$HOME/.config/benchbar/profiles/wincopy.toml"
ok profile import "$TMP_DIR/wincrew.toml" --as wincopy --expect "$IDIGEST" --yes --json
assert_file "$HOME/.config/benchbar/profiles/wincopy.toml"
ok profile update wincopy --plan --json
ok profile check wincopy --json
# subscribe: a team config repo, only its toml files are read
mkdir -p "$WORK/team-config/profiles"
printf 'base = "v15-lts"\ndescription = "Team A"\n\n[[apps]]\nname = "acme_crm"\nrepo = "file://%s/acme_crm.git"\nbranch = "main"\n' "$REMOTES" >"$WORK/team-config/profiles/team-a.toml"
git -C "$WORK/team-config" init -q -b main
git -C "$WORK/team-config" add -A; git -C "$WORK/team-config" commit -q -m profiles
git init -q --bare "$REMOTES/team-config.git"; git -C "$WORK/team-config" push -q "file://$REMOTES/team-config.git" main
git --git-dir="$REMOTES/team-config.git" symbolic-ref HEAD refs/heads/main
ok profile subscribe "file://$REMOTES/team-config.git" --plan --json
lx profile subscribe "file://$REMOTES/team-config.git" --json
assert_eq "1" "$CODE" "$(all)"; assert_contains "$(all)" "--yes"
ok profile subscribe "file://$REMOTES/team-config.git" --yes --json
ok profile list --json
assert_contains "$OUT" '"source":"subscribed"'
lx profile remove wincopy --plain
assert_eq "1" "$CODE" "$(all)"; assert_contains "$(all)" "--yes"
assert_file "$HOME/.config/benchbar/profiles/wincopy.toml"
ok profile remove wincopy --yes --plain
assert_no_file "$HOME/.config/benchbar/profiles/wincopy.toml"
no_root

# ================================================================ logs
printf '10:00:01 web.1 | listening\n10:00:02 web.1 | request\n10:00:03 socketio.1 | up\n' >"$BENCH/logs/bench.log"
printf '10:00:01 web.1 | old run\n' >"$BENCH/logs/bench.previous.log"
printf 'worker line\n' >"$BENCH/logs/worker.log"
ok logs --json -n 5 --bench-dir "$BENCH"
assert_eq "3" "$(J 'len(d["lines"])')"
ok logs --json --process web -n 1 --bench-dir "$BENCH"
assert_eq "1 web.1" "$(J '"%d %s" % (len(d["lines"]), d["lines"][0].split()[1])')"
ok logs --json --process worker --bench-dir "$BENCH"
assert_eq "$BENCH/logs/worker.log" "$(J 'd["file"]')"
ok logs --json --previous --bench-dir "$BENCH"
assert_contains "$OUT" "old run"
ok logs --json --since 2999-01-01T00:00:00Z --bench-dir "$BENCH"
assert_eq "0" "$(J 'len(d["lines"])')"
lx logs --json --since 1h --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$(all)"; assert_contains "$(all)" "Cannot read the time '1h'"
# without --json a terminal would follow the file: no terminal, it prints and ends
ok logs -n 2 --no-follow --bench-dir "$BENCH"

printf 'windows commands on Linux: ok\n'
