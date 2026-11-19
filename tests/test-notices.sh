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

# stdout alone, for JSON; stderr alone for the notice
fm_out() { set +e; OUT="$("$FM" "$@" 2>/dev/null)"; CODE=$?; set -e; }
fm_err() { set +e; ERR="$("$FM" "$@" 2>&1 >/dev/null)"; CODE=$?; set -e; }
ids() { printf '%s' "$OUT" | jget - '" ".join(n["id"] for n in d["notices"])'; }
# the state of an earlier run: none, or these lines
state_is() { rm -f "$FL_STATE_FILE" "$FL_STATE_DIR/registered-benches.txt"; if [[ "$#" -gt 0 ]]; then printf '%s\n' "$@" >"$FL_STATE_FILE"; fi; }
HEADING="changes some defaults"
ALL="listen-local unknown-flags pull-neutralise"

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
fm_err list
assert_eq 0 "$CODE" "$ERR"
assert_contains "$ERR" "$HEADING"
assert_contains "$ERR" "Switch back: benchbar listen all"
assert_contains "$ERR" "benchbar listen local"
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
run_fm notices --bogus
assert_eq 1 "$CODE" "$OUT"
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

echo "ok"
