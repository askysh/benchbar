#!/usr/bin/env bash
# Every doctor detection, plus JSON output and exit codes.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/frappe-bench"
make_fake_bench "$BENCH"
mkdir -p "$HOME/Library/LaunchAgents"
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
printf '127.0.0.1 macdev\n' >>"$FL_HOSTS_FILE"

# healthy bench: doctor passes (bench stopped on purpose)
run_fm doctor --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "[OK] Bench env: env/bin/python runs (Python 3.11)"
assert_contains "$OUT" "[OK] socket.io module"
assert_contains "$OUT" "[OK] Built assets: all 2 dist files"
assert_contains "$OUT" "[OK] Stop flag: stopped on purpose"
assert_contains "$OUT" "[OK] Site ping: bench is stopped"
assert_contains "$OUT" "[OK] /etc/hosts entry"
assert_not_contains "$OUT" "[FAIL]"

# doctor is read-only
reset_calls
snap_before="$(snapshot "$HOME" "$BENCH")"
run_fm doctor --bench-dir "$BENCH"
assert_eq "$snap_before" "$(snapshot "$HOME" "$BENCH")" "(doctor must not write)"
assert_calls_not_contain '^(launchctl (bootstrap|bootout|kickstart|kill)|pkill|bench (build|setup)|brew services)'

# 1. env deleted (the cleanup-tool case)
mv "$BENCH/env" "$BENCH/env.gone"
run_fm doctor --bench-dir "$BENCH"
assert_eq "1" "$CODE"
assert_contains "$OUT" "[FAIL] Bench env: env/bin/python is missing"
assert_contains "$OUT" "[FAIL] bench command: skipped: env is missing"
mv "$BENCH/env.gone" "$BENCH/env"

# 2. env/bin/python present but broken (dangling symlink after a Python upgrade)
mv "$BENCH/env/bin/python" "$BENCH/env/bin/python.real"
ln -s /nonexistent/python3.11 "$BENCH/env/bin/python"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[FAIL] Bench env: env/bin/python does not run"
rm "$BENCH/env/bin/python"; mv "$BENCH/env/bin/python.real" "$BENCH/env/bin/python"

# 3. wrong Python version in env
cat >"$BENCH/env/bin/python" <<'PY'
#!/bin/bash
case "$*" in *version_info*) echo "3.12" ;; --version) echo "Python 3.12.1" ;; *) exit 0 ;; esac
PY
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "env uses Python 3.12, profile v15-lts expects 3.11"
make_fake_env_python "$BENCH"

# 4. node_modules deleted
mv "$BENCH/apps/frappe/node_modules" "$BENCH/apps/frappe/nm.gone"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[FAIL] socket.io module: apps/frappe/node_modules/socket.io is missing"
assert_contains "$OUT" "bench setup requirements --node"
mv "$BENCH/apps/frappe/nm.gone" "$BENCH/apps/frappe/node_modules"

# 5. assets.json present but the dist files it references are gone
rm -rf "$BENCH/apps/frappe/frappe/public/dist"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[FAIL] Built assets: 2 of 2 dist files referenced by assets.json are missing"
assert_contains "$OUT" "bench build"
mkdir -p "$BENCH/apps/frappe/frappe/public/dist/js" "$BENCH/apps/frappe/frappe/public/dist/css"
printf 'x\n' >"$BENCH/apps/frappe/frappe/public/dist/js/desk.bundle.ABC123.js"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "1 of 2 dist files"
printf 'x\n' >"$BENCH/apps/frappe/frappe/public/dist/css/desk.bundle.DEF456.css"

# 6. assets.json missing entirely
mv "$BENCH/sites/assets/assets.json" "$BENCH/sites/assets/assets.json.gone"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "assets.json is missing (never built)"
mv "$BENCH/sites/assets/assets.json.gone" "$BENCH/sites/assets/assets.json"

# 7. a crash-looping legacy agent shows its exit code
printf '<?xml version="1.0"?><plist version="1.0"><dict><key>Label</key><string>com.akash.frappe-bench.worker</string></dict></plist>\n' >"$HOME/Library/LaunchAgents/com.akash.frappe-bench.worker.plist"
set_agent com.akash.frappe-bench.worker "not running" "" 1
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] Legacy agents: 1 legacy agent(s): com.akash.frappe-bench.worker (not running, last exit 1)"
rm "$HOME/Library/LaunchAgents/com.akash.frappe-bench.worker.plist"; rm "$MOCK_STATE/agents/com.akash.frappe-bench.worker"

# 8. crash-paused bench
printf 'crash\n' >"$BENCH/logs/.bench-stopped"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] Stop flag: auto-restart paused after repeated crashes"
assert_contains "$OUT" "[WARN] Site ping: bench is paused (crash)"
printf 'manual\n' >"$BENCH/logs/.bench-stopped"

# 9. our agent loaded but its last run failed
set_agent com.benchbar.frappe-bench "not running" "" 78
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] launchd agent: agent loaded, not running, last exit code 78"
set_agent com.benchbar.frappe-bench "not running" "" 0

# 10. running but the site does not answer
add_proc 4242 "honcho start -f Procfile.lean"
run_fm doctor --bench-dir "$BENCH"
assert_eq "1" "$CODE"
assert_contains "$OUT" "[FAIL] Site ping: bench processes are running but ping returned 000"
MOCK_CURL_CODE=200 run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[OK] Site ping: http://macdev:8000/api/method/ping returned 200"
: >"$MOCK_PROCS"

# 11. MariaDB exposed on the network, redis on 6379, missing hosts entry
add_listener 3306 900 mariadbd '*'
add_listener 6379 901 redis-server
printf '127.0.0.1 localhost\n' >"$FL_HOSTS_FILE"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] MariaDB bind address: MariaDB listens on *:3306"
assert_contains "$OUT" "[WARN] Homebrew redis: redis on 6379 (901 redis-server) is not used by the bench"
assert_contains "$OUT" "[WARN] /etc/hosts entry"
assert_contains "$OUT" "sudo tee -a"
: >"$MOCK_LISTEN"
add_listener 3306 900 mariadbd 127.0.0.1
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[OK] MariaDB bind address: MariaDB listens on 127.0.0.1 only"
printf '127.0.0.1 macdev\n' >>"$FL_HOSTS_FILE"

# 12. python formula not a leaf
printf 'node@20\n' >"$MOCK_BREW_LEAVES"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] Python formula: python@3.11 is only a dependency"
assert_contains "$OUT" "brew tab --installed-on-request python@3.11"
printf 'python@3.11\nnode@20\n' >"$MOCK_BREW_LEAVES"

# 13. missing formula
cp "$MOCK_STATE/installed" "$MOCK_STATE/installed.bak"
printf 'python@3.11\nnode@20\n' >"$MOCK_STATE/installed"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[FAIL] Homebrew formulae: missing formulae: mariadb@10.11 redis"
mv "$MOCK_STATE/installed.bak" "$MOCK_STATE/installed"

# 14. large logs
dd if=/dev/zero of="$BENCH/logs/worker.error.log" bs=1048576 count=3 2>/dev/null
FL_LOG_WARN_MB=2 run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] Log sizes: large logs: worker.error.log (3 MB)"
rm "$BENCH/logs/worker.error.log"

# 15. CleanMyMac installed
mkdir -p "$HOME/Applications/CleanMyMac X.app"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] CleanMyMac: CleanMyMac X.app is installed"
assert_contains "$OUT" "Ignore List"
rm -rf "$HOME/Applications/CleanMyMac X.app"
# the Setapp copy lives one folder down
mkdir -p "$HOME/Applications/Setapp/CleanMyMac.app"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] CleanMyMac: CleanMyMac.app is installed"
rm -rf "$HOME/Applications/Setapp"

# 15b. Mole installed: warns until the bench (or a folder above it) is in its whitelist
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[OK] Mole: Mole not installed"
mkdir -p "$TMP_DIR/mole-bin"
printf '#!/bin/sh\nexit 0\n' >"$TMP_DIR/mole-bin/mole"
chmod +x "$TMP_DIR/mole-bin/mole"
FL_MOLE_CMDS="$TMP_DIR/mole-bin/mole" run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] Mole: Mole is installed"
assert_contains "$OUT" "run 'mo clean --whitelist' and save once"
assert_contains "$OUT" "echo '${BENCH}' >> ~/.config/mole/whitelist"
mkdir -p "$HOME/.config/mole"
: >"$HOME/.config/mole/whitelist"
FL_MOLE_CMDS="$TMP_DIR/mole-bin/mole" run_fm doctor --bench-dir "$BENCH"
assert_not_contains "$OUT" "mo clean --whitelist" "(the file exists, so Mole's defaults are kept)"
printf '# protected\n%s/*\n' "$(dirname "$BENCH")" >"$HOME/.config/mole/whitelist"
FL_MOLE_CMDS="$TMP_DIR/mole-bin/mole" run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] Mole: Mole is installed" "(a glob line does not count)"
printf '  %s/  \n' "$(dirname "$BENCH")" >"$HOME/.config/mole/whitelist"
FL_MOLE_CMDS="$TMP_DIR/mole-bin/mole" run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[OK] Mole: Mole is installed; ${BENCH} is in ~/.config/mole/whitelist"
printf '%s-other\n' "$BENCH" >"$HOME/.config/mole/whitelist"
FL_MOLE_CMDS="$TMP_DIR/mole-bin/mole" run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] Mole: Mole is installed" "(a sibling with the same prefix does not count)"
rm -rf "$HOME/.config/mole"
# only mo on PATH: counted when it is Mole, not when it is another tool named mo
printf '#!/bin/bash\n# Mole - Main CLI entrypoint.\n' >"$TMP_DIR/mole-bin/mo"
chmod +x "$TMP_DIR/mole-bin/mo"
PATH="$TMP_DIR/mole-bin:$PATH" FL_MOLE_CMDS="benchbar-test-no-mole mo" run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] Mole: Mole is installed ($TMP_DIR/mole-bin/mo)"
printf '#!/bin/bash\n# mustache templates in bash\n' >"$TMP_DIR/mole-bin/mo"
PATH="$TMP_DIR/mole-bin:$PATH" FL_MOLE_CMDS="benchbar-test-no-mole mo" run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[OK] Mole: Mole not installed"

# 16. legacy helper block in zshrc
printf '# >>> frappe-bench helpers >>>\nbenchup() { :; }\n# <<< frappe-bench helpers <\n' >>"$HOME/.zshrc"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "old block(s) still present: frappe-bench helpers"

# 17. port clash with another running frappe-mac bench
OTHER="$HOME/dev/other"
make_fake_bench "$OTHER" other
run_fm service --yes --bench-dir "$OTHER"
set_agent com.benchbar.other running 777 0
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] Port clash: another running bench uses the same port: com.benchbar.other:8000"

# JSON output is machine readable
run_fm doctor --json --bench-dir "$BENCH"
printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["summary"]["ok"]>0; assert any(c["id"]=="assets" for c in d["checks"]); print("json ok")' || fail "doctor --json must be valid JSON"
run_fm status --json --bench-dir "$BENCH"
printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["stop_flag"]=="manual"' || fail "status --json must be valid JSON"

printf 'test-doctor: ok\n'

# ---- utf8mb4: a current drop-in is not enough when my.cnf stopped including my.cnf.d
printf '[client-server]\n' >"$MOCK_BREW_PREFIX/etc/my.cnf"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] MariaDB utf8mb4:"
assert_contains "$OUT" "no '!includedir'"
run_fm repair --yes --bench-dir "$BENCH"
grep -q "^!includedir $MOCK_BREW_PREFIX/etc/my.cnf.d" "$MOCK_BREW_PREFIX/etc/my.cnf" || fail "repair must restore the includedir line"
run_fm doctor --bench-dir "$BENCH"
assert_not_contains "$OUT" "[WARN] MariaDB utf8mb4:"

# a missing my.cnf counts as a missing include line, and repair recreates it
rm -f "$MOCK_BREW_PREFIX/etc/my.cnf"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] MariaDB utf8mb4:"
assert_contains "$OUT" "is missing or has no '!includedir'"
run_fm repair --yes --bench-dir "$BENCH"
grep -q "^!includedir $MOCK_BREW_PREFIX/etc/my.cnf.d" "$MOCK_BREW_PREFIX/etc/my.cnf" || fail "repair must recreate my.cnf with the includedir line"

# ---- doctor is read only: it never reads the Keychain, whatever the server runs
reset_calls
run_fm doctor --bench-dir "$BENCH"
assert_calls_not_contain '^security' "(doctor must never touch the Keychain)"

printf 'test-doctor utf8: ok\n'
