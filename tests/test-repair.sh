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
# while the bench runs, the env is not moved from under its processes
add_proc 7700 "/x/bin/honcho start -f Procfile.lean" "$BENCH"
run_fm repair --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "refusing to rebuild env while the bench is running"
assert_contains "$OUT" "down --bench-dir ${BENCH}, then"
assert_file "$BENCH/env/marker" "(a running bench keeps its env)"
[[ -z "$(ls -d "$BENCH"/env.broken.* 2>/dev/null)" ]] || fail "the env of a running bench must not be moved aside"
: >"$MOCK_PROCS"
reset_calls
MOCK_ENV_NO_PKG_RESOURCES=1 run_fm repair --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
[[ -n "$(ls -d "$BENCH"/env.broken.* 2>/dev/null)" ]] || fail "broken env must be moved aside"
grep -q 'keep me' "$BENCH"/env.broken.*/marker || fail "moved-aside env must keep its content"
# a v15 env gets setuptools<70, so pkg_resources is there for bench and honcho
assert_calls_contain "^uv pip install --python ${BENCH}/env/bin/python setuptools<70\$"

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
# a question nobody can answer is not a step: the run is unchanged and names it as optional
assert_contains "$OUT" "unchanged:"
assert_contains "$OUT" "optional, not asked without a terminal or under --yes: stop Homebrew redis on 6379"
assert_not_contains "$OUT" "stop Homebrew redis on 6379: done"
run_fm repair --bench-dir "$BENCH" </dev/null
assert_contains "$OUT" "unchanged:"
assert_calls_not_contain '^brew services stop redis'

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

# ---- env_setuptools: a v15 env without pkg_resources is flagged and repaired
make_fake_env_python "$BENCH"
MOCK_ENV_NO_PKG_RESOURCES=1 run_fm doctor --json --bench-dir "$BENCH"
r="$(printf '%s' "$OUT" | jget - '"|".join(str([c for c in d["checks"] if c["id"] == "env_setuptools"][0][k]) for k in ("level", "message", "action"))')"
assert_contains "$r" "warn|env/bin/python lacks pkg_resources (setuptools 70+ or none): bench and honcho fail on Frappe v15|env_setuptools"
reset_calls
printf 'still here\n' >"$BENCH/env/marker"
MOCK_ENV_NO_PKG_RESOURCES=1 run_fm repair --yes --bench-dir "$BENCH"
assert_contains "$OUT" "install 'setuptools<70' into the bench env"
assert_calls_contain "^uv pip install --python ${BENCH}/env/bin/python setuptools<70\$"
assert_file "$BENCH/env/marker" "(setuptools must not rebuild the env)"
# with pkg_resources present the step is unchanged (an env rebuild in the same run installs it already)
reset_calls
printf 'keep\n' >"$BENCH/env/marker"
run_fm repair --yes --bench-dir "$BENCH"
assert_calls_not_contain 'setuptools<70'
assert_calls_not_contain '^bench setup env'
rm -f "$BENCH/env/marker"
run_fm doctor --json --bench-dir "$BENCH"
assert_eq "ok" "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"] == "env_setuptools"][0]["level"]')"

# large logs are rotated by copy and truncate: the live file stays (the
# bench's processes keep writing to it) and starts empty, the copy keeps
# the content, and at most three copies are kept
dd if=/dev/zero of="$BENCH/logs/worker.error.log" bs=1048576 count=3 2>/dev/null
inode() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1"; }
old_copies() { find "$BENCH/logs" -name 'worker.error.log.old.*' | wc -l | tr -d ' '; }
ino_before="$(inode "$BENCH/logs/worker.error.log")"
FL_LOG_WARN_MB=2 run_fm repair --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_file "$BENCH/logs/worker.error.log"
[[ ! -s "$BENCH/logs/worker.error.log" ]] || fail "the live log must be truncated"
assert_eq "$ino_before" "$(inode "$BENCH/logs/worker.error.log")" "(the live file keeps its inode: the writers keep it)"
assert_eq "1" "$(old_copies)" "(one copy expected)"
assert_eq "3145728" "$(wc -c <"$BENCH"/logs/worker.error.log.old.* | tr -d ' ')" "(the copy holds the content)"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[OK] Log sizes"
for i in 1 2 3; do
  dd if=/dev/zero of="$BENCH/logs/worker.error.log" bs=1048576 count=3 2>/dev/null
  sleep 1
  FL_LOG_WARN_MB=2 run_fm repair --yes --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
done
assert_eq "3" "$(old_copies)" "(at most three copies are kept)"
assert_contains "$OUT" "removed the old copy"
rm -f "$BENCH"/logs/worker.error.log.old.*

# ---- a write that cannot happen is a failed step, not a done one, and the
# old file stays as it was
sed_inplace 's/benchbar-template: Procfile.lean v[0-9]* [0-9a-f]*/benchbar-template: Procfile.lean v0 000000000000/' "$BENCH/Procfile.lean"
chmod 0555 "$BENCH"
if ! touch "$BENCH/.probe" 2>/dev/null; then
  before="$(cat "$BENCH/Procfile.lean")"
  run_fm repair --yes --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"
  assert_contains "$OUT" "write Procfile.lean: failed"
  assert_not_contains "$OUT" "write Procfile.lean: done"
  assert_contains "$OUT" "read only?"
  assert_eq "$before" "$(cat "$BENCH/Procfile.lean")" "(a failed write leaves the file as it was)"
else
  rm -f "$BENCH/.probe"   # running as root: permissions do not bite, nothing to prove here
fi
chmod 0755 "$BENCH"
# writable again: the outdated Procfile.lean is rewritten
run_fm repair --yes --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"

# ---- callers carry a writer's failure: a drop-in that cannot be written
# is a failed action, a profile file that cannot be written stays as it was
OUT="$(cd "$ROOT" && bash -c 'set -u; SCRIPT_DIR="$PWD"; . lib/frappe-local/ui.sh; . lib/frappe-local/run.sh; . lib/frappe-local/templates.sh; . lib/frappe-local/state.sh; . lib/frappe-local/mariadb.sh; . lib/frappe-local/repair.sh
  fl_mariadb_dropin_path() { printf /nonexistent/local.cnf; }; fl_mariadb_utf8_dropin_path() { printf /nonexistent/utf8.cnf; }
  fl_mariadb_dropin_apply() { return 1; }
  act_mariadb_bind; printf "bind=%s\n" "$?"; act_mariadb_utf8; printf "utf8=%s\n" "$?"' 2>&1)"
assert_contains "$OUT" "bind=1"
assert_contains "$OUT" "utf8=1"
printf 'old\n' >"$TMP_DIR/prof.toml"; printf 'new\n' >"$TMP_DIR/prof.new"
OUT="$(cd "$ROOT" && bash -c 'set -u; SCRIPT_DIR="$PWD"; . lib/frappe-local/ui.sh; . lib/frappe-local/run.sh; . lib/frappe-local/templates.sh; . lib/frappe-local/state.sh; . lib/frappe-local/profiles.sh
  TARGET="$1"; cp() { local last; for last in "$@"; do :; done; [[ "$last" != "$TARGET" ]] || return 1; command cp "$@"; }   # only the final write fails
  FL_ASSUME_YES=1 fl_write_reviewed "$1" "$2" "the profile"; printf "code=%s\n" "$?"' x "$TMP_DIR/prof.toml" "$TMP_DIR/prof.new" 2>&1)"
assert_contains "$OUT" "code=1"
assert_contains "$OUT" "could not write $TMP_DIR/prof.toml; it is as it was"
assert_not_contains "$OUT" "[OK] wrote"
assert_eq "old" "$(cat "$TMP_DIR/prof.toml")"

printf 'test-repair: ok\n'
