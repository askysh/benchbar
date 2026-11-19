#!/usr/bin/env bash
# benchbar share on Linux: the sharing job is a systemd --user unit in the runtime folder (not launchd), the
# runner advertises with avahi-publish when it is installed and says so when it is not, names a port's owner
# with ss, and has no sleep inhibitor; the host label is the host name; share status reads the nftables
# guard; the lan-rooms lab lists Linux. The runner's own behaviour against its stand-ins is tests/test-share-run.sh
# (macOS); here its Linux-only branches are cut out of the rendered file and run, and the file is run as far as
# its first step. No node, no bench and no network is needed. Nothing here touches this machine's systemd.
# shellcheck disable=SC2016  # bash -c bodies are meant to stay literal
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
use_linux
export BENCHBAR_LABS=lan-rooms

BENCH="$HOME/frappe-bench"
make_fake_bench "$BENCH" linuxdev.localhost

# ---------------------------------------------------------------- the lab lists Linux (and so WSL), with no test seam
run_fm labs list --json
assert_eq 0 "$CODE" "$OUT"
assert_eq "('macos,linux', True)" "$(printf '%s' "$OUT" | jget - '[(",".join(l["platforms"]), l["available"]) for l in d["labs"] if l["name"] == "lan-rooms"][0]')" "(lan-rooms: platforms and availability)"

# ---------------------------------------------------------------- share is reached, and refused for the right reason
run_fm share start --bench-dir "$BENCH" </dev/null
assert_eq 1 "$CODE" "$OUT"
assert_not_contains "$OUT" "needs macOS"; assert_contains "$OUT" "person"
run_fm share status --json --bench-dir "$BENCH"
assert_eq 0 "$CODE" "$OUT"
assert_contains "$OUT" '"state":"off"'
assert_contains "$OUT" '"lan_guard":"missing"' "(status reads the nftables guard, not the pf files)"
run_fm share stop --bench-dir "$BENCH"
assert_eq 0 "$CODE" "(stop is never refused) $OUT"; assert_contains "$OUT" "unchanged: sharing was not on"

# ---------------------------------------------------------------- the job, through the library
export XDG_RUNTIME_DIR="$TMP_DIR/run-user"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
export HOSTNAME=lab-pc.example
LIB="$ROOT/lib/frappe-local"
for f in ui run templates platform platform-linux systemd share-site share-preflight share-run lan-guard-linux share-linux; do
  # shellcheck disable=SC1090
  . "$LIB/$f.sh"
done
FL_SELF="$ROOT/benchbar"; FL_SELF_DIR="$ROOT"
UNIT=benchbar-share-gateway.service
SHARE="$TMP_DIR/share"; mkdir -p "$SHARE"

assert_eq "$UNIT" "$(fl_share_job_target)"
assert_eq systemd "$(fl_share_job_manager)"
assert_eq "systemctl --user stop $UNIT" "$(fl_share_job_bootout_hint)"
assert_eq lab-pc "$(fl_share_computer_name)" "(the host name, without its domain)"

text="$(fl_share_job_text "$SHARE")"
assert_contains "$text" "benchbar-template: share.service v1 "
assert_contains "$text" "ExecStart=/bin/bash \"${SHARE}/share-run.sh\""
assert_contains "$text" "WorkingDirectory=${SHARE}"
assert_contains "$text" "ExecStopPost=-/bin/rm -f \"${XDG_RUNTIME_DIR}/systemd/user/${UNIT}\""
for want in 'Restart=no' 'KillMode=mixed' 'UMask=0077' 'CollectMode=inactive-or-failed' "StandardOutput=append:${SHARE}/share.log"; do
  assert_contains "$text" "$want"
done
assert_not_contains "$text" "[Install]" "(it is never enabled: a reboot forgets it)"
assert_not_contains "$text" "__" "(every value is filled in)"
assert_not_contains "$text" "$HOME/.config" "(nothing in the bench unit's folder)"

# start: the file lands in the runtime folder, systemd reads it, the unit starts
printf '%s\n' "$text" >"$SHARE/job.plist"
reset_calls
fl_share_job_loaded && fail "the job is loaded before it was started"
fl_share_job_start "$SHARE/job.plist"
assert_file "$XDG_RUNTIME_DIR/systemd/user/$UNIT"
assert_no_file "$HOME/.config/systemd/user/$UNIT"
assert_eq 700 "$(stat -c %a "$XDG_RUNTIME_DIR/systemd/user" 2>/dev/null || stat -f %Lp "$XDG_RUNTIME_DIR/systemd/user")" "(the folder is private)"
assert_calls_contain '^systemctl --user daemon-reload$'
assert_calls_contain "^systemctl --user start ${UNIT}\$"
fl_share_job_loaded || fail "the job is not loaded after the start"
assert_calls_not_contain '^(sudo|launchctl)'
# stop: the unit stops, its file goes, nothing is listed
reset_calls
fl_share_job_stop
assert_calls_contain "^systemctl --user stop ${UNIT}\$"
assert_no_file "$XDG_RUNTIME_DIR/systemd/user/$UNIT"
fl_share_job_loaded && fail "the job is still loaded after the stop"
# a stop that leaves the unit running is reported, so the caller does not say "stopped"
fl_share_job_start "$SHARE/job.plist"
MOCK_STOP_STUCK=1 fl_share_job_stop && fail "a stuck stop was reported as done"
fl_share_job_stop
# no user session folder: a clear failure, nothing written
reset_calls
XDG_RUNTIME_DIR="$TMP_DIR/no-such-run" fl_share_job_start "$SHARE/job.plist" >/dev/null 2>&1 && fail "a start with no user session folder reported success"
assert_calls_not_contain '^systemctl --user start'
# the user manager refuses: the unit file is taken out again
touch "$MOCK_STATE/user_manager_down"
fl_share_job_start "$SHARE/job.plist" >/dev/null 2>&1 && fail "a start with no user manager reported success"
rm -f "$MOCK_STATE/user_manager_down"
assert_no_file "$XDG_RUNTIME_DIR/systemd/user/$UNIT"

# ---------------------------------------------------------------- the tools the runner gets
assert_eq "/some/avahi-publish" "$(FL_SHARE_DNS_SD=/some/avahi-publish fl_share_dns_sd_bin)"
assert_eq "" "$(FL_SHARE_DNS_SD="" fl_share_dns_sd_bin)" "(set and empty: no advertiser)"
assert_eq "" "$(fl_share_caffeinate_bin)" "(no sleep inhibitor)"
assert_eq "/some/ss" "$(FL_SHARE_LSOF=/some/ss fl_share_lsof_bin)"
case "$(fl_share_lsof_bin)" in */ss) ;; *) fail "lsof is not ss on Linux: $(fl_share_lsof_bin)" ;; esac
note="$(FL_SHARE_DNS_SD="" fl_share_start_note 2>&1)"
assert_contains "$note" "avahi-publish is not installed"; assert_contains "$note" "address and the code"
assert_eq "" "$(FL_SHARE_DNS_SD=/some/avahi-publish fl_share_start_note 2>&1)" "(nothing said when there is an advertiser)"

# ---------------------------------------------------------------- the runner, rendered for Linux
render_runner() { # DNS_SD CAFFEINATE LSOF
  fl_template_render share-run.sh "SHARE_DIR=${SHARE}" "SOCK=${SHARE}/control.sock" "BENCH=${BENCH}" "SHARE_SITE=share.localhost" "WEB_PORT=8001" \
    "GATEWAY_PORT=8443" "PYTHON=${BENCH}/env/bin/python" "LIB=${LIB}" "NODE=/n/node" "BENCHBAR=${ROOT}/benchbar" "DNS_SD=$1" \
    "CAFFEINATE=$2" "LSOF=$3" "CURL=/usr/bin/curl" "WIPE_SECS=8" "LISTEN_SECS=60" "SOCK_SECS=15" "WARM_SECS=30" \
    "SESSIONS_PY=print(1)" "CONTROL_JS=1;" "SITE_LABEL=linuxdev" "ROOM_LABEL=Lab one"
}
render_runner /usr/bin/avahi-publish "" /usr/bin/ss >"$TMP_DIR/runner.sh"
bash -n "$TMP_DIR/runner.sh" || fail "the runner does not parse"
runner="$(cat "$TMP_DIR/runner.sh")"
assert_contains "$runner" "benchbar-template: share-run.sh v8 "
assert_not_contains "$runner" "__" "(every value is filled in)"
assert_contains "$runner" 'DNS_SD="/usr/bin/avahi-publish"'; assert_contains "$runner" 'CAFFEINATE=""'; assert_contains "$runner" 'LSOF="/usr/bin/ss"'
# no gateway.json: the runner ends with 78 before it starts anything
rm -f "$SHARE/gateway.json"
set +e; bash "$TMP_DIR/runner.sh" >"$TMP_DIR/runner.out" 2>&1; code=$?; set -e
assert_eq 78 "$code" "$(cat "$TMP_DIR/runner.out")"

# the branches of the runner that are Linux's, cut out of the file and run against stand-ins
cut_fn() { sed -n "/^$1()/,/^}/p" "$TMP_DIR/runner.sh"; }
say() { printf 'say: %s\n' "$*" >>"$TMP_DIR/say.log"; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
eval "$(cut_fn web_owns_port)"; eval "$(cut_fn start_dns)"; eval "$(cut_fn start_caffeinate)"
# ss names the owner of the web port: the web's own PID is the owner, another PID is not
WEB_PORT=8001; LSOF="$ROOT/tests/mocks/bin/ss"; WEB_PID="$$"
printf '8001 %s python 127.0.0.1\n' "$$" >"$MOCK_LISTEN"
web_owns_port || fail "ss: the web's own PID holds the port, web_owns_port said no"
printf '8001 1 python 127.0.0.1\n' >"$MOCK_LISTEN"
web_owns_port && fail "ss: another PID holds the port, web_owns_port said yes"
: >"$MOCK_LISTEN"
web_owns_port && fail "ss: nothing listens, web_owns_port said yes"
assert_calls_contain '^ss -Hltnp sport = :8001$'
# avahi-publish: its own arguments (a name, a type and a port, no domain), output silenced
cat >"$TMP_DIR/avahi-publish" <<'SH'
#!/bin/bash
printf 'avahi-publish %s\n' "$*" >>"$MOCK_STATE/order"
exit 0
SH
chmod +x "$TMP_DIR/avahi-publish"
DNS_SD="$TMP_DIR/avahi-publish"; ROOM_LABEL="Lab one"; GATEWAY_PORT=8443; SITE_LABEL=linuxdev; polls=0; DNS_PID=""
start_dns
wait "$DNS_PID" 2>/dev/null || true
assert_contains "$(cat "$MOCK_STATE/order")" 'avahi-publish -s Lab one _benchbar-share._tcp 8443 v=3 label=Lab one site=linuxdev'
assert_not_contains "$(cat "$MOCK_STATE/order")" " local "
# no advertiser: nothing starts, it is said once and never again, and it is not a failure
DNS_SD=""; DNS_PID=""; : >"$TMP_DIR/say.log"
start_dns; start_dns again; start_dns again
assert_eq "" "$DNS_PID"
assert_eq 1 "$(grep -c 'not listed on the network' "$TMP_DIR/say.log")" "(said once)"
# no sleep inhibitor: nothing starts
CAFFEINATE=""; CAF_PID=""
start_caffeinate; start_caffeinate again
assert_eq "" "$CAF_PID"

# ---------------------------------------------------------------- the checks that were the Mac's
fl_sp_reset
SP_NODE_REAL="/n/node"
fl_sp_firewall
assert_eq "firewall_node skip" "${SP_ID[0]} ${SP_STATUS[0]}"
assert_contains "${SP_MSG[0]}" "sudo ufw allow 8443/tcp"

# ---------------------------------------------------------------- WSL: a room needs mirrored networking
# the mode, read as wslinfo prints it; no wslinfo (a WSL with no mirrored mode) is NAT; outside WSL there is none
fl_sp_wsl_net_v m; assert_eq mirrored "$m" "(the mock's default)"
MOCK_WSL_NETMODE=nat fl_sp_wsl_net_v m; assert_eq nat "$m"
MOCK_WSL_NETMODE=Mirrored fl_sp_wsl_net_v m; assert_eq mirrored "$m" "(case does not matter)"
MOCK_WSL_NETMODE=bridged fl_sp_wsl_net_v m; assert_eq mirrored "$m" "(the VM has an address on the Wi-Fi)"
MOCK_WSL_NETMODE=virtioproxy fl_sp_wsl_net_v m; assert_eq nat "$m"
MOCK_WSL_NETMODE=none fl_sp_wsl_net_v m; assert_eq nat "$m"
FL_WSLINFO="$TMP_DIR/no-wslinfo" fl_sp_wsl_net_v m; assert_eq nat "$m" "(wslinfo is absent)"
FL_WSLINFO="" fl_sp_wsl_net_v m; assert_eq nat "$m" "(wslinfo is set and empty)"
WSL_PROC_VERSION="$(cat "$FL_PROC_VERSION")"
printf 'Linux version 6.8.0-generic (buildd@lcy02) #1 SMP\n' >"$FL_PROC_VERSION"
MOCK_WSL_NETMODE=nat fl_sp_wsl_net_v m; assert_eq "" "$m" "(not WSL: no mode, and nothing is asked)"
code=0; out="$( (export MOCK_WSL_NETMODE=nat; fl_share_wsl_gate warn) 2>&1 )" || code=$?
assert_eq 0 "$code" "$out"; assert_eq "" "$out" "(a real Linux PC is never stopped or warned)"
printf '%s\n' "$WSL_PROC_VERSION" >"$FL_PROC_VERSION"

fl_sp_wsl_rule_v rule
assert_eq "New-NetFirewallHyperVRule -Name BenchBarRoom -DisplayName \"BenchBar room\" -Direction Inbound -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Protocol TCP -LocalPorts 8443" "$rule"

# the gate: NAT stops with what NAT means and how to switch; mirrored warns with the rule; invite (no "warn") is quiet on mirrored
code=0; out="$( (export MOCK_WSL_NETMODE=nat; fl_share_wsl_gate warn) 2>&1 )" || code=$?
assert_eq 1 "$code" "$out"
assert_contains "$out" "NAT networking"; assert_contains "$out" "not available on WSL NAT"
assert_contains "$out" "networkingMode=mirrored"; assert_contains "$out" ".wslconfig"; assert_contains "$out" "wsl.exe --shutdown"
code=0; out="$( (export MOCK_WSL_NETMODE=nat; fl_share_wsl_gate) 2>&1 )" || code=$?
assert_eq 1 "$code" "(invite stops on NAT too) $out"
code=0; out="$( (export MOCK_WSL_NETMODE=mirrored; fl_share_wsl_gate warn) 2>&1 )" || code=$?
assert_eq 0 "$code" "$out"
assert_contains "$out" "New-NetFirewallHyperVRule"; assert_contains "$out" "-LocalPorts 8443"; assert_contains "$out" "administrator"
code=0; out="$( (export MOCK_WSL_NETMODE=mirrored; fl_share_wsl_gate) 2>&1 )" || code=$?
assert_eq 0 "$code" "$out"; assert_eq "" "$out" "(invite does not repeat the warning)"

# share preflight: a failing check on NAT, a warning with the rule on mirrored, none outside WSL
wsl_check() { printf '%s\n' "$OUT" | grep '^{' | jget - "[c[\"$1\"] for c in d[\"checks\"] if c[\"id\"] == \"wsl_networking\"][0]"; }
MOCK_WSL_NETMODE=nat run_fm share preflight --static --json --bench-dir "$BENCH"
assert_eq 1 "$CODE" "$OUT"
assert_eq fail "$(wsl_check status)"; assert_eq static "$(wsl_check class)"
assert_contains "$(wsl_check message)" "not available on WSL NAT"; assert_contains "$(wsl_check fix)" "networkingMode=mirrored"
MOCK_WSL_NETMODE=mirrored run_fm share preflight --static --json --bench-dir "$BENCH"
assert_eq warn "$(wsl_check status)"; assert_contains "$(wsl_check fix)" "New-NetFirewallHyperVRule"
assert_contains "$(wsl_check rule)" "-LocalPorts 8443"
assert_contains "$(wsl_check message)" "mirrored networking"
MOCK_WSL_NETMODE=nat run_fm share preflight --static --bench-dir "$BENCH"
assert_contains "$OUT" "wsl_networking: WSL uses NAT networking"
assert_contains "$OUT" "networkingMode=mirrored"
FL_WSLINFO="$TMP_DIR/no-wslinfo" run_fm share preflight --static --json --bench-dir "$BENCH"
assert_eq fail "$(wsl_check status)" "(no wslinfo counts as NAT)"
# the check is only for WSL: a native Linux run has none
printf 'Linux version 6.8.0-generic (buildd@lcy02) #1 SMP\n' >"$FL_PROC_VERSION"
MOCK_WSL_NETMODE=nat run_fm share preflight --static --json --bench-dir "$BENCH"
assert_eq "[]" "$(printf '%s\n' "$OUT" | grep '^{' | jget - '[c["id"] for c in d["checks"] if c["id"] == "wsl_networking"]')"
printf '%s\n' "$WSL_PROC_VERSION" >"$FL_PROC_VERSION"

# share start: a copy that is set up, so the first refusal is the network. NAT stops, even for --dry-run, before
# a plan is printed or a thing is written; mirrored warns and goes on to the next step
mkdir -p "$FL_STATE_DIR/share" "$BENCH/sites/share.localhost"
printf '{\n  "v": 3,\n  "room_label": "Lab room"\n}\n' >"$FL_STATE_DIR/share/share.json"
printf '{}\n' >"$BENCH/sites/share.localhost/site_config.json"
BENCHBAR_SUDO=gui MOCK_WSL_NETMODE=nat run_fm share start --dry-run --bench-dir "$BENCH" </dev/null
assert_eq 1 "$CODE" "$OUT"
assert_contains "$OUT" "not available on WSL NAT"; assert_contains "$OUT" "networkingMode=mirrored"
assert_not_contains "$OUT" "Share start" "(no plan is printed)"
BENCHBAR_SUDO=gui FL_WSLINFO="$TMP_DIR/no-wslinfo" run_fm share start --bench-dir "$BENCH" </dev/null
assert_eq 1 "$CODE" "$OUT"; assert_contains "$OUT" "not available on WSL NAT" "(no wslinfo: NAT)"
BENCHBAR_SUDO=gui MOCK_WSL_NETMODE=mirrored run_fm share start --dry-run --bench-dir "$BENCH" </dev/null
assert_not_contains "$OUT" "not available on WSL NAT"
assert_contains "$OUT" "New-NetFirewallHyperVRule"; assert_contains "$OUT" "-LocalPorts 8443"

printf 'test-share-linux: ok\n'
