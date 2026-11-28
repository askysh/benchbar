#!/usr/bin/env bash
# One time notices after an update (issue 188): a state folder with content and
# no LAST_VERSION is an install of 0.8.3 or older, an empty one is fresh; the
# first human command prints the notices once on stderr; --json, --for-agent
# and BENCHBAR_NONINTERACTIVE never print; status --json carries notices[]
# until `benchbar notices --dismiss ID|--all`.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/work/a/frappe-bench"
make_fake_bench "$BENCH" macdev
printf '127.0.0.1 macdev\n' >>"$FL_HOSTS_FILE"

# stdout alone, for JSON; stderr alone for the notice. The notice prints only to a terminal, so
# fm_err gives stderr a pty (a person at a prompt); fm_err_pipe gives it a pipe (a script's 2>&1)
fm_out() { set +e; OUT="$("$FM" "$@" 2>/dev/null)"; CODE=$?; set -e; }
fm_err_pipe() { set +e; ERR="$("$FM" "$@" 2>&1 >/dev/null)"; CODE=$?; set -e; }
fm_err_with() {
  # fm_err_with BENCHBAR ARGS...: stderr on a pty, stdout dropped; ERR and CODE
  set +e
  ERR="$(python3 -c '
import os, pty, subprocess, sys
master, slave = pty.openpty()
p = subprocess.Popen(sys.argv[1:], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=slave)
os.close(slave)
buf = b""
while True:
    try:
        d = os.read(master, 4096)
    except OSError:
        break
    if not d:
        break
    buf += d
rc = p.wait()
sys.stdout.buffer.write(buf.replace(b"\r\n", b"\n"))
sys.exit(rc)' "$@")"
  CODE=$?
  set -e
}
fm_err() { fm_err_with "$FM" "$@"; }
ids() { printf '%s' "$OUT" | jget - '" ".join(n["id"] for n in d["notices"])'; }
# the state of an earlier run: none, or these lines
state_is() { rm -rf "$FL_STATE_DIR/benches"; rm -f "$FL_STATE_FILE" "$FL_STATE_DIR/registered-benches.txt"; if [[ "$#" -gt 0 ]]; then printf '%s\n' "$@" >"$FL_STATE_FILE"; fi; }
HEADING="changes some defaults"
ALL="listen-local unknown-flags pull-neutralise"
# room-seats is for a person who used rooms: it joins the others only with the lan-rooms Lab on or a share folder

# ---- a fresh install: the first command records the version, nothing to say
state_is
fm_err list
assert_eq 0 "$CODE" "$ERR"
assert_not_contains "$ERR" "$HEADING" "(a fresh install shows no notice)"
assert_no_file "$FL_STATE_FILE" "(a read leaves no state behind)"
# the first run that makes state records the version, and nothing is active
run_fm register "$BENCH"
assert_eq 0 "$CODE" "$OUT"
assert_contains "$(cat "$FL_STATE_FILE")" "LAST_VERSION=" "(the first run records the version)"
assert_not_contains "$(cat "$FL_STATE_FILE")" "NOTICES=" "(a fresh install activates nothing)"
fm_err list
assert_not_contains "$ERR" "$HEADING" "(the run after a fresh install shows no notice)"
fm_out status --json --bench-dir "$BENCH"
assert_eq "[]" "$(printf '%s' "$OUT" | jget - 'd["notices"]')" "(status --json has an empty notices[])"

# ---- a fresh install whose first run writes state and then fails is still fresh, not 0.8.3
# (install writes PIPX_BIN_DIR, BENCH_BIN and RC_FILE before the step that can fail)
state_is
add_proc 900 "mariadbd --datadir=/x"
add_proc 901 "redis-server *:6379"
printf 'mariadb@10.11 started akash file\nredis started akash file\n' >"$MOCK_BREW_SERVICES"
touch "$MOCK_STATE/wkhtml_installed"
mkdir -p "$MOCK_STATE/keychain" "$MOCK_STATE/ps"
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
printf 'rootpw' >"$MOCK_STATE/keychain/benchbar-mariadb--root"
use_mocks_without bench
MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw run_fm install --yes --profile v15-lts
use_all_mocks
assert_eq 1 "$CODE" "(the install fails: there is no bench command)"
assert_contains "$(cat "$FL_STATE_FILE")" "BENCH_BIN=" "(the failed first run made state)"
assert_contains "$(cat "$FL_STATE_FILE")" "LAST_VERSION=" "(and recorded the version)"
fm_err doctor --quick --bench-dir "$BENCH"
assert_not_contains "$ERR" "$HEADING" "(the run after a failed first run shows no notice)"
fm_out status --json --bench-dir "$BENCH"
assert_eq "[]" "$(printf '%s' "$OUT" | jget - 'd["notices"]')" "(no notice is active after a failed first run)"
# a refusal that made no state leaves none
state_is
fm_err list --bench-dir "$TMP_DIR/not-a-bench"
assert_no_file "$FL_STATE_FILE" "(a run that makes no state records nothing)"
fm_out notices --json
assert_eq "[]" "$(printf '%s' "$OUT" | jget - 'd["notices"]')"

# ---- an install of 0.8.3 or older: state with content and no LAST_VERSION
state_is "LABS="
# an agent's first call (status --json) records the change and prints nothing
fm_err status --json --bench-dir "$BENCH"
assert_eq "" "$ERR" "(status --json prints nothing on stderr)"
fm_out status --json --bench-dir "$BENCH"
assert_eq "$ALL" "$(ids)" "(status --json lists the three notices)"
assert_eq "benchbar listen all|BENCHBAR_LENIENT_FLAGS=1|benchbar pull --keep-secrets" "$(printf '%s' "$OUT" | jget - '"|".join(n["switch_back"] for n in d["notices"])')"
assert_contains "$(printf '%s' "$OUT" | jget - 'd["notices"][0]["doc"]')" "/whats-new/#"
assert_contains "$(printf '%s' "$OUT" | jget - 'd["notices"][0]["text"]')" "benchbar listen local"
assert_contains "$(printf '%s' "$OUT" | jget - 'd["notices"][1]["text"]')" "exit 64"
assert_contains "$(printf '%s' "$OUT" | jget - 'd["notices"][2]["title"]')" "neutralises"
# a person, not a script: none of these print
fm_err list --json
assert_not_contains "$ERR" "$HEADING"
fm_err list --for-agent
assert_not_contains "$ERR" "$HEADING"
BENCHBAR_NONINTERACTIVE=1 fm_err list
assert_not_contains "$ERR" "$HEADING"
fm_err notices
assert_not_contains "$ERR" "$HEADING" "(notices names them itself)"
assert_not_contains "$(cat "$FL_STATE_FILE")" "NOTICES_SHOWN" "(nothing was shown yet)"
# the first human command prints them once
# stderr that is not a terminal (a script's 2>&1, cron) prints nothing and does not use up the one print
fm_err_pipe list
assert_eq 0 "$CODE" "$ERR"
assert_not_contains "$ERR" "$HEADING" "(stderr is a pipe: nothing printed)"
assert_not_contains "$(cat "$FL_STATE_FILE")" "NOTICES_SHOWN" "(and not recorded as shown)"
fm_err list
assert_eq 0 "$CODE" "$ERR"
assert_contains "$ERR" "$HEADING"
assert_contains "$ERR" "Switch back: benchbar listen all"
assert_contains "$ERR" "benchbar listen local"
assert_contains "$ERR" "Repair may restart a running bench itself; if it did not, run \`benchbar restart\`"
assert_not_contains "$ERR" "repair\` and then" "(the text says what repair does, as whats-new does)"
assert_contains "$ERR" "Switch back: BENCHBAR_LENIENT_FLAGS=1"
assert_contains "$ERR" "Switch back: benchbar pull --keep-secrets"
assert_contains "$ERR" "/whats-new/#"
assert_contains "$(cat "$FL_STATE_FILE")" "NOTICES_SHOWN=listen-local"
fm_err list
assert_not_contains "$ERR" "$HEADING" "(shown once)"
# shown in the terminal is not dismissed: the app banner still has them
fm_out status --json --bench-dir "$BENCH"
assert_eq "$ALL" "$(ids)"

# ---- dismiss one, then all
fm_out notices --dismiss listen-local --json
assert_eq 0 "$CODE" "$OUT"
assert_eq "unknown-flags pull-neutralise" "$(ids)"
fm_out notices --dismiss=listen-local --json
assert_eq 0 "$CODE" "(an id that is dismissed already is unchanged)"
assert_eq "unknown-flags pull-neutralise" "$(ids)"
run_fm notices --dismiss nonsense
assert_eq 1 "$CODE" "$OUT"
assert_contains "$OUT" "Unknown notice: nonsense"
assert_contains "$OUT" "listen-local, unknown-flags, pull-neutralise"
run_fm notices --dismiss
assert_eq 1 "$CODE" "$OUT"
# an unknown flag is a usage error since 0.9.0 (exit 64)
run_fm notices --bogus
assert_eq 64 "$CODE" "$OUT"
run_fm notices
assert_eq 0 "$CODE" "$OUT"
assert_contains "$OUT" "unknown-flags: An option a command does not take is now an error"
assert_not_contains "$OUT" "listen-local:"
fm_out status --json --bench-dir "$BENCH"
assert_eq "unknown-flags pull-neutralise" "$(ids)"
fm_out notices --all --for-agent
assert_eq 0 "$CODE" "$OUT"
assert_eq "[]" "$(printf '%s' "$OUT" | jget - 'd["notices"]')"
run_fm notices
assert_contains "$OUT" "No notices"
fm_out status --json --bench-dir "$BENCH"
assert_eq "[]" "$(printf '%s' "$OUT" | jget - 'd["notices"]')"

# ---- an update from an older 0.8: the recorded version is below the notices' SINCE
state_is "LAST_VERSION=0.8.2"
fm_out notices --json
assert_eq "$ALL" "$(ids)"
assert_contains "$(cat "$FL_STATE_FILE")" "LAST_VERSION=0.8.3"
# the same version again changes nothing: no write, no new notice after a dismissal
fm_out notices --all --json
cp "$FL_STATE_FILE" "$TMP_DIR/state.before"
fm_out notices --json
fm_err list
assert_not_contains "$ERR" "$HEADING"
assert_eq "$(cat "$TMP_DIR/state.before")" "$(cat "$FL_STATE_FILE")" "(a run of the same version writes nothing)"
# a version that is already at or above SINCE has nothing to say
state_is "LAST_VERSION=0.9.0"
fm_out notices --json
assert_eq "" "$(ids)" "(coming from 0.9.0 nothing is new)"

# ---- two CLIs of different versions share the state folder (the app's and a Homebrew one):
# a recorded version that is newer than the running one is left alone: no write, no notice
state_is "LAST_VERSION=0.9.1" "NOTICES=unknown-flags"
cp "$FL_STATE_FILE" "$TMP_DIR/state.before"
fm_out notices --json
assert_eq "unknown-flags" "$(ids)" "(a newer recorded version keeps the notices as they are)"
fm_out status --json --bench-dir "$BENCH"
fm_out list
assert_eq "$(cat "$TMP_DIR/state.before")" "$(cat "$FL_STATE_FILE")" "(an older CLI next to a newer one writes nothing)"
state_is "LAST_VERSION=0.9.0"
cp "$FL_STATE_FILE" "$TMP_DIR/state.before"
fm_out notices --json
assert_eq "$(cat "$TMP_DIR/state.before")" "$(cat "$FL_STATE_FILE")" "(the dev tree 0.8.3 next to a recorded 0.9.0 writes nothing)"

# ---- a prerelease: SINCE is compared without it (0.9.0-rc.1 counts as 0.9.0)
tree() {
  mkdir -p "$1"
  cp -R "$ROOT/benchbar" "$ROOT/00-mac-system-deps.sh" "$ROOT/01-install-bench-and-site.sh" \
    "$ROOT/02-background-service.sh" "$ROOT/lib" "$ROOT/templates" "$ROOT/config" "$1/"
  sed_inplace "s/^FL_VERSION=\".*\"\$/FL_VERSION=\"$2\"/" "$1/benchbar"
  chmod +x "$1/benchbar"
}
tree "$TMP_DIR/rc" "0.9.0-rc.1"
tree "$TMP_DIR/final" "0.9.0"
# 0.8.3 to 0.9.0-rc.1 activates the notices
state_is "LAST_VERSION=0.8.3"
set +e; OUT="$("$TMP_DIR/rc/benchbar" notices --json 2>/dev/null)"; CODE=$?; set -e
assert_eq 0 "$CODE" "$OUT"
assert_eq "$ALL" "$(ids)" "(0.8.3 to 0.9.0-rc.1 activates the notices)"
assert_contains "$(cat "$FL_STATE_FILE")" "LAST_VERSION=0.9.0-rc.1"
# 0.9.0-rc.1 to 0.9.0 adds nothing, not even after a dismissal
set +e; OUT="$("$TMP_DIR/rc/benchbar" notices --all --json 2>/dev/null)"; set -e
set +e; OUT="$("$TMP_DIR/final/benchbar" notices --json 2>/dev/null)"; CODE=$?; set -e
assert_eq 0 "$CODE" "$OUT"
assert_eq "" "$(ids)" "(0.9.0-rc.1 to 0.9.0 brings no dismissed notice back)"
assert_contains "$(cat "$FL_STATE_FILE")" "LAST_VERSION=0.9.0" "(the final release is recorded)"
assert_not_contains "$(cat "$FL_STATE_FILE")" "rc.1"
# the rc next to a recorded 0.9.0 writes nothing (the rc is older)
cp "$FL_STATE_FILE" "$TMP_DIR/state.before"
set +e; OUT="$("$TMP_DIR/rc/benchbar" notices --json 2>/dev/null)"; set -e
assert_eq "$(cat "$TMP_DIR/state.before")" "$(cat "$FL_STATE_FILE")" "(0.9.0-rc.1 next to a recorded 0.9.0 writes nothing)"

# ---- the registered benches alone make an old install
state_is
printf '%s\n' "$BENCH" >"$FL_STATE_DIR/registered-benches.txt"
fm_out notices --json
assert_eq "$ALL" "$(ids)" "(registered-benches.txt is an earlier run)"
state_is

# ---- a dry run changes nothing
state_is "LABS="
fm_err list --dry-run
assert_not_contains "$ERR" "$HEADING"
assert_not_contains "$(cat "$FL_STATE_FILE")" "LAST_VERSION"

# ---- the app's fixture (macos/BenchBarTests/Fixtures/status-notices.json) has the keys the CLI prints
state_is "LAST_VERSION=0.8.2"
fm_out status --json --bench-dir "$BENCH"
printf '%s' "$OUT" | python3 -c '
import json, sys
live = json.load(sys.stdin); fixture = json.load(open(sys.argv[1]))
assert set(fixture["notices"][0]) <= set(live["notices"][0]), set(fixture["notices"][0]) - set(live["notices"][0])
assert set(fixture["notices"][0]) >= set(live["notices"][0]), "the CLI prints a notice field the fixture lacks"
assert [n["id"] for n in fixture["notices"]] == [n["id"] for n in live["notices"]]
assert "notices" in live
' "$ROOT/macos/BenchBarTests/Fixtures/status-notices.json" || fail "status --json notices[] and the app fixture disagree"

# ---- the command is in the table (commands --json)
fm_out commands --json
assert_eq "benchbar notices [--json] [--dismiss ID|--all]" "$(printf '%s' "$OUT" | jget - '[c["usage"] for c in d["commands"] if c["name"] == "notices"][0]')"

# ---- room-seats: only for a host of rooms (the lan-rooms Lab is on, or sharing was set up)
state_is "LABS="
fm_out status --json --bench-dir "$BENCH"
assert_eq "$ALL" "$(ids)" "(never used rooms: no room notice)"
state_is "LABS="; mkdir -p "$FL_STATE_DIR/share"
fm_out status --json --bench-dir "$BENCH"
assert_eq "$ALL room-seats" "$(ids)" "(sharing was set up: the room notice too)"
fm_out notices --json
assert_contains "$OUT" "benchbar share start --open-seats"
rmdir "$FL_STATE_DIR/share"
state_is "LABS=lan-rooms"
fm_out status --json --bench-dir "$BENCH"
assert_eq "$ALL room-seats" "$(ids)" "(the Lab is on: the room notice too)"

echo "ok"
