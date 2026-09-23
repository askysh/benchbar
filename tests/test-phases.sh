#!/usr/bin/env bash
# The phase scripts under mocks: 00 writes the shell block and utf8mb4 config and exits 2
# while manual steps remain; 01 never moves a real bench aside and asks for passwords
# only when the site must be created; "frappe-mac install" twice changes nothing.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

add_proc 900 "mariadbd --datadir=/x"
add_proc 901 "redis-server *:6379"
printf 'mariadb@10.11 started akash file\nredis started akash file\n' >"$MOCK_BREW_SERVICES"
run00() { set +e; OUT="$("$ROOT/00-mac-system-deps.sh" "$@" 2>&1)"; CODE=$?; set -e; }
run01() { set +e; OUT="$("$ROOT/01-install-bench-and-site.sh" "$@" 2>&1)"; CODE=$?; set -e; }

# ---- 00: fresh machine with MariaDB still password-less
export MOCK_MARIADB_NOPASS_EXIT=0
run00 --profile v15-lts
assert_eq "2" "$CODE" "$OUT"
assert_contains "$OUT" "PENDING MANUAL STEPS"
assert_contains "$OUT" "mariadb-secure-installation"
assert_not_contains "$OUT" "cat >> ~/.zshrc"
grep -q -x -F "# >>> frappe-mac >>>" "$HOME/.zshrc" || fail "00 must write the frappe-mac block"
grep -q "opt/python@3.11/bin" "$HOME/.zshrc" || fail "profile exports expected"
assert_file "$MOCK_BREW_PREFIX/etc/my.cnf.d/frappe.cnf"
grep -q 'character-set-server = utf8mb4' "$MOCK_BREW_PREFIX/etc/my.cnf.d/frappe.cnf" || fail "utf8mb4 config expected"
assert_calls_contain '^brew services restart mariadb@10.11$'
assert_contains "$OUT" "source ${HOME}/.zshrc"

# second run: nothing rewritten, still exit 2 because of the password
reset_calls
snap_before="$(snapshot "$HOME" "$MOCK_BREW_PREFIX/etc")"
sleep 1
run00 --profile v15-lts
assert_eq "2" "$CODE" "$OUT"
assert_eq "$snap_before" "$(snapshot "$HOME" "$MOCK_BREW_PREFIX/etc")" "(00 rerun must write nothing)"
assert_calls_not_contain '^brew services restart'
assert_contains "$OUT" "[OK] frappe.cnf utf8mb4 config present"
assert_contains "$OUT" "has the frappe-mac block"

# password set: all green, exit 0
export MOCK_MARIADB_NOPASS_EXIT=1
run00 --profile v15-lts
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "All dependencies are configured"

# dry-run writes nothing
printf '# fresh\n' >"$HOME/.zshrc"
run00 --profile v15-lts --dry-run
assert_eq "0" "$CODE" "$OUT"
! grep -q 'frappe-mac' "$HOME/.zshrc" || fail "dry-run must not write the block"

# ---- 01: safety on an existing bench that lost its env
BENCH="$HOME/frappe-bench"
make_fake_bench "$BENCH"
rm -rf "$BENCH/env"
run01 --yes --offline
assert_eq "1" "$CODE"
assert_contains "$OUT" "has apps or sites but its env is missing"
assert_contains "$OUT" "frappe-mac repair"
assert_file "$BENCH/sites/macdev/site_config.json"
run01 --yes --offline --repair-bench
assert_eq "1" "$CODE"
assert_file "$BENCH/sites/macdev/site_config.json" "(--repair-bench must refuse to move a bench with sites)"
[[ -z "$(ls -d "$HOME"/frappe-bench.incomplete.* 2>/dev/null)" ]] || fail "a bench with sites must never be moved aside"
rm -rf "$BENCH"

# ---- 01: fresh bench with env passwords, then a rerun without passwords
export MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw
run01 --yes --offline
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain "^bench init ${BENCH} --frappe-branch version-15"
assert_calls_contain "^bench new-site macdev"
assert_eq "$BENCH" "$(sed -n 's/^BENCH_DIR=//p' "$FL_STATE_FILE")"
assert_eq "macdev" "$(sed -n 's/^SITE_NAME=//p' "$FL_STATE_FILE")"
assert_contains "$OUT" "frappe-mac service"
unset MARIADB_ROOT_PASSWORD ADMIN_PASSWORD
reset_calls
run01 --yes --offline
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "already exists: no passwords needed"
assert_calls_not_contain '^bench (init|new-site|get-app)'
assert_calls_not_contain '^mariadb -u root -p'

# ---- frappe-mac install, twice
rm -rf "$BENCH"; : >"$FL_STATE_FILE"; printf '# fresh\n' >"$HOME/.zshrc"
export MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw
run_fm install --yes --bench-dir "$BENCH" --site macdev
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "1. System dependencies"
assert_contains "$OUT" "2. Bench and site"
assert_contains "$OUT" "3. Background service"
assert_contains "$OUT" "Next steps"
assert_file "$BENCH/frappe-mac-run.sh"
assert_file "$HOME/Library/LaunchAgents/com.frappe-mac.frappe-bench.plist"
grep -q '^127.0.0.1 macdev$' "$FL_HOSTS_FILE" || fail "install --yes must add the hosts entry"
unset MARIADB_ROOT_PASSWORD ADMIN_PASSWORD

reset_calls
snap_before="$(snapshot "$HOME" "$BENCH")"
sleep 1
run_fm install --yes --bench-dir "$BENCH" --site macdev
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "unchanged: all"
assert_eq "$snap_before" "$(snapshot "$HOME" "$BENCH")" "(second install must write nothing)"
assert_calls_not_contain '^bench (init|new-site|get-app|build|setup)'
assert_calls_not_contain '^launchctl (bootstrap|bootout|kickstart)'

# install stops cleanly when 00 leaves manual steps
export MOCK_MARIADB_NOPASS_EXIT=0
run_fm install --yes --bench-dir "$BENCH" --site macdev
assert_eq "2" "$CODE" "$OUT"
assert_contains "$OUT" "manual steps pending"
assert_calls_not_contain '^bench init'

printf 'test-phases: ok\n'
