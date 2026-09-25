#!/usr/bin/env bash
# The 0.4 doctor checks from the community threads: Full Disk Access,
# the toolchain as the bench sees it, honcho without pkg_resources, the
# fork safety variables, and stale processes on the bench's ports. Each has
# a passing and a failing case.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/frappe-bench"
make_fake_bench "$BENCH"
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
printf '127.0.0.1 macdev\n' >>"$FL_HOSTS_FILE"

check() {
  # check ID: prints "level|message|fix|action" of one check from doctor --json
  { "$FM" doctor --json --bench-dir "$BENCH" 2>/dev/null || true; } | jget - "'|'.join(str(c[k] or '') for c in d['checks'] if c['id']=='$1' for k in ('level','message','fix_command','action'))"
}

# ---- healthy: every new check passes
run_fm doctor --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
for label in "Full Disk Access: crontab is readable" "Node: Node 20.18.0 at ${MOCK_BREW_PREFIX}/opt/node@20/bin/node" "yarn: yarn" \
  "MariaDB server: MariaDB" "pkg-config: pkg-config 2.5.1 finds mariadb-connector-c" "Fork safety env: the agent passes" "Stale processes: no stale process"; do
  assert_contains "$OUT" "[OK] ${label}"
done

# ---- full_disk_access: crontab denied
touch "$MOCK_STATE/crontab_denied"
r="$(check full_disk_access)"
assert_contains "$r" "warn|crontab is not readable (Operation not permitted)"
assert_contains "$r" "Full Disk Access: add Terminal"
# from the app it is not checked: the app's own access does not matter
r="$(__CFBundleIdentifier=com.akashmishra.benchbar check full_disk_access)"
assert_contains "$r" "ok|not checked from BenchBar"
rm "$MOCK_STATE/crontab_denied"

# ---- toolchain_node: env/bin/node wins; wrong major; nvm only
printf '#!/bin/sh\necho v18.20.1\n' >"$BENCH/env/bin/node"; chmod +x "$BENCH/env/bin/node"
r="$(check toolchain_node)"
assert_contains "$r" "warn|Node 18.20.1 at env/bin/node, profile v15-lts expects 20"
assert_contains "$r" "brew install node@20"
rm "$BENCH/env/bin/node"
mv "$MOCK_BREW_PREFIX/opt/node@20/bin/node" "$TMP_DIR/node.aside"; mkdir -p "$HOME/.nvm"
r="$(check toolchain_node)"
if [[ ! -x /usr/local/bin/node && ! -x /usr/bin/node ]]; then
  assert_contains "$r" "warn|no node on the bench's PATH (nvm's node"
fi
mv "$TMP_DIR/node.aside" "$MOCK_BREW_PREFIX/opt/node@20/bin/node"; rmdir "$HOME/.nvm"

# ---- toolchain_yarn: missing
mv "$MOCK_BREW_PREFIX/opt/node@20/bin/yarn" "$TMP_DIR/yarn.aside"
r="$(check toolchain_yarn)"
if [[ ! -x /usr/local/bin/yarn && ! -x /usr/bin/yarn ]]; then
  assert_contains "$r" "warn|no yarn on the bench's PATH"
  assert_contains "$r" "install -g yarn"
fi
mv "$TMP_DIR/yarn.aside" "$MOCK_BREW_PREFIX/opt/node@20/bin/yarn"

# ---- mariadb_version: not running, too old, too new; never reads the Keychain
reset_calls
: >"$MOCK_LISTEN"
r="$(check mariadb_version)"
assert_contains "$r" "warn|nothing listens on 3306"
assert_contains "$r" "brew services start mariadb@10.11"
assert_calls_not_contain '^security '
printf '3306 111 mariadbd 127.0.0.1\n' >"$MOCK_LISTEN"
assert_contains "$(check mariadb_version)" "ok|MariaDB 10.11"
cp "$MOCK_BREW_PREFIX/opt/mariadb@10.11/bin/mariadb" "$TMP_DIR/mariadb.real"
printf '#!/bin/sh\necho "mariadb  Ver 15.1 Distrib 10.5.9-MariaDB, for osx10.20 (arm64)"\n' >"$MOCK_BREW_PREFIX/opt/mariadb@10.11/bin/mariadb"
assert_contains "$(check mariadb_version)" "warn|MariaDB 10.5.9 is older than 10.6, the oldest profile v15-lts supports"
printf '#!/bin/sh\necho "mariadb from 12.0.2-MariaDB, client 15.2 for osx10.20 (arm64)"\n' >"$MOCK_BREW_PREFIX/opt/mariadb@10.11/bin/mariadb"
assert_contains "$(check mariadb_version)" "warn|MariaDB 12.0.2 is newer than 10.11, the newest profile v15-lts is tested with"
cp "$TMP_DIR/mariadb.real" "$MOCK_BREW_PREFIX/opt/mariadb@10.11/bin/mariadb"

# ---- toolchain_pkgconfig: connector missing, pkg-config missing
grep -v -x mariadb-connector-c "$MOCK_STATE/installed" >"$MOCK_STATE/i.tmp"; mv "$MOCK_STATE/i.tmp" "$MOCK_STATE/installed"
assert_contains "$(check toolchain_pkgconfig)" "warn|pkg-config 2.5.1 does not find mariadb-connector-c"
printf 'mariadb-connector-c\n' >>"$MOCK_STATE/installed"
mv "$MOCK_BREW_PREFIX/bin/pkg-config" "$TMP_DIR/pc.aside"
if [[ ! -x /usr/local/bin/pkg-config && ! -x /usr/bin/pkg-config ]]; then
  assert_contains "$(check toolchain_pkgconfig)" "warn|no pkg-config on the bench's PATH"
fi
mv "$TMP_DIR/pc.aside" "$MOCK_BREW_PREFIX/bin/pkg-config"

# ---- honcho_setuptools: a honcho 1.x whose Python has no setuptools
VENV="$MOCK_PIPX_HOME/venvs/frappe-bench/bin"
cat >"$VENV/python" <<'PY'
#!/usr/bin/env bash
# a venv Python: honcho.command and pkg_resources import unless $MOCK_STATE/no_setuptools
case "$*" in
  *"import honcho.command"*|*"import pkg_resources"*) [[ -f "$MOCK_STATE/no_setuptools" ]] && exit 1; exit 0 ;;
  *"-m pip install setuptools"*) rm -f "$MOCK_STATE/no_setuptools"; exit 0 ;;
  *) exit 0 ;;
esac
PY
chmod +x "$VENV/python"
{ printf '#!%s\n' "$VENV/python"; tail -n +2 "$ROOT/tests/mocks/honcho"; } >"$VENV/honcho"
assert_contains "$(check honcho_setuptools)" "ok|honcho imports cleanly with ${VENV}/python"
touch "$MOCK_STATE/no_setuptools"
r="$(check honcho_setuptools)"
assert_contains "$r" "warn|honcho needs pkg_resources"
assert_contains "$r" "|honcho_setuptools"
# repair: dry run changes nothing, then setuptools goes into that venv only (uv present)
reset_calls
run_fm repair --dry-run --bench-dir "$BENCH"
assert_contains "$OUT" "install setuptools into honcho's venv"
assert_calls_not_contain '^uv pip install'
reset_calls
run_fm repair --yes --bench-dir "$BENCH"
assert_calls_contain "^uv pip install --python ${VENV}/python setuptools$"
assert_calls_not_contain "^uv pip install --python ${BENCH}"
# adopt never installs it
touch "$MOCK_STATE/no_setuptools"; reset_calls
run_fm adopt "$BENCH" --yes
assert_calls_not_contain '^uv pip install'
rm -f "$MOCK_STATE/no_setuptools"
cp "$ROOT/tests/mocks/honcho" "$VENV/honcho"

# ---- fork_safety: a plist without the variables
PLIST="$HOME/Library/LaunchAgents/com.benchbar.frappe-bench.plist"
cp "$PLIST" "$TMP_DIR/plist.good"
grep -v -e 'OBJC_DISABLE_INITIALIZE_FORK_SAFETY' -e 'NO_PROXY' "$TMP_DIR/plist.good" >"$PLIST"
r="$(check fork_safety)"
assert_contains "$r" "warn|the agent does not pass OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES NO_PROXY=*"
assert_contains "$r" "|write_plist"
cp "$TMP_DIR/plist.good" "$PLIST"

# ---- orphans: redis and gunicorn left on the bench's ports, no honcho, agent not running
add_listener 13000 4101 redis-server
add_listener 8000 4102 python3.11
r="$(check orphans)"
assert_contains "$r" "warn|stale processes hold this bench's ports: 8000 (pid 4102 python3.11), 13000 (pid 4101 redis-server)"
assert_contains "$r" "benchbar down"
# the same listeners under benchfg are the bench, not orphans
add_proc 4100 "/x/honcho start -f Procfile.lean"
assert_contains "$(check orphans)" "ok|honcho is running"
# and under the agent
set_agent com.benchbar.frappe-bench running 4099 0
assert_contains "$(check orphans)" "ok|the agent runs this bench"

# ---- phase 01: bench init runs with --no-backups, a denied crontab only warns
grep -q -- '--no-backups --verbose' "$ROOT/lib/frappe-local/bench.sh" || fail "bench init must pass --no-backups"

printf 'test-doctor-hardening: ok\n'
