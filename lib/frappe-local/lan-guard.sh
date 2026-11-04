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
# Root never reads a file the user owns, and nothing from the environment chooses what root runs or
# writes: the root script names the system tools and the two root files by their absolute paths, and the
# pf and plist text are constants of this CLI (share-preflight.sh), put into the script as single-quoted
# literals. The script, run as root (sudo /bin/bash -c, or fl_root_run's dialog with BENCHBAR_SUDO=gui),
# writes them itself. The tests' sudo and osascript mocks map those absolute paths to mocks.
#
# install, remove and allow-node are a person's decision, like share setup
# (U3): refused under BENCHBAR_NONINTERACTIVE (so --for-agent and mcp), and
# without a terminal unless the app passes BENCHBAR_SUDO=gui after its own
# alert. status only reads and is never refused.
#
# Seams for the tests, nothing else sets them, and they only choose what this user's process reads:
# FL_LANGUARD_ANCHOR and FL_LANGUARD_DAEMON (where the checks read the two root files) and
# FL_SOCKETFILTERFW (the firewall state allow-node reads).

FL_LANGUARD_LABEL=com.benchbar.pf
FL_LANGUARD_PF_ANCHOR_NAME=com.apple/250.benchbar
FL_LANGUARD_PORTS="8000:8099 9000:9099 11000:11099 13000:13099 3306"

FL_LANGUARD_PF_TEXT="# BenchBar: Frappe bench ports answer this Mac only (benchbar lan-guard install).
# Web 8000-8099 (Werkzeug debugger included), socket.io 9000-9099, Redis 11000-11099 and 13000-13099, MariaDB 3306.
# Keyed on ports, not apps, so a brew upgrade cannot reopen it. \"from ! 127.0.0.1\" also blocks this Mac's own
# LAN address, which is what lets a probe of that address prove the rule works.
${FL_SHARE_PF_TEMPLATE}"

# where the checks read the two root files (the tests' seams); root always writes FL_SHARE_PF_*_FILE
fl_lg_anchor() { printf '%s' "${FL_LANGUARD_ANCHOR:-$FL_SHARE_PF_ANCHOR_FILE}"; }
fl_lg_daemon() { printf '%s' "${FL_LANGUARD_DAEMON:-$FL_SHARE_PF_DAEMON_FILE}"; }

# fl_lg_state_v VAR: installed, missing or outdated, by the rule share preflight and share status use
# (the anchor's non-comment lines, and a daemon that loads it)
fl_lg_state_v() {
  local __problem
  fl_sp_pf_files_problem_v __problem
  if [[ -z "$__problem" ]]; then printf -v "$1" installed
  elif [[ ! -r "$(fl_lg_anchor)" || ! -r "$(fl_lg_daemon)" ]]; then printf -v "$1" missing
  else printf -v "$1" outdated; fi
}

# fl_lg_active_v VAR: whether pf refuses the bench ports, by share preflight's probe from this Mac's LAN
# address alone (the files are the state's business): true (nothing answered and the control did), false
# (a port that must be refused answered), or null (no LAN address, or the probe could not run)
fl_lg_active_v() {
  fl_sp_lan_v
  if [[ -z "$SP_LAN_IP" ]]; then printf -v "$1" null; return 0; fi
  SP_ID=(); SP_STATUS=(); SP_PF_PROBE=unknown
  fl_sp_probe_pf
  case "$SP_PF_PROBE" in
    blocked) printf -v "$1" true ;;
    answered) printf -v "$1" false ;;
    *) printf -v "$1" null ;;
  esac
}

# fl_lg_say_active: one line for LG_ACTIVE
fl_lg_say_active() {
  case "$LG_ACTIVE" in
    true) fl_ok "the bench ports are refused on ${SP_LAN_IP}" ;;
    false) fl_warn "the bench ports are not refused on ${SP_LAN_IP}: see benchbar share preflight --critical" ;;
    *)
      if [[ -z "$SP_LAN_IP" ]]; then fl_info "no LAN address, so the block could not be probed"
      else fl_info "the block could not be probed on ${SP_LAN_IP}: see benchbar share preflight --critical"; fi ;;
  esac
}

# fl_lg_require_person COMMAND: U3, before anything is asked or changed
fl_lg_require_person() {
  [[ "${FL_DRY_RUN:-0}" != 1 ]] || return 0
  fl_noninteractive && fl_die "benchbar lan-guard $1 runs sudo, a person's decision, so nothing run without a terminal can do it." "Run it in a terminal: benchbar lan-guard $1"
  [[ -t 0 || "${BENCHBAR_SUDO:-}" == gui ]] || fl_die "benchbar lan-guard $1 needs a person at a terminal (it asks for your password), and this run has none." "Run it in a terminal: benchbar lan-guard $1"
}

# fl_lg_as_root REASON MANUAL SCRIPT: SCRIPT as root, once: one dialog with BENCHBAR_SUDO=gui, else sudo on
# this terminal, dropped (sudo -k) as soon as it is done. Stops the command, naming MANUAL, when root is refused.
# What the script printed on stdout is in FL_LG_ROOT_OUT.
FL_LG_ROOT_OUT=""
fl_lg_as_root() {
  local reason="$1" manual="$2" script="$3" code=0 last
  FL_LG_ROOT_OUT=""
  if fl_sudo_gui; then
    fl_root_run "$reason" "$script" || code=$?
    case "$code" in
      0) FL_LG_ROOT_OUT="$FL_ROOT_OUTPUT"; return 0 ;;
      2) fl_die "The password dialog was cancelled; nothing was changed." "Run: ${manual}" ;;
    esac
    last="$(printf '%s\n' "$FL_ROOT_OUTPUT" | grep -v '^[[:space:]]*$' | tail -n 1 || true)"
    fl_die "The root step failed${last:+: ${last}}." "Run: ${manual}"
  fi
  fl_sudo_begin "$reason" || fl_die "sudo was not available, so nothing was changed." "Run in a terminal: ${manual}"
  FL_LG_ROOT_OUT="$(sudo /bin/bash -c "$script" benchbar-root)" || code=$?
  fl_sudo_drop
  printf '%s\n' "$FL_LG_ROOT_OUT" | grep -v '^benchbar-pf-' || true
  [[ "$code" == 0 ]] || fl_die "The root step failed (exit ${code}); see the log." "Run: ${manual}"
}

# fl_lg_tools_sh: the tool and file paths every root script names, as shell assignments, one per line
fl_lg_tools_sh() {
  printf 'pfctl=%s\nlaunchctl=%s\nchown=%s\nanchor=%s\ndaemon=%s\nlabel=%s\npf_anchor=%s\n' \
    "'/sbin/pfctl'" "'/bin/launchctl'" "'/usr/sbin/chown'" \
    "$(fl_sq "$FL_SHARE_PF_ANCHOR_FILE")" "$(fl_sq "$FL_SHARE_PF_DAEMON_FILE")" "$FL_LANGUARD_LABEL" "$FL_LANGUARD_PF_ANCHOR_NAME"
}

# fl_lg_install_script: the root side of install. Each file is written next to its place, made
# root:wheel 0644 and moved in; then pf loads the anchor (and is enabled) and launchd loads the daemon,
# which loads it again at every boot.
fl_lg_install_script() {
  printf 'set -eu\numask 022\n'
  fl_lg_tools_sh
  printf 'pf_text=%s\nplist_text=%s\n' "$(fl_sq "$FL_LANGUARD_PF_TEXT")" "$(fl_sq "$FL_SHARE_PF_PLIST")"
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
ROOT
  fl_lg_load_sh
}

# fl_lg_load_sh: the load half: pf enabled with the anchor loaded, and the daemon (re)started.
# pfctl -E takes a reference on pf and prints its token; lan-guard remove gives that reference back with
# pfctl -X. So the root side says, on stdout, whether pf was enabled before and which token it got
# ("benchbar-pf-was-enabled 0|1", "benchbar-pf-token N"); fl_lg_pf_record keeps them in the state folder.
fl_lg_load_sh() {
  cat <<'ROOT'
pf_was=0
case "$("$pfctl" -s info 2>/dev/null || true)" in *"Status: Enabled"*) pf_was=1 ;; esac
pf_out="$("$pfctl" -E -a "$pf_anchor" -f "$anchor" 2>&1)" || { printf '%s\n' "$pf_out" >&2; exit 1; }
printf '%s\n' "$pf_out" >&2
printf 'benchbar-pf-was-enabled %s\n' "$pf_was"
pf_token="$(printf '%s\n' "$pf_out" | sed -n 's/^[Tt]oken *: *\([0-9][0-9]*\).*$/\1/p' | awk 'NR==1')"
if [ -n "$pf_token" ]; then printf 'benchbar-pf-token %s\n' "$pf_token"; fi
if "$launchctl" print "system/$label" >/dev/null 2>&1; then
  "$launchctl" kickstart -k "system/$label"
else
  "$launchctl" bootstrap system "$daemon"
fi
ROOT
}

# fl_lg_reload_script: the root side of a repair, when the files match but pf does not refuse the ports
fl_lg_reload_script() {
  printf 'set -eu\n'
  fl_lg_tools_sh
  fl_lg_load_sh
}

# fl_lg_pf_state: where the pf enable of install is remembered, in the state folder (never the bench):
# was_enabled=0|1 (pf was already on before the first install) and one token=N per pfctl -E
fl_lg_pf_state() { printf '%s/lan-guard/pf.state' "$FL_STATE_DIR"; }

# fl_lg_pf_record OUTPUT: keeps what the root side of install or reload said. was_enabled is kept from the
# first install (a later run finds pf on because of this guard); tokens are added.
fl_lg_pf_record() {
  local f dir was="" tokens="" line
  f="$(fl_lg_pf_state)"; dir="${f%/*}"
  if [[ -f "$f" ]]; then
    was="$(sed -n 's/^was_enabled=\([01]\)$/\1/p' "$f" | awk 'NR==1')"
    tokens="$(sed -n 's/^token=\([0-9][0-9]*\)$/\1/p' "$f")"
  fi
  while IFS= read -r line; do
    case "$line" in
      "benchbar-pf-was-enabled "[01]) [[ -n "$was" ]] || was="${line##* }" ;;
      "benchbar-pf-token "[0-9]*) tokens="${tokens}${tokens:+$'\n'}${line##* }" ;;
    esac
  done <<<"$1"
  [[ -n "$was" ]] || return 0
  (umask 077; mkdir -p "$dir")
  chmod 700 "$dir"
  { printf 'was_enabled=%s\n' "$was"; [[ -z "$tokens" ]] || printf '%s\n' "$tokens" | sed 's/^/token=/'; } >"${f}.new"
  mv -f "${f}.new" "$f"
}

# fl_lg_pf_tokens_v VAR: the tokens to give back, space separated: none when pf was on before the guard
# (it stays on), none without a record
fl_lg_pf_tokens_v() {
  local f was t
  f="$(fl_lg_pf_state)"
  printf -v "$1" '%s' ""
  [[ -f "$f" ]] || return 0
  was="$(sed -n 's/^was_enabled=\([01]\)$/\1/p' "$f" | awk 'NR==1')"
  [[ "$was" == 0 ]] || return 0
  t="$(sed -n 's/^token=\([0-9][0-9]*\)$/\1/p' "$f" | tr '\n' ' ')"
  printf -v "$1" '%s' "${t% }"
}

fl_lg_remove_script() {
  local tokens
  fl_lg_pf_tokens_v tokens
  printf 'set -eu\n'
  fl_lg_tools_sh
  printf 'pf_tokens=%s\n' "$(fl_sq "$tokens")"
  cat <<'ROOT'
if "$launchctl" print "system/$label" >/dev/null 2>&1; then "$launchctl" bootout "system/$label" || true; fi
"$pfctl" -a "$pf_anchor" -F all || true
for t in $pf_tokens; do "$pfctl" -X "$t" || true; done
/bin/rm -f "$daemon" "$anchor"
ROOT
}

# fl_lg_allow_node_script REALPATH
fl_lg_allow_node_script() {
  printf 'set -eu\nfw=%s\nnode=%s\n' "'/usr/libexec/ApplicationFirewall/socketfilterfw'" "$(fl_sq "$1")"
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
  fl_lg_say_active
  [[ "${OPT_JSON:-0}" != 1 ]] || fl_doc_emit 0 "$doc"
}

fl_cmd_lan_guard_status() {
  local a doc
  [[ "${OPT_JSON:-0}" != 1 ]] || fl_json_doc_begin
  for a in "$@"; do fl_die "Unknown argument for lan-guard status: $a" "Use: benchbar lan-guard status [--json]"; done
  fl_lg_doc_v doc
  if [[ "${OPT_JSON:-0}" == 1 ]]; then fl_doc_emit 0 "$doc"; return 0; fi
  fl_info "LAN guard: ${LG_STATE} (pf anchor ${FL_LANGUARD_PF_ANCHOR_NAME}: ${FL_LANGUARD_PORTS})"
  fl_lg_say_active
  [[ "$LG_STATE" == installed && "$LG_ACTIVE" != false ]] || fl_fix "benchbar lan-guard install"
}

# fl_lg_repair: the files match but a bench port answers on the LAN (pf disabled, the anchor flushed, the
# daemon not loaded): load the anchor and the daemon again, the files untouched
fl_lg_repair() {
  local doc ip="$SP_LAN_IP"
  if [[ "${FL_DRY_RUN:-0}" == 1 ]]; then
    fl_info "dry-run: the guard's files match, but the bench ports are not refused on ${ip}; with sudo, once, would:"
    fl_info "  run /sbin/pfctl -E -a ${FL_LANGUARD_PF_ANCHOR_NAME} -f ${FL_SHARE_PF_ANCHOR_FILE}, and load the daemon again (launchctl)"
    return 0
  fi
  fl_warn "The guard's files match, but the bench ports are not refused on ${ip}."
  fl_confirm "Load the LAN guard again with sudo (pf and its launch daemon)?" || fl_die "Not loaded." "Run: benchbar lan-guard install"
  fl_lg_as_root "load the LAN guard again: the pf anchor that keeps the bench ports off the LAN" \
    "benchbar lan-guard install" "$(fl_lg_reload_script)"
  fl_lg_pf_record "$FL_LG_ROOT_OUT"
  fl_lg_doc_v doc
  [[ "$LG_ACTIVE" != false ]] || fl_die "The bench ports still answer on ${ip} after the guard was loaded again." "See benchbar share preflight --critical."
  fl_changed lan-guard "$FL_LANGUARD_PF_ANCHOR_NAME" "reloaded"
  fl_ok "LAN guard loaded again"
  fl_lg_say_active
  [[ "${OPT_JSON:-0}" != 1 ]] || fl_doc_emit 0 "$doc"
}

fl_cmd_lan_guard_install() {
  local a state doc
  for a in "$@"; do fl_die "Unknown argument for lan-guard install: $a" "Use: benchbar lan-guard install [--dry-run] [--yes] [--json]"; done
  fl_lg_require_person install
  fl_lg_state_v state
  if [[ "$state" == installed ]]; then
    fl_lg_doc_v doc
    if [[ "$LG_ACTIVE" != false ]]; then
      fl_ok "unchanged: the guard is installed and matches"
      fl_lg_say_active
      [[ "${OPT_JSON:-0}" != 1 ]] || fl_doc_emit 0 "$doc"
      return 0
    fi
    fl_lg_repair
    return 0
  fi
  if [[ "${FL_DRY_RUN:-0}" == 1 ]]; then
    fl_info "dry-run: the guard is ${state}; with sudo, once, would:"
    fl_info "  write ${FL_SHARE_PF_ANCHOR_FILE} (root:wheel 0644): block TCP to ${FL_LANGUARD_PORTS} from anything but loopback"
    fl_info "  write ${FL_SHARE_PF_DAEMON_FILE} (root:wheel 0644): load that anchor at every boot"
    fl_info "  run /sbin/pfctl -E -a ${FL_LANGUARD_PF_ANCHOR_NAME} -f ${FL_SHARE_PF_ANCHOR_FILE}, and load the daemon (launchctl)"
    return 0
  fi
  fl_confirm "Install the LAN guard with sudo (a pf anchor and a launch daemon)?" || fl_die "Not installed." "Run: benchbar lan-guard install"
  fl_lg_as_root "install the LAN guard: the pf anchor that keeps the bench ports off the LAN, and the daemon that loads it at boot" \
    "benchbar lan-guard install" "$(fl_lg_install_script)"
  fl_lg_pf_record "$FL_LG_ROOT_OUT"
  fl_lg_state_v state
  [[ "$state" == installed ]] || fl_die "The guard files are still ${state} after the root step." "See the log; run benchbar lan-guard install again."
  fl_changed lan-guard "$FL_LANGUARD_PF_ANCHOR_NAME" "installed"
  fl_ok "LAN guard installed: ${FL_SHARE_PF_ANCHOR_FILE} and ${FL_SHARE_PF_DAEMON_FILE}"
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
  rm -f "$(fl_lg_pf_state)"
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
