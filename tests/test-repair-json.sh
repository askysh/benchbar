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

# --yes: running then done for each action, done 0, the log is named
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

printf 'test-repair-json: ok\n'
