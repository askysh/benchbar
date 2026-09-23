#!/usr/bin/env bash
# Repair of a partly broken bench (env, node_modules and dist deleted), in dependency order.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/frappe-bench"
make_fake_bench "$BENCH"
mkdir -p "$HOME/Library/LaunchAgents"
printf '127.0.0.1 macdev\n' >>"$FL_HOSTS_FILE"
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"

# break it the way a cleanup tool does
rm -rf "$BENCH/env" "$BENCH/apps/frappe/node_modules" "$BENCH/apps/frappe/frappe/public/dist"
# honcho only existed in the bench env for this user
mv "$MOCK_PIPX_HOME/venvs/frappe-bench/bin/honcho" "$TMP_DIR/honcho.away"
printf 'important\n' >"$BENCH/sites/macdev/site_config.json"

# dry-run: full plan, nothing changed
snap_before="$(snapshot "$HOME" "$BENCH")"
run_fm repair --dry-run --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "rebuild the bench env"
assert_contains "$OUT" "bench setup requirements --node"
assert_contains "$OUT" "bench build"
assert_contains "$OUT" "dry-run: bench setup env --python"
assert_eq "$snap_before" "$(snapshot "$HOME" "$BENCH")" "(dry-run wrote nothing)"
assert_calls_not_contain '^bench (setup|build)'

# real repair
reset_calls
run_fm repair --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
calls="$(grep -E '^(bench|uv) ' "$MOCK_LOG" | tr '\n' ';')"
assert_contains "$calls" "bench setup env --python ${MOCK_BREW_PREFIX}/opt/python@3.11/bin/python3.11;bench setup requirements --python;"
assert_contains "$calls" "bench setup requirements --node;"
assert_contains "$calls" "bench build;"
assert_contains "$calls" "bench --site all clear-cache;bench --site all clear-website-cache"
# order: env before node before build before clear-cache, honcho after env
python3 - "$MOCK_LOG" <<'PY' || fail "repair order wrong"
import sys
lines=[l.strip() for l in open(sys.argv[1])]
def idx(prefix):
    return next(i for i,l in enumerate(lines) if l.startswith(prefix))
assert idx("bench setup env") < idx("uv pip install") < idx("bench setup requirements --node") < idx("bench build") < idx("bench --site all clear-cache"), lines
PY
assert_file "$BENCH/env/bin/python"
assert_file "$BENCH/apps/frappe/node_modules/socket.io"
assert_file "$BENCH/apps/frappe/frappe/public/dist/js/desk.bundle.ABC123.js"
assert_file "$BENCH/env/bin/honcho"
grep -q "$BENCH/env/bin/honcho" "$BENCH/frappe-mac-run.sh" || fail "runner must be re-rendered with the new honcho path"
assert_eq "important" "$(cat "$BENCH/sites/macdev/site_config.json")" "(sites must not be touched)"
assert_file "$BENCH/sites/macdev"
assert_calls_not_contain '^bench (update|drop-site|new-site|migrate)'
assert_calls_not_contain 'rm '
# the old env was moved aside (there was none here, so no env.broken expected)
assert_contains "$OUT" "Verify"

# second repair: unchanged
reset_calls
snap_before="$(snapshot "$HOME" "$BENCH")"
run_fm repair --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "unchanged: all"
assert_eq "$snap_before" "$(snapshot "$HOME" "$BENCH")" "(second repair wrote nothing)"
assert_calls_not_contain '^bench (setup|build)'

# a broken env (present but dead) is moved aside, never deleted
rm "$BENCH/env/bin/python"; ln -s /nonexistent "$BENCH/env/bin/python"
printf 'keep me\n' >"$BENCH/env/marker"
run_fm repair --dry-run --bench-dir "$BENCH"
assert_contains "$OUT" "dry-run: would move ${BENCH}/env to ${BENCH}/env.broken."
assert_file "$BENCH/env/marker"
run_fm repair --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
[[ -n "$(ls -d "$BENCH"/env.broken.* 2>/dev/null)" ]] || fail "broken env must be moved aside"
grep -q 'keep me' "$BENCH"/env.broken.*/marker || fail "moved-aside env must keep its content"

# hosts entry: asked unless --yes; with --yes it is applied through sudo
printf '127.0.0.1 localhost\n' >"$FL_HOSTS_FILE"
run_fm repair --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
grep -q '^127.0.0.1 macdev$' "$FL_HOSTS_FILE" || fail "hosts entry expected"
assert_calls_contain '^sudo tee -a '

# MariaDB exposed: drop-in written and service restarted, my.cnf backed up
add_listener 3306 900 mariadbd '*'
printf 'mariadb@10.11 started akash file\n' >"$MOCK_BREW_SERVICES"
run_fm repair --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_file "$MOCK_BREW_PREFIX/etc/my.cnf.d/frappe-mac-local-only.cnf"
grep -q 'bind-address = 127.0.0.1' "$MOCK_BREW_PREFIX/etc/my.cnf.d/frappe-mac-local-only.cnf" || fail "bind-address expected"
assert_calls_contain '^brew services restart mariadb@10.11$'

# redis on 6379 is never stopped automatically under --yes
: >"$MOCK_LISTEN"; add_listener 6379 901 redis-server
reset_calls
run_fm repair --yes --bench-dir "$BENCH"
assert_calls_not_contain '^brew services stop redis'
assert_contains "$OUT" "not stopping redis on 6379 automatically"

# python formula marked as installed on request
printf 'node@20\n' >"$MOCK_BREW_LEAVES"
run_fm repair --yes --bench-dir "$BENCH"
assert_calls_contain '^brew tab --installed-on-request python@3.11$'
grep -qx 'python@3.11' "$MOCK_BREW_LEAVES" || fail "python must become a leaf"

# large logs are moved aside, not deleted
dd if=/dev/zero of="$BENCH/logs/worker.error.log" bs=1048576 count=3 2>/dev/null
FL_LOG_WARN_MB=2 run_fm repair --yes --bench-dir "$BENCH"
assert_no_file "$BENCH/logs/worker.error.log"
[[ -n "$(ls "$BENCH"/logs/worker.error.log.old.* 2>/dev/null)" ]] || fail "large log must be moved aside"

printf 'test-repair: ok\n'
