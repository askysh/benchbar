#!/usr/bin/env bash
# The agent contracts (0.9), part 2 of 3: the non interactive mode, the honest state fields, doctor --ack and --quick, the lock's owner, and logs with time.
# shellcheck source=tests/lib/agent-contracts-fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/agent-contracts-fixtures.sh"
make_second_bench

# ---------------------------------------------------------------- 3. the non interactive mode

# refused before the lock, the log and any bench call; every missing input in ONE error
noni() { BENCHBAR_NONINTERACTIVE=1 run_fm "$@"; }
rm -rf "$MOCK_STATE/keychain"
unset MARIADB_ROOT_PASSWORD
n_logs="$(logs_now)"; reset_calls
noni site add noniuser --bench-dir "$BENCH"
assert_eq "2" "$CODE" "$OUT" "(exit 2: the MariaDB root password is among the missing)"
assert_contains "$OUT" "missing:"
assert_contains "$OUT" "ADMIN_PASSWORD"
assert_contains "$OUT" "MARIADB_ROOT_PASSWORD"
assert_contains "$OUT" "--yes"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c 'Cannot start, missing')" "(one error names them all)"
assert_calls_not_contain '^bench ' "(no bench call)"
assert_no_file "$FL_STATE_DIR/lock" "(no lock)"
assert_no_file "$BENCH/.benchbar.lock" "(no bench lock)"
assert_eq "$n_logs" "$(logs_now)" "(no log written)"
assert_no_file "$BENCH/sites/noniuser"
# sudo that would ask is named too (a Mac hosts line needs it)
rm -f "$MOCK_STATE/sudo_cred"
noni site add noniuser --bench-dir "$BENCH"
assert_contains "$OUT" "sudo"
touch "$MOCK_STATE/sudo_cred"
# the secret's source is never said: the message does not tell where the password lives
assert_not_contains "$OUT" "Keychain"
# --yes and the secrets: it goes through (the mode only refuses what cannot be answered)
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
BENCHBAR_NONINTERACTIVE=1 ADMIN_PASSWORD=adminpw MARIADB_ROOT_PASSWORD=rootpw run_fm site add noniuser --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_file "$BENCH/sites/noniuser"
# a stored password counts as known (benchbar's own store)
mkdir -p "$MOCK_STATE/keychain"; printf 'rootpw' >"$MOCK_STATE/keychain/benchbar-mariadb--root"
BENCHBAR_NONINTERACTIVE=1 ADMIN_PASSWORD=adminpw run_fm site add noniuser2 --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
rm -rf "$MOCK_STATE/keychain"
# site drop: the password
mkdir -p "$BENCH/sites/dropme2"; printf '{}\n' >"$BENCH/sites/dropme2/site_config.json"
reset_calls; n_logs="$(logs_now)"
noni site drop dropme2 --confirm-site dropme2 --bench-dir "$BENCH"
assert_eq "2" "$CODE" "$OUT"; assert_contains "$OUT" "MARIADB_ROOT_PASSWORD"
assert_calls_not_contain '^bench '; assert_no_file "$FL_STATE_DIR/lock"; assert_eq "$n_logs" "$(logs_now)"
assert_file "$BENCH/sites/dropme2"
# install: --yes, the Administrator password and a sudo that would ask, all in one
NEWB="$HOME/noni-bench"
stream_machine
rm -f "$MOCK_STATE/sudo_cred"
reset_calls; n_logs="$(logs_now)"
noni install --bench-dir "$NEWB" --site noni.localhost
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "--yes"; assert_contains "$OUT" "ADMIN_PASSWORD"; assert_contains "$OUT" "sudo"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c 'Cannot start, missing')"
assert_calls_not_contain '^(bench|brew install|brew services|launchctl)'
assert_no_file "$FL_STATE_DIR/lock"; assert_eq "$n_logs" "$(logs_now)"; assert_no_file "$NEWB"
touch "$MOCK_STATE/sudo_cred"
# uninstall-service: no terminal and no --yes is refused in any mode, naming --yes
run_fm uninstall-service --bench-dir "$BENCH" </dev/null
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "--yes"
assert_file "$BENCH/benchbar-run.sh"
noni uninstall-service --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "--yes"
assert_file "$BENCH/Procfile.lean"
# fl_confirm under the mode names --yes instead of reading no
mkdir -p "$MOCK_STATE/keychain"; printf 'rootpw' >"$MOCK_STATE/keychain/benchbar-mariadb--root"
noni mariadb-password --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "--yes"
assert_not_contains "$OUT" "rootpw"
rm -rf "$MOCK_STATE/keychain"
# the flag sets the mode: --for-agent
run_fm site add noniuser3 --for-agent --bench-dir "$BENCH"
assert_eq "2" "$CODE"; assert_contains "$OUT" "ADMIN_PASSWORD"

# ---------------------------------------------------------------- 4. honest state fields

# bench_bin: the bench the service runs, from the PATH its agent bakes in; null when there is none
run_fm status --json --bench-dir "$BENCH"
assert_eq "None" "$(printf '%s' "$OUT" | jget - 'd["bench_bin"]')"
printf '#!/bin/sh\nexit 0\n' >"$HOME/.local/bin/bench"; chmod +x "$HOME/.local/bin/bench"
reset_calls
run_fm status --json --bench-dir "$BENCH"
assert_eq "$HOME/.local/bin/bench" "$(printf '%s' "$OUT" | jget - 'd["bench_bin"]')"
# it costs the status path no process (launchctl is the one the state already needs)
assert_calls_not_contain '^(bench|which|command) ' "(bench_bin starts nothing)"
rm -f "$HOME/.local/bin/bench"
# the same state_after of a done carries it
printf '#!/bin/sh\nexit 0\n' >"$HOME/.local/bin/bench"; chmod +x "$HOME/.local/bin/bench"
stream down --json --bench-dir "$BENCH"
assert_eq "$HOME/.local/bin/bench" "$(sx 'e[-1]["state_after"]["bench_bin"]')"
rm -f "$HOME/.local/bin/bench"

# not_adopted: a folder that is a bench, with no service of benchbar's and not remembered
NA="$HOME/elsewhere/na-bench"
make_fake_bench "$NA" na-site
mkdir -p "$HOME/elsewhere/empty-bench/sites" "$HOME/elsewhere/empty-bench/apps/frappe"
printf '{}\n' >"$HOME/elsewhere/empty-bench/sites/common_site_config.json"
run_fm status --json --bench-dir "$NA"
assert_eq "0" "$CODE" "$OUT"
assert_eq "not_adopted None None" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in (d["state"], d["site"], d["web_url"]))')"
assert_eq "False" "$(printf '%s' "$OUT" | jget - 'any(s["default"] for s in d["sites"])')" "(no site of this bench is marked default)"
assert_not_contains "$OUT" "macdev" "(the default bench's site never leaks into another bench's status)"
run_fm status --json --bench-dir "$HOME/elsewhere/empty-bench"
assert_eq "not_adopted None" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in (d["state"], d["site"]))')"
assert_not_contains "$OUT" "macdev"
run_fm status --bench-dir "$NA"
assert_contains "$OUT" "does not manage this bench yet"
# remembered (register), or with a service of its own: no longer not_adopted
run_fm register "$NA"
run_fm status --json --bench-dir "$NA"
assert_eq "stopped na-site" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in (d["state"], d["site"]))')"
# the default bench and a bench with a service are never not_adopted
run_fm status --json --bench-dir "$BENCH"
assert_eq "stopped" "$(printf '%s' "$OUT" | jget - 'd["state"]')"
# list --json still lists it, and it costs the same
run_fm list --json
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'any(b["path"] == "'"$NA"'" for b in d["benches"])')"

# the ping rules: status --ping asks every site only while the bench runs; a stopped bench starts nothing and asks nothing
reset_calls
stream down --json --bench-dir "$BENCH"
reset_calls
run_fm status --json --ping --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain '^curl ' "(a stopped bench is not pinged, site by site)"
assert_calls_not_contain '^launchctl (kickstart|bootstrap)' "(status never starts)"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'all(s["ping_code"] is None for s in d["sites"])')"
reset_calls
run_fm list --json
assert_calls_not_contain '^curl ' "(list never pings, at rest or running)"
add_proc 4242 "honcho start -f Procfile.lean" "$BENCH"
export MOCK_CURL_CODE=200
reset_calls
run_fm status --json --ping --bench-dir "$BENCH"
assert_eq "200" "$(printf '%s' "$OUT" | jget - '[s["ping_code"] for s in d["sites"] if s["default"]][0]')"
assert_calls_contain '^curl ' "(a running bench is pinged)"
reset_calls
run_fm list --json
assert_calls_not_contain '^curl ' "(list never pings)"
: >"$MOCK_PROCS"; unset MOCK_CURL_CODE

# ---------------------------------------------------------------- 5. doctor --ack, --quick and the lock's owner

mkdir -p "$HOME/Applications/CleanMyMac X.app"
dj() { run_json doctor --json --bench-dir "$BENCH"; }
dj
assert_eq "warn False []" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in ([c for c in d["checks"] if c["id"] == "cleanmymac"][0]["level"], [c for c in d["checks"] if c["id"] == "cleanmymac"][0]["acked"], d["acked"]))')"
WARNS_BEFORE="$(printf '%s' "$OUT" | jget - 'd["summary"]["warn"]')"
# ack: recorded, with the message it acknowledged
run_fm doctor --ack cleanmymac --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "acknowledged cleanmymac"
dj
assert_eq "warn True cleanmymac" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in ([c for c in d["checks"] if c["id"] == "cleanmymac"][0]["level"], [c for c in d["checks"] if c["id"] == "cleanmymac"][0]["acked"], ",".join(d["acked"])))')"
assert_eq "$WARNS_BEFORE" "$(printf '%s' "$OUT" | jget - 'd["summary"]["warn"]')" "(the check is kept at level warn)"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "acked: CleanMyMac"
assert_not_contains "$OUT" "[WARN] CleanMyMac"
run_fm doctor --fix-hints --bench-dir "$BENCH"
assert_not_contains "$OUT" "Ignore List" "(--fix-hints leaves an acked warning out)"
# ack is per bench
run_json doctor --json --bench-dir "$B2"
assert_eq "False" "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"] == "cleanmymac"][0]["acked"]')"
# the message changes: the ack lapses
mv "$HOME/Applications/CleanMyMac X.app" "$HOME/Applications/CleanMyMac Pro.app"
dj
assert_eq "False" "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"] == "cleanmymac"][0]["acked"]')"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] CleanMyMac"
# unack, twice
run_fm doctor --unack cleanmymac --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "no longer acknowledged"
run_fm doctor --unack cleanmymac --bench-dir "$BENCH"
assert_contains "$OUT" "was not acknowledged"
# a FAIL cannot be acked; an unknown id and an ok check say so
mv "$BENCH/env/bin/python" "$BENCH/env/bin/python.x"
run_fm doctor --ack env_python --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "cannot be acknowledged"
mv "$BENCH/env/bin/python.x" "$BENCH/env/bin/python"
run_fm doctor --ack nosuchcheck --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "No check named"
run_fm doctor --ack honcho --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "nothing to acknowledge"
rm -rf "$HOME/Applications/CleanMyMac Pro.app"

# --quick: the slow checks are left out and named
export MOCK_CURL_CODE=200
reset_calls
run_json doctor --json --quick --bench-dir "$BENCH"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["quick"] and "ping" in d["skipped_checks"] and "bench_version" in d["skipped_checks"] and not any(c["id"] in d["skipped_checks"] for c in d["checks"])')"
assert_calls_not_contain '^curl ' "(the site ping is a slow check)"
dj
assert_eq "False []" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in (d["quick"], d["skipped_checks"]))')"
run_fm doctor --quick --bench-dir "$BENCH"
assert_contains "$OUT" "quick: skipped the slow checks:"
unset MOCK_CURL_CODE

# the lock: "Reclaiming stale lock left by pid N" says what held it and since when
(
  set +e
  # shellcheck source=lib/frappe-local/ui.sh
  . "$ROOT/lib/frappe-local/ui.sh"
  # shellcheck source=lib/frappe-local/lock.sh
  . "$ROOT/lib/frappe-local/lock.sh"
  COMMAND=site; ARGS=(add x)
  fl_lock_acquire "$TMP_DIR/lockinfo" >/dev/null 2>&1
  printf '%s' "$(cat "$TMP_DIR/lockinfo/info")" >"$TMP_DIR/lockinfo.txt"
  fl_lock_release
)
assert_contains "$(cat "$TMP_DIR/lockinfo.txt")" "site add"
assert_not_contains "$(cat "$TMP_DIR/lockinfo.txt")" " x" "(the subcommand only, never an argument)"
mkdir -p "$FL_STATE_DIR/lock"; printf '999999\n' >"$FL_STATE_DIR/lock/pid"
printf 'site add\t2026-10-29T10:00:00Z\n' >"$FL_STATE_DIR/lock/info"
run_fm service --yes --bench-dir "$B2"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "Reclaiming stale lock left by pid 999999 (benchbar site add, started 2026-10-29T10:00:00Z)"

# ---------------------------------------------------------------- 6. logs with time

LB="$HOME/log-bench"
make_fake_bench "$LB" logsite
cat >"$LB/logs/bench.log" <<'LOG'
23:59:58 system | web.1 started (pid=11)
23:59:59 web.1        | * Running on http://127.0.0.1:8000
00:00:02 worker.1     | job done
00:00:03 web.1        | Traceback (most recent call last):
  File "x.py", line 1, in <module>
00:00:04 socketio.1   | listening on 9000
LOG
# the file's time: 2026-10-29 00:00:10 UTC, so the first two lines are from the day before
TZ=UTC touch -t 202610290000.10 "$LB/logs/bench.log"
tlogs() { TZ=UTC run_json logs --json --no-follow --bench-dir "$LB" "$@"; }
tlogs
assert_eq "0" "$CODE" "$ERR"
assert_eq "2026-10-29T00:00:10Z" "$(printf '%s' "$OUT" | jget - 'd["mtime"]')"
assert_eq "[None, None]" "$(printf '%s' "$OUT" | jget - '[d["since"], d.get("truncated_to")]')"
assert_eq "6 6" "$(printf '%s' "$OUT" | jget - '"%d %d" % (len(d["lines"]), len(d["ts"]))')" "(one ts per line)"
assert_eq "['2026-10-28T23:59:58Z', '2026-10-28T23:59:59Z', '2026-10-29T00:00:02Z', '2026-10-29T00:00:03Z', None, '2026-10-29T00:00:04Z']" "$(printf '%s' "$OUT" | jget - 'd["ts"]')" "(a line without a time has none, and inherits none)"
# --since: at or after, the untimed line under a kept line stays
tlogs --since 2026-10-29T00:00:03Z
assert_eq "['00:00:03 web.1        | Traceback (most recent call last):', '  File \"x.py\", line 1, in <module>', '00:00:04 socketio.1   | listening on 9000'] 2026-10-29T00:00:03Z" "$(printf '%s' "$OUT" | jget - 'str(d["lines"]) + " " + d["since"]')"
assert_eq "['2026-10-29T00:00:03Z', None, '2026-10-29T00:00:04Z']" "$(printf '%s' "$OUT" | jget - 'd["ts"]')"
tlogs --since 2026-10-29T00:00:05Z
assert_eq "[] []" "$(printf '%s' "$OUT" | jget - 'str(d["lines"]) + " " + str(d["ts"])')"
# local time without a zone; a zone; a date; the last lines after the filter
tlogs --since "2026-10-29 00:00:04"
assert_eq "1" "$(printf '%s' "$OUT" | jget - 'len(d["lines"])')"
tlogs --since 2026-10-29T05:30:03+05:30
assert_eq "3" "$(printf '%s' "$OUT" | jget - 'len(d["lines"])')"
tlogs --since 2026-10-29
assert_eq "0" "$(printf '%s' "$OUT" | jget - 'len([t for t in d["ts"] if t and t < "2026-10-29"])')"
tlogs -n2 --since 2026-10-28T23:59:59Z
assert_eq "2 2" "$(printf '%s' "$OUT" | jget - '"%d %d" % (len(d["lines"]), len(d["ts"]))')"
# a process filter keeps its own lines' times
tlogs --process web
assert_eq "['2026-10-28T23:59:59Z', '2026-10-29T00:00:03Z', None]" "$(printf '%s' "$OUT" | jget - 'd["ts"]')"
# --since-restart: after the start state.json recorded
mkdir -p "$LB/logs/.benchbar"
printf '{"schema_version":1,"state":"running","started_at":"2026-10-29T00:00:02Z"}\n' >"$LB/logs/.benchbar/state.json"
tlogs --since-restart
assert_eq "4 2026-10-29T00:00:02Z" "$(printf '%s' "$OUT" | jget - '"%d %s" % (len(d["lines"]), d["since"])')"
rm -f "$LB/logs/.benchbar/state.json"
tlogs --since-restart
assert_eq "1" "$CODE"; assert_contains "$ERR" "no recorded start"; assert_eq "" "$OUT" "(a refusal under --json is text on stderr, stdout stays empty)"
tlogs --since nonsense
assert_eq "1" "$CODE"; assert_contains "$ERR" "Cannot read the time"
run_fm logs --since 2026-10-29T00:00:03Z --no-follow --bench-dir "$LB"
assert_eq "1" "$CODE"; assert_contains "$OUT" "need --json"
# the dates a line can carry itself (worker logs): local time
printf '2026-10-28 23:59:58,123 first\ncontinued\n2026-10-29 00:00:01,456 second\n' >"$LB/logs/worker.log"
TZ=UTC touch -t 202610290000.10 "$LB/logs/worker.log"
tlogs --worker
assert_eq "['2026-10-28T23:59:58Z', None, '2026-10-29T00:00:01Z']" "$(printf '%s' "$OUT" | jget - 'd["ts"]')"
# a zone east of UTC: the line's local time is converted, not read as UTC
if [[ "$(TZ=Asia/Kolkata date +%z)" == "+0530" ]]; then
  printf '05:29:58 web.1 | late\n05:30:03 web.1 | later\n' >"$LB/logs/bench.log"
  TZ=Asia/Kolkata touch -t 202610290530.10 "$LB/logs/bench.log"
  TZ=Asia/Kolkata run_json logs --json --no-follow --bench-dir "$LB"
  assert_eq "['2026-10-28T23:59:58Z', '2026-10-29T00:00:03Z']" "$(printf '%s' "$OUT" | jget - 'd["ts"]')"
fi
# no file: empty, no times, no mtime
run_json logs --json --no-follow --previous --bench-dir "$LB"
assert_eq "None [] []" "$(printf '%s' "$OUT" | jget - '"%s %s %s" % (d["mtime"], d["lines"], d["ts"])')"
# the redaction keeps the line count: ts stays in step
printf '10:00:01 web.1 | password=hunter2 ok\n10:00:02 web.1 | fine\n' >"$LB/logs/bench.log"
tlogs
assert_eq "2 2" "$(printf '%s' "$OUT" | jget - '"%d %d" % (len(d["lines"]), len(d["ts"]))')"
assert_not_contains "$OUT" "hunter2"

printf 'test-agent-contracts-2: ok\n'
