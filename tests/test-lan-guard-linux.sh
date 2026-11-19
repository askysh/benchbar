#!/usr/bin/env bash
# benchbar lan-guard on Linux: an nftables table ("inet benchbar") and a systemd unit that loads it at
# boot, the same contract as the macOS pf anchor (tests/test-lan-guard.sh). The root script names the
# system tools and the two root files by absolute path; the sudo mock maps them to mocks and to TMP_DIR
# (tests/mocks/root-paths.sh), so nothing here touches this machine's firewall or systemd.
# Also: on a platform with no guard (and on Linux, for allow-node) every subcommand refuses before any
# sudo, and nothing with macOS paths can run.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
use_linux
export BENCHBAR_LABS=lan-rooms

BENCH="$HOME/frappe-bench"
make_fake_bench "$BENCH" linuxdev.localhost

NFT_DIR="$TMP_DIR/nft"; mkdir -p "$NFT_DIR"
export FL_LANGUARD_RULES="$NFT_DIR/lan-guard.nft" FL_LANGUARD_UNIT="$NFT_DIR/benchbar-lan-guard.service"
export FL_NFT="$ROOT/tests/mocks/bin/nft" FL_IP="$ROOT/tests/mocks/bin/ip" FL_NC="$ROOT/tests/mocks/bin/nc"
export FL_LGL_SYSTEMD_DIR="$TMP_DIR/run-systemd"; mkdir -p "$FL_LGL_SYSTEMD_DIR"

# node: a symlink (like fnm's) to the real file
NODE_REAL_DIR="$TMP_DIR/nodes/cellar/22/bin"; NODE_LINK_DIR="$TMP_DIR/nodes/bin"
mkdir -p "$NODE_REAL_DIR" "$NODE_LINK_DIR"
cp "$ROOT/tests/mocks/node" "$NODE_REAL_DIR/node"; chmod 755 "$NODE_REAL_DIR/node"
ln -s "$NODE_REAL_DIR/node" "$NODE_LINK_DIR/node"
chmod 755 "$TMP_DIR/nodes" "$TMP_DIR/nodes/cellar" "$TMP_DIR/nodes/cellar/22" "$NODE_REAL_DIR" "$NODE_LINK_DIR"
export FL_SHARE_NODE="$NODE_LINK_DIR/node"

# a LAN address, and the block working: the in-range listener refused, the control answering
printf 'eth0\n' >"$MOCK_STATE/lan_iface"; printf '192.168.1.20\n' >"$MOCK_STATE/lan_ip"
printf '18097\n' >"$MOCK_STATE/lan_reachable_ports"; : >"$MOCK_STATE/loopback_ports"

const_of() { # NAME: a single-quoted constant of lan-guard-linux.sh, as the CLI holds it
  sed -n "/^$1='/,/'\$/p" "$ROOT/lib/frappe-local/lan-guard-linux.sh" | sed "s/^$1='//; s/'\$//"
}
RULES_CONST="$(const_of FL_LGL_RULES_TEXT)"
squeeze='s/^[[:space:]]*//; /^#/d; /^$/d; s/[[:space:]][[:space:]]*/ /g; s/[[:space:]]$//'
clean() { rm -f "$FL_LANGUARD_RULES" "$FL_LANGUARD_UNIT" "$MOCK_STATE/nft_table" "$MOCK_STATE"/units/system/benchbar-lan-guard.service "$MOCK_STATE/nft_invalid"; printf '18097
' >"$MOCK_STATE/lan_reachable_ports"; reset_calls; }
lg() { run_fm lan-guard "$@" --bench-dir "$BENCH"; }
# lg_tty ARGS...: on a terminal (a pty), the sudo path (BENCHBAR_SUDO=gui is a Mac thing and is ignored here)
lg_tty() {
  set +e
  OUT="$(python3 -c 'import os, pty, sys; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))' "$FM" lan-guard "$@" --bench-dir "$BENCH" 2>&1)"
  CODE="$?"
  set -e
}
status_json() { "$FM" lan-guard status --json --bench-dir "$BENCH" 2>/dev/null; }
jstat() { status_json >"$TMP_DIR/st.json"; jget "$TMP_DIR/st.json" "$1"; }
calls() { cat "$MOCK_LOG"; }

# ---------------------------------------------------------------- the rules: only the bench ports, only from non-loopback
assert_contains "$RULES_CONST" 'add table inet benchbar'
assert_contains "$RULES_CONST" 'delete table inet benchbar'
assert_contains "$RULES_CONST" 'type filter hook input priority -10; policy accept;'
assert_contains "$RULES_CONST" 'ip saddr != 127.0.0.0/8 tcp dport { 8000-8099, 9000-9099, 11000-11099, 13000-13099, 3306 } reject with tcp reset'
assert_contains "$RULES_CONST" 'ip6 saddr != ::1 tcp dport { 8000-8099, 9000-9099, 11000-11099, 13000-13099, 3306 } reject with tcp reset'
assert_eq 2 "$(printf '%s\n' "$RULES_CONST" | grep -c 'tcp dport')" "(two rules, one per family)"
assert_not_contains "$RULES_CONST" 'flush ruleset'
assert_not_contains "$RULES_CONST" 'iifname'

# ---------------------------------------------------------------- no guard for this platform, none for allow-node on Linux
for sub in install remove allow-node status; do
  reset_calls
  FL_PLATFORM=freebsd lg "$sub" --yes </dev/null
  assert_eq 1 "$CODE" "(freebsd $sub) $OUT"
  assert_contains "$OUT" "benchbar lan-guard ${sub} is not available on freebsd" "(freebsd $sub)"
  assert_contains "$OUT" "Nothing was changed"
  assert_calls_not_contain '^(sudo|nft|systemctl|pfctl|launchctl|osascript|socketfilterfw)' "(freebsd $sub)"
done
reset_calls
lg allow-node --yes </dev/null
assert_eq 1 "$CODE" "$OUT"
assert_contains "$OUT" "benchbar lan-guard allow-node is not available on linux"
assert_contains "$OUT" "sudo ufw allow 8443/tcp"
assert_calls_not_contain '^(sudo|nft|systemctl|pfctl|launchctl|osascript|socketfilterfw)'

# ---------------------------------------------------------------- missing: status, dry run
clean
assert_eq "missing True 192.168.1.20 inet benchbar" "$(jstat '" ".join(str(x) for x in (d["state"], d["active"], d["lan_ip"], d["anchor"]))')"
assert_eq "8000:8099 9000:9099 11000:11099 13000:13099 3306" "$(jget "$TMP_DIR/st.json" 'd["ports"]')"
BENCHBAR_NONINTERACTIVE=1 run_fm lan-guard status --json --bench-dir "$BENCH"
assert_eq 0 "$CODE" "(status is never refused, also for an agent) $OUT"

lg install --dry-run
assert_eq 0 "$CODE" "$OUT"
assert_contains "$OUT" "dry-run"; assert_contains "$OUT" "/etc/benchbar/lan-guard.nft"; assert_contains "$OUT" "/etc/systemd/system/benchbar-lan-guard.service"
assert_no_file "$FL_LANGUARD_RULES"; assert_no_file "$FL_LANGUARD_UNIT"
assert_calls_not_contain '^(sudo|nft -|systemctl (daemon|enable|restart))'

# ---------------------------------------------------------------- install, on a terminal: one sudo, both files, loaded
reset_calls
lg_tty install --yes
assert_eq 0 "$CODE" "$OUT"
assert_eq "$(printf '%s\n' "$RULES_CONST" | sed "$squeeze")" "$(sed "$squeeze" "$FL_LANGUARD_RULES")" "(the rules file is the constant)"
assert_contains "$(cat "$FL_LANGUARD_RULES")" "# BenchBar: Frappe bench ports answer this machine only"
assert_contains "$(cat "$FL_LANGUARD_UNIT")" "ExecStart=${FL_NFT} -f /etc/benchbar/lan-guard.nft"
assert_contains "$(cat "$FL_LANGUARD_UNIT")" "ExecStop=-${FL_NFT} delete table inet benchbar"
assert_contains "$(cat "$FL_LANGUARD_UNIT")" "Before=network-pre.target"
assert_contains "$(cat "$FL_LANGUARD_UNIT")" "WantedBy=multi-user.target"
assert_eq 1 "$(grep -c '^sudo -v' "$MOCK_LOG")" "(sudo asked once)"
assert_calls_contain '^sudo /bin/bash -c'
assert_calls_contain "^nft -c -f ${FL_LANGUARD_RULES}.benchbar.new\$"
assert_calls_contain '^systemctl daemon-reload$'
assert_calls_contain '^systemctl enable benchbar-lan-guard.service$'
assert_calls_contain '^systemctl restart benchbar-lan-guard.service$'
[[ "$(grep -n '^sudo -k' "$MOCK_LOG" | tail -n1 | cut -d: -f1)" -gt "$(grep -n '^systemctl restart' "$MOCK_LOG" | tail -n1 | cut -d: -f1)" ]] || fail "sudo -k must come after the root step"
assert_contains "$OUT" "refused on 192.168.1.20"
# the root script holds the literals and the system paths, and names no path of the user or the environment
script="$(calls)"
for p in "$FL_NFT" /usr/bin/systemctl /etc/benchbar/lan-guard.nft /etc/systemd/system/benchbar-lan-guard.service \
  'add table inet benchbar' 'tcp dport { 8000-8099, 9000-9099, 11000-11099, 13000-13099, 3306 }'; do
  assert_contains "$script" "$p" "(root names $p)"
done
for p in "$TMP_DIR" "$HOME" "${TMPDIR:-/tmp}/benchbar"; do
  assert_not_contains "$(grep '^sudo /bin/bash' "$MOCK_LOG" | head -n1)" "$p" "(the first line of the root script names no user path)"
done
assert_eq "installed True" "$(jstat '" ".join(str(x) for x in (d["state"], d["active"]))')"

# ---------------------------------------------------------------- matching: unchanged, no sudo
reset_calls
lg_tty install --yes
assert_eq 0 "$CODE" "$OUT"
assert_contains "$OUT" "unchanged: the guard is installed and matches"
assert_calls_not_contain '^(sudo|nft|systemctl (daemon|enable|restart))'
# only the comment lines and the spacing differ: still unchanged
sed_inplace '/^# BenchBar/d' "$FL_LANGUARD_RULES"
assert_eq installed "$(jstat 'd["state"]')"
# an edited unit or rules file is outdated
cp "$FL_LANGUARD_UNIT" "$TMP_DIR/unit.good"; cp "$FL_LANGUARD_RULES" "$TMP_DIR/rules.good"
for bad in 's#ExecStart=.*#ExecStart=/bin/true#' 's#WantedBy=multi-user.target##' 's#RemainAfterExit=yes##'; do
  cp "$TMP_DIR/unit.good" "$FL_LANGUARD_UNIT"; sed_inplace "$bad" "$FL_LANGUARD_UNIT"
  assert_eq outdated "$(jstat 'd["state"]')" "(unit edited: $bad)"
done
cp "$TMP_DIR/unit.good" "$FL_LANGUARD_UNIT"
for bad in 's/8000-8099/8000-8199/' 's/reject with tcp reset/accept/' 's/ip6 saddr != ::1/ip6 saddr != ::2/'; do
  cp "$TMP_DIR/rules.good" "$FL_LANGUARD_RULES"; sed_inplace "$bad" "$FL_LANGUARD_RULES"
  assert_eq outdated "$(jstat 'd["state"]')" "(rules edited: $bad)"
done
cp "$TMP_DIR/rules.good" "$FL_LANGUARD_RULES"

# ---------------------------------------------------------------- the files match but a bench port answers: loaded again
printf '8097\n18097\n' >"$MOCK_STATE/lan_reachable_ports"
assert_eq "installed False" "$(jstat '" ".join(str(x) for x in (d["state"], d["active"]))')"
lg install --dry-run
assert_eq 0 "$CODE" "$OUT"; assert_contains "$OUT" "not refused"; assert_contains "$OUT" "restart benchbar-lan-guard.service"
assert_calls_not_contain '^(sudo|nft -|systemctl (daemon|enable|restart))'
reset_calls; printf '18097\n' >"$MOCK_STATE/nft_loads"
cp "$FL_LANGUARD_RULES" "$TMP_DIR/rules.before"
# the real unit's ExecStart loads the table; the mock systemctl does not, so the test loads it with the mock nft
lg_tty install --yes
assert_eq 1 "$CODE" "(a reload that does not stop the port answering is a failure) $OUT"; assert_contains "$OUT" "still answer"
assert_calls_contain '^systemctl restart benchbar-lan-guard.service$'
assert_calls_not_contain "^nft -c" "(the files are not rewritten)"
assert_eq "$(cat "$TMP_DIR/rules.before")" "$(cat "$FL_LANGUARD_RULES")"
rm -f "$MOCK_STATE/nft_loads"; printf '18097\n' >"$MOCK_STATE/lan_reachable_ports"
# the probe could not run (the control port does not answer): active is unknown, never false
: >"$MOCK_STATE/lan_reachable_ports"
assert_eq "installed None" "$(jstat '" ".join(str(x) for x in (d["state"], d["active"]))')"
lg_tty install --yes
assert_eq 0 "$CODE" "$OUT"; assert_contains "$OUT" "unchanged"; assert_contains "$OUT" "could not be probed"
printf '18097\n' >"$MOCK_STATE/lan_reachable_ports"

# ---------------------------------------------------------------- an invalid ruleset stops the root script before it moves anything in
clean; touch "$MOCK_STATE/nft_invalid"
lg_tty install --yes
assert_eq 1 "$CODE" "$OUT"; assert_contains "$OUT" "root step failed"
assert_no_file "$FL_LANGUARD_RULES"; assert_no_file "$FL_LANGUARD_UNIT"
assert_calls_not_contain '^systemctl (enable|restart)'
rm -f "$MOCK_STATE/nft_invalid"

# ---------------------------------------------------------------- different ports: outdated, rewritten
clean; lg_tty install --yes
sed_inplace 's/8000-8099/8000-8199/' "$FL_LANGUARD_RULES"
assert_eq outdated "$(jstat 'd["state"]')"
reset_calls
lg_tty install --yes
assert_eq 0 "$CODE" "$OUT"
assert_eq "$(printf '%s\n' "$RULES_CONST" | sed "$squeeze")" "$(sed "$squeeze" "$FL_LANGUARD_RULES")"
assert_calls_contain '^systemctl restart benchbar-lan-guard.service$'

# ---------------------------------------------------------------- refused for an agent and without a terminal, before any sudo
clean
for env in BENCHBAR_NONINTERACTIVE=1 BENCHBAR_NONINTERACTIVE=0; do
  for sub in install remove allow-node; do
    reset_calls
    set +e; OUT="$(env "$env" "$FM" lan-guard "$sub" --yes --bench-dir "$BENCH" </dev/null 2>&1)"; CODE="$?"; set -e
    assert_eq 1 "$CODE" "($env $sub) $OUT"
    assert_contains "$OUT" "benchbar lan-guard ${sub}" "($env $sub names the manual command)"
    assert_calls_not_contain '^(sudo|nft|systemctl (daemon|enable|restart|disable))' "($env $sub)"
  done
done
# BENCHBAR_SUDO=gui is the Mac's dialog: on Linux it is no way in, and --for-agent is refused too
BENCHBAR_SUDO=gui lg install --yes </dev/null
assert_eq 1 "$CODE" "$OUT"; assert_no_file "$FL_LANGUARD_RULES"
BENCHBAR_SUDO=gui run_fm lan-guard install --yes --for-agent --bench-dir "$BENCH"
assert_eq 1 "$CODE" "$OUT"; assert_contains "$OUT" '"exit":1'
assert_no_file "$FL_LANGUARD_RULES"; assert_calls_not_contain '^sudo'
# sudo refused: nothing is changed
touch "$MOCK_STATE/sudo_refused"
lg_tty install --yes
rm -f "$MOCK_STATE/sudo_refused"
assert_eq 1 "$CODE" "$OUT"; assert_no_file "$FL_LANGUARD_RULES"; assert_no_file "$FL_LANGUARD_UNIT"

# ---------------------------------------------------------------- this machine cannot have it: refused before sudo
for why in nft systemd; do
  clean
  if [[ "$why" == nft ]]; then FL_NFT="$TMP_DIR/no-nft" lg_tty install --yes; else FL_LGL_SYSTEMD_DIR="$TMP_DIR/none" lg_tty install --yes; fi
  assert_eq 1 "$CODE" "($why) $OUT"
  if [[ "$why" == nft ]]; then assert_contains "$OUT" "nft (nftables) is not installed"; else assert_contains "$OUT" "systemd is not the init"; fi
  assert_contains "$OUT" "Nothing was changed"
  assert_calls_not_contain '^(sudo|nft|systemctl (daemon|enable|restart))' "($why)"
  assert_no_file "$FL_LANGUARD_RULES"
done

# ---------------------------------------------------------------- remove: asks once, deletes the unit, the table and the files
clean; lg_tty install --yes
assert_eq 0 "$CODE" "$OUT"
printf 'table\n' >"$MOCK_STATE/nft_table"   # the loaded table, as the unit's ExecStart leaves it
reset_calls
lg remove </dev/null
assert_eq 1 "$CODE" "(no --yes and no terminal: not removed) $OUT"
assert_file "$FL_LANGUARD_RULES"; assert_calls_not_contain '^(sudo|nft|systemctl disable)'
lg_tty remove --yes
assert_eq 0 "$CODE" "$OUT"
assert_contains "$OUT" "share start refuses to run"
assert_no_file "$FL_LANGUARD_RULES"; assert_no_file "$FL_LANGUARD_UNIT"; assert_no_file "$MOCK_STATE/nft_table"
assert_eq 1 "$(grep -c '^sudo -v' "$MOCK_LOG")" "(sudo asked once)"
assert_calls_contain '^systemctl disable --now benchbar-lan-guard.service$'
assert_calls_contain '^nft delete table inet benchbar$'
assert_calls_not_contain '^nft (flush|delete (chain|rule)|-f)' "(only this table is deleted)"
assert_eq missing "$(jstat 'd["state"]')"
reset_calls
lg_tty remove --yes
assert_eq 0 "$CODE" "$OUT"; assert_contains "$OUT" "unchanged"; assert_calls_not_contain '^(sudo|nft)'

# ---------------------------------------------------------------- ufw: one line, never changed
clean; lg_tty install --yes
mkdir -p "$MOCK_STATE/units/system"
printf 'LoadState=loaded\nActiveState=active\nMainPID=1\nExecMainStatus=0\nUnitFileState=enabled\n' >"$MOCK_STATE/units/system/ufw.service"
reset_calls
lg status
assert_eq 0 "$CODE" "$OUT"
assert_contains "$OUT" "ufw is active"; assert_contains "$OUT" "sudo ufw allow 8443/tcp"
lg_tty install --yes
assert_contains "$OUT" "ufw is active"
assert_calls_not_contain '^ufw'
assert_calls_not_contain '^sudo'
rm -f "$MOCK_STATE/units/system/ufw.service"
lg status
assert_not_contains "$OUT" "ufw"

# ---------------------------------------------------------------- no LAN address: active is null
rm -f "$MOCK_STATE/lan_iface"
assert_eq "None None" "$(jstat '" ".join(str(x) for x in (d["active"], d["lan_ip"]))')"

printf 'test-lan-guard-linux: ok\n'
