#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# share-guest.sh: the guest side of a room, from a terminal (macOS, Linux, WSL).
#
#   benchbar share join [ADDRESS[:PORT]] [--host-key HEX] [--name NAME] [--seat SEAT_ID] [--no-wait] [--no-open] [--dry-run] [--yes] [--json]
#   benchbar share joined [--json]
#   benchbar share leave [ROOM] [--json]
#   benchbar share forget [ROOM] [--json]
#
# The work is done by lib/frappe-local/share/guest-cli.js with the gateway's own cpace.js, so the exchange
# is the Mac app's, byte for byte. This file asks, refuses and prints.
#
# The room code and an invite link (it carries the code) are never arguments: join asks for them on the
# terminal, or reads one line of stdin when the app or the tray started the run, and hands them to node on
# its stdin. They are printed nowhere, no run log is opened for join (the dispatcher's list), and this
# computer's key for a host never passes through the shell at all: node reads and writes it in the
# Keychain (macOS, with the command on "security -i"'s stdin) or a 0600 file of the guest folder (Linux).
#
# join, leave and forget are a person's: never under BENCHBAR_NONINTERACTIVE (so never --for-agent or
# mcp), and with a terminal on stdin unless the app passes BENCHBAR_SUDO=gui. joined only reads; for an
# agent it leaves out the local address of a room, which signs a browser in as the seat.
#
# The guest folder is <state>/share-guest (0700), apart from <state>/share: share teardown deletes that
# one, and doctor reads its existence as "this computer shared a site".

FL_SHARE_GUEST_WAIT_S=600

fl_share_guest_dir() { printf '%s/share-guest' "$FL_STATE_DIR"; }

# fl_share_guest_sub NAME: 0 for the subcommands of a guest, which need no bench
fl_share_guest_sub() {
  case "${1:-}" in join|joined|leave|forget) return 0 ;; esac
  return 1
}

# fl_sg_node WHAT: the node the gateway would run on (vetted the same way), or the command stops
fl_sg_node() {
  local problem
  fl_sp_node_problem_v problem
  [[ -z "$problem" ]] || fl_die "$1 runs on Node ${FL_SHARE_MIN_NODE} or later, and the one here cannot be used: ${problem}." \
    "Install it (benchbar install does, with the other dependencies), then run the command again."
}

# fl_sg_req_v VAR [MEMBERS]: the request of one guest-cli.js run: where the rooms and the keys rest, then MEMBERS
fl_sg_req_v() {
  local __store=file __sec=/usr/bin/security __more=""
  if ! fl_is_linux; then
    __store=keychain
    __sec="$(command -v security 2>/dev/null || printf /usr/bin/security)"
  fi
  # the tests' gateway listens on loopback, which is no address of a room
  [[ "${FL_TESTING:-}" != "1" || "${FL_SHARE_GUEST_LOOPBACK:-}" != "1" ]] || __more=',"allow_loopback":true'
  ! fl_noninteractive || __more="${__more},\"hide_url\":true"
  printf -v "$1" '{"dir":%s,"keystore":"%s","security":%s%s%s}' "$(fl_json_str "$(fl_share_guest_dir)")" "$__store" "$(fl_json_str "$__sec")" "$__more" "${2:+,$2}"
}

# fl_sg_call_v VAR OP REQUEST: one run of guest-cli.js; REQUEST goes to its stdin from a builtin, so the
# code in it is in no argument list and no temporary file. VAR gets the KEY=VALUE lines of the answer.
fl_sg_call_v() {
  local __out="" __code=0
  __out="$(printf '%s' "$3" | "$SP_NODE_REAL" "${FL_SELF_DIR}/lib/frappe-local/share/guest-cli.js" "$2" 2>/dev/null 3>&-)" || __code=$?
  printf -v "$1" '%s' "$__out"
  return "$__code"
}

# fl_sg_read_v VAR PROMPT [secret]: one line from the person: typed at the terminal (a secret, the room code
# or an invite link, is not shown, so it is not in the scrollback), or the first line of stdin when the app
# or the tray made the run
fl_sg_read_v() {
  local __line=""
  if [[ -t 0 && "${3:-}" == secret ]]; then
    fl_spinner_pause
    IFS= read -r -s -p "  $2 (not shown): " __line || true
    printf '\n'
  elif [[ -t 0 ]]; then
    fl_spinner_pause
    IFS= read -r -p "  $2: " __line || true
  else
    IFS= read -r __line || true
  fi
  # a line from Windows (the tray through wsl.exe) ends in CR LF: the CR is no part of the answer
  __line="${__line%$'\r'}"
  printf -v "$1" '%s' "$__line"
}

fl_sg_key_v() { printf -v "$1" '%s %s %s %s' "${2:0:4}" "${2:4:4}" "${2:8:4}" "${2:12:4}"; }

fl_sg_doc() { printf '{"schema_version":%d,"cli_version":"%s",%s}' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$1"; }

# fl_sg_refuse REPLY HOST WHERE: the sentence for the word guest-cli.js refused with, and the end of the command
fl_sg_refuse() {
  local err retry room host="${2:-the host}" where="${3:-the address of the room}" msg fix="Run the command again." mode="" rc=1
  fl_share_reply_v err "$1" error
  fl_share_reply_v retry "$1" retry_after
  fl_share_reply_v room "$1" room
  case "$err" in
    invalid_code) msg="The room code is 6 digits."; fix="Ask ${host} for it: benchbar share code shows it there." ;;
    wrong_code) msg="That code didn't work."; fix="Check it with ${host} and run the command again. Ten wrong codes lock the room." ;;
    locked) msg="${host} locked this room."; fix="Ask ${host} to unlock it (benchbar share unlock), then run the command again." ;;
    full) msg="This room is full."; fix="It opens again when someone leaves or is removed." ;;
    already_joined) msg="This computer is already in ${host}'s room."; fix="benchbar share joined shows it." ;;
    blocked|removed) msg="${host} removed this computer from the room."; fix="Ask ${host} for a new invite to join again." ;;
    ended) msg="${host} ended the room."; fix="A new room has a new code: ask ${host} for it." ;;
    expired) msg="That took too long." ;;
    rate_limited) msg="Too many tries."; fix="Wait ${retry:-60} seconds, then run the command again." ;;
    needs_update) msg="This room speaks another version of the room protocol."; fix="Update BenchBar on both computers (benchbar self-update)." ;;
    code_did_not_check_out)
      msg="This room's code didn't check out: the computer that answered does not know the code. Nothing was saved."
      fix="Ask ${host} for the code again, and compare the host key with the one benchbar share status shows there." ;;
    identity_changed)
      msg="The computer at ${where} shows another key than the one this computer joined there. BenchBar did not connect, and keeps the key it knows."
      fix="If the host reset BenchBar, forget the room (benchbar share forget ${room}) and join again with a new code." ;;
    unreachable)
      msg="The room at ${where} didn't answer."
      fix="Check that both computers are on the same Wi-Fi and that the host is still sharing (benchbar share status there)."
      fl_sp_wsl_net_v mode
      [[ "$mode" != nat ]] || fix="${fix} WSL uses NAT networking here and reaches the Wi-Fi through Windows: a VPN or the firewall of Windows can be in the way, so check that Windows itself reaches ${where}." ;;
    not_local)
      msg="${where} is not an address of a local network, and a room is on the network this computer is on."
      fix="Use the address in the host's invite or in its benchbar share status (10.x, 172.16 to 172.31, 192.168.x, 169.254.x or 100.64 to 100.127)." ;;
    bad_address) msg="That is not the IPv4 address of a room."; fix="Example: benchbar share join 192.168.1.20" ;;
    invite_not_found) msg="That holds no invite: an invite is a benchbar://share/join link."; fix="Paste the whole link, or join with the address and the code: benchbar share join ADDRESS" ;;
    invite_malformed) msg="The invite link is damaged."; fix="Ask ${host} for it again and paste the whole link." ;;
    invite_newer) msg="This invite is from a newer BenchBar."; fix="Update BenchBar (benchbar self-update), then join again." ;;
    invite_no_address)
      msg="This invite names no address this computer may dial: none, or one that is not of a local network."
      fix="Ask ${host} for the room's address and code, then: benchbar share join ADDRESS" ;;
    invite_expired) msg="This invite has expired and its room no longer answers."; fix="Ask ${host} for a new one." ;;
    not_the_invited_room) msg="This isn't the room in the invite: the computer that answered shows another key. BenchBar did not connect."; fix="Ask ${host} for a new invite." ;;
    invite_out_of_date) msg="This invite is out of date: the host changed the code."; fix="Ask ${host} for a new one." ;;
    host_key_mismatch)
      msg="The computer at ${where} shows another host key than the one you asked for (--host-key). BenchBar did not connect and sent nothing."
      fix="Check the key with ${host} (benchbar share status shows it there). To look at the room again: benchbar share join ${where} --dry-run"
      rc=3 ;;
    rooms_file)
      msg="The list of joined rooms ($(fl_share_guest_dir)/rooms.json) cannot be read. BenchBar did not change it."
      fix="Move the file aside to start a new list (the keys in $(fl_share_guest_dir)/keys stay), then join your rooms again." ;;
    key_store)
      if fl_is_linux; then msg="This computer's key for the room could not be read or written in $(fl_share_guest_dir)/keys."; fix="Check that the folder is yours and writable, then run the command again."
      else msg="The Keychain did not give or take this computer's key for the room."; fix="Unlock the login Keychain (security unlock-keychain), then run the command again."; fi ;;
    no_such_room) msg="This computer joined no room with that id."; fix="benchbar share joined lists the rooms and their ids." ;;
    which_room) msg="This computer joined more than one room."; fix="Name one by its id: benchbar share joined lists them." ;;
    no_rooms) msg="This computer joined no room."; fix="Join one: benchbar share join" ;;
    busy) msg="Another benchbar share command is at work on the rooms of this computer."; fix="Wait for it to end, then run the command again." ;;
    forwarder|no_port) msg="The room's local address did not start: no port from 41000 to 41999 could be opened on this computer." ;;
    seat_taken) msg="That seat was just taken."; fix="Run the command again and pick another." ;;
    host_assigns) msg="${host} gives out the seats in this room: a guest cannot take one."; fix="Ask ${host} for yours, then run benchbar share join ${where} again." ;;
    no_such_seat|refused) msg="That seat isn't available."; fix="Run the command again without --seat to see the free ones." ;;
    *) msg="That didn't work: the room gave an answer BenchBar does not know." ;;
  esac
  fl_die "$msg" "$fix" "$rc"
}

# fl_sg_app_present: 0 on a Mac where BenchBar.app is installed (it is a guest of its own)
fl_sg_app_present() {
  local dirs="${FL_APP_DIRS:-/Applications:$HOME/Applications}" dir
  ! fl_is_linux || return 1
  while [[ -n "$dirs" ]]; do
    dir="${dirs%%:*}"
    if [[ "$dirs" == *:* ]]; then dirs="${dirs#*:}"; else dirs=""; fi
    [[ ! -d "${dir}/BenchBar.app" ]] || return 0
  done
  return 1
}

# fl_sg_state_line STATE HOST SEAT: what `joined` and the end of `join` say of a room
fl_sg_state_line() {
  case "$1" in
    ready) printf 'open, seat %s' "${3:-given}" ;;
    waiting) printf 'no seat yet: %s has not given this computer one' "$2" ;;
    removed) printf '%s removed this computer' "$2" ;;
    new_room) printf '%s started a new room: join it with its code' "$2" ;;
    ended) printf '%s ended the room' "$2" ;;
    identity_changed) printf "the host's key changed: not connected" ;;
    offline|unknown) printf "%s isn't sharing right now" "$2" ;;
    *) printf 'closed' ;;
  esac
}

# ---------------------------------------------------------------- share join

fl_cmd_share_join() {
  local usage="Use: benchbar share join [ADDRESS[:PORT]] [--host-key HEX] [--name NAME] [--seat SEAT_ID] [--no-wait] [--no-open] [--dry-run] [--yes] [--json]"
  local hostkey="" have_hostkey=0 target="" name="" seat="" wait=1 open=1 invite="" code="" addr="" port="$FL_SHARE_GATEWAY_PORT" where req="" reply body model mode
  local id pin key shown room host paired locked full state url who doc extra="" seats assigns line n pick sid sname staken ids=() joined=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) [[ $# -ge 2 ]] || fl_die "--name needs the name the host sees for this computer." "$usage"; name="$2"; shift ;;
      --name=*) name="${1#*=}" ;;
      --seat) [[ $# -ge 2 ]] || fl_die "--seat needs a seat id." "$usage"; seat="$2"; shift ;;
      --seat=*) seat="${1#*=}" ;;
      --host-key) [[ $# -ge 2 ]] || fl_die "--host-key needs the 64 hex digits of the host's key." "$usage"; hostkey="$2"; have_hostkey=1; shift ;;
      --host-key=*) hostkey="${1#*=}"; have_hostkey=1 ;;
      --no-wait) wait=0 ;;
      --no-open) open=0 ;;
      -*) fl_die "Unknown argument for share join: $1" "$usage" ;;
      *) [[ -z "$target" ]] || fl_die "share join takes one address." "$usage"; target="$1" ;;
    esac
    shift
  done
  if [[ -n "$target" ]]; then
    # never echoed: the word may be the code
    if [[ "${target//[ -]/}" =~ ^[0-9]{6}$ || "$target" == *://* || "$target" == *[\?\&=]* ]]; then
      fl_die "The room code and an invite link are typed or pasted when benchbar asks, never passed as an argument: an argument stays in the shell's history and shows in the list of processes." \
        "For an invite: benchbar share join. For a code: benchbar share join ADDRESS. If the code was in a command you ran, ask the host for a new one (benchbar share code --new)."
    fi
    [[ "$target" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(:[0-9]{1,5})?$ ]] || fl_die "A room is joined at the IPv4 address of its host, with :PORT when the port is not ${FL_SHARE_GATEWAY_PORT}." \
      "The address is in the host's invite and in its benchbar share status. Example: benchbar share join 192.168.1.20"
    addr="${target%%:*}"
    [[ "$target" != *:* ]] || port="$((10#${target##*:}))"
  fi
  if [[ "$have_hostkey" == 1 ]]; then
    # public, so an argument is fine: the full hash that a look (--dry-run --json: host_pin) showed
    hostkey="$(printf '%s' "$hostkey" | tr 'A-F' 'a-f')"
    [[ "$hostkey" =~ ^[0-9a-f]{64}$ ]] || fl_die "--host-key takes the 64 hex digits of the host's key: host_pin in benchbar share join --dry-run --json." "$usage"
  fi
  [[ -z "$seat" || "$seat" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || fl_die "That is not a seat id." "benchbar share join lists the free seats of a room where guests pick."
  fl_share_require_person "Joining a room" "benchbar share join"
  fl_site_json_begin
  FL_DONE_NO_STATE=1; FL_DONE_NO_BENCH=1
  fl_sg_node "Joining a room"

  if [[ -z "$target" ]]; then
    fl_sg_read_v invite "Paste the invite link" secret
    [[ -n "$invite" ]] || fl_die "No invite was given." "Paste the benchbar://share/join link, or join with the address and the code: benchbar share join ADDRESS"
    fl_sg_req_v req "\"invite\":$(fl_json_str "$invite")${hostkey:+,\"expect_pin\":\"${hostkey}\"}"
  else
    fl_sg_req_v req "\"address\":\"${addr}\",\"port\":${port}${hostkey:+,\"expect_pin\":\"${hostkey}\"}"
  fi
  fl_sg_call_v reply look "$req" || fl_sg_refuse "$reply" "the host" "${target:-the address in the invite}"
  for line in id pin:host_pin key:host_key room host addr:address port paired locked full doc; do
    fl_share_reply_v "${line%%:*}" "$reply" "${line##*:}"
  done
  where="${addr}:${port}"
  fl_sg_key_v shown "$key"
  # what a person checks before the code is sent: the name is the host's own words, the key is not
  printf '  Room      %s (host: %s)\n  Address   %s%s\n  Host key  %s\n' "$room" "$host" "$where" "$([[ -z "$invite" ]] || printf ' (from the invite link, not found on the network)')" "$shown"
  printf '  If you are not sure this is the right computer, ask %s to read out the host key: benchbar share status shows it there.\n' "$host"
  if fl_sg_app_present; then
    fl_note "BenchBar.app is installed here. A room joined in the app and one joined here are two guests to ${host}: the host counts this person twice, and each takes a seat."
  fi
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_note "dry-run: nothing was sent that depends on the room code, and nothing was saved."
    [[ "${OPT_JSON:-0}" != 1 ]] || fl_doc_emit 0 "$(fl_sg_doc "$doc")" plan
    return 0
  fi

  if [[ "$paired" == true ]]; then
    fl_info "This computer is already in the room: no code is needed."
    fl_sg_req_v req "\"id\":\"${id}\""
    fl_sg_call_v reply open "$req" || fl_sg_refuse "$reply" "$host" "$where"
  else
    [[ "$locked" != true ]] || fl_sg_refuse "error=locked" "$host" "$where"
    [[ "$full" != true ]] || fl_sg_refuse "error=full" "$host" "$where"
    [[ -n "$name" ]] || name="$(fl_share_computer_name)"
    if fl_is_linux; then model="Linux"; ! fl_is_wsl || model="Windows (WSL)"; else model="$(sysctl -n hw.model 2>/dev/null || true)"; fi
    if [[ -n "$invite" ]]; then
      # at a terminal the person has now seen where the link leads; the app and the tray ask in their own window
      if [[ -t 0 ]]; then fl_confirm "Join this room?" || fl_die "Not joined: nothing was sent that depends on the room code." "Run benchbar share join again to join."; fi
      body="\"invite\":$(fl_json_str "$invite")"
    else
      fl_sg_read_v code "Room code" secret
      code="${code// /}"
      [[ "$code" =~ ^[0-9]{6}$ ]] || fl_sg_refuse "error=invalid_code" "$host" "$where"
      body="\"code\":\"${code}\""
    fi
    fl_sg_req_v req "${body},\"address\":\"${addr}\",\"port\":${port},\"host_pin\":\"${pin}\",\"name\":$(fl_json_str "$name"),\"model\":$(fl_json_str "${model:-computer}")"
    code=""; invite=""; body=""
    fl_sg_call_v reply join "$req" || { req=""; fl_sg_refuse "$reply" "$host" "$where"; }
    req=""; joined=true
    fl_changed share "$room" "joined"
    fl_ok "Joined ${room} (host: ${host})."
  fi

  fl_share_reply_v state "$reply" state
  if [[ -n "$seat" ]]; then
    fl_sg_req_v req "\"id\":\"${id}\",\"seat_id\":\"${seat}\""
    fl_sg_call_v reply seat "$req" || fl_sg_refuse "$reply" "$host" "$where"
  elif [[ "$state" == waiting ]]; then
    fl_sg_req_v req "\"id\":\"${id}\""
    fl_sg_call_v seats seats "$req" || fl_sg_refuse "$seats" "$host" "$where"
    fl_share_reply_v assigns "$seats" host_assigns
    fl_share_reply_v extra "$seats" doc
    if [[ "$assigns" == true ]]; then
      if [[ "$wait" == 1 ]]; then
        fl_info "${host} gives out the seats in this room. Waiting for yours, up to $((FL_SHARE_GUEST_WAIT_S / 60)) minutes. Ctrl-C ends the wait, not your place in the room."
        fl_sg_req_v req "\"id\":\"${id}\",\"timeout_s\":${FL_SHARE_GUEST_WAIT_S}"
        fl_sg_call_v reply wait "$req" || fl_sg_refuse "$reply" "$host" "$where"
      fi
    elif [[ -t 0 && "${OPT_JSON:-0}" != 1 ]]; then
      n=0
      while IFS=$'\x1f' read -r sid sname staken; do
        [[ "$sid" == row=* && -z "$staken" ]] || continue
        n=$((n + 1)); ids+=("${sid#row=}")
        printf '  %2d. %s\n' "$n" "$sname"
      done <<<"$seats"
      [[ "$n" -gt 0 ]] || fl_die "Every seat of this room is taken." "Ask ${host} to free one, then run benchbar share join ${where} again."
      fl_sg_read_v pick "Your seat (a number)"
      [[ "$pick" =~ ^[0-9]{1,3}$ && "$pick" -ge 1 && "$pick" -le "$n" ]] || fl_die "No seat was picked: your place in the room stays for 2 minutes." "Run benchbar share join ${where} again and type a number of the list."
      fl_sg_req_v req "\"id\":\"${id}\",\"seat_id\":\"${ids[$((pick - 1))]}\""
      fl_sg_call_v reply seat "$req" || fl_sg_refuse "$reply" "$host" "$where"
    fi
  fi

  for line in state url who:seat doc; do fl_share_reply_v "${line%%:*}" "$reply" "${line##*:}"; done
  if [[ "$state" == ready ]]; then
    extra=""
    fl_ok "Seat: ${who}. The room is open on this computer only:"
    printf '  %s\n' "$url"
    fl_note "The address closes after 15 minutes without a page request. benchbar share join ${where} opens it again, with no code."
    fl_sp_wsl_net_v mode
    [[ "$mode" != nat ]] || fl_note "WSL NAT: a browser in Windows reaches this address through WSL's localhost forwarding, which is on unless .wslconfig says localhostForwarding=false."
    if [[ "$open" == 1 && "${OPT_JSON:-0}" != 1 ]]; then fl_open_url "$url" >/dev/null 2>&1 || fl_note "No browser could be opened from here: open the address above yourself."; fi
  elif [[ "$state" == waiting ]]; then
    fl_warn "No seat yet: your place in the room stays for a few minutes (2 where guests pick, 10 where the host gives them out)."
    fl_note "Once you have a seat, open the room: benchbar share join ${where}"
  else
    fl_warn "The room did not open: $(fl_sg_state_line "$state" "$host" "")."
  fi
  [[ "${OPT_JSON:-0}" != 1 ]] || fl_doc_emit 0 "$(fl_sg_doc "\"joined\":${joined},${doc}${extra:+,$extra}")"
}

# ---------------------------------------------------------------- share joined

fl_cmd_share_joined() {
  local a req reply doc id room host state seat url where n=0
  for a in "$@"; do fl_die "Unknown argument for share joined: $a" "Use: benchbar share joined [--json]"; done
  fl_site_json_begin
  FL_DONE_NO_STATE=1; FL_DONE_NO_BENCH=1
  # a computer that joined no room starts no node to say so
  if [[ ! -f "$(fl_share_guest_dir)/rooms.json" ]]; then
    if [[ "${OPT_JSON:-0}" == 1 ]]; then fl_doc_emit 0 "$(fl_sg_doc '"rooms":[]')"; else fl_info "This computer joined no room."; fi
    return 0
  fi
  fl_sg_node "Listing the joined rooms"
  fl_sg_req_v req
  fl_sg_call_v reply joined "$req" || fl_sg_refuse "$reply"
  if [[ "${OPT_JSON:-0}" == 1 ]]; then
    fl_share_reply_v doc "$reply" doc
    fl_doc_emit 0 "$(fl_sg_doc "$doc")"
    return 0
  fi
  while IFS=$'\x1f' read -r id room host state seat url where; do
    [[ "$id" == row=* ]] || continue
    n=$((n + 1))
    printf '  %s  %s (host: %s) at %s\n      %s\n' "${id#row=}" "$room" "$host" "$where" "$(fl_sg_state_line "$state" "$host" "$seat")"
    if [[ -n "$url" ]]; then printf '      %s\n' "$url"
    elif [[ "$state" == closed ]]; then printf '      open it: benchbar share join %s\n' "$where"; fi
  done <<<"$reply"
  [[ "$n" -gt 0 ]] || fl_info "This computer joined no room."
}

# ---------------------------------------------------------------- share leave, share forget

fl_cmd_share_leave() {
  local action="$1" a id="" req reply told room host doc stopped
  shift
  for a in "$@"; do
    case "$a" in
      -*) fl_die "Unknown argument for share ${action}: $a" "Use: benchbar share ${action} [ROOM] [--json]" ;;
      *) id="${id}${a// /}" ;;
    esac
  done
  [[ -z "$id" || "$id" =~ ^[0-9a-f]{16}$ ]] || fl_die "A room is named by the 16 digits of its host key." "benchbar share joined lists the rooms and their ids."
  fl_share_require_person "Leaving a room" "benchbar share ${action}${id:+ $id}"
  fl_share_refuse_dry_run "$action"
  fl_site_json_begin
  FL_DONE_NO_STATE=1; FL_DONE_NO_BENCH=1
  fl_sg_node "Leaving a room"
  fl_sg_req_v req "\"id\":\"${id}\""
  fl_sg_call_v reply "$action" "$req" || fl_sg_refuse "$reply"
  for a in told:told_host stopped:forwarder_stopped room host doc; do fl_share_reply_v "${a%%:*}" "$reply" "${a##*:}"; done
  if [[ "$told" == true ]]; then fl_ok "Left ${room}: ${host} was told, so the seat is free and its sessions are ended there."
  else fl_warn "${host} could not be told: the room does not answer, or this computer was no longer in it."; fi
  if [[ "$stopped" == false ]]; then
    fl_warn "The local address of ${room} is still open: its process (guest-forward.js) did not end. Stop it yourself, then run benchbar share joined to check."
  else
    fl_note "The local address of ${room} is closed."
  fi
  if [[ "$action" == forget ]]; then
    fl_changed share "$room" "forgotten"
    fl_ok "Forgot ${room}: this computer's key for ${host} is deleted. To ${host}, a later join is a new computer."
  else
    fl_changed share "$room" "left"
    fl_note "The room stays in benchbar share joined, with this computer's key for ${host}: a later join needs the code and shows ${host} the same key."
  fi
  [[ "${OPT_JSON:-0}" != 1 ]] || fl_doc_emit 0 "$(fl_sg_doc "$doc")"
}

# fl_share_guest_close: every forwarder of a joined room stops (the lan-rooms Lab went off). No host is
# told and nothing is deleted; it never fails the caller.
fl_share_guest_close() {
  local problem req reply
  [[ -f "$(fl_share_guest_dir)/rooms.json" ]] || return 0
  fl_sp_node_path_problem_v problem
  [[ -z "$problem" ]] || return 0
  fl_sg_req_v req
  fl_sg_call_v reply close "$req" || true
}
