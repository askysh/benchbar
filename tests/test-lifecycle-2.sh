#!/usr/bin/env bash
# The bench lifecycle on Linux: forget and remove take the systemd unit, the
# helper block in ~/.bashrc stays while another bench has a unit, and site
# hosts --prune does nothing (no hosts block on Linux).
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
if ! declare -F use_linux >/dev/null; then
  printf 'skipped: the harness has no Linux platform switch (use_linux) yet\n'
  exit 0
fi
use_linux
export USER=tester

A="$HOME/frappe-bench"
B="$HOME/dev/side-one"
C="$HOME/dev/side-two"
make_fake_bench "$A" linuxdev.localhost
make_fake_bench "$B" one.localhost
make_fake_bench "$C" two.localhost
printf '{\n "db_name": "_00000000000000b1"\n}\n' >"$B/sites/one.localhost/site_config.json"
printf '{\n "db_name": "_00000000000000c1"\n}\n' >"$C/sites/two.localhost/site_config.json"
for b in "$A" "$B" "$C"; do printf 'port 11000\n' >"$b/config/redis_queue.conf"; printf 'port 13000\n' >"$b/config/redis_cache.conf"; done
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
# the MariaDB client the apt package puts on PATH
mkdir -p "$TMP_DIR/xbin"; cp "$ROOT/tests/mocks/mariadb" "$TMP_DIR/xbin/mariadb"; chmod +x "$TMP_DIR/xbin/mariadb"
export FL_MARIADB_BIN="$TMP_DIR/xbin/mariadb"
# the root password file benchbar keeps on Linux (the macOS test uses the environment)
mkdir -p "$FL_STATE_DIR/secrets"; printf 'rootpw\n' >"$FL_STATE_DIR/secrets/mariadb-root"; chmod 600 "$FL_STATE_DIR/secrets/mariadb-root"
printf '_00000000000000b1\n_00000000000000c1\n' >"$MOCK_STATE/mariadb_dbs"
for b in "$A" "$B" "$C"; do run_fm service --yes --bench-dir "$b"; assert_eq "0" "$CODE" "$OUT"; done
udir="$XDG_CONFIG_HOME/systemd/user"
assert_file "$udir/benchbar-side-one.service"
assert_file "$udir/benchbar-side-two.service"
noni() { set +e; OUT="$(BENCHBAR_NONINTERACTIVE=1 "$FM" "$@" 2>"$MOCK_STATE/stderr" </dev/null)"; CODE="$?"; ERR="$(cat "$MOCK_STATE/stderr")"; set -e; }

# ---- forget: the unit goes aside, the folder stays, the helper block stays for the other benches
noni bench forget "$B" --dry-run --json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "True True" "$(printf '%s' "$OUT" | jget - '"%s %s" % (d["service"], d["can_apply"])')"
TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
noni bench forget "$B" --apply "$TOKEN" --yes --json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_no_file "$udir/benchbar-side-one.service"
assert_file "$B/sites/one.localhost/site_config.json"
assert_calls_contain '^systemctl --user disable --now benchbar-side-one.service$'
grep -q -x -F "# >>> benchbar >>>" "$HOME/.bashrc" || fail "the helper block stays while another bench has a unit"

# ---- remove, by a person at a terminal: backup, drop, the unit, the folder into the trash
noni bench remove "$C" --dry-run --json
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')"
RTOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
reset_calls
run_fm_tty bench remove "$C" --confirm-bench side-two --apply "$RTOKEN" --yes
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^bench drop-site two.localhost --db-root-password @secret0@$'
assert_no_file "$udir/benchbar-side-two.service"
assert_no_file "$C"
[[ -n "$(find "$HOME/dev/.benchbar-trash" -maxdepth 1 -name 'side-two-*' 2>/dev/null)" ]] || fail "the folder is in the trash"

# ---- hosts --prune is a no-op on Linux: nothing is edited
before="$(cat "$FL_HOSTS_FILE")"
run_fm site hosts --prune --bench-dir "$A"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "does not edit"
assert_eq "$before" "$(cat "$FL_HOSTS_FILE")"

printf 'test-lifecycle-2: ok\n'
