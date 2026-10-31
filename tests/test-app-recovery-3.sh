#!/usr/bin/env bash
# Recovery after a partial failure, part 3 of 3: the planned app add (a retry runs only the steps that did not finish), the plan's dependency order and its cycle error, and fl_run_capture_timeout.
# shellcheck source=tests/lib/recovery-suite.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/recovery-suite.sh"
prime_app_update
# the bench has its service, as the update tests of part 2 leave it
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"

# ---------------------------------------------------------------- planned app add
make_app_remote acme_site
add_policy acme_site main
plan_json() { run_fm app add "$@" --dry-run --json --bench-dir "$BENCH"; }
apply_json() { run_fm app add "$@" --apply "$AP_TOKEN" --yes --json --bench-dir "$BENCH"; }
plan_json acme_site --site macdev
assert_eq "0" "$CODE" "$OUT"
AP_TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
assert_eq "clone,build,install,restart" "$(steps_of "$OUT")"
assert_eq "None" "$(printf '%s' "$OUT" | jget - 'd["reason"]')"
assert_eq "['acme_site']" "$(printf '%s' "$OUT" | jget - 'd["order"]')"
# a failed build: no install on a site whose assets were never built, no restart
reset_calls
run_with MOCK_BENCH_BUILD_EXIT 1 app add acme_site --site macdev --apply "$AP_TOKEN" --yes --json --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_calls_contain '^bench build --app acme_site$'
assert_calls_not_contain 'install-app'
assert_eq "app_add build" "$(pending_get acme_site 'd["op"] + " " + d["failed_step"]')"
assert_eq "build,install,restart" "$(pending_get acme_site '",".join(s["kind"] for s in d["steps"])')"
doc="$(printf '%s\n' "$OUT" | grep '"applied"' | tail -n1)"
assert_eq "done failed skipped skipped" "$(printf '%s' "$doc" | jget - '" ".join(s["status"] for s in d["steps"])')"
assert_eq "after failed build" "$(printf '%s' "$doc" | jget - 'd["steps"][2]["reason"]')"
run_fm doctor --json --bench-dir "$BENCH"
assert_eq "app_add_pending" "$(printf '%s' "$OUT" | jget - '[c["id"] for c in d["checks"] if c["id"].endswith("_pending") and c["level"]=="warn"][0]')"
# the next plan: the build and the install are steps again, with the reason
plan_json acme_site --site macdev
assert_eq "0" "$CODE" "$OUT"
assert_eq "build,install,restart" "$(steps_of "$OUT")"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["changes"]')"
assert_contains "$(printf '%s' "$OUT" | jget - 'd["reason"]')" "stopped at build"
AP_TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
reset_calls
apply_json acme_site --site macdev
assert_eq "0" "$CODE" "$OUT"
assert_eq "0" "$(calls 'get-app')" "(already cloned)"
assert_eq "1" "$(calls '^bench build --app acme_site$')"
assert_eq "1" "$(calls '^bench --site macdev install-app acme_site$')"
assert_eq "" "$(pending_file acme_site)"
plan_json acme_site --site macdev
assert_eq "[]" "$(printf '%s' "$OUT" | jget - '[s["kind"] for s in d["steps"]]')"
assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["changes"]')"
assert_eq "None" "$(printf '%s' "$OUT" | jget - 'd["reason"]')"

# a failed install: the build stays done, only the install is left
make_app_remote acme_shop
add_policy acme_shop main
plan_json acme_shop --site macdev
AP_TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
run_with MOCK_BENCH_INSTALL_APP_EXIT 1 app add acme_shop --site macdev --apply "$AP_TOKEN" --yes --json --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_eq "install" "$(pending_get acme_shop '",".join(s["kind"] for s in d["steps"])')"
plan_json acme_shop
assert_eq "install" "$(steps_of "$OUT")" "(the site comes from the record)"
AP_TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
reset_calls
apply_json acme_shop
assert_eq "0" "$CODE" "$OUT"
assert_eq "0" "$(calls 'get-app|bench build')"
assert_eq "1" "$(calls '^bench --site macdev install-app acme_shop$')"
assert_eq "" "$(pending_file acme_shop)"

# a clone that fails is rolled back and leaves no record: the app is simply absent
make_app_remote acme_bad
add_policy acme_bad main
plan_json acme_bad --site macdev
AP_TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
run_with MOCK_BENCH_GET_APP_EARLY_EXIT 1 app add acme_bad --site macdev --apply "$AP_TOKEN" --yes --json --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_eq "" "$(pending_file acme_bad)"
[[ ! -d "$BENCH/apps/acme_bad" ]] || fail "the failed clone was rolled back"
# get-app that cloned and listed the app, then failed: the folder stays (benchbar
# does not edit sites/), and the record keeps the requirements the failed pip
# install did not get to and the build for the next plan
run_with MOCK_BENCH_GET_APP_EXIT 1 app add acme_bad --site macdev --apply "$AP_TOKEN" --yes --json --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_eq "requirements_python,build,restart" "$(pending_get acme_bad '",".join(s["kind"] for s in d["steps"])')"
plan_json acme_bad --site macdev
assert_eq "requirements_python,build,install,restart" "$(steps_of "$OUT")"
AP_TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
# a failed requirements step skips the build, the install and the restart, and the record keeps them
reset_calls
run_with MOCK_BENCH_REQUIREMENTS_PYTHON_EXIT 1 app add acme_bad --site macdev --apply "$AP_TOKEN" --yes --json --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_calls_not_contain 'build --app|install-app'
doc="$(printf '%s\n' "$OUT" | grep '"applied"' | tail -n1)"
assert_eq "failed skipped skipped skipped" "$(printf '%s' "$doc" | jget - '" ".join(s["status"] for s in d["steps"])')"
assert_eq "after failed requirements_python" "$(printf '%s' "$doc" | jget - 'd["steps"][1]["reason"]')"
assert_eq "requirements_python,build,install,restart" "$(pending_get acme_bad '",".join(s["kind"] for s in d["steps"])')"
plan_json acme_bad --site macdev
AP_TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
reset_calls
apply_json acme_bad --site macdev
assert_eq "0" "$CODE" "$OUT"
r="$(grep -n 'setup requirements --python acme_bad' "$MOCK_LOG" | head -n1 | cut -d: -f1)"
b="$(grep -n 'build --app acme_bad' "$MOCK_LOG" | head -n1 | cut -d: -f1)"
i="$(grep -n 'install-app acme_bad' "$MOCK_LOG" | head -n1 | cut -d: -f1)"
[[ -n "$r" && -n "$b" && -n "$i" && "$r" -lt "$b" && "$b" -lt "$i" ]] || fail "requirements, build, install in that order: $r $b $i"
assert_eq "" "$(pending_file acme_bad)"

# an app_add record with nothing left to run (the install was done by hand): the
write_record acme_crm '{"kind":"install","target":"macdev","name":"Install on macdev"}' '"install"'
[[ -n "$(pending_file acme_crm)" ]] || fail "the hand written record is found"
run_fm app add acme_crm --site macdev --dry-run --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "its record would be removed"
assert_file "$(pending_file acme_crm)" "(a dry run removes nothing)"
run_fm app add acme_crm --site macdev --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "the unfinished app add of acme_crm is complete"
assert_eq "" "$(pending_file acme_crm)"
write_record acme_crm '{"kind":"install","target":"macdev","name":"Install on macdev"}' '"install"'
plan_json acme_crm --site macdev
AP_TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
apply_json acme_crm --site macdev
assert_eq "0" "$CODE" "$OUT"
assert_eq "" "$(pending_file acme_crm)"
# a record that names a site that is gone is cleared too
write_record acme_crm '{"kind":"install","target":"nosuchsite","name":"Install on nosuchsite"}' '"install"'
run_fm app add acme_crm --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "" "$(pending_file acme_crm)"

# ---------------------------------------------------------------- dependency order
make_app_remote dep_b
make_app_remote dep_c dep_b
make_app_remote dep_top dep_b dep_c
for n in dep_b dep_c dep_top; do add_policy "$n" main; done
plan_json dep_top
assert_eq "0" "$CODE" "$OUT"
assert_eq "['dep_b', 'dep_c', 'dep_top']" "$(printf '%s' "$OUT" | jget - 'd["order"]')"
assert_eq "dep_b,dep_c,dep_top" "$(printf '%s' "$OUT" | jget - '",".join(s["name"].replace("Clone ", "") for s in d["steps"] if s["kind"].startswith("clone"))')"
AP_TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
reset_calls
apply_json dep_top
assert_eq "0" "$CODE" "$OUT"
assert_eq "dep_b dep_c dep_top" "$(grep '^bench get-app' "$MOCK_LOG" | sed 's#.*/\([a-z_]*\)\.git$#\1#' | tr '\n' ' ' | sed 's/ $//')"
assert_eq "frappe acme_crm acme_site acme_shop acme_bad dep_b dep_c dep_top" "$(tr '\n' ' ' <"$BENCH/sites/apps.txt" | sed 's/ $//')"

# an app already in the bench between two to clone passes the order through:
# pres_x requires pres_p (in the bench), pres_p requires pres_y (not), so
# pres_y goes before pres_x
make_app_remote pres_y
make_app_remote pres_p
make_app_remote pres_x pres_p
make_app_remote pres_top pres_y pres_x
for n in pres_y pres_p pres_x pres_top; do add_policy "$n" main; done
run_fm app add pres_p --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
sed_inplace 's/required_apps = \[\]/required_apps = ["pres_y"]/' "$BENCH/apps/pres_p/pres_p/hooks.py"
plan_json pres_top
assert_eq "0" "$CODE" "$OUT"
assert_eq "['pres_y', 'pres_x', 'pres_top']" "$(printf '%s' "$OUT" | jget - 'd["order"]')"

# an app that requires itself is a cycle of one
make_app_remote selfy selfy
add_policy selfy main
plan_json selfy
assert_eq "0" "$CODE" "$OUT"
assert_contains "$(printf '%s' "$OUT" | jget - '" ".join(d["errors"])')" "required_apps cycle: selfy -> selfy"
assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')"

# a cycle is refused and named
make_app_remote cyc_a cyc_b
make_app_remote cyc_b cyc_a
add_policy cyc_a main
add_policy cyc_b main
plan_json cyc_a
assert_eq "0" "$CODE" "$OUT"
assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')"
assert_contains "$(printf '%s' "$OUT" | jget - '" ".join(d["errors"])')" "required_apps cycle: cyc_b -> cyc_a -> cyc_b"
AP_TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
reset_calls
apply_json cyc_a
assert_eq "1" "$CODE"; assert_contains "$OUT" "required_apps cycle"
assert_calls_not_contain '^bench get-app'

# the plain app add (asks once, same plan and loop) leaves and finishes the same record
make_app_remote acme_plain
add_policy acme_plain main
run_with MOCK_BENCH_BUILD_EXIT 1 app add acme_plain --site macdev --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "Install on macdev: skipped (after failed build)"
assert_eq "build,install,restart" "$(pending_get acme_plain '",".join(s["kind"] for s in d["steps"])')"
reset_calls
run_fm app add acme_plain --site macdev --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "0" "$(calls 'get-app')" "(already cloned)"
assert_eq "1" "$(calls '^bench --site macdev install-app acme_plain$')"
assert_eq "" "$(pending_file acme_plain)"

# ---------------------------------------------------------------- fl_run_capture_timeout
# a child that ignores TERM and a grandchild that does too: both die, 124,
# within the deadline plus the grace
cat >"$TMP_DIR/stubborn.sh" <<'SH'
#!/bin/bash
trap '' TERM
( trap '' TERM; printf '%s\n' "$BASHPID" >"$1.grandchild"; while :; do sleep 1; done ) &
printf '%s\n' "$$" >"$1.child"
while :; do sleep 1; done
SH
chmod +x "$TMP_DIR/stubborn.sh"
cat >"$TMP_DIR/captest.sh" <<SH
set -euo pipefail
. "$ROOT/lib/frappe-local/run.sh"
FL_KILL_GRACE=0.3
FL_RUN_PGID=4242
code=0
start="\$SECONDS"
fl_run_capture_timeout 1 "$TMP_DIR/cap.out" "$TMP_DIR/cap.err" "$TMP_DIR/stubborn.sh" "$TMP_DIR/pids" || code=\$?
printf '%s %s %s\n' "\$code" "\$((SECONDS - start))" "\$FL_RUN_PGID"
code=0
printf 'out\n' >"$TMP_DIR/ok.in"
fl_run_capture_timeout 5 "$TMP_DIR/cap2.out" "$TMP_DIR/cap2.err" bash -c 'echo to-out; echo to-err >&2; exit 3' || code=\$?
printf '%s\n' "\$code"
SH
result="$(bash "$TMP_DIR/captest.sh")"
read -r code secs pgid <<<"$(printf '%s\n' "$result" | head -n1)"
assert_eq "124 4242" "$code $pgid" "$result"
[[ "$secs" -le 3 ]] || fail "fl_run_capture_timeout took ${secs}s for a 1s deadline"
assert_eq "3" "$(printf '%s\n' "$result" | tail -n1)"
assert_eq "to-out" "$(cat "$TMP_DIR/cap2.out")" "(stdout to OUT only)"
assert_eq "to-err" "$(cat "$TMP_DIR/cap2.err")" "(stderr to ERR only)"
assert_contains "$(cat "$TMP_DIR/cap.err")" "timed out after 1s"
for who in child grandchild; do
  pid="$(cat "$TMP_DIR/pids.$who")"
  # a zombie nobody has reaped yet (its parent was killed) is dead
  state="$(ps -o state= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  if kill -0 "$pid" 2>/dev/null && [[ "$state" != Z* ]]; then fail "the ${who} (pid ${pid}, state ${state}) survived fl_run_capture_timeout"; fi
done


printf 'test-app-recovery-3 (%s): ok\n' "$RECOVERY_PASS"
