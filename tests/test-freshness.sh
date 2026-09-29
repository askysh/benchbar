#!/usr/bin/env bash
# Dependency freshness: focus apps (inferred from local changes, another
# branch, a recent commit of your own; pinned with app focus / unfocus),
# the transitive required_apps graph, doctor's dependency_behind and
# apps_behind, the once a day fetch and its cache, and offline runs.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=tests/lib/apps-fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apps-fixtures.sh"

BENCH="$HOME/frappe-bench"
make_fake_bench "$BENCH" macdev
rmdir "$BENCH/apps/erpnext"
printf 'frappe\n' >"$BENCH/sites/apps.txt"
# the local git user; the fixtures' commits are by tester@example.com
git config --global user.email me@example.com

# my_app -> mid_dep -> core_dep (transitive); other_app needs nothing
make_app_remote core_dep
make_app_remote mid_dep core_dep
make_app_remote my_app mid_dep
make_app_remote other_app
for a in core_dep mid_dep my_app other_app; do
  add_policy "$a" main
  git clone -q --origin upstream --branch main "file://${REMOTES}/${a}.git" "$BENCH/apps/$a"
  printf '%s\n' "$a" >>"$BENCH/sites/apps.txt"
done
NOW="$(date +%s)"
DAY=86400

check() { printf '%s' "$1" | jget - "[c for c in d['checks'] if c['id']=='$2']"; }
levels() { printf '%s' "$1" | jget - "' '.join(c['level'] for c in d['checks'] if c['id']=='$2')"; }
app_field() { printf '%s' "$1" | jget - "[a for a in d['apps'] if a['name']=='$2'][0]['$3']"; }

# ---- nothing is a focus app yet: one ok row, no fetch
reset_calls
run_fm doctor --json --bench-dir "$BENCH"
assert_eq "ok" "$(levels "$OUT" dependency_behind)"
assert_contains "$(check "$OUT" dependency_behind)" "no focus app"
assert_eq "ok" "$(levels "$OUT" apps_behind)"
assert_calls_not_contain 'fetch'

# ---- a commit of mine makes my_app a focus app (and only my_app)
(cd "$BENCH/apps/my_app" && printf 'x\n' >mine.txt && git add mine.txt && GIT_AUTHOR_EMAIL=me@example.com git commit -q -m "my change")
run_fm app focus --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "True" "$(app_field "$OUT" my_app focus)"
assert_eq "['your commit today']" "$(app_field "$OUT" my_app focus_reasons)"
assert_eq "auto" "$(app_field "$OUT" my_app focus_pin)"
assert_eq "False" "$(app_field "$OUT" mid_dep focus)"
assert_eq "['my_app']" "$(app_field "$OUT" mid_dep needed_by)"
assert_eq "['my_app']" "$(app_field "$OUT" core_dep needed_by)"
assert_eq "['core_dep']" "$(app_field "$OUT" mid_dep requires)"
assert_eq "[]" "$(app_field "$OUT" other_app needed_by)"
assert_eq "[]" "$(app_field "$OUT" my_app needed_by)"
assert_eq "0" "$(app_field "$OUT" mid_dep behind)"
assert_eq "upstream/main" "$(app_field "$OUT" mid_dep upstream)"
assert_eq "None" "$(printf '%s' "$OUT" | jget - 'd["fetched_at"]')"
assert_eq "1" "$(printf '%s' "$OUT" | jget - 'd["schema_version"]')"
# app list --json carries the same fields
run_fm app list --json --no-sites --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "True" "$(app_field "$OUT" my_app focus)"
assert_eq "['my_app']" "$(app_field "$OUT" core_dep needed_by)"

# ---- the dependencies move on; the focus app moves on too (never a warning)
GIT_COMMITTER_DATE="@$((NOW - 12 * DAY)) +0000" push_commits core_dep 3
push_commits mid_dep 1
push_commits my_app 5
push_commits other_app 2
# other apps are never fetched by doctor: their numbers are from your own fetches
git -C "$BENCH/apps/other_app" fetch -q upstream
reset_calls
FL_NOW="$NOW" run_fm doctor --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain "^git -C ${BENCH}/apps/mid_dep fetch --quiet --no-tags upstream \+refs/heads/main:refs/remotes/upstream/main$"
assert_calls_contain "^git -C ${BENCH}/apps/core_dep fetch"
assert_calls_not_contain "apps/(my_app|other_app) fetch"
assert_eq "warn warn" "$(levels "$OUT" dependency_behind)"
msgs="$(printf '%s' "$OUT" | jget - "'|'.join(c['message'] for c in d['checks'] if c['id']=='dependency_behind')")"
assert_contains "$msgs" "mid_dep (needed by my_app) is 1 commit behind upstream/main"
assert_contains "$msgs" "core_dep (needed by my_app) is 3 commits / 12 days behind upstream/main"
assert_not_contains "$msgs" "my_app ("
fixes="$(printf '%s' "$OUT" | jget - "'|'.join(c['fix_command'] for c in d['checks'] if c['id']=='dependency_behind')")"
assert_contains "$fixes" "benchbar app update core_dep --bench-dir ${BENCH}"
assert_not_contains "$fixes" "bench update"
assert_contains "$(check "$OUT" apps_behind)" "other_app 2"
assert_not_contains "$(check "$OUT" apps_behind)" "my_app"
assert_eq "ok" "$(levels "$OUT" apps_behind)"
# the text form: one [WARN] and fix line per dependency
FL_NOW="$NOW" run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] Dependencies of focus apps: core_dep (needed by my_app) is 3 commits / 12 days behind upstream/main"
assert_contains "$OUT" "fix: benchbar app update core_dep --bench-dir ${BENCH}"
assert_contains "$OUT" "[WARN] Dependencies of focus apps: mid_dep (needed by my_app)"
run_fm doctor --fix-hints --bench-dir "$BENCH"
assert_contains "$OUT" "benchbar app update mid_dep --bench-dir ${BENCH}"

# ---- at most once a day: the next runs read the cache
reset_calls
FL_NOW="$((NOW + 3600))" run_fm doctor --json --bench-dir "$BENCH"
assert_calls_not_contain ' fetch'
assert_eq "warn warn" "$(levels "$OUT" dependency_behind)"
push_commits mid_dep 1
reset_calls
FL_NOW="$((NOW + 2 * 3600))" run_fm doctor --json --bench-dir "$BENCH"
assert_calls_not_contain ' fetch'
assert_contains "$(check "$OUT" dependency_behind)" "mid_dep (needed by my_app) is 1 commit behind"
reset_calls
FL_NOW="$((NOW + DAY + 60))" run_fm doctor --json --bench-dir "$BENCH"
assert_calls_contain 'apps/mid_dep fetch'
assert_contains "$(check "$OUT" dependency_behind)" "mid_dep (needed by my_app) is 2 commits"
# OFFLINE=1 never fetches
reset_calls
OFFLINE=1 FL_NOW="$((NOW + 3 * DAY))" run_fm doctor --json --bench-dir "$BENCH"
assert_calls_not_contain ' fetch'

# ---- no network: a failed fetch is no FAIL, the numbers are the last fetch's
mv "$REMOTES/mid_dep.git" "$REMOTES/mid_dep.git.aside"
mv "$REMOTES/core_dep.git" "$REMOTES/core_dep.git.aside"
statef="$(ls "$FL_STATE_DIR"/benches/*.freshness)"
before="$(sed -n 's/^FETCHED_AT=//p' "$statef")"
reset_calls
FL_NOW="$((NOW + 4 * DAY))" run_fm doctor --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain 'apps/mid_dep fetch'
assert_eq "$before" "$(sed -n 's/^FETCHED_AT=//p' "$statef")" "(a failed fetch keeps the last good time)"
assert_eq "$((NOW + 4 * DAY))" "$(sed -n 's/^TRIED_AT=//p' "$statef")"
assert_contains "$(check "$OUT" dependency_behind)" "offline since"
assert_eq "0" "$(printf '%s' "$OUT" | jget - 'd["summary"]["fail"]')"
# retried an hour later, not sooner
reset_calls
FL_NOW="$((NOW + 4 * DAY + 600))" run_fm doctor --json --bench-dir "$BENCH"
assert_calls_not_contain ' fetch'
mv "$REMOTES/mid_dep.git.aside" "$REMOTES/mid_dep.git"
mv "$REMOTES/core_dep.git.aside" "$REMOTES/core_dep.git"

# ---- never fetched (no tracking ref): unknown, never a warning or FAIL
git -C "$BENCH/apps/mid_dep" update-ref -d refs/remotes/upstream/main
git -C "$BENCH/apps/core_dep" merge -q --ff-only upstream/main
OFFLINE=1 run_fm doctor --json --bench-dir "$BENCH"
assert_eq "ok" "$(levels "$OUT" dependency_behind)"
assert_contains "$(check "$OUT" dependency_behind)" "unknown for mid_dep"
OFFLINE=1 run_fm app focus --json --bench-dir "$BENCH"
assert_eq "None" "$(app_field "$OUT" mid_dep behind)"
git -C "$BENCH/apps/mid_dep" fetch -q upstream "+refs/heads/main:refs/remotes/upstream/main"

# ---- a recent commit of mine counts for FL_FOCUS_DAYS days only
OFFLINE=1 FL_NOW="$((NOW + 20 * DAY))" run_fm app focus --json --bench-dir "$BENCH"
assert_eq "False" "$(app_field "$OUT" my_app focus)"
OFFLINE=1 FL_NOW="$((NOW + 20 * DAY))" run_fm doctor --json --bench-dir "$BENCH"
assert_contains "$(check "$OUT" dependency_behind)" "no focus app"

# ---- local changes and another branch count too
printf 'wip\n' >>"$BENCH/apps/other_app/other_app/hooks.py"
git -C "$BENCH/apps/core_dep" checkout -q -b feature
OFFLINE=1 FL_NOW="$((NOW + 20 * DAY))" run_fm app focus --json --bench-dir "$BENCH"
assert_eq "['local changes']" "$(app_field "$OUT" other_app focus_reasons)"
assert_eq "['on feature, not main']" "$(app_field "$OUT" core_dep focus_reasons)"
git -C "$BENCH/apps/other_app" checkout -q -- .
git -C "$BENCH/apps/core_dep" checkout -q main

# ---- pins: focus, ignore, auto
run_fm app focus nosuch --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "nosuch is not an app of this bench"
run_fm app focus my_app --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "focus True ['pinned']" "$(printf '%s' "$OUT" | jget - '" ".join(str(d[k]) for k in ("pin","focus","reasons"))')"
OFFLINE=1 FL_NOW="$((NOW + 20 * DAY))" run_fm doctor --json --bench-dir "$BENCH"
assert_contains "$(check "$OUT" dependency_behind)" "mid_dep (needed by my_app)"
# a pinned focus app that is itself behind is still never warned about
assert_not_contains "$(check "$OUT" dependency_behind)" "my_app (needed"
# ignore: an app I committed to today is not a focus app
run_fm app unfocus my_app --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "my_app is not a focus app (pinned)"
OFFLINE=1 run_fm app focus --json --bench-dir "$BENCH"
assert_eq "False ignore" "$(app_field "$OUT" my_app focus) $(app_field "$OUT" my_app focus_pin)"
grep -q '^APP_FOCUS=my_app=ignore$' "$FL_STATE_DIR"/benches/frappe-bench-*.env || fail "the pin is in the bench's state file"
# auto: inferred again (my commit of today)
run_fm app focus my_app --auto --bench-dir "$BENCH"
assert_contains "$OUT" "my_app: inferred again, a focus app (your commit today)"
grep -q '^APP_FOCUS=' "$FL_STATE_DIR"/benches/frappe-bench-*.env || fail "the key stays, empty"
! grep -q 'my_app=' "$FL_STATE_DIR"/benches/frappe-bench-*.env || fail "auto clears the pin"
# dry run writes nothing
run_fm app focus other_app --dry-run --bench-dir "$BENCH"
! grep -q 'other_app=' "$FL_STATE_DIR"/benches/frappe-bench-*.env || fail "dry run wrote a pin"

# ---- the text list and a manual fetch
reset_calls
run_fm app focus --fetch --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "your commit today"
assert_contains "$OUT" "dependencies last fetched today"
assert_calls_contain 'apps/mid_dep fetch'

# ---- a dependency with local changes gets a fix that does not touch them
printf 'wip\n' >>"$BENCH/apps/mid_dep/mid_dep/hooks.py"
run_fm app unfocus mid_dep --bench-dir "$BENCH"
push_commits mid_dep 1
run_fm app focus --fetch --json --bench-dir "$BENCH" >/dev/null
OFFLINE=1 run_fm doctor --json --bench-dir "$BENCH"
assert_contains "$(check "$OUT" dependency_behind)" "git status   (commit or stash the changes, then: benchbar app update mid_dep"

printf 'test-freshness: ok\n'
