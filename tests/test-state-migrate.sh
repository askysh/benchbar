#!/usr/bin/env bash
# The one time move of the installer checkout's state folder
# (~/.local/share/benchbar/.benchbar) to ~/.local/state/benchbar when
# BenchBar.app made bin/benchbar in the new folder before the first CLI run;
# three first runs at once, serialized by the guard; a guard a live run
# holds, and a stale one; and where's view of a state folder behind a link
# (the cross volume layout).
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

APPS="$TMP_DIR/Applications"
APP="$APPS/BenchBar.app"
APP_CLI_DIR="$APP/Contents/Resources/cli"
BASE="$HOME/.local/state"
NEW="$BASE/benchbar"
LINK="$NEW/bin/benchbar"
GUARD="$BASE/.benchbar-migrating"
MH="$HOME/.local/share/benchbar"
LEGACY="$MH/.benchbar"
export FL_APP_DIRS="$APPS"

# tree DIR VERSION: the CLI's files, copied, with FL_VERSION set to VERSION
tree() {
  mkdir -p "$1"
  cp -R "$ROOT/benchbar" "$ROOT/00-mac-system-deps.sh" "$ROOT/01-install-bench-and-site.sh" \
    "$ROOT/02-background-service.sh" "$ROOT/lib" "$ROOT/templates" "$ROOT/config" "$1/"
  sed_inplace "s/^FL_VERSION=\".*\"\$/FL_VERSION=\"$2\"/" "$1/benchbar"
  chmod +x "$1/benchbar"
}
tree "$APP_CLI_DIR" 0.7.3
printf '<plist><dict>\n<key>CFBundleShortVersionString</key>\n<string>0.7.3</string>\n</dict></plist>\n' >"$APP/Contents/Info.plist"
# register: the link BenchBar.app makes at launch, before any CLI run
register() { mkdir -p "${LINK%/*}"; ln -sfn "$APP_CLI_DIR/benchbar" "$LINK"; }
# run CLI ARGS...: that benchbar, with the state where a real install keeps it
run() {
  set +e
  OUT="$(env -u FL_STATE_DIR -u FL_STATE_FILE -u FL_BACKUP_ROOT "$@" 2>&1)"
  CODE="$?"
  set -e
}
where_field() { printf '%s' "$OUT" | jget - "d['$1']"; }
# listed: the bench paths of the last list --json, default first
listed() { printf '%s' "$OUT" | jget - '" ".join(b["path"] for b in d["benches"]) + " default=" + str(d["default_bench"])'; }
check_status() { printf '%s' "$OUT" | jget - "[c['status'] for c in d['checks'] if c['id'] == '$1'][0]"; }

MA="$HOME/work/m-a"; MB="$HOME/work/m-b"
make_fake_bench "$MA"; make_fake_bench "$MB"
read -r crc _ < <(printf '%s' "$MA" | cksum)
MA_FILE="benches/m-a-$(printf '%08x' "$crc").env"
# seed_legacy: the state an install.sh CLI left: MA the default with its own
# settings (a port claim among them), MB registered, a run log
seed_legacy() {
  rm -rf "$MH" "$NEW" "$GUARD"
  mkdir -p "$LEGACY/benches" "$LEGACY/logs" "$LEGACY/backups"
  printf 'BENCH_DIR=%s\nPIPX_BIN_DIR=%s\n' "$MA" "$HOME/.local/bin" >"$LEGACY/state.env"
  printf 'SITE_NAME=macdev\nPORT_OFFSET=2\nPORTS_MODE=fixed\n' >"$LEGACY/$MA_FILE"
  printf '%s\n' "$MB" >"$LEGACY/registered-benches.txt"
  printf 'an old run\n' >"$LEGACY/logs/20260930-120000.log"
}
# no_leftovers: one state folder, linked from the old path, nothing stray
no_leftovers() {
  [[ -d "$NEW" && ! -L "$NEW" ]] || fail "the state must be a real folder in its new place ${1:-}"
  [[ -L "$LEGACY" ]] || fail "the old path must be a symlink ${1:-}"
  assert_eq "$NEW" "$(readlink "$LEGACY")" "${1:-}"
  [[ ! -e "$NEW/.benchbar" && ! -L "$NEW/.benchbar" ]] || fail "no .benchbar inside the state folder ${1:-}"
  [[ ! -e "$NEW/benchbar" && ! -L "$NEW/benchbar" ]] || fail "no link inside the state folder ${1:-}"
  [[ ! -e "$GUARD" ]] || fail "the guard must be gone after the move ${1:-}"
  [[ -z "$(find "$BASE" -maxdepth 1 -name '.benchbar-migrating*' -print)" ]] || fail "no stale guard left in ${BASE} ${1:-}"$'\n'"$(ls -la "$BASE")"
  assert_eq "BENCH_DIR=$MA" "$(head -n 1 "$NEW/state.env")" "${1:-}"
  assert_eq "PORT_OFFSET=2" "$(sed -n '2p' "$NEW/$MA_FILE")" "${1:-}"
}

# shims that log "exec NAME" for mv, ln, mkdir and stat, to count what a run starts
SHIMS="$TMP_DIR/shims"; mkdir -p "$SHIMS"
for n in mv ln mkdir stat; do
  # shellcheck disable=SC2016 # expands when the shim runs
  printf '#!/bin/bash\nprintf "exec %s\\n" >>"$MOCK_LOG"\nexec %s "$@"\n' "$n" "$(command -v "$n")" >"$SHIMS/$n"
  chmod +x "$SHIMS/$n"
done

# ---- the app registered its CLI before the first run: the new folder holds
# only bin/, so the legacy state still moves in, and bin/ stays in place
seed_legacy
register
seeded="$(cd "$LEGACY" && snapshot .)"
run "$LINK" list --json
assert_eq "0" "$CODE" "$OUT"
no_leftovers "(bin/ first)"
assert_contains "$(listed)" "default=$MA"
assert_contains "$(listed)" "$MB"
assert_eq "$seeded" "$(cd "$NEW" && snapshot . | grep -v '^\./bin/')" "(moved as is)"
assert_eq "$APP_CLI_DIR/benchbar" "$(readlink "$LINK")" "(the app's link is where the app made it)"
run "$LINK" --version
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "benchbar 0.7.3"
run "$LINK" where --json
assert_eq "$LINK" "$(where_field self)"
assert_eq "$NEW" "$(where_field state_dir)"
assert_eq "$NEW" "$(where_field state_dir_real)"
# a second run moves nothing, links nothing, and starts no mv, ln or mkdir
after="$(cd "$NEW" && snapshot .)"
reset_calls
PATH="$SHIMS:$PATH" run "$LINK" list --json
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain '^exec (mv|ln|mkdir|stat)$'
assert_eq "$after" "$(cd "$NEW" && snapshot .)" "(a read only second run writes nothing)"
no_leftovers "(second run)"
# doctor from the app's CLI sees one state, not a split
run "$LINK" doctor --json --bench-dir "$MA"
assert_eq "ok" "$(check_status cli_duplicate)"

# a .DS_Store Finder left next to bin/ is no state either
seed_legacy
register
: >"$NEW/.DS_Store"
run "$LINK" list --json
assert_eq "0" "$CODE" "$OUT"
no_leftovers "(.DS_Store next to bin/)"
assert_contains "$(listed)" "default=$MA"

# a new folder with state of its own is never merged into: both stay
seed_legacy
register
printf 'BENCH_DIR=%s\n' "$MB" >"$NEW/state.env"
run "$LINK" list --json
assert_eq "0" "$CODE" "$OUT"
[[ -d "$LEGACY" && ! -L "$LEGACY" ]] || fail "an existing state folder must not be merged into"
assert_eq "BENCH_DIR=$MB" "$(cat "$NEW/state.env")"
assert_contains "$(listed)" "default=$MB"

# an empty new folder (nothing registered yet) is no state: the move happens
seed_legacy
mkdir -p "$NEW"
run "$APP_CLI_DIR/benchbar" list --json
assert_eq "0" "$CODE" "$OUT"
no_leftovers "(empty new folder)"

# ---- three first runs at once: one state folder, one link, no guard left,
# every run exits 0 (a plain first run, then with the app's bin/ in place)
for first in plain bin; do
  for i in 1 2 3; do
    seed_legacy
    [[ "$first" == plain ]] || register
    cli="$APP_CLI_DIR/benchbar"; [[ "$first" == plain ]] || cli="$LINK"
    env -u FL_STATE_DIR -u FL_STATE_FILE -u FL_BACKUP_ROOT "$cli" list --json >"$TMP_DIR/r1.out" 2>&1 & p1=$!
    env -u FL_STATE_DIR -u FL_STATE_FILE -u FL_BACKUP_ROOT "$cli" where --json >"$TMP_DIR/r2.out" 2>&1 & p2=$!
    env -u FL_STATE_DIR -u FL_STATE_FILE -u FL_BACKUP_ROOT "$cli" list --json >"$TMP_DIR/r3.out" 2>&1 & p3=$!
    c1=0; c2=0; c3=0
    wait "$p1" || c1=$?; wait "$p2" || c2=$?; wait "$p3" || c3=$?
    assert_eq "0 0 0" "$c1 $c2 $c3" "(${first} round ${i})"$'\n'"$(cat "$TMP_DIR/r1.out" "$TMP_DIR/r2.out" "$TMP_DIR/r3.out")"
    no_leftovers "(${first} round ${i})"
    OUT="$(cat "$TMP_DIR/r1.out")"; assert_contains "$(listed)" "default=$MA" "(${first} round ${i})"
    OUT="$(cat "$TMP_DIR/r3.out")"; assert_contains "$(listed)" "default=$MA" "(${first} round ${i})"
    OUT="$(cat "$TMP_DIR/r2.out")"; assert_eq "$NEW" "$(where_field state_dir)" "(${first} round ${i})"
    [[ "$first" == plain ]] || assert_eq "$APP_CLI_DIR/benchbar" "$(readlink "$LINK")" "(${first} round ${i})"
  done
done

# ---- the guard: a first run that finds it held by a live run waits for
# it, then uses the state where it is; one left by a dead run is reclaimed
seed_legacy
mkdir -p "$BASE" "$GUARD"; printf '%s\n' "$$" >"$GUARD/pid"
t0="$(date +%s)"
run "$APP_CLI_DIR/benchbar" list --json
t1="$(date +%s)"
assert_eq "0" "$CODE" "$OUT"
[[ -d "$LEGACY" && ! -L "$LEGACY" ]] || fail "a held guard must leave the old folder in place"
assert_no_file "$NEW"
assert_contains "$(listed)" "default=$MA"
[[ $((t1 - t0)) -ge 3 ]] || fail "a held guard must be waited for (took $((t1 - t0)) s)"
[[ -d "$GUARD" && "$(cat "$GUARD/pid")" == "$$" ]] || fail "a live run's guard is left alone"
printf '999999\n' >"$GUARD/pid"
run "$APP_CLI_DIR/benchbar" list --json
assert_eq "0" "$CODE" "$OUT"
no_leftovers "(stale guard reclaimed)"
assert_contains "$(listed)" "default=$MA"
# once moved, a guard a live run holds is left alone by every later run (the
# fast path), and one a dead run left is swept
mkdir "$GUARD"; printf '%s\n' "$$" >"$GUARD/pid"
run "$APP_CLI_DIR/benchbar" list --json
assert_eq "0" "$CODE" "$OUT"
[[ -d "$GUARD" && "$(cat "$GUARD/pid")" == "$$" ]] || fail "a live run's guard is left alone after the move"
printf '999999\n' >"$GUARD/pid"
run "$APP_CLI_DIR/benchbar" list --json
assert_eq "0" "$CODE" "$OUT"
no_leftovers "(a dead run's guard swept on the fast path)"
# a guard older than a minute is stale whatever its pid says (a pid number
# can be reused): no wait, the move happens
seed_legacy
mkdir -p "$BASE" "$GUARD"; printf '%s\n' "$$" >"$GUARD/pid"
touch -t 202601010000 "$GUARD"
t0="$(date +%s)"
run "$APP_CLI_DIR/benchbar" list --json
t1="$(date +%s)"
assert_eq "0" "$CODE" "$OUT"
[[ $((t1 - t0)) -le 2 ]] || fail "an old guard must not be waited for (took $((t1 - t0)) s)"
no_leftovers "(old guard)"
# two waiters that both find a dead run's guard: one reclaims it, the other
# follows; one state folder, no stale folder left
seed_legacy
mkdir -p "$BASE" "$GUARD"; printf '999999\n' >"$GUARD/pid"
env -u FL_STATE_DIR -u FL_STATE_FILE -u FL_BACKUP_ROOT "$APP_CLI_DIR/benchbar" list --json >"$TMP_DIR/w1.out" 2>&1 & p1=$!
env -u FL_STATE_DIR -u FL_STATE_FILE -u FL_BACKUP_ROOT "$APP_CLI_DIR/benchbar" list --json >"$TMP_DIR/w2.out" 2>&1 & p2=$!
c1=0; c2=0
wait "$p1" || c1=$?; wait "$p2" || c2=$?
assert_eq "0 0" "$c1 $c2" "$(cat "$TMP_DIR/w1.out" "$TMP_DIR/w2.out")"
no_leftovers "(two waiters)"
OUT="$(cat "$TMP_DIR/w1.out")"; assert_contains "$(listed)" "default=$MA" "(waiter 1)"
OUT="$(cat "$TMP_DIR/w2.out")"; assert_contains "$(listed)" "default=$MA" "(waiter 2)"

# ---- a run killed in the middle of the move: whichever step it died after,
# the next run completes the move, and the app's link works again
# killshim DIR CMD N: a CMD shim that kills its caller (kill -9) right after
# its Nth call, as a crash or the app quitting its poll would
killshim() {
  mkdir -p "$1"; printf '0' >"$1/count.$2"
  # shellcheck disable=SC2016 # expands when the shim runs
  printf '#!/bin/bash\nc=$(cat "%s/count.%s"); c=$((c + 1)); printf "%%s" "$c" >"%s/count.%s"\n%s "$@"; r=$?\n[[ "$c" != "%s" ]] || kill -9 $PPID\nexit $r\n' \
    "$1" "$2" "$1" "$2" "$(command -v "$2")" "$3" >"$1/$2"
  chmod +x "$1/$2"
}
KILL="$TMP_DIR/kill"
for step in "bin mv 1" "bin rmdir 1" "bin mv 2" "bin ln 1" "plain mv 1" "plain ln 1"; do
  read -r kind kcmd kn <<<"$step"
  seed_legacy
  [[ "$kind" == plain ]] || register
  cli="$APP_CLI_DIR/benchbar"; [[ "$kind" == plain ]] || cli="$LINK"
  rm -rf "$KILL"; killshim "$KILL" "$kcmd" "$kn"
  set +e
  env -u FL_STATE_DIR -u FL_STATE_FILE -u FL_BACKUP_ROOT PATH="$KILL:$PATH" "$cli" list --json >/dev/null 2>&1
  set -e
  assert_eq "$kn" "$(cat "$KILL/count.$kcmd")" "(the shim saw the ${kcmd} calls it kills after: ${step})"
  rm -rf "$KILL"
  # the next run (the app's CLI by its own path: its link may be away)
  run "$APP_CLI_DIR/benchbar" list --json
  assert_eq "0" "$CODE" "$OUT (killed after ${step})"
  no_leftovers "(killed after ${step})"
  assert_contains "$(listed)" "default=$MA" "(killed after ${step})"
  assert_contains "$(listed)" "$MB" "(killed after ${step})"
  if [[ "$kind" == bin ]]; then
    assert_eq "$APP_CLI_DIR/benchbar" "$(readlink "$LINK")" "(the app's link is back: killed after ${step})"
    run "$LINK" --version
    assert_eq "0" "$CODE" "$OUT (killed after ${step})"
  fi
  # and the run after that moves nothing
  reset_calls
  PATH="$SHIMS:$PATH" run "$APP_CLI_DIR/benchbar" list --json
  assert_calls_not_contain '^exec (mv|ln|mkdir|stat)$' "(killed after ${step})"
done

# the app relaunches and makes bin/ again between the steps (right before
# the state is renamed into place): the state lands inside that folder and
# goes back; the next run completes the move
seed_legacy
register
RACE_APP="$TMP_DIR/race-app"; mkdir -p "$RACE_APP"
# shellcheck disable=SC2016 # expands when the shim runs
printf '#!/bin/bash\nif [[ "$1" == %q && "$2" == %q ]]; then mkdir -p %q; ln -sfn %q %q; fi\nexec %q "$@"\n' \
  "$LEGACY" "$NEW" "${LINK%/*}" "$APP_CLI_DIR/benchbar" "$LINK" "$(command -v mv)" >"$RACE_APP/mv"
chmod +x "$RACE_APP/mv"
PATH="$RACE_APP:$PATH" run "$LINK" list --json
assert_eq "0" "$CODE" "$OUT"
assert_contains "$(listed)" "default=$MA" "(the state is read where it is)"
[[ ! -e "$NEW/.benchbar" && ! -L "$NEW/.benchbar" ]] || fail "the state must not stay inside the app's folder"
run "$LINK" list --json
assert_eq "0" "$CODE" "$OUT"
no_leftovers "(the app made bin/ again in between)"
assert_contains "$(listed)" "default=$MA"
assert_eq "$APP_CLI_DIR/benchbar" "$(readlink "$LINK")"

# the layout an interrupted run leaves (the state and the app's bin/ in the
# checkout's folder, an empty new folder): one run completes the move, and
# the poll after it starts no process
seed_legacy
mkdir -p "$LEGACY/bin" "$NEW"; ln -sfn "$APP_CLI_DIR/benchbar" "$LEGACY/bin/benchbar"
reset_calls
PATH="$SHIMS:$PATH" run "$APP_CLI_DIR/benchbar" list --json
assert_eq "0" "$CODE" "$OUT"
no_leftovers "(interrupted layout)"
assert_contains "$(listed)" "default=$MA"
reset_calls
PATH="$SHIMS:$PATH" run "$LINK" list --json
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain '^exec (mv|ln|mkdir|stat)$' "(the poll after the move)"
# (status makes the bench's logs/.benchbar folder itself: mkdir is its own)
PATH="$SHIMS:$PATH" run "$LINK" status --json --bench-dir "$MA"
assert_calls_not_contain '^exec (mv|ln|stat)$' "(a status poll after the move)"
# when the emptied folder cannot go (something appeared in it), bin/ comes
# back, this run uses the new folder as it is, and doctor says the move did
# not finish, with no Trash in sight; the next run completes it
seed_legacy
register
FAILDIR="$TMP_DIR/rmdir-fails"; mkdir -p "$FAILDIR"
# shellcheck disable=SC2016 # expands when the shim runs
printf '#!/bin/bash\n[[ "$1" != %q ]] || exit 1\nexec %q "$@"\n' "$NEW" "$(command -v rmdir)" >"$FAILDIR/rmdir"; chmod +x "$FAILDIR/rmdir"
PATH="$FAILDIR:$PATH" run "$LINK" doctor --json --bench-dir "$MA"
assert_eq "0" "$CODE" "$OUT"
assert_eq "warn" "$(check_status cli_duplicate)"
assert_contains "$(printf '%s' "$OUT" | jget - "[c['message'] for c in d['checks'] if c['id'] == 'cli_duplicate'][0]")" "did not finish"
fix="$(printf '%s' "$OUT" | jget - "[c['fix'] for c in d['checks'] if c['id'] == 'cli_duplicate'][0]")"
assert_contains "$fix" "completes the move"
assert_not_contains "$fix" "Trash"
[[ -d "$LEGACY" && ! -L "$LEGACY" && -f "$LEGACY/state.env" ]] || fail "the state stays in the old folder until the move completes"
assert_eq "$APP_CLI_DIR/benchbar" "$(readlink "$LINK")" "(bin/ came back)"
[[ ! -e "$GUARD" ]] || fail "the guard must be gone after a move that could not finish"
run "$LINK" list --json
assert_eq "0" "$CODE" "$OUT"
no_leftovers "(the run after a move that could not finish)"
assert_contains "$(listed)" "default=$MA"

# ---- another volume: the folder stays and the new path leads to it;
# where names both (the link and the folder behind it)
RACE="$TMP_DIR/race"; mkdir -p "$RACE"
# shellcheck disable=SC2016 # expands when the shim runs
printf '#!/bin/bash\nprintf "exec stat\\n" >>"$MOCK_LOG"\nprintf "1\\n2\\n"\n' >"$RACE/stat"
chmod +x "$RACE/stat"
seed_legacy
register
seeded="$(cd "$LEGACY" && snapshot .)"
reset_calls
PATH="$RACE:$SHIMS:$PATH" run "$LINK" list --json
assert_eq "0" "$CODE" "$OUT"
[[ -d "$LEGACY" && ! -L "$LEGACY" ]] || fail "across volumes the folder stays"
assert_eq "$LEGACY" "$(readlink "$NEW")"
assert_eq "$seeded" "$(cd "$LEGACY" && snapshot . | grep -v '^\./bin/')" "(nothing copied)"
assert_eq "$APP_CLI_DIR/benchbar" "$(readlink "$LINK")" "(the app's link still works through the new path)"
[[ ! -e "$GUARD" ]] || fail "the guard must be gone after the link"
assert_contains "$(listed)" "default=$MA"
run "$LINK" --version
assert_contains "$OUT" "benchbar 0.7.3"
run "$LINK" where --json
assert_eq "0" "$CODE" "$OUT"
assert_eq "$NEW" "$(where_field state_dir)"
assert_eq "$LEGACY" "$(where_field state_dir_real)"
run "$LINK" where
assert_contains "$OUT" "state    $NEW -> $LEGACY"
reset_calls
PATH="$RACE:$SHIMS:$PATH" run "$LINK" list --json
assert_calls_not_contain '^exec (mv|ln|mkdir|stat)$'
rm -f "$RACE/stat"

printf 'test-state-migrate: ok\n'
