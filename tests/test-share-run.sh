#!/usr/bin/env bash
# benchbar share start, stop, extend and status; the launchd job com.benchbar-share.gateway and its
# runner (templates/share-run.sh.tmpl); share_web.py. launchctl is the file-backed mock, whose kickstart
# runs the rendered runner in the background like launchd would. The runner's children are stand-ins
# that write the order they start in to $MOCK_STATE/order: the web shim (the bench's Python), the
# gateway (a Python control socket), dns-sd, caffeinate, and a scripted "benchbar share preflight".
# Nothing listens on the LAN, and every stand-in is stopped by its recorded PID.
# shellcheck disable=SC2016  # bash -c bodies, JavaScript and labels are meant to stay literal
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
. "$ROOT/lib/frappe-local/ui.sh"
. "$ROOT/lib/frappe-local/run.sh"
. "$ROOT/lib/frappe-local/templates.sh"
. "$ROOT/lib/frappe-local/share-site.sh"
. "$ROOT/lib/frappe-local/share-run.sh"

BENCH="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH" macdev
export MOCK_ENV_PYTHON="$ROOT/tests/mocks/env-python"
printf 'port 11000\n' >"$BENCH/config/redis_queue.conf"; printf 'port 13000\n' >"$BENCH/config/redis_cache.conf"
for app in frappe erpnext; do
  MOCK_GIT_REAL=1 git -C "$BENCH/apps/$app" init -q
  MOCK_GIT_REAL=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com \
    git -C "$BENCH/apps/$app" commit -q --allow-empty -m "$app"
done
export MOCK_GIT_REAL=1
FRAPPE_SHA="$(git -C "$BENCH/apps/frappe" rev-parse HEAD)"; ERPNEXT_SHA="$(git -C "$BENCH/apps/erpnext" rev-parse HEAD)"

SHARE_DIR="$FL_STATE_DIR/share"
COPY="$BENCH/sites/share.localhost"
mkdir -p "$SHARE_DIR" "$COPY"; chmod 700 "$SHARE_DIR"
# macOS caps a socket path at 104 characters: the test HOME is long
SOCK="$TMP_DIR/c.sock"; export FL_SHARE_CONTROL_SOCK="$SOCK"
LABEL=com.benchbar-share.gateway
TARGET="gui/$(id -u)/${LABEL}"
REAL_NODE="$(command -v node 2>/dev/null || true)"

printf '{\n "db_name": "_share",\n "developer_mode": 0,\n "server_script_enabled": 0\n}\n' >"$COPY/site_config.json"
write_share_json() {
  cat >"$SHARE_DIR/share.json" <<JSON
{
  "v": 3,
  "site": "macdev",
  "share_site": "share.localhost",
  "allowed_users": ["priya@example.com","mgr@example.com"],
  "room_label": "Lab \"one\" \$HOME",
  "seats": [
    {"seat_id":"s_0a1b2c3d","user":"priya@example.com","full_name":"Priya Nair","roles":["NE"]},
    {"seat_id":"s_1a2b3c4d","user":"mgr@example.com","full_name":"Mgr Singh","roles":["Sales User"]}
  ],
  "web_port": 8001,
  "fingerprint": "sha256:00",
  "copy_made": "2026-11-02T10:00:00Z",
  "copy_source_stamp": "20260902_090000",
  "apps_at_copy": {"frappe":"${FRAPPE_SHA}","erpnext":"${ERPNEXT_SHA}"},
  "pii_acknowledged_at": "2026-11-02T10:00:00Z",
  "created": "2026-11-02T10:00:00Z"
}
JSON
  chmod 600 "$SHARE_DIR/share.json"
}
write_share_json
/usr/bin/openssl ecparam -name prime256v1 -genkey -noout -out "$SHARE_DIR/host.key" 2>/dev/null
/usr/bin/openssl req -new -x509 -key "$SHARE_DIR/host.key" -days 2 -subj /CN=benchbar-share -out "$SHARE_DIR/host.crt" 2>/dev/null

# the share checks' world (as in test-share-preflight): pf files, a LAN address, the block working
PF_DIR="$TMP_DIR/pf"; mkdir -p "$PF_DIR"
export FL_LANGUARD_ANCHOR="$PF_DIR/com.benchbar.lan" FL_LANGUARD_DAEMON="$PF_DIR/com.benchbar.pf.plist"
cat >"$FL_LANGUARD_ANCHOR" <<'PF'
ports = "{ 8000:8099, 9000:9099, 11000:11099, 13000:13099, 3306 }"
block return in quick inet  proto tcp from ! 127.0.0.1 to any port $ports
block return in quick inet6 proto tcp from ! ::1 to any port $ports
PF
printf '<?xml version="1.0"?>\n<plist><dict><key>ProgramArguments</key><array><string>/sbin/pfctl</string><string>-a</string><string>com.apple/250.benchbar</string><string>-f</string><string>%s</string></array></dict></plist>\n' "$FL_LANGUARD_ANCHOR" >"$FL_LANGUARD_DAEMON"
export FL_NC="$ROOT/tests/mocks/bin/nc" FL_CURL="$ROOT/tests/mocks/bin/curl" FL_SOCKETFILTERFW="$ROOT/tests/mocks/bin/socketfilterfw"
export FL_ROUTE="$ROOT/tests/mocks/bin/route" FL_IPCONFIG="$ROOT/tests/mocks/bin/ipconfig" FL_IFCONFIG="$ROOT/tests/mocks/bin/ifconfig"
http_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
serve() { printf '%s\r\n%s\r\n\r\n%s\n' "$2" "$3" "$4" >"$MOCK_STATE/share_http/$(http_key "$1")"; }
WEB=http://127.0.0.1:8001
healthy_world() {
  mkdir -p "$MOCK_STATE/share_http"
  printf 'en0\n' >"$MOCK_STATE/lan_iface"; printf '192.168.1.20\n' >"$MOCK_STATE/lan_ip"
  printf '8001\n13000\n' >"$MOCK_STATE/loopback_ports"
  # the control above the range answers, and so does the gateway on 8443
  printf '18097\n8443\n' >"$MOCK_STATE/lan_reachable_ports"
  serve "$WEB/" "HTTP/1.1 200 OK" "Content-Type: text/html; charset=utf-8" "<title>Login</title>"
  serve "$WEB/?__debugger__=yes&cmd=resource&f=style.css" "HTTP/1.1 200 OK" "Content-Type: text/html; charset=utf-8" "<title>Login</title>"
  serve "$WEB/api/method/benchbar.no.such.method" "HTTP/1.1 417 EXPECTATION FAILED" "Content-Type: application/json" '{"exc_type":"ValidationError"}'
}
healthy_world

# ---------------------------------------------------------------- the stand-ins
SB="$TMP_DIR/sb"; mkdir -p "$SB"
# the bench's Python: share_web.py becomes a loopback listener (the lsof mock reports it), the sessions
# helper records its stdin; anything else is the frappe-python mock
cat >"$BENCH/env/bin/python" <<SH
#!/bin/bash
case "\${1:-}" in
  */share_web.py)
    port=""; prev=""; for a in "\$@"; do [[ "\$prev" != --port ]] || port="\$a"; prev="\$a"; done
    printf 'web %s CI=%s DEV_SERVER=%s cwd=%s\n' "\$*" "\${CI:-}" "\${DEV_SERVER-unset}" "\$PWD" >>"\$MOCK_STATE/order"
    printf '%s\n' "\$\$" >>"\$MOCK_STATE/web_pids"
    [[ -f "\$MOCK_STATE/web_deaf" ]] || printf '%s %s python 127.0.0.1\n' "\$port" "\$\$" >>"\$MOCK_LISTEN"
    while kill -0 "\$PPID" 2>/dev/null; do sleep 0.2; done
    exit 0 ;;
  -c)
    if [[ "\${3:-}" == benchbar-share-sessions ]]; then
      keep="\$(cat)"
      printf 'wipe %s keep=[%s]\n' "\${4:-}" "\${keep//\$'\n'/,}" >>"\$MOCK_STATE/order"
      [[ ! -f "\$MOCK_STATE/wipe_fail" ]] || exit 1
      [[ ! -f "\$MOCK_STATE/wipe_hang" ]] || exec sleep 25
      printf '\nBENCHBAR-RESULT 2\n'
      exit 0
    fi ;;
esac
exec "$ROOT/tests/mocks/frappe-python" "\$@"
SH
chmod +x "$BENCH/env/bin/python"
cat >"$SB/dns-sd" <<'SH'
#!/bin/bash
printf 'dns-sd %s\n' "$*" >>"$MOCK_STATE/order"
printf '%s\n' "$$" >>"$MOCK_STATE/dns_pids"
if [[ -f "$MOCK_STATE/dns_die" ]]; then rm -f "$MOCK_STATE/dns_die"; exit 1; fi
while kill -0 "$PPID" 2>/dev/null; do sleep 0.2; done
SH
cat >"$SB/caffeinate" <<'SH'
#!/bin/bash
printf 'caffeinate %s\n' "$*" >>"$MOCK_STATE/order"
printf '%s\n' "$$" >>"$MOCK_STATE/caf_pids"
[[ ! -f "$MOCK_STATE/caf_die" ]] || exit 1
while kill -0 "$PPID" 2>/dev/null; do sleep 0.2; done
SH
# "benchbar share preflight": each run takes the next line of $MOCK_STATE/pre_script (ok when empty):
# ok, fail, or skipgw (gateway_reachable skipped although the gateway runs). Like the real one, ok says
# skip for gateway_reachable while there is no control socket.
cat >"$SB/benchbar" <<'SH'
#!/bin/bash
printf 'preflight %s sock=%s node=%s state=%s\n' "$*" "${FL_SHARE_CONTROL_SOCK:-}" "${FL_SHARE_NODE:-}" "${FL_STATE_DIR:-}" >>"$MOCK_STATE/order"
r=ok
if [[ -s "$MOCK_STATE/pre_script" ]]; then
  r="$(head -n1 "$MOCK_STATE/pre_script")"
  tail -n +2 "$MOCK_STATE/pre_script" >"$MOCK_STATE/pre_script.tmp"; mv "$MOCK_STATE/pre_script.tmp" "$MOCK_STATE/pre_script"
fi
case "$r" in
  hang) sleep 8; r=ok ;;
  # the web stops owning its port right after its checks
  unlisten) grep -v "^8001 " "$MOCK_LISTEN" >"$MOCK_LISTEN.tmp"; mv "$MOCK_LISTEN.tmp" "$MOCK_LISTEN"; r=ok ;;
esac
gw=skip; [[ ! -S "${FL_SHARE_CONTROL_SOCK:-/nonexistent}" ]] || gw=ok
ok=true; pf=ok; code=0
case "$r" in skipgw) gw=skip ;; fail) ok=false; pf=fail; code=1 ;; esac
printf '{"schema_version":1,"cli_version":"t","protocol":3,"ok":%s,"lan_ip":"192.168.1.20","checks":[{"id":"pf_active","class":"critical","status":"%s","message":"m","fix":"","fix_action":"install_network_protection"},{"id":"gateway_reachable","class":"critical","status":"%s","message":"m","fix":"","fix_action":"restart_sharing"}],"exit":%d,"changed":[],"warnings":[],"next_actions":[],"state_after":null}\n' "$ok" "$pf" "$gw" "$code"
exit "$code"
SH
# the gateway: its control socket answers status, extend (capped like the real one) and stop. Its status
# reply carries a code and a user list, which nothing of the CLI may pass on.
cat >"$SB/gateway.py" <<'PY'
import json, os, socket, sys, time
cfg_path = sys.argv[1]
cfg = json.load(open(cfg_path))
state = os.environ["MOCK_STATE"]
def note(text):
    with open(os.path.join(state, "order"), "a") as f:
        f.write(text + "\n")
note("gateway " + cfg_path)
with open(os.path.join(state, "gw_pids"), "a") as f:
    f.write("%d\n" % os.getpid())
path = cfg["control_sock"]
if os.path.exists(path):
    os.unlink(path)
os.umask(0o077)
srv = socket.socket(socket.AF_UNIX)
srv.bind(path)
srv.listen(8)
srv.settimeout(0.2)
parent = os.getppid()
stopping = False
web_up = False
def answer(msg):
    global stopping, web_up
    op = msg.get("op")
    if op == "web":
        note("webop " + str(msg.get("state")))
        if os.path.exists(os.path.join(state, "web_op_fail")):
            return {"ok": False, "error": "internal"}
        web_up = msg.get("state") == "up"
        return {"ok": True, "web_up": web_up}
    note("control " + str(op))
    d = cfg["deadline_epoch"]
    if time.time() >= d:
        return {"ok": False, "error": "ended"}
    if op == "status":
        return {"ok": True, "deadline_epoch": d, "online": ["d_0a1b2c3d"], "conns": 2, "web_up": web_up, "locked": False,
                "lock_reason": None, "budget_left": 9, "seats": 2, "people": 1, "join_trouble": False,
                "wipe_failed": ["priya@example.com"], "code": "482913"}
    if op == "extend":
        cap = cfg["started_epoch"] + cfg["max_total_s"]
        nxt = max(d, min(d + msg["seconds"], cap))
        capped = d + msg["seconds"] > cap
        cfg["deadline_epoch"] = nxt
        with open(cfg_path, "w") as f:
            json.dump(cfg, f)
        return {"ok": True, "deadline_epoch": nxt, "capped": capped}
    if op == "stop":
        stopping = True
        return {"ok": True}
    return {"ok": False, "error": "unknown_op"}
end = time.time() + 120
while not stopping and time.time() < end and os.getppid() == parent and not os.path.exists(os.path.join(state, "gw_exit")):
    # $MOCK_STATE/gw_latch: what the real gateway does on a refused upstream connect
    if os.path.exists(os.path.join(state, "gw_latch")):
        os.unlink(os.path.join(state, "gw_latch"))
        web_up = False
        note("latched")
    try:
        conn, _ = srv.accept()
    except socket.timeout:
        continue
    conn.settimeout(2)
    buf = b""
    try:
        while b"\n" not in buf:
            chunk = conn.recv(4096)
            if not chunk:
                break
            buf += chunk
        if b"\n" in buf:
            conn.sendall((json.dumps(answer(json.loads(buf.split(b"\n")[0]))) + "\n").encode())
    except (socket.timeout, OSError, ValueError):
        pass
    conn.close()
srv.close()
os.unlink(path)
PY
# lsof for the runner: the mock, except that with $MOCK_STATE/lsof_flip it answers once that the newest web
# process holds 8001 and then drops that listener (ownership lost between two checks)
cat >"$SB/lsof" <<SH
#!/bin/bash
out="\$("$ROOT/tests/mocks/bin/lsof" "\$@")"; code=\$?
web="\$(tail -n1 "\$MOCK_STATE/web_pids" 2>/dev/null)"
if [[ -f "\$MOCK_STATE/lsof_flip" && -n "\$web" && \$'\n'"\$out"\$'\n' == *\$'\n'"\$web"\$'\n'* ]]; then
  grep -v "^8001 " "\$MOCK_LISTEN" >"\$MOCK_LISTEN.tmp"; mv "\$MOCK_LISTEN.tmp" "\$MOCK_LISTEN"
  rm -f "\$MOCK_STATE/lsof_flip"
fi
[[ -z "\$out" ]] || printf '%s\n' "\$out"
exit "\$code"
SH
# the node the share runs on: gateway.js is the Python gateway, the control client is the real node,
# anything else (the version, the checks' throwaway listener) is the node mock
cat >"$SB/node" <<SH
#!/bin/bash
case "\${1:-}" in
  */gateway.js) exec python3 "$SB/gateway.py" "\${2:-}" ;;
  -e) if [[ "\${3:-}" == control ]]; then exec "$REAL_NODE" "\$@"; fi ;;
  --version)
    if [[ -f "\$MOCK_STATE/node_slow" ]]; then
      : >"\$MOCK_STATE/node_slow_entered"
      for _ in \$(seq 1 200); do [[ ! -f "\$MOCK_STATE/node_release" ]] || break; sleep 0.1; done
    fi ;;
esac
exec "$ROOT/tests/mocks/node" "\$@"
SH
chmod 755 "$SB" "$SB"/*
# like Homebrew's bin/node: a link, which the job must not run through (launchd's PATH has no Homebrew node)
mkdir -p "$TMP_DIR/nodebin"; chmod 755 "$TMP_DIR/nodebin"; ln -s "$SB/node" "$TMP_DIR/nodebin/node"
export FL_SHARE_NODE="$TMP_DIR/nodebin/node" FL_SHARE_DNS_SD="$SB/dns-sd" FL_SHARE_CAFFEINATE="$SB/caffeinate" FL_SHARE_LSOF="$ROOT/tests/mocks/bin/lsof"
export BENCHBAR_SHARE_POLL=0.2 BENCHBAR_SHARE_FIRST_TICK=2 BENCHBAR_SHARE_EVERY=2

order() { cat "$MOCK_STATE/order" 2>/dev/null || true; }
# events: the first word of each line of the order log, joined by spaces
# events: the first word of each line of the order log, joined by spaces (the control socket's status and
# stop calls left out; the web ops are "webop up" and "webop down", as one word each)
events() { order | grep -v '^control ' | awk '{ print ($1 == "webop") ? "webop-" $2 : $1 }' | tr '\n' ' ' | sed 's/ $//'; }
reset_order() {
  : >"$MOCK_STATE/order"
  rm -f "$MOCK_STATE/pre_script" "$MOCK_STATE/gw_exit" "$MOCK_STATE/dns_die" "$MOCK_STATE/web_deaf" "$MOCK_STATE/wipe_fail" \
    "$MOCK_STATE/wipe_hang" "$MOCK_STATE/caf_die" "$MOCK_STATE/web_op_fail" "$MOCK_STATE/lsof_flip"
}
# wait_for SECONDS CMD...: until CMD succeeds, or fail
wait_for() {
  local secs="$1" i=0
  shift
  while ! "$@"; do
    i=$((i + 1)); [[ "$i" -lt $((secs * 10)) ]] || fail "timed out after ${secs} s waiting for: $*"$'\n'"--- order ---"$'\n'"$(order)"$'\n'"--- runner log ---"$'\n'"$(cat "$TMP_DIR/runner.log" 2>/dev/null || true)"
    sleep 0.1
  done
}
has_event() { order | grep -q -E "$1"; }
pid_gone() { ! kill -0 "$1" 2>/dev/null; }
# every_recorded_gone: no stand-in the runner started still runs
every_recorded_gone() {
  local f pid
  for f in web_pids gw_pids dns_pids caf_pids; do
    [[ -f "$MOCK_STATE/$f" ]] || continue
    while IFS= read -r pid; do [[ -z "$pid" ]] || pid_gone "$pid" || return 1; done <"$MOCK_STATE/$f"
  done
}
stop_recorded() {
  local f pid
  for f in web_pids gw_pids dns_pids caf_pids; do
    [[ -f "$MOCK_STATE/$f" ]] || continue
    while IFS= read -r pid; do [[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true; done <"$MOCK_STATE/$f"
    rm -f "$MOCK_STATE/$f"
  done
}

# ================================================================ share_web.py
FAKE="$TMP_DIR/fakeweb"; mkdir -p "$FAKE/werkzeug" "$FAKE/frappe"
printf '' >"$FAKE/werkzeug/__init__.py"
cat >"$FAKE/werkzeug/serving.py" <<'PY'
import json, os
def run_simple(hostname, port, application, **kwargs):
    with open(os.environ["SERVE_LOG"], "w") as f:
        json.dump({"host": hostname, "port": port, "kwargs": kwargs, "ci": os.environ.get("CI"),
                   "dev_server": os.environ.get("DEV_SERVER"), "app": application}, f)
PY
printf '' >"$FAKE/frappe/__init__.py"
# like frappe v15: run_simple imported inside serve, the debugger on unless CI is set
cat >"$FAKE/frappe/app.py" <<'PY'
import os
def serve(port=8000, profile=False, no_reload=False, no_threading=False, site=None, sites_path=".", proxy=False):
    from werkzeug.serving import run_simple
    in_test_env = os.environ.get("CI")
    run_simple("0.0.0.0", int(port), "app:%s:%s" % (site, sites_path), exclude_patterns=["test_*"],
               use_reloader=False if in_test_env else not no_reload, use_debugger=not in_test_env,
               use_evalex=not in_test_env, threaded=not no_threading)
PY
web_py() { (cd "$BENCH/sites" && DEV_SERVER=1 SERVE_LOG="$TMP_DIR/serve.json" PYTHONPATH="$FAKE" python3 "$ROOT/lib/frappe-local/share/share_web.py" "$@"); }
web_py --site share.localhost --port 8123
assert_eq "127.0.0.1 8123 1 None" "$(jget "$TMP_DIR/serve.json" '" ".join(str(x) for x in (d["host"], d["port"], d["ci"], d["dev_server"]))')" "(loopback, CI set and DEV_SERVER gone before serve)"
assert_eq "False False False" "$(jget "$TMP_DIR/serve.json" '" ".join(str(d["kwargs"][k]) for k in ("use_debugger", "use_evalex", "use_reloader"))')"
assert_eq "app:share.localhost:." "$(jget "$TMP_DIR/serve.json" 'd["app"]')" "(the share site pinned, sites from the working folder)"
# a frappe that binds run_simple when the module loads gets the loopback one too, even with CI forced off
cat >"$FAKE/frappe/app.py" <<'PY'
import os
from werkzeug.serving import run_simple
def serve(port=8000, profile=False, no_reload=False, no_threading=False, site=None, sites_path=".", proxy=False):
    os.environ.pop("CI", None)
    run_simple("0.0.0.0", int(port), "app:%s:%s" % (site, sites_path), use_reloader=True, use_debugger=True, use_evalex=True)
PY
web_py --site share.localhost --port 8124
assert_eq "127.0.0.1 8124 False False False" "$(jget "$TMP_DIR/serve.json" '" ".join(str(x) for x in (d["host"], d["port"], d["kwargs"]["use_debugger"], d["kwargs"]["use_evalex"], d["kwargs"]["use_reloader"]))')"
set +e; web_py --port 8125 >/dev/null 2>&1; code=$?; set -e
assert_eq "2" "$code" "(no site, no serve)"
set +e; web_py --site "share.localhost" --port 0x1f >/dev/null 2>&1; code=$?; set -e
assert_eq "2" "$code" "(the port is a number)"

# ================================================================ the job's plist
plist="$(fl_template_render share.plist "LABEL=${LABEL}" "APP_BUNDLE_ID=com.akashmishra.benchbar" "RUNNER=${SHARE_DIR}/share-run.sh" \
  "SHARE_DIR=${SHARE_DIR}" "PATH=/opt/homebrew/bin:/usr/bin:/bin" "LOG=${SHARE_DIR}/share.log")"
printf '%s' "$plist" >"$TMP_DIR/job.plist"
python3 - "$TMP_DIR/job.plist" "$LABEL" "$SHARE_DIR" <<'PY' || fail "the share job's plist"
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
assert p["Label"] == sys.argv[2], p
assert p["RunAtLoad"] is False and p["KeepAlive"] is False, p
assert p["Umask"] == 0o077, p["Umask"]
assert p["ProgramArguments"] == ["/bin/bash", sys.argv[3] + "/share-run.sh"], p
assert p["AssociatedBundleIdentifiers"] == ["com.akashmishra.benchbar"], p
assert "/opt/homebrew/bin" in p["EnvironmentVariables"]["PATH"], p
PY
assert_contains "$plist" "benchbar-template: share.plist v"

if [[ -z "$REAL_NODE" ]]; then
  # the runner tells the gateway the web state over the control socket, which needs the real node
  printf 'SKIP: node not found: the runner and the start, stop, extend and status cases were not run\n'
  printf 'test-share-run: ok (SKIPPED the node cases)\n'
  exit 0
fi

# ================================================================ the runner, run directly
NOW="$(date +%s)"
write_gateway_cfg() { # DEADLINE: what the stand-in gateway reads (the real file is written by share start)
  printf '{"control_sock":"%s","deadline_epoch":%s,"started_epoch":%s,"max_total_s":43200}\n' "$SOCK" "$1" "$NOW" >"$SHARE_DIR/gateway.json"
  chmod 600 "$SHARE_DIR/gateway.json"
}
NASTY_ROOM='Lab "one" $HOME `x`'
render_runner() {
  fl_template_render share-run.sh "SHARE_DIR=${SHARE_DIR}" "SOCK=${SOCK}" "BENCH=${BENCH}" "SHARE_SITE=share.localhost" "WEB_PORT=8001" \
    "GATEWAY_PORT=8443" "PYTHON=${BENCH}/env/bin/python" "LIB=${ROOT}/lib/frappe-local" "NODE=${SB}/node" "BENCHBAR=${SB}/benchbar" \
    "DNS_SD=${SB}/dns-sd" "CAFFEINATE=${SB}/caffeinate" "LSOF=${SB}/lsof" "WIPE_SECS=${FL_SHARE_WIPE_SECS}" \
    "LISTEN_SECS=${FL_SHARE_LISTEN_SECS}" "SOCK_SECS=${FL_SHARE_SOCK_SECS}" "SESSIONS_PY=${FL_PY_SHARE_SESSIONS}" \
    "CONTROL_JS=${FL_JS_SHARE_CONTROL}" "SITE_LABEL=macdev" "ROOM_LABEL=${NASTY_ROOM}" >"$SHARE_DIR/share-run.sh"
  chmod 700 "$SHARE_DIR/share-run.sh"
  printf '<plist/>\n' >"$SHARE_DIR/job.plist"
}
RUNNER_PID=""
start_runner() {
  render_runner
  : >"$TMP_DIR/runner.log"
  /bin/bash "$SHARE_DIR/share-run.sh" >>"$TMP_DIR/runner.log" 2>&1 </dev/null &
  RUNNER_PID=$!
}
runner_gone() { pid_gone "$RUNNER_PID"; }
runner_code() { local c=0; wait "$RUNNER_PID" 2>/dev/null || c=$?; printf '%s' "$c"; }
finish_runner() { # after each case: nothing of it survives
  if ! runner_gone; then kill "$RUNNER_PID" 2>/dev/null || true; fi
  wait_for 15 runner_gone
  wait_for 5 every_recorded_gone
  stop_recorded
}

# the rendered runner: a header like the bench runner's, bash 3.2 syntax, the label survives the quotes
render_runner
assert_contains "$(head -n3 "$SHARE_DIR/share-run.sh")" "benchbar-template: share-run.sh v"
/bin/bash -n "$SHARE_DIR/share-run.sh"
assert_eq "$NASTY_ROOM" "$(bash -c 'eval "$(sed -n "/^ROOM_LABEL=/p" "$1")"; printf "%s" "$ROOM_LABEL"' _ "$SHARE_DIR/share-run.sh")"
assert_contains "$(cat "$SHARE_DIR/share-run.sh")" 'frappe.db.sql("delete from `tabSessions` where sid in %(sids)s"' "(the sessions helper is spliced in)"
assert_eq "1" "$(grep -c '^umask 077$' "$SHARE_DIR/share-run.sh")"

# ---- the order: wipe, web, checks, gateway, checks again, dns-sd, caffeinate; then a TERM (bootout) runs the trap
reset_order; write_gateway_cfg $((NOW + 3600))
start_runner
wait_for 15 has_event '^caffeinate '
assert_eq "wipe web preflight gateway preflight webop-up" "$(events | cut -d' ' -f1-6)" "(the gateway hears the web is up only after the second checks) $(order)"
# the two start together; the stand-ins write when they get to it, and a watchdog check may come first under load
assert_eq "caffeinate dns-sd" "$(events | cut -d' ' -f7- | tr ' ' '\n' | grep -v '^preflight$' | head -n2 | sort | tr '\n' ' ' | sed 's/ $//')"
started_order() { grep -o -E '(dns-sd|caffeinate) started' "$1" | awk '{print $1}' | tr '\n' ' ' | sed 's/ $//'; }
assert_eq "dns-sd caffeinate" "$(started_order "$TMP_DIR/runner.log")" "(Bonjour before caffeinate, from the runner's own log)"
assert_contains "$(order)" "wipe share.localhost keep=[]" "(the whole copy, at start: covers a runner killed with -9)"
assert_contains "$(order)" "web ${ROOT}/lib/frappe-local/share/share_web.py --site share.localhost --port 8001 CI=1 DEV_SERVER=unset cwd=${BENCH}/sites"
assert_contains "$(order)" "preflight share preflight --json --critical --quiet --bench-dir ${BENCH} sock=${SOCK} node=${SB}/node state=${FL_STATE_DIR}"
assert_contains "$(order)" "gateway ${SHARE_DIR}/gateway.json"
assert_contains "$(order)" "dns-sd -R ${NASTY_ROOM} _benchbar-share._tcp local 8443 v=3 label=${NASTY_ROOM} site=macdev"
assert_contains "$(order)" "caffeinate -i -w ${RUNNER_PID}"
assert_not_contains "$(order)" "fingerprint"
assert_eq "${RUNNER_PID} running" "$(cat "$SHARE_DIR/phase")"
assert_eq "600" "$(stat -f %Lp "$SHARE_DIR/phase" 2>/dev/null || stat -c %a "$SHARE_DIR/phase")"
# the watchdog ticks while all is well
wait_for 10 bash -c '[[ "$(grep -c "^preflight " "$1")" -ge 3 ]]' _ "$MOCK_STATE/order"
assert_eq "False" "$(runner_gone && echo True || echo False)"
kill -TERM "$RUNNER_PID"
wait_for 15 runner_gone
assert_eq "0" "$(runner_code)" "(a bootout is a normal end)"
wait_for 5 every_recorded_gone
assert_eq "wipe" "$(order | tail -n1 | awk '{print $1}')" "(the trap wipes the sessions after the children are gone)"
assert_eq "2" "$(grep -c '^wipe ' "$MOCK_STATE/order")"
assert_no_file "$SOCK"; assert_no_file "$SHARE_DIR/job.plist"; assert_no_file "$SHARE_DIR/share-run.sh"; assert_no_file "$SHARE_DIR/phase"
assert_file "$SHARE_DIR/gateway.json" "(status still reads the deadline)"
# the runner's children are its own processes; one it started that outlives a kill -9 of the runner is
# reaped by launchd, which kills the job's process group (AbandonProcessGroup unset): the stand-ins here
# exit with their parent instead, so that rests on launchd, UNVERIFIED until the real run of Task 9
stop_recorded

# ---- no gateway.json: exit 78, nothing started
reset_order; rm -f "$SHARE_DIR/gateway.json"
start_runner
wait_for 10 runner_gone
assert_eq "78" "$(runner_code)"
assert_not_contains "$(events)" "web"; assert_not_contains "$(events)" "gateway"
assert_no_file "$SHARE_DIR/job.plist"

# ---- the first checks fail: the gateway is never started
reset_order; write_gateway_cfg $((NOW + 3600)); printf 'fail\n' >"$MOCK_STATE/pre_script"
start_runner
wait_for 15 runner_gone
assert_eq "1" "$(runner_code)" "(line $LINENO: $(events))"
assert_eq "wipe web preflight wipe" "$(events)"
assert_contains "$(cat "$SHARE_DIR/ended")" "checks"
finish_runner

# ---- after the gateway starts, a skipped gateway_reachable is a failure
reset_order; printf 'ok\nskipgw\n' >"$MOCK_STATE/pre_script"
start_runner
wait_for 15 runner_gone
assert_eq "1" "$(runner_code)" "(line $LINENO: $(events))"
assert_eq "wipe web preflight gateway preflight wipe" "$(events)" "(no dns-sd, and the web is never marked up)"
finish_runner

# ---- a web op the gateway does not confirm ends the job
reset_order; : >"$MOCK_STATE/web_op_fail"
start_runner
wait_for 15 runner_gone
assert_eq "1" "$(runner_code)" "(line $LINENO: $(events))"
assert_eq "wipe web preflight gateway preflight webop-up wipe" "$(events)"
assert_contains "$(cat "$SHARE_DIR/ended")" "did not confirm that the web process is up"
finish_runner

# ---- the web shim never listens on its port: the job ends before any check
reset_order; : >"$MOCK_STATE/web_deaf"; export BENCHBAR_SHARE_LISTEN_SECS=1
start_runner
wait_for 15 runner_gone
assert_eq "1" "$(runner_code)" "(line $LINENO: $(events))"
assert_eq "wipe web wipe" "$(events)"
finish_runner
unset BENCHBAR_SHARE_LISTEN_SECS

# ---- the watchdog: one fail then ok goes on, two in a row end the job
reset_order; printf 'ok\nok\nfail\nok\nok\nfail\nfail\n' >"$MOCK_STATE/pre_script"
start_runner
wait_for 30 runner_gone
assert_eq "1" "$(runner_code)" "(line $LINENO: $(events))"
assert_eq "7" "$(grep -c '^preflight ' "$MOCK_STATE/order")" "(ended at the second fail in a row, not at the first)"
assert_contains "$(cat "$SHARE_DIR/ended")" "twice in a row"
finish_runner

# ---- dns-sd dies: restarted, and the share is degraded (a warning), never ended; once it has stayed up, no longer
reset_order; : >"$MOCK_STATE/dns_die"; export BENCHBAR_SHARE_STABLE_POLLS=10
start_runner
wait_for 15 bash -c '[[ "$(grep -c "^dns-sd " "$1")" -ge 2 ]]' _ "$MOCK_STATE/order"
wait_for 5 test -f "$SHARE_DIR/degraded"
assert_contains "$(cat "$SHARE_DIR/degraded")" "Bonjour"
assert_contains "$(cat "$TMP_DIR/runner.log")" "dns-sd ended; starting it again in 5 polls"
wait_for 10 bash -c '! test -f "$1"' _ "$SHARE_DIR/degraded"
assert_contains "$(cat "$TMP_DIR/runner.log")" "no longer degraded"
assert_eq "False" "$(runner_gone && echo True || echo False)"
kill -TERM "$RUNNER_PID"; wait_for 15 runner_gone
finish_runner
unset BENCHBAR_SHARE_STABLE_POLLS

# ---- caffeinate that keeps ending is started again after a backoff that doubles, one line a step
reset_order; : >"$MOCK_STATE/caf_die"
start_runner
wait_for 20 bash -c 'grep -q "caffeinate ended; starting it again in 20 polls" "$1"' _ "$TMP_DIR/runner.log"
assert_eq "5 10 20" "$(grep -o 'caffeinate ended; starting it again in [0-9]* polls' "$TMP_DIR/runner.log" | awk '{print $7}' | tr '\n' ' ' | sed 's/ $//')"
assert_eq "3" "$(grep -c '^caffeinate ' "$MOCK_STATE/order")" "(one start per step, not one a poll)"
assert_eq "1" "$(grep -c 'caffeinate started' "$TMP_DIR/runner.log")" "(a restart writes its one backoff line, not a second started line)"
kill -TERM "$RUNNER_PID"; wait_for 15 runner_gone
finish_runner

# ---- the gateway latched the web down (a refused connect) while the web's own PID listens: the watchdog re-arms it
reset_order
start_runner
wait_for 15 has_event '^caffeinate '
: >"$MOCK_STATE/order"; : >"$MOCK_STATE/gw_latch"
wait_for 15 has_event '^webop up'
# up comes after the latch and after a check that ran after it, never before
awk '/^latched/ { l = NR } /^preflight / && l && !p { p = NR } /^webop up/ && l { u = NR } END { exit !(l && p > l && u > p) }' "$MOCK_STATE/order" \
  || fail "re-armed before a passing check: $(order)"
wait_for 10 bash -c 'grep -q "marked the web up again" "$1"' _ "$TMP_DIR/runner.log"
assert_eq "1" "$(grep -c 'marked the web up again' "$TMP_DIR/runner.log")" "(one line)"
kill -TERM "$RUNNER_PID"; wait_for 15 runner_gone
finish_runner

# ---- the web loses its port between the check and the up: the gateway is told down again and the job ends
reset_order; : >"$MOCK_STATE/lsof_flip"
start_runner
wait_for 15 runner_gone
assert_eq "1" "$(runner_code)" "(line $LINENO: $(events))"
assert_eq "wipe web preflight gateway preflight webop-up webop-down wipe" "$(events)" "(at the first start)"
assert_contains "$(cat "$SHARE_DIR/ended")" "stopped holding its port as it was marked up"
finish_runner
reset_order
start_runner
wait_for 15 has_event '^caffeinate '
: >"$MOCK_STATE/order"; : >"$MOCK_STATE/lsof_flip"; : >"$MOCK_STATE/gw_latch"
wait_for 15 runner_gone
assert_eq "1" "$(runner_code)" "(line $LINENO: $(events))"
assert_eq "webop-up webop-down wipe" "$(events | tr ' ' '\n' | grep -v -E '^(latched|preflight)$' | tr '\n' ' ' | sed 's/ $//')" "(at a re-arm)"
assert_contains "$(cat "$SHARE_DIR/ended")" "stopped holding its port as it was marked up"
finish_runner
grep -v "^8001 " "$MOCK_LISTEN" >"$MOCK_LISTEN.tmp"; mv "$MOCK_LISTEN.tmp" "$MOCK_LISTEN"

# ---- a foreign listener holds the web port: the latched web stays down
reset_order
start_runner
wait_for 15 has_event '^caffeinate '
web_pid="$(tail -n1 "$MOCK_STATE/web_pids")"
grep -v "^8001 " "$MOCK_LISTEN" >"$MOCK_LISTEN.tmp"; printf '8001 99991 python 127.0.0.1\n' >>"$MOCK_LISTEN.tmp"; mv "$MOCK_LISTEN.tmp" "$MOCK_LISTEN"
: >"$MOCK_STATE/order"; : >"$MOCK_STATE/gw_latch"
wait_for 15 has_event '^latched'
wait_for 15 bash -c '[[ "$(grep -c "^preflight " "$1")" -ge 3 ]]' _ "$MOCK_STATE/order"
assert_not_contains "$(events)" "webop-up" "(a port someone else holds is never re-armed)"
assert_eq "1" "$(grep -c 'does not hold its port' "$TMP_DIR/runner.log")" "(said once, not every tick)"
assert_eq "False" "$(runner_gone && echo True || echo False)"
kill -TERM "$RUNNER_PID"; wait_for 15 runner_gone
finish_runner
grep -v "^8001 99991 " "$MOCK_LISTEN" >"$MOCK_LISTEN.tmp"; mv "$MOCK_LISTEN.tmp" "$MOCK_LISTEN"

# ---- a restarted web that stops holding its port after its checks is not marked up
reset_order; printf 'ok\nok\nunlisten\n' >"$MOCK_STATE/pre_script"; export BENCHBAR_SHARE_FIRST_TICK=2000
start_runner
wait_for 15 has_event '^caffeinate '
kill "$(tail -n1 "$MOCK_STATE/web_pids")"
wait_for 15 runner_gone
assert_eq "1" "$(runner_code)" "(line $LINENO: $(events))"
assert_eq "webop-down web preflight wipe" "$(events | cut -d' ' -f9-)" "(never up)"
assert_contains "$(cat "$SHARE_DIR/ended")" "does not hold its port"
finish_runner
export BENCHBAR_SHARE_FIRST_TICK=2

# ---- the web child: restarted 3 times, each followed by the checks; the 4th death ends the job
reset_order; export BENCHBAR_SHARE_FIRST_TICK=2000
start_runner
wait_for 15 has_event '^caffeinate '
for n in 1 2 3; do
  pid="$(tail -n1 "$MOCK_STATE/web_pids")"
  : >"$MOCK_STATE/order"
  kill "$pid"
  wait_for 15 has_event '^webop up'
  # the gateway is told down before the web starts again, and up only after the checks of the new one
  assert_eq "webop-down web preflight webop-up" "$(events)" "(restart $n)"
  assert_eq "False" "$(runner_gone && echo True || echo False)" "(restart $n)"
done
export BENCHBAR_SHARE_FIRST_TICK=2
kill "$(tail -n1 "$MOCK_STATE/web_pids")"
wait_for 15 runner_gone
assert_eq "1" "$(runner_code)" "(line $LINENO: $(events))"
assert_eq "webop-down wipe" "$(events | cut -d' ' -f5-)"
assert_contains "$(cat "$SHARE_DIR/ended")" "ended 4 times in 5 minutes"
finish_runner

# ---- a restarted web whose checks fail ends the job at once (no debounce)
reset_order; printf 'ok\nok\nfail\n' >"$MOCK_STATE/pre_script"; export BENCHBAR_SHARE_FIRST_TICK=200
start_runner
wait_for 15 has_event '^caffeinate '
kill "$(tail -n1 "$MOCK_STATE/web_pids")"
wait_for 15 runner_gone
assert_eq "1" "$(runner_code)" "(line $LINENO: $(events))"
assert_eq "webop-down web preflight wipe" "$(events | cut -d' ' -f9-)" "(after the restart: down, the web, its checks, the end; never up)"
finish_runner
export BENCHBAR_SHARE_FIRST_TICK=2

# ---- the gateway exits (stop, deadline, crash): the runner stops the rest and ends
reset_order
start_runner
wait_for 15 has_event '^caffeinate '
: >"$MOCK_STATE/gw_exit"
wait_for 15 runner_gone
assert_eq "0" "$(runner_code)"
wait_for 5 every_recorded_gone
assert_no_file "$SOCK"; assert_no_file "$SHARE_DIR/job.plist"
finish_runner

# ---- a session wipe that hangs is cut at WIPE_SECS: the trap ends well inside launchd's 20 s
reset_order
start_runner
wait_for 15 has_event '^caffeinate '
: >"$MOCK_STATE/wipe_hang"
t0="$SECONDS"
kill -TERM "$RUNNER_PID"
wait_for 16 runner_gone
[[ $((SECONDS - t0)) -le 14 ]] || fail "the trap took $((SECONDS - t0)) s"
assert_contains "$(cat "$TMP_DIR/runner.log")" "took more than ${FL_SHARE_WIPE_SECS} s"
finish_runner

# ================================================================ the CLI
# the mock launchctl runs the job's runner (as launchd would) when it is kickstarted
export MOCK_LAUNCHD_RUN=1
export FL_SHARE_BENCHBAR="$SB/benchbar"
cli() { # ARGS...: stdout in OUT, stderr in ERR, the exit code in CODE; like the app (no terminal, BENCHBAR_SUDO=gui)
  set +e
  OUT="$(BENCHBAR_SUDO=gui "$FM" share "$@" --bench-dir "$BENCH" 2>"$TMP_DIR/cli.err")"
  CODE="$?"
  set -e
  ERR="$(cat "$TMP_DIR/cli.err")"
}
status_json() { cli status --json; printf '%s' "$OUT" >"$TMP_DIR/status.json"; }
sget() { jget "$TMP_DIR/status.json" "$1"; }
done_line() { printf '%s\n' "$OUT" | tail -n1 >"$TMP_DIR/done.json"; }
loaded() { [[ -f "$MOCK_STATE/agents/$LABEL" ]]; }
job_running() { [[ -s "$MOCK_STATE/agents/$LABEL.pid" ]] && kill -0 "$(cat "$MOCK_STATE/agents/$LABEL.pid")" 2>/dev/null; }
redis_up() { printf '8001\n13000\n' >"$MOCK_STATE/loopback_ports"; }
redis_down() { printf '8001\n' >"$MOCK_STATE/loopback_ports"; }

# ---- off
reset_order; rm -f "$SHARE_DIR/gateway.json" "$SHARE_DIR/ended"
status_json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "off None None 0 0 None" "$(sget '" ".join(str(x) for x in (d["state"], d["started"], d["deadline"], d["seconds_left"], d["can_extend_s"], d["web_up"]))')"
assert_eq "3 share.localhost 8443 8001 macdev" "$(sget '" ".join(str(x) for x in (d["protocol"], d["share_site"], d["port"], d["web_port"], d["site"]))')"
assert_eq "installed 192.168.1.20 None" "$(sget '" ".join(str(x) for x in (d["lan_guard"], d["lan_ip"], d["preflight"]))')"
assert_eq "False 2 priya@example.com,mgr@example.com" "$(sget '" ".join(str(x) for x in (d["copy"]["drifted"], d["seats"], ",".join(d["allowed_users"])))')"
assert_eq "True" "$(sget 'd["copy"]["made"] == "2026-11-02T10:00:00Z" and d["copy"]["source_site"] == "macdev" and isinstance(d["copy"]["age_s"], int) and d["copy"]["apps"][0]["at_copy"] == d["copy"]["apps"][0]["now"]')"
[[ -n "$OUT" && "$OUT" != *$'\n'* ]] || fail "status --json is one line of JSON: $OUT"
assert_calls_not_contain '^launchctl (bootstrap|kickstart|bootout)' "(status never changes anything)"

# ---- the guards: refusals change nothing
snap="$(snapshot "$SHARE_DIR")"
set +e; OUT="$(BENCHBAR_NONINTERACTIVE=1 BENCHBAR_SUDO=gui "$FM" share start --bench-dir "$BENCH" 2>&1)"; CODE=$?; set -e
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "person"
set +e; OUT="$("$FM" share start --bench-dir "$BENCH" 2>&1)"; CODE=$?; set -e
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "terminal"
set +e; OUT="$(BENCHBAR_SUDO=gui "$FM" share start --for-agent --bench-dir "$BENCH" 2>&1)"; CODE=$?; set -e
assert_eq "1" "$CODE" "$OUT"
for bad in 13h 4m 0h 2d h 1.5h "4 h" -1h; do
  cli start --for "$bad"
  assert_eq "1" "$CODE" "($bad) $OUT$ERR"; assert_contains "$OUT$ERR" "--for must be 5 minutes to 12 hours"
done
cli start --for
assert_eq "1" "$CODE"; assert_contains "$OUT$ERR" "--for"
cli start --bogus
assert_eq "1" "$CODE"; assert_contains "$OUT$ERR" "Unknown argument for share start: --bogus"
redis_down
cli start
assert_eq "1" "$CODE"; assert_contains "$OUT$ERR" "The bench is not running"
redis_up
mv "$SHARE_DIR/share.json" "$SHARE_DIR/share.json.away"
cli start
assert_eq "1" "$CODE"; assert_contains "$OUT$ERR" "benchbar share setup"
mv "$SHARE_DIR/share.json.away" "$SHARE_DIR/share.json"
assert_eq "$snap" "$(snapshot "$SHARE_DIR")" "(a refusal writes nothing)"
assert_calls_not_contain '^launchctl (bootstrap|kickstart)'
# the dry run: the plan, nothing loaded or written
cli start --dry-run --json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "$snap" "$(snapshot "$SHARE_DIR")"
assert_calls_not_contain '^launchctl (bootstrap|kickstart)'

# ---- start: the job is loaded and runs, the plist is gone, gateway.json is what config.js accepts
reset_order; reset_calls
cli start --json --for 4h
assert_eq "0" "$CODE" "$OUT$ERR"
done_line
assert_eq "0" "$(jget "$TMP_DIR/done.json" 'd["exit"]')"
assert_eq "static_preflight gateway_config job wait_listening post_start_preflight" "$(printf '%s\n' "$OUT" | python3 -c '
import json, sys
print(" ".join(e["id"] for e in map(json.loads, sys.stdin) if e["event"] == "step" and e["status"] == "done" and not e.get("parent")))')"
assert_eq "True" "$(jget "$TMP_DIR/done.json" 'abs(d["deadline_epoch"] - d["started_epoch"] - 14400) <= 1 and d["state"] == "on"')"
loaded || fail "the job is loaded"
job_running || fail "the runner runs"
assert_no_file "$SHARE_DIR/job.plist" "(deleted right after the bootstrap)"
assert_calls_contain "^launchctl bootstrap gui/$(id -u) ${SHARE_DIR}/job.plist\$"
assert_calls_contain "^launchctl kickstart ${TARGET}\$"
assert_eq "" "$(ls "$HOME/Library/LaunchAgents" 2>/dev/null)" "(nothing in LaunchAgents)"
assert_eq "600" "$(stat -f %Lp "$SHARE_DIR/gateway.json" 2>/dev/null || stat -c %a "$SHARE_DIR/gateway.json")"
assert_eq "700" "$(stat -f %Lp "$SHARE_DIR/share-run.sh" 2>/dev/null || stat -c %a "$SHARE_DIR/share-run.sh")"
"$REAL_NODE" -e '
const config = require(process.argv[1] + "/lib/frappe-local/share/config.js");
const c = config.load(process.argv[2], Date.now());
const ok = c.v === 3 && c.protocol === 3 && c.listen.port === 8443 && c.web_port === 8001 && c.share_site === "share.localhost"
  && c.seats.length === 2 && c.seats[0].seat_id === "s_0a1b2c3d" && c.room_label === "Lab \"one\" $HOME" && c.site_label === "macdev"
  && c.copy_made === "2026-11-02T10:00:00Z" && c.control_sock === process.argv[3] && c.max_total_s === 43200
  && c.deadline_epoch - c.started_epoch === 14400 && c.python === process.argv[4] + "/env/bin/python"
  && c.signin_helper === process.argv[1] + "/lib/frappe-local/share/signin.py" && c.devices.endsWith("/share/devices.json");
if (!ok) { console.error(JSON.stringify(c)); process.exit(1); }
' "$ROOT" "$SHARE_DIR/gateway.json" "$SOCK" "$BENCH" || fail "gateway.json is what config.js validates"
assert_not_contains "$(cat "$SHARE_DIR/gateway.json")" "socketio"
assert_not_contains "$(cat "$SHARE_DIR/gateway.json")" "9000"
assert_eq "True" "$(jget "$SHARE_DIR/devices.json" 'd["devices"] == [] and d["blocked"] == []')" "(devices are scoped to one room)"
# the runner names node and benchbar by absolute paths, never by PATH
runner_text="$(cat "$SHARE_DIR/share-run.sh")"
assert_contains "$runner_text" "NODE=\"${SB}/node\"" "(the realpath, not the link)"
assert_contains "$runner_text" "BENCHBAR=\"${SB}/benchbar\""
assert_contains "$runner_text" "DNS_SD=\"${SB}/dns-sd\""
wait_for 15 has_event '^caffeinate '
assert_eq "wipe web preflight gateway preflight" "$(events | sed 's/ control//g' | cut -d' ' -f1-5)" "$(order)"
assert_eq "dns-sd caffeinate" "$(started_order "$SHARE_DIR/share.log")" "(the job's log is share.log, as launchd opens it)"
# it never moves the default site
assert_eq "macdev" "$(tr -d '[:space:]' <"$BENCH/sites/currentsite.txt")"

# ---- status while on: the room's counts from the control socket, never the code or a user name
status_json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "on None True" "$(sget '" ".join(str(x) for x in (d["state"], d["degraded"], d["web_up"]))')"
assert_eq "True" "$(sget '14300 < d["seconds_left"] <= 14400 and d["can_extend_s"] == 43200 - 14400 and d["started"].endswith("Z") and d["deadline"].endswith("Z")')"
assert_eq "1 1 0 9 2 1 False None False 1" "$(sget '" ".join(str(x) for x in (d["devices_total"], d["devices_online"], d["pending"], d["budget_left"], d["seats"], d["people"], d["locked"], d["lock_reason"], d["join_trouble"], d["wipe_failed"]))')"
assert_not_contains "$OUT" "482913"; assert_not_contains "$OUT" "\"code\""
# the runner's watchdog asks status too, whose reply carries the code: nothing under the state folder
# (share.log, the run logs) holds it (J14)
assert_eq "" "$(grep -r -l "482913" "$FL_STATE_DIR" 2>/dev/null || true)" "(the room code is in no log or state file)"
assert_not_contains "$(sget 'json.dumps(d["wipe_failed"])')" "priya"
assert_eq "Lab \"one\" \$HOME" "$(sget 'd["label"]')"

# ---- a second start is unchanged, and the deadline does not move
deadline_before="$(jget "$SHARE_DIR/gateway.json" 'd["deadline_epoch"]')"
sleep 1
cli start --json --for 2h
assert_eq "0" "$CODE" "$OUT$ERR"
done_line
assert_eq "[] $deadline_before" "$(jget "$TMP_DIR/done.json" 'json.dumps(d["changed"]) + " " + str(d["deadline_epoch"])')"
assert_eq "$deadline_before" "$(jget "$SHARE_DIR/gateway.json" 'd["deadline_epoch"]')"
assert_eq "1" "$(grep -c '^launchctl bootstrap' "$MOCK_LOG")"

# ---- extend: capped at 12 hours from the start
cli extend --by 2h --json
assert_eq "0" "$CODE" "$OUT$ERR"
done_line
assert_eq "$((deadline_before + 7200))" "$(jget "$TMP_DIR/done.json" 'd["deadline_epoch"]')"
cli extend --by 12h --json
assert_eq "0" "$CODE" "$OUT$ERR"
done_line
started="$(jget "$SHARE_DIR/gateway.json" 'd["started_epoch"]')"
assert_eq "$((started + 43200)) True" "$(jget "$TMP_DIR/done.json" 'str(d["deadline_epoch"]) + " " + str(d["capped"])')"
assert_contains "$ERR" "at most 12 hours"
cli extend --by 1h
assert_eq "1" "$CODE" "$OUT$ERR"; assert_contains "$OUT$ERR" "sharing can run for at most 12 hours from the start"
cli extend --by 13h
assert_eq "1" "$CODE"; assert_contains "$OUT$ERR" "--by must be 5 minutes to 12 hours"
cli extend
assert_eq "1" "$CODE"; assert_contains "$OUT$ERR" "--by"
status_json
assert_eq "0" "$(sget 'd["can_extend_s"]')"

# ---- stop: the gateway is told, the job is booted out, the files go, the whole copy is wiped; twice is unchanged
reset_calls
wipes_before="$(grep -c '^wipe ' "$MOCK_STATE/order")"
cli stop --json
assert_eq "0" "$CODE" "$OUT$ERR"
done_line
assert_eq "True" "$(jget "$TMP_DIR/done.json" 'len(d["changed"]) > 0 and d["state"] == "off"')"
loaded && fail "the job is no longer loaded"
wait_for 15 every_recorded_gone
assert_no_file "$SOCK"; assert_no_file "$SHARE_DIR/job.plist"; assert_no_file "$SHARE_DIR/share-run.sh"; assert_no_file "$SHARE_DIR/gateway.json"
assert_eq "True" "$(jget "$SHARE_DIR/devices.json" 'd["devices"] == [] and d["blocked"] == []')"
assert_contains "$(order)" "control stop"
assert_calls_contain "^launchctl bootout ${TARGET}\$"
# the runner's trap wiped, and stop wiped the whole copy once more (status.wipe_failed users included)
assert_eq "$((wipes_before + 2))" "$(grep -c '^wipe ' "$MOCK_STATE/order")"
cli stop --json
assert_eq "0" "$CODE" "$OUT$ERR"
done_line
assert_eq "[]" "$(jget "$TMP_DIR/done.json" 'json.dumps(d["changed"])')"
assert_contains "$ERR" "unchanged"
assert_eq "$((wipes_before + 2))" "$(grep -c '^wipe ' "$MOCK_STATE/order")" "(a second stop wipes nothing)"
# stop is never refused: no terminal, BENCHBAR_NONINTERACTIVE, --for-agent
set +e; OUT="$(BENCHBAR_NONINTERACTIVE=1 "$FM" share stop --for-agent --bench-dir "$BENCH" 2>/dev/null)"; CODE=$?; set -e
assert_eq "0" "$CODE" "$OUT"
status_json
assert_eq "off" "$(sget 'd["state"]')"

# ---- the runner's checks are the real benchbar share preflight: its document is what the runner reads
reset_order; unset FL_SHARE_BENCHBAR; export BENCHBAR_SHARE_FIRST_TICK=200
cli start --for 30m
assert_eq "0" "$CODE" "$OUT$ERR"
assert_contains "$(cat "$SHARE_DIR/share-run.sh")" "BENCHBAR=\"${ROOT}/benchbar\""
wait_for 30 has_event '^caffeinate '
assert_not_contains "$(events)" "preflight" "(no stand-in ran)"
cli stop
assert_eq "0" "$CODE" "$OUT$ERR"
export FL_SHARE_BENCHBAR="$SB/benchbar" BENCHBAR_SHARE_FIRST_TICK=2

# ---- a runner killed with -9 (no trap): stop still boots the job out, removes what it left and wipes
reset_order
cli start --for 30m
assert_eq "0" "$CODE" "$OUT$ERR"
wait_for 15 has_event '^caffeinate '
kill -KILL "$(cat "$MOCK_STATE/agents/$LABEL.pid")"
wait_for 5 bash -c '! kill -0 "$1" 2>/dev/null' _ "$(cat "$MOCK_STATE/agents/$LABEL.pid")"
stop_recorded
assert_file "$SHARE_DIR/share-run.sh" "(kill -9 skips the trap: S6)"
status_json
assert_eq "error" "$(sget 'd["state"]')"
wipes_before="$(grep -c '^wipe ' "$MOCK_STATE/order")"
cli stop
assert_eq "0" "$CODE" "$OUT$ERR"
loaded && fail "booted out"
assert_no_file "$SHARE_DIR/share-run.sh"; assert_no_file "$SOCK"
assert_eq "$((wipes_before + 1))" "$(grep -c '^wipe ' "$MOCK_STATE/order")"
assert_contains "$(order | grep '^wipe ' | tail -n1)" "keep=[]"

# ---- the post-start checks fail (the share web port answers on the LAN): the job is stopped, exit 1
reset_order
printf '18097\n8443\n8001\n' >"$MOCK_STATE/lan_reachable_ports"
cli start --json
assert_eq "1" "$CODE" "$OUT$ERR"
done_line
assert_eq "1" "$(jget "$TMP_DIR/done.json" 'd["exit"]')"
assert_eq "False" "$(jget "$TMP_DIR/done.json" 'any("started until" in c["detail"] for c in d["changed"])')" "(no started change for a share that did not stay up)"
assert_contains "$ERR" "8001 answers on 192.168.1.20"
loaded && fail "the job is not loaded after a failed post-start check"
wait_for 15 every_recorded_gone
assert_no_file "$SOCK"; assert_no_file "$SHARE_DIR/job.plist"
healthy_world

# ---- degraded and expired
reset_order
cli start --for 5m
assert_eq "0" "$CODE" "$OUT$ERR"
printf 'Rooms on this Wi-Fi may not list this room for a moment: Bonjour was restarted.\n' >"$SHARE_DIR/degraded"
status_json
assert_eq "on" "$(sget 'd["state"]')"; assert_contains "$(sget 'd["degraded"]')" "Bonjour"
# the deadline passes: the gateway ends, the job stays loaded until stop; status reports expired and changes nothing
python3 - "$SHARE_DIR/gateway.json" <<'PY'
import json, sys, time
p = sys.argv[1]; d = json.load(open(p)); d["deadline_epoch"] = int(time.time()) - 1; json.dump(d, open(p, "w"))
PY
: >"$MOCK_STATE/gw_exit"
wait_for 15 bash -c '! kill -0 "$1" 2>/dev/null' _ "$(cat "$MOCK_STATE/agents/$LABEL.pid")"
snap="$(snapshot "$SHARE_DIR")"
status_json
assert_eq "expired 0" "$(sget 'd["state"] + " " + str(d["seconds_left"])')"
assert_eq "$snap" "$(snapshot "$SHARE_DIR")" "(status never cleans up)"
loaded || fail "an expired share stays loaded until stop"
cli stop
assert_eq "0" "$CODE"
rm -f "$MOCK_STATE/gw_exit"

# ---- status --preflight: the checks, each with its fix_action; a dead control is Local Network's
: >"$MOCK_STATE/lan_reachable_ports"
status_json_pre() { cli status --json --preflight; printf '%s' "$OUT" >"$TMP_DIR/status.json"; }
status_json_pre
assert_eq "False" "$(sget 'd["preflight"]["ok"]')"
assert_eq "fail open_local_network_settings" "$(sget 'next(c["status"] + " " + c["fix_action"] for c in d["preflight"]["checks"] if c["id"] == "local_network")')"
assert_eq "True" "$(sget 'all(set(c) == {"id", "class", "status", "message", "fix_action"} for c in d["preflight"]["checks"])')" "(no CLI fix string)"
healthy_world

# ---- the copy drifted: an app's HEAD moved since the copy was made
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com git -C "$BENCH/apps/erpnext" commit -q --allow-empty -m moved
status_json
assert_eq "True" "$(sget 'd["copy"]["drifted"] and next(a["now"] != a["at_copy"] for a in d["copy"]["apps"] if a["app"] == "erpnext")')"

# ---- --for and --name with spaces and quotes; the label is cleaned, share.json is not touched
cfg_sha="$(shasum -a 256 "$SHARE_DIR/share.json" | awk '{print $1}')"
reset_order
cli start --for 30m --name $'  Lab \xe2\x80\xae"b" $(x)  '
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "Lab \"b\" \$(x)" "$(jget "$SHARE_DIR/gateway.json" 'd["room_label"]')"
assert_eq "1800" "$(jget "$SHARE_DIR/gateway.json" 'd["deadline_epoch"] - d["started_epoch"]')"
wait_for 15 has_event '^dns-sd '
assert_contains "$(order)" "dns-sd -R Lab \"b\" \$(x) _benchbar-share._tcp local 8443 v=3 label=Lab \"b\" \$(x) site=macdev"
assert_eq "$cfg_sha" "$(shasum -a 256 "$SHARE_DIR/share.json" | awk '{print $1}')"
cli stop
assert_eq "0" "$CODE"
cli start --for=12h --name="x"
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "43200" "$(jget "$SHARE_DIR/gateway.json" 'd["deadline_epoch"] - d["started_epoch"]')"
cli stop

# ---- stop and extend have no dry run: refused before anything is touched
cli start --for 30m
assert_eq "0" "$CODE" "$OUT$ERR"
snap="$(snapshot "$SHARE_DIR")"; reset_calls; reset_order
cli stop --dry-run
assert_eq "1" "$CODE"; assert_contains "$OUT$ERR" "share stop has no dry run"
cli extend --by 1h --dry-run
assert_eq "1" "$CODE"; assert_contains "$OUT$ERR" "share extend has no dry run"
assert_eq "$snap" "$(snapshot "$SHARE_DIR")"
assert_calls_not_contain '^launchctl bootout'
assert_not_contains "$(order)" "control stop"

# ---- launchd still lists the job after the bootout: stop cleans up the rest and says so, exit 1
MOCK_BOOTOUT_LINGER=1000 MOCK_BOOTOUT_LINGER_LABEL="$LABEL" FL_BOOTOUT_WAIT_SECS=1 cli stop
assert_eq "1" "$CODE" "$OUT$ERR"
assert_contains "$OUT$ERR" "launchd still lists ${LABEL}"
assert_not_contains "$OUT$ERR" "Sharing stopped"
assert_no_file "$SHARE_DIR/gateway.json"; assert_no_file "$SOCK"
rm -f "$MOCK_STATE/agents/$LABEL" "$MOCK_STATE/agents/$LABEL.linger"
wait_for 15 every_recorded_gone

# ---- a wipe that fails (or a Redis port held by another process) never stops stop midway
cli start --for 30m
assert_eq "0" "$CODE" "$OUT$ERR"
: >"$MOCK_STATE/wipe_fail"
cli stop --json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_contains "$ERR" "could not end the sessions"
done_line
assert_eq "off" "$(jget "$TMP_DIR/done.json" 'd["state"]')"
loaded && fail "booted out although the wipe failed"
assert_file "$SHARE_DIR/wipe_failed"
status_json
assert_eq "off 1" "$(sget 'd["state"] + " " + str(d["wipe_failed"])')" "(status names it until a wipe works)"
rm -f "$MOCK_STATE/wipe_fail"
cli start --for 30m
assert_eq "0" "$CODE" "$OUT$ERR"
assert_no_file "$SHARE_DIR/wipe_failed" "(the runner's start-wipe worked)"
cli stop
wait_for 15 every_recorded_gone

# ---- a start on its way: status says starting with the phase; a second start refuses and tears nothing down
sleep 60 &
FAKE_RUNNER=$!
set_agent "$LABEL" running "$FAKE_RUNNER" 0
printf '%s starting:web\n' "$FAKE_RUNNER" >"$SHARE_DIR/phase"
printf '{"deadline_epoch":%s,"started_epoch":%s}\n' $(($(date +%s) + 600)) "$(date +%s)" >"$SHARE_DIR/gateway.json"
status_json
assert_eq "starting starting:web None" "$(sget '" ".join(str(x) for x in (d["state"], d["phase"], d["error"]))')"
reset_calls
cli start --for 30m
assert_eq "1" "$CODE" "$OUT$ERR"; assert_contains "$OUT$ERR" "already starting:web"
assert_calls_not_contain '^launchctl (bootout|bootstrap)'
assert_file "$SHARE_DIR/phase"; assert_file "$SHARE_DIR/gateway.json"
kill "$FAKE_RUNNER" 2>/dev/null || true; wait "$FAKE_RUNNER" 2>/dev/null || true
status_json
assert_eq "error" "$(sget 'd["state"]')" "(the runner is gone: no longer starting)"
cli stop
assert_eq "0" "$CODE" "$OUT$ERR"

# ---- a start whose runner gets no further than a phase is ended, and the phase is named
reset_order; printf 'hang\n' >"$MOCK_STATE/pre_script"
FL_SHARE_CHECKS_SECS=2 cli start --for 30m
assert_eq "1" "$CODE" "$OUT$ERR"
assert_contains "$OUT$ERR" "got no further than starting:checks"
loaded && fail "the stuck job is booted out"
wait_for 20 every_recorded_gone

# ---- a stop while a start is on its way (before the job is loaded): the start ends what it began
reset_order; : >"$MOCK_STATE/node_slow"
rm -f "$MOCK_STATE/node_slow_entered" "$MOCK_STATE/node_release"
( cli start --for 30m; printf '%s\n' "$CODE" >"$TMP_DIR/start.code"; printf '%s' "$OUT$ERR" >"$TMP_DIR/start.out" ) &
STARTER=$!
# the start is inside its static checks (node --version holds there): past clearing the marker, before the job
wait_for 20 test -f "$MOCK_STATE/node_slow_entered"
cli stop
assert_eq "0" "$CODE" "$OUT$ERR"; assert_contains "$OUT$ERR" "unchanged"
: >"$MOCK_STATE/node_release"
wait "$STARTER" || true
rm -f "$MOCK_STATE/node_slow" "$MOCK_STATE/node_slow_entered" "$MOCK_STATE/node_release"
assert_eq "1" "$(cat "$TMP_DIR/start.code")" "$(cat "$TMP_DIR/start.out")"
assert_contains "$(cat "$TMP_DIR/start.out")" "benchbar share stop was run while sharing was starting"
loaded && fail "the start did not leave a job behind"
assert_not_contains "$(events)" "web"
# a start of its own clears the marker
cli start --for 30m
assert_eq "0" "$CODE" "$OUT$ERR"
assert_no_file "$SHARE_DIR/stop_requested"
cli stop
wait_for 15 every_recorded_gone

# ---- a stale phase file (a runner SIGKILLed; the job no longer loaded) does not fail the next start
# a PID that has ended (one that exits by itself: a background subshell killed before it execs would run
# this test's EXIT trap)
/usr/bin/true &
DEAD=$!; wait "$DEAD" || true
printf '%s starting:web\n' "$DEAD" >"$SHARE_DIR/phase"
reset_order
cli start --for 30m
assert_eq "0" "$CODE" "$OUT$ERR"
wait_for 10 bash -c 'grep -q " running$" "$1" 2>/dev/null' _ "$SHARE_DIR/phase"

# ---- share.log is this share's: the last one is kept as share.log.1, and only that one
assert_contains "$(cat "$SHARE_DIR/share.log")" "sharing share.localhost"
cli stop
printf 'the previous share\n' >>"$SHARE_DIR/share.log"
# no watchdog ticks for this share: the web marked down below would otherwise be re-armed (rightly)
export BENCHBAR_SHARE_FIRST_TICK=2000
cli start --for 30m
assert_eq "0" "$CODE" "$OUT$ERR"
wait_for 15 bash -c 'grep -q "sharing share.localhost" "$1"' _ "$SHARE_DIR/share.log"
assert_contains "$(cat "$SHARE_DIR/share.log.1")" "the previous share"
assert_not_contains "$(cat "$SHARE_DIR/share.log")" "the previous share" "(a fresh log)"
logs=""; for f in "$SHARE_DIR"/share.log*; do logs="${logs}${logs:+ }${f##*/}"; done
assert_eq "share.log share.log.1" "$logs"

# ---- a second start while the first is on but the web is marked down: not "unchanged"
"$REAL_NODE" -e "$FL_JS_SHARE_CONTROL" control "$SOCK" '{"op":"web","state":"down"}' >/dev/null
cli start --for 30m
assert_eq "1" "$CODE" "$OUT$ERR"
assert_not_contains "$OUT$ERR" "unchanged"
assert_contains "$OUT$ERR" "is starting or has its web marked down (running)"
export BENCHBAR_SHARE_FIRST_TICK=2
cli stop
wait_for 15 every_recorded_gone

# ---- a second start while a share is still starting (its gateway answers, its checks are not done). While the
# first share start runs, the lock refuses a second one; this is the share whose start has gone (the app quit)
reset_order; printf 'ok\nhang\n' >"$MOCK_STATE/pre_script"
write_gateway_cfg $(($(date +%s) + 3600))
start_runner
set_agent "$LABEL" running "$RUNNER_PID" 0
wait_for 20 bash -c 'grep -q " starting:gateway$" "$1" 2>/dev/null && test -S "$2"' _ "$SHARE_DIR/phase" "$SOCK"
cli start --for 30m
assert_eq "1" "$CODE" "$OUT$ERR"
assert_not_contains "$OUT$ERR" "unchanged"
assert_contains "$OUT$ERR" "is starting or has its web marked down (starting:gateway)"
kill -TERM "$RUNNER_PID"; wait_for 20 runner_gone
finish_runner
rm -f "$MOCK_STATE/agents/$LABEL" "$SHARE_DIR/gateway.json"

# ================================================================ Review Focus 5: the job is not a bench agent
reset_calls
set_agent "$LABEL" running 4243 0
listing="$(SCRIPT_DIR="$ROOT" FL_BENCH_DIR="$BENCH" bash -c '
  . "$1/lib/frappe-local/ui.sh"; . "$1/lib/frappe-local/run.sh"; . "$1/lib/frappe-local/benchinfo.sh"; . "$1/lib/frappe-local/launchd.sh"; . "$1/lib/frappe-local/process.sh"
  fl_same_path() { [[ "$1" == "$2" ]]; }
  printf "files[%s] dead[%s] dir[%s]" "$(fl_agent_files all)" "$(fl_dead_agents_list)" "$(fl_agents_for_dir "$FL_BENCH_DIR")"' _ "$ROOT")"
assert_eq "files[] dead[] dir[]" "$listing"
run_fm uninstall-service --all --yes
assert_calls_not_contain "bootout .*${LABEL}"
run_fm doctor --json --bench-dir "$BENCH"
assert_not_contains "$OUT" "$LABEL"
rm -f "$MOCK_STATE/agents/$LABEL"
# benchbar down's pattern does not reach the share web (S6/A3): that is why the checks probe Redis
pattern="$(SCRIPT_DIR="$ROOT" FL_BENCH_DIR="$BENCH" bash -c '. "$1/lib/frappe-local/process.sh"; fl_bench_helper_pattern' _ "$ROOT")"
for cmdline in "${BENCH}/env/bin/python ${ROOT}/lib/frappe-local/share/share_web.py --site share.localhost --port 8001" \
  "/usr/bin/env -u DEV_SERVER CI=1 ${BENCH}/env/bin/python ${ROOT}/lib/frappe-local/share/share_web.py --site share.localhost --port 8001"; do
  if printf '%s\n' "$cmdline" | grep -qE "$pattern"; then fail "benchbar down's pattern matches the share web: $cmdline"; fi
done
printf '%s\n' "${BENCH}/env/bin/python -m frappe.utils.bench_helper frappe serve --port 8000" | grep -qE "$pattern" || fail "the pattern still matches the bench's own web"

printf 'test-share-run: ok\n'
