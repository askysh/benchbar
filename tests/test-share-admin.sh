#!/usr/bin/env bash
# The host's room commands: share code, lock, unlock, people (devices), remove (revoke), assign, log,
# open-as and teardown. The gateway is a Python stand-in on the control socket that answers canned
# replies and records each request (never a reply: the code is only in replies). The control client is
# the real node; the bench's Python is a stand-in for signin.py and the sessions helper. Nothing listens
# on the network, and the stand-in gateway is stopped by its recorded PID.
# shellcheck disable=SC2016  # Python and JSON bodies are meant to stay literal
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

REAL_NODE="$(command -v node 2>/dev/null || true)"
if [[ -z "$REAL_NODE" ]]; then
  printf 'test-share-admin: ok (SKIPPED: node not found)\n'
  exit 0
fi

BENCH="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH" macdev
printf 'port 11000\n' >"$BENCH/config/redis_queue.conf"; printf 'port 13000\n' >"$BENCH/config/redis_cache.conf"
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
mkdir -p "$MOCK_STATE/keychain"; printf 'rootpw\n' >"$MOCK_STATE/keychain/benchbar-mariadb--root"
mkdir -p "$FL_STATE_DIR/secrets"; printf 'rootpw\n' >"$FL_STATE_DIR/secrets/mariadb-root"; chmod 600 "$FL_STATE_DIR/secrets/mariadb-root"
unset MARIADB_ROOT_PASSWORD ADMIN_PASSWORD
export FL_TMUTIL="$ROOT/tests/mocks/bin/tmutil" FL_NC="$ROOT/tests/mocks/bin/nc"

SHARE_DIR="$FL_STATE_DIR/share"
COPY="$BENCH/sites/share.localhost"
mkdir -p "$SHARE_DIR" "$COPY"; chmod 700 "$SHARE_DIR"
# macOS caps a socket path at 104 characters: the test HOME is long
SOCK="$TMP_DIR/c.sock"; export FL_SHARE_CONTROL_SOCK="$SOCK"
CODE1=482913; CODE2=771204
SID=MOCKSID0f3e9a7c41d2b8e6a5f0c3d9e1b7a2f4c6d8
printf '{\n "db_name": "_share",\n "developer_mode": 0,\n "server_script_enabled": 0\n}\n' >"$COPY/site_config.json"
cat >"$SHARE_DIR/share.json" <<'JSON'
{
  "v": 3,
  "site": "macdev",
  "share_site": "share.localhost",
  "allowed_users": ["priya@example.com","mgr@example.com","sam@example.com"],
  "room_label": "Lab",
  "seats": [
    {"seat_id":"s_0a1b2c3d","user":"priya@example.com","full_name":"Priya Nair","roles":["NE"]},
    {"seat_id":"s_1a2b3c4d","user":"mgr@example.com","full_name":"Mgr Singh","roles":["Sales User"]},
    {"seat_id":"s_2a2b3c4d","user":"sam@example.com","full_name":"Sam Rao","roles":["Stock User"]}
  ],
  "web_port": 8001,
  "fingerprint": "sha256:00",
  "copy_made": "2026-11-02T10:00:00Z",
  "copy_source_stamp": "20260902_090000",
  "apps_at_copy": {},
  "pii_acknowledged_at": "2026-11-02T10:00:00Z",
  "created": "2026-11-02T10:00:00Z"
}
JSON
chmod 600 "$SHARE_DIR/share.json"
printf 'host key\n' >"$SHARE_DIR/host.key"; printf 'host cert\n' >"$SHARE_DIR/host.crt"

SB="$TMP_DIR/sb"; mkdir -p "$SB"
# the bench's Python: signin.py mints (the sid on stdout) and wipes; the sessions helper of share stop;
# anything else is the env-python mock (share check, drop-site). No sid goes to the call log.
cat >"$BENCH/env/bin/python" <<SH
#!/bin/bash
case "\${1:-}" in
  */signin.py)
    shift
    if [[ "\${1:-}" == wipe ]]; then
      printf 'signin wipe %s %s\n' "\${2:-}" "\${3:-}" >>"\$MOCK_LOG"
      printf '3\n'; exit 0
    fi
    printf 'signin mint %s %s sites=%s\n' "\${1:-}" "\${2:-}" "\${BENCHBAR_SITES_DIR:-}" >>"\$MOCK_LOG"
    [[ ! -f "\$MOCK_STATE/mint_refuse" ]] || exit 1
    printf '%s\n' "$SID"; exit 0 ;;
  -c)
    if [[ "\${3:-}" == benchbar-share-sessions ]]; then
      keep="\$(cat)"
      printf 'sessions %s keep=[%s]\n' "\${4:-}" "\${keep//\$'\n'/,}" >>"\$MOCK_LOG"
      printf '\nBENCHBAR-RESULT 2\n'; exit 0
    fi ;;
esac
exec "$ROOT/tests/mocks/env-python" "\$@"
SH
chmod +x "$BENCH/env/bin/python"

# the gateway: its control socket answers the room ops with canned replies. Requests go to
# $MOCK_STATE/ctl.log, one JSON line each; replies are never written anywhere.
cat >"$SB/gw.py" <<'PY'
import json, os, socket, sys, time
state = os.environ["MOCK_STATE"]
path = sys.argv[1]
flag = lambda name: os.path.exists(os.path.join(state, name))
code = "482913"
host_locked = False
budget = 10
wipe_failed = []
people = [
    {"id": "d_0a1b2c3d", "name": "Priya\u202e Mac\u200b", "model": "MacBookPro18,1", "fp": "sha256:" + "a" * 64, "status": "active",
     "user": "priya@example.com", "seat_id": "s_0a1b2c3d", "paired_ip": "192.168.1.23", "added": "2026-11-03T09:00:00.000Z",
     "last_seen": "2026-11-03T09:05:00.000Z", "full_name": "Priya Nair", "online": True},
    {"id": "d_1a2b3c4d", "name": "Sam", "model": "Mac14,2", "fp": "sha256:" + "b" * 64, "status": "active",
     "user": None, "seat_id": None, "paired_ip": "192.168.1.24", "added": "2026-11-03T09:01:00.000Z",
     "last_seen": "2026-11-03T09:02:00.000Z", "full_name": None, "online": False},
]
def find(i):
    return next((p for p in people if p["id"] == i), None)
def answer(msg):
    global code, host_locked, budget
    op = msg.get("op")
    with open(os.path.join(state, "ctl.log"), "a") as f:
        f.write(json.dumps(msg, sort_keys=True) + "\n")
    if op == "status":
        locked = host_locked or flag("budget_lock")
        reason = "budget" if flag("budget_lock") else ("host" if host_locked else None)
        return {"ok": True, "deadline_epoch": int(time.time()) + 3600, "online": [p["id"] for p in people if p["online"]],
                "conns": 1, "web_up": not flag("web_down"), "locked": locked, "lock_reason": reason, "budget_left": budget,
                "seats": 3, "people": len(people), "join_trouble": False, "wipe_failed": list(wipe_failed)}
    if op == "code":
        return {"ok": True, "code": code}
    if op == "rotate":
        code = "771204"
        budget = 10
        return {"ok": True, "budget_left": budget}
    if op == "lock":
        host_locked = True
        return {"ok": True}
    if op == "unlock":
        host_locked = False
        b = flag("budget_lock")
        return {"ok": True, "locked": b, "lock_reason": "budget" if b else None}
    if op in ("people", "devices"):
        return {"ok": True, "people": people}
    if op == "assign":
        p = find(msg.get("device"))
        if p is None:
            return {"ok": False, "error": "not_found"}
        if msg.get("seat_id") == "s_1a2b3c4d" and flag("seat_taken"):
            return {"ok": False, "error": "seat_taken"}
        if msg.get("seat_id") not in ("s_0a1b2c3d", "s_1a2b3c4d", "s_2a2b3c4d"):
            return {"ok": False, "error": "no_such_seat"}
        p["seat_id"] = msg["seat_id"]
        return {"ok": True}
    if op in ("remove", "revoke"):
        p = find(msg.get("device"))
        if p is None:
            return {"ok": False, "error": "not_found"}
        people.remove(p)
        if p["user"]:
            wipe_failed.append(p["user"])
        return {"ok": True, "user": p["user"]}
    if op == "wipe":
        if flag("gw_wipe_fail"):
            return {"ok": True, "wiped": 0, "wipe_failed": list(wipe_failed)}
        n = len(wipe_failed)
        del wipe_failed[:]
        return {"ok": True, "wiped": n, "wipe_failed": []}
    if op == "stop":
        return {"ok": True, "stopping": True}
    return {"ok": False, "error": "unknown_op"}
if os.path.exists(path):
    os.unlink(path)
os.umask(0o077)
srv = socket.socket(socket.AF_UNIX)
srv.bind(path)
srv.listen(8)
srv.settimeout(0.2)
parent = os.getppid()
end = time.time() + 300
stop = False
while not stop and time.time() < end and os.getppid() == parent:
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
            msg = json.loads(buf.split(b"\n")[0])
            conn.sendall((json.dumps(answer(msg)) + "\n").encode())
            stop = msg.get("op") == "stop"
    except (socket.timeout, OSError, ValueError):
        pass
    conn.close()
srv.close()
if os.path.exists(path):
    os.unlink(path)
PY
# the node the share runs on: the control client is the real node, anything else the node mock
cat >"$SB/node" <<SH
#!/bin/bash
if [[ "\${1:-}" == -e && ( "\${3:-}" == control || "\${3:-}" == log ) ]]; then exec "$REAL_NODE" "\$@"; fi
exec "$ROOT/tests/mocks/node" "\$@"
SH
chmod 755 "$SB" "$SB"/*
mkdir -p "$TMP_DIR/nodebin"; chmod 755 "$TMP_DIR/nodebin"; ln -s "$SB/node" "$TMP_DIR/nodebin/node"
export FL_SHARE_NODE="$TMP_DIR/nodebin/node"

GW_PID=""
gw_start() {
  rm -f "$SOCK"
  python3 "$SB/gw.py" "$SOCK" &
  GW_PID=$!
  local i=0
  while [[ ! -S "$SOCK" ]]; do
    i=$((i + 1)); [[ "$i" -lt 100 ]] || fail "the stand-in gateway did not listen"
    sleep 0.1
  done
}
gw_stop() {
  [[ -n "$GW_PID" ]] || return 0
  kill "$GW_PID" 2>/dev/null || true
  wait "$GW_PID" 2>/dev/null || true
  GW_PID=""; rm -f "$SOCK"
}
ctl_log() { cat "$MOCK_STATE/ctl.log" 2>/dev/null || true; }
ctl_reset() { : >"$MOCK_STATE/ctl.log"; }
ctl_ops() { ctl_log | python3 -c 'import json,sys; print(" ".join(json.loads(l)["op"] for l in sys.stdin if l.strip()))'; }

cli() { # ARGS...: stdout in OUT, stderr in ERR, the exit code in CODE; like the app (no terminal, BENCHBAR_SUDO=gui)
  set +e
  OUT="$(BENCHBAR_SUDO=gui "$FM" share "$@" --bench-dir "$BENCH" </dev/null 2>"$TMP_DIR/cli.err")"
  CODE="$?"
  set -e
  ERR="$(cat "$TMP_DIR/cli.err")"
}
cli_env() { # ENV=VAL ARGS...: cli with one more variable in the environment
  local kv="$1"; shift
  set +e
  OUT="$(env "$kv" BENCHBAR_SUDO=gui "$FM" share "$@" --bench-dir "$BENCH" </dev/null 2>"$TMP_DIR/cli.err")"
  CODE="$?"
  set -e
  ERR="$(cat "$TMP_DIR/cli.err")"
}
cli_notty() { # ARGS...: no terminal and no BENCHBAR_SUDO=gui
  set +e
  OUT="$(env -u BENCHBAR_SUDO "$FM" share "$@" --bench-dir "$BENCH" </dev/null 2>"$TMP_DIR/cli.err")"
  CODE="$?"
  set -e
  ERR="$(cat "$TMP_DIR/cli.err")"
}
doc() { printf '%s' "$OUT" >"$TMP_DIR/doc.json"; jget "$TMP_DIR/doc.json" "$1"; }

# ================================================================ sharing off
cli code
assert_eq "1" "$CODE" "$OUT$ERR"
assert_contains "$OUT$ERR" "Sharing is not on"
cli lock
assert_eq "1" "$CODE" "$OUT$ERR"
cli people --json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "off []" "$(doc '" ".join([d["state"], json.dumps(d["people"])])')"
cli open-as priya@example.com
assert_eq "1" "$CODE" "$OUT$ERR"
assert_contains "$OUT$ERR" "start sharing first"
assert_calls_not_contain '^signin mint'
# a failed wipe left while sharing was off (the marker): a room command with the bench's Redis up retries it
printf '' >"$SHARE_DIR/wipe_failed"
printf '13000\n' >"$MOCK_STATE/loopback_ports"
reset_calls
cli people --json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_calls_contain '^sessions share.localhost keep=\[\]' "(the whole copy: nobody is in a room that is off)"
assert_no_file "$SHARE_DIR/wipe_failed"
assert_eq "True 2 0" "$(doc '" ".join(str(x) for x in (d["wipe"]["retried"], d["wipe"]["wiped"], d["wipe"]["wipe_failed"]))')"
# with Redis down nothing is started for it: the marker stays and the person is told
printf '' >"$SHARE_DIR/wipe_failed"; : >"$MOCK_STATE/loopback_ports"
reset_calls
cli people
assert_eq "0" "$CODE" "$OUT$ERR"
assert_calls_not_contain '^sessions '
assert_file "$SHARE_DIR/wipe_failed"
assert_contains "$OUT$ERR" "next share start ends them"
rm -f "$SHARE_DIR/wipe_failed"

# ================================================================ the room code
gw_start
ctl_reset
cli code
assert_eq "0" "$CODE" "$OUT$ERR"
assert_contains "$OUT" "Room code  482 913"
assert_contains "$OUT" "Anyone on this Wi-Fi with the code can join. Remove people anytime."
assert_eq "status code" "$(ctl_ops)"
cli code --json
assert_eq "0" "$CODE" "$OUT$ERR"
[[ -n "$OUT" && "$OUT" != *$'\n'* ]] || fail "code --json is one line of JSON: $OUT"
assert_eq "482913 False 10" "$(doc '" ".join(str(x) for x in (d["code"], d["new"], d["budget_left"]))')"
ctl_reset
cli code --new --json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "771204 True" "$(doc '" ".join(str(x) for x in (d["code"], d["new"]))')"
assert_eq "status rotate code" "$(ctl_ops)"
# an agent never reads the code: --for-agent and BENCHBAR_NONINTERACTIVE are refused before the socket
ctl_reset
cli code --for-agent
assert_eq "1" "$CODE" "$OUT$ERR"
assert_not_contains "$OUT$ERR" "$CODE2"
cli_env BENCHBAR_NONINTERACTIVE=1 code --json
assert_eq "1" "$CODE" "$OUT$ERR"
assert_not_contains "$OUT$ERR" "$CODE2"
assert_eq "" "$(ctl_ops)"
cli code --bogus
assert_eq "1" "$CODE" "$OUT$ERR"

# ================================================================ lock and unlock
ctl_reset
cli lock --json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_contains "$OUT$ERR" "Room locked: nobody new can join."
assert_eq "True host" "$(printf '%s\n' "$OUT" | tail -n1 | jget - '" ".join(str(x) for x in (d["locked"], d["lock_reason"]))')"
cli lock
assert_eq "0" "$CODE" "$OUT$ERR"
assert_contains "$OUT$ERR" "unchanged: the room is already locked"
cli unlock
assert_eq "0" "$CODE" "$OUT$ERR"
assert_contains "$OUT$ERR" "Room unlocked: people with the code can join."
assert_eq "status lock status status unlock" "$(ctl_ops)"
# a budget lock stays until a new code: unlock says so, and still lifts a host lock the status hides under it
cli lock
ctl_reset
touch "$MOCK_STATE/budget_lock"
cli unlock --json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "status unlock" "$(ctl_ops)"
assert_contains "$OUT$ERR" "Someone typed a wrong room code 10 times. The room is locked."
assert_eq "True budget" "$(printf '%s\n' "$OUT" | tail -n1 | jget - '" ".join(str(x) for x in (d["locked"], d["lock_reason"]))')"
rm -f "$MOCK_STATE/budget_lock"
cli unlock
assert_eq "0" "$CODE" "$OUT$ERR"
assert_contains "$OUT$ERR" "unchanged: the room is not locked"

# ================================================================ people
cli people --json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "on 2" "$(doc '" ".join(str(x) for x in (d["state"], len(d["people"])))')"
assert_eq "ip,joined,last_seen,model,name,online,seat_full_name,seat_id" "$(doc '",".join(sorted(k for k in d["people"][0] if k != "id"))')"
assert_eq "d_0a1b2c3d|Priya Mac|192.168.1.23|s_0a1b2c3d|Priya Nair|True|2026-11-03T09:00:00.000Z" \
  "$(doc '"|".join(str(x) for x in (d["people"][0]["id"], d["people"][0]["name"], d["people"][0]["ip"], d["people"][0]["seat_id"], d["people"][0]["seat_full_name"], d["people"][0]["online"], d["people"][0]["joined"]))')"
assert_eq "None None False" "$(doc '" ".join(str(x) for x in (d["people"][1]["seat_id"], d["people"][1]["seat_full_name"], d["people"][1]["online"]))')"
assert_not_contains "$OUT" "priya@example.com" "(people never carries the seat's user)"
assert_not_contains "$OUT" "sha256:"
cli devices --json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "2" "$(doc 'len(d["people"])')"
cli people
assert_eq "0" "$CODE" "$OUT$ERR"
assert_contains "$OUT" "People in the room"
assert_contains "$OUT" "d_1a2b3c4d"
assert_contains "$OUT" "Priya Nair"
assert_not_contains "$OUT" "$(printf '\342\200\256')"

# ================================================================ assign
ctl_reset
cli assign x s_0a1b2c3d
assert_eq "1" "$CODE" "$OUT$ERR"
cli assign d_1a2b3c4d 's_1"}'
assert_eq "1" "$CODE" "$OUT$ERR"
cli assign d_1a2b3c4d
assert_eq "1" "$CODE" "$OUT$ERR"
assert_eq "" "$(ctl_ops)" "(a malformed id never reaches the socket)"
cli assign d_1a2b3c4d s_2a2b3c4d --json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_contains "$OUT$ERR" "Sam is now in the seat of Sam Rao"
assert_contains "$(ctl_log)" '{"device": "d_1a2b3c4d", "op": "assign", "seat_id": "s_2a2b3c4d"}'
touch "$MOCK_STATE/seat_taken"
cli assign d_1a2b3c4d s_1a2b3c4d
assert_eq "1" "$CODE" "$OUT$ERR"
assert_contains "$OUT$ERR" "That seat is taken"
rm -f "$MOCK_STATE/seat_taken"
cli assign d_1a2b3c4d s_9a9b9c9d
assert_eq "1" "$CODE" "$OUT$ERR"
assert_contains "$OUT$ERR" "No seat s_9a9b9c9d"
cli assign d_99999999 s_1a2b3c4d
assert_eq "1" "$CODE" "$OUT$ERR"
assert_contains "$OUT$ERR" "Nobody in the room has the id d_99999999"

# ================================================================ remove
ctl_reset
cli remove nope --yes
assert_eq "1" "$CODE" "$OUT$ERR"
cli remove d_99999999 --yes
assert_eq "1" "$CODE" "$OUT$ERR"
assert_contains "$OUT$ERR" "Nobody in the room has the id d_99999999"
# no terminal and no --yes: the question is a no, and nothing is removed
cli remove d_0a1b2c3d
assert_eq "1" "$CODE" "$OUT$ERR"
assert_not_contains "$(ctl_ops)" "remove"
ctl_reset
cli remove d_0a1b2c3d --yes --json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "status people remove wipe" "$(ctl_ops)"
assert_contains "$OUT$ERR" "Removed Priya Mac from the room"
printf '%s\n' "$OUT" | tail -n1 >"$TMP_DIR/done.json"
assert_eq "d_0a1b2c3d True False 1 0" "$(jget "$TMP_DIR/done.json" '" ".join(str(x) for x in (d["device"], d["removed"], d["new_code"], d["wipe"]["wiped"], d["wipe"]["wipe_failed"]))')"
# the gateway could not end the sessions: a warning, and the next room command tries again
gw_stop; gw_start
touch "$MOCK_STATE/gw_wipe_fail"
ctl_reset
cli revoke d_0a1b2c3d --yes --new-code --json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "status people remove wipe rotate" "$(ctl_ops)"
assert_contains "$OUT$ERR" "could not be ended yet"
assert_contains "$OUT$ERR" "The room has a new code: benchbar share code shows it."
assert_not_contains "$OUT$ERR" "$CODE2"
printf '%s\n' "$OUT" | tail -n1 >"$TMP_DIR/done.json"
assert_eq "True 0 1" "$(jget "$TMP_DIR/done.json" '" ".join(str(x) for x in (d["new_code"], d["wipe"]["wiped"], d["wipe"]["wipe_failed"]))')"
rm -f "$MOCK_STATE/gw_wipe_fail"
ctl_reset
cli people --json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "status wipe people" "$(ctl_ops)" "(status.wipe_failed > 0: the wipe is retried)"
assert_eq "True 1 0" "$(doc '" ".join(str(x) for x in (d["wipe"]["retried"], d["wipe"]["wiped"], d["wipe"]["wipe_failed"]))')"
ctl_reset
cli people --json
assert_eq "status people" "$(ctl_ops)" "(nothing owed: no retry)"
assert_eq "None" "$(doc 'd["wipe"]')"

# ================================================================ open-as
gw_stop; gw_start
reset_calls
cli open-as nobody@example.com
assert_eq "1" "$CODE" "$OUT$ERR"
assert_contains "$OUT$ERR" "not a seat"
printf 'seat\tmgr@example.com\trole\tSystem Manager\ndone\n' >"$MOCK_STATE/share_check"
cli open-as mgr@example.com
assert_eq "1" "$CODE" "$OUT$ERR"
assert_contains "$OUT$ERR" "can run code"
rm -f "$MOCK_STATE/share_check"
touch "$MOCK_STATE/web_down"
cli open-as priya@example.com
assert_eq "1" "$CODE" "$OUT$ERR"
assert_contains "$OUT$ERR" "start sharing first"
rm -f "$MOCK_STATE/web_down"
assert_calls_not_contain '^signin mint'
touch "$MOCK_STATE/mint_refuse"
cli open-as priya@example.com
assert_eq "1" "$CODE" "$OUT$ERR"
rm -f "$MOCK_STATE/mint_refuse"
reset_calls
# the guards of upstream's Open as: no agent, no run without a person
cli_env BENCHBAR_NONINTERACTIVE=1 open-as priya@example.com
assert_eq "1" "$CODE" "$OUT$ERR"
cli open-as priya@example.com --for-agent
assert_eq "1" "$CODE" "$OUT$ERR"
cli_notty open-as priya@example.com
assert_eq "1" "$CODE" "$OUT$ERR"
assert_contains "$OUT$ERR" "needs a person at a terminal"
assert_calls_not_contain '^signin mint'
reset_calls
cli open-as priya@example.com
assert_eq "0" "$CODE" "$OUT$ERR"
assert_calls_contain "^signin mint share.localhost priya@example.com sites=${BENCH}/sites\$"
assert_calls_contain "^open http://share\\.localhost:8001/login\\?redirect-to=%2Fapp&sid=${SID}&t=[0-9]+\$" "(the sid reaches the browser the way open --as hands it over)"
assert_not_contains "$OUT$ERR" "$SID"
assert_contains "$OUT$ERR" "opened as priya@example.com"
# --print-url prints what upstream's open --as --print-url prints; nothing is opened
reset_calls
cli open-as priya@example.com --print-url
assert_eq "0" "$CODE" "$OUT$ERR"
[[ "$OUT" =~ ^http://share\.localhost:8001/login\?redirect-to=%2Fapp\&sid=${SID}\&t=[0-9]+$ ]] || fail "print-url: $OUT"
assert_calls_not_contain '^open '
# --json never carries the sid, --print-url or not
for extra in "" --print-url; do
  # shellcheck disable=SC2086  # an empty extra is no argument
  cli open-as priya@example.com --json $extra
  assert_eq "0" "$CODE" "$OUT$ERR"
  assert_not_contains "$OUT$ERR" "$SID"
  assert_eq "priya@example.com http://share.localhost:8001/app False" "$(doc '" ".join(str(x) for x in (d["user"], d["page"], "url" in d))')"
done

# ================================================================ log
DAY0="$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"))')"
ts() { python3 -c 'import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%S.000Z"))' "$1"; }
OLD_DAY="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=20)).strftime("%Y-%m-%d"))')"
T1="$(ts 30)"; T2="$(ts 20)"; T3="$(ts 10)"; TOLD="$(ts $((20 * 1440)))"
{
  printf '{"ts":"%s","device":"d_0a1b2c3d","user":"priya@example.com","method":"GET","path":"/app/sales-order","status":200}\n' "$T1"
  # a line written by something else: a query, a document name and a cookie field must not come out
  printf '{"ts":"%s","device":"d_1a2b3c4d","user":"sam@example.com","method":"POST","path":"/app/customer/CUST-0042?sid=leak","status":200,"cookie":"sid=leakcookie"}\n' "$T2"
  printf '{"ts":"%s","device":"d_0a1b2c3d","user":"priya@example.com","method":"GET","path":"/api/method","status":403}\n' "$T3"
  printf 'not json\n'
  printf '{"ts":"%s","device":"d_0a1b2c3d","user":"priya@example.com","method":"GET","path":"/app/old","status":200}\n' "$TOLD"
} >"$SHARE_DIR/activity-${DAY0}.log"
printf '{"ts":"%sT10:00:00.000Z","device":"d_0a1b2c3d","user":"priya@example.com","method":"GET","path":"/app/ancient","status":200}\n' "$OLD_DAY" >"$SHARE_DIR/activity-${OLD_DAY}.log"
chmod 600 "$SHARE_DIR"/activity-*.log
cli log --json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "3 False" "$(doc '" ".join(str(x) for x in (len(d["entries"]), d["truncated"]))')"
assert_eq "/app/sales-order /app/customer /api/method" "$(doc '" ".join(e["path"] for e in d["entries"])')"
assert_eq "device,method,path,status,ts,user" "$(doc '",".join(sorted(d["entries"][1]))')"
assert_not_contains "$OUT" "leak"
assert_not_contains "$OUT" "CUST-0042"
assert_not_contains "$OUT" "ancient"
assert_not_contains "$OUT" "/app/old"
cli log --device d_1a2b3c4d --json
assert_eq "d_1a2b3c4d" "$(doc '" ".join(e["device"] for e in d["entries"])')"
cli log --since "$T2" --json
assert_eq "2" "$(doc 'len(d["entries"])')"
cli log --limit 1 --json
assert_eq "1 True /api/method" "$(doc '" ".join(str(x) for x in (len(d["entries"]), d["truncated"], d["entries"][0]["path"]))')"
for bad in 0 abc 5001; do
  cli log --limit "$bad"
  assert_eq "1" "$CODE" "$OUT$ERR"
  assert_contains "$OUT$ERR" "--limit needs a number from 1 to 5000"
done
cli log --since yesterdayish
assert_eq "1" "$CODE" "$OUT$ERR"
cli log --device x
assert_eq "1" "$CODE" "$OUT$ERR"
cli log
assert_eq "0" "$CODE" "$OUT$ERR"
assert_contains "$OUT" "/app/customer"
assert_contains "$OUT" "d_1a2b3c4d"
assert_not_contains "$OUT" "leak"

# ================================================================ secret hygiene (Review Focus 3, J14)
# after the whole flow: the code nowhere but the terminal and code --json; the sid only on the opener's line
hits="$(grep -r -l -e "$CODE1" -e "$CODE2" -e "$SID" "$FL_STATE_DIR" "$MOCK_STATE/ctl.log" 2>/dev/null || true)"
assert_eq "" "$hits" "(no state file or log holds the code or the sid)"
assert_eq "" "$(grep -e "$CODE1" -e "$CODE2" "$MOCK_LOG" || true)" "(the code is in no argv)"
assert_eq "" "$(grep -e "$SID" "$MOCK_LOG" | grep -v '^open http://share\.localhost:8001/login?' || true)" "(the sid is in no argv but the opener's)"

# ================================================================ teardown
cli_env BENCHBAR_NONINTERACTIVE=1 teardown --yes
assert_eq "1" "$CODE" "$OUT$ERR"
cli teardown --yes --for-agent
assert_eq "1" "$CODE" "$OUT$ERR"
cli_notty teardown --yes
assert_eq "1" "$CODE" "$OUT$ERR"
assert_contains "$OUT$ERR" "needs a person at a terminal"
# no --yes and no terminal: the question is a no
cli teardown
assert_eq "1" "$CODE" "$OUT$ERR"
assert_file "$SHARE_DIR/share.json"; assert_file "$COPY/site_config.json"
# a drop that fails keeps the share folder, and with it every Time Machine exclusion
reset_calls
set +e; OUT="$(MOCK_DROP_SITE_EXIT=1 BENCHBAR_SUDO=gui "$FM" share teardown --yes --bench-dir "$BENCH" </dev/null 2>&1)"; CODE=$?; set -e
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "the share folder is kept"
assert_file "$SHARE_DIR/share.json"; assert_file "$COPY/site_config.json"
assert_calls_not_contain '^tmutil removeexclusion'
gw_start
reset_calls; ctl_reset
cli teardown --yes --json
assert_eq "0" "$CODE" "$OUT$ERR"
assert_contains "$(ctl_ops)" "stop"
wait "$GW_PID" 2>/dev/null || true; GW_PID=""
assert_calls_contain "^tmutil removeexclusion ${SHARE_DIR}\$"
assert_calls_not_contain "^tmutil removeexclusion ${COPY}" "(the copy's sticky exclusion goes with it to archived/sites)"
assert_calls_contain '^bench drop-site share\.localhost'
assert_no_file "$SHARE_DIR"
assert_no_file "$COPY"
assert_file "$BENCH/archived/sites/share.localhost"
assert_file "$BENCH/sites/macdev/site_config.json"
printf '%s\n' "$OUT" | tail -n1 >"$TMP_DIR/done.json"
assert_eq "True True" "$(jget "$TMP_DIR/done.json" '" ".join(str(x) for x in (d["copy_dropped"], d["state_removed"]))')"
reset_calls
cli teardown --yes
assert_eq "0" "$CODE" "$OUT$ERR"
assert_contains "$OUT$ERR" "unchanged"
assert_calls_not_contain '^(bench drop-site|tmutil)'

printf 'test-share-admin: ok\n'
