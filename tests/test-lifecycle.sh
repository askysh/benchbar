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
printf '127.0.0.1 macdev\n\n# >>> benchbar >>>\n127.0.0.1 one.localhost\n127.0.0.1 two.localhost\n127.0.0.1 gone.localhost\n# <<< benchbar <<<\n' >>"$FL_HOSTS_FILE"
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
export MARIADB_ROOT_PASSWORD=rootpw
printf '_00000000000000a1\n_00000000000000b1\n_00000000000000c1\n_00000000000000dd\nmysql\n' >"$MOCK_STATE/mariadb_dbs"
run_fm service --yes --bench-dir "$A"; assert_eq "0" "$CODE" "$OUT"
run_fm service --yes --bench-dir "$B"; assert_eq "0" "$CODE" "$OUT"
run_fm service --yes --bench-dir "$C"; assert_eq "0" "$CODE" "$OUT"
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

# ---- scratch: install --scratch is checked up front; bench scratch marks and clears
run_fm install --scratch --make-default --bench-dir "$HOME/dev/never" --dry-run
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "do not go together"
run_fm install --ttl 3 --bench-dir "$HOME/dev/never" --dry-run
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "--ttl goes with --scratch"
run_fm install --scratch --ttl 0 --bench-dir "$HOME/dev/never" --dry-run
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "from 1 to 90"
export FL_NOW=1800000000
run_fm register "$B" "$C"; assert_eq "0" "$CODE" "$OUT"
run_json bench scratch "$B" --ttl 2 --json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "1800172800" "$(printf '%s' "$OUT" | jget - 'd["scratch_until"]')"
run_json bench scratch "$C" --json
assert_eq "1800604800" "$(printf '%s' "$OUT" | jget - 'd["scratch_until"]')" "(7 days by default)"
run_json bench scratch "$A" --ttl 1 --json
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

# ---- remove, by a person at a terminal: the name is confirmed, each site backed up and dropped, the folder moved
run_fm_tty bench remove "$B" --apply "$RTOKEN" --yes
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "--confirm-bench must repeat the folder name"
assert_file "$B/sites/one.localhost/site_config.json"
reset_calls
run_fm_tty bench remove "$B" --confirm-bench scratch-one --apply "$RTOKEN" --yes
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^bench drop-site one.localhost --db-root-password @secret0@$'
assert_no_file "$B"
TRASH=""; for t in "$HOME"/dev/.benchbar-trash/scratch-one-*; do TRASH="$t"; break; done
assert_file "$TRASH/archived/sites/one.localhost/private/backups" "(the backup is in the moved folder)"
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
assert_eq "2" "$(printf '%s' "$OUT" | jget - 'd["checked"]')" "(mysql is not of frappe's shape)"
assert_calls_not_contain 'DROP|drop-site'
noni db orphans
assert_eq "0" "$CODE" "$OUT$ERR"
assert_contains "$ERR$OUT" "does not drop them"

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
assert_contains "$OUT" "run in Terminal to remove them: sudo sed"
assert_eq "$before" "$(cat "$FL_HOSTS_FILE")" "(without a terminal nothing is written)"
run_fm_tty site hosts --prune --yes --bench-dir "$A"
assert_eq "0" "$CODE" "$OUT"
! grep -q 'gone.localhost' "$FL_HOSTS_FILE" || fail "the stale line goes"
! grep -q 'one.localhost' "$FL_HOSTS_FILE" || fail "a removed bench's line goes"
grep -q '^127.0.0.1 macdev$' "$FL_HOSTS_FILE" || fail "a line outside the block stays"
run_fm site hosts --prune --yes --bench-dir "$A"
assert_contains "$OUT" "unchanged"

printf 'test-lifecycle: ok\n'
