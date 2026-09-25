#!/usr/bin/env bash
# Port blocks: a second bench gets the next free block (8001 and friends),
# written with bench set-config and bench setup redis; --port-offset picks
# one; a taken block is refused; the first bench is never touched.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

A="$HOME/frappe-bench"
B="$HOME/dev/v16-bench"
C="$HOME/dev/third"
make_fake_bench "$A" macdev
make_fake_bench "$B" v16dev
make_fake_bench "$C" third
printf '127.0.0.1 macdev\n127.0.0.1 v16dev\n127.0.0.1 third\n' >>"$FL_HOSTS_FILE"
run_fm adopt "$A" --yes
assert_eq "0" "$CODE" "$OUT"
cfg() { jget "$1/sites/common_site_config.json" "d.get('$2')"; }

# ---- doctor sees B set up with A's ports (not running: still a warning)
run_fm doctor --bench-dir "$B"
assert_contains "$OUT" "[WARN] Port clash: another bench is set up with the same ports"
assert_contains "$OUT" "benchbar service --port-offset 1 --bench-dir ${B}"

# ---- adopt B: dry run changes nothing
snapA="$(snapshot "$A")"; snapB="$(snapshot "$B/sites" "$B/config")"
reset_calls
run_fm adopt "$B" --dry-run
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "dry-run: cd ${B} && bench set-config -g -p webserver_port 8001"
assert_calls_not_contain '^bench (set-config|setup redis)'
assert_eq "$snapB" "$(snapshot "$B/sites" "$B/config")"

# ---- adopt B: moves to block 1 with bench's own commands
run_fm adopt "$B" --yes
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^bench set-config -g -p webserver_port 8001$'
assert_calls_contain '^bench set-config -g -p socketio_port 9001$'
assert_calls_contain '^bench set-config -g redis_queue redis://127.0.0.1:11001$'
assert_calls_contain '^bench set-config -g redis_cache redis://127.0.0.1:13001$'
assert_calls_contain '^bench set-config -g redis_socketio redis://127.0.0.1:13001$'
assert_calls_contain '^bench setup redis$'
assert_eq "8001" "$(cfg "$B" webserver_port)"
assert_eq "redis://127.0.0.1:11001" "$(cfg "$B" redis_queue)"
grep -q 'port 11001' "$B/config/redis_queue.conf" || fail "redis config regenerated"
grep -q 'bench serve --port 8001' "$B/Procfile.lean" || fail "Procfile.lean uses the new port"
grep -q 'PORTS="8001,9001,11001,13001"' "$B/benchbar-run.sh" || fail "the runner uses the new ports"
assert_eq "$snapA" "$(snapshot "$A")" "(the first bench is never touched)"
assert_eq "1" "$(sed -n 's/^PORT_OFFSET=//p' "$FL_STATE_DIR/benches/v16-bench.env")"
run_fm list --json
assert_eq "8000 8001 8000" "$(printf '%s' "$OUT" | jget - '" ".join(str(b["ports"]["web"]) for b in d["benches"])')"
assert_eq "13001" "$(printf '%s' "$OUT" | jget - '[b for b in d["benches"] if b["name"]=="v16-bench"][0]["ports"]["redis_socketio"]')"
run_fm status --json --bench-dir "$B"
assert_eq "{'web': 8001, 'socketio': 9001, 'redis_queue': 11001, 'redis_socketio': 13001, 'redis_cache': 13001}" "$(printf '%s' "$OUT" | jget - 'd["ports"]')"
assert_eq "http://v16dev:8001" "$(printf '%s' "$OUT" | jget - 'd["web_url"]')"
run_fm doctor --bench-dir "$B"
assert_contains "$OUT" "[OK] Port clash: no other benchbar bench uses 8001, 9001, 11001 or 13001"

# ---- a second adopt is a no-op for the ports
reset_calls
run_fm adopt "$B" --yes
assert_calls_not_contain '^bench set-config'

# ---- C: block 1 is B's, a foreign listener sits on 8002, so C gets block 3
add_listener 8002 7777 SomeApp
run_fm adopt "$C" --yes
assert_eq "0" "$CODE" "$OUT"
assert_eq "8003" "$(cfg "$C" webserver_port)"

# ---- --port-offset: a taken block is refused, a free one is used
reset_calls
run_fm service --port-offset 0 --bench-dir "$C"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "port block 0 is not free: 8000 used by ${A}"
assert_calls_not_contain '^bench set-config'
run_fm service --port-offset abc --bench-dir "$C"
assert_eq "1" "$CODE"
snapC="$(snapshot "$C/sites")"
run_fm service --dry-run --port-offset 5 --bench-dir "$C"
assert_eq "$snapC" "$(snapshot "$C/sites")" "(dry run)"
run_fm service --yes --port-offset 5 --bench-dir "$C"
assert_eq "0" "$CODE" "$OUT"
assert_eq "8005" "$(cfg "$C" webserver_port)"
run_fm service --yes --port-offset 5 --bench-dir "$C"
assert_contains "$OUT" "ports already use block 5"

# ---- up asks only about a running clash, not a configured one
cp "$A/sites/common_site_config.json" "$TMP_DIR/a.json"
cp "$B/sites/common_site_config.json" "$A/sites/common_site_config.json"
run_fm up --bench-dir "$A"
assert_not_contains "$OUT" "Start anyway?"
cp "$TMP_DIR/a.json" "$A/sites/common_site_config.json"

printf 'test-ports: ok\n'
