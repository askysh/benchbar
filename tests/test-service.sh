#!/usr/bin/env bash
# Background service phase: install twice, legacy migration, dry-run, autostart, uninstall.
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
assert_no_file "$BENCH/frappe-mac-run.sh"
assert_eq "$snap_before" "$(snapshot "$HOME" "$BENCH" "$FL_STATE_DIR")" "(dry-run wrote nothing)"
assert_calls_not_contain '^launchctl (bootstrap|bootout|kickstart)'

# ---- first real run
reset_calls
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "Legacy agents: 3 legacy agent(s)"
assert_contains "$OUT" "com.akash.frappe-bench.worker (not running, last exit 1)"
assert_file "$plist"
assert_file "$BENCH/frappe-mac-run.sh"
assert_file "$BENCH/Procfile.lean"
[[ -x "$BENCH/frappe-mac-run.sh" ]] || fail "runner must be executable"
bash -n "$BENCH/frappe-mac-run.sh"
grep -q "$MOCK_PIPX_HOME/venvs/frappe-bench/bin/honcho" "$BENCH/frappe-mac-run.sh" || fail "runner must bake the absolute honcho path"
grep -q 'OBJC_DISABLE_INITIALIZE_FORK_SAFETY' "$plist" || fail "plist must set the fork safety variable"
grep -q '<key>NO_PROXY</key><string>\*</string>' "$plist" || fail "plist must set NO_PROXY=*"
grep -q "<string>${MOCK_BREW_PREFIX}/opt/python@3.11/bin:" "$plist" || fail "plist must bake PATH"
grep -q '<key>RunAtLoad</key><true/>' "$plist" || fail "RunAtLoad expected"
grep -q -x -F "# >>> frappe-mac >>>" "$HOME/.zshrc" || fail "helper block expected in zshrc"
grep -q 'benchup()' "$HOME/.zshrc" || fail "benchup helper expected"
grep -q "opt/python@3.11/bin" "$HOME/.zshrc" || fail "profile exports expected in the helper block"
grep -q '^export EDITOR=vim$' "$HOME/.zshrc" || fail "existing zshrc content must survive"
assert_calls_contain "^launchctl bootstrap gui/[0-9]+ ${plist}\$"
for name in benchbar frappe-mac; do
  [[ -L "$HOME/.local/bin/$name" && "$(readlink "$HOME/.local/bin/$name")" == "$ROOT/benchbar" ]] || fail "$name must be linked into ~/.local/bin"
  "$HOME/.local/bin/$name" --version | grep -q 'benchbar 0.3.0' || fail "the symlinked $name must resolve its own libraries"
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
printf '\n# edited by hand\n' >>"$BENCH/frappe-mac-run.sh"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[OK] Runner script"   # appended text does not change the header, so still current
sed -i '' 's/frappe-mac-template: bench-run.sh v1 [0-9a-f]*/frappe-mac-template: bench-run.sh v0 000000000000/' "$BENCH/frappe-mac-run.sh"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] Runner script: runner is outdated"
run_fm repair --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
grep -q 'frappe-mac-template: bench-run.sh v1' "$BENCH/frappe-mac-run.sh" || fail "runner must be regenerated"

# ---- uninstall-service removes only service files
run_fm uninstall-service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_no_file "$plist"
assert_no_file "$BENCH/frappe-mac-run.sh"
assert_no_file "$BENCH/Procfile.lean"
! grep -q -x -F "# >>> frappe-mac >>>" "$HOME/.zshrc" || fail "helper block must be removed"
grep -q '^export EDITOR=vim$' "$HOME/.zshrc" || fail "user zshrc content must survive uninstall"
assert_file "$BENCH/sites/macdev/site_config.json"
assert_file "$BENCH/apps/frappe"
assert_file "$BENCH/env/bin/python"
[[ -n "$(find "$HOME/Library/LaunchAgents-disabled" -name 'com.benchbar.frappe-bench.plist')" ]] || fail "uninstalled plist must be kept aside"

printf 'test-service: ok\n'
