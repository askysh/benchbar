#!/usr/bin/env bash
# repair --json: the plan, one step event per action, done with the exit
# code; --dry-run --json prints only the plan and changes nothing; without
# --yes nothing is applied; a failed step carries its message; a sudo step
# without a terminal is skipped. Every stdout line is a JSON object.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/frappe-bench"
make_fake_bench "$BENCH"
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
printf '127.0.0.1 macdev\n' >>"$FL_HOSTS_FILE"
events() { set +e; EV="$("$FM" repair --json "$@" --bench-dir "$BENCH" 2>/dev/null)"; CODE=$?; set -e; }
ev() { printf '%s\n' "$EV" | python3 -c "import json,sys; e=[json.loads(l) for l in sys.stdin if l.strip()]; print($1)"; }

# ---- nothing to do: a plan with no actions, done 0
events --yes
assert_eq "0" "$CODE" "$EV"
assert_eq "plan done" "$(ev '" ".join(x["event"] for x in e)')"
assert_eq "[]" "$(ev 'e[0]["actions"]')"

# ---- break two things: the Procfile and the built assets
rm "$BENCH/Procfile.lean"
rm -rf "$BENCH/apps/frappe/frappe/public/dist"
snap="$(snapshot "$BENCH")"

# dry run: exactly one line, the plan, and nothing changed
events --dry-run
assert_eq "0" "$CODE" "$EV"
assert_eq "1" "$(printf '%s\n' "$EV" | grep -c .)"
assert_eq "plan" "$(ev 'e[0]["event"]')"
assert_eq "True" "$(ev 'e[0]["dry_run"]')"
assert_eq "build write_procfile" "$(ev '" ".join(a["id"] for a in e[0]["actions"])')"
assert_eq "['Built assets']" "$(ev '[a["fixes"] for a in e[0]["actions"] if a["id"]=="build"][0]')"
assert_eq "$snap" "$(snapshot "$BENCH")" "(dry run)"

# without --yes: the plan, then done 1, nothing applied
events
assert_eq "1" "$CODE" "$EV"
assert_eq "plan done" "$(ev '" ".join(x["event"] for x in e)')"
assert_eq "1" "$(ev 'e[-1]["exit_code"]')"
assert_eq "$snap" "$(snapshot "$BENCH")" "(no --yes, nothing changed)"

# ---- the plan's token (UI-15): the dry run prints it, --apply runs exactly that plan
events --dry-run
tok="$(ev 'e[0]["token"]')"
assert_eq "64" "${#tok}" "(the dry run prints a token)"
events --dry-run
assert_eq "$tok" "$(ev 'e[0]["token"]')" "(the same plan, the same token)"
# a bad or lone --apply, and --apply with --dry-run, are refused before anything changes
events --apply nope --yes
assert_eq "1" "$CODE" "$EV"
assert_contains "$(ev 'e[-1]["error"]')" "needs the token of a plan"
events --apply "$tok"
assert_eq "1" "$CODE" "$EV"
assert_contains "$(ev 'e[-1]["error"]')" "--apply TOKEN --yes"
events --apply "$tok" --dry-run
assert_eq "1" "$CODE" "$EV"
assert_contains "$(ev 'e[-1]["error"]')" "--apply runs the plan"
# the bench changed since the dry run (a new action): refused, nothing changed
sed_inplace '/macdev/d' "$FL_HOSTS_FILE"
snap2="$(snapshot "$BENCH")"; hosts2="$(cat "$FL_HOSTS_FILE")"
events --apply "$tok" --yes
assert_eq "1" "$CODE" "$EV"
assert_contains "$(ev 'e[-1]["error"]')" "plan changed since it was shown"
assert_not_contains "$EV" '"event":"step"'
assert_eq "$snap2" "$(snapshot "$BENCH")" "(a stale token changes nothing)"
assert_eq "$hosts2" "$(cat "$FL_HOSTS_FILE")" "(a stale token leaves the hosts file)"
printf '127.0.0.1 macdev\n' >>"$FL_HOSTS_FILE"
# an expired token is named as such
FL_PLAN_NOW=$(( FL_PLAN_NOW + 7200 )) events --apply "$tok" --yes
assert_eq "1" "$CODE" "$EV"
assert_contains "$(ev 'e[-1]["error"]')" "expired"
assert_eq "$snap" "$(snapshot "$BENCH")" "(an expired token changes nothing)"
# the right token runs the plan
events --apply "$tok" --yes
assert_eq "0" "$CODE" "$EV"
assert_eq "build:running build:done write_procfile:running write_procfile:done" "$(ev '" ".join(x["action"]+":"+x["status"] for x in e if x["event"]=="step")')"
assert_eq "$tok" "$(ev 'e[0]["token"]')" "(the real run's plan carries the token)"
assert_file "$BENCH/Procfile.lean"
rm "$BENCH/Procfile.lean"
rm -rf "$BENCH/apps/frappe/frappe/public/dist"
snap="$(snapshot "$BENCH")"

# --yes without a token still runs (a person, or an older app): running then done for each action, done 0, the log is named
events --yes
assert_eq "0" "$CODE" "$EV"
assert_eq "plan step step step step done" "$(ev '" ".join(x["event"] for x in e)')"
assert_eq "build:running build:done write_procfile:running write_procfile:done" "$(ev '" ".join(x["action"]+":"+x["status"] for x in e if x["event"]=="step")')"
assert_eq "0" "$(ev 'e[-1]["exit_code"]')"
assert_file "$(ev 'e[-1]["log"]')"
assert_file "$BENCH/Procfile.lean"

# ---- a failing step carries the CLI's message
rm -rf "$BENCH/apps/frappe/frappe/public/dist"
MOCK_BENCH_BUILD_EXIT=1 events --yes
assert_eq "1" "$CODE"
assert_eq "failed" "$(ev '[x["status"] for x in e if x.get("action")=="build"][-1]')"
assert_contains "$(ev '[x["message"] for x in e if x.get("action")=="build"][-1]')" "[FAIL]"
assert_eq "1" "$(ev 'e[-1]["exit_code"]')"

# ---- a sudo step without a terminal (the app) is skipped and says so
sed_inplace '/macdev/d' "$FL_HOSTS_FILE"
touch "$MOCK_STATE/sudo_refused"
events --yes
assert_eq "True" "$(ev '[a["sudo"] for a in e[0]["actions"] if a["id"]=="hosts_entry"][0]')"
assert_eq "skipped" "$(ev '[x["status"] for x in e if x.get("action")=="hosts_entry"][-1]')"
assert_contains "$(ev '[x["message"] for x in e if x.get("action")=="hosts_entry"][-1]')" "sudo"

# ---- a declined hosts step (the person answers no) is skipped, not done, and
# the fix it prints is a benchbar repair, which writes inside the marker block
rm -f "$MOCK_STATE/sudo_refused"
sed_inplace '/macdev/d' "$FL_HOSTS_FILE"
before="$(cat "$FL_HOSTS_FILE")"
set +e
OUT="$(FL_BENCH_DIR="$BENCH" FL_SITE=macdev FL_SELF=benchbar FL_BREW_PREFIX="$MOCK_BREW_PREFIX" bash -c '
  for f in ui run platform version-policy state templates shellrc benchinfo process launchd benchstate discovery ports checks sudo mariadb repair service sites; do . "$0/lib/frappe-local/$f.sh"; done
  FL_PLAIN=1; fl_ui_init
  fl_confirm() { fl_warn "declined: $1"; return 1; }
  FL_STEP_RESULT=done
  act_hosts_entry; code=$?
  printf "code=%s result=%s\n" "$code" "$FL_STEP_RESULT"' "$ROOT" 2>&1)"; CODE=$?
set -e
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "code=0 result=skipped"
assert_contains "$OUT" "benchbar repair --bench-dir ${BENCH}   (adds '127.0.0.1 macdev' inside the benchbar block)"
assert_not_contains "$OUT" "sudo tee -a"
assert_eq "$before" "$(cat "$FL_HOSTS_FILE")" "(a declined step writes nothing)"

printf 'test-repair-json: ok\n'
