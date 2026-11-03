#!/usr/bin/env bash
#
# lan-guard.sh: benchbar lan-guard install|status|remove|allow-node
#
# The LAN guard is a pf anchor (com.apple/250.benchbar, loaded by Apple's own
# pf.conf through its com.apple/* anchor) that refuses TCP from anything but
# loopback to every bench port: web 8000:8099, socket.io 9000:9099, Redis
# 11000:11099 and 13000:13099, MariaDB 3306. A LaunchDaemon loads it again at
# boot. share start refuses to run without it (share preflight, pf_active).
#
# Root never reads a file the user owns: the CLI renders the pf and plist text
# from templates/ in the user's process and puts both into the root script as
# single-quoted literals, with the destination paths and the tool paths; the
# script, run as root (sudo /bin/bash -c, or fl_root_run's dialog with
# BENCHBAR_SUDO=gui), writes them itself.
#
# install, remove and allow-node are a person's decision, like share setup
# (U3): refused under BENCHBAR_NONINTERACTIVE (so --for-agent and mcp), and
# without a terminal unless the app passes BENCHBAR_SUDO=gui after its own
# alert. status only reads and is never refused.
#
# Seams for the tests, nothing else sets them: FL_LANGUARD_ANCHOR and
# FL_LANGUARD_DAEMON (the two root files), FL_PFCTL, FL_LAUNCHCTL, FL_CHOWN and
# FL_SOCKETFILTERFW (the tools the root script runs).

FL_LANGUARD_LABEL=com.benchbar.pf
FL_LANGUARD_PF_ANCHOR_NAME=com.apple/250.benchbar
FL_LANGUARD_PORTS="8000:8099 9000:9099 11000:11099 13000:13099 3306"

fl_lg_anchor() { printf '%s' "${FL_LANGUARD_ANCHOR:-/etc/pf.anchors/com.benchbar.lan}"; }
fl_lg_daemon() { printf '%s' "${FL_LANGUARD_DAEMON:-/Library/LaunchDaemons/com.benchbar.pf.plist}"; }

# fl_lg_state_v VAR: installed, missing or outdated, by the rule share preflight and share status use
# (the anchor's non-comment lines, and a daemon that loads it)
fl_lg_state_v() {
  local __problem
  fl_sp_pf_files_problem_v __problem
  if [[ -z "$__problem" ]]; then printf -v "$1" installed
  elif [[ ! -r "$(fl_lg_anchor)" || ! -r "$(fl_lg_daemon)" ]]; then printf -v "$1" missing
  else printf -v "$1" outdated; fi
}

# fl_lg_active_v VAR: the pf_active probe of share preflight from this Mac's LAN address: true, false,
# or null when there is no LAN address to probe from
fl_lg_active_v() {
  local i
  fl_sp_lan_v
  if [[ -z "$SP_LAN_IP" ]]; then printf -v "$1" null; return 0; fi
  SP_ID=(); SP_STATUS=()
  fl_sp_probe_pf
  printf -v "$1" false
  for ((i = 0; i < ${#SP_ID[@]}; i++)); do
    [[ "${SP_ID[$i]}" == pf_active && "${SP_STATUS[$i]}" == ok ]] && printf -v "$1" true
  done
  return 0
}

# fl_lg_require_person COMMAND: U3, before anything is asked or changed
fl_lg_require_person() {
  [[ "${FL_DRY_RUN:-0}" != 1 ]] || return 0
  fl_noninteractive && fl_die "benchbar lan-guard $1 runs sudo, a person's decision, so nothing run without a terminal can do it." "Run it in a terminal: benchbar lan-guard $1"
  [[ -t 0 || "${BENCHBAR_SUDO:-}" == gui ]] || fl_die "benchbar lan-guard $1 needs a person at a terminal (it asks for your password), and this run has none." "Run it in a terminal: benchbar lan-guard $1"
}

# fl_lg_as_root REASON MANUAL SCRIPT: SCRIPT as root, once: one dialog with BENCHBAR_SUDO=gui, else sudo on
# this terminal, dropped (sudo -k) as soon as it is done. Stops the command, naming MANUAL, when root is refused.
fl_lg_as_root() {
  local reason="$1" manual="$2" script="$3" code=0 last
  if fl_sudo_gui; then
    fl_root_run "$reason" "$script" || code=$?
    case "$code" in
      0) return 0 ;;
      2) fl_die "The password dialog was cancelled; nothing was changed." "Run: ${manual}" ;;
    esac
    last="$(printf '%s\n' "$FL_ROOT_OUTPUT" | grep -v '^[[:space:]]*$' | tail -n 1 || true)"
    fl_die "The root step failed${last:+: ${last}}." "Run: ${manual}"
  fi
  fl_sudo_begin "$reason" || fl_die "sudo was not available, so nothing was changed." "Run in a terminal: ${manual}"
  sudo /bin/bash -c "$script" benchbar-root || code=$?
  fl_sudo_drop
  [[ "$code" == 0 ]] || fl_die "The root step failed (exit ${code}); see the log." "Run: ${manual}"
}

# fl_lg_tools_sh: the tool paths every root script names, as shell assignments
fl_lg_tools_sh() {
  printf 'pfctl=%s\nlaunchctl=%s\nchown=%s\nanchor=%s\ndaemon=%s\nlabel=%s\npf_anchor=%s\n' \
    "$(fl_sq "${FL_PFCTL:-/sbin/pfctl}")" "$(fl_sq "${FL_LAUNCHCTL:-/bin/launchctl}")" "$(fl_sq "${FL_CHOWN:-/usr/sbin/chown}")" \
    "$(fl_sq "$(fl_lg_anchor)")" "$(fl_sq "$(fl_lg_daemon)")" "$FL_LANGUARD_LABEL" "$FL_LANGUARD_PF_ANCHOR_NAME"
}

# fl_lg_install_script PF PLIST: the root side of install. Each file is written next to its place, made
# root:wheel 0644 and moved in; then pf loads the anchor (and is enabled) and launchd loads the daemon,
# which loads it again at every boot.
fl_lg_install_script() {
  printf 'set -eu\numask 022\n'
  fl_lg_tools_sh
  printf 'pf_text=%s\nplist_text=%s\n' "$(fl_sq "$1")" "$(fl_sq "$2")"
  cat <<'ROOT'
put() {
  new="$1.benchbar.new"
  /bin/rm -f "$new"
  printf '%s' "$2" >"$new"
  /bin/chmod 0644 "$new"
  "$chown" root:wheel "$new"
  /bin/mv -f "$new" "$1"
}
/bin/mkdir -p "${anchor%/*}"
put "$anchor" "$pf_text"
put "$daemon" "$plist_text"
"$pfctl" -E -a "$pf_anchor" -f "$anchor"
if "$launchctl" print "system/$label" >/dev/null 2>&1; then
  "$launchctl" kickstart -k "system/$label"
else
  "$launchctl" bootstrap system "$daemon"
fi
ROOT
}

fl_lg_remove_script() {
  printf 'set -eu\n'
  fl_lg_tools_sh
  cat <<'ROOT'
if "$launchctl" print "system/$label" >/dev/null 2>&1; then "$launchctl" bootout "system/$label" || true; fi
"$pfctl" -a "$pf_anchor" -F all || true
/bin/rm -f "$daemon" "$anchor"
ROOT
}

# fl_lg_allow_node_script REALPATH
fl_lg_allow_node_script() {
  printf 'set -eu\nfw=%s\nnode=%s\n' "$(fl_sq "${FL_SOCKETFILTERFW:-/usr/libexec/ApplicationFirewall/socketfilterfw}")" "$(fl_sq "$1")"
  cat <<'ROOT'
"$fw" --add "$node"
"$fw" --unblockapp "$node"
ROOT
}

fl_lg_doc_v() {
  local __state __active __ip=null
  fl_lg_state_v __state
  fl_lg_active_v __active
  [[ -z "$SP_LAN_IP" ]] || __ip="$(fl_json_str "$SP_LAN_IP")"
  printf -v "$1" '{"schema_version":%d,"cli_version":"%s","state":"%s","active":%s,"ports":"%s","anchor":"%s","lan_ip":%s}' \
    "$FL_SCHEMA_VERSION" "$FL_VERSION" "$__state" "$__active" "$FL_LANGUARD_PORTS" "$FL_LANGUARD_PF_ANCHOR_NAME" "$__ip"
  LG_STATE="$__state"; LG_ACTIVE="$__active"
}

fl_lg_report() {
  local doc
  fl_lg_doc_v doc
  case "$LG_ACTIVE" in
    true) fl_ok "the bench ports are refused on ${SP_LAN_IP}" ;;
    false) fl_warn "the bench ports are not refused on ${SP_LAN_IP}: see benchbar share preflight --critical" ;;
    *) fl_info "no LAN address, so the block could not be probed" ;;
  esac
  [[ "${OPT_JSON:-0}" != 1 ]] || fl_doc_emit 0 "$doc"
}

fl_cmd_lan_guard_status() {
  local a doc
  [[ "${OPT_JSON:-0}" != 1 ]] || fl_json_doc_begin
  for a in "$@"; do fl_die "Unknown argument for lan-guard status: $a" "Use: benchbar lan-guard status [--json]"; done
  fl_lg_doc_v doc
  if [[ "${OPT_JSON:-0}" == 1 ]]; then fl_doc_emit 0 "$doc"; return 0; fi
  fl_info "LAN guard: ${LG_STATE} (pf anchor ${FL_LANGUARD_PF_ANCHOR_NAME}: ${FL_LANGUARD_PORTS})"
  case "$LG_ACTIVE" in
    true) fl_ok "the bench ports are refused on ${SP_LAN_IP}" ;;
    false) fl_warn "the bench ports are not refused on ${SP_LAN_IP}" ;;
    *) fl_info "no LAN address, so the block was not probed" ;;
  esac
  [[ "$LG_STATE" == installed ]] || fl_fix "benchbar lan-guard install"
}

fl_cmd_lan_guard_install() {
  local a state pf plist
  for a in "$@"; do fl_die "Unknown argument for lan-guard install: $a" "Use: benchbar lan-guard install [--dry-run] [--yes] [--json]"; done
  fl_lg_require_person install
  fl_lg_state_v state
  if [[ "$state" == installed ]]; then
    fl_ok "unchanged: the guard is installed and matches"
    fl_lg_report
    return 0
  fi
  pf="$(fl_template_render lan-guard.pf)"
  plist="$(fl_template_render lan-guard.plist "ANCHOR=$(fl_lg_anchor)")"
  if [[ "${FL_DRY_RUN:-0}" == 1 ]]; then
    fl_info "dry-run: the guard is ${state}; with sudo, once, would:"
    fl_info "  write $(fl_lg_anchor) (root:wheel 0644): block TCP to ${FL_LANGUARD_PORTS} from anything but loopback"
    fl_info "  write $(fl_lg_daemon) (root:wheel 0644): load that anchor at every boot"
    fl_info "  run ${FL_PFCTL:-/sbin/pfctl} -E -a ${FL_LANGUARD_PF_ANCHOR_NAME} -f $(fl_lg_anchor), and load the daemon (launchctl)"
    return 0
  fi
  fl_confirm "Install the LAN guard with sudo (a pf anchor and a launch daemon)?" || fl_die "Not installed." "Run: benchbar lan-guard install"
  fl_lg_as_root "install the LAN guard: the pf anchor that keeps the bench ports off the LAN, and the daemon that loads it at boot" \
    "benchbar lan-guard install" "$(fl_lg_install_script "$pf" "$plist")"
  fl_lg_state_v state
  [[ "$state" == installed ]] || fl_die "The guard files are still ${state} after the root step." "See the log; run benchbar lan-guard install again."
  fl_changed lan-guard "$FL_LANGUARD_PF_ANCHOR_NAME" "installed"
  fl_ok "LAN guard installed: $(fl_lg_anchor) and $(fl_lg_daemon)"
  fl_lg_report
}

fl_cmd_lan_guard_remove() {
  local a state
  for a in "$@"; do fl_die "Unknown argument for lan-guard remove: $a" "Use: benchbar lan-guard remove [--yes] [--json]"; done
  [[ "${FL_DRY_RUN:-0}" != 1 ]] || fl_die "lan-guard remove has no dry run." "benchbar lan-guard status shows the guard."
  fl_lg_require_person remove
  if [[ ! -e "$(fl_lg_anchor)" && ! -e "$(fl_lg_daemon)" ]]; then
    fl_ok "unchanged: the guard is not installed"
    fl_lg_report
    return 0
  fi
  fl_warn "Without the guard the bench ports answer the LAN, and benchbar share start refuses to run."
  fl_confirm "Remove the LAN guard with sudo?" || fl_die "Not removed." "Run: benchbar lan-guard remove"
  fl_lg_as_root "remove the LAN guard: its pf anchor and its launch daemon" "benchbar lan-guard remove" "$(fl_lg_remove_script)"
  fl_lg_state_v state
  [[ "$state" == missing ]] || fl_die "The guard files are still there after the root step." "See the log; run benchbar lan-guard remove again."
  fl_changed lan-guard "$FL_LANGUARD_PF_ANCHOR_NAME" "removed"
  fl_ok "LAN guard removed"
  fl_lg_report
}

# allow-node: the firewall lets incoming connections reach the node the gateway runs on. A Homebrew upgrade
# changes that realpath, so share preflight's firewall_node check asks for this again.
fl_cmd_lan_guard_allow_node() {
  local a problem fw state app real doc
  for a in "$@"; do fl_die "Unknown argument for lan-guard allow-node: $a" "Use: benchbar lan-guard allow-node [--yes] [--json]"; done
  [[ "${FL_DRY_RUN:-0}" != 1 ]] || fl_die "lan-guard allow-node has no dry run." "benchbar share preflight --static shows the firewall_node check."
  fl_lg_require_person allow-node
  fl_sp_node_path_problem_v problem
  [[ -z "$problem" ]] || fl_die "Node cannot be trusted to run the gateway: ${problem}." "Install Node ${FL_SHARE_MIN_NODE} or later with Homebrew, and keep it writable only by you."
  real="$SP_NODE_REAL"
  fw="${FL_SOCKETFILTERFW:-/usr/libexec/ApplicationFirewall/socketfilterfw}"
  [[ -x "$fw" ]] || fl_die "Cannot read the firewall state: ${fw} is missing." ""
  state="$("$fw" --getglobalstate 2>&1 | tr '[:upper:]' '[:lower:]' || true)"
  case "$state" in
    *"state = 0"*|*"is disabled"*) fl_ok "unchanged: the firewall is off" ;;
    *"state = 2"*) fl_die "macOS is blocking all incoming connections; no app can be allowed while it does." "Turn off \"Block all incoming connections\" in System Settings > Network > Firewall > Options." ;;
    *)
      app="$("$fw" --getappblocked "$real" 2>&1 || true)"
      app="$(printf '%s' "${app//"$real"/}" | tr '[:upper:]' '[:lower:]')"
      if [[ "$app" == *"is permitted"* ]]; then
        fl_ok "unchanged: the firewall allows ${real}"
      else
        fl_confirm "Allow ${real} through the firewall with sudo?" || fl_die "Not allowed." "Run: benchbar lan-guard allow-node"
        fl_lg_as_root "allow node (${real}) through the macOS firewall, for the share gateway" "benchbar lan-guard allow-node" "$(fl_lg_allow_node_script "$real")"
        fl_changed firewall "$real" "allowed"
        fl_ok "the firewall allows ${real}"
      fi ;;
  esac
  doc="$(printf '{"schema_version":%d,"cli_version":"%s","node":%s}' "$FL_SCHEMA_VERSION" "$FL_VERSION" "$(fl_json_str "$real")")"
  [[ "${OPT_JSON:-0}" != 1 ]] || fl_doc_emit 0 "$doc"
}

fl_cmd_lan_guard() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    install) fl_cmd_lan_guard_install "$@" ;;
    status) fl_cmd_lan_guard_status "$@" ;;
    remove) fl_cmd_lan_guard_remove "$@" ;;
    allow-node) fl_cmd_lan_guard_allow_node "$@" ;;
    *) fl_die "Usage: benchbar lan-guard install|status|remove|allow-node ..." "Example: benchbar lan-guard status" ;;
  esac
}
