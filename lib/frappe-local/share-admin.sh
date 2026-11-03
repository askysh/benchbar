#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# share-admin.sh: the host's room while it is shared.
#
#   benchbar share code [--new] [--json]
#   benchbar share lock|unlock [--json]
#   benchbar share people [--json]                              (alias: devices)
#   benchbar share remove ID [--new-code] [--yes] [--json]      (alias: revoke)
#   benchbar share assign ID SEAT_ID [--json]
#   benchbar share log [--device ID] [--since TIME] [--limit N] [--json]
#   benchbar share open-as USER [--print-url] [--json]
#   benchbar share teardown [--yes] [--json]
#
# The room code leaves the gateway only through share code: on the terminal, or in share code --json,
# which the app reads (J14). No run log is opened for it (the dispatcher's list), it is printed with
# printf and never through fl_info or fl_log, and an agent (BENCHBAR_NONINTERACTIVE, so --for-agent and
# mcp too) is refused before the socket is asked.
#
# A removed person's seat is owed a wipe of its Frappe sessions: the gateway keeps such users in
# status.wipe_failed until its wipe op ends them. remove runs that op at once; every other room command
# here that reads the status runs it when anything is owed (share status does not: it only reads). With
# sharing off, the wipe_failed marker share stop leaves is retried while the bench's Redis answers.
#
# open-as delivers the sid exactly as upstream's open --as does (fl_open_as_login_url_v): on the
# browser opener's command line, or on stdout with --print-url; never in --json, a log or a file.

# node -e SCRIPT control SOCKET REQUEST MODE: one request, one reply, printed as MODE asks. Exit 0 for an
# ok reply; anything else prints error=CODE and exits 1. MODE:
#   code         the six digits, and nothing else
#   people_json  the people as a JSON array of the documented fields only
#   people_rows  a line per person, the same fields apart by \x1f
#   wipe         wiped=N and wipe_failed=M (counts)
# Text fields lose control, bidirectional and zero width characters (\x1f with them), so no name can
# reorder a line or split a row.
# shellcheck disable=SC2016  # JavaScript source
FL_JS_SHARE_ROOM='
const net = require("net");
const [, sock, request, mode] = process.argv.slice(1);
const UNSEEN = /[\u0000-\u001f\u007f-\u009f\u061c\u200b-\u200f\u2028-\u202e\u2060-\u206f\ufeff]/g;
const shown = (v) => (typeof v === "string" ? v.replace(UNSEEN, "").trim().slice(0, 200) : "");
const finish = (code, text) => { process.stdout.write(text); process.exit(code); };
setTimeout(() => finish(1, "error=timeout\n"), mode === "wipe" ? 9500 : 5000);
const person = (p) => ({
  id: /^d_[0-9a-f]{8}$/.test(p.id) ? p.id : "", name: shown(p.name), model: shown(p.model), ip: shown(p.paired_ip),
  seat_id: /^[A-Za-z0-9_-]{1,64}$/.test(p.seat_id) ? p.seat_id : null, seat_full_name: shown(p.full_name) || null,
  online: p.online === true, joined: shown(p.added) || null, last_seen: shown(p.last_seen) || null
});
const c = net.connect(sock);
let buf = "";
c.on("error", () => finish(1, "error=unreachable\n"));
c.on("connect", () => c.write(request + "\n"));
c.on("data", (chunk) => {
  buf += chunk;
  const nl = buf.indexOf("\n");
  if (nl < 0) return;
  let m;
  try { m = JSON.parse(buf.slice(0, nl)); } catch { return finish(1, "error=bad_reply\n"); }
  if (m === null || typeof m !== "object") return finish(1, "error=bad_reply\n");
  if (m.ok !== true) return finish(1, "error=" + (typeof m.error === "string" && /^[a-z_]{1,32}$/.test(m.error) ? m.error : "bad_reply") + "\n");
  if (mode === "code") return /^[0-9]{6}$/.test(m.code) ? finish(0, m.code) : finish(1, "error=bad_reply\n");
  if (mode === "wipe") {
    if (!Number.isInteger(m.wiped) || !Array.isArray(m.wipe_failed)) return finish(1, "error=bad_reply\n");
    return finish(0, "wiped=" + m.wiped + "\nwipe_failed=" + m.wipe_failed.length + "\n");
  }
  if (!Array.isArray(m.people)) return finish(1, "error=bad_reply\n");
  const people = m.people.filter((p) => p && typeof p === "object").map(person).filter((p) => p.id);
  if (mode === "people_json") return finish(0, JSON.stringify(people));
  const cell = (v) => (v === null ? "" : String(v));
  finish(0, people.map((p) => [p.id, p.name, p.model, p.ip, p.seat_id, p.seat_full_name, p.online, p.joined, p.last_seen].map(cell).join("\x1f") + "\n").join(""));
});'

# node -e SCRIPT log DIR LIB NOW_MS SINCE_MS DEVICE LIMIT MODE: the activity log's entries of the last 14
# days (by each entry's own time, whatever files survive), at or after SINCE_MS, of DEVICE when it is not
# empty, oldest first, the newest LIMIT of them. Only the six logged fields come out, and the path is cut
# again to its first two segments (policy.redactPath), so a line planted in a file cannot carry a query,
# a cookie or a document name. MODE json: {"entries":[...],"truncated":bool}; rows: truncated=0|1, then
# a line per entry, the fields apart by \x1f.
# shellcheck disable=SC2016  # JavaScript source
FL_JS_SHARE_LOG='
const fs = require("fs");
const path = require("path");
const [, dir, lib, nowMs, sinceMs, device, limit, mode] = process.argv.slice(1);
const { redactPath } = require(path.join(lib, "policy.js"));
const UNSEEN = /[\u0000-\u001f\u007f-\u009f\u061c\u200b-\u200f\u2028-\u202e\u2060-\u206f\ufeff]/g;
const clean = (v) => (typeof v === "string" ? v.replace(UNSEEN, "").slice(0, 200) : "");
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$/;
const cutoff = Math.max(Number(nowMs) - 14 * 86400000, Number(sinceMs));
let names = [];
try { names = fs.readdirSync(dir).filter((n) => /^activity-\d{4}-\d{2}-\d{2}\.log$/.test(n)); } catch { names = []; }
const entries = [];
for (const name of names) {
  let text = "";
  try { text = fs.readFileSync(path.join(dir, name), "utf8"); } catch { continue; }
  for (const line of text.split("\n")) {
    let e;
    try { e = JSON.parse(line); } catch { continue; }
    if (!e || typeof e !== "object" || typeof e.ts !== "string" || !ISO.test(e.ts)) continue;
    const ms = Date.parse(e.ts);
    if (!(ms >= cutoff) || ms > Number(nowMs) + 86400000) continue;
    if (device && e.device !== device) continue;
    entries.push({
      ms, ts: e.ts, device: clean(e.device), user: clean(e.user), method: /^[A-Z]{1,16}$/.test(e.method) ? e.method : "",
      path: redactPath(clean(e.path)), status: Number.isInteger(e.status) ? e.status : 0
    });
  }
}
entries.sort((a, b) => a.ms - b.ms);
const truncated = entries.length > Number(limit);
const kept = entries.slice(-Number(limit)).map(({ ms, ...rest }) => rest);
if (mode === "json") {
  process.stdout.write(JSON.stringify({ entries: kept, truncated }));
} else {
  process.stdout.write("truncated=" + (truncated ? 1 : 0) + "\n" + kept.map((e) => [e.ts, e.device, e.user, e.method, e.path, e.status].join("\x1f") + "\n").join(""));
}'

FL_SHARE_LOG_LIMIT_MAX=5000
SH_STATUS=""
SH_WIPE_JSON=null

fl_share_room_v() { fl_share_control_v "$1" "$2" "$FL_JS_SHARE_ROOM" "$3"; }

# fl_share_require_person WHAT COMMAND: only a person runs WHAT, as with site open-as on and share
# start: never under BENCHBAR_NONINTERACTIVE (so never --for-agent or mcp), and with a terminal on stdin
# unless the app passes BENCHBAR_SUDO=gui after its own alert
fl_share_require_person() {
  fl_noninteractive && fl_die "$1 is a person's decision, so nothing run without a terminal can do it." "Run it in a terminal: $2"
  [[ -t 0 || "${BENCHBAR_SUDO:-}" == gui ]] || fl_die "$1 needs a person at a terminal, and this run has none." "Run it in a terminal: $2"
}

fl_share_valid_device() {
  [[ "$1" =~ ^d_[0-9a-f]{8}$ ]] || fl_die "$1 is not the id of a person in the room (d_ and 8 hex digits)." "benchbar share people lists them."
}

fl_share_refuse_dry_run() {
  [[ "${FL_DRY_RUN:-0}" != 1 ]] || fl_die "share $1 has no dry run." "benchbar share people and benchbar share status show the room."
}

# fl_share_room_status: SH_STATUS, the gateway's status reply; stops the command when sharing is not on
fl_share_room_status() {
  local err
  fl_share_control_v SH_STATUS '{"op":"status"}' && return 0
  fl_share_reply_v err "$SH_STATUS" error
  [[ "$err" != ended ]] || fl_die "Sharing has ended." "Start it again: benchbar share start"
  fl_die "Sharing is not on." "Start it: benchbar share start"
}

# fl_share_wipe_run: the gateway's wipe op, which ends the sessions of every seat it still owes a wipe;
# SH_WIPE_JSON says how it went
fl_share_wipe_run() {
  local reply wiped="" left=""
  if fl_share_room_v reply '{"op":"wipe"}' wipe; then
    fl_share_reply_v wiped "$reply" wiped
    fl_share_reply_v left "$reply" wipe_failed
  fi
  if [[ ! "$wiped" =~ ^[0-9]+$ || ! "$left" =~ ^[0-9]+$ ]]; then
    SH_WIPE_JSON='{"retried":true,"wiped":null,"wipe_failed":null}'
    fl_warn "The gateway did not answer when asked to end the sessions of seats nobody holds; benchbar share status counts what is left."
    return 0
  fi
  SH_WIPE_JSON="{\"retried\":true,\"wiped\":${wiped},\"wipe_failed\":${left}}"
  [[ "$wiped" == 0 ]] || fl_info "ended the sessions of ${wiped} seat(s) nobody holds now"
  [[ "$left" == 0 ]] || fl_warn "The sessions of ${left} seat(s) could not be ended yet. The next room command tries again; benchbar share stop ends every session."
}

# fl_share_wipe_owed: the wipe op, when the status counts seats owed one
fl_share_wipe_owed() {
  local owed
  fl_share_reply_v owed "$SH_STATUS" wipe_failed
  [[ ! "$owed" =~ ^[1-9][0-9]*$ ]] || fl_share_wipe_run
}

# fl_share_wipe_marker_retry: with sharing off, a wipe share stop could not finish (the wipe_failed
# marker) is run again over the whole copy, but only while the bench's Redis answers: a read starts no
# service. The next share start ends them anyway, before anyone can sign in.
fl_share_wipe_marker_retry() {
  [[ -e "$(fl_share_dir)/wipe_failed" ]] || return 0
  if ! fl_sp_nc_open 127.0.0.1 "$FL_REDIS_CACHE_PORT"; then
    SH_WIPE_JSON='{"retried":false,"wiped":null,"wipe_failed":1}'
    fl_warn "Sessions of ${FL_SHARE_SITE} are still owed a wipe and the bench is not running; the next share start ends them before anyone can sign in."
    return 0
  fi
  if fl_share_wipe_all; then
    SH_WIPE_JSON="{\"retried\":true,\"wiped\":${SH_WIPED_COUNT:-0},\"wipe_failed\":0}"
  else
    SH_WIPE_JSON='{"retried":true,"wiped":null,"wipe_failed":1}'
  fi
}

# fl_share_person_name_v VAR ID: the name of the person in the room with the id ID; stops the command
# when nobody has it
fl_share_person_name_v() {
  local __rows __line __id __rest __name
  fl_share_room_v __rows '{"op":"people"}' people_rows || fl_die "The gateway did not list the people in the room." "See benchbar share status."
  while IFS= read -r __line; do
    __id="${__line%%$'\x1f'*}"; __rest="${__line#*$'\x1f'}"; __name="${__rest%%$'\x1f'*}"
    if [[ -n "$__id" && "$__id" == "$2" ]]; then printf -v "$1" '%s' "${__name:-$2}"; return 0; fi
  done <<<"$__rows"
  fl_die "Nobody in the room has the id $2." "benchbar share people lists the people in the room."
}

# fl_share_seat_full_name_v VAR SEAT_ID: the seat's full name as share.json has it (empty when it is not there)
fl_share_seat_full_name_v() {
  local __line __re='"full_name":"(([^"\\]|\\.)*)"'
  __line="$(grep -F -- "\"seat_id\":$(fl_json_str "$2")," "$(fl_share_dir)/share.json" 2>/dev/null | awk 'NR == 1' || true)"
  if [[ "$__line" =~ $__re ]]; then printf -v "$1" '%s' "${BASH_REMATCH[1]}"; else printf -v "$1" '%s' ""; fi
}

fl_share_room_doc() { # FIELDS: a document of the room commands, FIELDS (JSON members) after the shared ones
  printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"share_site":%s,%s,"wipe":%s}' \
    "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$FL_SHARE_SITE")" "$1" "$SH_WIPE_JSON"
}

# ---------------------------------------------------------------- share code

fl_cmd_share_code() {
  local rotate=0 a code reply budget
  for a in "$@"; do
    case "$a" in
      --new) rotate=1 ;;
      *) fl_die "Unknown argument for share code: $a" "Use: benchbar share code [--new] [--json]" ;;
    esac
  done
  fl_noninteractive && fl_die "The room code is for the person sharing, so nothing run without a terminal reads it." "Run it in a terminal: benchbar share code"
  fl_share_refuse_dry_run code
  fl_site_json_begin
  FL_DONE_NO_STATE=1
  fl_require_bench
  fl_share_room_status
  fl_share_wipe_owed
  fl_share_reply_v budget "$SH_STATUS" budget_left
  if [[ "$rotate" == 1 ]]; then
    fl_share_control_v reply '{"op":"rotate"}' || fl_die "The gateway did not draw a new code." "See benchbar share status."
    fl_share_reply_v budget "$reply" budget_left
    fl_changed share room "new code"
  fi
  [[ "$budget" =~ ^[0-9]+$ ]] || budget=null
  fl_share_room_v code '{"op":"code"}' code || fl_die "The gateway did not give the room code." "See benchbar share status."
  [[ "$code" =~ ^[0-9]{6}$ ]] || fl_die "The gateway gave no room code." "See benchbar share status."
  if [[ "${OPT_JSON:-0}" == 1 ]]; then
    fl_doc_emit 0 "$(fl_share_room_doc "\"code\":\"${code}\",\"new\":$(fl_json_bool "$rotate"),\"budget_left\":${budget}")"
    return 0
  fi
  printf '  Room code  %s %s\n' "${code:0:3}" "${code:3:3}"
  printf '  Anyone on this Wi-Fi with the code can join. Remove people anytime.\n'
  printf '  The code proves someone may join; it does not prove to them that this Mac is the host.\n'
}

# ---------------------------------------------------------------- share lock, share unlock

fl_cmd_share_lock() {
  local action="$1" a reason reply locked=true
  shift
  for a in "$@"; do fl_die "Unknown argument for share ${action}: $a" "Use: benchbar share ${action} [--json]"; done
  fl_share_refuse_dry_run "$action"
  fl_require_bench
  fl_share_room_status
  fl_share_wipe_owed
  fl_share_reply_v reason "$SH_STATUS" lock_reason
  if [[ "$action" == lock ]]; then
    if [[ "$reason" == host ]]; then
      fl_info "unchanged: the room is already locked"
    else
      fl_share_control_v reply '{"op":"lock"}' || fl_die "The gateway did not lock the room." "See benchbar share status."
      fl_changed share room "locked"
      fl_ok "Room locked: nobody new can join."
    fi
    reason=host
  elif [[ "$reason" == host || "$reason" == budget ]]; then
    # the status names a budget lock first, so a host lock may sit under it: unlock lifts that one
    fl_share_control_v reply '{"op":"unlock"}' || fl_die "The gateway did not unlock the room." "See benchbar share status."
    fl_share_reply_v reason "$reply" lock_reason
    if [[ "$reason" == budget ]]; then
      fl_warn "Someone typed a wrong room code 10 times. The room is locked."
      fl_note "Only a new code opens it again: benchbar share code --new"
    else
      locked=false; reason=""
      fl_changed share room "unlocked"
      fl_ok "Room unlocked: people with the code can join."
    fi
  elif [[ "$reason" == full ]]; then
    fl_info "unchanged: Room full: every seat is taken. It opens again when someone leaves or is removed."
  else
    locked=false; reason=""
    fl_info "unchanged: the room is not locked"
  fi
  [[ "${OPT_JSON:-0}" != 1 ]] || fl_doc_emit 0 "$(fl_share_room_doc "\"locked\":${locked},\"lock_reason\":$( [[ -n "$reason" ]] && fl_json_str "$reason" || printf null)")"
}

# ---------------------------------------------------------------- share people

fl_cmd_share_people() {
  local a rows line id name model ip seat full online state=on table=()
  for a in "$@"; do fl_die "Unknown argument for share people: $a" "Use: benchbar share people [--json]"; done
  fl_site_json_begin
  FL_DONE_NO_STATE=1
  fl_require_bench
  if ! fl_share_control_v SH_STATUS '{"op":"status"}'; then
    state=off
    fl_share_wipe_marker_retry
  else
    fl_share_wipe_owed
  fi
  if [[ "${OPT_JSON:-0}" == 1 ]]; then
    rows="[]"
    if [[ "$state" == on ]]; then fl_share_room_v rows '{"op":"people"}' people_json || fl_die "The gateway did not list the people in the room." "See benchbar share status."; fi
    fl_doc_emit 0 "$(fl_share_room_doc "\"state\":\"${state}\",\"people\":${rows}")"
    return 0
  fi
  if [[ "$state" == off ]]; then fl_info "Sharing is off: nobody is in the room."; return 0; fi
  fl_share_room_v rows '{"op":"people"}' people_rows || fl_die "The gateway did not list the people in the room." "See benchbar share status."
  table=("ID|Name|Mac|Address|Seat|Online")
  while IFS=$'\x1f' read -r id name model ip seat full online _; do
    [[ -n "$id" ]] || continue
    [[ -n "$full" ]] || full="${seat:-no seat yet}"
    table+=("${id}|${name//|/}|${model//|/}|${ip//|/}|${full//|/}|$([[ "$online" == true ]] && printf yes || printf no)")
  done <<<"$rows"
  fl_info "People in the room: $((${#table[@]} - 1))"
  [[ "${#table[@]}" == 1 ]] || fl_table "${table[@]}"
}

# ---------------------------------------------------------------- share remove

fl_cmd_share_remove() {
  local id="" new_code=0 name reply err
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --new-code) new_code=1 ;;
      -*) fl_die "Unknown argument for share remove: $1" "Use: benchbar share remove ID [--new-code] [--yes] [--json]" ;;
      *) [[ -z "$id" ]] || fl_die "share remove takes one id." "Use: benchbar share remove ID [--new-code] [--yes] [--json]"; id="$1" ;;
    esac
    shift
  done
  [[ -n "$id" ]] || fl_die "share remove needs the id of a person in the room." "benchbar share people lists them."
  fl_share_valid_device "$id"
  fl_share_refuse_dry_run remove
  fl_require_bench
  fl_share_room_status
  fl_share_person_name_v name "$id"
  fl_confirm "Remove ${name} from the room? They are signed out and cannot join this room again." \
    || fl_die "${name} stays in the room." "Run it again and answer yes, or pass --yes."
  if ! fl_share_control_v reply "{\"op\":\"remove\",\"device\":\"${id}\"}"; then
    fl_share_reply_v err "$reply" error
    [[ "$err" != not_found ]] || fl_die "Nobody in the room has the id ${id}." "benchbar share people lists the people in the room."
    fl_die "The gateway did not remove ${name} (${err:-no answer})." "See benchbar share status."
  fi
  fl_changed share "$id" "removed"
  fl_ok "Removed ${name} from the room; they cannot join it again"
  fl_share_wipe_run
  if [[ "$new_code" == 1 ]]; then
    if fl_share_control_v reply '{"op":"rotate"}'; then
      fl_changed share room "new code"
      fl_info "The room has a new code: benchbar share code shows it."
    else
      new_code=0
      fl_warn "The gateway did not draw a new code: run benchbar share code --new"
    fi
  else
    fl_note "A Mac that is new to the room can still join with the code: benchbar share code --new changes it."
  fi
  [[ "${OPT_JSON:-0}" != 1 ]] || fl_doc_emit 0 "$(fl_share_room_doc "\"device\":\"${id}\",\"name\":$(fl_json_str "$name"),\"removed\":true,\"new_code\":$(fl_json_bool "$new_code")")"
}

# ---------------------------------------------------------------- share assign

fl_cmd_share_assign() {
  local id="${1:-}" seat="${2:-}" name full reply err
  [[ "$#" -eq 2 ]] || fl_die "share assign needs the id of a person and a seat." "Use: benchbar share assign ID SEAT_ID [--json]"
  fl_share_valid_device "$id"
  [[ "$seat" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || fl_die "${seat} is not a seat id." "Seat ids look like s_0a1b2c3d; benchbar share people shows the seats people hold."
  fl_share_refuse_dry_run assign
  fl_require_bench
  fl_share_room_status
  fl_share_wipe_owed
  fl_share_person_name_v name "$id"
  fl_share_seat_full_name_v full "$seat"
  if ! fl_share_control_v reply "{\"op\":\"assign\",\"device\":\"${id}\",\"seat_id\":\"${seat}\"}"; then
    fl_share_reply_v err "$reply" error
    case "$err" in
      seat_taken) fl_die "That seat is taken." "benchbar share people shows who holds it." ;;
      no_such_seat) fl_die "No seat ${seat} in this room." "Seat ids look like s_0a1b2c3d; benchbar share people shows the seats people hold." ;;
      not_found) fl_die "Nobody in the room has the id ${id}." "benchbar share people lists the people in the room." ;;
      restarting) fl_die "The sessions of ${name}'s seat could not be ended, so nobody moved." "Try again in a moment." ;;
      *) fl_die "The gateway did not move ${name} (${err:-no answer})." "See benchbar share status." ;;
    esac
  fi
  fl_changed share "$id" "seat ${seat}"
  fl_ok "${name} is now in the seat of ${full:-$seat}"
  [[ "${OPT_JSON:-0}" != 1 ]] || fl_doc_emit 0 "$(fl_share_room_doc "\"device\":\"${id}\",\"name\":$(fl_json_str "$name"),\"seat_id\":$(fl_json_str "$seat"),\"seat_full_name\":$(fl_json_str_or_null "$full")")"
}

# ---------------------------------------------------------------- share log

fl_cmd_share_log() {
  local device="" since="" since_ms=0 limit=200 problem out more line ts dev user method path status table=() mode=rows
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --device) [[ -n "${2:-}" ]] || fl_die "--device needs an id." "Example: --device d_0a1b2c3d"; device="$2"; shift 2 ;;
      --device=*) device="${1#*=}"; shift ;;
      --since) [[ -n "${2:-}" ]] || fl_die "--since needs a time." "Example: --since 2026-11-03T10:00:00Z, or --since 10:00:00"; since="$2"; shift 2 ;;
      --since=*) since="${1#*=}"; shift ;;
      --limit) limit="${2:-}"; shift 2 || shift ;;
      --limit=*) limit="${1#*=}"; shift ;;
      *) fl_die "Unknown argument for share log: $1" "Use: benchbar share log [--device ID] [--since TIME] [--limit N] [--json]" ;;
    esac
  done
  [[ "$limit" =~ ^[0-9]{1,4}$ && "$((10#$limit))" -ge 1 && "$((10#$limit))" -le "$FL_SHARE_LOG_LIMIT_MAX" ]] \
    || fl_die "--limit needs a number from 1 to ${FL_SHARE_LOG_LIMIT_MAX}." "Example: --limit 50"
  limit=$((10#$limit))
  [[ -z "$device" ]] || fl_share_valid_device "$device"
  if [[ -n "$since" ]]; then
    # the log's own times carry milliseconds, which logs --since does not read
    local frac_re='^([0-9-]+T[0-9]{2}:[0-9]{2}:[0-9]{2})\.[0-9]{1,6}(.*)$'
    [[ ! "$since" =~ $frac_re ]] || since="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
    fl_ts_epoch_v since_ms "$since"
    [[ -n "$since_ms" ]] || fl_die "Cannot read the time '${since}'." "Use ISO 8601 (2026-11-03T10:00:00Z, or without the Z for local time), 'YYYY-MM-DD HH:MM:SS', a date, or HH:MM:SS for today"
    since_ms=$((since_ms * 1000))
  fi
  fl_site_json_begin
  FL_DONE_NO_STATE=1
  fl_require_bench
  fl_sp_node_path_problem_v problem
  [[ -z "$problem" ]] || fl_die "The activity log is read with the share's node, which cannot be trusted: ${problem}" "See benchbar share preflight."
  [[ "${OPT_JSON:-0}" != 1 ]] || mode=json
  out="$("$SP_NODE_REAL" -e "$FL_JS_SHARE_LOG" log "$(fl_share_dir)" "${SCRIPT_DIR}/lib/frappe-local/share" "$(($(date +%s) * 1000))" "$since_ms" "$device" "$limit" "$mode" </dev/null 2>/dev/null)" \
    || fl_die "Could not read the activity log in $(fl_share_dir)." "Check the folder's permissions."
  if [[ "$mode" == json ]]; then
    fl_doc_emit 0 "$(printf '{"schema_version":%d,"cli_version":"%s","bench":%s,%s' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "${out#\{}")"
    return 0
  fi
  more=0
  table=("Time|Mac|Seat|Method|Page|Status")
  while IFS= read -r line; do
    if [[ "$line" == truncated=* ]]; then more="${line#truncated=}"; continue; fi
    IFS=$'\x1f' read -r ts dev user method path status <<<"$line"
    [[ -n "$ts" ]] && table+=("${ts}|${dev//|/}|${user//|/}|${method}|${path//|/}|${status}")
  done <<<"$out"
  if [[ "${#table[@]}" == 1 ]]; then fl_info "Nothing in the room's activity log${device:+ for ${device}}${since:+ since ${since}}."; return 0; fi
  fl_table "${table[@]}"
  [[ "$more" == 0 ]] || fl_note "Older entries match too: raise --limit (up to ${FL_SHARE_LOG_LIMIT_MAX}) or narrow it with --since."
}

# ---------------------------------------------------------------- share open-as

# fl_share_seat_problem_v VAR USER: why USER may not be opened in the copy (empty: it may): the copy's own
# check (share preflight's) of that one seat, so a role that can run code is found where it is held
fl_share_seat_problem_v() {
  local __rows __line __rest __done=0 __why=""
  fl_bench_python_v __rows "$FL_PY_SHARE_CHECK" benchbar-share-check "$FL_SHARE_SITE" < <(printf '%s\n' "$2")
  while IFS= read -r __line; do
    [[ "$__line" != "done" ]] || __done=1
    [[ "$__line" == "seat"$'\x1f'"$2"$'\x1f'* ]] || continue
    __rest="${__line#seat$'\x1f'"$2"$'\x1f'}"
    __why="${__why:+${__why}, }${__rest//$'\x1f'/ }"
  done <<<"$__rows"
  [[ "$__done" == 1 ]] || __why="${__why:+${__why}, }the check of the copy did not finish"
  printf -v "$1" '%s' "$__why"
}

fl_cmd_share_open_as() {
  local user="" print_url=0 browser=1 deadline web_up problem web_port sid base url opened=false
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --print-url) print_url=1; browser=0 ;;
      -*) fl_die "Unknown argument for share open-as: $1" "Use: benchbar share open-as USER [--print-url] [--json]" ;;
      *) [[ -z "$user" ]] || fl_die "share open-as takes one user." "Use: benchbar share open-as USER [--print-url] [--json]"; user="$1" ;;
    esac
    shift
  done
  [[ -n "$user" ]] || fl_die "share open-as needs the user of a seat." "Use: benchbar share open-as USER [--print-url] [--json]"
  fl_share_require_person "Opening the copy as a seat" "benchbar share open-as ${user}"
  fl_site_json_begin
  FL_DONE_NO_STATE=1
  fl_require_bench
  if ! fl_share_on_v deadline web_up || [[ "$web_up" != true ]]; then
    fl_die "Sharing is not on, so the copy is not served: start sharing first." "Run: benchbar share start"
  fi
  grep -qF -- "\"user\":$(fl_json_str "$user")," "$(fl_share_dir)/share.json" 2>/dev/null \
    || fl_die "${user} is not a seat of this room, so it is not opened." "The seats are the users of benchbar share setup --users."
  fl_share_seat_problem_v problem "$user"
  [[ -z "$problem" ]] || fl_die "${user} can run code in the copy or cannot sign in there (${problem}), so it is not opened." \
    "Run benchbar share setup --refresh to make the copy and its seats again."
  fl_share_cfg_str_v web_port web_port
  [[ "$web_port" =~ ^[0-9]+$ ]] || fl_die "share.json has no web port." "Run benchbar share setup again."
  sid="$(cd "${FL_BENCH_DIR}/sites" && BENCHBAR_SITES_DIR="${FL_BENCH_DIR}/sites" "${FL_BENCH_DIR}/env/bin/python" \
    "${SCRIPT_DIR}/lib/frappe-local/share/signin.py" "$FL_SHARE_SITE" "$user" </dev/null 2>/dev/null)" || sid=""
  [[ "$sid" =~ ^[A-Za-z0-9_-]{8,200}$ ]] || fl_die "The copy started no session for ${user}." "A seat must be an enabled System User of the copy: see benchbar share preflight."
  base="http://${FL_SHARE_SITE}:${web_port}"
  fl_open_as_login_url_v url "$base" /app "$sid"
  if [[ "$browser" == 1 ]]; then
    if fl_open_url "$url" >/dev/null; then opened=true
    else
      fl_die "No program here opens a browser ($(fl_open_cmd))." "Open it yourself: benchbar share open-as ${user} --print-url"
    fi
  fi
  if [[ "${OPT_JSON:-0}" == 1 ]]; then
    fl_doc_emit 0 "$(printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"share_site":%s,"user":%s,"page":%s,"opened":%s}' \
      "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$FL_SHARE_SITE")" "$(fl_json_str "$user")" \
      "$(fl_json_str "${base}/app")" "$opened")"
  elif [[ "$print_url" == 1 ]]; then
    printf '%s\n' "$url"
  else
    fl_ok "${FL_SHARE_SITE}: opened as ${user} at /app"
  fi
}

# ---------------------------------------------------------------- share teardown

fl_cmd_share_teardown() {
  local a dir copy had_state=0 had_copy=0 archive="" dropped=0 removed=0 tm
  for a in "$@"; do fl_die "Unknown argument for share teardown: $a" "Use: benchbar share teardown [--yes] [--json]"; done
  fl_share_require_person "Tearing down sharing" "benchbar share teardown"
  fl_share_refuse_dry_run teardown
  fl_require_bench
  dir="$(fl_share_dir)"; copy="${FL_BENCH_DIR}/sites/${FL_SHARE_SITE}"
  [[ ! -d "$dir" ]] || had_state=1
  [[ ! -d "$copy" ]] || had_copy=1
  if [[ "$had_state" == 0 && "$had_copy" == 0 ]]; then
    fl_info "unchanged: sharing is not set up on this bench"
  else
    fl_confirm "Tear down sharing? It stops sharing, drops ${FL_SHARE_SITE} (backed up first) and deletes this Mac's host identity: everyone who joined needs a new code and sees a new host." \
      || fl_die "Nothing was torn down." "Run it again and answer yes, or pass --yes."
    if [[ "$had_state" == 1 ]]; then
      fl_share_write_private "${dir}/stop_requested" 600 "" || fl_warn "could not leave the stop marker for a start on its way"
      fl_share_teardown
      [[ "$SH_BOOTOUT_FAILED" == 0 ]] || fl_die "launchd still lists ${FL_SHARE_JOB_LABEL} after the bootout, so the share may still run; nothing else was torn down." \
        "Run: launchctl bootout $(fl_share_job_target), then benchbar share teardown again"
      [[ "$SH_TORN" == 0 ]] || fl_changed process share "stopped"
    fi
    if [[ "$had_copy" == 1 ]]; then
      # site drop backs the copy up first and stops the run on any failure: in a subshell, so the share
      # folder is kept when the copy is
      (OPT_JSON=0 FL_JSONL=0 fl_cmd_site_drop "$FL_SHARE_SITE" --confirm-site "$FL_SHARE_SITE") \
        || fl_die "${FL_SHARE_SITE} was not dropped, so the share folder is kept." "Fix what is listed above, then run benchbar share teardown again."
      archive="$(fl_site_archive_latest "$FL_SHARE_SITE")"
      dropped=1
      fl_changed site "$FL_SHARE_SITE" "dropped${archive:+, archived to ${archive}}"
    fi
    if [[ "$had_state" == 1 && "$dir" == "${FL_STATE_DIR}/share" ]]; then
      # the copy keeps its exclusion: setup's is sticky (tmutil addexclusion without -p), so it moved with the
      # folder to archived/sites, and that archive (with drop-site's backup in it) holds the site's real data.
      # The share folder's goes last, so a failure above leaves it excluded.
      tm="${FL_TMUTIL:-/usr/bin/tmutil}"
      if ! fl_is_linux && [[ -x "$tm" ]]; then
        "$tm" removeexclusion "$dir" >>"${FL_LOG_FILE:-/dev/null}" 2>&1 || fl_warn "could not remove the Time Machine exclusion of ${dir}"
      fi
      rm -rf -- "$dir" || fl_die "Could not remove ${dir}." "Remove it yourself: rm -rf ${dir}"
      removed=1
      fl_changed config "$dir" "removed: the host identity, the room and its activity log"
    fi
    fl_ok "Sharing is torn down"
  fi
  [[ "${OPT_JSON:-0}" != 1 ]] || fl_doc_emit 0 "$(printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"share_site":%s,"copy_dropped":%s,"archived_path":%s,"state_removed":%s}' \
    "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$FL_SHARE_SITE")" "$(fl_json_bool "$dropped")" \
    "$(fl_json_str_or_null "$archive")" "$(fl_json_bool "$removed")")"
}
