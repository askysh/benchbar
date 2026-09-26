#!/usr/bin/env bash
# benchbar docs, the docs URL at the end of --help, the app version in
# --version, and the "see:" line doctor prints under a [FAIL].
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

DOCS="https://benchbar.akashmishra.com"

# ---- --help ends with the docs URL
run_fm --help; assert_eq "0" "$CODE"
assert_eq "Documentation: ${DOCS}/" "$(printf '%s\n' "$OUT" | tail -n 1)"
assert_contains "$OUT" "docs [TOPIC]"

# ---- --version: the first line as before; the app only when installed
run_fm --version; assert_eq "0" "$CODE"; assert_eq "benchbar ${VER}" "$OUT" "(no app installed: one line)"
mkdir -p "$HOME/Applications/BenchBar.app/Contents"
printf '<plist><dict>\n<key>CFBundleShortVersionString</key>\n<string>0.5.5</string>\n</dict></plist>\n' >"$HOME/Applications/BenchBar.app/Contents/Info.plist"
run_fm --version; assert_eq "0" "$CODE"
assert_eq "benchbar ${VER}" "$(printf '%s\n' "$OUT" | head -n 1)" "(the first line never changes)"
assert_eq "BenchBar app 0.5.5 (${HOME}/Applications/BenchBar.app)" "$(printf '%s\n' "$OUT" | sed -n 2p)"

# ---- docs: opens the site, or a topic's page, after a HEAD check
reset_calls
MOCK_CURL_CODE=200 run_fm docs; assert_eq "0" "$CODE" "$OUT"
assert_calls_contain "^curl .*-I .*--max-time 3 .*${DOCS}/$"
assert_calls_contain "^open ${DOCS}/$"

reset_calls
MOCK_CURL_CODE=200 run_fm docs doctor; assert_eq "0" "$CODE" "$OUT"
assert_calls_contain "^open ${DOCS}/guides/doctor-and-repair/$"
assert_contains "$OUT" "${DOCS}/guides/doctor-and-repair/"

# every topic maps to one of the fixed pages
for pair in install:/install/ quick-start:/quick-start/ app:/app/ sites:/guides/benches-and-sites/ apps:/guides/apps/ \
  teams:/guides/teams/ agents:/guides/agents/ mcp:/reference/cli/mcp/ cli:/reference/cli/install/ json:/json-schema/ \
  runners:/runners/ troubleshooting:/troubleshooting/ config:/reference/configuration/ MCP:/reference/cli/mcp/; do
  run_fm docs "${pair%%:*}" --print; assert_eq "0" "$CODE" "$OUT"
  assert_eq "${DOCS}${pair#*:}" "$OUT" "(topic ${pair%%:*})"
done

# --print never opens and never asks the network
reset_calls
run_fm docs --print; assert_eq "${DOCS}/" "$OUT"
assert_calls_not_contain '^(open|curl) '

# a page that is not there (404) opens the start page instead
reset_calls
MOCK_CURL_CODE=404 run_fm docs apps; assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "is not there (404)"
assert_calls_contain "^open ${DOCS}/$"
assert_calls_not_contain "^open ${DOCS}/guides/apps/"

# no answer at all (offline): the page opens anyway
reset_calls
MOCK_CURL_CODE=000 run_fm docs apps; assert_eq "0" "$CODE" "$OUT"
assert_calls_contain "^open ${DOCS}/guides/apps/$"

# unknown topics and options list what exists
reset_calls
run_fm docs nonsense; assert_eq "1" "$CODE"
assert_contains "$OUT" "Unknown docs topic: nonsense"
assert_contains "$OUT" "troubleshooting"
assert_calls_not_contain '^open '
run_fm docs --help; assert_eq "0" "$CODE"
assert_contains "$OUT" "Usage: benchbar docs [TOPIC]"
assert_contains "$OUT" "quick-start, start"
run_fm docs a b; assert_eq "1" "$CODE"; assert_contains "$OUT" "one topic"
run_fm docs --bogus; assert_eq "1" "$CODE"; assert_contains "$OUT" "Unknown docs option"

# a failing open says so
MOCK_OPEN_EXIT=1 MOCK_CURL_CODE=200 run_fm docs; assert_eq "1" "$CODE"; assert_contains "$OUT" "could not open"

# ---- doctor: a [FAIL] gets a see: line after its fix: line, only in text
BENCH="$HOME/frappe-bench"
make_fake_bench "$BENCH"
run_fm service --yes --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
mv "$BENCH/env" "$BENCH/env.gone"
run_fm doctor --bench-dir "$BENCH"; assert_eq "1" "$CODE"
block="$(printf '%s\n' "$OUT" | grep -A2 '^  \[FAIL\] Bench env:')"
assert_eq "     fix: ${SCRIPT_DIR}/benchbar repair" "$(printf '%s\n' "$block" | sed -n 2p | sed 's/ (.*//')"
assert_eq "     see: ${DOCS}/guides/doctor-and-repair/#env_python" "$(printf '%s\n' "$block" | sed -n 3p)"
# [WARN] lines have no see: line
printf '%s\n' "$OUT" | grep -A2 '^  \[WARN\]' | grep -q 'see:' && fail "a [WARN] must not get a see: line"
# every see: follows a fix: line or a [FAIL] line
printf '%s\n' "$OUT" | awk '/see:/ && prev !~ /fix:|\[FAIL\]/ { bad = 1 } { prev = $0 } END { exit bad }' || fail "see: must follow fix: or [FAIL]"
run_fm doctor --json --bench-dir "$BENCH"; assert_eq "1" "$CODE"
assert_not_contains "$OUT" "see:"
assert_not_contains "$OUT" "benchbar.akashmishra.com"
mv "$BENCH/env.gone" "$BENCH/env"

printf 'test-docs: ok\n'
