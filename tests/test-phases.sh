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

# ---- 00: a locked Keychain: the generated password is never applied to MariaDB
touch "$MOCK_STATE/keychain_locked"
run00 --yes --profile v15-lts
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "MariaDB was left unchanged"
[[ -z "$(mariadb_pw)" ]] || fail "MariaDB must keep its empty password when the Keychain refuses"
[[ -z "$(keychain_get)" ]] || fail "nothing may be stored in a locked Keychain"
rm -f "$MOCK_STATE/keychain_locked"

# ---- 00: fresh machine: MariaDB without a password, no wkhtmltopdf, no Rosetta
rm -f "$MOCK_BREW_PREFIX/etc/my.cnf.d/frappe.cnf"
touch "$MOCK_STATE/wkhtml_missing"
run00 --yes --profile v15-lts
assert_eq "0" "$CODE" "$OUT"
assert_not_contains "$OUT" "MariaDB root already has a password"
assert_not_contains "$OUT" "mariadb-secure-installation"
# the password was generated, set in SQL, stored in the Keychain and verified
PW="$(keychain_get)"
[[ "${#PW}" -ge 20 ]] || fail "a generated password is expected in the Keychain, got [$PW]"
assert_eq "$PW" "$(mariadb_pw)" "(the Keychain and MariaDB must agree)"
sql="$(cat "$MOCK_STATE/mariadb_sql.log")"
assert_contains "$sql" "DELETE FROM mysql.global_priv WHERE User='';"
assert_contains "$sql" "Host NOT IN ('localhost', '127.0.0.1', '::1')"
assert_contains "$sql" "DROP DATABASE IF EXISTS test;"
assert_contains "$sql" "IDENTIFIED VIA mysql_native_password"
assert_not_contains "$OUT" "$PW" "(the password is never printed)"
assert_not_contains "$(cat "$MOCK_LOG")" "$PW" "(the password is never on a command line)"
assert_contains "$OUT" "saved to the Keychain"
# wkhtmltopdf: Rosetta offered and installed, package downloaded, verified, installed with sudo
assert_contains "$OUT" "Rosetta 2 installed"
assert_calls_contain '^softwareupdate --install-rosetta --agree-to-license$'
assert_calls_contain '^curl .*wkhtmltox-0.12.6-2.macos-cocoa.pkg'
assert_contains "$OUT" "sha256 ok"
assert_calls_contain '^sudo -v$'
assert_calls_contain '^sudo installer -pkg .*wkhtmltox-0.12.6-2.macos-cocoa.pkg -target /$'
assert_contains "$OUT" "[OK] wkhtmltopdf"
assert_file "$FL_STATE_DIR/downloads/wkhtmltox-0.12.6-2.macos-cocoa.pkg"
# shell block and utf8mb4 drop-in
assert_not_contains "$OUT" "cat >> ~/.zshrc"
grep -q -x -F "# >>> benchbar >>>" "$HOME/.zshrc" || fail "00 must write the benchbar block"
grep -q "opt/python@3.11/bin" "$HOME/.zshrc" || fail "profile exports expected"
assert_file "$MOCK_BREW_PREFIX/etc/my.cnf.d/frappe.cnf"
grep -q 'character-set-server = utf8mb4' "$MOCK_BREW_PREFIX/etc/my.cnf.d/frappe.cnf" || fail "utf8mb4 config expected"
assert_calls_contain '^brew services restart mariadb@10.11$'
assert_contains "$OUT" "source ${HOME}/.zshrc"

# second run: nothing rewritten, password read from the Keychain, nothing installed again
reset_calls; : >"$MOCK_STATE/mariadb_sql.log"
snap_before="$(snapshot "$HOME" "$MOCK_BREW_PREFIX/etc")"
sleep 1
run00 --yes --profile v15-lts
assert_eq "0" "$CODE" "$OUT"
assert_eq "$snap_before" "$(snapshot "$HOME" "$MOCK_BREW_PREFIX/etc")" "(00 rerun must write nothing)"
assert_calls_not_contain '^brew services restart'
assert_calls_not_contain '^(sudo|softwareupdate|installer|curl .*wkhtmltox)'
[[ ! -s "$MOCK_STATE/mariadb_sql.log" ]] || fail "no SQL on a rerun"
assert_contains "$OUT" "[OK] MariaDB root password verified (Keychain, unchanged)"
assert_contains "$OUT" "[OK] frappe.cnf utf8mb4 config present"
assert_contains "$OUT" "[OK] wkhtmltopdf patched Qt build"
assert_contains "$OUT" "has the benchbar block"
assert_contains "$OUT" "All dependencies are configured"

# an existing password nobody knows: exit 2 with the manual step; the env var fixes it
rm -f "$MOCK_STATE/keychain/benchbar-mariadb--root"
printf 'olderpw' >"$MOCK_STATE/mariadb_root_pw"
run00 --yes --profile v15-lts
assert_eq "2" "$CODE" "$OUT"
assert_contains "$OUT" "PENDING MANUAL STEPS"
assert_contains "$OUT" "MARIADB_ROOT_PASSWORD='the password'"
MARIADB_ROOT_PASSWORD=wrongpw run00 --yes --profile v15-lts
assert_eq "2" "$CODE" "$OUT"
assert_contains "$OUT" "does not work"
MARIADB_ROOT_PASSWORD=olderpw run00 --yes --profile v15-lts
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "verified (from MARIADB_ROOT_PASSWORD)"
assert_eq "olderpw" "$(keychain_get)"

# Rosetta declined (no --yes, no terminal): wkhtmltopdf skipped with a warning, still exit 0
rm -f "$MOCK_STATE/rosetta" "$MOCK_STATE/wkhtml_installed"; reset_calls
run00 --profile v15-lts </dev/null
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "PDFs will not work"
assert_calls_not_contain '^(sudo|installer|curl .*wkhtmltox)'
assert_contains "$OUT" "wkhtmltopdf            skipped"

# checksum mismatch: the download is discarded and nothing is installed; a
# failure is listed as such (not as a skip) but does not block the next phase
printf 'tampered\n' >"$MOCK_STATE/download_payload"; printf 'rosetta\n' >"$MOCK_STATE/rosetta"; reset_calls
rm -rf "$FL_STATE_DIR/downloads"
run00 --yes --profile v15-lts
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "checksum mismatch"
assert_contains "$OUT" "wkhtmltopdf            FAILED"
assert_contains "$OUT" "The wkhtmltopdf install failed (not skipped)"
assert_not_contains "$OUT" "wkhtmltopdf            skipped"
assert_calls_not_contain '^sudo installer'
assert_no_file "$FL_STATE_DIR/downloads/wkhtmltox-0.12.6-2.macos-cocoa.pkg.part"
printf 'stub download\n' >"$MOCK_STATE/download_payload"

# sudo refused: skipped with the manual command, still exit 0
touch "$MOCK_STATE/sudo_refused"; rm -rf "$FL_STATE_DIR/downloads"; reset_calls
run00 --yes --profile v15-lts
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "sudo was not available"
assert_calls_not_contain '^sudo installer'
rm -f "$MOCK_STATE/sudo_refused"

# dry-run writes nothing
printf '# fresh\n' >"$HOME/.zshrc"
run00 --profile v15-lts --dry-run
assert_eq "0" "$CODE" "$OUT"
! grep -q 'frappe-mac' "$HOME/.zshrc" || fail "dry-run must not write the block"
touch "$MOCK_STATE/wkhtml_installed"

# ---- 01: safety on an existing bench that lost its env
BENCH="$HOME/frappe-bench"
make_fake_bench "$BENCH"
rm -rf "$BENCH/env"
run01 --yes --offline
assert_eq "1" "$CODE"
assert_contains "$OUT" "has apps or sites but its env is missing"
assert_contains "$OUT" "benchbar repair"
assert_file "$BENCH/sites/macdev/site_config.json"
run01 --yes --offline --repair-bench
assert_eq "1" "$CODE"
assert_file "$BENCH/sites/macdev/site_config.json" "(--repair-bench must refuse to move a bench with sites)"
[[ -z "$(ls -d "$HOME"/frappe-bench.incomplete.* 2>/dev/null)" ]] || fail "a bench with sites must never be moved aside"
rm -rf "$BENCH"

# ---- 01: fresh bench with env passwords, then a rerun without passwords
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
export MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw
run01 --yes --offline
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain '^mariadb -u root -p' "(the password never goes on the command line)"
assert_eq "rootpw" "$(keychain_get)" "(a verified env password is saved)"
assert_calls_contain "^bench init ${BENCH} --frappe-branch version-15"
# the bench's own Redis ran for new-site and install-app, and was stopped after
assert_calls_contain '^redis-server config/redis_queue.conf --daemonize yes$'
assert_calls_contain '^redis-server config/redis_cache.conf --daemonize yes$'
assert_calls_contain '^redis-cli -p 11000 shutdown nosave$'
assert_calls_contain '^redis-cli -p 13000 shutdown nosave$'
! grep -q -E '^(11000|13000) ' "$MOCK_LISTEN" || fail "the setup Redis must be stopped afterwards"
assert_calls_contain "^bench new-site macdev"
assert_eq "$BENCH" "$(sed -n 's/^BENCH_DIR=//p' "$FL_STATE_FILE")"
# the site and profile belong to the bench's own state file
assert_eq "macdev" "$(sed -n 's/^SITE_NAME=//p' "$FL_STATE_DIR/benches/$(basename "$BENCH")"-????????.env)"
assert_eq "v15-lts" "$(sed -n 's/^PROFILE=//p' "$FL_STATE_DIR/benches/$(basename "$BENCH")"-????????.env)"
[[ -z "$(sed -n 's/^SITE_NAME=//p' "$FL_STATE_FILE")" ]] || fail "SITE_NAME no longer lives in state.env"
assert_contains "$OUT" "benchbar service"
unset MARIADB_ROOT_PASSWORD ADMIN_PASSWORD
reset_calls
run01 --yes --offline
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "already exists: no passwords needed"
assert_calls_not_contain '^bench (init|new-site|get-app)'
assert_calls_not_contain '^mariadb -u root -p'

# ---- 01: a fresh site with the root password from the Keychain only
rm -rf "$BENCH"
ADMIN_PASSWORD=adminpw run01 --yes --offline
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "MariaDB root password read from the Keychain"
assert_calls_contain "^bench new-site macdev"
# and none at all: a clear failure, not a hang
rm -rf "$BENCH"; rm -f "$MOCK_STATE/keychain/benchbar-mariadb--root"
ADMIN_PASSWORD=adminpw run01 --yes --offline
assert_eq "2" "$CODE" "$OUT"
assert_contains "$OUT" "not in MARIADB_ROOT_PASSWORD and not in the Keychain"

# ---- benchbar install, twice
rm -rf "$BENCH"; : >"$FL_STATE_FILE"; printf '# fresh\n' >"$HOME/.zshrc"
export MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw
run_fm install --yes --bench-dir "$BENCH" --site macdev
assert_eq "0" "$CODE" "$OUT"
grep -q -x -F "# >>> benchbar >>>" "$FL_HOSTS_FILE" || fail "the hosts entry sits inside marker comments"
assert_eq "1" "$(grep -c '^sudo -v$' "$MOCK_LOG")" "(one sudo prompt for the whole run)"
assert_contains "$OUT" "1. System dependencies"
assert_contains "$OUT" "2. Bench and site"
assert_contains "$OUT" "3. Background service"
assert_contains "$OUT" "Next steps"
assert_file "$BENCH/benchbar-run.sh"
assert_file "$HOME/Library/LaunchAgents/com.benchbar.frappe-bench.plist"
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

# the official package binary wins over an unpatched Homebrew build, which is reported as shadowing it
mkdir -p "$(dirname "$FL_WKHTML_PKG_BIN")"
printf '#!/usr/bin/env bash\nprintf "wkhtmltopdf 0.12.6 (with patched qt)\\n"\n' >"$FL_WKHTML_PKG_BIN"; chmod +x "$FL_WKHTML_PKG_BIN"
rm -f "$MOCK_STATE/wkhtml_installed" "$MOCK_STATE/wkhtml_missing"; reset_calls
MOCK_WKHTML_PATCHED=0 run00 --yes --profile v15-lts
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "[OK] wkhtmltopdf patched Qt build at ${FL_WKHTML_PKG_BIN}"
assert_contains "$OUT" "is not the patched build: Frappe would run it"
assert_contains "$OUT" "brew uninstall wkhtmltopdf"
assert_calls_not_contain '^(sudo installer|curl .*wkhtmltox)' "(nothing to install when the package binary is present)"
MOCK_WKHTML_PATCHED=0 run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] PDF engine: patched build at ${FL_WKHTML_PKG_BIN}, but"
rm -f "$FL_WKHTML_PKG_BIN"; touch "$MOCK_STATE/wkhtml_installed"

# a refused sudo is asked once for the whole install, then every sudo step is skipped
rm -f "$MOCK_STATE/wkhtml_installed"; touch "$MOCK_STATE/wkhtml_missing" "$MOCK_STATE/sudo_refused"
printf '127.0.0.1 localhost\n' >"$FL_HOSTS_FILE"; rm -rf "$FL_STATE_DIR/downloads"; reset_calls
run_fm install --yes --bench-dir "$BENCH" --site macdev
assert_eq "0" "$CODE" "$OUT"
assert_eq "1" "$(grep -c '^sudo -v$' "$MOCK_LOG")" "(a refused sudo is asked exactly once)"
assert_contains "$OUT" "not asking again"
assert_contains "$OUT" "install the patched wkhtmltopdf package (sudo): skipped"
assert_contains "$OUT" "add macdev to /etc/hosts (sudo): skipped"
assert_calls_not_contain '^sudo (installer|tee|cp)'
rm -f "$MOCK_STATE/sudo_refused"; touch "$MOCK_STATE/wkhtml_installed"

# a deliberately skipped wkhtmltopdf (no Rosetta, no terminal) does not fail the install
rm -f "$MOCK_STATE/rosetta" "$MOCK_STATE/wkhtml_installed"; touch "$MOCK_STATE/wkhtml_missing"
run_fm install --bench-dir "$BENCH" --site macdev </dev/null
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "PDFs will not work"
assert_not_contains "$OUT" "still need attention"
printf 'rosetta\n' >"$MOCK_STATE/rosetta"; touch "$MOCK_STATE/wkhtml_installed"

# install stops cleanly when 00 leaves manual steps (unknown root password under --yes)
rm -f "$MOCK_STATE/keychain/benchbar-mariadb--root"; printf 'mystery' >"$MOCK_STATE/mariadb_root_pw"
run_fm install --yes --bench-dir "$BENCH" --site macdev
assert_eq "2" "$CODE" "$OUT"
assert_contains "$OUT" "manual steps pending"
assert_calls_not_contain '^bench init'


# a second site on the same run: the hosts line goes inside the existing block
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
run_fm service --yes --bench-dir "$BENCH" --site second
assert_eq "0" "$CODE" "$OUT"
assert_eq "1" "$(grep -c -x -F "# >>> benchbar >>>" "$FL_HOSTS_FILE")" "(one block only)"
awk '/^# >>> benchbar >>>$/{b=1;next} /^# <<< benchbar <<<$/{b=0} b' "$FL_HOSTS_FILE" | grep -q -x '127.0.0.1 second' || fail "second site inside the block"

printf 'test-phases: ok\n'
