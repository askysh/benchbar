#!/usr/bin/env bash
# Sites (list, add, default, hosts, and sites[] in the JSON) and the opt in
# scheduler (service --with-schedule / --without-schedule).
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/dev/v16-bench"
make_fake_bench "$BENCH" v16dev
printf 'port 11000\n' >"$BENCH/config/redis_queue.conf"; printf 'port 13000\n' >"$BENCH/config/redis_cache.conf"
printf '127.0.0.1 v16dev\n' >>"$FL_HOSTS_FILE"
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
export MARIADB_ROOT_PASSWORD=rootpw

# ---- list: one site, the default, in the hosts file, no ping while stopped
run_fm site list --bench-dir "$BENCH"
assert_contains "$OUT" "v16dev"
run_fm site list --json --bench-dir "$BENCH"
assert_eq "[{'name': 'v16dev', 'default': True, 'hosts_entry': True, 'ping_code': None, 'db_name': '_v16dev', 'db_port': 3306}]" "$(printf '%s' "$OUT" | jget - 'd["sites"]')"
assert_not_contains "$OUT" "db_password" "(site list carries the database name and port, never the password)"
assert_not_contains "$OUT" "fake-db-pw"
# db_port from common_site_config.json when the bench's MariaDB is not on 3306; no db_name without one
cp "$BENCH/sites/common_site_config.json" "$TMP_DIR/common_site_config.json.orig"
printf '{\n "db_port": 3307,\n "default_site": "v16dev",\n "webserver_port": 8000\n}\n' >"$BENCH/sites/common_site_config.json"
mkdir -p "$BENCH/sites/noname"; printf '{}\n' >"$BENCH/sites/noname/site_config.json"
run_fm site list --json --bench-dir "$BENCH"
assert_eq "noname:None:3307 v16dev:_v16dev:3307" "$(printf '%s' "$OUT" | jget - '" ".join("%s:%s:%s" % (s["name"], s["db_name"], s["db_port"]) for s in d["sites"])')"
rm -r "$BENCH/sites/noname"; cp "$TMP_DIR/common_site_config.json.orig" "$BENCH/sites/common_site_config.json"

# ---- add: refusals first
run_fm site add "Bad_Name" --bench-dir "$BENCH"; assert_eq "1" "$CODE"; assert_contains "$OUT" "Invalid site name"
run_fm site add v16two --apps "nosuchapp" --bench-dir "$BENCH"; assert_eq "1" "$CODE"; assert_contains "$OUT" "nosuchapp is not in"
run_fm site add v16two --yes --bench-dir "$BENCH"; assert_eq "1" "$CODE"; assert_contains "$OUT" "ADMIN_PASSWORD="
# dry run: nothing is created, nothing asked
reset_calls; snap="$(snapshot "$BENCH/sites" "$FL_HOSTS_FILE")"
run_fm site add v16two --dry-run --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "$snap" "$(snapshot "$BENCH/sites" "$FL_HOSTS_FILE")" "(dry run)"
assert_calls_not_contain '^bench new-site'
# the real thing: new-site with the MariaDB password, hosts line, the default stays
reset_calls
ADMIN_PASSWORD=adminpw run_fm site add v16two --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
# the passwords go to frappe on stdin: placeholders on the command line, nothing in any log
assert_calls_contain '^bench new-site v16two --mariadb-root-password @secret0@ --admin-password @secret1@ --no-mariadb-socket$'
assert_eq "rootpw
adminpw" "$(cat "$MOCK_STATE/stdin-new-site")"
assert_not_contains "$(cat "$MOCK_LOG")" "adminpw"
assert_not_contains "$(cat "$MOCK_LOG")" "rootpw"
assert_not_contains "$(cat "$FL_STATE_DIR"/logs/*.log)" "adminpw"
assert_not_contains "$OUT" "adminpw"
assert_calls_not_contain '^bench --site v16two install-app'
assert_calls_contain '^redis-server config/redis_queue.conf --daemonize yes$' "(frappe v16 needs the bench's Redis for new-site)"
assert_calls_contain '^redis-cli -p 11000 shutdown save$'
grep -q '^127.0.0.1 v16two$' "$FL_HOSTS_FILE" || fail "hosts line for the new site"
assert_contains "$OUT" "the default site stays v16dev"
run_fm site list --json --bench-dir "$BENCH"
assert_eq "v16dev:True v16two:False" "$(printf '%s' "$OUT" | jget - '" ".join("%s:%s" % (s["name"], s["default"]) for s in d["sites"])')"
# again: unchanged, no second new-site
reset_calls
run_fm site add v16two --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "site v16two already exists"
assert_calls_not_contain '^bench new-site'
# a failed new-site still stops the Redis it started (the exit handler does it)
reset_calls
MOCK_BENCH_NEW_SITE_EXIT=1 ADMIN_PASSWORD=adminpw run_fm site add v16broken --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_calls_contain '^redis-cli -p 11000 shutdown save$' "(cleanup after a failure)"
! grep -q -E '^(11000|13000) ' "$MOCK_LISTEN" || fail "no setup Redis may stay behind"

# an interrupted new-site (the folder is there, the marker too) is a recovery,
# never "already exists": the next run refuses and says how to move it aside
mkdir -p "$BENCH/sites/v16half"
mkdir -p "$BENCH/logs/.benchbar"; printf '2026-10-03T10:00:00Z\n' >"$BENCH/logs/.benchbar/creating-v16half"
reset_calls
ADMIN_PASSWORD=adminpw run_fm site add v16half --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "a previous bench new-site v16half did not finish (started 2026-10-03T10:00:00Z); the site folder is incomplete"
assert_contains "$OUT" "mv ${BENCH}/sites/v16half ~/v16half.incomplete"
assert_not_contains "$OUT" "already exists"
assert_calls_not_contain '^bench (new-site|--site v16half install-app)'
assert_file "$BENCH/sites/v16half" "(benchbar never moves a site folder itself)"
rm -rf "$BENCH/sites/v16half"; rm -f "$BENCH/logs/.benchbar/creating-v16half"
# a new-site that fails leaves the marker, so the half made site is caught next time
MOCK_BENCH_NEW_SITE_EXIT=1 ADMIN_PASSWORD=adminpw run_fm site add v16fail --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_file "$BENCH/logs/.benchbar/creating-v16fail" "(the marker stays after a failed new-site)"
# a finished new-site leaves no marker
ADMIN_PASSWORD=adminpw run_fm site add v16done --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_no_file "$BENCH/logs/.benchbar/creating-v16done"
rm -rf "$BENCH/sites/v16done"; rm -f "$BENCH/logs/.benchbar/creating-v16fail"

# another bench's Redis on these ports is refused: its workers would get our jobs
add_listener 11000 5110 redis-server; mkdir -p "$MOCK_STATE/cwd"; printf '%s' "$HOME/other-bench" >"$MOCK_STATE/cwd/5110"
reset_calls
ADMIN_PASSWORD=adminpw run_fm site add v16five --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "Port 11000 (config/redis_queue.conf) is held by another process running in ${HOME}/other-bench"
assert_calls_not_contain '^bench new-site'
sed_inplace '/^11000 /d' "$MOCK_LISTEN"
# a running bench's Redis is used as it is, never started twice or stopped
add_listener 11000 5111 redis-server; add_listener 13000 5112 redis-server
printf '%s' "$BENCH" >"$MOCK_STATE/cwd/5111"; printf '%s/config' "$BENCH" >"$MOCK_STATE/cwd/5112"
reset_calls
ADMIN_PASSWORD=adminpw run_fm site add v16four --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain '^redis-(server|cli)'
sed_inplace '/^1[13]000 /d' "$MOCK_LISTEN"
# apps from apps/
mkdir -p "$BENCH/apps/erpnext"
ADMIN_PASSWORD=adminpw run_fm site add v16three --apps erpnext --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^bench --site v16three install-app erpnext$'

# ---- sites[] in status and list, with the hosts state
sed_inplace '/v16three/d' "$FL_HOSTS_FILE"
run_fm status --json --bench-dir "$BENCH"
assert_eq "False" "$(printf '%s' "$OUT" | jget - '[s for s in d["sites"] if s["name"]=="v16three"][0]["hosts_entry"]')"
assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["scheduler"]')"
run_fm list --json
assert_eq "4" "$(printf '%s' "$OUT" | jget - 'len(d["benches"][0]["sites"])')"

# ---- hosts: only the missing line is added
reset_calls
run_fm site hosts --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
grep -q '^127.0.0.1 v16three$' "$FL_HOSTS_FILE" || fail "site hosts adds the missing line"
assert_eq "1" "$(grep -c '^127.0.0.1 v16two$' "$FL_HOSTS_FILE")" "(no duplicate lines)"
run_fm site hosts --yes --bench-dir "$BENCH"
assert_contains "$OUT" "unchanged"

# ---- default: bench use, remembered, the runner pings the new default
run_fm site default nosuch --bench-dir "$BENCH"; assert_eq "1" "$CODE"
run_fm site default v16two --dry-run --bench-dir "$BENCH"
assert_eq "v16dev" "$(cat "$BENCH/sites/currentsite.txt")" "(dry run)"
run_fm site default v16two --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "v16two" "$(cat "$BENCH/sites/currentsite.txt")"
grep -q '^SITE="v16two"$' "$BENCH/benchbar-run.sh" || fail "the runner pings the default site"
run_fm status --json --bench-dir "$BENCH"
assert_eq "v16two" "$(printf '%s' "$OUT" | jget - 'd["site"]')"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[OK] Runner script"
run_fm site default v16two --bench-dir "$BENCH"
assert_contains "$OUT" "unchanged"

# ---- scheduler: off by default, the Procfile is the one from before 0.4
before="$(cat "$BENCH/Procfile.lean")"
assert_not_contains "$before" "schedule:"
run_fm service --dry-run --with-schedule --bench-dir "$BENCH"
assert_eq "$before" "$(cat "$BENCH/Procfile.lean")" "(dry run)"
assert_contains "$OUT" "Procfile.lean"
run_fm service --yes --with-schedule --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
grep -q '^schedule: bench schedule$' "$BENCH/Procfile.lean" || fail "the scheduler line"
run_fm status --json --bench-dir "$BENCH"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["scheduler"]')"
# repair keeps it
run_fm repair --yes --bench-dir "$BENCH"
grep -q '^schedule: bench schedule$' "$BENCH/Procfile.lean" || fail "repair keeps the scheduler"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[OK] Scheduler: on"
assert_contains "$OUT" "[OK] Procfile.lean"
# and off again: byte for byte the Procfile from before
run_fm service --yes --without-schedule --bench-dir "$BENCH"
assert_eq "$before" "$(cat "$BENCH/Procfile.lean")"

# ---- console and db: bench's own shells for the default site or --site, nothing written
reset_calls; snap="$(snapshot "$BENCH/sites" "$FL_STATE_DIR")"
run_fm console --bench-dir "$BENCH" </dev/null
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^bench --site v16(dev|two) console$' "(the default site)"
run_fm db --site v16two --bench-dir "$BENCH" </dev/null
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^bench --site v16two mariadb$'
assert_not_contains "$(cat "$MOCK_LOG")" "rootpw" "(db uses the site's own user, never the root password)"
assert_eq "$snap" "$(snapshot "$BENCH/sites" "$FL_STATE_DIR")" "(console and db write nothing)"
run_fm db --site nosuch --bench-dir "$BENCH" </dev/null
assert_eq "1" "$CODE"; assert_contains "$OUT" "No site 'nosuch'"
run_fm console extra --bench-dir "$BENCH" </dev/null
assert_eq "1" "$CODE"; assert_contains "$OUT" "Unknown argument for console"

printf 'test-sites: ok\n'
