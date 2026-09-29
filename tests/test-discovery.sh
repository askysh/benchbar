#!/usr/bin/env bash
# Discovery must find nested benches without modifying or adopting them.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

SCAN="$HOME/Developer projects"
FIRST="$SCAN/Client A/frappe-bench"
SECOND="$SCAN/Client B/deep/frappe-bench"
make_fake_bench "$FIRST" first.local
make_fake_bench "$SECOND" second.local
make_fake_bench "$SCAN/node_modules/ignored"
make_fake_bench "$SCAN/.hidden/ignored"
make_fake_bench "$SCAN/tests/fixtures/ignored"
ln -s "$FIRST" "$SCAN/alias"
ln -s "$SCAN" "$SCAN/loop"
# A common_site_config DocType/file alone is not an installed bench.
mkdir -p "$SCAN/not-a-bench"
printf '{}' >"$SCAN/not-a-bench/common_site_config.json"

before="$(snapshot "$SCAN")"
run_fm scan "$SCAN" --json
assert_eq 0 "$CODE" "$OUT"
assert_eq 2 "$(printf '%s' "$OUT" | jget - 'len(d["benches"])')"
assert_eq "$FIRST" "$(printf '%s' "$OUT" | jget - 'd["benches"][0]["path"]')"
assert_eq first.local "$(printf '%s' "$OUT" | jget - 'd["benches"][0]["site"]')"
assert_eq False "$(printf '%s' "$OUT" | jget - 'any(x["service_installed"] for x in d["benches"])')"
assert_eq "$before" "$(snapshot "$SCAN")"
assert_no_file "$FIRST/Procfile.lean"
assert_no_file "$FL_STATE_DIR/registered-benches.txt"
assert_calls_not_contain '^(bench |launchctl |sudo |security )'

run_fm scan "$FIRST" --json
assert_eq 0 "$CODE" "$OUT"
assert_eq 1 "$(printf '%s' "$OUT" | jget - 'len(d["benches"])')"
# a folder named dev under ~ is scanned; only the system /dev is skipped
mkdir -p "$HOME/devscan"
make_fake_bench "$HOME/devscan/dev/frappe-bench" dev.local
make_fake_bench "$HOME/devscan/Library/ignored"
run_fm scan "$HOME/devscan" --json
assert_eq 0 "$CODE" "$OUT"
assert_eq "$HOME/devscan/dev/frappe-bench" "$(printf '%s' "$OUT" | jget - '" ".join(x["path"] for x in d["benches"])')"
mkdir -p "$HOME/empty"
run_fm scan "$HOME/empty" --json
assert_eq 0 "$CODE" "$OUT"
assert_eq 0 "$(printf '%s' "$OUT" | jget - 'len(d["benches"])')"
run_fm scan "$HOME/missing" --json
assert_eq 1 "$CODE"
assert_contains "$OUT" 'not a readable folder'

# Registration persists across CLI runs, deduplicates symlinks, changes no bench.
run_fm register "$FIRST" "$SECOND" --dry-run
assert_eq 0 "$CODE" "$OUT"
assert_no_file "$FL_STATE_DIR/registered-benches.txt"
run_fm register "$FIRST" "$SECOND" "$SCAN/alias" --json
assert_eq 0 "$CODE" "$OUT"
run_fm list --json
assert_eq 2 "$(printf '%s' "$OUT" | jget - 'len(d["benches"])')"
assert_eq "$before" "$(snapshot "$SCAN")"
assert_eq 2 "$(printf '%s' "$OUT" | jget - 'len(set(x["label"] for x in d["benches"]))')" 'same-name benches must not share an agent'
assert_no_file "$FIRST/Procfile.lean"
registry_before="$(snapshot "$FL_STATE_DIR/registered-benches.txt")"
run_fm register "$FIRST" --json
assert_eq 0 "$CODE" "$OUT"
assert_eq "$registry_before" "$(snapshot "$FL_STATE_DIR/registered-benches.txt")"
# Validate every argument before any write.
run_fm register "$HOME/missing" --json
assert_eq 1 "$CODE"
assert_eq "$registry_before" "$(snapshot "$FL_STATE_DIR/registered-benches.txt")"
# Restore permissions before asserting, so fixture cleanup works on failures.
mkdir -p "$SCAN/unreadable"
chmod 000 "$SCAN/unreadable"
expect_warning=0; [[ -r "$SCAN/unreadable" ]] || expect_warning=1
run_fm scan "$SCAN" --json
chmod 700 "$SCAN/unreadable"
assert_eq 0 "$CODE" "$OUT"
assert_eq "$expect_warning" "$(printf '%s' "$OUT" | jget - 'len(d["warnings"])')"
# Helpers must preserve a filesystem root and recognize path-hashed services.
. "$ROOT/lib/frappe-local/state.sh"
. "$ROOT/lib/frappe-local/benchinfo.sh"
. "$ROOT/lib/frappe-local/launchd.sh"
. "$ROOT/lib/frappe-local/ports.sh"
assert_eq / "$(fl_abs_path /)" 'a root scan must not scan the working directory'
label="com.benchbar.frappe-bench-$(printf '%s' "$SECOND" | cksum | awk '{printf "%08x", $1}')"
cat >"$HOME/Library/LaunchAgents/$label.plist" <<PLIST
<plist><dict><key>WorkingDirectory</key><string>${SECOND}</string></dict></plist>
PLIST
fl_bench_established "$SECOND" || fail 'a stopped hashed-label bench still reserves its ports'
if fl_bench_established "$FIRST"; then fail 'same folder name is not service ownership'; fi
printf 'test-discovery: ok\n'
