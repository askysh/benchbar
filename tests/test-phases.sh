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
assert_calls_contain '^redis-cli -p 11000 shutdown save$'
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

# ---- 01: a bench on PATH that does not run stops with its owner's reinstall;
# one older than the profile's minimum is a warning with the upgrade command
rm -rf "$BENCH"; reset_calls
BADBIN="$TMP_DIR/badbin"; mkdir -p "$BADBIN"
printf '#!/usr/bin/env bash\nprintf "bad interpreter\\n" >&2; exit 127\n' >"$BADBIN/bench"; chmod +x "$BADBIN/bench"
PATH="$BADBIN:$PATH" ADMIN_PASSWORD=adminpw run01 --yes --offline
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "does not run (bench --version failed)"
assert_contains "$OUT" "uv tool install --reinstall frappe-bench"
assert_calls_not_contain '^bench init'
# a pipx owned bench gets pipx's reinstall
PIPXBIN="$TMP_DIR/pipxbin"; mkdir -p "$PIPXBIN" "$TMP_DIR/pipx/venvs/frappe-bench/bin"
cp "$BADBIN/bench" "$TMP_DIR/pipx/venvs/frappe-bench/bin/bench"; ln -s "$TMP_DIR/pipx/venvs/frappe-bench/bin/bench" "$PIPXBIN/bench"
PATH="$PIPXBIN:$PATH" ADMIN_PASSWORD=adminpw run01 --yes --offline
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "pipx reinstall frappe-bench"
MOCK_BENCH_VERSION=5.10.3 ADMIN_PASSWORD=adminpw run01 --yes --offline
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "[OK] bench 5.10.3 at"
assert_contains "$OUT" "bench 5.10.3 is older than 5.22.0, the oldest known to handle profile v15-lts"
assert_contains "$OUT" "uv tool upgrade frappe-bench"
rm -rf "$BENCH"
MOCK_BENCH_VERSION=5.25.1 ADMIN_PASSWORD=adminpw run01 --yes --offline
assert_eq "0" "$CODE" "$OUT"
assert_not_contains "$OUT" "is older than"

# ---- 01: a fresh site with the root password from the Keychain only
rm -rf "$BENCH"
ADMIN_PASSWORD=adminpw run01 --yes --offline
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "MariaDB root password read from the Keychain"
assert_calls_contain "^bench new-site macdev"
# no ADMIN_PASSWORD and no terminal to ask (an agent): a message and a fix, not a silent exit 1
rm -rf "$BENCH"; reset_calls
run01 --offline </dev/null
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "Cannot ask for ADMIN_PASSWORD: there is no terminal to type it in."
assert_contains "$OUT" "ADMIN_PASSWORD='...' benchbar install"
assert_calls_not_contain '^bench new-site'
# and none at all: a clear failure, not a hang
rm -rf "$BENCH"; rm -f "$MOCK_STATE/keychain/benchbar-mariadb--root"
ADMIN_PASSWORD=adminpw run01 --yes --offline
assert_eq "2" "$CODE" "$OUT"
assert_contains "$OUT" "no working password in MARIADB_ROOT_PASSWORD or the Keychain"

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
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c '^Summary')" "(one Summary for the whole install)"
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

# no Rosetta, no terminal, no --yes: phase 00 skips the package (every
# question is "no") and asks for no sudo password, since nothing in this run
# will install it and the hosts line is already there; the install then stops
# at phase 01's plan, which nothing can confirm, and says so
rm -f "$MOCK_STATE/rosetta" "$MOCK_STATE/wkhtml_installed"; touch "$MOCK_STATE/wkhtml_missing"
grep -q '^127.0.0.1 macdev$' "$FL_HOSTS_FILE" || printf '127.0.0.1 macdev\n' >>"$FL_HOSTS_FILE"
reset_calls
run_fm install --bench-dir "$BENCH" --site macdev </dev/null
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "PDFs will not work"
assert_contains "$OUT" "Cancelled. No bench or site was created"
assert_not_contains "$OUT" "still need attention"
assert_calls_not_contain '^sudo' "(nothing in this run needs sudo, so it is not asked for)"
# with --yes Rosetta and the package would be installed: sudo is asked up front, once
reset_calls
run_fm install --yes --bench-dir "$BENCH" --site macdev
assert_eq "0" "$CODE" "$OUT"
assert_eq "1" "$(grep -c '^sudo -v$' "$MOCK_LOG")" "(one sudo prompt, for the package)"
assert_calls_contain '^sudo installer -pkg'
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

# ---- a stale MARIADB_ROOT_PASSWORD falls through to the Keychain password that works
rm -rf "$BENCH"
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"; printf 'rootpw\n' >"$MOCK_STATE/keychain/benchbar-mariadb--root"
reset_calls
MARIADB_ROOT_PASSWORD=stale-from-an-old-shell ADMIN_PASSWORD=adminpw run01 --yes --offline
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "MARIADB_ROOT_PASSWORD from the environment does not work; trying the Keychain"
assert_contains "$OUT" "MariaDB root password read from the Keychain"
assert_calls_contain "^bench new-site macdev"
# no source works: exit 2, as documented
rm -rf "$BENCH"; reset_calls
printf 'other\n' >"$MOCK_STATE/keychain/benchbar-mariadb--root"
MARIADB_ROOT_PASSWORD=stale ADMIN_PASSWORD=adminpw run01 --yes --offline
assert_eq "2" "$CODE" "$OUT"
assert_contains "$OUT" "no working password in MARIADB_ROOT_PASSWORD or the Keychain"
assert_calls_not_contain '^bench (init|new-site)'
printf 'rootpw\n' >"$MOCK_STATE/keychain/benchbar-mariadb--root"

# ---- cancelled at "Proceed?" with no terminal: nothing registered, no agent, exit 1
CANCEL="$HOME/cancel-bench"
before_default="$(sed -n 's/^BENCH_DIR=//p' "$FL_STATE_FILE")"
reset_calls
MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw run_fm install --bench-dir "$CANCEL" --site cancelsite </dev/null
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "Cancelled. No bench or site was created; the system dependencies of step 1 stay in place."
assert_not_contains "$OUT" "Nothing was changed"
assert_not_contains "$OUT" "Bench and site (01-install-bench-and-site.sh): done"
assert_no_file "$CANCEL"
assert_no_file "$HOME/Library/LaunchAgents/com.benchbar.cancel-bench.plist"
assert_eq "$before_default" "$(sed -n 's/^BENCH_DIR=//p' "$FL_STATE_FILE")" "(a cancelled install must not change the default bench)"
[[ -z "$(ls "$FL_STATE_DIR"/benches/cancel-bench-* 2>/dev/null)" ]] || fail "a cancelled install must leave no per bench state"
assert_calls_not_contain '^(bench init|launchctl bootstrap)'
assert_calls_not_contain 'cancelsite'

# ---- OFFLINE=1 reaches both phases: no remote call in a dry run
reset_calls
OFFLINE=1 run_fm install --dry-run --bench-dir "$HOME/offline-bench" --site offsite
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain '^(curl|git ls-remote)' "(OFFLINE=1 must stop every remote check)"
assert_contains "$OUT" "Offline mode"
reset_calls
run_fm install --dry-run --offline --bench-dir "$HOME/offline-bench" --site offsite
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain '^(curl|git ls-remote)' "(--offline must stop every remote check)"
reset_calls
run_fm install --dry-run --bench-dir "$HOME/offline-bench" --site offsite
assert_calls_contain '^git ls-remote' "(without offline the branch checks run)"

# ---- 00 on a fresh Homebrew MariaDB: root logs in over the socket only,
# the macOS user's socket account secures it; no exit 2, no password asked
rm -f "$MOCK_STATE/mariadb_root_pw" "$MOCK_STATE/keychain/benchbar-mariadb--root"; : >"$MOCK_STATE/mariadb_sql.log"
reset_calls
MOCK_MARIADB_ROOT_SOCKET_ONLY=1 run00 --yes --profile v15-lts
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "root@localhost uses socket login only (fresh Homebrew install); setting a password (generated) through the tester socket account"
assert_not_contains "$OUT" "MariaDB root already has a password"
assert_calls_contain "^mariadb -u tester --protocol=socket\$" "(the SQL goes through the user's socket account, over the socket)"
assert_calls_not_contain '^mariadb -u root -p' "(no password on a command line)"
assert_calls_not_contain '^sudo mariadb'
PW="$(keychain_get)"
[[ "${#PW}" -ge 20 ]] || fail "a generated password is expected in the Keychain, got [$PW]"
assert_eq "$PW" "$(mariadb_pw)" "(root now has the Keychain password)"
assert_contains "$(cat "$MOCK_STATE/mariadb_sql.log")" "IDENTIFIED VIA unix_socket OR mysql_native_password" "(root keeps its socket login next to the new password)"
# the rerun verifies root with that password, as on any set up machine
reset_calls; : >"$MOCK_STATE/mariadb_sql.log"
MOCK_MARIADB_ROOT_SOCKET_ONLY=1 run00 --yes --profile v15-lts
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "[OK] MariaDB root password verified (Keychain, unchanged)"
[[ ! -s "$MOCK_STATE/mariadb_sql.log" ]] || fail "no SQL on a rerun"
# a server that accepts neither login still stops with exit 2 and asks
rm -f "$MOCK_STATE/mariadb_root_pw" "$MOCK_STATE/keychain/benchbar-mariadb--root"
printf 'someoneelses' >"$MOCK_STATE/mariadb_root_pw"
MOCK_MARIADB_ROOT_SOCKET_ONLY=1 run00 --yes --profile v15-lts
assert_eq "2" "$CODE" "$OUT"
assert_contains "$OUT" "MariaDB root already has a password and no source knows it"
# a socket account that may not read mysql.user proves nothing: root is not
# touched, and a working Keychain password is neither overwritten nor skipped
printf 'someoneelses\n' >"$MOCK_STATE/keychain/benchbar-mariadb--root"; : >"$MOCK_STATE/mariadb_sql.log"
MOCK_MARIADB_ROOT_SOCKET_ONLY=1 MOCK_MARIADB_USER_NO_GRANTS=1 MARIADB_ROOT_PASSWORD=wrongenv run00 --yes --profile v15-lts
assert_eq "0" "$CODE" "$OUT"
assert_not_contains "$OUT" "uses socket login only"
assert_contains "$OUT" "MARIADB_ROOT_PASSWORD from the environment does not work"
assert_contains "$OUT" "[OK] MariaDB root password verified (Keychain, unchanged)"
assert_eq "someoneelses" "$(keychain_get)" "(the working Keychain password stays)"
assert_eq "someoneelses" "$(mariadb_pw)" "(root's password is not touched)"
[[ ! -s "$MOCK_STATE/mariadb_sql.log" ]] || fail "no SQL may run through an account that cannot prove root is open"
# a stopped server: the password is not blamed
: >"$MOCK_LISTEN"; grep -v '^900 ' "$MOCK_PROCS" >"$MOCK_PROCS.tmp" || true; mv "$MOCK_PROCS.tmp" "$MOCK_PROCS"
rm -rf "$BENCH"
MARIADB_ROOT_PASSWORD=someoneelses ADMIN_PASSWORD=adminpw run01 --yes --offline
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "mariadbd is not running"
printf '3306 111 mariadbd 127.0.0.1\n' >"$MOCK_LISTEN"; add_proc 900 "mariadbd --datadir=/x"
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"; printf 'rootpw\n' >"$MOCK_STATE/keychain/benchbar-mariadb--root"

# ---- a second bench while another program holds the default ports: install
# picks the next free block and writes it before phase 01 starts the Redis
SECOND="$HOME/second-bench"; rm -rf "$SECOND"
add_listener 11000 5110 redis-server; mkdir -p "$MOCK_STATE/cwd"; printf '%s' "$HOME/other-bench" >"$MOCK_STATE/cwd/5110"
reset_calls
MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw run_fm install --yes --bench-dir "$SECOND" --site second
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "the default ports are taken; the new bench gets port block"
assert_not_contains "$OUT" "is held by another process"
assert_calls_contain '^bench setup redis$'
grep -q '"webserver_port": *8000' "$SECOND/sites/common_site_config.json" && fail "the new bench must not keep the taken default block"
rm -f "$MOCK_STATE/cwd/5110"; printf '3306 111 mariadbd 127.0.0.1\n' >"$MOCK_LISTEN"

printf 'test-phases: ok\n'
