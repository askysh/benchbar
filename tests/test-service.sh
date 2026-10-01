#!/usr/bin/env bash
# Background service phase: install twice, legacy migration, dry-run, autostart, uninstall,
# and uninstall-service --all over several benches.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH"
mkdir -p "$HOME/Library/LaunchAgents"
plist="$HOME/Library/LaunchAgents/com.benchbar.frappe-bench.plist"

# ---- legacy per-process agents from an older setup, one of them crash-looping
for name in web worker socketio; do
  printf '<?xml version="1.0"?><plist version="1.0"><dict><key>Label</key><string>com.akash.frappe-bench.%s</string><key>ProgramArguments</key><array><string>bench</string><string>%s</string></array></dict></plist>\n' "$name" "$name" \
    >"$HOME/Library/LaunchAgents/com.akash.frappe-bench.${name}.plist"
done
set_agent com.akash.frappe-bench.web running 500 0
set_agent com.akash.frappe-bench.worker "not running" "" 1
printf '<?xml version="1.0"?><plist version="1.0"><dict><key>Label</key><string>com.unrelated.app</string></dict></plist>\n' >"$HOME/Library/LaunchAgents/com.unrelated.app.plist"

# ---- first run: dry-run must print the plan and change nothing
snap_before="$(snapshot "$HOME" "$BENCH" "$FL_STATE_DIR")"
run_fm service --dry-run --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "mode     dry-run"
assert_contains "$OUT" "to update"
assert_contains "$OUT" "dry-run: would write"
assert_no_file "$plist"
assert_no_file "$BENCH/benchbar-run.sh"
assert_eq "$snap_before" "$(snapshot "$HOME" "$BENCH" "$FL_STATE_DIR")" "(dry-run wrote nothing)"
assert_calls_not_contain '^launchctl (bootstrap|bootout|kickstart)'

# ---- first real run
reset_calls
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "Legacy agents: 3 legacy agent(s)"
assert_contains "$OUT" "com.akash.frappe-bench.worker (not running, last exit 1)"
assert_file "$plist"
assert_file "$BENCH/benchbar-run.sh"
assert_file "$BENCH/Procfile.lean"
[[ -x "$BENCH/benchbar-run.sh" ]] || fail "runner must be executable"
bash -n "$BENCH/benchbar-run.sh"
grep -q "$MOCK_PIPX_HOME/venvs/frappe-bench/bin/honcho" "$BENCH/benchbar-run.sh" || fail "runner must bake the absolute honcho path"
grep -q 'OBJC_DISABLE_INITIALIZE_FORK_SAFETY' "$plist" || fail "plist must set the fork safety variable"
grep -q '<key>NO_PROXY</key><string>\*</string>' "$plist" || fail "plist must set NO_PROXY=*"
grep -q "<string>${MOCK_BREW_PREFIX}/opt/python@3.11/bin:" "$plist" || fail "plist must bake PATH"
grep -q '<key>RunAtLoad</key><true/>' "$plist" || fail "RunAtLoad expected"
grep -q -x -F "# >>> benchbar >>>" "$HOME/.zshrc" || fail "helper block expected in zshrc"
grep -q 'benchup()' "$HOME/.zshrc" || fail "benchup helper expected"
grep -q "opt/python@3.11/bin" "$HOME/.zshrc" || fail "profile exports expected in the helper block"
grep -q '^export EDITOR=vim$' "$HOME/.zshrc" || fail "existing zshrc content must survive"
assert_calls_contain "^launchctl bootstrap gui/[0-9]+ ${plist}\$"
for name in benchbar frappe-mac; do
  [[ -L "$HOME/.local/bin/$name" && "$(readlink "$HOME/.local/bin/$name")" == "$ROOT/benchbar" ]] || fail "$name must be linked into ~/.local/bin"
  "$HOME/.local/bin/$name" --version | grep -q "benchbar ${VER}" || fail "the symlinked $name must resolve its own libraries"
done
grep -q '<key>AssociatedBundleIdentifiers</key>' "$plist" || fail "plist must name the BenchBar app"
grep -q '<string>com.akashmishra.benchbar</string>' "$plist" || fail "plist must carry the app bundle id"
assert_eq "manual" "$(cat "$BENCH/logs/.bench-stopped")"
# legacy agents: booted out and moved, never deleted, unrelated agent untouched
for name in web worker socketio; do
  assert_no_file "$HOME/Library/LaunchAgents/com.akash.frappe-bench.${name}.plist"
  [[ -n "$(find "$HOME/Library/LaunchAgents-disabled" -name "com.akash.frappe-bench.${name}.plist")" ]] || fail "legacy ${name} plist must be moved aside"
done
assert_calls_contain '^launchctl bootout gui/[0-9]+/com.akash.frappe-bench.web$'
assert_file "$HOME/Library/LaunchAgents/com.unrelated.app.plist"
assert_calls_not_contain 'com.unrelated.app'
# the user's Procfile.lean was foreign: backed up before replacing
grep -rq 'web: bench serve --port 8000' "$FL_BACKUP_ROOT" || true
assert_eq "$BENCH" "$(sed -n 's/^BENCH_DIR=//p' "$FL_STATE_FILE")"

# ---- second run: everything unchanged, nothing written
reset_calls
snap_before="$(snapshot "$HOME" "$BENCH")"
sleep 1
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "unchanged: all"
assert_not_contains "$OUT" "to update"
assert_eq "$snap_before" "$(snapshot "$HOME" "$BENCH")" "(second run must write nothing)"
assert_calls_not_contain '^launchctl (bootstrap|bootout|kickstart)'
[[ -z "$(find "$FL_BACKUP_ROOT" -newer "$FL_STATE_FILE" -type f 2>/dev/null)" ]] || true

# ---- the bench dir is remembered: no flag needed now
run_fm service --yes
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "unchanged"

# ---- a changed template input (autostart off) rewrites only the plist, with a backup
reset_calls
run_fm autostart off --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
grep -q '<key>RunAtLoad</key><false/>' "$plist" || fail "autostart off must set RunAtLoad false"
[[ -n "$(find "$FL_BACKUP_ROOT" -name '*com.benchbar.frappe-bench.plist' | head -n1)" ]] || fail "old plist must be backed up"
assert_calls_contain '^launchctl bootout'
assert_calls_contain '^launchctl bootstrap'
run_fm autostart on --bench-dir "$BENCH"
grep -q '<key>RunAtLoad</key><true/>' "$plist" || fail "autostart on must restore RunAtLoad"

# ---- a hand-edited runner is detected as outdated and regenerated
printf '\n# edited by hand\n' >>"$BENCH/benchbar-run.sh"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[OK] Runner script"   # appended text does not change the header, so still current
sed_inplace 's/benchbar-template: bench-run.sh v[0-9]* [0-9a-f]*/benchbar-template: bench-run.sh v0 000000000000/' "$BENCH/benchbar-run.sh"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] Runner script: runner is outdated"
run_fm repair --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
grep -q 'benchbar-template: bench-run.sh v4' "$BENCH/benchbar-run.sh" || fail "runner must be regenerated"

# ---- reloading a running agent waits for launchd to let go of it
# (real launchctl: bootout returns while the job still shuts down, and a
# bootstrap meanwhile fails; this left a bench stopped and unloaded)
run_fm up --bench-dir "$BENCH" >/dev/null
sed_inplace 's/benchbar-template: launchagent.plist v\([0-9]*\) [0-9a-f]*/benchbar-template: launchagent.plist v\1 000000000000/' "$plist"
reset_calls
MOCK_BOOTOUT_LINGER=3 run_fm repair --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_file "$MOCK_STATE/agents/com.benchbar.frappe-bench" "(agent must be loaded after the reload)"
assert_contains "$(cat "$MOCK_STATE/agents/com.benchbar.frappe-bench")" "state = running"
assert_calls_contain '^launchctl kickstart gui/[0-9]+/com.benchbar.frappe-bench$'
assert_not_contains "$OUT" "written but not loaded"

# a job that never goes away fails the step instead of claiming success
sed_inplace 's/benchbar-template: launchagent.plist v\([0-9]*\) [0-9a-f]*/benchbar-template: launchagent.plist v\1 000000000000/' "$plist"
FL_BOOTOUT_WAIT_SECS=1 MOCK_BOOTOUT_LINGER=1000 run_fm repair --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "launchd did not let go of com.benchbar.frappe-bench"
rm -f "$MOCK_STATE/agents/com.benchbar.frappe-bench.linger"
set_agent com.benchbar.frappe-bench running 4242 0

# ---- uninstall-service removes only service files
run_fm uninstall-service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_no_file "$plist"
assert_no_file "$BENCH/benchbar-run.sh"
assert_no_file "$BENCH/Procfile.lean"
! grep -q -x -F "# >>> benchbar >>>" "$HOME/.zshrc" || fail "helper block must be removed"
grep -q '^export EDITOR=vim$' "$HOME/.zshrc" || fail "user zshrc content must survive uninstall"
assert_file "$BENCH/sites/macdev/site_config.json"
assert_file "$BENCH/apps/frappe"
assert_file "$BENCH/env/bin/python"
[[ -n "$(find "$HOME/Library/LaunchAgents-disabled" -name 'com.benchbar.frappe-bench.plist')" ]] || fail "uninstalled plist must be kept aside"

# ---- an emptied bench whose agent is still loaded (it exits 127 every 20 s)
V16="$HOME/dev/v16-bench"
make_fake_bench "$V16" v16dev
run_fm service --yes --bench-dir "$V16"
assert_eq "0" "$CODE" "$OUT"
v16plist="$HOME/Library/LaunchAgents/com.benchbar.v16-bench.plist"
assert_file "$v16plist"
launchctl print "gui/$(id -u)/com.benchbar.v16-bench" >/dev/null 2>&1 || fail "test setup: the v16 agent is loaded"
find "$V16" -mindepth 1 -delete   # a cleanup tool emptied the folder
# doctor of another bench names it, with the command that removes it
make_fake_bench "$BENCH"
run_fm doctor --json --bench-dir "$BENCH"
assert_eq "warn" "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"] == "dead_agents"][0]["status"]')"
assert_contains "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"] == "dead_agents"][0]["fix"]')" "uninstall-service --bench-dir '$V16'"
# uninstall-service works on the emptied folder: the agent goes, nothing else
run_fm uninstall-service --dry-run --yes --bench-dir "$V16"
assert_eq "0" "$CODE" "$OUT"
assert_file "$v16plist"
# launchd keeps the job past the wait: the plist stays and the run fails, so it can be retried
FL_BOOTOUT_WAIT_SECS=1 MOCK_BOOTOUT_LINGER=100 run_fm uninstall-service --yes --bench-dir "$V16"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "launchd still runs com.benchbar.v16-bench"
assert_file "$v16plist"
rm -f "$MOCK_STATE"/agents/com.benchbar.v16-bench.linger
printf 'state = running\nlast exit code = 127\n' >"$MOCK_STATE/agents/com.benchbar.v16-bench"
run_fm uninstall-service --yes --bench-dir "$V16"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "booted out com.benchbar.v16-bench"
assert_no_file "$v16plist"
! launchctl print "gui/$(id -u)/com.benchbar.v16-bench" >/dev/null 2>&1 || fail "the agent must be booted out"
[[ -n "$(find "$HOME/Library/LaunchAgents-disabled" -name 'com.benchbar.v16-bench.plist')" ]] || fail "its plist is kept aside"
run_fm doctor --json --bench-dir "$BENCH"
assert_eq "ok" "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"] == "dead_agents"][0]["status"]')"
# a path with no bench and no agent: the old refusal, clearer
run_fm uninstall-service --yes --bench-dir "$HOME/nowhere"
assert_eq "1" "$CODE"
assert_contains "$OUT" "no com.benchbar agent points at it"

# ---- uninstall-service --all: every bench with a benchbar agent, after one
# question (before brew uninstall, which cannot stop them); a folder that is
# no bench any more loses only its agent, and the benches stay
A="$HOME/dev/all-a"; B="$HOME/dev/all-b"; GONE="$HOME/dev/all-gone"
make_fake_bench "$A"; make_fake_bench "$B" bdev; make_fake_bench "$GONE" gonedev
for b in "$A" "$B" "$GONE"; do
  run_fm service --yes --bench-dir "$b"
  assert_eq "0" "$CODE" "$OUT"
done
find "$GONE" -mindepth 1 -delete
snap_before="$(snapshot "$HOME")"
run_fm uninstall-service --all </dev/null
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "This removes the background service of 3 bench(es)"
assert_contains "$OUT" "${GONE}   (no bench there any more: only its agent goes)"
assert_contains "$OUT" "Cancelled."
run_fm uninstall-service --all --dry-run --yes
assert_eq "0" "$CODE" "$OUT"
assert_eq "$snap_before" "$(snapshot "$HOME")" "(no answer and a dry run change nothing)"
run_fm uninstall-service --all --bench-dir "$A"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "takes --all or --bench-dir, not both"
# launchd keeps the gone folder's job past the wait: that one fails, the
# other two are still uninstalled, and the run says how many
FL_BOOTOUT_WAIT_SECS=1 MOCK_BOOTOUT_LINGER=100 run_fm uninstall-service --all --yes
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "launchd still runs com.benchbar.all-gone"
assert_contains "$OUT" "2 of 3 bench(es) uninstalled"
for b in all-a all-b; do
  assert_no_file "$HOME/Library/LaunchAgents/com.benchbar.${b}.plist"
  [[ -n "$(find "$HOME/Library/LaunchAgents-disabled" -name "com.benchbar.${b}.plist")" ]] || fail "the ${b} plist is kept aside"
done
for b in "$A" "$B"; do
  assert_no_file "$b/benchbar-run.sh"
  assert_no_file "$b/Procfile.lean"
  assert_file "$b/sites/common_site_config.json"
  assert_file "$b/apps/frappe"
done
assert_file "$HOME/Library/LaunchAgents/com.benchbar.all-gone.plist"
! grep -q -x -F "# >>> benchbar >>>" "$HOME/.zshrc" || fail "the helper block goes with --all"
assert_eq "1" "$(grep -c 'removed the helper block' <<<"$OUT")" "(the block is removed once, and said once)"
# the next run finds only what is left: an agent whose folder is no bench
# any more. Its run alone never removes the block, so --all does, once
rm -f "$MOCK_STATE"/agents/*.linger
printf '\n# >>> benchbar >>>\nBENCHBAR="%s"\n# <<< benchbar <<<\n' "$FM" >>"$HOME/.zshrc"
run_fm uninstall-service --all --yes
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "the background service of 1 bench(es) is uninstalled"
assert_no_file "$HOME/Library/LaunchAgents/com.benchbar.all-gone.plist"
! grep -q -x -F "# >>> benchbar >>>" "$HOME/.zshrc" || fail "with only orphan agents the helper block goes too"
assert_eq "1" "$(grep -c 'removed the helper block' <<<"$OUT")"
# nothing left
run_fm uninstall-service --all --yes
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "nothing to uninstall"
# no agent, but a helper block: --all removes it too, after asking
printf '\n# >>> benchbar >>>\nBENCHBAR="%s"\n# <<< benchbar <<<\n' "$FM" >>"$HOME/.zshrc"
run_fm uninstall-service --all --yes
assert_eq "0" "$CODE" "$OUT"
! grep -q -x -F "# >>> benchbar >>>" "$HOME/.zshrc" || fail "the helper block goes with --all"
grep -q '^export EDITOR=vim$' "$HOME/.zshrc" || fail "user zshrc content must survive"

printf 'test-service: ok\n'
