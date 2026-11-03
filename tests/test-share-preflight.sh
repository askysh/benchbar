#!/usr/bin/env bash
# benchbar share preflight: the checks that prove the Mac is safe to share a hardened copy on the LAN.
# Every program it runs is a mock (nc, curl, route, ipconfig, ifconfig, socketfilterfw, node, the bench's
# Python), reached through the FL_* seams, so nothing here touches the machine's pf, firewall or network.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH" macdev
cp "$ROOT/tests/mocks/frappe-python" "$BENCH/env/bin/python"; chmod +x "$BENCH/env/bin/python"
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

write_copy_config() { printf '{\n "db_name": "_share",\n "developer_mode": %s,\n "server_script_enabled": %s\n}\n' "${1:-0}" "${2:-0}" >"$COPY/site_config.json"; }
write_share_json() {
  cat >"$SHARE_DIR/share.json" <<JSON
{
  "v": 3,
  "site": "macdev",
  "share_site": "share.localhost",
  "allowed_users": ["priya@example.com","mgr@example.com"],
  "room_label": "Lab",
  "seats": [
    {"seat_id":"s_0a1b2c3d","user":"priya@example.com","full_name":"Priya Nair","roles":["NE"]},
    {"seat_id":"s_1a2b3c4d","user":"mgr@example.com","full_name":"Mgr \\"M\\" Singh","roles":["Sales User"]}
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
}

# node: a symlink (like Homebrew's bin/node) to a real file two folders down
NODE_REAL_DIR="$TMP_DIR/nodes/cellar/22/bin"; NODE_LINK_DIR="$TMP_DIR/nodes/bin"
mkdir -p "$NODE_REAL_DIR" "$NODE_LINK_DIR"
cp "$ROOT/tests/mocks/node" "$NODE_REAL_DIR/node"; chmod 755 "$NODE_REAL_DIR/node"
ln -s "$NODE_REAL_DIR/node" "$NODE_LINK_DIR/node"
export FL_SHARE_NODE="$NODE_LINK_DIR/node"

# the Phase 0 pf anchor and daemon, as lan-guard writes them
PF_DIR="$TMP_DIR/pf"; mkdir -p "$PF_DIR"
export FL_LANGUARD_ANCHOR="$PF_DIR/com.benchbar.lan" FL_LANGUARD_DAEMON="$PF_DIR/com.benchbar.pf.plist"
write_anchor() {
  cat >"$FL_LANGUARD_ANCHOR" <<'PF'
# BenchBar: Frappe bench ports answer this Mac only.
ports = "{ 8000:8099, 9000:9099, 11000:11099, 13000:13099, 3306 }"
block return in quick inet  proto tcp from ! 127.0.0.1 to any port $ports
block return in quick inet6 proto tcp from ! ::1 to any port $ports
PF
  sed -n "/^FL_SHARE_PF_PLIST='/,/'\$/p" "$ROOT/lib/frappe-local/share-preflight.sh" | sed "s/^FL_SHARE_PF_PLIST='//; s/'\$//" >"$FL_LANGUARD_DAEMON"
}

export FL_NC="$ROOT/tests/mocks/bin/nc" FL_CURL="$ROOT/tests/mocks/bin/curl" FL_SOCKETFILTERFW="$ROOT/tests/mocks/bin/socketfilterfw"
export FL_ROUTE="$ROOT/tests/mocks/bin/route" FL_IPCONFIG="$ROOT/tests/mocks/bin/ipconfig" FL_IFCONFIG="$ROOT/tests/mocks/bin/ifconfig"

# reset_world: a healthy Mac: a LAN address, the block working (the in-range listener refused, the
# control answering), the share web process and the bench's Redis up on loopback, the firewall off
reset_world() {
  rm -rf "$MOCK_STATE/fw_state" "$MOCK_STATE/fw_app" "$MOCK_STATE/share_check" "$MOCK_STATE/share_http" "$MOCK_STATE/share_http_down" \
    "$MOCK_STATE/share_http_404" "$MOCK_STATE/ifconfig6" "$MOCK_STATE/listener_fail" "$MOCK_STATE/listener_dead"
  mkdir -p "$MOCK_STATE/share_http"
  printf 'en0\n' >"$MOCK_STATE/lan_iface"; printf '192.168.1.20\n' >"$MOCK_STATE/lan_ip"
  printf '8001\n13000\n' >"$MOCK_STATE/loopback_ports"
  printf '18097\n' >"$MOCK_STATE/lan_reachable_ports"
  rm -f "$SHARE_DIR/control.sock"
  write_copy_config; write_share_json; write_anchor
  chmod 755 "$TMP_DIR/nodes" "$TMP_DIR/nodes/cellar" "$TMP_DIR/nodes/cellar/22" "$NODE_REAL_DIR" "$NODE_LINK_DIR"
  unset FL_SHARE_ADMIN_GROUP
  serve_healthy_web
}
# what a healthy share web process (Frappe v15, the debugger off, allow_error_traceback 0) answers a Guest:
# the login page at / (also for the debugger URL, whose path is /), and exc_type with no traceback for an API error
serve_healthy_web() {
  serve "$WEB/" "HTTP/1.1 200 OK" "Content-Type: text/html; charset=utf-8" "<title>Login</title>"
  serve "$DEBUGGER_URL" "HTTP/1.1 200 OK" "Content-Type: text/html; charset=utf-8" "<title>Login</title>"
  serve "$TRACEBACK_URL" "HTTP/1.1 417 EXPECTATION FAILED" "Content-Type: application/json" \
    '{"exc_type":"ValidationError","_server_messages":"[\"{\\\"message\\\": \\\"Failed to get method for command benchbar.no.such.method\\\"}\"]"}'
}
http_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
# serve URL STATUS_LINE HEADER BODY: a raw response for the curl mock
serve() { printf '%s\r\n%s\r\n\r\n%s\n' "$2" "$3" "$4" >"$MOCK_STATE/share_http/$(http_key "$1")"; }
WEB=http://127.0.0.1:8001
TRACEBACK_URL="$WEB/api/method/benchbar.no.such.method"
DEBUGGER_URL="$WEB/?__debugger__=yes&cmd=resource&f=style.css"

pre() {
  set +e
  "$FM" share preflight --json --bench-dir "$BENCH" "$@" >"$TMP_DIR/pre.out" 2>"$TMP_DIR/pre.err"
  CODE="$?"
  set -e
  OUT="$(cat "$TMP_DIR/pre.out")"; ERR="$(cat "$TMP_DIR/pre.err")"
  listener_gone
}
# listener_gone: the throwaway listener of the last run (if it started) is not running any more
listener_gone() {
  [[ -s "$MOCK_STATE/listener_pid" ]] || return 0
  local pid; pid="$(cat "$MOCK_STATE/listener_pid")"; rm -f "$MOCK_STATE/listener_pid"
  ! kill -0 "$pid" 2>/dev/null || fail "the throwaway listener (pid $pid) outlived the run"
}
st() { jget "$TMP_DIR/pre.out" 'next(c["status"] for c in d["checks"] if c["id"] == "'"$1"'")'; }
fld() { jget "$TMP_DIR/pre.out" 'next(c["'"$2"'"] for c in d["checks"] if c["id"] == "'"$1"'")'; }
ids() { jget "$TMP_DIR/pre.out" '" ".join(c["id"] for c in d["checks"])'; }
assert_check() { # ID STATUS [MESSAGE_PART] [FIX_ACTION]
  assert_eq "$2" "$(st "$1")" "(check $1: $OUT)"
  [[ -z "${3:-}" ]] || assert_contains "$(fld "$1" message)" "$3" "(check $1)"
  [[ -z "${4:-}" ]] || assert_eq "$4" "$(fld "$1" fix_action)" "(check $1)"
}

# ---------------------------------------------------------------- a healthy Mac: every check ok
reset_world
pre
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "True" "$(jget "$TMP_DIR/pre.out" 'd["ok"] and d["protocol"] == 3 and d["lan_ip"] == "192.168.1.20" and d["schema_version"] == 1 and "cli_version" in d')"
for id in lan_ip local_network pf_active share_web_lan_closed share_traceback_off bench_redis_up share_debugger_off \
  firewall_node developer_mode_off server_script_off signup_disabled admin_password_not_default seats_valid no_api_keys node_ok copy_ready copy_drift cli_protocol; do
  assert_check "$id" ok
done
assert_check gateway_reachable skip "not running"
assert_eq "True" "$(jget "$TMP_DIR/pre.out" 'all(c["class"] in ("static", "critical") and c["status"] in ("ok", "fail", "warn", "skip") for c in d["checks"])')"
assert_eq "critical" "$(fld pf_active class)"; assert_eq "static" "$(fld node_ok class)"
# the document is the only thing on stdout, and it is one document
assert_eq "1" "$(wc -l <"$TMP_DIR/pre.out" | tr -d ' ')" "(one line of JSON)"
# the throwaway listener ran under node with the 0.0.0.0 address inside the pf range and a control above 18000
assert_calls_contain "^nc .*-z -w1 192.168.1.20 8097"; assert_calls_contain "^nc .*-z -w1 192.168.1.20 18097"
assert_calls_not_contain "^nc .*-6 "

# ---------------------------------------------------------------- pf_active: not vacuous
# a mock that answers everywhere (a probe that proves nothing, or a block that does not work) fails
printf '8097\n18097\n' >"$MOCK_STATE/lan_reachable_ports"
pre --critical
assert_eq "1" "$CODE" "$OUT"
assert_check pf_active fail "8097 answers on 192.168.1.20" install_network_protection
assert_eq "False" "$(jget "$TMP_DIR/pre.out" 'd["ok"]')"
# a mock that refuses everywhere: the probe itself does not work, and the app is told about Local Network
: >"$MOCK_STATE/lan_reachable_ports"
pre --critical
assert_eq "1" "$CODE" "$OUT"
assert_check pf_active fail "the probe itself does not work" open_local_network_settings
assert_check local_network fail "Local Network" open_local_network_settings
# the control fails and a pf file is wrong too: the pf file is what to fix first
rm -f "$FL_LANGUARD_DAEMON"
pre --critical; assert_check pf_active fail "the probe itself does not work" install_network_protection
write_anchor
# a listener node cannot open, or a node that dies: never ok
printf '18097\n' >"$MOCK_STATE/lan_reachable_ports"
: >"$MOCK_STATE/listener_fail"
pre --critical
assert_check pf_active fail "could not open"; assert_eq "1" "$CODE"
rm -f "$MOCK_STATE/listener_fail"; : >"$MOCK_STATE/listener_dead"
pre --critical
assert_check pf_active fail "could not open"; assert_eq "1" "$CODE"
rm -f "$MOCK_STATE/listener_dead"
# the other bench ports are probed only when something listens on loopback
printf '18097\n3306\n8000\n' >"$MOCK_STATE/lan_reachable_ports"
pre --critical
assert_check pf_active ok; assert_eq "0" "$CODE" "(not listening on loopback: not probed)"
printf '8001\n13000\n3306\n8000\n' >"$MOCK_STATE/loopback_ports"
pre --critical
assert_check pf_active fail "3306 answers on 192.168.1.20" install_network_protection
assert_contains "$(fld pf_active message)" "8000 answers"
printf '18097\n11000\n13000\n' >"$MOCK_STATE/lan_reachable_ports"
printf '11000\n13000\n8001\n' >"$MOCK_STATE/loopback_ports"
pre --critical
assert_check pf_active fail "11000 answers"; assert_contains "$(fld pf_active message)" "13000 answers"
# the share web port reachable from the LAN: its own check says the caller stops everything
printf '18097\n8001\n' >"$MOCK_STATE/lan_reachable_ports"
pre --critical
assert_check share_web_lan_closed fail "8001 answers on 192.168.1.20" restart_sharing
assert_check pf_active fail "8001 answers"

# ---------------------------------------------------------------- pf_active: IPv6
reset_world
printf '18097\n6:18098\n' >"$MOCK_STATE/lan_reachable_ports"
printf '    inet6 fe80::1c2b:3d4e:5f60:7182%%en0 prefixlen 64 secured scopeid 0xd\n    inet6 2401:4900:1:2::99 prefixlen 64 autoconf secured\n' >"$MOCK_STATE/ifconfig6"
pre --critical
assert_eq "0" "$CODE" "$OUT"; assert_check pf_active ok
assert_calls_contain "^nc -z -w1 -6 2401:4900:1:2::99 8098\$"; assert_calls_contain "^nc -z -w1 -6 2401:4900:1:2::99 18098\$"
# only a link-local address: probed with its scope
printf '    inet6 fe80::1c2b:3d4e:5f60:7182%%en0 prefixlen 64 secured scopeid 0xd\n' >"$MOCK_STATE/ifconfig6"
pre --critical
assert_check pf_active ok; assert_calls_contain "^nc -z -w1 -6 fe80::1c2b:3d4e:5f60:7182%en0 8098\$"
# the IPv6 in-range listener answers: fail naming it
printf '18097\n6:18098\n6:8098\n' >"$MOCK_STATE/lan_reachable_ports"
pre --critical
assert_check pf_active fail "IPv6" install_network_protection; assert_contains "$(fld pf_active message)" "8098"
# IPv4 fine but the IPv6 control does not answer: the IPv6 probe does not work
printf '18097\n' >"$MOCK_STATE/lan_reachable_ports"
pre --critical
assert_check pf_active fail "IPv6" open_local_network_settings; assert_contains "$(fld pf_active message)" "the probe itself does not work"
# no IPv6 address at all: no IPv6 probe, no failure
rm -f "$MOCK_STATE/ifconfig6"; reset_world
pre --critical
assert_check pf_active ok

# ---------------------------------------------------------------- the LAN address
reset_world
rm -f "$MOCK_STATE/lan_iface"; : >"$MOCK_LOG"
pre
assert_eq "1" "$CODE" "$OUT"
assert_check lan_ip fail "no LAN address"
assert_eq "None" "$(jget "$TMP_DIR/pre.out" 'd["lan_ip"]')"
for id in pf_active local_network gateway_reachable share_web_lan_closed; do assert_eq "skip" "$(st "$id")" "($id without a LAN address)"; done
assert_eq "False" "$(jget "$TMP_DIR/pre.out" 'd["ok"]')"
assert_calls_not_contain "^nc .*192"
# an interface with no IPv4 address (a VPN's) is no LAN address either
reset_world; printf 'utun4\n' >"$MOCK_STATE/lan_iface"; rm -f "$MOCK_STATE/lan_ip"
pre --critical
assert_check lan_ip fail "no LAN address"

# ---------------------------------------------------------------- the gateway
reset_world
touch "$SHARE_DIR/control.sock"
pre --critical
assert_check gateway_reachable fail "8443" restart_sharing
printf '18097\n8443\n' >"$MOCK_STATE/lan_reachable_ports"
pre --critical
assert_check gateway_reachable ok; assert_eq "0" "$CODE" "$OUT"

# ---------------------------------------------------------------- no share web port: a critical run fails closed
reset_world; rm -f "$SHARE_DIR/share.json"
pre --critical
assert_eq "1" "$CODE" "$OUT"; assert_eq "False" "$(jget "$TMP_DIR/pre.out" 'd["ok"]')"
for id in share_web_lan_closed share_traceback_off share_debugger_off; do assert_check "$id" fail "no share.json" rerun_setup; done
reset_world; sed_inplace 's/"web_port": 8001/"web_port": "x"/' "$SHARE_DIR/share.json"
pre --critical
assert_eq "1" "$CODE" "$OUT"
for id in share_web_lan_closed share_traceback_off share_debugger_off; do assert_check "$id" fail "no usable share web port" restart_sharing; done

# ---------------------------------------------------------------- the share web process: debugger, tracebacks, Redis
reset_world
serve "$DEBUGGER_URL" "HTTP/1.1 200 OK" "Content-Type: text/css; charset=utf-8" "body{}"
pre --critical
assert_check share_debugger_off fail "debugger" restart_sharing; assert_eq "1" "$CODE"
reset_world
serve "$WEB/console" "HTTP/1.1 200 OK" "Content-Type: text/html" "<html>console</html>"
pre --critical; assert_check share_debugger_off fail
reset_world
serve "$WEB/" "HTTP/1.1 302 FOUND" "Content-Type: text/html" "<title>Debugger - Werkzeug</title>"
pre --critical; assert_check share_debugger_off fail
reset_world
serve "$WEB/" "HTTP/1.1 302 FOUND" "Content-Type: text/css" "x"
pre --critical; assert_check share_debugger_off fail
reset_world
serve "$WEB/" "HTTP/1.1 200 OK" "Content-Type: text/html" "<title>Home</title>"
pre --critical; assert_check share_debugger_off ok "" "" # the home page itself may be a 200
assert_calls_contain "^curl .*-D .*127.0.0.1:8001/console"; assert_calls_contain "^curl .*__debugger__=yes&cmd=resource&f=style.css"
# the web process down: nothing proves the debugger is off
printf 'x' >"$MOCK_STATE/share_http_down"
pre --critical
assert_check share_debugger_off fail "does not answer"; assert_check share_traceback_off fail "does not answer"
reset_world
serve "$TRACEBACK_URL" "HTTP/1.1 404 NOT FOUND" "Content-Type: application/json" '{"exc_type":"ValidationError","exc":"[\"Traceback (most recent call last):\"]"}'
pre --critical
assert_check share_traceback_off fail "traceback" rerun_setup; assert_eq "1" "$CODE"
serve "$TRACEBACK_URL" "HTTP/1.1 404 NOT FOUND" "Content-Type: application/json" '{"exc": "x"}'
pre --critical; assert_check share_traceback_off fail
serve "$TRACEBACK_URL" "HTTP/1.1 417 EXPECTATION FAILED" "Content-Type: application/json" '{"exc_type":"ValidationError","exception":"frappe.exceptions.ValidationError: x"}'
pre --critical; assert_check share_traceback_off fail
serve "$TRACEBACK_URL" "HTTP/1.1 500 INTERNAL SERVER ERROR" "Content-Type: text/html" "<pre>Traceback (most recent call last):</pre>"
pre --critical; assert_check share_traceback_off fail
serve "$TRACEBACK_URL" "HTTP/1.1 404 NOT FOUND" "Content-Type: application/json" '{"message":"not found","_server_messages":"[]"}'
pre --critical; assert_check share_traceback_off ok
reset_world # exc_type alone is no traceback: Frappe sends it on every API error
pre --critical; assert_check share_traceback_off ok; assert_check share_debugger_off ok
# the bench's Redis
reset_world; printf '8001\n' >"$MOCK_STATE/loopback_ports"
pre --critical
assert_check bench_redis_up fail "13000" none; assert_contains "$(fld bench_redis_up message)" "stopped"
assert_calls_contain "^nc .*-z -w1 127.0.0.1 13000"

# ---------------------------------------------------------------- the firewall and node
reset_world
printf 'Firewall is enabled. (State = 1)\n' >"$MOCK_STATE/fw_state"
printf 'Incoming connection to %%PATH%% is blocked.\n' >"$MOCK_STATE/fw_app"
: >"$MOCK_LOG"
pre --static
assert_check firewall_node fail "macOS is blocking incoming connections to node." allow_node_firewall
assert_eq "1" "$CODE" "$OUT"
assert_calls_contain "^socketfilterfw --getappblocked $NODE_REAL_DIR/node\$"
assert_calls_not_contain "getappblocked $NODE_LINK_DIR/node"
printf 'Incoming connection to %%PATH%% is permitted.\n' >"$MOCK_STATE/fw_app"
pre --static; assert_check firewall_node ok
printf 'something nobody has seen\n' >"$MOCK_STATE/fw_app"
pre --static; assert_check firewall_node fail "" allow_node_firewall
printf 'Mystery firewall output\n' >"$MOCK_STATE/fw_state"
pre --static; assert_check firewall_node fail "" allow_node_firewall
# block all incoming connections: no allow for node overrides it, and the CLI offers no fix
printf 'Firewall is enabled. (State = 2)\n' >"$MOCK_STATE/fw_state"; printf 'Incoming connection to %%PATH%% is permitted.\n' >"$MOCK_STATE/fw_app"
: >"$MOCK_LOG"
pre --static; assert_check firewall_node fail "macOS is blocking all incoming connections." none; assert_eq "1" "$CODE"
assert_eq "None" "$(fld firewall_node fix)"; assert_calls_not_contain "getappblocked"
rm -f "$MOCK_STATE/fw_state" "$MOCK_STATE/fw_app"; : >"$MOCK_LOG"
pre --static; assert_check firewall_node ok # off, as measured on a Mac
assert_calls_not_contain "getappblocked" "(off: the app is not asked)"

# node_ok: the owner, the mode of every parent, the group
reset_world
pre --static; assert_check node_ok ok
chmod 775 "$TMP_DIR/nodes/cellar"
: >"$MOCK_STATE/node_calls"
pre --static; assert_check node_ok fail "group" none; assert_eq "1" "$CODE"
assert_eq "" "$(cat "$MOCK_STATE/node_calls")" "(a node in an unsafe path is never run, not even --version)"
assert_eq "skip" "$(st firewall_node)"
# a critical run vets the same path before it starts the listener with it
pre --critical
assert_check pf_active fail "Node cannot be trusted to run the gateway" none; assert_contains "$(fld pf_active message)" "group-writable"
assert_eq "skip" "$(st local_network)"
assert_eq "" "$(cat "$MOCK_STATE/node_calls")" "(no listener from an unsafe node)"
FL_SHARE_ADMIN_GROUP="$(id -gn)" pre --static; assert_check node_ok ok "" "" # group-writable by admin (Homebrew's own mode)
chmod 755 "$TMP_DIR/nodes/cellar"; chmod 757 "$TMP_DIR/nodes/cellar"
FL_SHARE_ADMIN_GROUP="$(id -gn)" pre --static; assert_check node_ok fail "world" none
# a sticky world-writable folder (like /tmp: 1777) is not held against what lies below it; this reads the
# special bits on the platform the suite runs on (BSD stat's %Lp alone drops them)
chmod 1757 "$TMP_DIR/nodes/cellar"
FL_SHARE_ADMIN_GROUP="$(id -gn)" pre --static; assert_check node_ok ok "" ""
chmod 755 "$TMP_DIR/nodes/cellar"; chmod 757 "$NODE_REAL_DIR/node"
pre --static; assert_check node_ok fail "world"
chmod 755 "$NODE_REAL_DIR/node"
printf '#!/bin/bash\necho v20.11.0\n' >"$NODE_REAL_DIR/node"
pre --static; assert_check node_ok fail "22"
cp "$ROOT/tests/mocks/node" "$NODE_REAL_DIR/node"
FL_SHARE_NODE=node pre --static; assert_check node_ok fail "absolute"
FL_SHARE_NODE="$TMP_DIR/nodes/none" pre --static; assert_check node_ok fail

# ---------------------------------------------------------------- the copy and the helper
reset_world
write_copy_config 1 0
pre --static; assert_check developer_mode_off fail "developer_mode" rerun_setup; assert_eq "1" "$CODE"
write_copy_config 0 true
pre --static; assert_check server_script_off fail "server_script_enabled" rerun_setup
write_copy_config 0 0
# the site's own value wins over common_site_config.json
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["developer_mode"]=1; json.dump(d, open(p,"w"), indent=1)' "$BENCH/sites/common_site_config.json"
pre --static; assert_check developer_mode_off ok
printf '{\n "db_name": "_share"\n}\n' >"$COPY/site_config.json"
pre --static; assert_check developer_mode_off fail
write_copy_config
# the helper's answers, one at a time
printf 'flag\tsignup_disabled\t0\nflag\tadmin_default\t0\ncount\tapi_keys\t0\ncount\tapi_secrets\t0\ncount\toauth_rows\t0\ndone\n' >"$MOCK_STATE/share_check"
pre --static; assert_check signup_disabled fail "Sign ups are open" rerun_setup; assert_check admin_password_not_default ok; assert_eq "1" "$CODE"
printf 'flag\tsignup_disabled\t1\nflag\tadmin_default\t1\ncount\tapi_keys\t0\ncount\tapi_secrets\t0\ncount\toauth_rows\t0\ndone\n' >"$MOCK_STATE/share_check"
pre --static; assert_check admin_password_not_default fail "well-known default password" rerun_setup
assert_not_contains "$OUT$ERR" "admin123"; assert_not_contains "$OUT$ERR" "password\":"
printf 'flag\tsignup_disabled\t1\nflag\tadmin_default\t0\nseat\tpriya@example.com\trole\tAuditor\nseat\tmgr@example.com\tdisabled\t\ncount\tapi_keys\t0\ncount\tapi_secrets\t0\ncount\toauth_rows\t0\ndone\n' >"$MOCK_STATE/share_check"
pre --static
assert_check seats_valid fail "Priya Nair holds the role Auditor" rerun_setup
assert_contains "$(fld seats_valid message)" 'Mgr "M" Singh is disabled in the copy'
printf 'flag\tsignup_disabled\t1\nflag\tadmin_default\t0\nseat\tmgr@example.com\tnot_system_user\t\nseat\tpriya@example.com\tmissing\t\ncount\tapi_keys\t0\ncount\tapi_secrets\t0\ncount\toauth_rows\t0\ndone\n' >"$MOCK_STATE/share_check"
pre --static
assert_contains "$(fld seats_valid message)" "is not a System User"; assert_contains "$(fld seats_valid message)" "missing from the copy"
printf 'flag\tsignup_disabled\t1\nflag\tadmin_default\t0\ncount\tapi_keys\t2\ncount\tapi_secrets\t1\ncount\toauth_rows\t4\ndone\n' >"$MOCK_STATE/share_check"
pre --static
assert_check no_api_keys fail "2 API keys, 1 API secrets and 4 OAuth token rows" rerun_setup
# the seats go to the helper on stdin, never in argv
assert_eq "priya@example.com
mgr@example.com" "$(cat "$MOCK_STATE/stdin-share-check")"
assert_calls_contain "^bench-python benchbar-share-check \[share.localhost\]\$"
# a helper that says nothing (it crashed): every check that depends on it fails closed
printf 'garbage\n' >"$MOCK_STATE/share_check"
pre --static
for id in signup_disabled admin_password_not_default seats_valid no_api_keys; do assert_check "$id" fail "" rerun_setup; done
rm -f "$MOCK_STATE/share_check"
# a share.json with no seats: said so, not a crash (bash 3.2 and an empty array under set -u; the error
# dies inside a command substitution, so only stderr shows it)
reset_world; sed_inplace '/"seat_id"/d' "$SHARE_DIR/share.json"
pre --static; assert_check seats_valid fail "lists no seats" rerun_setup; assert_check signup_disabled ok
assert_not_contains "$ERR" "unbound variable"
# no copy yet
reset_world; rm -f "$SHARE_DIR/share.json"
: >"$MOCK_LOG"
pre --static
assert_check copy_ready fail "share setup" rerun_setup
for id in signup_disabled admin_password_not_default seats_valid no_api_keys copy_drift; do assert_eq "skip" "$(st "$id")" "($id needs the copy)"; done
assert_calls_not_contain "benchbar-share-check"
reset_world; rm -rf "$COPY"
pre --static; assert_check copy_ready fail "share.localhost" rerun_setup
mkdir -p "$COPY"; reset_world
sed_inplace 's/"v": 3/"v": 2/' "$SHARE_DIR/share.json"
pre --static; assert_check copy_ready fail "older" rerun_setup
# the code changed since the copy: a warning, not a failure
reset_world
git -C "$BENCH/apps/erpnext" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m "newer"
pre --static
assert_check copy_drift warn "" refresh_copy
assert_eq "Your code changed since the copy was made: refresh to avoid errors." "$(fld copy_drift message)" "(the app's own words, nothing appended)"
assert_eq "['erpnext']" "$(fld copy_drift apps)"
assert_eq "0" "$CODE" "$OUT"; assert_eq "True" "$(jget "$TMP_DIR/pre.out" 'd["ok"]')"
assert_check cli_protocol ok "3"

# ---------------------------------------------------------------- the pf files
reset_world
rm -f "$FL_LANGUARD_ANCHOR"
pre --critical; assert_check pf_active fail "anchor" install_network_protection
reset_world
sed_inplace 's/8000:8099/8000:8199/' "$FL_LANGUARD_ANCHOR"
pre --critical; assert_check pf_active fail "does not match" install_network_protection
reset_world
rm -f "$FL_LANGUARD_DAEMON"
pre --critical; assert_check pf_active fail "daemon" install_network_protection
# comments and blank lines are not compared
reset_world; printf '\n# another comment\n' >>"$FL_LANGUARD_ANCHOR"
pre --critical; assert_check pf_active ok

# ---------------------------------------------------------------- the document: modes, exit code, fix_action enum
reset_world
pre --critical
assert_eq "lan_ip local_network pf_active gateway_reachable share_web_lan_closed share_traceback_off bench_redis_up share_debugger_off" "$(ids)"
pre --static
assert_eq "node_ok firewall_node copy_ready developer_mode_off server_script_off signup_disabled admin_password_not_default seats_valid no_api_keys copy_drift cli_protocol" "$(ids)"
# --critical runs no static check (the helper is not asked), --static runs no probe
reset_world; : >"$MOCK_LOG"
pre --critical
assert_calls_not_contain "benchbar-share-check|socketfilterfw|redis-server"
reset_world; : >"$MOCK_LOG"
pre --static
assert_calls_not_contain "^(nc|curl|route|ipconfig) "
reset_world; : >"$MOCK_LOG"
pre
assert_eq "True" "$(jget "$TMP_DIR/pre.out" 'len(d["checks"]) == 19')" "(no flag: both)"
# every failing check has a fix_action from the enum; a fail exits 1 and the document is still printed
reset_world
printf 'Firewall is enabled. (State = 1)\n' >"$MOCK_STATE/fw_state"; printf 'Incoming connection to %%PATH%% is blocked.\n' >"$MOCK_STATE/fw_app"
printf '8097\n18097\n' >"$MOCK_STATE/lan_reachable_ports"; printf '8001\n' >"$MOCK_STATE/loopback_ports"
write_copy_config 1 1; printf 'flag\tsignup_disabled\t0\nflag\tadmin_default\t1\nseat\tpriya@example.com\trole\tAuditor\ncount\tapi_keys\t1\ncount\tapi_secrets\t0\ncount\toauth_rows\t0\ndone\n' >"$MOCK_STATE/share_check"
serve "$TRACEBACK_URL" "HTTP/1.1 404 NOT FOUND" "Content-Type: application/json" '{"exc_type":"X","exc":"[]"}'
serve "$WEB/console" "HTTP/1.1 200 OK" "Content-Type: text/html" "x"
pre
assert_eq "1" "$CODE"
assert_eq "True" "$(jget "$TMP_DIR/pre.out" 'd["ok"] is False and sum(c["status"] == "fail" for c in d["checks"]) >= 10')"
assert_eq "True" "$(jget "$TMP_DIR/pre.out" 'all(c["fix_action"] in ("install_network_protection", "allow_node_firewall", "open_local_network_settings", "update_cli", "rerun_setup", "refresh_copy", "restart_sharing", "none") for c in d["checks"] if c["status"] in ("fail", "warn"))')"
assert_eq "True" "$(jget "$TMP_DIR/pre.out" 'all(c["fix"] for c in d["checks"] if c["status"] == "fail" and c["fix_action"] != "none")')" "(a terminal fix for every fail with an action)"
# nothing secret or private in the document or the text: no room code (preflight never sees one)
assert_not_contains "$OUT$ERR" "mock-admin-password"
# --quiet: the text lists what is wrong, not what is fine; plain text is not JSON
reset_world
set +e; "$FM" share preflight --quiet --bench-dir "$BENCH" >"$TMP_DIR/text.out" 2>&1; CODE="$?"; set -e
assert_eq "0" "$CODE" "$(cat "$TMP_DIR/text.out")"; assert_not_contains "$(cat "$TMP_DIR/text.out")" "pf_active"
printf '8097\n18097\n' >"$MOCK_STATE/lan_reachable_ports"
set +e; "$FM" share preflight --quiet --critical --bench-dir "$BENCH" >"$TMP_DIR/text.out" 2>&1; CODE="$?"; set -e
assert_eq "1" "$CODE"; assert_contains "$(cat "$TMP_DIR/text.out")" "8097 answers"
set +e; "$FM" share preflight --critical --bench-dir "$BENCH" >"$TMP_DIR/text.out" 2>&1; set -e
assert_contains "$(cat "$TMP_DIR/text.out")" "lan_ip"
# arguments
run_fm share preflight --bogus --bench-dir "$BENCH"; assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "Unknown argument for share preflight: --bogus"
run_fm share preflight extra --bench-dir "$BENCH"; assert_eq "1" "$CODE" "$OUT"
# a read: no lock, no change to the bench, the hosts file or the share folder
reset_world
before="$(snapshot "$BENCH" "$FL_HOSTS_FILE" "$SHARE_DIR")"
pre
assert_eq "$before" "$(snapshot "$BENCH" "$FL_HOSTS_FILE" "$SHARE_DIR")" "(preflight writes nothing)"
# the command table knows it, as a document that does not change anything
assert_eq "True" "$(BENCHBAR_TEST_X=1 "$FM" commands --json | python3 -c 'import json,sys; d=json.load(sys.stdin); c = [x for x in d["commands"] if x["name"] == "share preflight"][0]; print(c["json"] == "document" and c["mutating"] is False)')"

# ---------------------------------------------------------------- the listener never outlives the run
# a run stopped by a signal while its listener is up (a probe in flight) still stops it: the EXIT trap
reset_world; rm -f "$MOCK_STATE/listener_pid"; : >"$MOCK_STATE/nc_slow"
"$FM" share preflight --critical --json --bench-dir "$BENCH" >/dev/null 2>&1 &
PRE_PID="$!"
for ((i = 0; i < 100; i++)); do [[ ! -s "$MOCK_STATE/listener_pid" ]] || break; sleep 0.1; done
assert_eq "yes" "$([[ -s "$MOCK_STATE/listener_pid" ]] && echo yes || echo no)" "(the listener started)"
kill -TERM "$PRE_PID"; wait "$PRE_PID" 2>/dev/null || true
rm -f "$MOCK_STATE/nc_slow"
listener_gone

# the REAL listener script under a real node: it says ready, listens on the ports it names, and is gone
# after the stop path, which kills only the PID it recorded
REAL_NODE=""
for n in /opt/homebrew/opt/node@22/bin/node /usr/local/opt/node@22/bin/node /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node; do
  [[ -x "$n" ]] && { REAL_NODE="$n"; break; }
done
if [[ -z "$REAL_NODE" ]]; then
  printf 'test-share-preflight: SKIP the real listener test: no real node found\n'
else
  got="$(bash -c '
    set -u
    . "$1/lib/frappe-local/share-preflight.sh"
    open_port() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && echo open || echo closed; }
    fl_sp_listener_start "$2" "" || { echo "not ready"; exit 0; }
    pid="$SP_LISTENER_PID"
    printf "%s %s %s %s " "$SP_L4R" "$SP_L4C" "$(open_port "$SP_L4R")" "$(open_port "$SP_L4C")"
    fl_sp_listener_stop
    kill -0 "$pid" 2>/dev/null && echo alive || echo gone' _ "$ROOT" "$REAL_NODE")"
  [[ "$got" =~ ^([0-9]+)\ ([0-9]+)\ open\ open\ gone$ ]] || fail "real listener under $REAL_NODE: [$got]"
  (( BASH_REMATCH[1] >= 8002 && BASH_REMATCH[1] <= 8099 && BASH_REMATCH[2] >= 18000 )) || fail "real listener ports: [$got]"
fi

printf 'test-share-preflight: ok\n'
