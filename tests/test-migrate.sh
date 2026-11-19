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
add_proc 4242 "honcho start -f Procfile.lean" "$BENCH"
export MOCK_CURL_CODE=200

# ---- doctor names the old agent, and only the one for this bench
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] Legacy agents: 1 legacy agent(s): com.frappe-mac.frappe-bench (running, last exit 0)"
assert_not_contains "$OUT" "com.frappe-mac.other-bench ("

# ---- a user's own agent is never benchbar's to migrate, even when it says "frappe",
# "honcho" or names this bench's folder; only one that runs this bench's own
# processes (honcho, the runner, socketio, serve) is an old per-process setup
user_plist() {
  # user_plist LABEL WORKDIR ARG...: a LaunchAgent of the user's own
  local label="$1" dir="$2" arg; shift 2
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n<key>Label</key><string>%s</string>\n<key>ProgramArguments</key>\n<array>\n' "$label"
    for arg in "$@"; do printf '  <string>%s</string>\n' "$arg"; done
    printf '</array>\n<key>WorkingDirectory</key><string>%s</string>\n</dict>\n</plist>\n' "$dir"
  } >"$agents/${label}.plist"
}
user_plist com.example.frappe-cloud-backup "$HOME" /usr/local/bin/pull-frappe-cloud-backup.sh --site example.frappe.cloud
user_plist com.example.frappe-vpn "$HOME" /usr/local/bin/frappe-vpn-up
user_plist com.example.nightly-bench-backup "$BENCH" /opt/homebrew/bin/bench --site macdev backup
user_plist com.example.my-honcho "$HOME/side-project" /usr/local/bin/honcho start
user_plist com.example.bench-migrate "$BENCH" "$BENCH/env/bin/python" -m frappe.utils.bench_helper frappe --site macdev migrate
user_plist com.example.old-web "$BENCH" "$BENCH/env/bin/honcho" start -f Procfile
for label in frappe-cloud-backup frappe-vpn nightly-bench-backup my-honcho bench-migrate old-web; do set_agent "com.example.$label" "not running" "" 0; done
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "2 legacy agent(s): com.example.old-web (not running, last exit 0); com.frappe-mac.frappe-bench (running, last exit 0)" "(the frappe-mac agent and the user's old per-process honcho agent for this bench, and nothing else)"
for label in frappe-cloud-backup frappe-vpn nightly-bench-backup my-honcho bench-migrate; do assert_not_contains "$OUT" "com.example.$label" "(a user's own agent is not benchbar's)"; done
user_agents_kept() { for label in frappe-cloud-backup frappe-vpn nightly-bench-backup my-honcho bench-migrate; do assert_file "$agents/com.example.$label.plist" "(repair must leave $label alone)"; done; }

# ---- up before the migration names the old agent and the fix, not "not installed"
run_fm up --bench-dir "$BENCH"
assert_eq "1" "$CODE"
assert_contains "$OUT" "frappe-bench still uses the old agent com.example.old-web and 1 more, set up before BenchBar's own service."
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

# ---- launchd keeps the old job past the wait: the old plist stays where it
# is (a job with nothing on disk to remove it by would run for good), the
# step fails, and the run can be repeated
reset_calls
FL_BOOTOUT_WAIT_SECS=1 MOCK_BOOTOUT_LINGER=100 MOCK_BOOTOUT_LINGER_LABEL=com.frappe-mac.frappe-bench run_fm repair --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "launchd still runs com.frappe-mac.frappe-bench; its plist stays at ${old}"
assert_contains "$OUT" "migrate legacy launchd agents: failed"
assert_contains "$OUT" "stopping: later steps depend on this one"
assert_file "$old"
assert_no_file "$new" "(no second agent is written next to a legacy one launchd still runs)"
assert_calls_not_contain '^launchctl bootstrap'
[[ -z "$(find "$HOME/Library/LaunchAgents-disabled" -name 'com.frappe-mac.frappe-bench.plist' 2>/dev/null)" ]] || fail "the plist must not be moved while launchd runs the job"
rm -f "$MOCK_STATE/agents/com.frappe-mac.frappe-bench.linger"
set_agent com.frappe-mac.frappe-bench running 4242 0

# ---- the real run
reset_calls
run_fm repair --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_no_file "$old"
moved="$(find "$HOME/Library/LaunchAgents-disabled" -name 'com.frappe-mac.frappe-bench.plist')"
[[ -n "$moved" ]] || fail "old plist must be moved aside"
[[ "$(basename "$(dirname "$moved")")" =~ ^[0-9]{8}-[0-9]{6}-[0-9]+$ ]] || fail "old plist must land in LaunchAgents-disabled/<timestamp>-<pid>/, got $moved"
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
# the user's own agents stay in LaunchAgents, loaded and unmoved
user_agents_kept
assert_no_file "$agents/com.example.old-web.plist" "(the old per-process agent of this bench is moved aside)"
[[ -n "$(find "$HOME/Library/LaunchAgents-disabled" -name 'com.example.old-web.plist')" ]] || fail "the old per-process plist must be moved aside, not deleted"
assert_calls_not_contain '(bootout|bootstrap|kickstart|unload).*com.example'
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
