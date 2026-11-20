#!/usr/bin/env bash
# The end of a bench's life: bench forget, remove, scratch and gc (plans with
# tokens, a person for the ones that delete), install --scratch, db orphans,
# site hosts --prune, and uninstall-service keeping the shared helper block
# while another bench has a service.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

A="$HOME/frappe-bench"
B="$HOME/dev/scratch-one"
C="$HOME/dev/scratch-two"
make_fake_bench "$A" macdev
make_fake_bench "$B" one.localhost
make_fake_bench "$C" two.localhost
# frappe's own shape for the databases of the sites
printf '{\n "db_name": "_00000000000000a1"\n}\n' >"$A/sites/macdev/site_config.json"
printf '{\n "db_name": "_00000000000000b1"\n}\n' >"$B/sites/one.localhost/site_config.json"
printf '{\n "db_name": "_00000000000000c1"\n}\n' >"$C/sites/two.localhost/site_config.json"
for b in "$A" "$B" "$C"; do printf 'port 11000\n' >"$b/config/redis_queue.conf"; printf 'port 13000\n' >"$b/config/redis_cache.conf"; done
printf '127.0.0.1 macdev\n\n# >>> benchbar >>>\n127.0.0.1 one.localhost\n127.0.0.1 two.localhost\n127.0.0.1 gone.localhost\n127.0.0.1 keep.localhost\n# <<< benchbar <<<\n' >>"$FL_HOSTS_FILE"
D="$HOME/dev/trial-three"
E="$HOME/elsewhere/kept-bench"
F="$HOME/elsewhere/loose-bench"
make_fake_bench "$D" three.localhost
make_fake_bench "$E" keep.localhost
make_fake_bench "$F" loose.localhost
printf '{\n "db_name": "_00000000000000d1"\n}\n' >"$D/sites/three.localhost/site_config.json"
printf '{\n "db_name": "_00000000000000e1"\n}\n' >"$E/sites/keep.localhost/site_config.json"
for b in "$D" "$E"; do printf 'port 11000\n' >"$b/config/redis_queue.conf"; printf 'port 13000\n' >"$b/config/redis_cache.conf"; done
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
export MARIADB_ROOT_PASSWORD=rootpw
printf '_00000000000000a1\n_00000000000000b1\n_00000000000000c1\n_00000000000000d1\n_00000000000000e1\n_00000000000000dd\nmysql\n' >"$MOCK_STATE/mariadb_dbs"
run_fm service --yes --bench-dir "$A"; assert_eq "0" "$CODE" "$OUT"
run_fm service --yes --bench-dir "$B"; assert_eq "0" "$CODE" "$OUT"
run_fm service --yes --bench-dir "$C"; assert_eq "0" "$CODE" "$OUT"
run_fm service --yes --bench-dir "$D"; assert_eq "0" "$CODE" "$OUT"
run_fm service --yes --bench-dir "$E"; assert_eq "0" "$CODE" "$OUT"
gstate() { sed -n "s/^$1=//p" "$FL_STATE_FILE"; }
assert_eq "$A" "$(gstate BENCH_DIR)"
PLB="$HOME/Library/LaunchAgents/com.benchbar.scratch-one.plist"
PLC="$HOME/Library/LaunchAgents/com.benchbar.scratch-two.plist"
assert_file "$PLB"; assert_file "$PLC"
run_json() { set +e; OUT="$("$FM" "$@" 2>"$MOCK_STATE/stderr")"; CODE="$?"; ERR="$(cat "$MOCK_STATE/stderr")"; set -e; }
noni() { BENCHBAR_NONINTERACTIVE=1 run_json "$@" </dev/null; }

# ---- uninstall-service keeps the shared helper block while another bench has a service
run_fm uninstall-service --yes --bench-dir "$C"
assert_eq "0" "$CODE" "$OUT"
assert_no_file "$PLC"
assert_contains "$OUT" "helper block in"
grep -q -x -F "# >>> benchbar >>>" "$HOME/.zshrc" || fail "the helper block stays while other benches have a service"
run_fm service --yes --bench-dir "$C"; assert_eq "0" "$CODE" "$OUT"

# ---- forget: the plan, a refused stale token, then the run (an agent may run this one)
noni bench forget "$B" --dry-run --json
assert_eq "0" "$CODE" "$OUT"
assert_eq "forget True False True" "$(printf '%s' "$OUT" | jget - '"%s %s %s %s" % (d["action"], d["can_apply"], d["default"], d["service"])')"
TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
assert_not_contains "$(printf '%s' "$OUT" | jget - '" ".join(s["id"] for s in d["steps"])')" "trash"
snap="$(snapshot "$B/sites" "$B/apps" "$B/env")"
noni bench forget "$B" --apply "$(printf 'f%.0s' $(seq 64))" --yes --json
assert_eq "1" "$CODE" "$OUT$ERR"
assert_contains "$ERR" "plan changed"
assert_file "$PLB"
noni bench forget --apply "$TOKEN" "$B" --yes --json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["done"]')"
assert_no_file "$PLB"
assert_eq "$snap" "$(snapshot "$B/sites" "$B/apps" "$B/env")" "(forget leaves the sites, apps and env as they are)"
assert_no_file "$B/Procfile.lean" "(only benchbar's own service files go, each backed up)"
assert_file "$B/sites/one.localhost/site_config.json"
assert_file "$FL_STATE_DIR/forgotten"
grep -q '^127.0.0.1 one.localhost$' "$FL_HOSTS_FILE" || fail "forget keeps the hosts lines"
grep -q -x -F "# >>> benchbar >>>" "$HOME/.zshrc" || fail "the helper block stays: other benches have a service"
run_json bench forget "$B" --dry-run --json
assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')"
assert_contains "$OUT" "nothing to forget"
# a bench with no registration and no service is refused, not "forgotten"
run_fm bench forget "$HOME/nowhere" --dry-run
assert_eq "1" "$CODE" "$OUT"

# ---- a forgotten bench that stays in place: its databases and hosts lines are not leftovers
noni bench forget "$E" --dry-run --json
EF="$(printf '%s' "$OUT" | jget - 'd["token"]')"
noni bench forget "$E" --apply "$EF" --yes --json
assert_eq "0" "$CODE" "$OUT$ERR"

# ---- scratch: install --scratch is checked up front; bench scratch marks and clears
run_fm install --scratch --make-default --bench-dir "$HOME/dev/never" --dry-run
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "do not go together"
run_fm install --ttl 3 --bench-dir "$HOME/dev/never" --dry-run
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "--ttl goes with --scratch"
run_fm install --scratch --ttl 0 --bench-dir "$HOME/dev/never" --dry-run
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "from 1 to 90"
export FL_NOW=1800000000
run_fm register "$B" "$C"; assert_eq "0" "$CODE" "$OUT"
noni bench scratch "$B" --ttl 2 --json
assert_eq "1" "$CODE" "$OUT$ERR"
assert_contains "$ERR$OUT" "--yes"
run_json bench scratch "$B" --ttl 2 --yes --json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "1800172800" "$(printf '%s' "$OUT" | jget - 'd["scratch_until"]')"
run_json bench scratch "$C" --yes --json
assert_eq "1800604800" "$(printf '%s' "$OUT" | jget - 'd["scratch_until"]')" "(7 days by default)"
run_json bench scratch "$A" --ttl 1 --yes --json
assert_eq "0" "$CODE" "$OUT$ERR"

# ---- gc: nothing has expired yet; later B and the default bench A have
noni bench gc --dry-run --json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "0 2 1" "$(printf '%s' "$OUT" | jget - '"%d %d %d" % (len(d["expired"]), len(d["pending"]), len(d["skipped"]))')"
assert_contains "$(printf '%s' "$OUT" | jget - 'd["skipped"][0]["why"]')" "default bench"
export FL_NOW=1800200000
noni bench gc --dry-run --json
assert_eq "$B" "$(printf '%s' "$OUT" | jget - 'd["expired"][0]["bench"]')"
GCTOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
ISO0="$(date -u -r 1800000000 +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @1800000000 +%Y-%m-%dT%H:%M:%SZ)"
assert_eq "agent $ISO0" "$(printf '%s' "$OUT" | jget - '"%s %s" % (d["expired"][0]["marked_by"], d["expired"][0]["marked_at"])')" "(the plan says who marked it, and when)"
# a scratch bench benchbar does not know (not registered, no service, outside the usual folders) is not collected
run_json bench scratch "$F" --ttl 1 --yes --json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_contains "$ERR" "does not know"
export FL_NOW=1801000000
noni bench gc --dry-run --json
assert_not_contains "$OUT" "loose-bench" "(gc looks only at benches benchbar knows)"
export FL_NOW=1800200000

# ---- remove and gc delete data: a person only
noni bench remove "$B" --confirm-bench scratch-one --apply "$GCTOKEN" --yes --json
assert_eq "1" "$CODE" "$OUT$ERR"
assert_contains "$ERR$OUT" "a person at a terminal"
noni bench gc --apply "$GCTOKEN" --yes --json
assert_eq "1" "$CODE" "$OUT$ERR"
assert_contains "$ERR$OUT" "a person at a terminal"
run_fm bench remove "$B" --confirm-bench scratch-one --apply "$GCTOKEN" --yes </dev/null
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "needs a person at a terminal"
assert_file "$B/sites/one.localhost/site_config.json"
assert_calls_not_contain 'drop-site'

# ---- remove: the plan an agent may read, the default bench refused
noni bench remove "$B" --dry-run --json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "remove True" "$(printf '%s' "$OUT" | jget - '"%s %s" % (d["action"], d["can_apply"])')"
assert_eq "one.localhost _00000000000000b1" "$(printf '%s' "$OUT" | jget - '"%s %s" % (d["sites"][0]["name"], d["sites"][0]["db_name"])')"
assert_contains "$OUT" "/dev/.benchbar-trash"
RTOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
noni bench remove "$A" --dry-run --json
assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')"
assert_contains "$OUT" "is the default bench"

# ---- a mount point is refused: moving it would copy and delete
FL_TEST_MOUNTPOINTS="$D" noni bench remove "$D" --dry-run --json
assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')"
assert_contains "$OUT" "is a mount point"

# ---- remove stops before it drops anything when the backup is not whole (no file archives), and when drop-site fails
noni bench remove "$D" --dry-run --json
DTOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
OLD="$D/sites/three.localhost/private/backups/20260101_000000-three_localhost-database.sql.gz"
mkdir -p "${OLD%/*}"; mkgz "$OLD" "an old backup"
reset_calls
MOCK_BENCH_BACKUP_NOFILES=1 run_fm_tty bench remove "$D" --confirm-bench trial-three --apply "$DTOKEN" --yes
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "nothing was dropped"
assert_calls_not_contain 'drop-site'
assert_file "$D/sites/three.localhost/site_config.json"
assert_file "$OLD" "(the older backup is back where it was)"
assert_file "$HOME/Library/LaunchAgents/com.benchbar.trial-three.plist" "(nothing was forgotten)"
MOCK_DROP_SITE_EXIT=1 run_fm_tty bench remove "$D" --confirm-bench trial-three --apply "$DTOKEN" --yes
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "nothing was moved"
assert_file "$D/apps/frappe"
assert_file "$D/sites/three.localhost/site_config.json"
assert_file "$OLD"
assert_file "$HOME/Library/LaunchAgents/com.benchbar.trial-three.plist"
[[ -z "$(find "$HOME/dev/.benchbar-trash" -maxdepth 1 -name 'trial-three-*' 2>/dev/null)" ]] || fail "nothing was moved into the trash"

# ---- remove, by a person at a terminal: the name is confirmed, each site backed up and dropped, the folder moved
run_fm_tty bench remove "$B" --apply "$RTOKEN" --yes
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "--confirm-bench must repeat the folder name"
assert_file "$B/sites/one.localhost/site_config.json"
reset_calls
OLDB="$B/sites/one.localhost/private/backups/20260101_000000-one_localhost-database.sql.gz"
mkdir -p "${OLDB%/*}"; mkgz "$OLDB" "an old backup of one"
MOCK_BENCH_BACKUP_PRUNE=1 run_fm_tty bench remove "$B" --confirm-bench scratch-one --apply "$RTOKEN" --yes
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^bench drop-site one.localhost --db-root-password @secret0@$'
assert_no_file "$B"
TRASH=""; for t in "$HOME"/dev/.benchbar-trash/scratch-one-*; do TRASH="$t"; break; done
assert_file "$TRASH/archived/sites/one.localhost/private/backups" "(the backup is in the moved folder)"
assert_file "$TRASH/archived/sites/one.localhost/private/backups/20260101_000000-one_localhost-database.sql.gz" "(an older backup survives frappe's own prune)"
assert_file "$TRASH/apps/frappe"
assert_no_file "$TRASH/.benchbar.lock" "(the run's own bench lock does not travel into the trash)"
assert_eq "$A" "$(gstate BENCH_DIR)" "(the default bench does not move)"
run_json list --json
assert_not_contains "$OUT" "scratch-one"

# ---- gc, by a person: C expires later; A (default) is never collected
export FL_NOW=1801000000
noni bench gc --dry-run --json
assert_eq "$C" "$(printf '%s' "$OUT" | jget - 'd["expired"][0]["bench"]')"
assert_eq "1" "$(printf '%s' "$OUT" | jget - 'len(d["expired"])')"
GCTOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
run_fm_tty bench gc --apply "$(printf 'a%.0s' $(seq 64))" --yes
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "plan changed"
assert_file "$C/sites/two.localhost/site_config.json"
run_fm_tty bench gc --apply "$GCTOKEN" --yes
assert_eq "0" "$CODE" "$OUT"
assert_no_file "$C"
[[ -d "$(for t in "$HOME"/dev/.benchbar-trash/scratch-two-*; do printf '%s' "$t"; break; done)" ]] || fail "gc moves the folder into the trash"
assert_file "$A/sites/macdev/site_config.json"
assert_no_file "$PLC"
assert_file "$HOME/Library/LaunchAgents/com.benchbar.frappe-bench.plist"

# ---- db orphans: read only, frappe's shape, the archived folder named
# bench drop-site dropped the databases of the two removed benches (the mock's drop-site leaves the list alone)
sed_inplace '/_00000000000000[bc]1/d' "$MOCK_STATE/mariadb_dbs"
mkdir -p "$A/archived/sites/old.localhost"
printf '{\n "db_name": "_00000000000000dd"\n}\n' >"$A/archived/sites/old.localhost/site_config.json"
reset_calls
noni db orphans --json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["read_only"]')"
assert_eq "_00000000000000dd" "$(printf '%s' "$OUT" | jget - '" ".join(o["name"] for o in d["orphans"])')"
assert_eq "$A/archived/sites/old.localhost" "$(printf '%s' "$OUT" | jget - 'd["orphans"][0]["archived_site"]')"
assert_eq "4" "$(printf '%s' "$OUT" | jget - 'd["checked"]')" "(mysql is not of frappe's shape)"
assert_contains "$(printf '%s' "$OUT" | jget - 'd["note"]')" "may belong to a bench or a program benchbar does not know"
assert_not_contains "$OUT" "_00000000000000e1\"" "(the forgotten bench's database is not listed)"
assert_calls_not_contain 'DROP|drop-site'
noni db orphans
assert_eq "0" "$CODE" "$OUT$ERR"
assert_contains "$ERR$OUT" "does not drop them"
assert_contains "$ERR$OUT" "may belong to a bench or a program benchbar does not know"

# ---- site hosts --prune: lines of sites no bench has; one backup, one rewrite; none outside the block
run_fm site hosts --prune --dry-run --bench-dir "$A"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "gone.localhost"
assert_contains "$OUT" "one.localhost"
assert_contains "$OUT" "dry-run: would remove them"
before="$(cat "$FL_HOSTS_FILE")"
assert_eq "$before" "$(cat "$FL_HOSTS_FILE")"
BENCHBAR_NONINTERACTIVE=1 run_fm site hosts --prune --bench-dir "$A"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "run in Terminal to remove them: sudo sed -i .bak"
assert_eq "$before" "$(cat "$FL_HOSTS_FILE")" "(without a terminal nothing is written)"
run_fm_tty site hosts --prune --yes --bench-dir "$A"
assert_eq "0" "$CODE" "$OUT"
! grep -q 'gone.localhost' "$FL_HOSTS_FILE" || fail "the stale line goes"
! grep -q 'one.localhost' "$FL_HOSTS_FILE" || fail "a removed bench's line goes"
grep -q '^127.0.0.1 macdev$' "$FL_HOSTS_FILE" || fail "a line outside the block stays"
grep -q '^127.0.0.1 keep.localhost$' "$FL_HOSTS_FILE" || fail "the forgotten bench's site keeps its hosts line"
run_fm site hosts --prune --yes --bench-dir "$A"
assert_contains "$OUT" "unchanged"

printf 'test-lifecycle: ok\n'
