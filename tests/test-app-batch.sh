#!/usr/bin/env bash
# app add with pinned commits, several apps in one plan and per app sites:
# --commit (reached, short, not reached, unknown), a batch with a shared
# required app (one clone, the order, one token, a stale token), --install-on
# per app, and the apply result (per app: clone, build, installs with their
# migrate). The whole file runs twice, under the macOS mocks and under
# use_linux, side by side.
if [[ -z "${BATCH_PASS:-}" ]]; then
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/benchbar-batch.XXXXXX")"
  BATCH_PASS=macos bash "$here/$(basename "${BASH_SOURCE[0]}")" >"$tmp/macos.out" 2>&1 </dev/null &
  p1=$!
  BATCH_PASS=linux BENCHBAR_TEST_PLATFORM=linux bash "$here/$(basename "${BASH_SOURCE[0]}")" >"$tmp/linux.out" 2>&1 </dev/null &
  p2=$!
  c1=0; c2=0
  wait "$p1" || c1=$?
  wait "$p2" || c2=$?
  printf '== macos mocks\n'; cat "$tmp/macos.out"
  printf '== use_linux\n'; cat "$tmp/linux.out"
  rm -rf "$tmp"
  [[ "$c1" == "0" && "$c2" == "0" ]] || { printf 'FAIL: test-app-batch (macos %s, linux %s)\n' "$c1" "$c2" >&2; exit 1; }
  exit 0
fi

# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=tests/lib/apps-fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apps-fixtures.sh"

fail() { printf "FAIL (line %s): %s\n" "${BASH_LINENO[1]}" "$*" >&2; exit 1; }
BENCH="$HOME/frappe-bench"
make_fake_bench "$BENCH" macdev
printf 'frappe\n' >"$BENCH/sites/apps.txt"
rmdir "$BENCH/apps/erpnext"
printf 'frappe 15.0.0\n' >"$BENCH/sites/macdev/installed_apps"
mkdir -p "$BENCH/sites/site2"; printf '{}\n' >"$BENCH/sites/site2/site_config.json"
printf 'frappe 15.0.0\n' >"$BENCH/sites/site2/installed_apps"

# run_json ARGS...: stdout (the JSON document) in OUT, the text in ERR
run_json() { set +e; OUT="$("$FM" "$@" 2>"$MOCK_STATE/stderr")"; CODE="$?"; ERR="$(cat "$MOCK_STATE/stderr")"; set -e; }
plan() { run_json app add "$@" --dry-run --json --bench-dir "$BENCH"; }
apply() { run_json app add "$@" --apply "$TOKEN" --yes --json --bench-dir "$BENCH"; }
calls() { grep -c -E "$1" "$MOCK_LOG" || true; }
steps_of() { printf '%s' "$OUT" | jget - '",".join(s["name"] for s in d["steps"])'; }
pending_file() { find "$FL_STATE_DIR/benches" -path "*.pending/$1.json" 2>/dev/null | head -n1; }
remote_head() { git -C "$REMOTES/$1.git" rev-parse "${2:-main}"; }
# app_line N: the Nth app of the last result: app, cloned, clone, build and its first install
app_line() {
  printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); a=d["apps"][int(sys.argv[1])]; i=a["installs"][0]; print(":".join(str(x) for x in [a["app"],a["cloned"],a["clone"],a["build"],i["site"],i["status"],i["migrate"]]))' "$1"
}
apps_txt() { tr '\n' ' ' <"$BENCH/sites/apps.txt" | sed 's/ $//'; }

# ---------------------------------------------------------------- pinned commits
make_app_remote acme_pin
add_policy acme_pin main
make_app_remote acme_shared
add_policy acme_shared main
C1="$(remote_head acme_pin)"
# the tip requires acme_shared; the first commit does not
(
  cd "$WORK/acme_pin" || exit 1
  printf 'app_name = "acme_pin"\nrequired_apps = ["acme_shared"]\n' >acme_pin/hooks.py
  git add -A && git commit -q -m "acme_pin: needs acme_shared" && git push -q origin main
)
TIP="$(remote_head acme_pin)"
[[ "$C1" != "$TIP" ]] || fail "the fixture has two commits"

# without a pin: the branch tip, its required app, commit_source branch, and no apps[]
plan acme_pin --site macdev
assert_eq "0" "$CODE" "$ERR"
assert_eq "$TIP branch None acme_shared" "$(printf '%s' "$OUT" | jget - 'd["commit"] + " " + d["commit_source"] + " " + str("apps" in d and d["apps"] or None) + " " + ",".join(r["name"] for r in d["required_apps"])')"
# --commit: hooks.py is read at the pin, so the required app of the tip is not planned
plan acme_pin --commit "$C1" --site macdev
assert_eq "0" "$CODE" "$ERR"
assert_eq "$C1 pin True []" "$(printf '%s' "$OUT" | jget - 'd["commit"] + " " + d["commit_source"] + " " + str(d["can_apply"]) + " " + str(d["required_apps"])')"
assert_eq "Clone acme_pin,Build,Install on macdev,Restart" "$(steps_of)"
assert_eq "False" "$(printf '%s' "$OUT" | jget - '"apps" in d')" "(a single target keeps today's shape)"
# --commit=SHA and an option before the target mean the same
plan --commit="$C1" acme_pin --site macdev
assert_eq "$C1 pin" "$(printf '%s' "$OUT" | jget - 'd["commit"] + " " + d["commit_source"]')"
TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
# a clone that reaches the pin: checked out after get-app, built once, installed
reset_calls
apply acme_pin --commit "$C1" --site macdev
assert_eq "0" "$CODE" "$ERR"
assert_eq "$C1" "$(app_head "$BENCH/apps/acme_pin")" "(the clone is on the pinned commit)"
assert_eq "1" "$(calls '^bench build --app acme_pin$')"
assert_eq "1" "$(calls '^bench --site macdev install-app acme_pin$')"
assert_eq "$C1 pin" "$(printf '%s' "$OUT" | jget - 'd["commit"] + " " + d["commit_source"]')"
assert_contains "$ERR" "apps/acme_pin is at the pinned commit ${C1:0:12}"
# again with the pin: nothing to do. Another commit: refused, nothing is moved
plan acme_pin --commit "$C1" --site macdev
assert_eq "True $C1 pin False" "$(printf '%s' "$OUT" | jget - 'str(d["present"]) + " " + d["commit"] + " " + d["commit_source"] + " " + str(d["changes"])')"
plan acme_pin --commit "$TIP" --site macdev
assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')"
assert_contains "$(printf '%s' "$OUT" | jget - 'd["errors"][0]')" "not the pinned commit"
assert_eq "$C1" "$(app_head "$BENCH/apps/acme_pin")"

# a short pin resolves in the clone (the shallow clone is deepened), and the plan names the full hash
make_app_remote acme_short
add_policy acme_short main
S1="$(remote_head acme_short)"
push_commits acme_short 2
plan acme_short --commit "${S1:0:9}" --site macdev
assert_eq "0" "$CODE" "$ERR"
assert_eq "$S1 pin True" "$(printf '%s' "$OUT" | jget - 'd["commit"] + " " + d["commit_source"] + " " + str(d["can_apply"])')"
TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
MOCK_BENCH_SHALLOW=1 apply acme_short --commit "${S1:0:9}" --site macdev
assert_eq "0" "$CODE" "$ERR"
assert_eq "$S1" "$(app_head "$BENCH/apps/acme_short")" "(a shallow clone is deepened to reach the pin)"

# an unknown commit and a malformed one
run_json app add acme_shared --commit deadbeef1234567 --dry-run --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$ERR"
assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')"
assert_contains "$(printf '%s' "$OUT" | jget - 'd["errors"][0]')" "deadbeef1234567 is not in"
run_json app add acme_shared --commit nothex --dry-run --json --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$ERR" "Invalid commit"
run_json app add acme_shared --commit --dry-run --json --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$ERR" "needs a value"

# a clone that does not reach the pin: refused before the build and the install
make_app_remote acme_nr
add_policy acme_nr main
N1="$(remote_head acme_nr)"
push_commits acme_nr 2
plan acme_nr --commit "$N1" --site macdev
assert_eq "0" "$CODE" "$ERR"
TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
reset_calls
MOCK_BENCH_SHALLOW=1 MOCK_BENCH_GET_APP_NO_REMOTE=1 apply acme_nr --commit "$N1" --site macdev
assert_eq "1" "$CODE" "$ERR"
assert_calls_contain '^bench get-app --skip-assets --branch main '
assert_calls_not_contain '^bench build'
assert_calls_not_contain 'install-app acme_nr'
assert_contains "$ERR" "the clone does not reach the pinned commit (planned ${N1:0:12}, cloned $(remote_head acme_nr | cut -c1-12)); nothing was built or installed."
assert_eq "failed skipped skipped skipped" "$(printf '%s' "$OUT" | jget - '" ".join(s["status"] for s in d["steps"])')"
assert_eq "failed" "$(printf '%s' "$OUT" | jget - 'd["apps"][0]["clone"]')"
assert_eq "skipped skipped" "$(printf '%s' "$OUT" | jget - 'd["apps"][0]["build"] + " " + d["apps"][0]["installs"][0]["status"]')"
if grep -q '^acme_nr ' "$BENCH/sites/macdev/installed_apps"; then fail "acme_nr was installed"; fi

# ---------------------------------------------------------------- a batch with a shared required app
make_app_remote acme_b1 acme_shared2
make_app_remote acme_b2 acme_shared2
make_app_remote acme_shared2
for a in acme_b1 acme_b2 acme_shared2; do add_policy "$a" main; done
cp "$BENCH/sites/apps.txt" "$TMP_DIR/apps.before"
snap="$(snapshot "$BENCH" "$FL_STATE_DIR")"
reset_calls
plan acme_b1 acme_b2 --site macdev
assert_eq "0" "$CODE" "$ERR"
assert_eq "$snap" "$(snapshot "$BENCH" "$FL_STATE_DIR")" "(the plan writes nothing)"
assert_calls_not_contain '^bench (get-app|build|--site macdev install-app)'
assert_eq "Clone acme_shared2,Clone acme_b1,Clone acme_b2,Build,Install acme_b1 on macdev,Install acme_b2 on macdev,Restart" "$(steps_of)"
assert_eq "['acme_shared2', 'acme_b1', 'acme_b2']" "$(printf '%s' "$OUT" | jget - 'd["order"]')"
assert_eq "bench build --apps acme_shared2,acme_b1,acme_b2" "$(printf '%s' "$OUT" | jget - '[s["command"] for s in d["steps"] if s["kind"]=="build"][0]')"
assert_eq "acme_b1 acme_b2" "$(printf '%s' "$OUT" | jget - '" ".join(a["app"] for a in d["apps"])')"
assert_eq "acme_b1:main:branch:False:['acme_shared2']" "$(printf '%s' "$OUT" | jget - '":".join(str(x) for x in [d["apps"][0]["app"], d["apps"][0]["branch"], d["apps"][0]["commit_source"], d["apps"][0]["present"], d["apps"][0]["required_apps"]])')"
assert_eq "$(remote_head acme_b2)" "$(printf '%s' "$OUT" | jget - 'd["apps"][1]["commit"]')"
assert_eq "['acme_shared2']" "$(printf '%s' "$OUT" | jget - '[r["name"] for r in d["required_apps"]]')" "(the shared app is in the graph once)"
assert_eq "acme_b1" "$(printf '%s' "$OUT" | jget - 'd["app"]')" "(the top level keeps the first target)"
assert_eq "64" "$(printf '%s' "$OUT" | jget - 'len(d["token"])')"
TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
plan acme_b1 acme_b2 --site macdev
assert_eq "$TOKEN" "$(printf '%s' "$OUT" | jget - 'd["token"]')" "(the same state, the same token)"
# the token follows the arguments: other sites, another plan
plan acme_b1 acme_b2 --site site2
assert_eq "False" "$([[ "$TOKEN" == "$(printf '%s' "$OUT" | jget - 'd["token"]')" ]] && echo True || echo False)"
# a stale token: apps.txt changed since the review, nothing runs
printf 'extra_app\n' >>"$BENCH/sites/apps.txt"
reset_calls
apply acme_b1 acme_b2 --site macdev
assert_eq "1" "$CODE"; assert_contains "$ERR" "The app add plan changed"
assert_calls_not_contain '^bench (get-app|build|--site macdev install-app)'
cp "$TMP_DIR/apps.before" "$BENCH/sites/apps.txt"
# the same arguments listed twice, an app named twice: refused in the plan
plan acme_b1 acme_b1 --site macdev
assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')"
assert_contains "$(printf '%s' "$OUT" | jget - 'd["errors"][0]')" "is named twice"
# the approved plan runs exactly: one clone of the shared app, before the apps that need it
reset_calls
apply acme_b1 acme_b2 --site macdev
assert_eq "0" "$CODE" "$ERR"
assert_eq "1" "$(calls '^bench get-app .*acme_shared2.git$')" "(one clone of the shared app)"
assert_eq "1" "$(calls '^bench build ')"
assert_calls_contain '^bench build --apps acme_shared2,acme_b1,acme_b2$'
assert_eq "frappe acme_pin acme_short acme_nr acme_shared2 acme_b1 acme_b2" "$(apps_txt)" "(apps.txt order: the shared app first)"
order="$(grep -n -E '^bench (get-app|build|--site macdev install-app)' "$MOCK_LOG" | sed -E 's/^[0-9]+://; s#file://[^ ]*/##; s/\.git$//' | tr '\n' ',')"
case "$order" in
  *"get-app --skip-assets --branch main acme_shared2,bench get-app --skip-assets --branch main acme_b1,bench get-app --skip-assets --branch main acme_b2,bench build --apps acme_shared2,acme_b1,acme_b2,bench --site macdev install-app acme_b1,bench --site macdev install-app acme_b2,"*) ;;
  *) fail "order of the calls: $order" ;;
esac
assert_eq "$TOKEN" "$(printf '%s' "$OUT" | jget - 'd["token"]')"
# the result: per app, the clone, the build and the installs with their migrate
assert_eq "True done done done" "$(printf '%s' "$OUT" | jget - 'str(d["ok"]) + " " + " ".join([d["apps"][0]["clone"], d["apps"][0]["build"], d["apps"][0]["installs"][0]["status"]])')"
assert_eq "acme_b1:True:done:done:macdev:done:done" "$(app_line 0)"
assert_eq "acme_b2:True:done:done:macdev:done:done" "$(app_line 1)"
assert_eq "acme_shared2:True:done:done:0" "$(printf '%s' "$OUT" | jget - '":".join(str(x) for x in [d["required_apps"][0]["app"], d["required_apps"][0]["cloned"], d["required_apps"][0]["clone"], d["required_apps"][0]["build"], len(d["required_apps"][0]["installs"])])')"
assert_eq "" "$(pending_file acme_b1)$(pending_file acme_b2)" "(no record when everything ran)"
# the plan after it: nothing to do
plan acme_b1 acme_b2 --site macdev
assert_eq "False []" "$(printf '%s' "$OUT" | jget - 'str(d["changes"]) + " " + str(d["steps"])')"

# ---------------------------------------------------------------- --install-on per app, and a dependency between targets
make_app_remote acme_i1
make_app_remote acme_i2
add_policy acme_i1 main
add_policy acme_i2 main
plan acme_i1 --install-on macdev acme_i2 --install-on macdev,site2
assert_eq "0" "$CODE" "$ERR"
assert_eq "Clone acme_i1,Clone acme_i2,Build,Install acme_i1 on macdev,Install acme_i2 on macdev,Install acme_i2 on site2,Restart" "$(steps_of)" "(site by site)"
assert_eq "['macdev'] ['macdev', 'site2']" "$(printf '%s' "$OUT" | jget - 'str(d["apps"][0]["install_on"]) + " " + str(d["apps"][1]["install_on"])')"
assert_eq "macdev site2" "$(printf '%s' "$OUT" | jget - '" ".join(s["name"] for s in d["sites"])')"
TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
# --site applies to the apps without --install-on
plan acme_i1 --install-on site2 acme_i2 --site macdev
assert_eq "Clone acme_i1,Clone acme_i2,Build,Install acme_i1 on site2,Install acme_i2 on macdev,Restart" "$(steps_of)" "(site2 from the first target's own list, macdev from --site)"
plan acme_i1 --install-on nosite acme_i2
assert_eq "1" "$CODE"; assert_contains "$ERR" "nosite"
# --commit and --install-on belong to the target before them
plan acme_i1 --commit "$(remote_head acme_i1)" acme_i2 --install-on site2
assert_eq "pin/branch" "$(printf '%s' "$OUT" | jget - 'd["apps"][0]["commit_source"] + "/" + d["apps"][1]["commit_source"]')"
assert_eq "[] ['site2']" "$(printf '%s' "$OUT" | jget - 'str(d["apps"][0]["install_on"]) + " " + str(d["apps"][1]["install_on"])')"
# an install that fails on one site: the others and the restart still run, the records keep it
plan acme_i1 --install-on macdev acme_i2 --install-on macdev,site2
TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
reset_calls
MOCK_BENCH_INSTALL_APP_EXIT=1 apply acme_i1 --install-on macdev acme_i2 --install-on macdev,site2
assert_eq "1" "$CODE" "$ERR"
assert_eq "3" "$(calls 'install-app')" "(every install is tried)"
assert_eq "failed failed failed" "$(printf '%s' "$OUT" | jget - '" ".join(i["status"] for a in d["apps"] for i in a["installs"])')"
assert_eq "failed failed" "$(printf '%s' "$OUT" | jget - 'd["apps"][1]["installs"][0]["migrate"] + " " + d["apps"][1]["installs"][1]["migrate"]')"
assert_eq "install,install" "$(jget "$(pending_file acme_i2)" '",".join(s["kind"] for s in d["steps"])')" "(acme_i2: its two installs)"
assert_eq "macdev" "$(jget "$(pending_file acme_i1)" '",".join(s["target"] for s in d["steps"] if s["kind"]=="install")')" "(acme_i1: its own install only)"
run_fm doctor --json --bench-dir "$BENCH"
assert_contains "$(printf '%s' "$OUT" | jget - '" ".join(c["message"] for c in d["checks"] if c["id"]=="app_add_pending")')" "app add of acme_i2 did not finish"
# one app finishes on its own: the record of acme_i1 plans its install and nothing of acme_i2's
plan acme_i1 --site macdev
assert_eq "Install on macdev" "$(steps_of)"
TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
reset_calls
apply acme_i1 --site macdev
assert_eq "0" "$CODE" "$ERR"
assert_eq "1" "$(calls 'install-app acme_i1')"
assert_eq "0" "$(calls 'install-app acme_i2')"
assert_eq "" "$(pending_file acme_i1)"
assert_file "$(pending_file acme_i2)" "(the other app still has its record)"
# and acme_i2 does too, from the batch plan
plan acme_i2 --install-on macdev,site2
assert_eq "Install on macdev,Install on site2" "$(steps_of)"
TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
apply acme_i2 --install-on macdev,site2
assert_eq "0" "$CODE" "$ERR"
assert_eq "" "$(pending_file acme_i2)"

# a target that requires another target: the required one is cloned and installed first
make_app_remote acme_low
make_app_remote acme_high acme_low
add_policy acme_low main
add_policy acme_high main
plan acme_high acme_low --site macdev
assert_eq "0" "$CODE" "$ERR"
assert_eq "Clone acme_low,Clone acme_high,Build,Install acme_low on macdev,Install acme_high on macdev,Restart" "$(steps_of)"
assert_eq "[]" "$(printf '%s' "$OUT" | jget - 'd["missing_required"]')" "(a target is not a missing required app)"
TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
# acme_low failing to install on the site: acme_high is not tried there
reset_calls
MOCK_BENCH_INSTALL_APP_EXIT=1 apply acme_high acme_low --site macdev
assert_eq "1" "$CODE" "$ERR"
assert_eq "1" "$(calls 'install-app')" "(acme_high waits for acme_low)"
assert_eq "failed skipped" "$(printf '%s' "$OUT" | jget - '" ".join(s["status"] for s in d["steps"] if s["kind"]=="install")')"
assert_eq "after failed install of acme_low" "$(printf '%s' "$OUT" | jget - '[s["reason"] for s in d["steps"] if s["kind"]=="install"][1]')"
assert_eq "skipped" "$(printf '%s' "$OUT" | jget - '[a for a in d["apps"] if a["app"]=="acme_high"][0]["installs"][0]["status"]')"

# a clone that fails in a batch: nothing after it is tried
make_app_remote acme_c1
make_app_remote acme_c2
add_policy acme_c1 main
add_policy acme_c2 main
plan acme_c1 acme_c2 --site macdev
TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
reset_calls
MOCK_BENCH_GET_APP_EARLY_EXIT=1 apply acme_c1 acme_c2 --site macdev
assert_eq "1" "$CODE" "$ERR"
assert_calls_not_contain '^bench (build|--site macdev install-app)'
assert_eq "failed skipped skipped skipped skipped skipped" "$(printf '%s' "$OUT" | jget - '" ".join(s["status"] for s in d["steps"])')"
assert_eq "" "$(pending_file acme_c1)$(pending_file acme_c2)" "(nothing was cloned, so nothing to resume)"

printf 'test-app-batch (%s): ok\n' "$BATCH_PASS"
