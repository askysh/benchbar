#!/usr/bin/env bash
# benchbar lan-guard install|status|remove|allow-node. The root scripts name the system tools and the two
# root files by their absolute paths; the sudo and osascript mocks map those to mocks and to TMP_DIR
# (tests/mocks/root-paths.sh), so nothing here touches this Mac's pf, launchd or firewall.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH" macdev

PF_DIR="$TMP_DIR/pf"; mkdir -p "$PF_DIR"
export FL_LANGUARD_ANCHOR="$PF_DIR/com.benchbar.lan" FL_LANGUARD_DAEMON="$PF_DIR/com.benchbar.pf.plist"
export FL_SOCKETFILTERFW="$ROOT/tests/mocks/bin/socketfilterfw" FL_OSASCRIPT="$ROOT/tests/mocks/osascript-gui"
export FL_NC="$ROOT/tests/mocks/bin/nc" FL_ROUTE="$ROOT/tests/mocks/bin/route" FL_IPCONFIG="$ROOT/tests/mocks/bin/ipconfig" FL_IFCONFIG="$ROOT/tests/mocks/bin/ifconfig"

# node: a symlink (like Homebrew's bin/node) to the real file
NODE_REAL_DIR="$TMP_DIR/nodes/cellar/22/bin"; NODE_LINK_DIR="$TMP_DIR/nodes/bin"
mkdir -p "$NODE_REAL_DIR" "$NODE_LINK_DIR"
cp "$ROOT/tests/mocks/node" "$NODE_REAL_DIR/node"; chmod 755 "$NODE_REAL_DIR/node"
ln -s "$NODE_REAL_DIR/node" "$NODE_LINK_DIR/node"
chmod 755 "$TMP_DIR/nodes" "$TMP_DIR/nodes/cellar" "$TMP_DIR/nodes/cellar/22" "$NODE_REAL_DIR" "$NODE_LINK_DIR"
export FL_SHARE_NODE="$NODE_LINK_DIR/node"

# a LAN address, and the block working: the in-range listener refused, the control answering
printf 'en0\n' >"$MOCK_STATE/lan_iface"; printf '192.168.1.20\n' >"$MOCK_STATE/lan_ip"
printf '18097\n' >"$MOCK_STATE/lan_reachable_ports"; : >"$MOCK_STATE/loopback_ports"

const_of() { # NAME: a single-quoted constant of share-preflight.sh, as the CLI holds it
  sed -n "/^$1='/,/'\$/p" "$ROOT/lib/frappe-local/share-preflight.sh" | sed "s/^$1='//; s/'\$//"
}
WANT_PLIST="$(const_of FL_SHARE_PF_PLIST)"
clean() { rm -f "$FL_LANGUARD_ANCHOR" "$FL_LANGUARD_DAEMON" "$MOCK_STATE/osa_reasons" "$MOCK_STATE"/osa_cmd.* "$MOCK_STATE/agents/com.benchbar.pf"; reset_calls; }
lg() { run_fm lan-guard "$@" --bench-dir "$BENCH"; }
lg_gui() { BENCHBAR_SUDO=gui run_fm lan-guard "$@" --bench-dir "$BENCH"; }
# lg_tty ARGS...: on a terminal (a pty), the sudo path
lg_tty() {
  set +e
  OUT="$(python3 -c 'import os, pty, sys; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))' "$FM" lan-guard "$@" --bench-dir "$BENCH" 2>&1)"
  CODE="$?"
  set -e
}
status_json() { "$FM" lan-guard status --json --bench-dir "$BENCH" 2>/dev/null; }
jstat() { status_json >"$TMP_DIR/st.json"; jget "$TMP_DIR/st.json" "$1"; }

# ---------------------------------------------------------------- the daemon enables pf and loads the anchor at boot
squeeze='s/^[[:space:]]*//; /^#/d; /^$/d; s/[[:space:]][[:space:]]*/ /g; s/[[:space:]]$//'
PF_TEMPLATE_CONST="$(const_of FL_SHARE_PF_TEMPLATE)"
for want in '<string>/sbin/pfctl</string><string>-E</string>' '<string>-f</string><string>/etc/pf.anchors/com.benchbar.lan</string>' \
  '<key>RunAtLoad</key><true/>' '<key>Label</key><string>com.benchbar.pf</string>'; do
  assert_contains "$WANT_PLIST" "$want"
done

# ---------------------------------------------------------------- missing: status, dry run, install (gui)
# active is share preflight's pf_active check, which fails while the files are missing
clean
assert_eq "missing False 192.168.1.20 com.apple/250.benchbar" "$(jstat '" ".join(str(x) for x in (d["state"], d["active"], d["lan_ip"], d["anchor"]))')"
assert_eq "8000:8099 9000:9099 11000:11099 13000:13099 3306" "$(jget "$TMP_DIR/st.json" 'd["ports"]')"
# status is never refused, also for an agent
BENCHBAR_NONINTERACTIVE=1 run_fm lan-guard status --json --bench-dir "$BENCH"
assert_eq 0 "$CODE" "$OUT"

lg install --dry-run
assert_eq 0 "$CODE" "$OUT"
assert_contains "$OUT" "dry-run"; assert_contains "$OUT" "/etc/pf.anchors/com.benchbar.lan"
assert_no_file "$FL_LANGUARD_ANCHOR"; assert_no_file "$FL_LANGUARD_DAEMON"
assert_calls_not_contain '^(sudo|pfctl|osascript)'

# I1: nothing in the environment chooses what root runs or writes, not the old seams and not FL_TEMPLATE_DIR
EVIL="$TMP_DIR/evil"; mkdir -p "$EVIL"; cp "$ROOT"/templates/*.tmpl "$EVIL/"
printf 'pass\n' >"$EVIL/lan-guard.pf.tmpl"; printf '<plist>evil</plist>\n' >"$EVIL/lan-guard.plist.tmpl"
FL_TEMPLATE_DIR="$EVIL" FL_PFCTL="$EVIL/pfctl" FL_LAUNCHCTL="$EVIL/launchctl" FL_CHOWN="$EVIL/chown" FL_SOCKETFILTERFW="$EVIL/fw" \
  lg_gui install --yes
assert_eq 0 "$CODE" "$OUT"
assert_eq "$(printf '%s\n' "$PF_TEMPLATE_CONST" | sed "$squeeze")" "$(sed "$squeeze" "$FL_LANGUARD_ANCHOR")" "(the anchor is share preflight's rules)"
assert_contains "$(cat "$FL_LANGUARD_ANCHOR")" "# BenchBar: Frappe bench ports answer this Mac only"
assert_eq "$WANT_PLIST" "$(cat "$FL_LANGUARD_DAEMON")"
assert_eq 1 "$(wc -l <"$MOCK_STATE/osa_reasons" | tr -d ' ')" "(one dialog)"
assert_contains "$(cat "$MOCK_STATE/osa_reasons")" "install the LAN guard"
assert_calls_contain "^pfctl -E -a com.apple/250.benchbar -f ${FL_LANGUARD_ANCHOR}\$"
assert_calls_contain "^launchctl bootstrap system ${FL_LANGUARD_DAEMON}\$"
assert_calls_contain "^chown root:wheel ${FL_LANGUARD_ANCHOR}.benchbar.new\$"
assert_calls_not_contain '^sudo'
assert_contains "$OUT" "refused on 192.168.1.20"
# the root script holds the literals and the system paths, and names no path of the user or the environment
script="$(cat "$MOCK_STATE/osa_cmd.1")"
# shellcheck disable=SC2016  # pf's $ports macro
assert_contains "$script" 'block return in quick inet proto tcp from ! 127.0.0.1 to any port $ports'
assert_contains "$script" '<key>Label</key><string>com.benchbar.pf</string>'
for p in /sbin/pfctl /bin/launchctl /usr/sbin/chown /etc/pf.anchors/com.benchbar.lan /Library/LaunchDaemons/com.benchbar.pf.plist; do
  assert_contains "$script" "$p" "(root names $p)"
done
for p in "$TMP_DIR" "$HOME" "${TMPDIR:-/tmp}" /tmp/ /var/folders /private/var; do
  assert_not_contains "$script" "$p" "(the root script names no user path)"
done
assert_eq "installed True" "$(jstat '" ".join(str(x) for x in (d["state"], d["active"]))')"

# ---------------------------------------------------------------- matching: unchanged, no sudo
reset_calls; rm -f "$MOCK_STATE/osa_reasons"
lg_gui install --yes
assert_eq 0 "$CODE" "$OUT"
assert_contains "$OUT" "unchanged: the guard is installed and matches"
assert_calls_not_contain '^(sudo|pfctl)'; assert_no_file "$MOCK_STATE/osa_reasons"
# only the comment lines differ (the Phase 0 file had no header): still unchanged
sed_inplace '/^# BenchBar/d' "$FL_LANGUARD_ANCHOR"
lg_tty install --yes
assert_eq 0 "$CODE" "$OUT"; assert_contains "$OUT" "unchanged"; assert_calls_not_contain '^sudo'

# I3: the daemon is compared whole. The header comment an earlier (template) install wrote is not compared;
# a plist that does not enable pf, does not run at load, or runs another pfctl is outdated
cp "$FL_LANGUARD_DAEMON" "$TMP_DIR/daemon.good"
awk 'NR == 4 { print "<!-- benchbar-template: lan-guard.plist v1 0123456789ab -->" } 1' "$TMP_DIR/daemon.good" >"$FL_LANGUARD_DAEMON"
assert_contains "$(cat "$FL_LANGUARD_DAEMON")" "benchbar-template"
assert_eq installed "$(jstat 'd["state"]')"
for bad in 's#<string>-E</string>##' 's#<key>RunAtLoad</key><true/>##' 's#/sbin/pfctl#/tmp/pfctl-x#' 's#</plist>##'; do
  cp "$TMP_DIR/daemon.good" "$FL_LANGUARD_DAEMON"; sed_inplace "$bad" "$FL_LANGUARD_DAEMON"
  assert_eq outdated "$(jstat 'd["state"]')" "(daemon edited: $bad)"
done
cp "$TMP_DIR/daemon.good" "$FL_LANGUARD_DAEMON"

# ---------------------------------------------------------------- different ports: outdated, rewritten (terminal, sudo)
sed_inplace 's/8000:8099/8000:8199/' "$FL_LANGUARD_ANCHOR"
assert_eq outdated "$(jstat 'd["state"]')"
reset_calls; printf 'com.benchbar.pf\n' >"$MOCK_STATE/agents/com.benchbar.pf"
lg_tty install --yes
assert_eq 0 "$CODE" "$OUT"
assert_eq "$(printf '%s\n' "$PF_TEMPLATE_CONST" | sed "$squeeze")" "$(sed "$squeeze" "$FL_LANGUARD_ANCHOR")"
assert_calls_contain '^sudo -v'; assert_calls_contain '^sudo /bin/bash -c'
assert_calls_contain "^launchctl kickstart -k system/com.benchbar.pf\$"
# the credential is dropped at the end
assert_calls_contain '^sudo -k'
[[ "$(grep -n '^sudo -k' "$MOCK_LOG" | tail -n1 | cut -d: -f1)" -gt "$(grep -n '^pfctl' "$MOCK_LOG" | tail -n1 | cut -d: -f1)" ]] || fail "sudo -k must come after the root step"
assert_eq installed "$(jstat 'd["state"]')"

# ---------------------------------------------------------------- U3: refused for an agent and without a terminal
clean
for env in BENCHBAR_NONINTERACTIVE=1 BENCHBAR_NONINTERACTIVE=0; do
  for sub in install remove allow-node; do
    reset_calls
    set +e; OUT="$(env "$env" "$FM" lan-guard "$sub" --yes --bench-dir "$BENCH" </dev/null 2>&1)"; CODE="$?"; set -e
    assert_eq 1 "$CODE" "($env $sub) $OUT"
    assert_contains "$OUT" "benchbar lan-guard ${sub}" "($env $sub names the manual command)"
    assert_calls_not_contain '^(sudo|pfctl|osascript|socketfilterfw --add)' "($env $sub)"
  done
done
BENCHBAR_SUDO=gui run_fm lan-guard install --yes --for-agent --bench-dir "$BENCH"
assert_eq 1 "$CODE" "$OUT"; assert_contains "$OUT" '"exit":1'
assert_no_file "$FL_LANGUARD_ANCHOR"
# without a terminal, BENCHBAR_SUDO=gui from the app is the one way in (above); a cancelled dialog changes nothing
clean; touch "$MOCK_STATE/osa_cancel_all"
lg_gui install --yes
rm -f "$MOCK_STATE/osa_cancel_all"
assert_eq 1 "$CODE" "$OUT"; assert_contains "$OUT" "cancelled"; assert_no_file "$FL_LANGUARD_ANCHOR"

# ---------------------------------------------------------------- remove: asks once, deletes both
clean
lg_gui install --yes
assert_eq 0 "$CODE" "$OUT"
reset_calls; rm -f "$MOCK_STATE/osa_reasons"
lg_gui remove
assert_eq 1 "$CODE" "(no --yes and no terminal: not removed) $OUT"
assert_file "$FL_LANGUARD_ANCHOR"; assert_calls_not_contain '^pfctl'
lg_gui remove --yes
assert_eq 0 "$CODE" "$OUT"
assert_contains "$OUT" "share start refuses to run"
assert_no_file "$FL_LANGUARD_ANCHOR"; assert_no_file "$FL_LANGUARD_DAEMON"
assert_eq 1 "$(wc -l <"$MOCK_STATE/osa_reasons" | tr -d ' ')" "(one dialog)"
assert_calls_contain '^launchctl bootout system/com.benchbar.pf$'
assert_calls_contain '^pfctl -a com.apple/250.benchbar -F all$'
assert_eq missing "$(jstat 'd["state"]')"
reset_calls
lg_gui remove --yes
assert_eq 0 "$CODE" "$OUT"; assert_contains "$OUT" "unchanged"; assert_calls_not_contain '^pfctl'

# ---------------------------------------------------------------- allow-node: the realpath, unchanged when allowed or off
clean; rm -f "$MOCK_STATE/osa_reasons"
lg_gui allow-node --yes
assert_eq 0 "$CODE" "$OUT"; assert_contains "$OUT" "unchanged: the firewall is off"
assert_calls_not_contain '^socketfilterfw --(add|unblockapp)'; assert_no_file "$MOCK_STATE/osa_reasons"
printf 'Firewall is enabled. (State = 1)\n' >"$MOCK_STATE/fw_state"
lg_gui allow-node --yes
assert_eq 0 "$CODE" "$OUT"; assert_contains "$OUT" "unchanged: the firewall allows ${NODE_REAL_DIR}/node"
assert_no_file "$MOCK_STATE/osa_reasons"
printf 'The application at %%PATH%% is blocking incoming connections.\n' >"$MOCK_STATE/fw_app"
lg_gui allow-node --yes --json
assert_eq 0 "$CODE" "$OUT"
assert_calls_contain "^socketfilterfw --add ${NODE_REAL_DIR}/node\$"
assert_calls_contain "^socketfilterfw --unblockapp ${NODE_REAL_DIR}/node\$"
assert_calls_not_contain "^socketfilterfw --add ${NODE_LINK_DIR}"
assert_contains "$OUT" "\"node\":\"${NODE_REAL_DIR}/node\""
# a node another user could replace is never named to root
chmod 777 "$NODE_REAL_DIR"; reset_calls
lg_gui allow-node --yes
chmod 755 "$NODE_REAL_DIR"
assert_eq 1 "$CODE" "$OUT"; assert_calls_not_contain '^socketfilterfw --add'
rm -f "$MOCK_STATE/fw_state" "$MOCK_STATE/fw_app"

# ---------------------------------------------------------------- no LAN address: active is null
rm -f "$MOCK_STATE/lan_iface"
assert_eq "None None" "$(jstat '" ".join(str(x) for x in (d["active"], d["lan_ip"]))')"

printf 'test-lan-guard: ok\n'
