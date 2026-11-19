#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# lan-guard-linux.sh: the Linux half of benchbar lan-guard (lan-guard.sh has the macOS half and the
# dispatch). The contract is the pf anchor's: TCP to the bench ports from anything but loopback is
# refused, with or without a room, and this machine's own LAN address counts as "not loopback", which
# is what lets a probe of that address prove the rule works.
#
# One nftables table, "inet benchbar", owned by benchbar, with one input chain at priority -10 and a
# policy of accept: only the bench ports are touched, nothing else about the machine's firewall. A
# systemd unit (benchbar-lan-guard.service) loads the table again at boot and deletes it on stop.
# remove deletes that table, the unit and the rules file, nothing else. ufw and a firewalld are not
# changed (docs/DECISIONS.md).
#
# Root runs a script of this CLI's own text, as the macOS half does: the system tools and the two root
# files are named by absolute path, the rules and the unit are single-quoted literals, and nothing from
# the environment chooses what root runs or writes. A person's decision (BENCHBAR_NONINTERACTIVE, so
# --for-agent and mcp, is refused), asked once.
#
# Seams for the tests, read only under FL_TESTING=1: FL_NFT (the nft binary the checks and the root
# script name), FL_LANGUARD_RULES and FL_LANGUARD_UNIT (the two root files), FL_LGL_SYSTEMD_DIR (the
# folder whose existence says systemd is the init).

FL_LGL_TABLE="inet benchbar"
FL_LGL_UNIT_NAME=benchbar-lan-guard.service
FL_LGL_RULES_FILE=/etc/benchbar/lan-guard.nft
FL_LGL_UNIT_FILE=/etc/systemd/system/benchbar-lan-guard.service
FL_LGL_SYSTEMCTL=/usr/bin/systemctl

# The rules file. "add table" then "delete table" makes loading it again start from nothing, and only
# ever touches this table. Loopback is exempt by address, not by interface: a connection from this
# machine to its own LAN address arrives on lo with the LAN address as its source, and is refused.
FL_LGL_RULES_TEXT='# BenchBar: Frappe bench ports answer this machine only (benchbar lan-guard install).
# Web 8000-8099 (Werkzeug debugger included), socket.io 9000-9099, Redis 11000-11099 and 13000-13099, MariaDB 3306.
# Keyed on ports, not apps. Nothing else is filtered. Only this table is touched; remove deletes it.
add table inet benchbar
delete table inet benchbar
table inet benchbar {
  chain input {
    type filter hook input priority -10; policy accept;
    ip saddr != 127.0.0.0/8 tcp dport { 8000-8099, 9000-9099, 11000-11099, 13000-13099, 3306 } reject with tcp reset
    ip6 saddr != ::1 tcp dport { 8000-8099, 9000-9099, 11000-11099, 13000-13099, 3306 } reject with tcp reset
  }
}'

# fl_lgl_nft_v VAR: the nft binary, by absolute path (empty: none)
fl_lgl_nft_v() {
  local __p __r=""
  if [[ "${FL_TESTING:-}" == "1" && -n "${FL_NFT:-}" ]]; then
    [[ -x "$FL_NFT" ]] && __r="$FL_NFT"
  else
    for __p in /usr/sbin/nft /sbin/nft /usr/bin/nft; do [[ -x "$__p" ]] && { __r="$__p"; break; }; done
  fi
  printf -v "$1" '%s' "$__r"
}

# fl_lgl_unit_text NFT: the unit, with the nft binary this machine has
fl_lgl_unit_text() {
  cat <<UNIT
# BenchBar: loads the LAN guard table at boot (benchbar lan-guard install).
[Unit]
Description=BenchBar LAN guard: bench ports answer this machine only
Wants=network-pre.target
Before=network-pre.target shutdown.target
Conflicts=shutdown.target
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${1} -f ${FL_LGL_RULES_FILE}
ExecStop=-${1} delete table ${FL_LGL_TABLE}

[Install]
WantedBy=multi-user.target
UNIT
}

# the two root files; the tests' seams are read only under FL_TESTING=1
fl_lgl_rules_path() { if [[ "${FL_TESTING:-}" == "1" ]]; then printf '%s' "${FL_LANGUARD_RULES:-$FL_LGL_RULES_FILE}"; else printf '%s' "$FL_LGL_RULES_FILE"; fi; }
fl_lgl_unit_path() { if [[ "${FL_TESTING:-}" == "1" ]]; then printf '%s' "${FL_LANGUARD_UNIT:-$FL_LGL_UNIT_FILE}"; else printf '%s' "$FL_LGL_UNIT_FILE"; fi; }

# fl_lgl_files_problem_v VAR: why the rules file or the unit is not what lan-guard installs (empty: they
# are). Comment lines and spacing are not compared.
fl_lgl_files_problem_v() {
  local rules unit nft lines want
  local squeeze='s/^[[:space:]]*//; /^#/d; /^$/d; s/[[:space:]][[:space:]]*/ /g; s/[[:space:]]$//'
  rules="$(fl_lgl_rules_path)"; unit="$(fl_lgl_unit_path)"
  printf -v "$1" '%s' ""
  if [[ ! -r "$rules" ]]; then printf -v "$1" 'the rules file %s is missing' "$rules"; return 0; fi
  lines="$(sed "$squeeze" "$rules")"
  want="$(printf '%s\n' "$FL_LGL_RULES_TEXT" | sed "$squeeze")"
  if [[ "$lines" != "$want" ]]; then printf -v "$1" 'the rules file %s does not match what lan-guard installs' "$rules"; return 0; fi
  if [[ ! -r "$unit" ]]; then printf -v "$1" 'the unit %s is missing' "$unit"; return 0; fi
  fl_lgl_nft_v nft
  lines="$(sed "$squeeze" "$unit")"
  want="$(fl_lgl_unit_text "${nft:-/usr/sbin/nft}" | sed "$squeeze")"
  if [[ "$lines" != "$want" ]]; then
    printf -v "$1" 'the unit %s does not match what lan-guard installs (it must load the rules at boot)' "$unit"
  fi
}

# fl_lgl_unsupported_v VAR: why this Linux cannot have the guard (empty: it can). Read only; the first
# thing install and remove look at, before any sudo.
fl_lgl_unsupported_v() {
  local nft sd=/run/systemd/system
  printf -v "$1" '%s' ""
  [[ "${FL_TESTING:-}" != "1" ]] || sd="${FL_LGL_SYSTEMD_DIR:-$sd}"
  fl_lgl_nft_v nft
  if [[ -z "$nft" ]]; then printf -v "$1" 'nft (nftables) is not installed: run sudo apt install nftables'; return 0; fi
  if [[ ! -d "$sd" ]]; then
    printf -v "$1" 'systemd is not the init of this machine, and the guard is loaded at boot by a systemd unit (in WSL, enable systemd in /etc/wsl.conf)'
  fi
}

# fl_lgl_ufw_note: one line when ufw is on. The guard stacks with it (both can refuse; neither accepts for
# the other), so a room's port needs its own ufw rule, which benchbar does not write.
fl_lgl_ufw_note() {
  fl_linux_unit_active ufw.service || return 0
  fl_info "ufw is active. It stays as it is: BenchBar does not change ufw. A room's port needs an allow rule of yours (sudo ufw allow ${FL_SHARE_GATEWAY_PORT:-8443}/tcp), and the guard still refuses the bench ports on top of it."
}

# ---------------------------------------------------------------- the root scripts

# fl_lgl_tools_sh NFT: the tool and file paths every root script names, as shell assignments, one per line
fl_lgl_tools_sh() {
  printf 'nft=%s\nsystemctl=%s\nrules=%s\nunitf=%s\nunit=%s\n' \
    "$(fl_sq "$1")" "$(fl_sq "$FL_LGL_SYSTEMCTL")" "$(fl_sq "$FL_LGL_RULES_FILE")" "$(fl_sq "$FL_LGL_UNIT_FILE")" "$FL_LGL_UNIT_NAME"
}

# fl_lgl_install_script NFT: each file is written next to its place and checked (nft -c for the rules)
# before it is moved in; then systemd learns the unit, enables it and starts it again, which loads the table.
fl_lgl_install_script() {
  printf 'set -eu\numask 022\n'
  fl_lgl_tools_sh "$1"
  printf 'rules_text=%s\nunit_text=%s\n' "$(fl_sq "$FL_LGL_RULES_TEXT")" "$(fl_sq "$(fl_lgl_unit_text "$1")")"
  cat <<'ROOT'
put() {
  new="$1.benchbar.new"
  /bin/rm -f "$new"
  printf '%s\n' "$2" >"$new"
  /bin/chmod 0644 "$new"
  if [ "$1" = "$rules" ]; then "$nft" -c -f "$new" || { /bin/rm -f "$new"; exit 1; }; fi
  /bin/mv -f "$new" "$1"
}
/bin/mkdir -p "${rules%/*}"
put "$rules" "$rules_text"
put "$unitf" "$unit_text"
ROOT
  fl_lgl_load_sh
}

# fl_lgl_load_sh: the load half: systemd knows the unit, it is enabled, and the rules are loaded again
fl_lgl_load_sh() {
  cat <<'ROOT'
"$systemctl" daemon-reload
"$systemctl" enable "$unit"
"$systemctl" restart "$unit"
ROOT
}

# fl_lgl_reload_script NFT: the root side of a repair, when the files match but the table is not loaded
fl_lgl_reload_script() {
  printf 'set -eu\n'
  fl_lgl_tools_sh "$1"
  fl_lgl_load_sh
}

# fl_lgl_remove_script NFT: the unit stops (which deletes the table), then the table is deleted if it is
# still there, then the unit, the rules file and their folder go. Nothing else in nftables is touched.
fl_lgl_remove_script() {
  printf 'set -eu\n'
  fl_lgl_tools_sh "$1"
  cat <<'ROOT'
"$systemctl" disable --now "$unit" || true
"$nft" delete table inet benchbar 2>/dev/null || true
/bin/rm -f "$unitf" "$rules"
/bin/rmdir "${rules%/*}" 2>/dev/null || true
"$systemctl" daemon-reload
ROOT
}

# ---------------------------------------------------------------- commands

fl_lgl_install() {
  local state doc nft why
  fl_lgl_unsupported_v why
  [[ -z "$why" ]] || fl_die "benchbar lan-guard install cannot run here: ${why}." "Nothing was changed."
  fl_lgl_nft_v nft
  fl_lg_require_person install
  fl_lg_state_v state
  if [[ "$state" == installed ]]; then
    fl_lg_doc_v doc
    if [[ "$LG_ACTIVE" != false ]]; then
      fl_ok "unchanged: the guard is installed and matches"
      fl_lg_say_active
      fl_lgl_ufw_note
      [[ "${OPT_JSON:-0}" != 1 ]] || fl_doc_emit 0 "$doc"
      return 0
    fi
    fl_lgl_repair "$nft"
    return 0
  fi
  if [[ "${FL_DRY_RUN:-0}" == 1 ]]; then
    fl_info "dry-run: the guard is ${state}; with sudo, once, would:"
    fl_info "  write ${FL_LGL_RULES_FILE} (root 0644): refuse TCP to ${FL_LANGUARD_PORTS} from anything but loopback, in the nftables table ${FL_LGL_TABLE}"
    fl_info "  write ${FL_LGL_UNIT_FILE} (root 0644): load that table at every boot"
    fl_info "  run ${FL_LGL_SYSTEMCTL} daemon-reload, enable and restart ${FL_LGL_UNIT_NAME}"
    return 0
  fi
  fl_confirm "Install the LAN guard with sudo (an nftables table and a systemd unit)?" || fl_die "Not installed." "Run: benchbar lan-guard install"
  fl_lg_as_root "install the LAN guard: the nftables table that keeps the bench ports off the LAN, and the systemd unit that loads it at boot" \
    "benchbar lan-guard install" "$(fl_lgl_install_script "$nft")"
  fl_lg_state_v state
  [[ "$state" == installed ]] || fl_die "The guard files are still ${state} after the root step." "See the log; run benchbar lan-guard install again."
  fl_changed lan-guard "$FL_LGL_TABLE" "installed"
  fl_ok "LAN guard installed: ${FL_LGL_RULES_FILE} and ${FL_LGL_UNIT_FILE}"
  fl_lg_report
  fl_lgl_ufw_note
}

# fl_lgl_repair NFT: the files match but a bench port answers on the LAN (the table is gone: an nftables
# reload that flushes the ruleset, a stopped unit): load it again, the files untouched
fl_lgl_repair() {
  local doc ip="$SP_LAN_IP"
  if [[ "${FL_DRY_RUN:-0}" == 1 ]]; then
    fl_info "dry-run: the guard's files match, but the bench ports are not refused on ${ip}; with sudo, once, would:"
    fl_info "  run ${FL_LGL_SYSTEMCTL} daemon-reload, enable and restart ${FL_LGL_UNIT_NAME}"
    return 0
  fi
  fl_warn "The guard's files match, but the bench ports are not refused on ${ip}."
  fl_confirm "Load the LAN guard again with sudo (its systemd unit)?" || fl_die "Not loaded." "Run: benchbar lan-guard install"
  fl_lg_as_root "load the LAN guard again: the nftables table that keeps the bench ports off the LAN" \
    "benchbar lan-guard install" "$(fl_lgl_reload_script "$1")"
  fl_lg_doc_v doc
  [[ "$LG_ACTIVE" != false ]] || fl_die "The bench ports still answer on ${ip} after the guard was loaded again." "See benchbar share preflight --critical."
  fl_changed lan-guard "$FL_LGL_TABLE" "reloaded"
  fl_ok "LAN guard loaded again"
  fl_lg_say_active
  [[ "${OPT_JSON:-0}" != 1 ]] || fl_doc_emit 0 "$doc"
}

fl_lgl_remove() {
  local state nft why
  fl_lgl_unsupported_v why
  [[ -z "$why" ]] || fl_die "benchbar lan-guard remove cannot run here: ${why}." "Nothing was changed."
  fl_lgl_nft_v nft
  fl_lg_require_person remove
  if [[ ! -e "$(fl_lgl_rules_path)" && ! -e "$(fl_lgl_unit_path)" ]]; then
    fl_ok "unchanged: the guard is not installed"
    fl_lg_report
    return 0
  fi
  fl_warn "Without the guard the bench ports answer the LAN, and benchbar share start refuses to run."
  fl_confirm "Remove the LAN guard with sudo?" || fl_die "Not removed." "Run: benchbar lan-guard remove"
  fl_lg_as_root "remove the LAN guard: its nftables table and its systemd unit" "benchbar lan-guard remove" "$(fl_lgl_remove_script "$nft")"
  fl_lg_state_v state
  [[ "$state" == missing ]] || fl_die "The guard files are still there after the root step." "See the log; run benchbar lan-guard remove again."
  fl_changed lan-guard "$FL_LGL_TABLE" "removed"
  fl_ok "LAN guard removed"
  fl_lg_report
}

# allow-node is the macOS application firewall's: Linux has no per-program allow list to change
fl_lgl_allow_node() {
  fl_die "benchbar lan-guard allow-node is not available on linux: it changes the macOS application firewall, and Linux has no such list." \
    "Nothing was changed. If ufw is on, a room's port needs: sudo ufw allow ${FL_SHARE_GATEWAY_PORT:-8443}/tcp"
}
