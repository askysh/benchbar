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
grep -q "$BENCH/env/bin/honcho" "$BENCH/benchbar-run.sh" || fail "runner must be re-rendered with the new honcho path"
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

# MariaDB exposed: drop-in written and service restarted, my.cnf backed up.
# MariaDB is shared by every bench: the plan says so, and the restart names
# the benches that are running, also under --yes
add_listener 3306 900 mariadbd '*'
printf 'mariadb@10.11 started akash file\n' >"$MOCK_BREW_SERVICES"
OTHERB="$HOME/otherbench"; make_fake_bench "$OTHERB" othersite
sed_inplace 's/8000/8100/; s/9000/9100/; s/11000/11100/; s/13000/13100/' "$OTHERB/sites/common_site_config.json"
run_fm register "$OTHERB"; assert_eq "0" "$CODE" "$OUT"
add_proc 9100 "/x/bin/honcho start -f Procfile.lean" "$OTHERB"
run_fm repair --dry-run --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "bind MariaDB to 127.0.0.1 (restarts MariaDB, shared by 1 running bench)"
run_fm repair --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "restarting MariaDB, which these running benches use: otherbench"
{ grep -v '^9100 ' "$MOCK_PROCS" || true; } >"$MOCK_PROCS.tmp"; mv "$MOCK_PROCS.tmp" "$MOCK_PROCS"
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
printf 'node@22\n' >"$MOCK_BREW_LEAVES"
run_fm repair --yes --bench-dir "$BENCH"
assert_calls_contain '^brew tab --installed-on-request python@3.11$'
grep -qx 'python@3.11' "$MOCK_BREW_LEAVES" || fail "python must become a leaf"

# ---- a bench set up when v15-lts named node@20: doctor flags the shell
# block, the agent plist and the Node, repair installs node@22 and yarn
# under it, re-renders both PATHs, and never removes node@20
: >"$MOCK_LISTEN"; add_listener 3306 900 mariadbd 127.0.0.1
OLDCFG="$TMP_DIR/config-node20"; mkdir -p "$OLDCFG"; cp "$FL_CONFIG_DIR"/*.tsv "$OLDCFG/"
sed_inplace 's/node@22	22/node@20	20/' "$OLDCFG/release-profiles.tsv"
grep -q 'node@20' "$OLDCFG/release-profiles.tsv" || fail "test setup: the old profile names node@20"
MIG="$HOME/mig-bench"; make_fake_bench "$MIG" migsite
sed_inplace 's/8000/8200/; s/9000/9200/; s/11000/11200/; s/13000/13200/' "$MIG/sites/common_site_config.json"
# the Mac of that time: node@20 installed with its yarn, no node@22 anywhere
mkdir -p "$MOCK_BREW_PREFIX/opt/node@20/bin"
printf '#!/usr/bin/env bash\nprintf "v20.18.0\\n"\n' >"$MOCK_BREW_PREFIX/opt/node@20/bin/node"; chmod +x "$MOCK_BREW_PREFIX/opt/node@20/bin/node"
cp "$ROOT/tests/mocks/npm" "$ROOT/tests/mocks/yarn" "$MOCK_BREW_PREFIX/opt/node@20/bin/"
mv "$MOCK_BREW_PREFIX/opt/node@22" "$TMP_DIR/node22.aside"
# brew's unversioned node (brew/bin comes before /usr/local/bin on the agent's PATH, so the Mac running this test does not decide)
cp "$MOCK_BREW_PREFIX/opt/node@20/bin/node" "$MOCK_BREW_PREFIX/bin/node"
grep -v '^node@22$' "$MOCK_STATE/installed" >"$MOCK_STATE/installed.tmp"; printf 'node@20\n' >>"$MOCK_STATE/installed.tmp"; mv "$MOCK_STATE/installed.tmp" "$MOCK_STATE/installed"
FL_CONFIG_DIR="$OLDCFG" run_fm service --yes --make-default --bench-dir "$MIG"
assert_eq "0" "$CODE" "$OUT"
grep -q 'opt/node@20/bin' "$HOME/.zshrc" || fail "test setup: the shell block names node@20"
grep -q 'opt/node@20/bin' "$HOME/Library/LaunchAgents/com.benchbar.mig-bench.plist" || fail "test setup: the plist PATH names node@20"
FL_CONFIG_DIR="$OLDCFG" run_fm doctor --bench-dir "$MIG"
assert_eq "0" "$CODE" "$OUT"
# the new profile: the block and the plist are outdated, Node and yarn are flagged with actions
run_fm doctor --json --bench-dir "$MIG"
assert_eq "warn" "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"] == "helpers"][0]["status"]')"
assert_eq "warn write_plist" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in [[c for c in d["checks"] if c["id"] == "agent"][0]["status"], [c for c in d["checks"] if c["id"] == "agent"][0]["action"]])')"
assert_eq "warn node_install" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in [[c for c in d["checks"] if c["id"] == "toolchain_node"][0]["status"], [c for c in d["checks"] if c["id"] == "toolchain_node"][0]["action"]])')"
# the formulae check names the move too, with the same action, not the whole system-deps script
assert_eq "fail node_install" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in [[c for c in d["checks"] if c["id"] == "brew"][0]["status"], [c for c in d["checks"] if c["id"] == "brew"][0]["action"]])')"
assert_contains "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"] == "brew"][0]["message"]')" "missing formula: node@22 (the profile's Node moved"
assert_contains "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"] == "toolchain_node"][0]["message"]')" "profile v15-lts expects 22"
assert_eq "warn yarn_install" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in [[c for c in d["checks"] if c["id"] == "toolchain_yarn"][0]["status"], [c for c in d["checks"] if c["id"] == "toolchain_yarn"][0]["action"]])')"
run_fm repair --dry-run --bench-dir "$MIG"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "brew install node@22 (the Node of profile v15-lts; an older node formula is not removed)"
assert_contains "$OUT" "install yarn under node@22 (npm install -g yarn)"
# a Node install that fails stops the run before the plist and the shell block
# are rewritten with a PATH that has no node
reset_calls
MOCK_BREW_INSTALL_FAIL=node@22 run_fm repair --yes --bench-dir "$MIG"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "stopping: later steps depend on this one"
assert_calls_not_contain '^npm install -g yarn$'
grep -q 'opt/node@20/bin' "$HOME/.zshrc" || fail "a failed node install must leave the shell block on node@20"
grep -q 'opt/node@20/bin' "$HOME/Library/LaunchAgents/com.benchbar.mig-bench.plist" || fail "a failed node install must leave the plist PATH on node@20"
reset_calls
run_fm repair --yes --bench-dir "$MIG"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^brew install node@22$'
assert_calls_contain '^npm install -g yarn$'
assert_calls_not_contain '^brew (uninstall|remove)' "(node@20 stays for whatever else uses it)"
assert_file "$MOCK_BREW_PREFIX/opt/node@22/bin/yarn"
assert_file "$MOCK_BREW_PREFIX/opt/node@20/bin/yarn"
grep -q 'opt/node@22/bin' "$HOME/.zshrc" || fail "the shell block must name node@22 after repair"
! grep -q 'opt/node@20/bin' "$HOME/.zshrc" || fail "the shell block must no longer name node@20"
grep -q 'opt/node@22/bin' "$HOME/Library/LaunchAgents/com.benchbar.mig-bench.plist" || fail "the plist PATH must name node@22 after repair"
run_fm doctor --bench-dir "$MIG"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "[OK] Node: Node 22.0.0 at ${MOCK_BREW_PREFIX}/opt/node@22/bin/node, profile v15-lts expects 22"
assert_contains "$OUT" "[OK] yarn: yarn 1.22.22 at ${MOCK_BREW_PREFIX}/opt/node@22/bin/yarn"
# brew knows node@22 but its node is gone (a damaged keg): reinstall, not install
mv "$MOCK_BREW_PREFIX/opt/node@22" "$TMP_DIR/node22.damaged"
reset_calls
run_fm repair --yes --bench-dir "$MIG"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^brew reinstall node@22$'
assert_calls_not_contain '^brew install node@22$'
assert_file "$MOCK_BREW_PREFIX/opt/node@22/bin/node"
rm -rf "$TMP_DIR/node22.damaged"
# a second repair changes nothing
reset_calls
run_fm repair --yes --bench-dir "$MIG"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "unchanged:"
assert_not_contains "$OUT" "to update"
assert_calls_not_contain '^(brew install|npm install)'
rm -rf "$MOCK_BREW_PREFIX/opt/node@22"; mv "$TMP_DIR/node22.aside" "$MOCK_BREW_PREFIX/opt/node@22"; rm -f "$MOCK_BREW_PREFIX/bin/node"
run_fm service --yes --make-default --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"

# large logs are moved aside, not deleted
dd if=/dev/zero of="$BENCH/logs/worker.error.log" bs=1048576 count=3 2>/dev/null
FL_LOG_WARN_MB=2 run_fm repair --yes --bench-dir "$BENCH"
assert_no_file "$BENCH/logs/worker.error.log"
[[ -n "$(ls "$BENCH"/logs/worker.error.log.old.* 2>/dev/null)" ]] || fail "large log must be moved aside"

printf 'test-repair: ok\n'
