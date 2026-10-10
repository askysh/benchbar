#!/usr/bin/env bash
# The Linux service backend: one systemd --user unit per bench. Unit render,
# install, up/down/restart/status through systemctl, autostart and linger,
# uninstall-service, dead agents, the shared fl_agent_files, and the runner:
# its macOS render must stay what it was, its Linux render must not need
# osascript, lsof or pgrep -q.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
if ! declare -F use_linux >/dev/null; then
  printf 'skipped: the harness has no Linux platform switch (use_linux) yet\n'
  exit 0
fi
use_linux
export USER=tester

BENCH="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH" linuxdev.localhost
udir="$XDG_CONFIG_HOME/systemd/user"
unit="$udir/benchbar-frappe-bench.service"
uname_="benchbar-frappe-bench.service"

# ---- install: the unit is written, systemd reads it, enables it, starts it (a
# stopped bench's runner exits at once on its stop flag)
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_file "$unit"
assert_no_file "$HOME/Library/LaunchAgents/com.benchbar.frappe-bench.plist" "(no plist on Linux)"
assert_calls_contain '^systemctl --user daemon-reload$'
assert_calls_contain "^systemctl --user enable ${uname_}\$"
assert_calls_not_contain '^launchctl'
assert_eq "manual" "$(cat "$BENCH/logs/.bench-stopped")"
assert_eq "enabled" "$(systemctl --user show -p UnitFileState --value "$uname_")"
assert_eq "inactive" "$(systemctl --user show -p ActiveState --value "$uname_")" "(a stopped bench stays stopped)"

# ---- the unit
grep -q -E '^# benchbar-template: systemd-user\.service v[0-9]+ [0-9a-f]{12}$' "$unit" || fail "unit must carry the version hash header"
grep -q -x '# benchbar-label: benchbar-frappe-bench' "$unit" || fail "unit must name its label"
grep -q -x '# benchbar-autostart: true' "$unit" || fail "autostart on is recorded in the unit"
grep -q -x 'Description=BenchBar bench frappe-bench' "$unit" || fail "unit description"
grep -q -x "WorkingDirectory=${BENCH}" "$unit" || fail "WorkingDirectory"
grep -q -x "ExecStart=/bin/bash \"${BENCH}/benchbar-run.sh\"" "$unit" || fail "ExecStart runs the runner"
grep -q -x 'Type=simple' "$unit" || fail "Type"
grep -q -x 'Restart=on-failure' "$unit" || fail "Restart"
grep -q -x 'RestartSec=20' "$unit" || fail "RestartSec"
grep -q -x 'KillMode=mixed' "$unit" || fail "KillMode"
grep -q -x 'Environment=LANG=C.UTF-8' "$unit" || fail "LANG"
grep -q -x 'Environment=NO_PROXY=\*' "$unit" || fail "NO_PROXY"
grep -q -x "StandardOutput=append:${BENCH}/logs/bench.log" "$unit" || fail "StandardOutput"
grep -q -x "StandardError=append:${BENCH}/logs/bench.log" "$unit" || fail "StandardError"
grep -q -x 'WantedBy=default.target' "$unit" || fail "WantedBy"
! grep -q 'OBJC_DISABLE_INITIALIZE_FORK_SAFETY' "$unit" || fail "no macOS only environment in the unit"
! grep -q -i -E 'launchd|plist|Library/' "$unit" || fail "nothing of launchd in the unit"
path_line="$(sed -n 's/^Environment="PATH=\(.*\)"$/\1/p' "$unit")"
case "$path_line" in "$HOME"/.local/share/fnm/node-versions/v22.*/installation/bin:*) ;; *) fail "PATH starts with fnm's Node: $path_line" ;; esac
case "$path_line" in *"$HOME"/.local/share/uv/python/cpython-3.11*/bin:*) ;; *) fail "PATH names uv's Python: $path_line" ;; esac
case "$path_line" in *":$HOME/.local/bin:"*) ;; *) fail "PATH names ~/.local/bin: $path_line" ;; esac

# ---- the runner of the Linux bench
runner="$BENCH/benchbar-run.sh"
bash -n "$runner"
! grep -q 'osascript' "$runner" || fail "the Linux runner has no osascript"
! grep -q 'lsof' "$runner" || fail "the Linux runner has no lsof"
! grep -q 'pgrep -[a-z]*q' "$runner" || fail "the Linux runner has no pgrep -q"
! grep -q '__[A-Z_]*__' "$runner" || fail "no token may be left in the runner"
# shellcheck disable=SC2016  # the literal text of the runner
grep -q -F '/proc/$1/cwd' "$runner" || fail "the Linux runner reads the folder of a process from /proc"
grep -q 'ss -Hltnp' "$runner" || fail "the Linux runner finds listeners with ss"
grep -q -x '  :' "$runner" || fail "notify is a no-op on Linux"

# ---- second run: nothing to do, nothing written
reset_calls
snap_before="$(snapshot "$udir" "$BENCH")"
sleep 1
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "unchanged: all"
assert_eq "$snap_before" "$(snapshot "$udir" "$BENCH")" "(a second run writes nothing)"
assert_calls_not_contain '^systemctl --user (enable|start|disable|restart)'

# ---- a start systemd refuses (masked, start limit) is a failed bootstrap
printf '# benchbar-autostart: true\n[Service]\nExecStart=/bin/true\n' >"$udir/benchbar-refused.service"
touch "$MOCK_STATE/start_refused"
rc=0; XDG_CONFIG_HOME="$HOME/.config" bash -c '. "$1/lib/frappe-local/ui.sh"; . "$1/lib/frappe-local/launchd.sh"; . "$1/lib/frappe-local/systemd.sh"; fl_agent_bootstrap "$2"' _ "$ROOT" "$udir/benchbar-refused.service" >/dev/null 2>&1 || rc=$?
assert_eq "1" "$rc" "(a refused start is not reported as loaded)"
rm -f "$MOCK_STATE/start_refused" "$udir/benchbar-refused.service"
systemctl --user daemon-reload

# ---- up: arms the start, starts the unit, turns lingering on
reset_calls
export MOCK_KICKSTART_PING=200
run_fm up --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "bench is up: http://linuxdev.localhost:8000"
assert_no_file "$BENCH/logs/.bench-stopped"
assert_calls_contain "^systemctl --user start ${uname_}\$"
assert_calls_contain '^loginctl --no-ask-password enable-linger tester$'
assert_eq "yes" "$(cat "$MOCK_STATE/linger/tester")"
assert_eq "active" "$(systemctl --user show -p ActiveState --value "$uname_")"

# ---- status --json: the same keys as on the Mac, filled from systemd
run_fm status --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["agent_loaded"]')"
assert_eq "running" "$(printf '%s' "$OUT" | jget - 'd["agent_state"]')"
assert_eq "4242" "$(printf '%s' "$OUT" | jget - 'd["pid"]')"
assert_eq "running" "$(printf '%s' "$OUT" | jget - 'd["state"]')"
assert_eq "benchbar-frappe-bench" "$(printf '%s' "$OUT" | jget - 'd["label"]')"
assert_eq "yes" "$(printf '%s' "$OUT" | jget - 'd["loaded"]')"
assert_eq "benchbar-frappe-bench" "$(printf '%s' "$OUT" | jget - 'd["agent"]')"
for key in schema_version cli_version bench name site label state stop_reason pid started_at last_exit_code web_url web_ping_code ports sites scheduler state_file log agent_loaded agent_state processes_running url agent loaded stop_flag ping; do
  printf '%s' "$OUT" | jget - "d['$key']" >/dev/null || fail "status --json lost the key $key"
done
run_fm status --bench-dir "$BENCH"
assert_contains "$OUT" "state      running, pid 4242"
run_fm list --json
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["benches"][0]["service_installed"]' 2>/dev/null || printf '%s' "$OUT" | jget - 'd[0]["service_installed"]')"

# up when already running is a no-op
reset_calls
run_fm up --bench-dir "$BENCH"
assert_contains "$OUT" "already running"
assert_calls_not_contain '^systemctl --user (start|restart)'

# ---- restart
reset_calls
run_fm restart --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain "^systemctl --user restart ${uname_}\$"

# ---- down: the stop flag first, then the runner is sent TERM (main process only)
reset_calls
run_fm down --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "manual" "$(cat "$BENCH/logs/.bench-stopped")"
assert_calls_contain "^systemctl --user kill -s SIGTERM --kill-whom=main ${uname_}\$"
assert_eq "inactive" "$(systemctl --user show -p ActiveState --value "$uname_")"
run_fm status --json --bench-dir "$BENCH"
assert_eq "stopped" "$(printf '%s' "$OUT" | jget - 'd["state"]')"
assert_eq "manual" "$(printf '%s' "$OUT" | jget - 'd["stop_reason"]')"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["agent_loaded"]')"
assert_eq "not running" "$(printf '%s' "$OUT" | jget - 'd["agent_state"]')"
unset MOCK_KICKSTART_PING

# ---- a unit systemd has not read yet is loaded by up
rm -f "$MOCK_STATE/units/${uname_}"
reset_calls
export MOCK_KICKSTART_PING=200
run_fm up --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "agent not loaded; loading"
assert_calls_contain '^systemctl --user daemon-reload$'
assert_calls_contain "^systemctl --user start ${uname_}\$"
run_fm down --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
unset MOCK_KICKSTART_PING

# ---- autostart off: the unit is rewritten and no longer enabled
reset_calls
run_fm autostart off --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
grep -q -x '# benchbar-autostart: false' "$unit" || fail "autostart off is recorded in the unit"
assert_calls_contain "^systemctl --user disable (--now )?${uname_}\$"
assert_eq "disabled" "$(systemctl --user show -p UnitFileState --value "$uname_")"
assert_calls_not_contain "^systemctl --user enable ${uname_}"
run_fm autostart --bench-dir "$BENCH"; assert_contains "$OUT" "autostart is off"

# ---- autostart on: enabled again, lingering on
rm -f "$MOCK_STATE/linger/tester"
reset_calls
run_fm autostart on --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
grep -q -x '# benchbar-autostart: true' "$unit" || fail "autostart on is recorded in the unit"
assert_calls_contain "^systemctl --user enable ${uname_}\$"
assert_calls_contain '^loginctl --no-ask-password enable-linger tester$'
assert_eq "enabled" "$(systemctl --user show -p UnitFileState --value "$uname_")"
assert_eq "manual" "$(cat "$BENCH/logs/.bench-stopped")" "(changing autostart does not start a stopped bench)"
# lingering already on: asked, not set again
reset_calls
run_fm autostart on --bench-dir "$BENCH"
assert_calls_contain '^loginctl show-user tester'
assert_calls_not_contain '^loginctl( --no-ask-password)? enable-linger'
# a refusal is a warning, not a failure
rm -f "$MOCK_STATE/linger/tester"
export MOCK_LINGER_DENIED=1
run_fm autostart on --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "could not turn on lingering"
unset MOCK_LINGER_DENIED

# ---- dry run: the plan only
reset_calls
run_fm up --dry-run --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain '^systemctl --user (start|restart|enable|disable|kill)'
assert_calls_not_contain '^loginctl( --no-ask-password)? enable-linger'

# ---- the shared helpers, on both platforms
glob_home="$TMP_DIR/globhome"
mkdir -p "$glob_home/Library/LaunchAgents" "$glob_home/.config/systemd/user"
: >"$glob_home/Library/LaunchAgents/com.benchbar.a.plist"
: >"$glob_home/Library/LaunchAgents/com.benchbar.b.plist"
: >"$glob_home/Library/LaunchAgents/com.frappe-mac.c.plist"
: >"$glob_home/Library/LaunchAgents/com.other.d.plist"
: >"$glob_home/.config/systemd/user/benchbar-a.service"
: >"$glob_home/.config/systemd/user/benchbar-b.service"
: >"$glob_home/.config/systemd/user/other.service"
mac_files="$(HOME="$glob_home" bash -c '. "$1/lib/frappe-local/launchd.sh"; fl_agent_files' _ "$ROOT")"
assert_eq "$glob_home/Library/LaunchAgents/com.benchbar.a.plist
$glob_home/Library/LaunchAgents/com.benchbar.b.plist" "$mac_files" "(macOS: the benchbar plists)"
mac_all="$(HOME="$glob_home" bash -c '. "$1/lib/frappe-local/launchd.sh"; fl_agent_files all' _ "$ROOT")"
assert_eq "$glob_home/Library/LaunchAgents/com.benchbar.a.plist
$glob_home/Library/LaunchAgents/com.benchbar.b.plist
$glob_home/Library/LaunchAgents/com.frappe-mac.c.plist" "$mac_all" "(macOS: all adds the frappe-mac plists)"
lin_files="$(HOME="$glob_home" XDG_CONFIG_HOME="$glob_home/.config" bash -c '. "$1/lib/frappe-local/launchd.sh"; . "$1/lib/frappe-local/systemd.sh"; fl_agent_files all' _ "$ROOT")"
assert_eq "$glob_home/.config/systemd/user/benchbar-a.service
$glob_home/.config/systemd/user/benchbar-b.service" "$lin_files" "(Linux: the benchbar units)"
none="$(HOME="$TMP_DIR/nothing" XDG_CONFIG_HOME="$TMP_DIR/nothing/.config" bash -c '. "$1/lib/frappe-local/launchd.sh"; . "$1/lib/frappe-local/systemd.sh"; fl_agent_files; fl_legacy_agents_list; echo end' _ "$ROOT")"
assert_eq "end" "$none" "(no units, no legacy agents)"

# ---- dead agents: a running unit whose runner script is gone
ghost="$TMP_DIR/ghost-bench"
mkdir -p "$ghost"
cat >"$udir/benchbar-ghost.service" <<UNIT
# benchbar-label: benchbar-ghost
[Unit]
Description=BenchBar bench ghost
[Service]
WorkingDirectory=${ghost}
ExecStart=/bin/bash "${ghost}/benchbar-run.sh"
UNIT
systemctl --user daemon-reload
systemctl --user enable benchbar-ghost.service
systemctl --user start benchbar-ghost.service
dead="$(bash -c '. "$1/lib/frappe-local/ui.sh"; . "$1/lib/frappe-local/launchd.sh"; . "$1/lib/frappe-local/systemd.sh"; fl_dead_agents_list' _ "$ROOT")"
assert_eq "$udir/benchbar-ghost.service|benchbar-ghost|${ghost}" "$dead"
assert_eq "benchbar-ghost" "$(bash -c '. "$1/lib/frappe-local/launchd.sh"; . "$1/lib/frappe-local/systemd.sh"; fl_plist_label "$2"' _ "$ROOT" "$udir/benchbar-ghost.service")"
assert_eq "${ghost}/benchbar-run.sh" "$(bash -c '. "$1/lib/frappe-local/launchd.sh"; . "$1/lib/frappe-local/systemd.sh"; fl_plist_runner "$2"' _ "$ROOT" "$udir/benchbar-ghost.service")"
assert_eq "$ghost" "$(bash -c '. "$1/lib/frappe-local/launchd.sh"; . "$1/lib/frappe-local/systemd.sh"; fl_plist_working_dir "$2"' _ "$ROOT" "$udir/benchbar-ghost.service")"
assert_eq "$udir/benchbar-ghost.service|benchbar-ghost" "$(bash -c '. "$1/lib/frappe-local/ui.sh"; . "$1/lib/frappe-local/state.sh"; . "$1/lib/frappe-local/launchd.sh"; . "$1/lib/frappe-local/systemd.sh"; fl_agents_for_dir "$2"' _ "$ROOT" "$ghost")"
# stopped: no longer listed
systemctl --user stop benchbar-ghost.service
assert_eq "" "$(bash -c '. "$1/lib/frappe-local/ui.sh"; . "$1/lib/frappe-local/launchd.sh"; . "$1/lib/frappe-local/systemd.sh"; fl_dead_agents_list' _ "$ROOT")"
# uninstall-service on a folder that is no bench: only the orphan unit goes
reset_calls
run_fm uninstall-service --yes --bench-dir "$ghost"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^systemctl --user disable --now benchbar-ghost.service$'
assert_no_file "$udir/benchbar-ghost.service"
[[ -n "$(find "$XDG_CONFIG_HOME/systemd/user-disabled" -name 'benchbar-ghost.service')" ]] || fail "the orphan unit must be moved aside, not deleted"
assert_file "$unit" "(another bench's unit stays)"
systemctl --user daemon-reload

# ---- uninstall-service: stop and disable, move the unit aside, keep the bench
printf 'keep\n' >"$BENCH/sites/keep.txt"
reset_calls
run_fm uninstall-service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain "^systemctl --user disable --now ${uname_}\$"
assert_no_file "$unit"
[[ -n "$(find "$XDG_CONFIG_HOME/systemd/user-disabled" -name 'benchbar-frappe-bench.service')" ]] || fail "the unit must be moved aside, not deleted"
assert_file "$BENCH/sites/keep.txt" "(the bench is untouched)"
assert_file "$BENCH/sites/common_site_config.json"
assert_no_file "$BENCH/benchbar-run.sh"
assert_calls_not_contain '^rm '
run_fm status --json --bench-dir "$BENCH"
assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["agent_loaded"]')" "(systemd was told to forget the unit)"

# ---- a runner that will not stop keeps its unit
run_fm service --yes --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
export MOCK_KICKSTART_PING=200
run_fm up --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
unset MOCK_KICKSTART_PING
export MOCK_STOP_STUCK=1 FL_BOOTOUT_WAIT_SECS=1
run_fm uninstall-service --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "systemd still runs benchbar-frappe-bench"
assert_contains "$OUT" "systemctl --user disable --now ${uname_}"
assert_file "$unit" "(a unit systemd still runs keeps its file)"
unset MOCK_STOP_STUCK FL_BOOTOUT_WAIT_SECS

# ---- the runner on the Mac is what it was
# The header hash covers the whole rendered text except the CLI version, so
# the hash from before the notify and lsof lines became template variables
# proves the render is the same text byte for byte.
. "$ROOT/lib/frappe-local/ui.sh"
. "$ROOT/lib/frappe-local/run.sh"
. "$ROOT/lib/frappe-local/templates.sh"
B=/home/u/dev/frappe-bench
mac_runner="$(fl_template_render bench-run.sh "BENCH_DIR=$B" "BENCH_RE=$B" "BENCH_NAME=frappe-bench" "HONCHO=/h/honcho" \
  "PORTS=8000,9000,11000,13000" "LABEL=com.benchbar.frappe-bench" "MAX_STARTS=3" "WINDOW=600" "SITE=macdev" "WEB_PORT=8000" "CLI_VERSION=1.2.3")"
assert_eq "bench-run.sh v7 e0168e9aee41" "$(fl_template_header_of "$mac_runner")" "(the macOS runner renders as before)"
assert_contains "$mac_runner" "  pgrep -xq BenchBar 2>/dev/null && return 0
  osascript -e \"display notification \\\"\$1\\\" with title \\\"BenchBar: frappe-bench\\\"\" >/dev/null 2>&1
}"
assert_contains "$mac_runner" "case \"\$(lsof -a -p \"\$1\" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n1)\" in"
assert_contains "$mac_runner" "for pid in \$(lsof -ti \"tcp:\$PORTS\" -sTCP:LISTEN 2>/dev/null); do"
assert_contains "$mac_runner" "held=\"\$(lsof -ti \"tcp:\$PORTS\" -sTCP:LISTEN 2>/dev/null | tr '\\n' ' ')\""
assert_not_contains "$mac_runner" "__NOTIFY_BODY__"
mac_plist="$(fl_template_render launchagent.plist "LABEL=com.benchbar.frappe-bench" "APP_BUNDLE_ID=x.y" "RUNNER=$B/benchbar-run.sh" "BENCH_DIR=$B" "PATH=/a:/b" "RUN_AT_LOAD=true" "LOG=$B/logs/bench.log")"
assert_eq "launchagent.plist v2 e8668b7bf322" "$(fl_template_header_of "$mac_plist")" "(the macOS plist renders as before)"
# a value passed for a key beats the template's default, and a default is not
# part of the hash twice
over="$(fl_template_render bench-run.sh "BENCH_DIR=$B" "BENCH_RE=$B" "BENCH_NAME=frappe-bench" "HONCHO=/h/honcho" \
  "PORTS=8000,9000,11000,13000" "LABEL=com.benchbar.frappe-bench" "MAX_STARTS=3" "WINDOW=600" "SITE=macdev" "WEB_PORT=8000" "CLI_VERSION=1.2.3" "NOTIFY_BODY=:")"
assert_not_contains "$over" "osascript"
assert_contains "$over" "lsof -a -p"
[[ "$(fl_template_header_of "$over")" != "$(fl_template_header_of "$mac_runner")" ]] || fail "a changed runner must have another hash"

printf 'ok\n'
