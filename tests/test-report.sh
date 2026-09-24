#!/usr/bin/env bash
# benchbar report: the bundle holds doctor, status, versions, agent, logs and
# config key names, and no secret, home path or site config value ever
# reaches the zip.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/frappe-bench"
make_fake_bench "$BENCH"
mkdir -p "$BENCH/apps/frappe/frappe" "$BENCH/apps/erpnext/erpnext"
printf '__version__ = "15.50.1"\n' >"$BENCH/apps/frappe/frappe/__init__.py"
printf "__version__ = '15.48.0'\n" >"$BENCH/apps/erpnext/erpnext/__init__.py"

# secrets that must never appear in the report
DB_PW="SuperSecretDbPw1"; ENC_KEY="EncKeyXYZ987"; API_KEY="ApiKeyQQQ"; API_SECRET="ApiSecretZZZ"
ROOT_PW="RootPwHidden"; TOKEN="TokenLeak123"; BEARER="BearerLeak456"; JSON_PW="JsonPwLeak789"; INI_PW="IniLeak000"
cat >"$BENCH/sites/macdev/site_config.json" <<JSON
{
 "db_name": "_1234abcd",
 "db_password": "${DB_PW}",
 "encryption_key": "${ENC_KEY}",
 "api_key": "${API_KEY}",
 "api_secret": "${API_SECRET}",
 "developer_mode": 1
}
JSON
cat >"$BENCH/sites/common_site_config.json" <<JSON
{
 "default_site": "macdev",
 "root_password": "${ROOT_PW}",
 "redis_cache": "redis://127.0.0.1:13000",
 "redis_queue": "redis://127.0.0.1:11000",
 "socketio_port": 9000,
 "webserver_port": 8000
}
JSON
i=1
while [[ "$i" -le 300 ]]; do printf 'line %d from %s/logs\n' "$i" "$HOME" >>"$BENCH/logs/bench.log"; i=$((i + 1)); done
printf 'token=%s\nAuthorization: Bearer %s\n{"password": "%s"}\n' "$TOKEN" "$BEARER" "$JSON_PW" >>"$BENCH/logs/bench.log"
printf 'worker boot\ndb_password = %s\n' "$INI_PW" >"$BENCH/logs/worker.error.log"

# a fake installed app so its version shows up
mkdir -p "$HOME/Applications/BenchBar.app/Contents"
printf '<plist><dict>\n<key>CFBundleShortVersionString</key>\n<string>0.3.0</string>\n</dict></plist>\n' >"$HOME/Applications/BenchBar.app/Contents/Info.plist"

run_fm service --yes --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
set_agent com.benchbar.frappe-bench "not running" "" 0

# ---- zip on request
OUTDIR="$TMP_DIR/out"
run_fm report --bench-dir "$BENCH" --out "$OUTDIR"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "report written:"
ZIP="$(ls "$OUTDIR"/benchbar-report-*.zip)"
[[ -f "$ZIP" ]] || fail "zip expected in $OUTDIR"
listing="$(unzip -l "$ZIP")"
for f in versions.txt doctor.json status.json launchctl.txt agent.plist Procfile.lean state.json bench.log.tail worker.error.log.tail site-config-keys.txt REDACTIONS.txt; do
  assert_contains "$listing" " $f" "(zip must contain $f)"
done
assert_not_contains "$listing" "site_config.json" "(site configs are never packed)"

EX="$TMP_DIR/extract"; mkdir -p "$EX"; unzip -q "$ZIP" -d "$EX"
all="$(cat "$EX"/*)"
for secret in "$DB_PW" "$ENC_KEY" "$API_KEY" "$API_SECRET" "$ROOT_PW" "$TOKEN" "$BEARER" "$JSON_PW" "$INI_PW"; do
  assert_not_contains "$all" "$secret" "(secret must not reach the zip)"
done
assert_not_contains "$all" "$HOME" "(home folder must be written as ~)"
assert_contains "$all" "~/frappe-bench"
# key names are listed, values are not
keys="$(cat "$EX/site-config-keys.txt")"
assert_contains "$keys" "db_password"
assert_contains "$keys" "encryption_key"
assert_contains "$keys" "common_site_config.json"
assert_contains "$keys" "sites/macdev/site_config.json"
assert_not_contains "$keys" "_1234abcd"
# masked forms stay readable
assert_contains "$(cat "$EX/bench.log.tail")" "token=***"
assert_contains "$(cat "$EX/bench.log.tail")" "Authorization: ***"
assert_contains "$(cat "$EX/bench.log.tail")" '"password": "***"'
assert_contains "$(cat "$EX/worker.error.log.tail")" "db_password = ***"
# the tail is 200 lines plus its heading
assert_eq "201" "$(wc -l <"$EX/bench.log.tail" | tr -d ' ')"
assert_contains "$(cat "$EX/bench.log.tail")" "line 300 from"
assert_not_contains "$(cat "$EX/bench.log.tail")" "line 100 from"
# REDACTIONS.txt says what happened
red="$(cat "$EX/REDACTIONS.txt")"
assert_contains "$red" "masked credential-like values"
assert_contains "$red" "bench.log.tail:"
assert_contains "$red" "replaced the home folder with ~"
# versions and JSON
ver="$(cat "$EX/versions.txt")"
assert_contains "$ver" "benchbar CLI: 0.3.0"
assert_contains "$ver" "BenchBar app: 0.3.0"
assert_contains "$ver" "frappe: 15.50.1"
assert_contains "$ver" "erpnext: 15.48.0"
assert_contains "$ver" "## macOS"
assert_contains "$ver" "ProductVersion"
assert_contains "$ver" "## Homebrew"
assert_eq "1" "$(jget "$EX/doctor.json" 'd["schema_version"]')"
assert_eq "stopped" "$(jget "$EX/status.json" 'd["state"]')"
assert_contains "$(cat "$EX/launchctl.txt")" "com.benchbar.frappe-bench"
assert_contains "$(cat "$EX/agent.plist")" "<key>Label</key>"

# ---- --print writes nothing and shows every section
count_files() { find "$1" -type f | wc -l | tr -d ' '; }
before="$(count_files "$OUTDIR")"
run_fm report --bench-dir "$BENCH" --out "$OUTDIR" --print
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "===== doctor.json ====="
assert_contains "$OUT" "===== REDACTIONS.txt ====="
assert_not_contains "$OUT" "$DB_PW"
assert_eq "$before" "$(count_files "$OUTDIR")" "(--print must not write a zip)"

# ---- default location is the Desktop
mkdir -p "$HOME/Desktop"
run_fm report --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
[[ -n "$(ls "$HOME"/Desktop/benchbar-report-*.zip 2>/dev/null)" ]] || fail "default report goes to ~/Desktop"

# ---- no bench: still a report with versions
run_fm report --bench-dir "$HOME/nothing-here" --print
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "no bench at"
assert_contains "$OUT" "benchbar CLI: 0.3.0"

run_fm report --bench-dir "$BENCH" --bogus
assert_eq "1" "$CODE"
assert_contains "$OUT" "Unknown report option"

printf 'test-report: ok\n'
