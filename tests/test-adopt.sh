#!/usr/bin/env bash
# benchbar adopt: registers an existing bench, shows the plan, asks, writes
# only the service files, never runs migrate, build or update, and is
# idempotent. Also: benchbar mariadb-password.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH"

# not a bench
mkdir -p "$HOME/notabench"
run_fm adopt "$HOME/notabench"; assert_eq "1" "$CODE"; assert_contains "$OUT" "is not a bench"
run_fm adopt; assert_eq "1" "$CODE"; assert_contains "$OUT" "Usage: benchbar adopt"

# plan mode: no terminal and no --yes means the question is answered "no" and nothing is written
run_fm adopt "$BENCH" </dev/null
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "benchbar adopt"
assert_contains "$OUT" "Plan"
assert_contains "$OUT" "write Procfile.lean"
assert_contains "$OUT" "write and load the launchd agent"
assert_contains "$OUT" "Cancelled. Nothing was changed."
assert_no_file "$BENCH/Procfile.lean"
assert_no_file "$BENCH/benchbar-run.sh"
assert_no_file "$HOME/Library/LaunchAgents/com.benchbar.frappe-bench.plist"
# a cancelled adopt does not make the bench the default
[[ -z "$(sed -n 's/^BENCH_DIR=//p' "$FL_STATE_FILE" 2>/dev/null)" ]] || fail "a cancelled adopt must not remember the bench"

# dry-run shows the plan and writes nothing
run_fm adopt "$BENCH" --dry-run
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "dry-run: nothing will be changed"
assert_no_file "$BENCH/Procfile.lean"
[[ -z "$(sed -n 's/^BENCH_DIR=//p' "$FL_STATE_FILE" 2>/dev/null)" ]] || fail "a dry-run adopt must not remember the bench"

# --yes applies: service files, agent, helpers, hosts; the bench stays stopped
run_fm adopt "$BENCH" --yes
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "sites/, apps/, env/ and the databases are not touched"
assert_file "$BENCH/Procfile.lean"
assert_file "$BENCH/benchbar-run.sh"
assert_file "$HOME/Library/LaunchAgents/com.benchbar.frappe-bench.plist"
assert_file "$HOME/.local/bin/benchbar"
grep -q -x -F "# >>> benchbar >>>" "$HOME/.zshrc" || fail "helper block expected"
grep -q -x '127.0.0.1 macdev' "$FL_HOSTS_FILE" || fail "hosts entry expected"
assert_eq "manual" "$(tr -d '[:space:]' <"$BENCH/logs/.bench-stopped")" "(adopt must not start the bench)"
assert_calls_not_contain '^bench (migrate|build|update|setup)'
assert_calls_contain '^launchctl bootstrap'
assert_contains "$OUT" "Next steps"
assert_eq "$BENCH" "$(sed -n 's/^BENCH_DIR=//p' "$FL_STATE_FILE")" "(remembered once applied)"
# data untouched
assert_file "$BENCH/sites/macdev/site_config.json"
assert_eq "$(cat "$BENCH/Procfile")" "redis_cache: redis-server config/redis_cache.conf
web: bench serve --port 8000" "(the bench's own Procfile is not rewritten)"

# a second adopt changes nothing
reset_calls
snap_before="$(snapshot "$HOME" "$BENCH")"
sleep 1
run_fm adopt "$BENCH" --yes
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "unchanged: all"
assert_eq "$snap_before" "$(snapshot "$HOME" "$BENCH")" "(second adopt must write nothing)"
assert_calls_not_contain '^launchctl (bootstrap|bootout|kickstart)'
assert_calls_not_contain '^bench '

# adopting a bench with the old frappe-mac agent migrates it, like repair
OLD="$HOME/oldbench"; make_fake_bench "$OLD" oldsite
cat >"$HOME/Library/LaunchAgents/com.frappe-mac.oldbench.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>Label</key><string>com.frappe-mac.oldbench</string>
<key>WorkingDirectory</key><string>${OLD}</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>${OLD}/frappe-mac-run.sh</string></array>
</dict></plist>
PLIST
set_agent com.frappe-mac.oldbench "not running" "" 0
run_fm adopt "$OLD" --yes
assert_eq "0" "$CODE" "$OUT"
assert_no_file "$HOME/Library/LaunchAgents/com.frappe-mac.oldbench.plist"
assert_file "$HOME/Library/LaunchAgents/com.benchbar.oldbench.plist"
[[ -n "$(ls "$HOME"/Library/LaunchAgents-disabled/*/com.frappe-mac.oldbench.plist 2>/dev/null)" ]] || fail "old plist must be moved aside, not deleted"

# ---- a bench without honcho: adopt warns and never installs into env
NOH="$HOME/nohoncho"; make_fake_bench "$NOH" nosite
mv "$MOCK_PIPX_HOME/venvs/frappe-bench/bin/honcho" "$MOCK_PIPX_HOME/venvs/frappe-bench/bin/honcho.away"
run_fm adopt "$NOH" --yes
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "adopt does not install into env"
assert_contains "$OUT" "pipx install honcho"
assert_calls_not_contain '^(uv pip install|pip install|pipx install|python.* -m pip install)' "(adopt must not install anything)"
assert_not_contains "$OUT" "install honcho into the bench env"
assert_file "$HOME/Library/LaunchAgents/com.benchbar.nohoncho.plist"
mv "$MOCK_PIPX_HOME/venvs/frappe-bench/bin/honcho.away" "$MOCK_PIPX_HOME/venvs/frappe-bench/bin/honcho"

# ---- benchbar mariadb-password
run_fm mariadb-password </dev/null
assert_eq "1" "$CODE"; assert_contains "$OUT" "no MariaDB root password in the Keychain"
mkdir -p "$MOCK_STATE/keychain"; printf 'kc-secret-1\n' >"$MOCK_STATE/keychain/benchbar-mariadb--root"
run_fm mariadb-password </dev/null
assert_eq "1" "$CODE" "$OUT"; assert_not_contains "$OUT" "kc-secret-1"; assert_contains "$OUT" "not printed"
run_fm mariadb-password --yes
assert_eq "0" "$CODE" "$OUT"; assert_eq "kc-secret-1" "$OUT"

printf 'test-adopt: ok\n'
