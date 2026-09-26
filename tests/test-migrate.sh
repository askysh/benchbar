#!/usr/bin/env bash
# Migration from frappe-mac 0.2.0 agents (com.frappe-mac.<bench>) to
# com.benchbar.<bench>: bootout, move aside, write the new plist, restart a
# bench that was running, leave other benches alone, second run is a no-op.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/dev/frappe-bench"
OTHER="$HOME/dev/other-bench"
make_fake_bench "$BENCH"
make_fake_bench "$OTHER" othersite
agents="$HOME/Library/LaunchAgents"
old="$agents/com.frappe-mac.frappe-bench.plist"
other_old="$agents/com.frappe-mac.other-bench.plist"
new="$agents/com.benchbar.frappe-bench.plist"

old_plist() {
  # old_plist LABEL BENCH_DIR: the shape frappe-mac 0.2.0 wrote
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<!-- frappe-mac-template: launchagent.plist v1 000000000000 -->
<dict>
  <key>Label</key><string>$1</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$2/frappe-mac-run.sh</string>
  </array>
  <key>WorkingDirectory</key><string>$2</string>
</dict>
</plist>
PLIST
}
old_plist com.frappe-mac.frappe-bench "$BENCH" >"$old"
old_plist com.frappe-mac.other-bench "$OTHER" >"$other_old"
set_agent com.frappe-mac.frappe-bench running 4242 0
set_agent com.frappe-mac.other-bench running 5151 0
add_proc 4242 "honcho start -f Procfile.lean"
export MOCK_CURL_CODE=200

# ---- doctor names the old agent, and only the one for this bench
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] Legacy agents: 1 legacy agent(s): com.frappe-mac.frappe-bench (running, last exit 0)"
assert_not_contains "$OUT" "com.frappe-mac.other-bench ("

# ---- up before the migration names the old agent and the fix, not "not installed"
run_fm up --bench-dir "$BENCH"
assert_eq "1" "$CODE"
assert_contains "$OUT" "frappe-bench still uses the old agent com.frappe-mac.frappe-bench"
assert_contains "$OUT" "benchbar repair"
assert_not_contains "$OUT" "not installed"

# ---- names from before 0.3.0 in the bench and the rc file
printf '#!/bin/bash\n# frappe-mac-template: bench-run.sh v2 000000000000\n' >"$BENCH/frappe-mac-run.sh"
printf '# >>> frappe-mac >>>\nbenchup() { old; }\n# <<< frappe-mac <<<\nexport AFTER=1\n' >>"$HOME/.zshrc"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "helper block in $HOME/.zshrc is outdated"
assert_not_contains "$OUT" "old block(s) still present"

# ---- dry-run changes nothing
snap_before="$(snapshot "$HOME" "$BENCH")"
run_fm repair --dry-run --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "would bootout com.frappe-mac.frappe-bench"
assert_eq "$snap_before" "$(snapshot "$HOME" "$BENCH")" "(dry-run wrote nothing)"

# ---- the real run
reset_calls
run_fm repair --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_no_file "$old"
moved="$(find "$HOME/Library/LaunchAgents-disabled" -name 'com.frappe-mac.frappe-bench.plist')"
[[ -n "$moved" ]] || fail "old plist must be moved aside"
[[ "$(basename "$(dirname "$moved")")" =~ ^[0-9]{8}-[0-9]{6}$ ]] || fail "old plist must land in LaunchAgents-disabled/<timestamp>/, got $moved"
assert_calls_contain '^launchctl bootout gui/[0-9]+/com.frappe-mac.frappe-bench$'
assert_file "$new"
grep -q '<string>com.benchbar.frappe-bench</string>' "$new" || fail "new label expected"
grep -q '<string>com.akashmishra.benchbar</string>' "$new" || fail "AssociatedBundleIdentifiers expected"
assert_calls_contain "^launchctl bootstrap gui/[0-9]+ ${new}\$"
assert_calls_contain '^launchctl kickstart gui/[0-9]+/com.benchbar.frappe-bench$' "(a running bench must come back under the new agent)"
assert_no_file "$BENCH/logs/.bench-stopped" "(a running bench must not get a manual stop flag)"
# the runner is benchbar-run.sh now; the old one is backed up and gone
assert_file "$BENCH/benchbar-run.sh"
grep -q "$BENCH/benchbar-run.sh" "$new" || fail "the new agent must run benchbar-run.sh"
assert_no_file "$BENCH/frappe-mac-run.sh"
[[ -n "$(find "$FL_BACKUP_ROOT" -name '*frappe-mac-run.sh' | head -n1)" ]] || fail "the old runner must be backed up"
# the frappe-mac block became the benchbar block, in the same place
assert_eq "1" "$(grep -c -x -F '# >>> benchbar >>>' "$HOME/.zshrc")"
assert_eq "0" "$(grep -c -x -F '# >>> frappe-mac >>>' "$HOME/.zshrc")"
assert_eq "export AFTER=1" "$(tail -n 1 "$HOME/.zshrc")" "(content after the block stays after it)"
# the other bench keeps its agent until its own repair
assert_file "$other_old"
assert_calls_not_contain '(bootout|bootstrap|kickstart|unload).*com.frappe-mac.other-bench'

# ---- second run: nothing to migrate, nothing written
reset_calls
snap_before="$(snapshot "$HOME/Library")"
run_fm repair --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "unchanged"
assert_not_contains "$OUT" "Legacy agents"
assert_eq "$snap_before" "$(snapshot "$HOME/Library")" "(second run must not touch LaunchAgents)"
assert_calls_not_contain '^launchctl (bootout|bootstrap)'

# ---- a stopped bench migrates without starting
BENCH2="$HOME/dev/stopped-bench"
make_fake_bench "$BENCH2" stoppedsite
old_plist com.frappe-mac.stopped-bench "$BENCH2" >"$agents/com.frappe-mac.stopped-bench.plist"
set_agent com.frappe-mac.stopped-bench "not running" "" 0
printf 'manual\n' >"$BENCH2/logs/.bench-stopped"
: >"$MOCK_PROCS"
export MOCK_CURL_CODE=000
reset_calls
run_fm repair --yes --bench-dir "$BENCH2"
assert_eq "0" "$CODE" "$OUT"
assert_file "$agents/com.benchbar.stopped-bench.plist"
assert_no_file "$agents/com.frappe-mac.stopped-bench.plist"
assert_calls_not_contain '^launchctl kickstart'
assert_eq "manual" "$(cat "$BENCH2/logs/.bench-stopped")"

# ---- the frappe-mac alias still works
"$ROOT/frappe-mac" --version | grep -q "benchbar ${VER}" || fail "frappe-mac alias must run benchbar"

printf 'test-migrate: ok\n'
