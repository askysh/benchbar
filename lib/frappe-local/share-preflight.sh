#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# share-preflight.sh: benchbar share preflight [--static|--critical] [--quiet] [--json]
# (shown to people as "Checks"). It proves this Mac is safe to share the hardened
# copy on the LAN, and it fails closed: a probe that cannot run is a failure,
# never an ok.
#
#   static    before anything starts: the copy, its seats, node, the firewall
#   critical  once the web process is up, again once the gateway is, then every
#             watchdog tick: the pf block, the share web process, the bench's Redis
#
# The pf check is not vacuous. A probe of a blocked port that is refused proves
# nothing when the probe itself cannot connect, so each run opens its own
# throwaway listener on 0.0.0.0 inside the blocked range, plus a control above
# the range, and probes both from this Mac's own LAN address: the listener must
# be refused and the control must answer. The anchor's rule is "from !
# 127.0.0.1", so the LAN address of this very Mac is blocked too.
#
# Every program is the absolute system one, or the file named by its FL_* seam
# (FL_NC, FL_CURL, FL_ROUTE, FL_IPCONFIG, FL_IFCONFIG, FL_SOCKETFILTERFW,
# FL_SHARE_NODE; FL_LANGUARD_ANCHOR and FL_LANGUARD_DAEMON for where these checks
# read the pf files): the tests point them at mocks, nothing else sets them. They
# only choose what this user's process reads; what root runs and writes is fixed
# (lan-guard.sh).

FL_SHARE_PROTOCOL=3
FL_SHARE_GATEWAY_PORT=8443
FL_SHARE_MIN_NODE=22

# The non-comment lines of the pf anchor, whitespace squeezed. lan-guard installs the same text.
# shellcheck disable=SC2016  # pf source: $ports is pf's macro, not the shell's
FL_SHARE_PF_TEMPLATE='ports = "{ 8000:8099, 9000:9099, 11000:11099, 13000:13099, 3306 }"
block return in quick inet proto tcp from ! 127.0.0.1 to any port $ports
block return in quick inet6 proto tcp from ! ::1 to any port $ports'

# The two root files lan-guard installs, and the daemon's exact text: pfctl enables pf (-E) and loads the
# anchor at every boot (RunAtLoad).
FL_SHARE_PF_ANCHOR_FILE=/etc/pf.anchors/com.benchbar.lan
FL_SHARE_PF_DAEMON_FILE=/Library/LaunchDaemons/com.benchbar.pf.plist
FL_SHARE_PF_PLIST='<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.benchbar.pf</string>
    <key>ProgramArguments</key>
    <array>
        <string>/sbin/pfctl</string><string>-E</string>
        <string>-a</string><string>com.apple/250.benchbar</string>
        <string>-f</string><string>/etc/pf.anchors/com.benchbar.lan</string>
    </array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>'

# The throwaway listener (node -e SCRIPT [6]). It prints "ready V4_RANGE V4_CONTROL V6_RANGE V6_CONTROL"
# (0: could not listen, or not asked for) and exits by itself after 20 s whatever happens to its parent.
# The range is tried from the top down, away from the ports a bench starts at.
# shellcheck disable=SC2016  # JavaScript source
FL_JS_SHARE_LISTENER='
const net = require("net");
const want6 = process.argv[1] === "6";
const keep = [];
function listenOn(host, candidates) {
  return new Promise((resolve) => {
    const attempt = (i) => {
      if (i >= candidates.length) return resolve(0);
      const server = net.createServer((socket) => socket.destroy());
      server.once("error", () => attempt(i + 1));
      server.listen({ port: candidates[i], host: host, ipv6Only: host === "::" }, () => { keep.push(server); resolve(candidates[i]); });
    };
    attempt(0);
  });
}
const inRange = [];
for (let p = 8099; p >= 8002; p--) inRange.push(p);
const outside = [];
const first = 18000 + Math.floor(Math.random() * 20000);
for (let i = 0; i < 40; i++) outside.push(first + i);
setTimeout(() => process.exit(0), 20000);
(async () => {
  const v4Range = await listenOn("0.0.0.0", inRange);
  const v4Control = await listenOn("0.0.0.0", outside);
  const v6Range = want6 ? await listenOn("::", inRange) : 0;
  const v6Control = want6 ? await listenOn("::", outside) : 0;
  console.log("ready " + v4Range + " " + v4Control + " " + v6Range + " " + v6Control);
})();'

# ---------------------------------------------------------------- results

SP_ID=(); SP_CLASS=(); SP_STATUS=(); SP_MSG=(); SP_FIX=(); SP_ACT=(); SP_EXTRA=(); SP_NOTE=()
SP_LAN_IP=""; SP_LAN_IFACE=""; SP_LAN_IP6=""; SP_WEB_PORT=""
SP_SEAT_USERS=(); SP_SEAT_NAMES=()
SP_NODE_REAL=""; SP_COPY_READY=0
SP_LISTENER_PID=""; SP_LISTENER_OUT=""; SP_L4R=0; SP_L4C=0; SP_L6R=0; SP_L6C=0
SP_HTTP_CODE=""; SP_HTTP_TYPE=""; SP_HTTP_WERKZEUG=0; SP_HTTP_EXC=0

# fl_sp_add ID CLASS STATUS MESSAGE [FIX [FIX_ACTION]]
fl_sp_add() {
  SP_ID+=("$1"); SP_CLASS+=("$2"); SP_STATUS+=("$3"); SP_MSG+=("$4"); SP_FIX+=("${5:-}"); SP_ACT+=("${6:-none}")
  SP_EXTRA+=(""); SP_NOTE+=("")
}

# fl_sp_detail JSON_MEMBER TEXT: more about the check just added, kept out of its message (which the app
# shows as written): JSON_MEMBER joins the check's object, TEXT follows the message in the terminal
fl_sp_detail() {
  local last=$((${#SP_ID[@]} - 1))
  SP_EXTRA[last]="$1"; SP_NOTE[last]="$2"
}

# ---------------------------------------------------------------- probes

# fl_sp_nc_open ARGS...: whether a TCP connection to HOST PORT succeeds within a second (nc -z -w1 ARGS)
fl_sp_nc_open() { "${FL_NC:-/usr/bin/nc}" -z -w1 "$@" >/dev/null 2>&1; }

# fl_sp_lan_v: SP_LAN_IFACE and SP_LAN_IP, the address of the default route's interface
fl_sp_lan_v() {
  local out iface ip
  SP_LAN_IFACE=""; SP_LAN_IP=""; SP_LAN_IP6=""
  out="$("${FL_ROUTE:-/sbin/route}" -n get default 2>/dev/null || true)"
  iface="$(printf '%s\n' "$out" | awk '$1 == "interface:" { print $2; exit }')"
  [[ "$iface" =~ ^[A-Za-z0-9]+$ ]] || return 0
  ip="$("${FL_IPCONFIG:-/usr/sbin/ipconfig}" getifaddr "$iface" 2>/dev/null || true)"
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 0
  SP_LAN_IFACE="$iface"; SP_LAN_IP="$ip"
  fl_sp_lan6_v "$iface"
}

# fl_sp_lan6_v IFACE: SP_LAN_IP6, a non-link-local address of the interface, else its link-local one with its scope
fl_sp_lan6_v() {
  local out line addr="" linklocal="" re='^[[:space:]]*inet6[[:space:]]+([0-9a-fA-F:]+)'
  out="$("${FL_IFCONFIG:-/sbin/ifconfig}" "$1" inet6 2>/dev/null || true)"
  while IFS= read -r line; do
    [[ "$line" =~ $re ]] || continue
    [[ "$line" != *tentative* && "$line" != *duplicated* && "$line" != *detached* ]] || continue
    case "${BASH_REMATCH[1]}" in
      ::1) ;;
      [fF][eE][89aAbB]*) [[ -n "$linklocal" ]] || linklocal="${BASH_REMATCH[1]}%${1}" ;;
      *) addr="${BASH_REMATCH[1]}"; break ;;
    esac
  done <<<"$out"
  SP_LAN_IP6="${addr:-$linklocal}"
}

# fl_sp_node_v VAR: the node the share would run on: FL_SHARE_NODE, else the profile's Homebrew node
fl_sp_node_v() {
  if [[ -n "${FL_SHARE_NODE:-}" ]]; then printf -v "$1" '%s' "$FL_SHARE_NODE"; else printf -v "$1" '%s' "$(fl_node_bin)"; fi
}

# fl_sp_realpath_v VAR PATH: PATH with every symlink resolved (readlink -f is not on a Mac's bash 3.2 PATH)
fl_sp_realpath_v() {
  local p="$2" dir i=0 target
  while [[ -L "$p" && "$i" -lt 40 ]]; do
    target="$(readlink "$p")"
    case "$target" in /*) p="$target" ;; *) p="$(dirname "$p")/${target}" ;; esac
    i=$((i + 1))
  done
  dir="$(cd -P "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
  printf -v "$1" '%s/%s' "${dir%/}" "$(basename "$p")"
}

# fl_sp_listener_start NODE WANT6: SP_LISTENER_PID and the four ports; fails when NODE cannot open them.
# NODE must already have passed fl_sp_node_path_problem_v. fl_cleanup stops it however the run ends.
fl_sp_listener_start() {
  local node="$1" ready i
  SP_LISTENER_PID=""; SP_L4R=0; SP_L4C=0; SP_L6R=0; SP_L6C=0
  [[ "$node" == /* && -x "$node" ]] || return 1
  SP_LISTENER_OUT="$(mktemp "${TMPDIR:-/tmp}/benchbar-share-listener.XXXXXX")" || return 1
  # fd 3 is the real stdout of a --json run: the child must not keep it open
  "$node" -e "$FL_JS_SHARE_LISTENER" "$2" >"$SP_LISTENER_OUT" 2>/dev/null </dev/null 3>&- &
  SP_LISTENER_PID="$!"
  for ((i = 0; i < 50; i++)); do
    [[ ! -s "$SP_LISTENER_OUT" ]] || break
    kill -0 "$SP_LISTENER_PID" 2>/dev/null || break
    sleep 0.1
  done
  read -r ready SP_L4R SP_L4C SP_L6R SP_L6C <"$SP_LISTENER_OUT" || true
  [[ "$ready" == ready && "$SP_L4R" =~ ^[0-9]+$ && "$SP_L4C" =~ ^[0-9]+$ && "$SP_L6R" =~ ^[0-9]+$ && "$SP_L6C" =~ ^[0-9]+$ ]] || return 1
  [[ "$SP_L4R" != 0 && "$SP_L4C" != 0 ]] || return 1
  [[ "$2" != 6 || ( "$SP_L6R" != 0 && "$SP_L6C" != 0 ) ]]
}

fl_sp_listener_stop() {
  [[ -z "$SP_LISTENER_PID" ]] || { kill "$SP_LISTENER_PID" 2>/dev/null || true; wait "$SP_LISTENER_PID" 2>/dev/null || true; }
  [[ -z "$SP_LISTENER_OUT" ]] || rm -f "$SP_LISTENER_OUT"
  SP_LISTENER_PID=""; SP_LISTENER_OUT=""
}

# fl_sp_fetch URL: one GET of the share web process: SP_HTTP_CODE (empty: it did not answer), SP_HTTP_TYPE
# (lower case), SP_HTTP_WERKZEUG and SP_HTTP_EXC (whether the body names Werkzeug, or carries a traceback).
# A traceback is an exc, exception or _exc_source key, or the text of one. exc_type alone is not: Frappe v15
# sets it on every API error whatever allow_error_traceback says (frappe/utils/response.py report_error,
# outside its allow_traceback branch), and it holds only the class name.
fl_sp_fetch() {
  local hdr body line
  SP_HTTP_CODE=""; SP_HTTP_TYPE=""; SP_HTTP_WERKZEUG=0; SP_HTTP_EXC=0
  hdr="$(mktemp "${TMPDIR:-/tmp}/benchbar-share-hdr.XXXXXX")"; body="$(mktemp "${TMPDIR:-/tmp}/benchbar-share-body.XXXXXX")"
  if "${FL_CURL:-/usr/bin/curl}" -s -m 3 -H "Host: ${FL_SHARE_SITE}" -o "$body" -D "$hdr" "$1" >/dev/null 2>&1; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      case "$line" in
        HTTP/*) SP_HTTP_CODE="${line#* }"; SP_HTTP_CODE="${SP_HTTP_CODE%% *}" ;;
        [Cc][Oo][Nn][Tt][Ee][Nn][Tt]-[Tt][Yy][Pp][Ee]:*) SP_HTTP_TYPE="$(printf '%s' "${line#*:}" | tr '[:upper:]' '[:lower:]')" ;;
      esac
    done <"$hdr"
    ! grep -qiF Werkzeug "$body" || SP_HTTP_WERKZEUG=1
    ! grep -Eq '"(exc|exception|_exc_source)"[[:space:]]*:' "$body" || SP_HTTP_EXC=1
    ! grep -qF 'Traceback (most recent call last)' "$body" || SP_HTTP_EXC=1
  fi
  rm -f "$hdr" "$body"
}

# ---------------------------------------------------------------- critical checks

# fl_sp_pf_files_problem_v VAR: why the anchor or its daemon is not what lan-guard installs (empty: they are)
fl_sp_pf_files_problem_v() {
  local anchor="${FL_LANGUARD_ANCHOR:-$FL_SHARE_PF_ANCHOR_FILE}" daemon="${FL_LANGUARD_DAEMON:-$FL_SHARE_PF_DAEMON_FILE}" lines want
  local squeeze='s/^[[:space:]]*//; /^#/d; /^$/d; s/[[:space:]][[:space:]]*/ /g; s/[[:space:]]$//'
  # a whole-line XML comment is the header an earlier install wrote, not part of what launchd reads
  local squeeze_xml='s/^[[:space:]]*//; /^<!--.*-->$/d; /^$/d; s/[[:space:]][[:space:]]*/ /g; s/[[:space:]]$//'
  printf -v "$1" '%s' ""
  if [[ ! -r "$anchor" ]]; then printf -v "$1" 'the pf anchor %s is missing' "$anchor"; return 0; fi
  lines="$(sed "$squeeze" "$anchor")"
  want="$(printf '%s\n' "$FL_SHARE_PF_TEMPLATE" | sed "$squeeze")"
  if [[ "$lines" != "$want" ]]; then printf -v "$1" 'the pf anchor %s does not match what lan-guard installs' "$anchor"; return 0; fi
  if [[ ! -r "$daemon" ]]; then printf -v "$1" 'the launch daemon %s is missing' "$daemon"; return 0; fi
  lines="$(sed "$squeeze_xml" "$daemon")"
  want="$(printf '%s\n' "$FL_SHARE_PF_PLIST" | sed "$squeeze_xml")"
  if [[ "$lines" != "$want" ]]; then
    printf -v "$1" 'the launch daemon %s does not match what lan-guard installs (it must enable pf and load the anchor at boot)' "$daemon"
  fi
}

# fl_sp_probe_pf: the local_network and pf_active checks
# pf_active's fix_action names the cause: the pf files or a port that answers (install_network_protection)
# before a listener that could not run (none) before a control that did not answer
# (open_local_network_settings, the cause local_network names).
# SP_PF_PROBE is what the probe alone saw, the files aside: answered (a port that must be refused
# answered), blocked (none did, and the control answered) or unknown (the probe could not run).
fl_sp_probe_pf() {
  local want6="" problems=() control_bad=0 listener_bad=0 pf_bad=0 answered=0 files node_problem p ports=() seen=" " ip="$SP_LAN_IP" action
  [[ -z "$SP_LAN_IP6" ]] || want6=6
  fl_sp_pf_files_problem_v files
  [[ -z "$files" ]] || { pf_bad=1; problems+=("$files"); }
  fl_sp_node_path_problem_v node_problem
  if [[ -n "$node_problem" ]]; then
    listener_bad=1; problems+=("Node cannot be trusted to run the gateway: ${node_problem}")
  elif fl_sp_listener_start "$SP_NODE_REAL" "$want6"; then
    if ! fl_sp_nc_open "$ip" "$SP_L4C"; then
      control_bad=1; problems+=("the probe itself does not work: this Mac did not answer its own address ${ip} on port ${SP_L4C}, outside the blocked ranges")
    elif fl_sp_nc_open "$ip" "$SP_L4R"; then
      pf_bad=1; answered=1; problems+=("${SP_L4R} answers on ${ip}: the pf block let a test listener through")
    fi
    if [[ -n "$want6" ]]; then
      if ! fl_sp_nc_open -6 "$SP_LAN_IP6" "$SP_L6C"; then
        control_bad=1; problems+=("the probe itself does not work over IPv6: this Mac did not answer its own address ${SP_LAN_IP6} on port ${SP_L6C}")
      elif fl_sp_nc_open -6 "$SP_LAN_IP6" "$SP_L6R"; then
        pf_bad=1; answered=1; problems+=("IPv6 ${SP_L6R} answers on ${SP_LAN_IP6}: the pf block let a test listener through")
      fi
    fi
  else
    listener_bad=1; problems+=("could not open a throwaway listener to test the block (node: see the log)")
  fi
  fl_sp_listener_stop
  # shellcheck disable=SC2153  # the bench's ports, set by fl_context_init
  ports=("$FL_WEB_PORT" "$FL_REDIS_CACHE_PORT" "$FL_REDIS_QUEUE_PORT" 3306)
  [[ -z "$SP_WEB_PORT" ]] || ports=("$SP_WEB_PORT" "${ports[@]}")
  for p in "${ports[@]}"; do
    [[ "$p" =~ ^[0-9]+$ && "$seen" != *" ${p} "* ]] || continue
    seen="${seen}${p} "
    if fl_sp_nc_open 127.0.0.1 "$p" && fl_sp_nc_open "$ip" "$p"; then pf_bad=1; answered=1; problems+=("${p} answers on ${ip}"); fi
  done
  if [[ "$answered" == 1 ]]; then SP_PF_PROBE=answered
  elif [[ "$listener_bad" == 1 || "$control_bad" == 1 ]]; then SP_PF_PROBE=unknown
  else SP_PF_PROBE=blocked; fi

  if [[ "$listener_bad" == 1 ]]; then
    fl_sp_add local_network critical skip "no probe could run"
  elif [[ "$control_bad" == 1 ]]; then
    fl_sp_add local_network critical fail "This Mac did not answer its own address ${ip} on a port outside the bench ports. If BenchBar has no Local Network access, allow it under System Settings > Privacy & Security > Local Network." \
      "Open System Settings > Privacy & Security > Local Network and allow BenchBar." open_local_network_settings
  else
    fl_sp_add local_network critical ok "this Mac answers its own address ${ip}"
  fi
  if [[ "${#problems[@]}" -eq 0 ]]; then
    fl_sp_add pf_active critical ok "bench ports are refused on ${ip}, and the control port answers"
  else
    local joined="" problem fix="benchbar lan-guard install"
    for problem in "${problems[@]}"; do joined="${joined}${joined:+; }${problem}"; done
    if [[ "$pf_bad" == 1 ]]; then action=install_network_protection
    elif [[ "$listener_bad" == 1 ]]; then action=none
    else action=open_local_network_settings; fix="Open System Settings > Privacy & Security > Local Network and allow BenchBar."; fi
    fl_sp_add pf_active critical fail "$joined" "$fix" "$action"
  fi
}

# fl_sp_no_web_port ID: a critical check of the share web process that has no port to look at. It fails: a
# watchdog tick that cannot see the web process has not shown it is safe.
fl_sp_no_web_port() {
  if [[ ! -f "$(fl_share_dir)/share.json" ]]; then
    fl_sp_add "$1" critical fail "There is no share.json, so there is no share web port to check." "Run benchbar share setup." rerun_setup
  else
    fl_sp_add "$1" critical fail "share.json names no usable share web port." "Stop sharing and start it again." restart_sharing
  fi
}

fl_sp_critical() {
  local ip i code gateway_sock="${FL_SHARE_CONTROL_SOCK:-$(fl_share_dir)/control.sock}" violations
  local urls=("/" "/?__debugger__=yes&cmd=resource&f=style.css" "/console")
  fl_sp_lan_v
  fl_share_cfg_str_v SP_WEB_PORT web_port
  [[ "$SP_WEB_PORT" =~ ^[0-9]+$ ]] || SP_WEB_PORT=""
  ip="$SP_LAN_IP"
  if [[ -z "$ip" ]]; then
    fl_sp_add lan_ip critical fail "This Mac has no LAN address (no default route with an IPv4 address), so nothing can be probed." \
      "Join a network, then try again." none
    fl_sp_add local_network critical skip "no LAN address"
    fl_sp_add pf_active critical skip "no LAN address"
    fl_sp_add gateway_reachable critical skip "no LAN address"
    fl_sp_add share_web_lan_closed critical skip "no LAN address"
  else
    fl_sp_add lan_ip critical ok "${ip} on ${SP_LAN_IFACE}"
    fl_sp_probe_pf
    if [[ ! -e "$gateway_sock" ]]; then
      fl_sp_add gateway_reachable critical skip "the gateway is not running yet"
    elif fl_sp_nc_open "$ip" "$FL_SHARE_GATEWAY_PORT"; then
      fl_sp_add gateway_reachable critical ok "the gateway answers on ${ip}:${FL_SHARE_GATEWAY_PORT}"
    else
      fl_sp_add gateway_reachable critical fail "The gateway does not answer on ${ip}:${FL_SHARE_GATEWAY_PORT}." "Stop sharing and start it again." restart_sharing
    fi
    if [[ -z "$SP_WEB_PORT" ]]; then
      fl_sp_no_web_port share_web_lan_closed
    elif fl_sp_nc_open "$ip" "$SP_WEB_PORT"; then
      fl_sp_add share_web_lan_closed critical fail "The share web port ${SP_WEB_PORT} answers on ${ip}: anyone on the network could reach it without the gateway." "Stop sharing." restart_sharing
    else
      fl_sp_add share_web_lan_closed critical ok "the share web port ${SP_WEB_PORT} is refused on ${ip}"
    fi
  fi

  if [[ -z "$SP_WEB_PORT" ]]; then
    fl_sp_no_web_port share_traceback_off
  else
    fl_sp_fetch "http://127.0.0.1:${SP_WEB_PORT}/api/method/benchbar.no.such.method"
    if [[ -z "$SP_HTTP_CODE" ]]; then
      fl_sp_add share_traceback_off critical fail "The share web process does not answer on 127.0.0.1:${SP_WEB_PORT}." "Stop sharing and start it again." restart_sharing
    elif [[ "$SP_HTTP_EXC" == 1 ]]; then
      fl_sp_add share_traceback_off critical fail "The share web process returns tracebacks to guests (exc in an error answer)." "Run benchbar share setup --refresh." rerun_setup
    else
      fl_sp_add share_traceback_off critical ok "errors carry no traceback"
    fi
  fi

  if fl_sp_nc_open 127.0.0.1 "$FL_REDIS_CACHE_PORT"; then
    fl_sp_add bench_redis_up critical ok "Redis answers on ${FL_REDIS_CACHE_PORT}"
  else
    fl_sp_add bench_redis_up critical fail "The bench is stopped: Redis does not answer on ${FL_REDIS_CACHE_PORT}." "Start the bench (benchbar up)." none
  fi

  if [[ -z "$SP_WEB_PORT" ]]; then
    fl_sp_no_web_port share_debugger_off
  else
    violations=""
    # / and the debugger URL (whose path is also /) are the home page once the debugger is off, and Frappe
    # renders it for a Guest with 200 (login): only their body and type are held against them
    for i in 0 1 2; do
      fl_sp_fetch "http://127.0.0.1:${SP_WEB_PORT}${urls[$i]}"
      if [[ -z "$SP_HTTP_CODE" ]]; then violations="does not answer on 127.0.0.1:${SP_WEB_PORT}"; break; fi
      code=""
      [[ "$i" != 2 || "$SP_HTTP_CODE" != 200 ]] || code="GET ${urls[$i]} answered 200"
      [[ "$SP_HTTP_WERKZEUG" != 1 ]] || code="${code:+${code}, }the answer to GET ${urls[$i]} names Werkzeug"
      [[ "$SP_HTTP_TYPE" != *text/css* ]] || code="${code:+${code}, }GET ${urls[$i]} answered text/css"
      [[ -z "$code" ]] || violations="${violations}${violations:+; }${code}"
    done
    if [[ "$violations" == "does not answer"* ]]; then
      fl_sp_add share_debugger_off critical fail "The share web process ${violations}." "Stop sharing and start it again." restart_sharing
    elif [[ -n "$violations" ]]; then
      fl_sp_add share_debugger_off critical fail "The share web process serves the Werkzeug debugger (${violations})." "Stop sharing and start it again." restart_sharing
    else
      fl_sp_add share_debugger_off critical ok "no debugger on the share web process"
    fi
  fi
}

# ---------------------------------------------------------------- static checks

# fl_sp_stat_v VAR PATH: "UID GROUP MODE" (MODE: octal, four digits, the first the setuid/setgid/sticky bits).
# BSD %Lp alone drops those bits (/private/tmp is 777 there, 1777 with %Mp%Lp, as GNU %a prints it).
fl_sp_stat_v() {
  local __var="$1" __out __uid __group __mode
  if stat --version >/dev/null 2>&1; then __out="$(stat -c '%u %G %a' "$2")" || return 1; else __out="$(stat -f '%u %Sg %Mp%Lp' "$2")" || return 1; fi
  read -r __uid __group __mode <<<"$__out"
  while [[ "${#__mode}" -lt 4 ]]; do __mode="0${__mode}"; done
  printf -v "$__var" '%s %s %s' "$__uid" "$__group" "$__mode"
}

# fl_sp_path_problem_v VAR PATH IS_DIR: what makes PATH unsafe to run code from (empty: nothing).
# Owner: this user or root. World-writable: never, but a sticky directory (like /tmp) lets nobody replace an
# entry that is not theirs, so it is not held against what lies below it. Group-writable: only for the group
# that owns Homebrew's folders on every Mac (admin, whose members can sudo anyway).
fl_sp_path_problem_v() {
  local __var="$1" __info __uid __group __mode __me __admin="${FL_SHARE_ADMIN_GROUP:-admin}"
  printf -v "$__var" '%s' ""
  fl_sp_stat_v __info "$2" || { printf -v "$__var" 'cannot read %s' "$2"; return 0; }
  read -r __uid __group __mode <<<"$__info"
  __me="$(id -u)"
  if [[ "$__uid" != 0 && "$__uid" != "$__me" ]]; then printf -v "$__var" '%s is owned by another user (uid %s)' "$2" "$__uid"; return 0; fi
  if (( (${__mode:3:1} & 2) != 0 )); then
    if [[ "$3" == 1 ]] && (( (${__mode:0:1} & 1) != 0 )); then :; else printf -v "$__var" '%s is world-writable' "$2"; return 0; fi
  fi
  if (( (${__mode:2:1} & 2) != 0 )) && [[ "$__group" != "$__admin" ]]; then
    printf -v "$__var" '%s is group-writable by %s' "$2" "$__group"
  fi
}

# fl_sp_node_path_problem_v VAR: why the node the share would run on cannot be trusted, from its path alone
# (empty: it can). Nothing is run: a node another user could have replaced must not run even once.
# SP_NODE_REAL is its realpath, set only when the walk is clean.
fl_sp_node_path_problem_v() {
  local __var="$1" __node __real __p __why __is_dir=0
  printf -v "$__var" '%s' ""
  SP_NODE_REAL=""
  fl_sp_node_v __node
  if [[ "$__node" != /* ]]; then printf -v "$__var" 'node is not an absolute path (%s)' "$__node"; return 0; fi
  if [[ ! -x "$__node" ]]; then printf -v "$__var" 'there is no executable node at %s' "$__node"; return 0; fi
  fl_sp_realpath_v __real "$__node" || { printf -v "$__var" 'cannot resolve %s' "$__node"; return 0; }
  __p="$__real"
  while :; do
    fl_sp_path_problem_v __why "$__p" "$__is_dir"
    if [[ -n "$__why" ]]; then printf -v "$__var" '%s' "$__why"; return 0; fi
    [[ "$__p" != / ]] || break
    __p="$(dirname "$__p")"; __is_dir=1
  done
  SP_NODE_REAL="$__real"
}

# fl_sp_node_problem_v VAR: the path walk, then (only when it is clean) the version
fl_sp_node_problem_v() {
  local __problem __ver
  fl_sp_node_path_problem_v __problem
  if [[ -z "$__problem" ]]; then
    __ver="$("$SP_NODE_REAL" --version 2>/dev/null || true)"
    if [[ ! "$__ver" =~ ^v([0-9]+)\. || "${BASH_REMATCH[1]}" -lt "$FL_SHARE_MIN_NODE" ]]; then
      __problem="node ${__ver:-of unknown version} is older than ${FL_SHARE_MIN_NODE}"
    fi
  fi
  printf -v "$1" '%s' "$__problem"
}

fl_sp_firewall() {
  local state app out real="$SP_NODE_REAL"
  if [[ -z "$real" ]]; then fl_sp_add firewall_node static skip "needs a usable node"; return 0; fi
  local fw="${FL_SOCKETFILTERFW:-/usr/libexec/ApplicationFirewall/socketfilterfw}"
  local blocked="macOS is blocking incoming connections to node."
  local fix="Allow node through the firewall: benchbar lan-guard allow-node"
  [[ -x "$fw" ]] || { fl_sp_add firewall_node static fail "Cannot read the firewall state: ${fw} is missing." "$fix" allow_node_firewall; return 0; }
  state="$("$fw" --getglobalstate 2>&1 || true)"
  state="$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')"
  case "$state" in
    *"state = 0"*|*"is disabled"*) fl_sp_add firewall_node static ok "the firewall is off"; return 0 ;;
    # block all incoming connections: no per-app allow overrides it, and the CLI has nothing to offer
    *"state = 2"*) fl_sp_add firewall_node static fail "macOS is blocking all incoming connections." "" none; return 0 ;;
    *"state = 1"*|*"is enabled"*) ;;
    *) fl_sp_add firewall_node static fail "${blocked} (the firewall state is not readable)" "$fix" allow_node_firewall; return 0 ;;
  esac
  app="$("$fw" --getappblocked "$real" 2>&1 || true)"
  # the path itself could say "blocked" or "permitted": it is cut out before the answer is read
  out="$(printf '%s' "${app//"$real"/}" | tr '[:upper:]' '[:lower:]')"
  case "$out" in
    *"is permitted"*) fl_sp_add firewall_node static ok "the firewall allows ${real}" ;;
    *) fl_sp_add firewall_node static fail "$blocked" "$fix" allow_node_firewall ;;
  esac
}

# fl_sp_site_flag_on KEY: whether the copy's config (else the bench's common config) has KEY on
fl_sp_site_flag_on() {
  local v
  fl_site_file_value_v v "${FL_BENCH_DIR}/sites/${FL_SHARE_SITE}/site_config.json" "$1"
  [[ -n "$v" ]] || fl_site_config_value_v v "$1"
  [[ "$v" == 1 || "$v" == true ]]
}

# fl_sp_seats_load: SP_SEAT_USERS and SP_SEAT_NAMES from share.json's seats, one to a line
fl_sp_seats_load() {
  local line name re='"user":"([^"]*)","full_name":"(.*)","roles":'
  SP_SEAT_USERS=(); SP_SEAT_NAMES=()
  while IFS= read -r line; do
    [[ "$line" =~ $re ]] || continue
    name="${BASH_REMATCH[2]}"
    name="${name//\\\"/\"}"; name="${name//\\\\/\\}"
    fl__share_strip_v name "$name"
    SP_SEAT_USERS+=("${BASH_REMATCH[1]}"); SP_SEAT_NAMES+=("$name")
  done < <(grep -F '"seat_id"' "$(fl_share_dir)/share.json")
}

fl_sp_seat_name_v() {
  local i
  for ((i = 0; i < ${#SP_SEAT_USERS[@]}; i++)); do
    [[ "${SP_SEAT_USERS[$i]}" != "$2" ]] || { printf -v "$1" '%s' "${SP_SEAT_NAMES[$i]}"; return 0; }
  done
  printf -v "$1" '%s' "$2"
}

# fl_sp_copy_rows_v VAR: the helper's rows, or nothing when it did not finish
fl_sp_copy_rows_v() {
  local __rows=""
  fl_share_redis_up
  __rows="$(
    fl_bench_python_v __rows "$FL_PY_SHARE_CHECK" benchbar-share-check "$FL_SHARE_SITE" <<<"$(printf '%s\n' ${SP_SEAT_USERS[@]+"${SP_SEAT_USERS[@]}"})"
    printf '%s' "$__rows"
  )" || __rows=""
  fl_share_redis_down
  [[ "$__rows" == *$'\n'"done" || "$__rows" == "done" ]] || __rows=""
  printf -v "$1" '%s' "$__rows"
}

fl_sp_copy_checks() {
  local rows kind a b c signup="" admin="" keys=0 secrets=0 oauth=0 seat_problems="" name msg
  local fix="Run benchbar share setup --refresh."
  fl_sp_seats_load
  fl_sp_copy_rows_v rows
  if [[ -z "$rows" ]]; then
    for a in signup_disabled admin_password_not_default seats_valid no_api_keys; do
      fl_sp_add "$a" static fail "Could not read the copy: the check did not finish (the run log has the reason)." "$fix" rerun_setup
    done
    return 0
  fi
  while IFS=$'\x1f' read -r kind a b c; do
    case "$kind" in
      flag) case "$a" in signup_disabled) signup="$b" ;; admin_default) admin="$b" ;; esac ;;
      count) case "$a" in api_keys) keys="$b" ;; api_secrets) secrets="$b" ;; oauth_rows) oauth="$b" ;; esac ;;
      seat)
        fl_sp_seat_name_v name "$a"
        case "$b" in
          missing) msg="${name} is missing from the copy" ;;
          disabled) msg="${name} is disabled in the copy" ;;
          not_system_user) msg="${name} is not a System User in the copy" ;;
          role) msg="${name} holds the role ${c}, which can run code or change settings" ;;
          role_profile) msg="${name} still has a role profile, which hands roles back" ;;
          *) msg="${name} cannot take a seat (${b})" ;;
        esac
        seat_problems="${seat_problems}${seat_problems:+; }${msg}" ;;
    esac
  done <<<"$rows"
  if [[ "$signup" == 1 ]]; then fl_sp_add signup_disabled static ok "sign ups are off"
  else fl_sp_add signup_disabled static fail "Sign ups are open in the copy." "$fix" rerun_setup; fi
  if [[ "$admin" == 0 ]]; then fl_sp_add admin_password_not_default static ok "Administrator's password is not a well-known default"
  else fl_sp_add admin_password_not_default static fail "Administrator in the copy has a well-known default password." "$fix" rerun_setup; fi
  if [[ "${#SP_SEAT_USERS[@]}" -eq 0 ]]; then fl_sp_add seats_valid static fail "share.json lists no seats." "$fix" rerun_setup
  elif [[ -z "$seat_problems" ]]; then fl_sp_add seats_valid static ok "${#SP_SEAT_USERS[@]} seats, each an enabled System User with no role that can run code"
  else fl_sp_add seats_valid static fail "${seat_problems}." "$fix" rerun_setup; fi
  if [[ "$keys" == 0 && "$secrets" == 0 && "$oauth" == 0 ]]; then fl_sp_add no_api_keys static ok "no API keys, API secrets or OAuth tokens"
  else fl_sp_add no_api_keys static fail "The copy holds ${keys} API keys, ${secrets} API secrets and ${oauth} OAuth token rows." "$fix" rerun_setup; fi
}

# fl_sp_drift_v VAR: the apps whose git HEAD is not the one the copy was made at
fl_sp_drift_v() {
  local __var="$1" __recorded __rest __sha __now __list="" __re='"([A-Za-z0-9_-]+)":"([0-9a-f]{40,64})"'
  fl_share_cfg_raw_v __recorded apps_at_copy
  __rest="$__recorded"
  while [[ "$__rest" =~ $__re ]]; do
    __sha="${BASH_REMATCH[2]}"
    __now="$(git -C "${FL_BENCH_DIR}/apps/${BASH_REMATCH[1]}" rev-parse -q --verify HEAD 2>/dev/null || true)"
    [[ "$__now" == "$__sha" ]] || __list="${__list}${__list:+, }${BASH_REMATCH[1]}"
    __rest="${__rest#*"${BASH_REMATCH[0]}"}"
  done
  printf -v "$__var" '%s' "$__list"
}

fl_sp_static() {
  local problem version drifted app apps_json rest copy="${FL_BENCH_DIR}/sites/${FL_SHARE_SITE}/site_config.json" none_yet="needs the copy"
  fl_sp_node_problem_v problem
  if [[ -z "$problem" ]]; then fl_sp_add node_ok static ok "node ${SP_NODE_REAL}"
  else fl_sp_add node_ok static fail "Node cannot be trusted to run the gateway: ${problem}." "Install Node ${FL_SHARE_MIN_NODE} or later with Homebrew, and keep it writable only by you." none; fi
  fl_sp_firewall

  SP_COPY_READY=0
  fl_share_cfg_raw_v version v
  if [[ ! -f "$(fl_share_dir)/share.json" ]]; then
    fl_sp_add copy_ready static fail "There is no share.json: benchbar share setup has not finished." "Run benchbar share setup." rerun_setup
  elif [[ "$version" != 3 ]]; then
    fl_sp_add copy_ready static fail "share.json comes from an older benchbar share setup." "Run benchbar share setup --refresh." rerun_setup
  elif [[ ! -f "$copy" ]]; then
    fl_sp_add copy_ready static fail "The copy ${FL_SHARE_SITE} does not exist." "Run benchbar share setup --refresh." rerun_setup
  else
    SP_COPY_READY=1
    fl_sp_add copy_ready static ok "${FL_SHARE_SITE} and share.json are there"
  fi
  if [[ "$SP_COPY_READY" != 1 ]]; then
    for problem in developer_mode_off server_script_off signup_disabled admin_password_not_default seats_valid no_api_keys copy_drift; do
      fl_sp_add "$problem" static skip "$none_yet"
    done
  else
    if fl_sp_site_flag_on developer_mode; then
      fl_sp_add developer_mode_off static fail "developer_mode is on in ${FL_SHARE_SITE}." "Run benchbar share setup --refresh." rerun_setup
    else fl_sp_add developer_mode_off static ok "developer_mode is off"; fi
    if fl_sp_site_flag_on server_script_enabled; then
      fl_sp_add server_script_off static fail "server_script_enabled is on in ${FL_SHARE_SITE}." "Run benchbar share setup --refresh." rerun_setup
    else fl_sp_add server_script_off static ok "server scripts are off"; fi
    fl_sp_copy_checks
    fl_sp_drift_v drifted
    if [[ -z "$drifted" ]]; then fl_sp_add copy_drift static ok "the apps are at the commits the copy was made from"
    else
      fl_sp_add copy_drift static warn "Your code changed since the copy was made: refresh to avoid errors." "Run benchbar share setup --refresh." refresh_copy
      apps_json=""; rest="${drifted}, "
      while [[ -n "$rest" ]]; do app="${rest%%, *}"; rest="${rest#*, }"; apps_json="${apps_json}${apps_json:+,}$(fl_json_str "$app")"; done
      fl_sp_detail "\"apps\":[${apps_json}]" "(${drifted})"
    fi
  fi
  fl_sp_add cli_protocol static ok "protocol ${FL_SHARE_PROTOCOL}"
}

# ---------------------------------------------------------------- the command

fl_sp_doc() {
  local i sep="" checks="" ok=true
  for ((i = 0; i < ${#SP_ID[@]}; i++)); do
    [[ "${SP_STATUS[$i]}" != fail ]] || ok=false
    checks="${checks}${sep}{\"id\":$(fl_json_str "${SP_ID[$i]}"),\"class\":$(fl_json_str "${SP_CLASS[$i]}"),\"status\":$(fl_json_str "${SP_STATUS[$i]}"),\"message\":$(fl_json_str "${SP_MSG[$i]}"),\"fix\":$(fl_json_str "${SP_FIX[$i]}"),\"fix_action\":$(fl_json_str "${SP_ACT[$i]}")${SP_EXTRA[$i]:+,${SP_EXTRA[$i]}}}"
    sep=","
  done
  printf '{"schema_version":%d,"cli_version":"%s","protocol":%d,"ok":%s,"lan_ip":%s,"checks":[%s]}' \
    "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$FL_SHARE_PROTOCOL" "$ok" "$(fl_json_str "$SP_LAN_IP")" "$checks"
}

fl_sp_reset() { SP_ID=(); SP_CLASS=(); SP_STATUS=(); SP_MSG=(); SP_FIX=(); SP_ACT=(); SP_EXTRA=(); SP_NOTE=(); SP_LAN_IP=""; SP_WARNED=0; }

# fl_sp_print QUIET: the checks as text (QUIET 1: only those that are not ok); non zero when one failed.
# SP_WARNED=1 when one warned.
SP_WARNED=0
fl_sp_print() {
  local i line failed=0
  for ((i = 0; i < ${#SP_ID[@]}; i++)); do
    line="${SP_ID[$i]}: ${SP_MSG[$i]}${SP_NOTE[$i]:+ ${SP_NOTE[$i]}}"
    case "${SP_STATUS[$i]}" in
      ok) [[ "$1" == 1 ]] || fl_ok "$line" ;;
      skip) [[ "$1" == 1 ]] || fl_info "$line (skipped)" ;;
      warn) fl_warn "$line"; SP_WARNED=1 ;;
      fail) fl_fail "$line"; [[ -z "${SP_FIX[$i]}" ]] || fl_info "  fix: ${SP_FIX[$i]}"; failed=1 ;;
    esac
  done
  [[ "$failed" == 0 ]]
}

fl_cmd_share_preflight() {
  local run_static=0 run_critical=0 quiet=0 a failed=0
  for a in "$@"; do
    case "$a" in
      --static) run_static=1 ;;
      --critical) run_critical=1 ;;
      --quiet) quiet=1 ;;
      -*) fl_die "Unknown argument for share preflight: $a" "Use: benchbar share preflight [--static|--critical] [--quiet] [--json]" ;;
      *) fl_die "share preflight takes no argument: $a" "Use: benchbar share preflight [--static|--critical] [--quiet] [--json]" ;;
    esac
  done
  [[ "$run_static" == 1 || "$run_critical" == 1 ]] || { run_static=1; run_critical=1; }
  fl_site_json_begin
  fl_require_bench
  fl_sp_reset
  [[ "$run_static" == 0 ]] || fl_sp_static
  [[ "$run_critical" == 0 ]] || fl_sp_critical
  fl_sp_print "$quiet" || failed=1
  if [[ "${OPT_JSON:-0}" == 1 ]]; then
    FL_DONE_NO_STATE=1
    fl_doc_emit "$failed" "$(fl_sp_doc)"
  fi
  [[ "$failed" == 0 ]]
}
