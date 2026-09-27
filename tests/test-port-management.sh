#!/usr/bin/env bash
# Batch previews are read-only, approval is stale-safe, and stopped benches
# retain reservations. All actions run in the harness's isolated fake HOME.
# shellcheck disable=SC2329 # overridden callbacks are invoked by the sourced apply function
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
A="$HOME/Client A/frappe-bench"
B="$HOME/Client B/frappe-bench"
make_fake_bench "$A" alpha
make_fake_bench "$B" beta
printf '127.0.0.1 alpha\n127.0.0.1 beta\n' >>"$FL_HOSTS_FILE"
run_fm register "$A" "$B"
assert_eq 0 "$CODE" "$OUT"
# A conflicting early selection must not steal a later valid current block.
sed_inplace 's/8000/8001/; s/9000/9001/; s/11000/11001/; s/13000/13001/' "$B/sites/common_site_config.json"
add_listener 8000 9998 ForeignApp
run_fm ports plan --json -- "$A" "$B"
assert_eq '8002 8001' "$(printf '%s' "$OUT" | jget - '" ".join(str(x["proposed"]["web"]) for x in d["entries"])')"
sed_inplace 's/8001/8000/; s/9001/9000/; s/11001/11000/; s/13001/13000/' "$B/sites/common_site_config.json"
printf '3306 111 mariadbd 127.0.0.1\n' >"$MOCK_LISTEN"
before="$(snapshot "$A" "$B")"
run_fm ports plan --json -- "$B" "$A" "$A"
assert_eq 0 "$CODE" "$OUT"
assert_eq 2 "$(printf '%s' "$OUT" | jget - 'len(d["entries"])')"
assert_eq '8000 8001' "$(printf '%s' "$OUT" | jget - '" ".join(str(x["proposed"]["web"]) for x in d["entries"])')"
assert_eq True "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')"
token="$(printf '%s' "$OUT" | jget - 'd["token"]')"
assert_eq "$before" "$(snapshot "$A" "$B")"
run_fm ports plan --json -- "$A" "$B"
assert_eq "$token" "$(printf '%s' "$OUT" | jget - 'd["token"]')"
# Whole plan must become blocked if a fixed bench's current ports conflict.
run_fm ports mode fixed --bench-dir "$A"
run_fm ports mode fixed --bench-dir "$B"
run_fm ports plan --json -- "$A" "$B"
assert_eq False "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')"
run_fm ports apply "$token" --yes -- "$A" "$B"
assert_eq 1 "$CODE"
assert_contains "$OUT" 'plan changed'
assert_eq "$before" "$(snapshot "$A" "$B")"
run_fm ports mode automatic --bench-dir "$A"
run_fm ports mode automatic --bench-dir "$B"
# New listener invalidates an otherwise valid approval.
run_fm ports plan --json -- "$A" "$B"
token="$(printf '%s' "$OUT" | jget - 'd["token"]')"
add_listener 8001 9999 OtherApp
run_fm ports apply "$token" --yes -- "$A" "$B"
assert_eq 1 "$CODE"
assert_contains "$OUT" 'plan changed'
printf '3306 111 mariadbd 127.0.0.1\n' >"$MOCK_LISTEN"
run_fm ports plan --json -- "$A" "$B"
token="$(printf '%s' "$OUT" | jget - 'd["token"]')"
run_fm ports apply "$token" --yes -- "$A" "$B"
assert_eq 0 "$CODE" "$OUT"
assert_eq 8001 "$(jget "$B/sites/common_site_config.json" 'd["webserver_port"]')"
assert_calls_not_contain '^bench (migrate|build|update|start)'
# Repeating an approved successful batch changes no files or ports.
run_fm ports plan --json -- "$A" "$B"
token="$(printf '%s' "$OUT" | jget - 'd["token"]')"
reset_calls
run_fm ports apply "$token" --yes -- "$A" "$B"
assert_eq 0 "$CODE" "$OUT"
assert_calls_not_contain '^bench set-config'
# A positively identified process blocks setup; a foreign listener does not.
add_proc 12345 "honcho start -f Procfile.lean" "$A"
run_fm ports plan --json -- "$A"
assert_eq False "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')"
assert_contains "$OUT" 'Stop this bench'
: >"$MOCK_PROCS"
# Stopped services continue to reserve their own block.
C="$HOME/Client C/third"; make_fake_bench "$C" gamma
run_fm register "$C"
run_fm ports plan --json -- "$C"
assert_eq 8002 "$(printf '%s' "$OUT" | jget - 'd["entries"][0]["proposed"]["web"]')"
# An unmanaged duplicate never prevents an established bench from starting.
run_fm ports check --json --bench-dir "$A"
assert_eq 0 "$(printf '%s' "$OUT" | jget - 'len(d["conflicts"])')"
run_fm ports plan --json -- "$A"
assert_eq 8000 "$(printf '%s' "$OUT" | jget - 'd["entries"][0]["proposed"]["web"]')"
# Insufficient space is an explicit blocked plan, never an arbitrary port.
export FL_PORT_MAX_OFFSET=1
run_fm ports plan --json -- "$C"
assert_eq False "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')"
assert_contains "$OUT" 'No free port block'
unset FL_PORT_MAX_OFFSET
# Start checks include stopped reservations and unknown listener ownership.
run_fm ports check --json --bench-dir "$C"
assert_eq True "$(printf '%s' "$OUT" | jget - 'len(d["conflicts"]) > 0')"
add_listener 8001 9999 OtherApp
run_fm up --bench-dir "$B" --yes
assert_eq 1 "$CODE"
assert_contains "$OUT" 'Cannot start'
assert_not_contains "$OUT" 'Start anyway'
reset_calls
run_fm restart --bench-dir "$B" --yes
assert_eq 1 "$CODE"
assert_contains "$OUT" 'Cannot start'
assert_calls_not_contain '^launchctl (kickstart|kill|bootout)'
run_fm fg --bench-dir "$B" --yes
assert_eq 1 "$CODE"
assert_contains "$OUT" 'Cannot start'
assert_calls_not_contain '^(launchctl (kickstart|kill|bootout)|mockkill|pkill)'
# A failed second action stops the batch and never records success for it.
# Stub the adoption boundary so this is deterministic, independent of launchd.
(
  . "$ROOT/lib/frappe-local/port-management.sh"
  FL_ASSUME_YES=1; FL_HONCHO=honcho
  fl_pm_build() { PM_PATHS=(first second third); PM_TARGETS=('8000 9000 11000 13000' '8000 9000 11000 13000' '8000 9000 11000 13000'); PM_TOKEN=approved; PM_CAN_APPLY=1; }
  fl_bench_load() { FL_BENCH_DIR="$1"; FL_WEB_PORT=8000; FL_SOCKETIO_PORT=9000; FL_REDIS_QUEUE_PORT=11000; FL_REDIS_CACHE_PORT=13000; }
  fl_context_init() { :; }
  fl_pm_running() { return 1; }
  fl_pm_conflicts() { :; }
  fl_pm_mode() { printf automatic; }
  fl_bstate_set() { :; }
  fl_info() { :; }; fl_ok() { :; }; fl_fail() { printf '%s\n' "$*"; }
  fl_cmd_register() { printf '%s\n' "$1" >>"$TMP_DIR/completed"; }
  cmd_adopt() { printf '%s\n' "$1" >>"$TMP_DIR/attempted"; [[ "$1" != second ]]; }
  if fl_cmd_ports apply approved first second third >"$TMP_DIR/partial-output"; then fail 'partial failure must fail the command'; fi
  assert_eq $'first\nsecond' "$(cat "$TMP_DIR/attempted")"
  assert_eq first "$(cat "$TMP_DIR/completed")"
  assert_contains "$(cat "$TMP_DIR/partial-output")" 'Earlier completed benches remain configured'
)
printf 'test-port-management: ok\n'
