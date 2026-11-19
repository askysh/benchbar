#!/usr/bin/env bash
# The readiness contract: status --json "ready" (agent, processes, web with a
# 2xx or 3xx, socketio, redis, and with --deep workers and stale code) and
# `benchbar wait`. The mocks give the agent, the processes (pgrep, lsof) and
# the site's ping (curl); socketio and Redis are bash's own /dev/tcp probes,
# so this test brings real listeners on free ports.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

PIDS=()
cleanup() {
  local p
  for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null || true; { wait "$p"; } 2>/dev/null || true; done
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cat >"$TMP_DIR/listen.py" <<'PY'
import socket, sys
if sys.argv[1] == "ports":
    out = []
    for _ in range(3):
        s = socket.socket(); s.bind(("127.0.0.1", 0)); out.append(s.getsockname()[1]); s.close()
    print(*out)
else:
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(5)
    while True:
        c, _ = s.accept(); c.close()
PY
read -r SIO QUEUE CACHE < <(python3 "$TMP_DIR/listen.py" ports)
wait_port() { local i=0; while ! ( exec 9<>"/dev/tcp/127.0.0.1/$1" ) 2>/dev/null; do i=$((i + 1)); [[ "$i" -lt 100 ]] || fail "nothing listens on $1"; sleep 0.1; done; }

BENCH="$HOME/work/a/frappe-bench"
make_fake_bench "$BENCH" macdev
sed_inplace "s/\"socketio_port\": 9000/\"socketio_port\": ${SIO}/; s#redis://127.0.0.1:13000#redis://127.0.0.1:${CACHE}#; s#redis://127.0.0.1:11000#redis://127.0.0.1:${QUEUE}#" "$BENCH/sites/common_site_config.json"
printf '127.0.0.1 macdev\n' >>"$FL_HOSTS_FILE"
run_fm register "$BENCH"
assert_eq "0" "$CODE" "$OUT"
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
label="$("$FM" status --json --bench-dir "$BENCH" 2>/dev/null | jget - 'd["label"]')"
export FL_LOCAL_PROBES=1
export MOCK_CURL_CODE=000

# json_of ARGS...: stdout only (the text of a --json run goes to stderr)
json_of() { set +e; OUT="$("$FM" "$@" 2>/dev/null)"; CODE="$?"; set -e; }
ready_of() { printf '%s' "$OUT" | jget - "$1"; }
write_state() {
  mkdir -p "$BENCH/logs/.benchbar"
  printf '{"schema_version":1,"cli_version":"%s","bench":"%s","name":"frappe-bench","site":"macdev","label":"%s","state":"%s","stop_reason":null,"pid":%s,"started_at":"2026-09-30T05:00:00Z","last_exit_code":null,"web_url":"http://macdev:8000","web_ping_code":200,"updated_at":"2026-09-30T05:00:04Z","source":"runner"}\n' \
    "$("$FM" --version | awk '{print $NF}')" "$BENCH" "$label" "$1" "$2" >"$BENCH/logs/.benchbar/state.json"
}
# touch_py FILE HHMM: the file's mtime on 2026-09-30 (UTC); the bench started at 05:00
touch_py() { mkdir -p "$(dirname "$1")"; TZ=UTC touch -t "20260930$2.00" "$1"; }
drop_file() { local f; for f in "$@"; do rm -f "$f"; done; }

# ---- nothing runs: not ready, and the fix says how to start
json_of status --json --bench-dir "$BENCH"
assert_eq "0" "$CODE"
assert_eq "False False" "$(ready_of 'str(d["ready"]["ready"]) + " " + str(d["ready"]["processes"])')"
assert_eq "processes web socketio redis" "$(ready_of '" ".join(d["ready"]["waiting_on"])')" "(workers and stale are not asked without --deep)"
assert_contains "$(ready_of 'd["ready"]["fix"]')" "up --bench-dir ${BENCH}"

# ---- running under its agent: the runner, honcho, web, socketio, a worker, Redis
drop_file "$BENCH/logs/.bench-stopped"
set_agent "$label" running 4241 0
add_proc 4241 "/bin/bash $BENCH/benchbar-run.sh" "$BENCH"
add_proc 4242 "honcho start -f Procfile.lean" "$BENCH"
add_proc 4243 "/usr/bin/python -m frappe.utils.bench_helper frappe serve --port 8000 --noreload" "$BENCH/sites"
add_proc 4244 "node apps/frappe/socketio.js" "$BENCH"
add_proc 4247 "/usr/bin/python -m frappe.utils.bench_helper frappe worker" "$BENCH/sites"
write_state running 4241
python3 "$TMP_DIR/listen.py" "$SIO" & PIDS+=("$!")
python3 "$TMP_DIR/listen.py" "$QUEUE" & PIDS+=("$!")
python3 "$TMP_DIR/listen.py" "$CACHE" & PIDS+=("$!")
wait_port "$SIO"; wait_port "$QUEUE"; wait_port "$CACHE"
export MOCK_CURL_CODE=200
touch_py "$BENCH/apps/erpnext/erpnext/hooks.py" 0400

reset_calls
json_of status --json --bench-dir "$BENCH"
assert_eq "True True True True True True" "$(ready_of '" ".join(str(x) for x in (d["ready"]["ready"], d["ready"]["agent"], d["ready"]["processes"], d["ready"]["web"], d["ready"]["socketio"], d["ready"]["redis"]))')"
assert_eq "None None None []" "$(ready_of '" ".join(str(x) for x in (d["ready"]["workers"], d["ready"]["stale"], d["ready"]["fix"], d["ready"]["waiting_on"]))')"
# the fast path starts no program the status did not already start
assert_calls_not_contain '^(pgrep|lsof|find|ps)( |$)'

# ---- --deep asks the workers and the code: nothing changed since the start
json_of status --json --deep --bench-dir "$BENCH"
assert_eq "True True False None" "$(ready_of '" ".join(str(x) for x in (d["ready"]["ready"], d["ready"]["workers"], d["ready"]["stale"], d["ready"]["stale_file"]))')"
# a Python file changed after the start: the code that runs is old
touch_py "$BENCH/apps/erpnext/erpnext/new_module.py" 0600
json_of status --json --deep --bench-dir "$BENCH"
assert_eq "False True apps/erpnext/erpnext/new_module.py stale" "$(ready_of '" ".join(str(x) for x in (d["ready"]["ready"], d["ready"]["stale"], d["ready"]["stale_file"], " ".join(d["ready"]["waiting_on"])))')"
assert_contains "$(ready_of 'd["ready"]["fix"]')" "restart --bench-dir ${BENCH}"
# a file in node_modules or a cache never counts
drop_file "$BENCH/apps/erpnext/erpnext/new_module.py"
touch_py "$BENCH/apps/frappe/node_modules/x/lib.py" 0600
touch_py "$BENCH/apps/erpnext/erpnext/__pycache__/m.py" 0600
json_of status --json --deep --bench-dir "$BENCH"
assert_eq "False" "$(ready_of 'd["ready"]["stale"]')"
# a worker that is gone
grep -v '^4247 ' "$MOCK_PROCS" >"$MOCK_STATE/procs.tmp" || true
cp "$MOCK_STATE/procs.tmp" "$MOCK_PROCS"
json_of status --json --deep --bench-dir "$BENCH"
assert_eq "False False workers" "$(ready_of '" ".join(str(x) for x in (d["ready"]["ready"], d["ready"]["workers"], " ".join(d["ready"]["waiting_on"])))')"
add_proc 4247 "/usr/bin/python -m frappe.utils.bench_helper frappe worker" "$BENCH/sites"

# ---- the text status says it too
run_fm status --bench-dir "$BENCH"
assert_contains "$OUT" "ready"

# ---- wait: ready at once
json_of wait --json --timeout 5 --bench-dir "$BENCH"
assert_eq "0" "$CODE"
assert_eq "ready True False 0 []" "$(ready_of '" ".join(str(x) for x in (d["for"], d["satisfied"], d["timed_out"], d["exit"], d["waiting_on"]))')"
assert_eq "True True False" "$(ready_of '" ".join(str(x) for x in (d["ready"]["ready"], d["ready"]["workers"], d["ready"]["stale"]))')" "(wait asks the deep parts)"
run_fm wait --timeout 5 --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "is ready"

# ---- wait: the code changed, so the bench is not ready, and one part still is
touch_py "$BENCH/apps/erpnext/erpnext/new_module.py" 0600
json_of wait --json --timeout 0 --bench-dir "$BENCH"
assert_eq "1" "$CODE"
assert_eq "False True 1 ['stale']" "$(ready_of '" ".join(str(x) for x in (d["satisfied"], d["timed_out"], d["exit"], d["waiting_on"]))')"
assert_contains "$(ready_of 'd["next_actions"][0]["command"]')" "restart"
run_fm wait --timeout 0 --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "waiting on: stale"
assert_contains "$OUT" "new_module.py"
json_of wait --json --for web --timeout 0 --bench-dir "$BENCH"
assert_eq "0" "$CODE"
assert_eq "web True" "$(ready_of 'd["for"] + " " + str(d["satisfied"])')"
drop_file "$BENCH/apps/erpnext/erpnext/new_module.py"

# ---- the ping decides web: 2xx and 3xx pass, 4xx and 5xx do not
for c in 204 302; do
  export MOCK_CURL_CODE="$c"
  json_of wait --json --for web --timeout 0 --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "ping $c"
done
for c in 404 500 000; do
  export MOCK_CURL_CODE="$c"
  json_of wait --json --for web --timeout 0 --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "ping $c"
  assert_eq "['web']" "$(ready_of 'str(d["waiting_on"])')"
done

# ---- wait blocks until the site answers
export MOCK_CURL_CODE=000
( sleep 2; printf '200' >"$MOCK_STATE/curl_code" ) &
PIDS+=("$!")
json_of wait --json --timeout 30 --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "True" "$(ready_of 'str(d["waited_s"] >= 1 and d["waited_s"] < 20)')" "(it waited, and not for the whole timeout)"
drop_file "$MOCK_STATE/curl_code"
export MOCK_CURL_CODE=200

# ---- a bench that cannot start by itself is not waited for
: >"$MOCK_PROCS"
drop_file "$MOCK_STATE/agents/$label" "$BENCH/logs/.benchbar/state.json"
printf 'crash\n' >"$BENCH/logs/.bench-stopped"
start="$SECONDS"
json_of wait --json --timeout 30 --bench-dir "$BENCH"
assert_eq "1" "$CODE"
[[ $((SECONDS - start)) -lt 15 ]] || fail "wait on a paused bench waited for its whole timeout"
assert_contains "$(ready_of 'd["ready"]["fix"]')" "doctor --bench-dir ${BENCH}"
# a stopped bench is waited for: someone may be starting it
drop_file "$BENCH/logs/.bench-stopped"
json_of wait --json --timeout 1 --bench-dir "$BENCH"
assert_eq "1" "$CODE"
assert_eq "True" "$(ready_of 'str(d["timed_out"])')"

# ---- bad arguments are refused before anything is asked
run_fm wait --for nonsense --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "unknown part nonsense"
run_fm wait --timeout soon --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "whole seconds"
run_fm wait --frobnicate --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "Unknown argument for wait"

printf 'test-ready: ok\n'
