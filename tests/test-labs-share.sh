#!/usr/bin/env bash
# The lan-rooms lab and the share commands: refused while the lab is off (exit 2 with the hint), listed
# under "gated" in commands --json and absent from --help, present with BENCHBAR_LABS=lan-rooms, and
# `labs off lan-rooms` stopping a running share and naming lan-guard's removal without sudo.
# shellcheck disable=SC2016
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# a person turns labs on: the harness is the app's run (BENCHBAR_NONINTERACTIVE=0 with the app tree), tests/test-person-guard.sh covers the refusals
export BENCHBAR_NONINTERACTIVE=0
BENCH="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH" macdev
export MOCK_ENV_PYTHON="$ROOT/tests/mocks/env-python"
PF_DIR="$TMP_DIR/pf"; mkdir -p "$PF_DIR"
export FL_LANGUARD_ANCHOR="$PF_DIR/com.benchbar.lan" FL_LANGUARD_DAEMON="$PF_DIR/com.benchbar.pf.plist"
unset BENCHBAR_LABS
fm_out() { set +e; OUT="$("$FM" "$@" 2>/dev/null)"; CODE=$?; set -e; }

# ---- off: refused, hinted, hidden
for c in "share people" "share setup" "share start" "share code" "lan-guard install" "lan-guard allow-node"; do
  # shellcheck disable=SC2086
  run_fm $c --bench-dir "$BENCH"
  assert_eq "2" "$CODE" "$c: $OUT"
  assert_contains "$OUT" "is an experiment and it is off."
  assert_contains "$OUT" "benchbar labs on lan-rooms"
done
run_fm share people --json --bench-dir "$BENCH"
assert_eq "2" "$CODE" "$OUT"
# a stream command is refused by the gate (a done line, exit 2), not by the preflight (exit 1)
# that wants a person at a terminal; one valid JSON line and no MariaDB hint
set +e
OUT="$(BENCHBAR_NONINTERACTIVE=1 "$FM" share start --json --bench-dir "$BENCH" 2>/dev/null)"; CODE=$?
set -e
assert_eq "2" "$CODE" "$OUT"
assert_eq "done 2 True" "$(printf '%s' "$OUT" | jget - 'd["event"], d["exit"], "experiment" in d["error"]' | tr -d "',()" )"
assert_not_contains "$OUT" "MARIADB"
run_fm --help
assert_not_contains "$OUT" "  share "
assert_not_contains "$OUT" "lan-guard"
fm_out commands --json
assert_eq "['share', 'lan-guard']" "$(printf '%s' "$OUT" | jget - '[g["name"] for g in d["gated"]]')"
assert_eq "[]" "$(printf '%s' "$OUT" | jget - '[c["name"] for c in d["commands"] if c["name"].split()[0] in ("share", "lan-guard")]')"

# ---- off: what stops, removes or reports the experiment still runs, so that an experiment that is
# off can always be undone (#159 SHARE-2). Nothing was started here, so each one is a quiet no-op.
# teardown is a person's command: the app's run (a person clicked) passes, with nothing set up to tear down
BENCHBAR_SUDO=gui run_fm share teardown --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "unchanged: sharing is not set up"
for c in "share status" "share stop" "lan-guard status"; do
  # shellcheck disable=SC2086
  run_fm $c --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$c: $OUT"
  assert_not_contains "$OUT" "is an experiment"
done
# (share stop leaves its stop marker for a start on its way; the doctor cases below want no share folder)
rm -rf "$FL_STATE_DIR/share"
fm_out share status --json --bench-dir "$BENCH"
assert_eq "0 off" "$CODE $(printf '%s' "$OUT" | jget - 'd["state"]')"
fm_out lan-guard status --json --bench-dir "$BENCH"
assert_eq "0 missing" "$CODE $(printf '%s' "$OUT" | jget - 'd["state"]')"
# their help is shown too, and the refusal of the others names the way out
run_fm lan-guard remove --help
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "benchbar lan-guard remove"; assert_not_contains "$OUT" "is an experiment"
run_fm share setup --help
assert_eq "2" "$CODE" "$OUT"
# a flag before the subcommand does not hide it from the gate or from the help (review note 5)
run_fm share --json stop --help
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "benchbar share stop"; assert_not_contains "$OUT" "is an experiment"
run_fm share --json setup --help
assert_eq "2" "$CODE" "$OUT"

# ---- on: listed, not gated, runs
BENCHBAR_LABS=lan-rooms fm_out commands --json
assert_eq "[]" "$(printf '%s' "$OUT" | jget - 'd["gated"]')"
assert_contains "$(printf '%s' "$OUT" | jget - '[c["name"] for c in d["commands"]]')" "share status"
BENCHBAR_LABS=lan-rooms run_fm --help
assert_contains "$OUT" "share"
BENCHBAR_LABS=lan-rooms fm_out share status --json --bench-dir "$BENCH"
assert_eq "0" "$CODE"; assert_eq "off" "$(printf '%s' "$OUT" | jget - 'd["state"]')"

# ---- doctor: the share check runs only with the lab on or a share state folder
fm_out doctor --json --bench-dir "$BENCH"
assert_not_contains "$OUT" '"share_scheduler"'
BENCHBAR_LABS=lan-rooms fm_out doctor --json --bench-dir "$BENCH"
assert_contains "$OUT" '"share_scheduler"'
mkdir -p "$FL_STATE_DIR/share"
fm_out doctor --json --bench-dir "$BENCH"
assert_contains "$OUT" '"share_scheduler"'

# ---- off with a running share and lan-guard installed: stop runs, the warning names the removal
run_fm labs on lan-rooms --yes
assert_eq "0" "$CODE" "$OUT"
printf '<plist/>\n' >"$FL_STATE_DIR/share/job.plist"
printf '123 running\n' >"$FL_STATE_DIR/share/phase"
printf '# BenchBar: Frappe bench ports answer this Mac only\n' >"$FL_LANGUARD_ANCHOR"; : >"$FL_LANGUARD_DAEMON"
# and a node that lan-guard allow-node put on the firewall's list
mkdir -p "$FL_STATE_DIR/lan-guard"; printf '/opt/homebrew/Cellar/node/22/bin/node\n' >"$FL_STATE_DIR/lan-guard/firewall.allowed"
: >"$MOCK_LOG"
BENCHBAR_NONINTERACTIVE=1 fm_out labs off lan-rooms --json
assert_eq "0" "$CODE" "$OUT"
assert_no_file "$FL_STATE_DIR/share/job.plist"; assert_no_file "$FL_STATE_DIR/share/phase"
assert_contains "$(printf '%s' "$OUT" | jget - 'd["warnings"]')" "run: benchbar lan-guard remove"
assert_contains "$(printf '%s' "$OUT" | jget - 'd["warnings"]')" "the macOS firewall still allows node"
assert_calls_not_contain '^sudo'
assert_calls_not_contain '^osascript'
assert_not_contains "$(cat "$FL_STATE_FILE")" "lan-rooms"
# the command the warning names runs with the lab off: one dialog, both root files gone
export FL_OSASCRIPT="$ROOT/tests/mocks/osascript-gui" FL_SOCKETFILTERFW="$ROOT/tests/mocks/bin/socketfilterfw"
: >"$MOCK_LOG"
BENCHBAR_SUDO=gui run_fm lan-guard remove --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_no_file "$FL_LANGUARD_ANCHOR"; assert_no_file "$FL_LANGUARD_DAEMON"; assert_no_file "$FL_STATE_DIR/lan-guard/firewall.allowed"
assert_calls_contain '^pfctl -a com.apple/250.benchbar -F all$'
assert_calls_contain '^socketfilterfw --remove /opt/homebrew/Cellar/node/22/bin/node$'
# a share job that is still loaded while the lab is off (an app and a CLI that disagree) can be stopped
mkdir -p "$FL_STATE_DIR/share"
printf '<plist/>\n' >"$FL_STATE_DIR/share/job.plist"
printf '123 running\n' >"$FL_STATE_DIR/share/phase"
run_fm share stop --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_no_file "$FL_STATE_DIR/share/job.plist"; assert_no_file "$FL_STATE_DIR/share/phase"

# ---- off with nothing started and no lan-guard: quiet
rm -f "$FL_LANGUARD_ANCHOR" "$FL_LANGUARD_DAEMON"
rm -rf "$FL_STATE_DIR/share"
run_fm labs on lan-rooms --yes
fm_out labs off lan-rooms --json
assert_eq "0" "$CODE" "$OUT"
assert_eq "[]" "$(printf '%s' "$OUT" | jget - 'd["warnings"]')"
echo "test-labs-share: ok"
