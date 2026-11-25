#!/usr/bin/env bash
# benchbar share join, joined, leave and forget: the guest side of a room from the CLI (#174, parity row P31).
# The rooms are real gateways (lib/frappe-local/share/gateway.js through tests/share/helpers.js) that this
# test starts on loopback and stops by their PIDs: nothing leaves this machine, and the guest folder, the
# Keychain (the security mock) and the browser opener (a mock) are the test's own.
# Covers: the refusals (an agent, no terminal, the Lab off, the code or an invite as an argument, an address
# that is not of a local network), the look before the code, a join as the tray sends it (the code on
# stdin) and with an invite link, the seat, the room through the local address, the JSON, joined, leave,
# forget, both key stores, the WSL NAT hint, and the rule that the room code and this computer's key are in
# no argument of a child process, no call of a tool, no file of the state folder, no report and no output.
# shellcheck disable=SC2016  # the node and Python bodies are meant to stay literal
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

REAL_NODE="$(command -v node 2>/dev/null || true)"
if [[ -z "$REAL_NODE" ]]; then printf 'test-share-join: ok (SKIPPED: node not found)\n'; exit 0; fi
NODE_MAJOR="$("$REAL_NODE" -p 'process.versions.node.split(".")[0]')"
if [[ "$NODE_MAJOR" -lt 22 ]]; then printf 'test-share-join: ok (SKIPPED: node %s is older than 22)\n' "$NODE_MAJOR"; exit 0; fi

export BENCHBAR_LABS=lan-rooms FL_SHARE_GUEST_LOOPBACK=1
GUEST="$FL_STATE_DIR/share-guest"
SEEN="$TMP_DIR/seen"; : >"$SEEN"     # every byte the CLI printed, for the secrets rule

# the node the CLI runs: a file the path check accepts, which records every argument list it is given
mkdir -p "$TMP_DIR/nodebin"; chmod 755 "$TMP_DIR/nodebin"
cat >"$TMP_DIR/nodebin/node" <<SH
#!/bin/bash
printf '%s\n' "\$*" >>"$MOCK_STATE/node.argv"
exec "$REAL_NODE" "\$@"
SH
chmod 755 "$TMP_DIR/nodebin/node"
export FL_SHARE_NODE="$TMP_DIR/nodebin/node"

cat >"$TMP_DIR/room.js" <<'JS'
const H = require(process.argv[2] + "/tests/share/helpers.js");
H.startGateway({ config: process.argv[3] === "host" ? { seat_mode: "host" } : {} }).then((gw) => {
    process.stdout.write(JSON.stringify({ port: gw.port, sock: gw.cfg.control_sock, fp: gw.host.fp, state: gw.stateDir, log: gw.logDir, clock: gw.clockFile }) + "\n");
    process.on("SIGTERM", () => gw.stop().then(() => process.exit(0)));
});
JS
cat >"$TMP_DIR/ctl.js" <<'JS'
const c = require("net").connect(process.argv[2]);
let buf = "";
c.on("data", (d) => { buf += d; if (buf.includes("\n")) { process.stdout.write(buf); c.destroy(); } });
c.write(process.argv[3] + "\n");
JS
cat >"$TMP_DIR/browse.py" <<'PY'
import http.client, sys
port, host, path = int(sys.argv[1]), sys.argv[2], sys.argv[3]
conn = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
conn.request("GET", path, headers={"Host": host, "Accept": "text/html"})
reply = conn.getresponse()
print(reply.status, reply.read().decode())
PY

ROOM_PIDS=()
room_start() { # [host]: a room; ROOM_PORT, ROOM_SOCK, ROOM_KEY (64 hex), ROOM_ID (16), ROOM_STATE, ROOM_LOG, ROOM_CLOCK
  local i=0 line=""
  : >"$TMP_DIR/room.out"
  "$REAL_NODE" "$TMP_DIR/room.js" "$ROOT" "${1:-}" >"$TMP_DIR/room.out" 2>&1 &
  ROOM_PIDS+=("$!")
  while :; do
    line="$(grep '^{' "$TMP_DIR/room.out" || true)"
    [[ -z "$line" ]] || break
    i=$((i + 1)); [[ "$i" -lt 150 ]] || fail "the room did not start: $(cat "$TMP_DIR/room.out")"
    sleep 0.1
  done
  ROOM_PORT="$(printf '%s' "$line" | jget - 'd["port"]')"; ROOM_SOCK="$(printf '%s' "$line" | jget - 'd["sock"]')"
  ROOM_KEY="$(printf '%s' "$line" | jget - 'd["fp"][7:]')"; ROOM_ID="${ROOM_KEY:0:16}"
  ROOM_STATE="$(printf '%s' "$line" | jget - 'd["state"]')"; ROOM_LOG="$(printf '%s' "$line" | jget - 'd["log"]')"
  ROOM_CLOCK="$(printf '%s' "$line" | jget - 'd["clock"]')"
}
room_stop() {
  local pid
  for pid in ${ROOM_PIDS[@]+"${ROOM_PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
  ROOM_PIDS=()
}
ctl() { "$REAL_NODE" "$TMP_DIR/ctl.js" "$ROOM_SOCK" "$1"; }
# GNU stat reads -f as "file system" and prints text before it fails, so the two forms are never chained
perm_of() { if [[ "$STAT_GNU" == "1" ]]; then stat -c %a "$1"; else stat -f %Lp "$1"; fi; }
people() { ctl '{"op":"people"}' | jget - "$1"; }
finish() {
  # a failed assertion must leave no forwarder and no room behind (a forwarder also ends by itself
  # within seconds of its folder being deleted)
  BENCHBAR_LABS=lan-rooms BENCHBAR_SUDO=gui "$FM" share forget </dev/null >/dev/null 2>&1 || true
  room_stop
  rm -rf "$TMP_DIR"
}
trap finish EXIT

guest() { # STDIN ARGS...: like the tray: no terminal, BENCHBAR_SUDO=gui, the code or the invite as the first line of stdin
  local input="$1"
  shift
  set +e
  OUT="$(printf '%s\n' "$input" | BENCHBAR_SUDO=gui "$FM" share "$@" 2>"$TMP_DIR/cli.err")"
  CODE="$?"
  set -e
  ERR="$(cat "$TMP_DIR/cli.err")"
  ALL="${OUT}"$'\n'"${ERR}"   # a refusal is on stdout, and on stderr under --json
  printf '%s\n' "$ALL" >>"$SEEN"
}
last() { printf '%s\n' "$OUT" | python3 -c 'import json,sys; d=json.loads([l for l in sys.stdin.read().splitlines() if l.strip()][-1]); print(eval(sys.argv[1]))' "$1"; }

# ---------------------------------------------------------------- refusals, before any room exists
BENCHBAR_LABS="" run_fm share join 192.168.1.20
assert_eq 2 "$CODE" "$OUT"; assert_contains "$OUT" "benchbar labs on lan-rooms"
for sub in "join 192.168.1.20" leave forget; do
  # shellcheck disable=SC2086  # the words of a subcommand
  BENCHBAR_NONINTERACTIVE=1 run_fm share $sub
  assert_eq 1 "$CODE" "(${sub}, an agent) $OUT"; assert_contains "$OUT" "a person at a terminal"
  # shellcheck disable=SC2086
  run_fm share $sub --for-agent
  assert_eq 1 "$CODE" "(${sub}, --for-agent) $OUT"; assert_contains "$OUT" "a person at a terminal"
  # shellcheck disable=SC2086
  run_fm share $sub </dev/null
  assert_eq 1 "$CODE" "(${sub}, no terminal) $OUT"; assert_contains "$OUT" "needs a person at a terminal"
done
assert_no_file "$GUEST"

# the Lab is off: leaving and forgetting still run (an experiment that is off stays undoable), joining does not
for sub in leave forget; do
  BENCHBAR_LABS="" guest "" "$sub"
  assert_eq 1 "$CODE" "(${sub}, Lab off) $ALL"; assert_contains "$ALL" "joined no room"; assert_not_contains "$ALL" "labs on lan-rooms"
done

# macOS: BENCHBAR_SUDO=gui counts only when BenchBar.app is above the command (fl_person_env_ok)
for sub in "join 192.168.1.20" leave forget; do
  # shellcheck disable=SC2086  # the words of a subcommand
  BENCHBAR_APP_PID=4300 guest "" $sub
  assert_eq 1 "$CODE" "(${sub}, no app above) $ALL"; assert_contains "$ALL" "needs a person at a terminal"; assert_contains "$ALL" "is not above this command"
  # shellcheck disable=SC2086
  BENCHBAR_APP_PID="" guest "" $sub
  assert_eq 1 "$CODE" "(${sub}, no app pid) $ALL"; assert_contains "$ALL" "BENCHBAR_APP_PID is not set"
done

# the code and an invite link are never arguments: refused, and not echoed, logged or kept in the history
for word in 482913 "482 913" 482-913 "48 29-13" "benchbar://share/join?v=1&r=Lab&h=$(printf 'ab%.0s' {1..32})&s=$(printf 'cd%.0s' {1..16})&c=482913&a=192.168.1.20%3A8443&x=1900000000"; do
  guest "" join "$word"
  assert_eq 1 "$CODE" "$ALL"; assert_contains "$ALL" "never passed as an argument"
done
assert_not_contains "$(cat "$SEEN")" "482913"
if grep -r -q -E '482 ?913' "$FL_STATE_DIR" 2>/dev/null; then fail "a room code passed as an argument was kept in the state folder"; fi
# and should such a command line ever reach the history, its words are masked there too
KEPT="$(bash -c '. "$1/lib/frappe-local/ui.sh"; . "$1/lib/frappe-local/history.sh"
  FL_ORIG_ARGS=(share join "482 913" 482913 "benchbar://share/join?v=1&c=482913" --name x 192.168.1.20); fl_hist_words; printf "%s|" "${FL_HIST_WORDS[@]}"
  FL_ORIG_ARGS=(site backup 482913); fl_hist_words; printf "%s|" "${FL_HIST_WORDS[@]}"
  FL_ORIG_ARGS=(share join 482-913 "482 913" "48-29-13" 4829133 --seat seat-1); fl_hist_words; printf "%s|" "${FL_HIST_WORDS[@]}"' _ "$ROOT")"
assert_eq "share|join|***|***|***|--name|x|192.168.1.20|site|backup|482913|share|join|***|***|***|4829133|--seat|seat-1|" "$KEPT"
# at a terminal the code and the link are read without an echo
assert_contains "$(cat "$ROOT/lib/frappe-local/share-guest.sh")" 'IFS= read -r -s -p'
assert_eq "2" "$(grep -c 'secret$' "$ROOT/lib/frappe-local/share-guest.sh")" "(the code and the invite link are the secrets read)"
: >"$SEEN"

guest "" join 8.8.8.8
assert_eq 1 "$CODE" "$ALL"; assert_contains "$ALL" "not an address of a local network"
guest "" join room.example
assert_eq 1 "$CODE" "$ALL"; assert_contains "$ALL" "IPv4 address"
guest "" join 192.168.1.20 --nope
assert_eq 64 "$CODE" "$ALL"; assert_contains "$ALL" "Unknown option for share join: --nope"
guest "" join 192.168.1.20 --seat 'a b'
assert_eq 1 "$CODE" "$ALL"; assert_contains "$ALL" "not a seat id"
guest "" leave nothex
assert_eq 1 "$CODE" "$ALL"; assert_contains "$ALL" "16 digits of its host key"
guest "" leave
assert_eq 1 "$CODE" "$ALL"; assert_contains "$ALL" "joined no room"
guest "not an invite" join
assert_eq 1 "$CODE" "$ALL"; assert_contains "$ALL" "holds no invite"
guest "" join
assert_eq 1 "$CODE" "$ALL"; assert_contains "$ALL" "No invite was given"

# joined only reads: an agent may run it, and a computer that joined nothing starts no node for it
: >"$MOCK_STATE/node.argv"
run_fm share joined
assert_eq 0 "$CODE" "$OUT"; assert_contains "$OUT" "joined no room"
run_fm share joined --for-agent
assert_eq 0 "$CODE" "$OUT"
assert_eq "([], 0)" "$(printf '%s' "$OUT" | jget - '(d["rooms"], d["exit"])')"
assert_eq "" "$(cat "$MOCK_STATE/node.argv")" "(joined started node with no room saved)"

# ---------------------------------------------------------------- a room where guests pick their seat (macOS: the Keychain)
room_start
ROOM_CODE="$(ctl '{"op":"code"}' | jget - 'd["code"]')"
WRONG=000000; [[ "$ROOM_CODE" != 000000 ]] || WRONG=111111
ITEM="$MOCK_STATE/keychain/benchbar-share-guest--${ROOM_KEY}"

# the look: the room, its address and the host key, and nothing else happens; with BenchBar.app installed
# the output says that the app is a second guest
guest "" join "127.0.0.1:${ROOM_PORT}" --dry-run --json
assert_eq 0 "$CODE" "$ALL"; assert_not_contains "$ALL" "two guests"
mkdir -p "$HOME/Applications/BenchBar.app"
guest "" join "127.0.0.1:${ROOM_PORT}" --dry-run --json
rmdir "$HOME/Applications/BenchBar.app"
assert_eq 0 "$CODE" "$ALL"; assert_contains "$ALL" "two guests to Test Host"
assert_eq "('${ROOM_ID}', 'Test Room', 'Test Host', '127.0.0.1', ${ROOM_PORT}, False, False)" "$(printf '%s' "$OUT" | jget - '(d["host_key"], d["room"], d["host"], d["address"], d["port"], d["paired"], d["known"])')"
assert_contains "$ALL" "Host key  ${ROOM_ID:0:4} ${ROOM_ID:4:4} ${ROOM_ID:8:4} ${ROOM_ID:12:4}"
assert_eq "[]" "$(people '[p["name"] for p in d["people"]]')"
assert_no_file "$GUEST/rooms.json"; assert_no_file "$ITEM"

# --host-key: the key a look showed is the key that is joined; another key, or a malformed one, ends the run
# before the room is asked anything (exit 3 for another key)
HOST_KEY_UP="$(printf '%s' "$ROOM_KEY" | tr 'a-f' 'A-F')"
guest "" join "127.0.0.1:${ROOM_PORT}" --host-key "$HOST_KEY_UP" --dry-run --json
assert_eq 0 "$CODE" "$ALL"; assert_eq "$ROOM_KEY" "$(printf '%s' "$OUT" | jget - 'd["host_pin"]')"
OTHER_KEY="$(printf 'ab%.0s' {1..32})"
guest "$ROOM_CODE" join "127.0.0.1:${ROOM_PORT}" --host-key "$OTHER_KEY" --json
assert_eq 3 "$CODE" "$ALL"; assert_contains "$ERR" "shows another host key than the one you asked for"; assert_eq "" "$OUT"
assert_no_file "$GUEST/rooms.json"; assert_no_file "$ITEM"
assert_eq "[]" "$(people '[p["name"] for p in d["people"]]')"
for bad in abc "${ROOM_KEY:0:63}" "${ROOM_KEY:0:63}g" "" "${ROOM_KEY}00"; do
  guest "$ROOM_CODE" join "127.0.0.1:${ROOM_PORT}" --host-key "$bad"
  assert_eq 1 "$CODE" "(host key ${bad}) $ALL"; assert_contains "$ALL" "takes the 64 hex digits"
done
guest "" join "127.0.0.1:${ROOM_PORT}" --host-key
assert_eq 1 "$CODE" "$ALL"; assert_contains "$ALL" "--host-key needs"

# a wrong code: one sentence on stderr, no document, and the key made for the try is gone again
guest "$WRONG" join "127.0.0.1:${ROOM_PORT}" --name "Lab PC" --json
assert_eq 1 "$CODE" "$ALL"; assert_contains "$ERR" "That code didn't work."
assert_eq "" "$OUT" "(a refused join printed a document)"
assert_no_file "$ITEM"; assert_no_file "$GUEST/rooms.json"
guest "12345" join "127.0.0.1:${ROOM_PORT}"
assert_eq 1 "$CODE" "$ALL"; assert_contains "$ALL" "The room code is 6 digits."
printf 120000 >"$ROOM_CLOCK"   # past the gateway's pause after a wrong code

# the join as the tray makes it: the code on stdin, a seat, no browser
: >"$MOCK_LOG"
guest "${ROOM_CODE:0:3} ${ROOM_CODE:3:3}" join "127.0.0.1:${ROOM_PORT}" --host-key "$ROOM_KEY" --name "Lab PC" --seat seat2 --no-open --json
assert_eq 0 "$CODE" "$ALL"
assert_eq "(True, '${ROOM_ID}', 'Test Room', 'ready', 'seat2@example.com', True, 0)" "$(last '(d["joined"], d["id"], d["room"], d["state"], d["seat"], d["forwarding"], d["exit"])')"
assert_eq "[{'kind': 'share', 'name': 'Test Room', 'detail': 'joined'}]" "$(last 'd["changed"]')"
URL="$(last 'd["url"]')"; LOCAL_PORT="$(last 'd["local_port"]')"
LOCAL_NAME="${URL#http://}"; LOCAL_NAME="${LOCAL_NAME%%/*}"
[[ "$URL" =~ ^http://test-room-[0-9a-f]{16}\.localhost:41[0-9]{3}/_benchbar/signin\?next=/app$ ]] || fail "the local address is $URL"
assert_eq "['Lab PC']" "$(people '[p["name"] for p in d["people"]]')"
assert_file "$ITEM"; assert_no_file "$GUEST/keys"
assert_calls_contain '^security -i$' "(the key was not written through security -i)"
assert_calls_not_contain '^(open|xdg-open|wslview) '
assert_eq "200 upstream-ok" "$(python3 "$TMP_DIR/browse.py" "$LOCAL_PORT" "$LOCAL_NAME" /app/sales-order)"
assert_contains "$(python3 "$TMP_DIR/browse.py" "$LOCAL_PORT" evil.example /app)" "403 "
assert_eq 700 "$(perm_of "$GUEST")" "(the guest folder)"

# joined: the text, the document, and for an agent the document without the address that signs a browser in
run_fm share joined
assert_eq 0 "$CODE" "$OUT"
assert_contains "$OUT" "${ROOM_ID}  Test Room (host: Test Host) at 127.0.0.1:${ROOM_PORT}"; assert_contains "$OUT" "open, seat seat2@example.com"; assert_contains "$OUT" "$URL"
run_fm share joined --json
assert_eq "('${ROOM_ID}', 'ready', 'seat2@example.com', True, '${URL}', '${ROOM_ID}', 'macdev')" "$(printf '%s' "$OUT" | jget - '[(r["id"], r["state"], r["seat"], r["forwarding"], r["url"], r["host_key"], r["site"]) for r in d["rooms"]][0]')"
assert_eq "schema_version cli_version rooms" "$(printf '%s' "$OUT" | jget - '" ".join(list(d)[:3])')"
run_fm share joined --for-agent
assert_eq "[None]" "$(printf '%s' "$OUT" | jget - '[r["url"] for r in d["rooms"]]')"

# a second join needs no code, and at a terminal the browser is opened on the local address
: >"$MOCK_LOG"
guest "" join "127.0.0.1:${ROOM_PORT}"
assert_eq 0 "$CODE" "$ALL"
assert_contains "$OUT" "already in the room: no code is needed"; assert_contains "$OUT" "Seat: seat2@example.com"; assert_contains "$OUT" "$URL"
assert_calls_contain "^open ${URL//\?/\\?}$"

# the secrets rule, guest side: the code and the key are nowhere but where they belong
KEY_BODY="$(cat "$ITEM")"
[[ "${#KEY_BODY}" -gt 100 ]] || fail "the Keychain item holds no key"
"$FM" report --print >"$TMP_DIR/report.txt" 2>&1 || true
holds() { # NAME FILE...: fails when a file holds the room code as a word of its own, or the key
  local name="$1" f
  shift
  for f in "$@"; do
    [[ -f "$f" && "$f" != "$ITEM" ]] || continue
    if grep -q -E "(^|[^0-9A-Za-z])${ROOM_CODE}([^0-9A-Za-z]|$)" "$f"; then fail "${name} holds the room code: ${f}"; fi
    if grep -q -F -- "$KEY_BODY" "$f"; then fail "${name} holds this computer's key: ${f}"; fi
  done
}
holds "the output" "$SEEN"
holds "an argument of node" "$MOCK_STATE/node.argv"
holds "a call of a tool" "$MOCK_LOG" "$MOCK_STATE"/keychain/*.cmd
holds "the report" "$TMP_DIR/report.txt"
while IFS= read -r f; do holds "the state folder" "$f"; done < <(find "$FL_STATE_DIR" "$ROOM_STATE" "$ROOM_LOG" -type f)
assert_contains "$(cat "$MOCK_STATE/node.argv")" "guest-cli.js join"

# leave: the host is told, the seat is free, the address is closed; the room and the key stay
guest "" leave "${ROOM_ID:0:4} ${ROOM_ID:4:4}" "${ROOM_ID:8:8}" --json
assert_eq 0 "$CODE" "$ALL"
assert_eq "(True, True, 'Test Room', [{'kind': 'share', 'name': 'Test Room', 'detail': 'left'}])" "$(last '(d["told_host"], d["forwarder_stopped"], d["room"], d["changed"])')"
assert_eq "[]" "$(people '[p["name"] for p in d["people"]]')"
run_fm share joined --json
assert_eq "[('closed', False, None)]" "$(printf '%s' "$OUT" | jget - '[(r["state"], r["forwarding"], r["url"]) for r in d["rooms"]]')"
assert_file "$ITEM"
run_fm share joined
assert_contains "$OUT" "open it: benchbar share join 127.0.0.1:${ROOM_PORT}"
guest "" forget --dry-run
assert_eq 1 "$CODE" "$ALL"; assert_contains "$ALL" "no dry run"
guest "" forget
assert_eq 0 "$CODE" "$ALL"; assert_contains "$OUT" "this computer's key for Test Host is deleted"
assert_no_file "$ITEM"
run_fm share joined --json
assert_eq "[]" "$(printf '%s' "$OUT" | jget - 'd["rooms"]')"
room_stop

# ---------------------------------------------------------------- a room where the host gives out the seats, an invite, Linux and WSL
use_linux
: >"$MOCK_LOG"
room_start host
ROOM_CODE="$(ctl '{"op":"code"}' | jget - 'd["code"]')"; SALT="$(ctl '{"op":"code"}' | jget - 'd["salt"]')"
LINK="benchbar://share/join?v=1&r=Whatever%20it%20says&h=${ROOM_KEY}&s=${SALT}&c=${ROOM_CODE}&a=127.0.0.1%3A${ROOM_PORT}&x=1900000000"
KEYFILE="$GUEST/keys/${ROOM_KEY}.pem"

# nothing answers at an address of the Wi-Fi: on WSL NAT the hint names Windows
MOCK_WSL_NETMODE=nat guest "$ROOM_CODE" join 127.0.0.1:1
assert_eq 1 "$CODE" "$ALL"; assert_contains "$ALL" "didn't answer"; assert_contains "$ALL" "WSL uses NAT networking here and reaches the Wi-Fi through Windows"
guest "$ROOM_CODE" join 127.0.0.1:1
assert_not_contains "$ALL" "NAT"

guest "Join my room <${LINK}>." join --dry-run --json
assert_eq 0 "$CODE" "$ALL"
assert_eq "('${ROOM_ID}', 'Test Room', True)" "$(printf '%s' "$OUT" | jget - '(d["host_key"], d["room"], d["from_invite"])')"
assert_contains "$ALL" "from the invite link, not found on the network"
assert_no_file "$KEYFILE"

guest "$LINK" join --host-key "$OTHER_KEY" --dry-run
assert_eq 3 "$CODE" "$ALL"; assert_contains "$ALL" "another host key"
assert_no_file "$KEYFILE"
guest "$LINK" join --name "Lab PC" --no-wait --host-key "$ROOM_KEY" --json
assert_eq 0 "$CODE" "$ALL"
assert_eq "(True, 'waiting', None, True, 6)" "$(last '(d["joined"], d["state"], d["seat"], d["host_assigns"], len(d["seats"]))')"
assert_contains "$ALL" "No seat yet"
assert_file "$KEYFILE"
assert_eq 600 "$(perm_of "$KEYFILE")" "(the key file)"
assert_calls_not_contain '^security .*benchbar-share-guest'
guest "" join "127.0.0.1:${ROOM_PORT}" --seat seat1 --no-open
assert_eq 1 "$CODE" "$ALL"; assert_contains "$ALL" "gives out the seats in this room"

# the host gives the seat: the next join, with no code, waits for nothing and says where the room is
DEVICE="$(people 'd["people"][0]["id"]')"
GAVE=""
for _ in 1 2 3 4 5; do
  GAVE="$(ctl "{\"op\":\"assign\",\"device\":\"${DEVICE}\",\"seat_id\":\"seat3\"}")"
  [[ "$(printf '%s' "$GAVE" | jget - 'd["ok"]')" != True ]] || break
  sleep 0.2
done
assert_eq "True" "$(printf '%s' "$GAVE" | jget - 'd["ok"]')" "the gateway did not give the seat: $GAVE (device ${DEVICE})"
MOCK_WSL_NETMODE=nat guest "" join "127.0.0.1:${ROOM_PORT}" --no-open
assert_eq 0 "$CODE" "$ALL"
assert_contains "$OUT" "Seat: seat3@example.com"; assert_contains "$OUT" "localhostForwarding=false"
holds "the output" "$SEEN"
holds "an argument of node" "$MOCK_STATE/node.argv"

# the Lab goes off: the local address closes, the room and the key stay
ls "$GUEST"/*.sock >/dev/null 2>&1 || fail "no forwarder socket in the guest folder"
unset BENCHBAR_LABS
BENCHBAR_NONINTERACTIVE=0 run_fm labs on lan-rooms --yes   # as the app turns it on
assert_eq 0 "$CODE" "$OUT"
BENCHBAR_NONINTERACTIVE=1 run_fm labs off lan-rooms
assert_eq 0 "$CODE" "$OUT"
if ls "$GUEST"/*.sock >/dev/null 2>&1; then fail "labs off left a forwarder running"; fi
assert_file "$KEYFILE"
export BENCHBAR_LABS=lan-rooms

# the host draws a new code: the old invite is told so, before anything of the code is sent
ctl '{"op":"remove","device":"'"$DEVICE"'"}' >/dev/null
ctl '{"op":"rotate"}' >/dev/null
guest "$LINK" join
assert_eq 1 "$CODE" "$ALL"; assert_contains "$ALL" "out of date: the host changed the code"
# with the Lab off, forgetting still works
BENCHBAR_LABS="" guest "" forget "$ROOM_ID"
assert_eq 0 "$CODE" "$ALL"; assert_contains "$OUT" "could not be told"
assert_no_file "$KEYFILE"

printf 'test-share-join: ok\n'
