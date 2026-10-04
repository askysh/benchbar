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

# runner heartbeat (0.6.1): a runner process older than its script
hb_check() {
  { "$FM" doctor --json --bench-dir "$BENCH" 2>/dev/null || true; } |
    jget - '" | ".join("%s | %s" % (c["level"], c["fix_command"] or "-") for c in d["checks"] if c["id"] == "runner_heartbeat")'
}
hb="$BENCH/logs/.benchbar/heartbeat"
assert_eq "ok | -" "$(hb_check)" "(a stopped bench has nothing to beat)"
mkdir -p "$BENCH/logs/.benchbar"
printf '{"state":"running","pid":4241}\n' >"$BENCH/logs/.benchbar/state.json"
add_proc 4241 "/bin/bash $BENCH/benchbar-run.sh" "$BENCH"
assert_eq "warn | ${ROOT}/benchbar restart --bench-dir ${BENCH}" "$(hb_check)" "(a running runner without a heartbeat predates its script)"
touch "$hb"
assert_eq "ok | -" "$(hb_check)"
FL_NOW="$(( $(mtime_of "$hb") + 200 ))" run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] Runner heartbeat: the runner's last heartbeat is 200s old (pid 4241)"
# dated in the future: a clock moved back, and a beating runner rewrites it
FL_NOW="$(( $(mtime_of "$hb") - 2 ))" run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[OK] Runner heartbeat"
FL_NOW="$(( $(mtime_of "$hb") - 600 ))" run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] Runner heartbeat: the runner's last heartbeat is dated 600s in the future (pid 4241)"
# an outdated runner script is the runner check's to report, not this one's
cp "$BENCH/benchbar-run.sh" "$TMP_DIR/runner.saved"
sed_inplace 's/benchbar-template: bench-run.sh v[0-9]* [0-9a-f]*/benchbar-template: bench-run.sh v0 000000000000/' "$BENCH/benchbar-run.sh"
rm -f "$hb"
assert_eq "ok | -" "$(hb_check)"
cp "$TMP_DIR/runner.saved" "$BENCH/benchbar-run.sh"
rm -f "$BENCH/logs/.benchbar/state.json"
{ grep -v '^4241 ' "$MOCK_PROCS" || true; } >"$MOCK_PROCS.tmp"; mv "$MOCK_PROCS.tmp" "$MOCK_PROCS"

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

# 10. running but the site does not answer (honcho's working folder is the bench, as lsof reports it)
add_proc 4242 "honcho start -f Procfile.lean" "$BENCH"
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
printf 'node@22\n' >"$MOCK_BREW_LEAVES"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] Python formula: python@3.11 is only a dependency"
assert_contains "$OUT" "brew tab --installed-on-request python@3.11"
printf 'python@3.11\nnode@22\n' >"$MOCK_BREW_LEAVES"

# 13. missing formula
cp "$MOCK_STATE/installed" "$MOCK_STATE/installed.bak"
printf 'python@3.11\nnode@22\n' >"$MOCK_STATE/installed"
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

# ---- a bench no profile matches (frappe 17.0.0-dev, nothing stored): the
# default is named as such, the env checks warn without an action, and
# nothing offers to rebuild the env with a guessed Python
DEV="$HOME/work/develop-bench"; make_fake_bench "$DEV" devsite
mkdir -p "$DEV/apps/frappe/frappe"; printf '__version__ = "17.0.0-dev"\n' >"$DEV/apps/frappe/frappe/__init__.py"
run_fm doctor --bench-dir "$DEV"
assert_contains "$OUT" "profile  v15-lts (default: no profile matches this bench)"
# a fresh install has no bench to match: the default carries no note
run_fm install --dry-run --yes --bench-dir "$HOME/work/fresh-bench"
assert_contains "$OUT" "profile  v15-lts"
assert_not_contains "$OUT" "no profile matches"
# a stored profile is named without the note
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "profile  v15-lts "
assert_not_contains "$OUT" "(default:"
cat >"$DEV/env/bin/python" <<'PY'
#!/bin/bash
case "$*" in *version_info*) echo "3.13" ;; --version) echo "Python 3.13.1" ;; *) exit 0 ;; esac
PY
run_fm doctor --json --bench-dir "$DEV"
assert_eq "warn None" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in [[c for c in d["checks"] if c["id"] == "env_python"][0]["level"], [c for c in d["checks"] if c["id"] == "env_python"][0]["action"]])')"
assert_contains "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"] == "env_python"][0]["message"]')" "no profile matches this bench's Frappe (v15-lts is only the default), so the env is left as it is"
assert_contains "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"] == "env_python"][0]["fix_command"]')" "benchbar install --profile NAME"
# env gone: still no rebuild offered, the fix names the way to set a profile
mv "$DEV/env" "$DEV/env.gone"
run_fm doctor --json --bench-dir "$DEV"
assert_eq "fail None" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in [[c for c in d["checks"] if c["id"] == "env_python"][0]["level"], [c for c in d["checks"] if c["id"] == "env_python"][0]["action"]])')"
assert_eq "None" "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"] == "bench_version"][0]["action"]')"
mv "$DEV/env.gone" "$DEV/env"
printf 'keep\n' >"$DEV/env/marker"
run_fm repair --yes --bench-dir "$DEV"
assert_not_contains "$OUT" "rebuild the bench env"
assert_file "$DEV/env/marker" "(the env of a bench no profile matches is never moved aside)"
[[ -z "$(ls -d "$DEV"/env.broken.* 2>/dev/null)" ]] || fail "repair must not move the env of a bench no profile matches"
# the setuptools check and action stay out of a bench no profile matches too
MOCK_ENV_NO_PKG_RESOURCES=1 run_fm doctor --json --bench-dir "$DEV"
assert_eq "ok None" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in [[c for c in d["checks"] if c["id"] == "env_setuptools"][0]["level"], [c for c in d["checks"] if c["id"] == "env_setuptools"][0]["action"]])')"
reset_calls
MOCK_ENV_NO_PKG_RESOURCES=1 run_fm repair --yes --bench-dir "$DEV"
assert_calls_not_contain 'setuptools<70' "(no pip into an env whose Frappe is unknown)"
# a bench whose apps/frappe is gone (a cleanup tool) with nothing stored is a guess too
GONE="$HOME/work/gone-bench"; make_fake_bench "$GONE" gonesite
rm -rf "$GONE/apps/frappe" "$GONE/env"
run_fm doctor --json --bench-dir "$GONE"
assert_eq "None" "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"] == "env_python"][0]["action"]')"
# the action itself refuses, whatever planned it
set +e
OUT="$(FL_BENCH_DIR="$DEV" FL_PROFILE=v15-lts FL_PROFILE_SOURCE=default FL_PYTHON_BIN_NAME=python3.11 FL_PYTHON_FORMULA=python@3.11 FL_BREW_PREFIX="$MOCK_BREW_PREFIX" FL_SELF=benchbar bash -c '
  for f in ui run platform version-policy state templates benchinfo process launchd checks repair; do . "$0/lib/frappe-local/$f.sh"; done
  act_env_rebuild' "$ROOT" 2>&1)"; CODE=$?
set -e
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "refusing to rebuild env: no profile matches this bench's Frappe"
assert_file "$DEV/env/marker"
assert_calls_not_contain '^bench setup env'
make_fake_env_python "$DEV"

# ---- bench version failures are classified: the CLI's own problems and an
# app that does not import never move the env aside
run_fm doctor --json --bench-dir "$BENCH"
assert_eq "ok" "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"] == "bench_version"][0]["level"]')"
# no bench command at all
NOBENCH="$TMP_DIR/nobench"; mkdir -p "$NOBENCH"
for t in "$ROOT"/tests/mocks/bin/*; do [[ "$(basename "$t")" == "bench" ]] || ln -s "$t" "$NOBENCH/$(basename "$t")"; done
PATH="$NOBENCH:/usr/bin:/bin" run_fm doctor --json --bench-dir "$BENCH"
r="$(printf '%s' "$OUT" | jget - '"|".join(str([c for c in d["checks"] if c["id"] == "bench_version"][0][k]) for k in ("level", "message", "fix_command", "action"))')"
assert_contains "$r" "fail|the bench command is not on the bench's PATH (frappe-bench is not installed)|uv tool install frappe-bench|None"
# without uv on the Mac the fix names pipx, which is there (the system
# folders only: the machine running the tests may have a real uv)
rm "$NOBENCH/uv"
PATH="$NOBENCH:/usr/bin:/bin" run_fm doctor --json --bench-dir "$BENCH"
r="$(printf '%s' "$OUT" | jget - '"|".join(str([c for c in d["checks"] if c["id"] == "bench_version"][0][k]) for k in ("level", "message", "fix_command", "action"))')"
assert_contains "$r" "fail|the bench command is not on the bench's PATH (frappe-bench is not installed)|pipx install frappe-bench|None"
# a bench whose own venv is broken (bad interpreter, exit 127)
MOCK_BENCH_VERSION_EXIT=127 MOCK_BENCH_VERSION_OUT="bash: /Users/me/.local/bin/bench: /Users/me/.local/share/uv/tools/frappe-bench/bin/python: bad interpreter: No such file or directory" run_fm doctor --json --bench-dir "$BENCH"
r="$(printf '%s' "$OUT" | jget - '"|".join(str([c for c in d["checks"] if c["id"] == "bench_version"][0][k]) for k in ("level", "fix_command", "action"))')"
assert_contains "$r" "fail|the bench at $ROOT/tests/mocks/bin/bench was not installed by uv or pipx: reinstall it with the tool that did, or remove it and run: uv tool install frappe-bench|None"
assert_contains "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"] == "bench_version"][0]["message"]')" "its own venv is broken, not the bench env"
# an app that does not import is named; frappe itself failing keeps the rebuild
MOCK_BENCH_VERSION_EXIT=1 MOCK_BENCH_VERSION_OUT="ModuleNotFoundError: No module named 'erpnext'" run_fm doctor --json --bench-dir "$BENCH"
r="$(printf '%s' "$OUT" | jget - '"|".join(str([c for c in d["checks"] if c["id"] == "bench_version"][0][k]) for k in ("level", "message", "fix_command", "action"))')"
assert_contains "$r" "fail|bench version fails: the app erpnext does not import"
assert_contains "$r" "bench setup requirements --python"
assert_contains "$r" "|None"
MOCK_BENCH_VERSION_EXIT=1 MOCK_BENCH_VERSION_OUT="ModuleNotFoundError: No module named 'frappe'" run_fm doctor --json --bench-dir "$BENCH"
assert_eq "env_rebuild" "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"] == "bench_version"][0]["action"]')"
# with a classified failure, repair leaves the env alone
printf 'keep\n' >"$BENCH/env/marker"
MOCK_BENCH_VERSION_EXIT=127 MOCK_BENCH_VERSION_OUT="bad interpreter" run_fm repair --yes --bench-dir "$BENCH"
assert_file "$BENCH/env/marker"
assert_not_contains "$OUT" "rebuild the bench env"
rm -f "$BENCH/env/marker"

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

# ---- --fix-hints: exactly the fixes of fail, then warn checks, each once; nothing else on stdout
set +e
json="$("$FM" doctor --json --bench-dir "$BENCH" 2>/dev/null)"; json_code=$?
hints="$("$FM" doctor --fix-hints --bench-dir "$BENCH" 2>/dev/null)"; hints_code=$?
set -e
assert_eq "$json_code" "$hints_code" "(the exit code is doctor's)"
expected="$(printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin); seen = []
for level in ("fail", "warn"):
    for c in d["checks"]:
        if c["level"] == level and c["fix_command"] and c["fix_command"] not in seen:
            seen.append(c["fix_command"])
print("\n".join(seen))')"
[[ -n "$expected" ]] || fail "test setup: this bench should have at least one fix"
assert_eq "$expected" "$hints"
assert_not_contains "$hints" "[WARN]"
set +e; missing="$("$FM" doctor --fix-hints --bench-dir "$HOME/nowhere" 2>/dev/null)"; missing_code=$?; set -e
assert_eq "1" "$missing_code"; assert_eq "" "$missing" "(errors go to stderr)"

printf 'test-doctor utf8: ok\n'
