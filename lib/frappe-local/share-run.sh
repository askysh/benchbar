#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# share-run.sh: a share's lifetime.
#
#   benchbar share start [--for DUR] [--name LABEL] [--dry-run] [--json]
#   benchbar share stop [--json]
#   benchbar share extend --by DUR [--json]
#   benchbar share status [--preflight] [--json]
#
# start writes gateway.json (exactly the keys lib/frappe-local/share/config.js
# accepts: any other key makes the gateway exit 78), renders the runner
# (templates/share-run.sh.tmpl) and the job's plist (templates/share.plist.tmpl)
# into the share folder, bootstraps the job com.benchbar-share.gateway by that
# path, kickstarts it and deletes the plist. launchd keeps the job; nothing in
# ~/Library/LaunchAgents names it, so the bench agent's globs (doctor,
# uninstall-service, the agent lists) never see it. The runner starts the web
# process, the gateway, Bonjour and caffeinate in a fixed order and ends the
# job when any of them cannot be trusted.
#
# stop is never refused, whatever the run (no terminal, BENCHBAR_NONINTERACTIVE,
# a node that cannot be trusted, a bench that is down): stopping must always work.
# status only reads, and asks the control socket only when the job is loaded.
#
# The control socket is reached with the share's own node (vetted like the
# gateway's: fl_sp_node_path_problem_v), and its reply is cut down to the
# fields below before bash reads it, so no other field (the room code
# included) can reach a document or a log.

FL_SHARE_JOB_LABEL="com.benchbar-share.gateway"
FL_SHARE_MAX_TOTAL_S=43200
FL_SHARE_MIN_S=300
FL_SHARE_DEFAULT_S=14400
# The runner's time limits (rendered into it) and share start's wait, which is built from them: the
# session wipe, the web process until it listens, its warm-up GET, the control socket, and one run of the
# critical checks. The wipe also runs in the runner's trap, which must end well inside the 20 s launchd
# gives a job after a bootout: about 2 s for the children, then the wipe.
FL_SHARE_WIPE_SECS=8
FL_SHARE_LISTEN_SECS=60
FL_SHARE_WARM_SECS=30
FL_SHARE_SOCK_SECS=15
FL_SHARE_CHECKS_SECS="${FL_SHARE_CHECKS_SECS:-30}"

# node -e SCRIPT control SOCKET REQUEST: one request line, one reply, printed as
# KEY=VALUE lines of the allowed fields only (an array as its length). Exit 0
# for an ok reply, 1 for anything else; no reply within 5 s is error=timeout.
# shellcheck disable=SC2016  # JavaScript source
FL_JS_SHARE_CONTROL='
const net = require("net");
const KEYS = ["ok", "error", "deadline_epoch", "capped", "locked", "lock_reason", "budget_left", "seats", "people", "join_trouble", "web_up"];
const COUNTS = ["online", "wipe_failed"];
const plain = (v) => typeof v === "number" || typeof v === "boolean" || v === null || (typeof v === "string" && /^[a-z_]{1,32}$/.test(v));
const finish = (code, text) => { process.stdout.write(text); process.exit(code); };
setTimeout(() => finish(1, "error=timeout\n"), 5000);
const c = net.connect(process.argv[2]);
let buf = "";
c.on("error", () => finish(1, "error=unreachable\n"));
c.on("connect", () => c.write(process.argv[3] + "\n"));
c.on("data", (chunk) => {
  buf += chunk;
  const nl = buf.indexOf("\n");
  if (nl < 0) return;
  let m;
  try { m = JSON.parse(buf.slice(0, nl)); } catch { return finish(1, "error=bad_reply\n"); }
  if (m === null || typeof m !== "object") return finish(1, "error=bad_reply\n");
  const out = [];
  for (const k of KEYS) if (k in m && plain(m[k])) out.push(k + "=" + (m[k] === null ? "" : m[k]));
  for (const k of COUNTS) if (Array.isArray(m[k])) out.push(k + "=" + m[k].length);
  finish(m.ok === true ? 0 : 1, out.join("\n") + "\n");
});'

fl_share_sock() { printf '%s' "${FL_SHARE_CONTROL_SOCK:-$(fl_share_dir)/control.sock}"; }

# fl_share_phase_v VAR_PID VAR_PHASE: the runner's PID and how far its start has come (both empty
# without the phase file; the runner removes it when it ends, a runner killed with -9 leaves it)
fl_share_phase_v() {
  local __pid="" __phase="" __f
  __f="$(fl_share_dir)/phase"
  [[ ! -s "$__f" ]] || read -r __pid __phase <"$__f" || true
  [[ "$__pid" =~ ^[0-9]+$ ]] || { __pid=""; __phase=""; }
  printf -v "$1" '%s' "$__pid"; printf -v "$2" '%s' "$__phase"
}
# the runner's own PID (not the test process table of FL_KILL_CMD)
fl_share_runner_alive() { [[ -n "$1" ]] && kill -0 "$1" 2>/dev/null; }
fl_share_job_target() { printf '%s/%s' "$(fl_launchd_domain)" "$FL_SHARE_JOB_LABEL"; }
fl_share_job_loaded() { launchctl print "$(fl_share_job_target)" >/dev/null 2>&1; }

# fl_share_dur_v VAR TEXT FLAG: the seconds of "30m" or "4h", from 5 minutes to 12 hours
fl_share_dur_v() {
  local __n
  if [[ "$2" =~ ^([0-9]{1,5})([mh])$ ]]; then
    __n=$((10#${BASH_REMATCH[1]}))
    if [[ "${BASH_REMATCH[2]}" == h ]]; then __n=$((__n * 3600)); else __n=$((__n * 60)); fi
    if [[ "$__n" -ge "$FL_SHARE_MIN_S" && "$__n" -le "$FL_SHARE_MAX_TOTAL_S" ]]; then printf -v "$1" '%s' "$__n"; return 0; fi
  fi
  fl_die "$3 must be 5 minutes to 12 hours." "Example: $3 30m, or $3 4h"
}

fl_share_iso_of() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
fl_share_epoch_of_iso() { date -u -j -f %Y-%m-%dT%H:%M:%SZ "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null || true; }

# fl_share_control_v VAR REQUEST [SCRIPT MODE]: the reply's KEY=VALUE lines; non zero when there is no ok
# reply. SCRIPT (FL_JS_SHARE_ROOM of share-admin.sh) replaces FL_JS_SHARE_CONTROL, MODE is its last argument.
fl_share_control_v() {
  local __out="" __code=0 __problem __sock
  printf -v "$1" '%s' ""
  __sock="$(fl_share_sock)"
  [[ -S "$__sock" ]] || return 1
  fl_sp_node_path_problem_v __problem
  if [[ -n "$__problem" ]]; then fl_log "the control socket is not asked: ${__problem}"; return 1; fi
  __out="$("$SP_NODE_REAL" -e "${3:-$FL_JS_SHARE_CONTROL}" control "$__sock" "$2" ${4:+"$4"} </dev/null 2>/dev/null 3>&-)" || __code=$?
  printf -v "$1" '%s' "$__out"
  return "$__code"
}

# fl_share_reply_v VAR REPLY KEY: one field of a control reply (empty without it)
fl_share_reply_v() {
  local __line __v=""
  while IFS= read -r __line; do
    if [[ "$__line" == "$3="* ]]; then __v="${__line#*=}"; break; fi
  done <<<"$2"
  printf -v "$1" '%s' "$__v"
}

# fl_share_gw_int_v VAR KEY: an integer of gateway.json, in whatever layout (extend rewrites it on one line)
fl_share_gw_int_v() {
  local __text="" __re="\"$2\"[[:space:]]*:[[:space:]]*([0-9]+)"
  [[ ! -f "$(fl_share_dir)/gateway.json" ]] || __text="$(<"$(fl_share_dir)/gateway.json")"
  if [[ "$__text" =~ $__re ]]; then printf -v "$1" '%s' "${BASH_REMATCH[1]}"; else printf -v "$1" '%s' ""; fi
}

# fl_share_gw_str_raw_v VAR KEY: a string of gateway.json as its JSON text, quotes and escapes kept
fl_share_gw_str_raw_v() {
  local __text="" __re="\"$2\"[[:space:]]*:[[:space:]]*(\"([^\"\\\\]|\\\\.)*\")"
  [[ ! -f "$(fl_share_dir)/gateway.json" ]] || __text="$(<"$(fl_share_dir)/gateway.json")"
  if [[ "$__text" =~ $__re ]]; then printf -v "$1" '%s' "${BASH_REMATCH[1]}"; else printf -v "$1" '%s' ""; fi
}

fl_share_write_private() { # FILE MODE CONTENT: written whole (temp file, then mv), never wider than MODE
  local tmp="${1}.new"
  (umask 077; printf '%s' "$3" >"$tmp") && chmod "$2" "$tmp" && mv -f "$tmp" "$1"
}

# devices are scoped to one room: emptied at start and at stop
fl_share_devices_empty() {
  fl_share_write_private "$(fl_share_dir)/devices.json" 600 '{"v":3,"devices":[],"blocked":[]}
' || fl_warn "could not empty $(fl_share_dir)/devices.json"
}

# fl_share_wipe_all: ends every session of the copy (the whole copy, so the users of status.wipe_failed too).
# Redis and the helper run in a subshell, so neither can end the caller (stop must finish): a Redis port
# held by another process, or a helper that dies, is a warning and the wipe_failed marker, which status
# reports and the runner's next start-wipe clears. SH_WIPED_COUNT: the sessions it ended (empty on a failure).
SH_WIPED_COUNT=""
fl_share_wipe_all() {
  local count=""
  SH_WIPED_COUNT=""
  count="$(
    trap 'fl_share_redis_down >/dev/null 2>&1' EXIT
    fl_share_redis_up >&2
    fl_bench_python_v count "$FL_PY_SHARE_SESSIONS" benchbar-share-sessions "$FL_SHARE_SITE" </dev/null
    printf '%s' "$count"
  )" || count=""
  if [[ "$count" =~ ^[0-9]+$ ]]; then
    rm -f "$(fl_share_dir)/wipe_failed"
    SH_WIPED_COUNT="$count"
    fl_info "ended ${count} sessions in ${FL_SHARE_SITE}"
    return 0
  fi
  fl_share_write_private "$(fl_share_dir)/wipe_failed" 600 "" || true
  fl_warn "could not end the sessions in ${FL_SHARE_SITE}; the next share start ends them before anyone can sign in"
  return 1
}

# fl_share_teardown: ends a share in whatever state it is: tells the gateway, boots the job out, removes
# what the runner leaves, empties the room and ends every session of the copy. SH_TORN=1 when there
# was anything to end (a second stop finds nothing, wipes nothing and says unchanged).
# SH_BOOTOUT_FAILED=1 when launchd still lists the job afterwards: the caller must not report it stopped.
SH_TORN=0; SH_BOOTOUT_FAILED=0
fl_share_teardown() {
  local dir sock reply f had=0
  dir="$(fl_share_dir)"; sock="$(fl_share_sock)"
  SH_TORN=0; SH_BOOTOUT_FAILED=0
  fl_share_job_loaded && had=1
  for f in "$sock" "$dir/job.plist" "$dir/share-run.sh" "$dir/gateway.json" "$dir/ended" "$dir/phase"; do [[ ! -e "$f" ]] || had=1; done
  [[ "$had" == 1 ]] || return 0
  if [[ -S "$sock" ]] && fl_share_control_v reply '{"op":"stop"}'; then fl_info "the gateway is stopping"; fi
  if fl_share_job_loaded && ! fl_agent_bootout "$(fl_share_job_target)"; then SH_BOOTOUT_FAILED=1; fi
  rm -f "$sock" "$dir/job.plist" "$dir/share-run.sh" "$dir/gateway.json" "$dir/degraded" "$dir/ended" "$dir/phase"
  fl_share_devices_empty
  fl_share_wipe_all || true
  SH_TORN=1
}

# fl_share_require_setup: share.json of this protocol, and the copy
fl_share_require_setup() {
  local v
  fl_share_cfg_raw_v v v
  [[ -f "$(fl_share_dir)/share.json" && "$v" == 3 && -f "${FL_BENCH_DIR}/sites/${FL_SHARE_SITE}/site_config.json" ]] \
    || fl_die "Sharing is not set up on this bench." "Run benchbar share setup first."
}

# fl_share_seats_lines_v VAR: share.json's seats, one JSON object to a line, as setup wrote them
fl_share_seats_lines_v() {
  local __out="" __line
  while IFS= read -r __line; do
    __line="${__line#"${__line%%[![:space:]]*}"}"; __line="${__line%,}"
    __out="${__out}${__out:+,$'\n'    }${__line}"
  done < <(grep -F '"seat_id"' "$(fl_share_dir)/share.json")
  printf -v "$1" '%s' "$__out"
}

# fl_share_host_label_v VAR: this Mac's name as people see it, cleaned like a room label
fl_share_host_label_v() {
  local __n
  __n="$(scutil --get ComputerName 2>/dev/null || true)"
  fl_share_clean_label_v __n "$__n"
  printf -v "$1" '%s' "${__n:-This Mac}"
}

# fl_share_gateway_json STARTED DEADLINE ROOM_LABEL_JSON: gateway.json, the keys config.js accepts and no other
fl_share_gateway_json() {
  local dir web_port copy_made site seats host lib content
  dir="$(fl_share_dir)"; lib="${FL_SELF_DIR}/lib/frappe-local/share"
  fl_share_cfg_str_v web_port web_port; fl_share_cfg_str_v copy_made copy_made; fl_share_cfg_str_v site site
  fl_share_seats_lines_v seats
  fl_share_host_label_v host
  [[ "$web_port" =~ ^[0-9]+$ && -n "$seats" && -n "$copy_made" ]] || { fl_fail "share.json lacks the web port, the seats or the copy's date"; return 1; }
  content="$(printf '{\n  "v": 3,\n  "protocol": 3,\n  "listen": {"host": "0.0.0.0", "port": %s},\n  "tls": {"key": %s, "cert": %s},\n  "share_site": %s,\n  "web_port": %s,\n  "deadline_epoch": %s,\n  "started_epoch": %s,\n  "max_total_s": %s,\n  "state_dir": %s,\n  "devices": %s,\n  "control_sock": %s,\n  "log_dir": %s,\n  "python": %s,\n  "signin_helper": %s,\n  "max_conns": {"per_device": 64, "total": 256, "unpaired_total": 16, "unpaired_per_ip": 4},\n  "max_body_mb": 50,\n  "label": %s,\n  "room_label": %s,\n  "site_label": %s,\n  "copy_made": %s,\n  "seats": [\n    %s\n  ]\n}\n' \
    "$FL_SHARE_GATEWAY_PORT" "$(fl_json_str "${dir}/host.key")" "$(fl_json_str "${dir}/host.crt")" "$(fl_json_str "$FL_SHARE_SITE")" "$web_port" \
    "$2" "$1" "$FL_SHARE_MAX_TOTAL_S" "$(fl_json_str "$dir")" "$(fl_json_str "${dir}/devices.json")" "$(fl_json_str "$(fl_share_sock)")" \
    "$(fl_json_str "$dir")" "$(fl_json_str "${FL_BENCH_DIR}/env/bin/python")" "$(fl_json_str "${lib}/signin.py")" \
    "$(fl_json_str "$host")" "$3" "$(fl_json_str "$site")" "$(fl_json_str "$copy_made")" "$seats")"
  fl_share_write_private "${dir}/gateway.json" 600 "$content" || { fl_fail "could not write ${dir}/gateway.json"; return 1; }
}

# fl_share_render_job ROOM_LABEL BENCHBAR: the runner (0700) and the job's plist (0600) in the share folder
fl_share_render_job() {
  local dir runner plist web_port site
  dir="$(fl_share_dir)"
  fl_share_cfg_str_v web_port web_port; fl_share_cfg_str_v site site
  runner="$(fl_template_render share-run.sh "SHARE_DIR=${dir}" "SOCK=$(fl_share_sock)" "BENCH=${FL_BENCH_DIR}" "SHARE_SITE=${FL_SHARE_SITE}" \
    "WEB_PORT=${web_port}" "GATEWAY_PORT=${FL_SHARE_GATEWAY_PORT}" "PYTHON=${FL_BENCH_DIR}/env/bin/python" "LIB=${FL_SELF_DIR}/lib/frappe-local" \
    "NODE=${SP_NODE_REAL}" "BENCHBAR=$2" "DNS_SD=${FL_SHARE_DNS_SD:-/usr/bin/dns-sd}" "CAFFEINATE=${FL_SHARE_CAFFEINATE:-/usr/bin/caffeinate}" \
    "LSOF=${FL_SHARE_LSOF:-/usr/sbin/lsof}" "CURL=${FL_CURL:-/usr/bin/curl}" "WIPE_SECS=${FL_SHARE_WIPE_SECS}" "LISTEN_SECS=${FL_SHARE_LISTEN_SECS}" \
    "SOCK_SECS=${FL_SHARE_SOCK_SECS}" "WARM_SECS=${FL_SHARE_WARM_SECS}" \
    "SESSIONS_PY=${FL_PY_SHARE_SESSIONS}" "CONTROL_JS=${FL_JS_SHARE_CONTROL}" "SITE_LABEL=${site}" "ROOM_LABEL=$1")" || return 1
  plist="$(fl_template_render share.plist "LABEL=${FL_SHARE_JOB_LABEL}" "APP_BUNDLE_ID=${FL_APP_BUNDLE_ID}" "RUNNER=${dir}/share-run.sh" \
    "SHARE_DIR=${dir}" "PATH=$(fl_launchd_path_value)" "LOG=${dir}/share.log")" || return 1
  if ! fl_share_write_private "${dir}/share-run.sh" 700 "$runner" || ! fl_share_write_private "${dir}/job.plist" 600 "$plist"; then
    fl_fail "could not write the share job into ${dir}"
    return 1
  fi
}

# fl_share_on_v VAR_DEADLINE [VAR_WEB_UP]: the share answers on its control socket (its deadline, and
# whether the gateway sends to the web process: true once the runner's checks have passed)
fl_share_on_v() {
  local __reply __d __w
  printf -v "$1" '%s' ""
  [[ -z "${2:-}" ]] || printf -v "$2" '%s' ""
  fl_share_control_v __reply '{"op":"status"}' || return 1
  fl_share_reply_v __d "$__reply" deadline_epoch
  fl_share_reply_v __w "$__reply" web_up
  printf -v "$1" '%s' "$__d"
  [[ -z "${2:-}" ]] || printf -v "$2" '%s' "$__w"
}

# a stop that came while a start was on its way: the start ends what it began
fl_share_stop_requested() { [[ -e "$(fl_share_dir)/stop_requested" ]]; }

# ---------------------------------------------------------------- share start

SH_START_FOR=""; SH_START_ROOM_JSON=""; SH_START_NOW=""; SH_START_DEADLINE=""; SH_START_BENCHBAR=""

fl_share_start_step_static_preflight() {
  fl_sp_reset
  fl_sp_static
  fl_sp_print 1 || return 1
  [[ "$SP_WARNED" == 0 ]] || FL_STEP_RESULT=warning
  [[ -n "$SP_NODE_REAL" ]] || { fl_fail "no node to run the gateway on"; return 1; }
}

fl_share_start_step_gateway_config() {
  local dir
  dir="$(fl_share_dir)"
  [[ -s "${dir}/host.key" && -s "${dir}/host.crt" ]] || { fl_fail "the host identity is missing: run benchbar share setup"; return 1; }
  SH_START_BENCHBAR="${FL_SHARE_BENCHBAR:-$FL_SELF}"
  [[ "$SH_START_BENCHBAR" == /* && -x "$SH_START_BENCHBAR" ]] || { fl_fail "benchbar is not at an absolute path: ${SH_START_BENCHBAR}"; return 1; }
  SH_START_NOW="$(date +%s)"
  SH_START_DEADLINE=$((SH_START_NOW + SH_START_FOR))
  # what an earlier runner left (one SIGKILLed leaves its phase with a dead PID) must not be read as this one's
  rm -f "${dir}/ended" "${dir}/degraded" "${dir}/phase"
  fl_share_gateway_json "$SH_START_NOW" "$SH_START_DEADLINE" "$SH_START_ROOM_JSON" || return 1
  fl_share_devices_empty
}

fl_share_start_step_job() {
  local dir target
  dir="$(fl_share_dir)"; target="$(fl_share_job_target)"
  fl_share_render_job "$(printf '%s' "$SH_START_ROOM_JSON" | fl_share_json_unquote)" "$SH_START_BENCHBAR" || return 1
  if fl_share_stop_requested; then fl_fail "benchbar share stop was run while sharing was starting"; return 1; fi
  # the log is this share's: the last one is kept as share.log.1
  if [[ -f "${dir}/share.log" ]]; then mv -f "${dir}/share.log" "${dir}/share.log.1" || true; fi
  if ! fl_agent_bootstrap "${dir}/job.plist" "$FL_SHARE_JOB_LABEL"; then
    rm -f "${dir}/job.plist"
    fl_fail "launchd did not load ${FL_SHARE_JOB_LABEL}"
    return 1
  fi
  rm -f "${dir}/job.plist"
  fl_launchd_kickstart "$target" || { fl_fail "launchd did not start ${FL_SHARE_JOB_LABEL}"; return 1; }
}

# fl_share_phase_secs PHASE: how long the runner may stay in PHASE, from the limits it was rendered with
fl_share_phase_secs() {
  case "$1" in
    starting:wipe) printf '%s' $((FL_SHARE_WIPE_SECS + 5)) ;;
    starting:web) printf '%s' $((FL_SHARE_LISTEN_SECS + FL_SHARE_WARM_SECS + 5)) ;;
    starting:checks) printf '%s' "$FL_SHARE_CHECKS_SECS" ;;
    starting:gateway) printf '%s' $((FL_SHARE_SOCK_SECS + FL_SHARE_CHECKS_SECS)) ;;
    # running: the web is marked up at once; no phase yet: launchd has not started the runner
    *) printf '%s' 10 ;;
  esac
}

# wait_listening: until the gateway says the web is up (the runner's checks passed), for as long as the
# runner lives and each phase keeps within its own limit
fl_share_start_step_wait_listening() {
  local deadline web_up pid ph last="none" since="$SECONDS" ended
  while :; do
    if fl_share_on_v deadline web_up && [[ "$web_up" == true ]]; then break; fi
    if [[ -s "$(fl_share_dir)/ended" ]]; then
      ended="$(awk -F '\t' 'NR == 1 { print $2 }' "$(fl_share_dir)/ended")"
      fl_fail "the sharing job ended: ${ended}"; return 1
    fi
    fl_share_phase_v pid ph
    if [[ -n "$pid" ]] && ! fl_share_runner_alive "$pid"; then fl_fail "the sharing job ended while ${ph} (its log: $(fl_share_dir)/share.log)"; return 1; fi
    [[ "${ph:-none}" == "$last" ]] || { last="${ph:-none}"; since="$SECONDS"; }
    if [[ $((SECONDS - since)) -gt "$(fl_share_phase_secs "${ph:-}")" ]]; then
      fl_fail "the sharing job got no further than ${ph:-being started by launchd} (its log: $(fl_share_dir)/share.log)"; return 1
    fi
    sleep 0.25
  done
  if fl_share_stop_requested; then fl_fail "benchbar share stop was run while sharing was starting"; return 1; fi
}

fl_share_start_step_post_start_preflight() {
  local i gw=""
  fl_sp_reset
  fl_sp_critical
  for ((i = 0; i < ${#SP_ID[@]}; i++)); do [[ "${SP_ID[$i]}" != gateway_reachable ]] || gw="${SP_STATUS[$i]}"; done
  fl_sp_print 1 || return 1
  # the gateway runs: a probe of it that did not run proves nothing
  [[ "$gw" == ok ]] || { fl_fail "gateway_reachable: the gateway was not probed (${gw:-no result})"; return 1; }
}

# fl_share_json_unquote: a JSON string on stdin as its text (the labels hold no escapes but \" and \\)
fl_share_json_unquote() {
  local s
  s="$(cat)"; s="${s#\"}"; s="${s%\"}"
  s="${s//\\\"/\"}"; s="${s//\\\\/\\}"
  printf '%s' "$s"
}

fl_share_start_doc() {
  printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"share_site":%s,"state":"on","label":%s,"port":%s,"started_epoch":%s,"deadline_epoch":%s,"started":%s,"deadline":%s}' \
    "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$FL_SHARE_SITE")" "$SH_START_ROOM_JSON" "$FL_SHARE_GATEWAY_PORT" \
    "$1" "$2" "$(fl_json_str "$(fl_share_iso_of "$1")")" "$(fl_json_str "$(fl_share_iso_of "$2")")"
}

fl_cmd_share_start() {
  local dur=4h name="" name_given=0 label secs deadline started i id code
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --for) [[ -n "${2:-}" ]] || fl_die "--for needs a duration." "Example: --for 30m, or --for 4h"; dur="$2"; shift 2 ;;
      --for=*) dur="${1#*=}"; shift ;;
      --name) [[ "$#" -ge 2 ]] || fl_die "--name needs a label." "Example: --name \"Priya's room\""; name="$2"; name_given=1; shift 2 ;;
      --name=*) name="${1#*=}"; name_given=1; shift ;;
      *) fl_die "Unknown argument for share start: $1" "Use: benchbar share start [--for DUR] [--name LABEL] [--dry-run] [--json]" ;;
    esac
  done
  fl_noninteractive && fl_die "Sharing on the network is a person's decision, so nothing run without a terminal can start it." \
    "Run it in a terminal: benchbar share start"
  [[ -t 0 || "${BENCHBAR_SUDO:-}" == gui ]] || fl_die "Sharing needs a person at a terminal, and this run has none." \
    "Run it in a terminal: benchbar share start"
  ! fl_is_linux || fl_die "Sharing on the network needs macOS." "Run it on a Mac."
  fl_share_dur_v secs "$dur" --for
  fl_require_bench
  fl_share_require_setup
  rm -f "$(fl_share_dir)/stop_requested"
  fl_sp_nc_open 127.0.0.1 "$FL_REDIS_CACHE_PORT" || fl_die "The bench is not running: its Redis does not answer on ${FL_REDIS_CACHE_PORT}." "Start it (benchbar up), then run this again."

  # one share at a time: a second start leaves the one that runs as it is. One that answers but has the
  # web marked down (still starting, or latched down by the gateway) is not "already on": it is refused
  local web_up runner_pid runner_phase
  if fl_share_on_v deadline web_up && [[ "$web_up" != true ]]; then
    fl_share_phase_v runner_pid runner_phase
    fl_die "A share is starting or has its web marked down (${runner_phase:-unknown phase}), so it is not started again." \
      "Wait, and see benchbar share status; benchbar share stop ends it."
  fi
  if [[ "$web_up" == true ]]; then
    fl_share_gw_int_v started started_epoch
    fl_share_gw_str_raw_v SH_START_ROOM_JSON room_label
    [[ -n "$SH_START_ROOM_JSON" ]] || fl_share_cfg_raw_v SH_START_ROOM_JSON room_label
    fl_info "unchanged: sharing is already on until $(fl_share_iso_of "$deadline") (benchbar share extend moves the deadline)"
    [[ "${OPT_JSON:-0}" != 1 ]] || fl_doc_emit 0 "$(fl_share_start_doc "$started" "$deadline")"
    return 0
  fi

  if [[ "$name_given" == 1 ]]; then
    fl_share_clean_label_v label "$name"
    [[ -n "$label" ]] || fl_die "--name needs a label with something printable in it." "Example: --name \"Priya's room\""
    fl_json_str_v SH_START_ROOM_JSON "$label"
  else
    fl_share_cfg_raw_v SH_START_ROOM_JSON room_label
  fi
  SH_START_FOR="$secs"
  started="$(date +%s)"; deadline=$((started + secs))
  fl_header "benchbar share start" "$(fl_mode_name)" "$FL_PROFILE" "$FL_BENCH_DIR" "$FL_SHARE_SITE"
  if [[ "${OPT_JSON:-0}" == 1 ]]; then
    fl_doc_emit 0 "$(printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"share_site":%s,"dry_run":%s,"label":%s,"for_s":%s,"deadline":%s,"steps":["static_preflight","gateway_config","job","wait_listening","post_start_preflight"]}' \
      "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$FL_SHARE_SITE")" "$(fl_json_bool "${FL_DRY_RUN:-0}")" \
      "$SH_START_ROOM_JSON" "$secs" "$(fl_json_str "$(fl_share_iso_of "$deadline")")")" plan
  fi
  fl_box "Share start" \
    "room     $(printf '%s' "$SH_START_ROOM_JSON" | fl_share_json_unquote)" \
    "copy     ${FL_SHARE_SITE}, on port ${FL_SHARE_GATEWAY_PORT} of this Mac's network address" \
    "until    $(fl_share_iso_of "$deadline") ($(fl_fmt_secs "$secs"))"
  if [[ "${FL_DRY_RUN:-0}" == 1 ]]; then
    fl_info "dry-run: nothing was started or written"
    return 0
  fi

  # a job that is loaded but does not answer: one whose runner lives (still starting, or a gateway that
  # is slow or a node that cannot be trusted) is left alone; one whose runner ended is cleared first
  fl_share_phase_v runner_pid runner_phase
  if fl_share_job_loaded && fl_share_runner_alive "$runner_pid"; then
    fl_die "A share is already ${runner_phase:-running}, and its gateway does not answer." "Wait, see benchbar share status, or run benchbar share stop."
  fi
  if fl_share_job_loaded || [[ -e "$(fl_share_sock)" ]]; then
    fl_info "clearing a share that is no longer running"
    fl_share_teardown
  fi

  fl_steps_define "Run the checks" "Write the gateway's settings" "Start the sharing job" "Wait for the gateway" "Run the checks again"
  fl_steps_ids static_preflight gateway_config job wait_listening post_start_preflight
  i=0
  for id in static_preflight gateway_config job wait_listening post_start_preflight; do
    fl_step_begin "$i"
    FL_STEP_RESULT="done"
    code=0
    "fl_share_start_step_${id}" || code=$?
    if [[ "$code" != 0 ]]; then
      fl_step_end failed
      # anything this run started is ended again: a share is either fully up or off
      [[ "$id" == static_preflight ]] || fl_share_teardown
      fl_die "share start stopped at: ${FL_STEP_LABELS[$i]}." "Fix what is listed above, then run it again."
    fi
    fl_step_end "$FL_STEP_RESULT"
    i=$((i + 1))
  done
  fl_changed process share "started until $(fl_share_iso_of "$SH_START_DEADLINE")"
  fl_next_action "benchbar share status" "See who is in the room and the time left"
  fl_next_action "benchbar share stop" "Stop sharing"
  [[ "${OPT_JSON:-0}" != 1 ]] || fl_doc_emit 0 "$(fl_share_start_doc "$SH_START_NOW" "$SH_START_DEADLINE")"
  fl_ok "Sharing ${FL_SHARE_SITE} on your network until $(fl_share_iso_of "$SH_START_DEADLINE")"
}

# ---------------------------------------------------------------- share stop

# no fl_require_bench: a bench that is broken or gone still has its share job booted out
fl_cmd_share_stop() {
  [[ "$#" -eq 0 ]] || fl_die "share stop takes no argument: $1" "Use: benchbar share stop [--json]"
  [[ "${FL_DRY_RUN:-0}" != 1 ]] || fl_die "share stop has no dry run: it changes nothing until it stops the share." "Run benchbar share status to see what would stop."
  # a start on its way sees this and ends what it began
  fl_share_dir_ensure
  fl_share_write_private "$(fl_share_dir)/stop_requested" 600 "" || fl_warn "could not leave the stop marker for a start on its way"
  fl_share_teardown
  if [[ "$SH_BOOTOUT_FAILED" == 1 ]]; then
    fl_die "launchd still lists ${FL_SHARE_JOB_LABEL} after the bootout, so the share may still run." \
      "Run: launchctl bootout $(fl_share_job_target)"
  fi
  if [[ "$SH_TORN" == 1 ]]; then
    fl_changed process share "stopped"
    fl_ok "Sharing stopped"
  else
    fl_info "unchanged: sharing was not on"
  fi
  [[ "${OPT_JSON:-0}" != 1 ]] || fl_doc_emit 0 "$(printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"share_site":%s,"state":"off"}' \
    "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$FL_SHARE_SITE")")"
}

# ---------------------------------------------------------------- share extend

fl_cmd_share_extend() {
  local by="" secs before after capped reply err
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --by) [[ -n "${2:-}" ]] || fl_die "--by needs a duration." "Example: --by 30m, or --by 1h"; by="$2"; shift 2 ;;
      --by=*) by="${1#*=}"; shift ;;
      *) fl_die "Unknown argument for share extend: $1" "Use: benchbar share extend --by DUR [--json]" ;;
    esac
  done
  [[ -n "$by" ]] || fl_die "share extend needs --by." "Example: benchbar share extend --by 1h"
  [[ "${FL_DRY_RUN:-0}" != 1 ]] || fl_die "share extend has no dry run." "benchbar share status shows the deadline and can_extend_s."
  fl_share_dur_v secs "$by" --by
  fl_require_bench
  fl_share_on_v before || fl_die "Sharing is not on." "Start it: benchbar share start"
  if ! fl_share_control_v reply "{\"op\":\"extend\",\"seconds\":${secs}}"; then
    fl_share_reply_v err "$reply" error
    [[ "$err" != ended ]] || fl_die "Sharing has ended." "Start it again: benchbar share start"
    fl_die "The gateway did not extend the share (${err:-no answer})." "See benchbar share status."
  fi
  fl_share_reply_v after "$reply" deadline_epoch
  fl_share_reply_v capped "$reply" capped
  [[ "$after" =~ ^[0-9]+$ ]] || fl_die "The gateway gave no deadline." "See benchbar share status."
  [[ "$after" != "$before" ]] || fl_die "sharing can run for at most 12 hours from the start." "Stop it and start it again for more time."
  [[ "$capped" != true ]] || fl_warn "capped: sharing can run for at most 12 hours from the start"
  fl_changed process share "deadline $(fl_share_iso_of "$after")"
  fl_ok "Sharing now ends at $(fl_share_iso_of "$after")"
  [[ "${OPT_JSON:-0}" != 1 ]] || fl_doc_emit 0 "$(printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"deadline_epoch":%s,"deadline":%s,"capped":%s,"seconds_left":%s}' \
    "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$after" "$(fl_json_str "$(fl_share_iso_of "$after")")" \
    "$(fl_json_bool "$([[ "$capped" == true ]] && echo 1 || echo 0)")" "$((after - $(date +%s)))")"
}

# ---------------------------------------------------------------- share status

# fl_share_copy_json_v VAR: the copy object of status (null without share.json)
fl_share_copy_json_v() {
  local __var="$1" __recorded __rest __made __site __made_epoch __age="null" __apps="" __now __drifted=false
  local __re='"([A-Za-z0-9_-]+)":"([0-9a-f]{40,64})"'
  if [[ ! -f "$(fl_share_dir)/share.json" ]]; then printf -v "$__var" 'null'; return 0; fi
  fl_share_cfg_str_v __made copy_made; fl_share_cfg_str_v __site site
  __made_epoch="$(fl_share_epoch_of_iso "$__made")"
  [[ ! "$__made_epoch" =~ ^[0-9]+$ ]] || __age=$(($(date +%s) - __made_epoch))
  fl_share_cfg_raw_v __recorded apps_at_copy
  __rest="$__recorded"
  while [[ "$__rest" =~ $__re ]]; do
    __now="$(git -C "${FL_BENCH_DIR}/apps/${BASH_REMATCH[1]}" rev-parse -q --verify HEAD 2>/dev/null || true)"
    [[ "$__now" == "${BASH_REMATCH[2]}" ]] || __drifted=true
    __apps="${__apps}${__apps:+,}{\"app\":$(fl_json_str "${BASH_REMATCH[1]}"),\"at_copy\":\"${BASH_REMATCH[2]}\",\"now\":$(fl_json_str "$__now")}"
    __rest="${__rest#*"${BASH_REMATCH[0]}"}"
  done
  printf -v "$__var" '{"made":%s,"source_site":%s,"age_s":%s,"drifted":%s,"apps":[%s]}' \
    "$(fl_json_str "$__made")" "$(fl_json_str "$__site")" "$__age" "$__drifted" "$__apps"
}

# fl_share_preflight_json_v VAR: the critical checks as {"ok","checks":[...]}, without the CLI's fix text
fl_share_preflight_json_v() {
  local __i __sep="" __checks="" __ok=true
  fl_sp_reset
  fl_sp_critical
  for ((__i = 0; __i < ${#SP_ID[@]}; __i++)); do
    [[ "${SP_STATUS[$__i]}" != fail ]] || __ok=false
    __checks="${__checks}${__sep}{\"id\":$(fl_json_str "${SP_ID[$__i]}"),\"class\":$(fl_json_str "${SP_CLASS[$__i]}"),\"status\":$(fl_json_str "${SP_STATUS[$__i]}"),\"message\":$(fl_json_str "${SP_MSG[$__i]}"),\"fix_action\":$(fl_json_str "${SP_ACT[$__i]}")}"
    __sep=","
  done
  printf -v "$1" '{"ok":%s,"checks":[%s]}' "$__ok" "$__checks"
}

fl_cmd_share_status() {
  local want_pre=0 a dir sock now state=off loaded=0 reply="" started="" deadline="" ended="" degraded="null" error="null"
  local site web_port label users seats copy lan_guard pre="null" started_json=null deadline_json=null left=0 can=0
  local total=0 online=0 locked=null lock_reason=null budget=null people=0 trouble=false wipe=0 v files runner_pid runner_phase phase_json=null web_up_json=null
  for a in "$@"; do
    case "$a" in
      --preflight) want_pre=1 ;;
      *) fl_die "Unknown argument for share status: $a" "Use: benchbar share status [--preflight] [--json]" ;;
    esac
  done
  fl_site_json_begin
  fl_require_bench
  dir="$(fl_share_dir)"; sock="$(fl_share_sock)"; now="$(date +%s)"
  fl_share_cfg_str_v site site; fl_share_cfg_str_v web_port web_port; fl_share_cfg_raw_v users allowed_users
  [[ "$web_port" =~ ^[0-9]+$ ]] || web_port=null
  seats="$(grep -c -F '"seat_id"' "${dir}/share.json" 2>/dev/null || true)"; [[ "$seats" =~ ^[0-9]+$ ]] || seats=0
  fl_share_gw_int_v started started_epoch; fl_share_gw_int_v deadline deadline_epoch
  fl_share_gw_str_raw_v label room_label
  [[ -n "$label" ]] || fl_share_cfg_raw_v label room_label

  fl_share_job_loaded && loaded=1
  fl_share_phase_v runner_pid runner_phase
  [[ ! -e "${dir}/wipe_failed" ]] || wipe=1
  if [[ "$loaded" == 1 || -f "${dir}/gateway.json" ]]; then
    if [[ "$loaded" == 1 && -S "$sock" ]] && fl_share_control_v reply '{"op":"status"}'; then
      state=on
      fl_share_reply_v v "$reply" deadline_epoch; [[ ! "$v" =~ ^[0-9]+$ ]] || deadline="$v"
      fl_share_reply_v v "$reply" people; [[ ! "$v" =~ ^[0-9]+$ ]] || { people="$v"; total="$v"; }
      fl_share_reply_v v "$reply" online; [[ ! "$v" =~ ^[0-9]+$ ]] || online="$v"
      fl_share_reply_v v "$reply" seats; [[ ! "$v" =~ ^[0-9]+$ ]] || seats="$v"
      fl_share_reply_v v "$reply" budget_left; [[ ! "$v" =~ ^[0-9]+$ ]] || budget="$v"
      fl_share_reply_v v "$reply" wipe_failed; [[ ! "$v" =~ ^[0-9]+$ ]] || wipe="$v"
      fl_share_reply_v v "$reply" locked; [[ "$v" != true && "$v" != false ]] || locked="$v"
      fl_share_reply_v v "$reply" join_trouble; [[ "$v" != true ]] || trouble=true
      fl_share_reply_v v "$reply" lock_reason; [[ ! "$v" =~ ^(budget|host|full)$ ]] || lock_reason="\"${v}\""
      fl_share_reply_v v "$reply" web_up; [[ "$v" != true && "$v" != false ]] || web_up_json="$v"
      [[ ! -s "${dir}/degraded" ]] || degraded="$(fl_json_str "$(awk 'NR == 1' "${dir}/degraded")")"
    elif [[ "$deadline" =~ ^[0-9]+$ && "$now" -ge "$deadline" ]] || { fl_share_reply_v v "$reply" error; [[ "$v" == ended ]]; }; then
      state=expired
    elif [[ "$runner_phase" == starting:* ]] && fl_share_runner_alive "$runner_pid"; then
      state=starting
      phase_json="\"${runner_phase}\""
    else
      state=error
      [[ ! -s "${dir}/ended" ]] || ended="$(awk -F '\t' 'NR == 1 { print $2 }' "${dir}/ended")"
      error="$(fl_json_str "${ended:-Sharing stopped: the gateway does not answer. Stop sharing and start it again.}")"
    fi
  fi
  if [[ "$state" != off ]]; then
    [[ ! "$started" =~ ^[0-9]+$ ]] || started_json="$(fl_json_str "$(fl_share_iso_of "$started")")"
    [[ ! "$deadline" =~ ^[0-9]+$ ]] || deadline_json="$(fl_json_str "$(fl_share_iso_of "$deadline")")"
  fi
  if [[ "$state" == on && "$deadline" =~ ^[0-9]+$ ]]; then
    left=$((deadline - now)); [[ "$left" -ge 0 ]] || left=0
    if [[ "$started" =~ ^[0-9]+$ ]]; then can=$((started + FL_SHARE_MAX_TOTAL_S - deadline)); [[ "$can" -ge 0 ]] || can=0; fi
  fi

  fl_share_copy_json_v copy
  fl_sp_pf_files_problem_v files
  if [[ -z "$files" ]]; then lan_guard=installed
  elif [[ ! -r "${FL_LANGUARD_ANCHOR:-$FL_SHARE_PF_ANCHOR_FILE}" || ! -r "${FL_LANGUARD_DAEMON:-$FL_SHARE_PF_DAEMON_FILE}" ]]; then lan_guard=missing
  else lan_guard=outdated; fi
  fl_sp_lan_v
  [[ "$want_pre" == 0 ]] || fl_share_preflight_json_v pre

  if [[ "${OPT_JSON:-0}" == 1 ]]; then
    FL_DONE_NO_STATE=1
    fl_doc_emit 0 "$(printf '{"schema_version":%d,"cli_version":"%s","protocol":%d,"bench":%s,"site":%s,"share_site":%s,"state":"%s","phase":%s,"web_up":%s,"degraded":%s,"error":%s,"label":%s,"port":%s,"web_port":%s,"lan_ip":%s,"started":%s,"deadline":%s,"seconds_left":%s,"can_extend_s":%s,"copy":%s,"allowed_users":%s,"seats":%s,"people":%s,"devices_total":%s,"devices_online":%s,"pending":0,"locked":%s,"lock_reason":%s,"budget_left":%s,"join_trouble":%s,"wipe_failed":%s,"lan_guard":"%s","preflight":%s}' \
      "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$FL_SHARE_PROTOCOL" "$(fl_json_str "$FL_BENCH_DIR")" "$( [[ -n "$site" ]] && fl_json_str "$site" || printf 'null')" \
      "$(fl_json_str "$FL_SHARE_SITE")" "$state" "$phase_json" "$web_up_json" "$degraded" "$error" "${label:-null}" "$FL_SHARE_GATEWAY_PORT" "$web_port" \
      "$( [[ -n "$SP_LAN_IP" ]] && fl_json_str "$SP_LAN_IP" || printf 'null')" "$started_json" "$deadline_json" "$left" "$can" "$copy" "${users:-[]}" \
      "$seats" "$people" "$total" "$online" "$locked" "$lock_reason" "$budget" "$trouble" "$wipe" "$lan_guard" "$pre")"
    return 0
  fi
  case "$state" in
    on) fl_ok "Sharing ${FL_SHARE_SITE} until $(fl_share_iso_of "$deadline") ($(fl_fmt_secs "$left") left): ${people} in the room, ${online} online" ;;
    starting) fl_info "Sharing is starting (${runner_phase})." ;;
    expired) fl_info "Sharing has ended (the deadline passed). benchbar share stop clears it." ;;
    error) fl_warn "Sharing is not running: ${ended:-the gateway does not answer}. benchbar share stop clears it." ;;
    *) fl_info "Sharing is off." ;;
  esac
  [[ "$degraded" == null ]] || fl_warn "$(awk 'NR == 1' "${dir}/degraded")"
  fl_info "Network protection: ${lan_guard}"
}
