#!/usr/bin/env bash
# up --services-only (the bench's Redis and nothing else), and what status and
# doctor say about it: status --json redis, sites[].served, and the doctor
# check site_not_served. The status probes are bash's own /dev/tcp (no program
# starts), so the tests that look at them bring real listeners on free ports.
# Run on the macOS platform and again as Linux (use_linux).
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

PIDS=()
cleanup() {
  local p
  for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# the listeners: a web server that answers 200 for the hosts it is given and
# 404 for any other, writing every Host it was asked about to a file, and
# plain listeners for the Redis ports
cat >"$TMP_DIR/listeners.py" <<'PY'
import http.server, socket, sys

def free():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
    return port

mode = sys.argv[1]
if mode == "ports":
    print(free(), free(), free())
elif mode == "web":
    port, hosts, log = int(sys.argv[2]), set(sys.argv[3].split(",")), sys.argv[4]
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            host = (self.headers.get("Host") or "").split(":")[0]
            with open(log, "a") as f:
                f.write(host + "\n")
            try:
                self.send_response(200 if host in hosts else 404)
                self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"ok")
            except OSError:
                pass  # the prober hung up after the status line
        def log_message(self, *a):
            pass
    http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
else:
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", int(sys.argv[2]))); s.listen(5)
    while True:
        conn, _ = s.accept(); conn.close()
PY
read -r WEB QUEUE CACHE < <(python3 "$TMP_DIR/listeners.py" ports)
REQUESTS="$TMP_DIR/requests"
wait_port() {
  local i=0
  until ( exec 9<>"/dev/tcp/127.0.0.1/$1" ) 2>/dev/null; do
    i=$((i + 1)); [[ "$i" -lt 50 ]] || fail "nothing listens on $1"
    sleep 0.1
  done
}
requests() { if [[ -f "$REQUESTS" ]]; then wc -l <"$REQUESTS" | tr -d ' '; else printf 0; fi; }
status_json() { run_fm status --json --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"; }

suite() {
  local tag="$1" n
  BENCH="$HOME/dev/served-$tag"
  make_fake_bench "$BENCH" macdev
  cp "$ROOT/tests/mocks/frappe-python" "$BENCH/env/bin/python"; chmod +x "$BENCH/env/bin/python"
  printf 'port 11000\n' >"$BENCH/config/redis_queue.conf"; printf 'port 13000\n' >"$BENCH/config/redis_cache.conf"
  reset_calls
  : >"$MOCK_PROCS"; sed_inplace '/^1[13]000 /d' "$MOCK_LISTEN"

  # ---- up --services-only: the Redis of the bench and nothing else
  export MOCK_REDIS_PROC=1
  run_fm up --services-only --dry-run --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
  assert_calls_not_contain '^redis-server'
  run_fm up --bogus --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "Unknown option for up: --bogus"
  reset_calls
  run_fm up --services-only --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
  assert_contains "$OUT" "Redis of served-$tag is up (queue 11000, cache 13000); nothing else was started"
  assert_calls_contain '^redis-server config/redis_queue.conf --daemonize yes$'
  assert_calls_contain '^redis-server config/redis_cache.conf --daemonize yes$'
  assert_calls_not_contain '^(launchctl|systemctl|honcho|bench |curl)'
  assert_no_file "$BENCH/logs/.bench-stopped" "(no stop flag: up --services-only starts and stops nothing else)"
  assert_no_file "$BENCH/logs/.benchbar/state.json"
  assert_eq "2" "$(grep -c -E '^1[13]000 ' "$MOCK_LISTEN")" "(both Redis servers listen)"
  # nothing starts twice, and the bench is not "running"
  reset_calls
  run_fm up --services-only --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
  assert_calls_not_contain '^redis-server'
  # down stops it
  run_fm down --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
  assert_eq "" "$(lsof -ti tcp:11000,13000 -sTCP:LISTEN || true)" "(down stops the Redis servers of the bench)"
  rm -f "$BENCH/logs/.bench-stopped"; rm -f "$BENCH/logs/.benchbar/state.json"
  # a running bench has its Redis already
  add_proc 4242 "honcho start -f Procfile.lean" "$BENCH"
  reset_calls
  run_fm up --services-only --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "is running; its Redis is up already"
  assert_calls_not_contain '^redis-server'
  : >"$MOCK_PROCS"
  # another program on the port is not the bench's Redis: refused, never taken over
  add_listener 11000 5110 redis-server; mkdir -p "$MOCK_STATE/cwd"; printf '%s' "$HOME/other-bench" >"$MOCK_STATE/cwd/5110"
  reset_calls
  run_fm up --services-only --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "Port 11000 (config/redis_queue.conf) is held by another process"
  sed_inplace '/^11000 /d' "$MOCK_LISTEN"
  unset MOCK_REDIS_PROC
  : >"$MOCK_PROCS"

  # ---- status: redis and served, from real listeners
  for s in two.localhost ghost.localhost; do
    mkdir -p "$BENCH/sites/$s"; printf '{}\n' >"$BENCH/sites/$s/site_config.json"
  done
  printf '127.0.0.1 macdev two.localhost ghost.localhost\n' >>"$FL_HOSTS_FILE"
  sed_inplace "s/\"webserver_port\": 8000/\"webserver_port\": ${WEB}/; s#redis://127.0.0.1:13000#redis://127.0.0.1:${CACHE}#; s#redis://127.0.0.1:11000#redis://127.0.0.1:${QUEUE}#" "$BENCH/sites/common_site_config.json"
  export FL_LOCAL_PROBES=1
  # nothing listens: the Redis servers are down, a stopped bench has no served answers
  : >"$REQUESTS"
  status_json
  assert_eq "$QUEUE False $CACHE False" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in (d["redis"]["queue"]["port"], d["redis"]["queue"]["running"], d["redis"]["cache"]["port"], d["redis"]["cache"]["running"]))')"
  assert_eq "None None None" "$(printf '%s' "$OUT" | jget - '" ".join(str(s["served"]) for s in d["sites"])')"
  # the listeners come up, the bench does not: Redis is seen, no site is asked
  python3 "$TMP_DIR/listeners.py" web "$WEB" "macdev,two.localhost" "$REQUESTS" & WEB_PID="$!"; PIDS+=("$WEB_PID")
  python3 "$TMP_DIR/listeners.py" redis "$QUEUE" & PIDS+=("$!")
  python3 "$TMP_DIR/listeners.py" redis "$CACHE" & PIDS+=("$!")
  wait_port "$WEB"; wait_port "$QUEUE"; wait_port "$CACHE"
  reset_calls
  status_json
  assert_eq "True True" "$(printf '%s' "$OUT" | jget - 'str(d["redis"]["queue"]["running"]) + " " + str(d["redis"]["cache"]["running"])')"
  assert_eq "None None None" "$(printf '%s' "$OUT" | jget - '" ".join(str(s["served"]) for s in d["sites"])')" "(a stopped bench is never asked)"
  assert_eq "0" "$(requests)" "(no request reached the web port of a stopped bench)"
  assert_calls_not_contain '^curl'
  run_fm status --json --ping --bench-dir "$BENCH"
  assert_eq "None None None" "$(printf '%s' "$OUT" | jget - '" ".join(str(s["served"]) for s in d["sites"])')" "(--ping does not wake a stopped bench either)"
  assert_eq "0" "$(requests)"
  # the bench runs: the default site's ping is reused, the others are asked once, in bash
  add_proc 4242 "honcho start -f Procfile.lean" "$BENCH"
  export MOCK_CURL_CODE=200
  reset_calls
  status_json
  assert_eq "ghost.localhost:False macdev:True two.localhost:True" "$(printf '%s' "$OUT" | jget - '" ".join("%s:%s" % (s["name"], s["served"]) for s in d["sites"])')"
  assert_eq "ghost.localhost
two.localhost" "$(sort "$REQUESTS")" "(the default site is not asked again, the other two once each)"
  assert_eq "1" "$(grep -c '^curl' "$MOCK_LOG")" "(the one ping of the default site is the only program)"
  # --ping asks every site with curl: those answers are reused, no extra request
  : >"$REQUESTS"
  export MOCK_CURL_CODE=404
  reset_calls
  run_fm status --json --ping --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
  assert_eq "ghost.localhost:False macdev:False two.localhost:False" "$(printf '%s' "$OUT" | jget - '" ".join("%s:%s" % (s["name"], s["served"]) for s in d["sites"])')"
  assert_eq "0" "$(requests)" "(status --ping reuses its own answers)"
  export MOCK_CURL_CODE=200
  # site list does not carry the field
  run_fm site list --json --bench-dir "$BENCH"
  assert_eq "False" "$(printf '%s' "$OUT" | jget - '"served" in d["sites"][0]')"

  # ---- doctor: a site the running bench does not serve is a warning, with its fix
  : >"$REQUESTS"
  run_fm doctor --json --bench-dir "$BENCH"
  n="$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"] == "site_not_served"][0]["level"]')"
  assert_eq "warn" "$n" "$OUT"
  assert_eq "site Sites served" "$(printf '%s' "$OUT" | jget - '[c["group"] + " " + c["label"] for c in d["checks"] if c["id"] == "site_not_served"][0]')"
  assert_contains "$OUT" "answers 404 for ghost.localhost"
  assert_contains "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"] == "site_not_served"][0]["fix_command"]')" "restart --bench-dir $BENCH"
  run_fm doctor --bench-dir "$BENCH"
  assert_contains "$OUT" "[WARN] Sites served: the web process on port ${WEB} answers 404 for ghost.localhost"
  # served by all: ok
  kill "$WEB_PID"; wait "$WEB_PID" 2>/dev/null || true
  python3 "$TMP_DIR/listeners.py" web "$WEB" "macdev,two.localhost,ghost.localhost" "$REQUESTS" & WEB_PID="$!"; PIDS+=("$WEB_PID")
  wait_port "$WEB"
  run_fm doctor --json --bench-dir "$BENCH"
  assert_eq "ok" "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"] == "site_not_served"][0]["level"]')"
  assert_contains "$OUT" "serves every site it was asked about (3)"
  # a stopped bench is not asked
  : >"$MOCK_PROCS"; : >"$REQUESTS"
  run_fm doctor --json --bench-dir "$BENCH"
  assert_eq "ok" "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"] == "site_not_served"][0]["level"]')"
  assert_contains "$OUT" "the bench is not running; no site is asked"
  assert_eq "0" "$(requests)" "(doctor never pings a stopped bench's sites)"
  # a web port nobody answers on is no 404: nothing is reported
  add_proc 4242 "honcho start -f Procfile.lean" "$BENCH"
  kill "$WEB_PID"; wait "$WEB_PID" 2>/dev/null || true
  export MOCK_CURL_CODE=000
  status_json
  assert_eq "None None None" "$(printf '%s' "$OUT" | jget - '" ".join(str(s["served"]) for s in d["sites"])')" "$OUT"
  run_fm doctor --json --bench-dir "$BENCH"
  assert_eq "ok" "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"] == "site_not_served"][0]["level"]')"
  # back to the other tests' state: probes off, no listeners, no processes
  export FL_LOCAL_PROBES=0
  : >"$MOCK_PROCS"
  export MOCK_CURL_CODE=000
  for n in ${PIDS[@]+"${PIDS[@]}"}; do kill "$n" 2>/dev/null || true; done
  PIDS=()
}

suite mac
# the same on Linux: /proc for the processes, ss for the listeners
use_linux
suite linux

printf 'test-services-served: ok\n'
