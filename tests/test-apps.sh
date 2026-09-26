#!/usr/bin/env bash
# App commands: app list, app add (by name, by URL, required apps, refusals,
# a half finished clone), app install, app update (changelog, backups,
# dirty, detached, diverged, shallow), and the two doctor checks.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=tests/lib/apps-fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apps-fixtures.sh"

BENCH="$HOME/frappe-bench"
make_fake_bench "$BENCH" macdev
printf 'frappe\n' >"$BENCH/sites/apps.txt"
rmdir "$BENCH/apps/erpnext"
printf 'frappe 15.0.0\n' >"$BENCH/sites/macdev/installed_apps"

make_app_remote acme_crm
make_app_remote acme_base
make_app_remote acme_hr acme_base
make_app_remote acme_orphan nosuchapp
add_policy acme_crm main
add_policy acme_base main
add_policy acme_hr version-15
add_policy acme_orphan main

# ---- refusals before anything changes
run_fm app add nosuch --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "Unknown app 'nosuch'"
run_fm app add "https://user:tok@example.com/acme/x.git" --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "carries a user name or token"
run_fm app add acme_crm --site nosite --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "No site 'nosite'"

# ---- dry run: plan only, nothing written, no get-app
reset_calls; snap="$(snapshot "$BENCH" "$FL_STATE_DIR")"
run_fm app add acme_crm --site macdev --dry-run --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "bench get-app --skip-assets --branch main file://${REMOTES}/acme_crm.git"
assert_contains "$OUT" "bench --site macdev install-app acme_crm"
assert_contains "$OUT" "dry-run: nothing was changed"
assert_calls_not_contain '^bench get-app'
assert_calls_not_contain '^bench --site macdev install-app'
assert_eq "$snap" "$(snapshot "$BENCH" "$FL_STATE_DIR")" "(dry run writes nothing)"

# ---- add by name: preflight, get-app without --overwrite or --resolve-deps, install, build
reset_calls
run_fm app add acme_crm --site macdev --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain "^git ls-remote --exit-code --heads --tags file://${REMOTES}/acme_crm.git main$"
assert_calls_contain "^bench get-app --skip-assets --branch main file://${REMOTES}/acme_crm.git$"
assert_calls_not_contain 'get-app.*(--overwrite|--resolve-deps)'
assert_calls_contain '^bench --site macdev install-app acme_crm$'
assert_calls_contain '^bench build --app acme_crm$'
assert_contains "$OUT" "1. Clone acme_crm: done"
assert_contains "$OUT" "[OK] acme_crm is installed on macdev"
assert_eq "frappe acme_crm" "$(tr '\n' ' ' <"$BENCH/sites/apps.txt" | sed 's/ $//')"
assert_eq "main" "$(git -C "$BENCH/apps/acme_crm" symbolic-ref --short HEAD)"
assert_eq "upstream" "$(git -C "$BENCH/apps/acme_crm" remote)"
# the second run is a no-op
reset_calls
run_fm app add acme_crm --site macdev --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "unchanged: acme_crm is on main and installed on macdev"
assert_calls_not_contain '^bench (get-app|build|--site macdev install-app)'

# ---- app list
run_fm app list --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "frappe,acme_crm" "$(printf '%s' "$OUT" | jget - '",".join(a["name"] for a in d["apps"])')"
assert_eq "main upstream False False ['macdev'] True" "$(printf '%s' "$OUT" | jget - '" ".join(str(x) for x in [d["apps"][1][k] for k in ("branch","remote","dirty","shallow","sites","in_apps_txt")])')"
assert_eq "file://${REMOTES}/acme_crm.git" "$(printf '%s' "$OUT" | jget - 'd["apps"][1]["repo"]')"
assert_eq "40" "$(printf '%s' "$OUT" | jget - 'len(d["apps"][1]["commit"])')"
assert_eq "None" "$(printf '%s' "$OUT" | jget - 'd["sites_error"]')"
# --no-sites reads the cache only: no bench call
reset_calls
run_fm app list --no-sites --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "acme_crm"
assert_contains "$OUT" "macdev"
assert_calls_not_contain '^bench '
# a database that does not answer: the cached lists and an error
MOCK_BENCH_LIST_APPS_EXIT=1 run_fm app list --json --bench-dir "$BENCH"
assert_contains "$(printf '%s' "$OUT" | jget - 'd["sites_error"]')" "list-apps failed for macdev"
assert_eq "['macdev']" "$(printf '%s' "$OUT" | jget - 'd["apps"][1]["sites"]')"

# ---- by URL with --name and --branch, no site: cloned and built only
reset_calls
run_fm app add "file://${REMOTES}/acme_base.git" --branch version-15 --name acme_base --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain "^bench get-app --skip-assets --branch version-15 file://${REMOTES}/acme_base.git$"
assert_calls_not_contain 'install-app acme_base'
assert_eq "version-15" "$(git -C "$BENCH/apps/acme_base" symbolic-ref --short HEAD)"
# the same app on another branch is refused with the manual commands
run_fm app add acme_base --site macdev --bench-dir "$BENCH"
assert_eq "1" "$CODE"
assert_contains "$OUT" "apps/acme_base is on version-15, not main"
assert_contains "$OUT" "git fetch upstream main && git checkout main"

# ---- a branch the remote does not have: refused before any change
reset_calls
run_fm app add "file://${REMOTES}/acme_hr.git" --branch nope --bench-dir "$BENCH"
assert_eq "1" "$CODE"
assert_contains "$OUT" "branch nope not found"
assert_contains "$OUT" "remote branches: main version-15"
assert_calls_not_contain '^bench get-app'

# ---- a private repo fails fast with a fix, for SSH (a host alias) and HTTPS
reset_calls
MOCK_GIT_LSREMOTE_EXIT=128 run_fm app add "git@work-gh:acme/private.git" --branch main --bench-dir "$BENCH"
assert_eq "1" "$CODE"
assert_contains "$OUT" "cannot read git@work-gh:acme/private.git"
assert_contains "$OUT" "ssh -T git@work-gh"
assert_calls_not_contain '^bench get-app'
MOCK_GIT_LSREMOTE_EXIT=128 run_fm app add "https://github.com/acme/private" --branch main --bench-dir "$BENCH"
assert_eq "1" "$CODE"
assert_contains "$OUT" "gh auth setup-git"
assert_eq "frappe acme_crm acme_base" "$(tr '\n' ' ' <"$BENCH/sites/apps.txt" | sed 's/ $//')"

# ---- required apps: resolved through apps.tsv, cloned first, one build
make_app_remote acme_base2
add_policy acme_base2 main
make_app_remote acme_payroll acme_base2
add_policy acme_payroll main
reset_calls
run_fm app add acme_payroll --site macdev --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "acme_payroll requires apps that are not in the bench yet"
assert_calls_contain '^bench get-app --skip-assets --branch main .*acme_base2.git$'
assert_calls_contain '^bench build --apps acme_base2,acme_payroll$'
assert_eq "frappe acme_crm acme_base acme_payroll acme_base2" "$(tr '\n' ' ' <"$BENCH/sites/apps.txt" | sed 's/ $//')"
# an unknown required app stops before its install
reset_calls
run_fm app add acme_orphan --site macdev --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE"
assert_contains "$OUT" "acme_orphan requires nosuchapp"
assert_calls_not_contain 'install-app acme_orphan'
# the clone stays (it is a real app), and a second add names the missing app
run_fm app add acme_orphan --site macdev --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE"
assert_contains "$OUT" "benchbar app add nosuchapp"

# ---- get-app failing half way after bench listed the app: benchbar never edits
# sites/ (AGENTS.md), so the folder and the apps.txt line stay and the fix is printed
make_app_remote acme_half
add_policy acme_half main
cp "$BENCH/sites/apps.txt" "$TMP_DIR/apps.txt.before"
MOCK_BENCH_GET_APP_EXIT=1 run_fm app add acme_half --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE"
assert_contains "$OUT" "apps/acme_half is half cloned and already listed in sites/apps.txt"
assert_contains "$OUT" "bench remove-app acme_half"
grep -qx acme_half "$BENCH/sites/apps.txt" || fail "bench's own apps.txt line is left to bench"
[[ "$(grep -v -x acme_half "$BENCH/sites/apps.txt")" == "$(cat "$TMP_DIR/apps.txt.before")" ]] || fail "nothing else in apps.txt changed"

# ---- install-app failing: the clone stays, a rerun resumes with the install only
mkdir -p "$BENCH/sites/site2"; printf '{}\n' >"$BENCH/sites/site2/site_config.json"
printf 'frappe 15.0.0\n' >"$BENCH/sites/site2/installed_apps"
MOCK_BENCH_INSTALL_APP_EXIT=1 run_fm app add acme_half --site site2 --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE"
assert_contains "$OUT" "Install on site2: failed"
assert_contains "$OUT" "bench --site site2 install-app acme_half"
assert_file "$BENCH/apps/acme_half"
reset_calls
run_fm app add acme_half --site site2 --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain '^bench get-app'
assert_calls_contain '^bench --site site2 install-app acme_half$'

# ---- app install
run_fm app install acme_crm --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "Usage: benchbar app install NAME --site SITE"
run_fm app install nosuch --site site2 --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "benchbar app add nosuch"
reset_calls
run_fm app install acme_crm --site site2 --dry-run --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain 'install-app'
run_fm app install acme_crm --site site2 --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "[OK] acme_crm is installed on site2"
run_fm app install acme_crm --site site2 --yes --bench-dir "$BENCH"
assert_contains "$OUT" "unchanged: acme_crm is already installed on site2"

# ---- update: changelog, dry run JSON, backups, migrate, build, then unchanged
push_commits acme_crm 2
old="$(app_head "$BENCH/apps/acme_crm")"
reset_calls
snap="$(snapshot "$BENCH/sites" "$BENCH/apps/acme_crm/acme_crm" "$BENCH/apps/acme_crm/pyproject.toml" "$FL_STATE_DIR")"
run_fm app update acme_crm --dry-run --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "$snap" "$(snapshot "$BENCH/sites" "$BENCH/apps/acme_crm/acme_crm" "$BENCH/apps/acme_crm/pyproject.toml" "$FL_STATE_DIR")" "(update dry run: only .git changes)"
assert_eq "2" "$(printf '%s' "$OUT" | jget - 'd["commits_total"]')"
assert_eq "acme_crm: change 2 on main|acme_crm: change 1 on main" "$(printf '%s' "$OUT" | jget - '"|".join(c["subject"] for c in d["commits"])')"
assert_eq "['macdev', 'site2']" "$(printf '%s' "$OUT" | jget - 'd["sites"]')"
assert_eq "Back up macdev,Back up site2,Fast forward,Python requirements,Node requirements,Migrate macdev,Migrate site2,Build" "$(printf '%s' "$OUT" | jget - '",".join(s["name"] for s in d["steps"])')"
assert_eq "$old" "$(printf '%s' "$OUT" | jget - 'd["from"]')"
assert_eq "$old" "$(app_head "$BENCH/apps/acme_crm")" "(dry run keeps the code)"
assert_calls_not_contain '^bench --site .* (backup|migrate)'
run_fm app update acme_crm --json --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "add --dry-run"
# human dry run shows the changelog
run_fm app update acme_crm --dry-run --bench-dir "$BENCH"
assert_contains "$OUT" "2 commit(s)"
assert_contains "$OUT" "acme_crm: change 1 on main"
reset_calls
run_fm app update acme_crm --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^bench --site macdev backup$'
assert_calls_contain '^bench --site site2 backup$'
assert_calls_contain '^git -C .*apps/acme_crm merge --ff-only --quiet [0-9a-f]{40}$'
assert_calls_contain '^bench setup requirements --python acme_crm$'
assert_calls_contain '^bench setup requirements --node acme_crm$'
assert_calls_contain '^bench --site macdev migrate$'
assert_calls_contain '^bench build --app acme_crm$'
assert_calls_not_contain '^bench update'
[[ "$(app_head "$BENCH/apps/acme_crm")" != "$old" ]] || fail "update moves the app"
assert_eq "$(git -C "$REMOTES/acme_crm.git" rev-parse main)" "$(app_head "$BENCH/apps/acme_crm")"
# backups come before the code changes: the first backup before the merge
b="$(grep -n 'backup$' "$MOCK_LOG" | head -n1 | cut -d: -f1)"; m="$(grep -n 'merge --ff-only' "$MOCK_LOG" | head -n1 | cut -d: -f1)"
[[ "$b" -lt "$m" ]] || fail "site backups run before the merge"
reset_calls
run_fm app update acme_crm --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "unchanged: acme_crm is up to date with upstream/main"
assert_calls_not_contain '^bench '
# --skip-backup
push_commits acme_crm 1
reset_calls
run_fm app update acme_crm --skip-backup --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain 'backup$'
assert_calls_contain '^bench --site macdev migrate$'
# a failed migrate prints the way back, never runs it
push_commits acme_crm 1
before="$(app_head "$BENCH/apps/acme_crm")"
MOCK_BENCH_MIGRATE_EXIT=1 run_fm app update acme_crm --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE"
assert_contains "$OUT" "git -C ${BENCH}/apps/acme_crm reset --hard ${before}"
assert_calls_not_contain 'reset --hard'

# ---- refusals: dirty, detached, diverged
printf 'local\n' >>"$BENCH/apps/acme_crm/acme_crm/__init__.py"
run_fm app update acme_crm --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "has local changes"
git -C "$BENCH/apps/acme_crm" checkout -q -- .
git -C "$BENCH/apps/acme_crm" checkout -q --detach
run_fm app update acme_crm --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "detached HEAD"
git -C "$BENCH/apps/acme_crm" checkout -q main
printf 'mine\n' >"$BENCH/apps/acme_crm/mine.txt"
git -C "$BENCH/apps/acme_crm" add mine.txt
git -C "$BENCH/apps/acme_crm" commit -q -m "local work"
push_commits acme_crm 1
run_fm app update acme_crm --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "diverged, not a fast forward"

# ---- a shallow clone (bench's shallow_clone) updates with its changelog
MOCK_BENCH_SHALLOW=1 run_fm app add acme_hr --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "true" "$(git -C "$BENCH/apps/acme_hr" rev-parse --is-shallow-repository)"
push_commits acme_hr 3 version-15
run_fm app update acme_hr --dry-run --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "3" "$(printf '%s' "$OUT" | jget - 'd["commits_total"]')"
run_fm app update acme_hr --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "$(git -C "$REMOTES/acme_hr.git" rev-parse version-15)" "$(app_head "$BENCH/apps/acme_hr")"

# ---- doctor: apps.txt and the branch policy, from local reads only
reset_calls
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[OK] Apps in apps.txt"
assert_contains "$OUT" "[WARN] App branches: acme_base is on version-15 (policy main)"
# bench version is the bench_version check's own call; the app checks add none
assert_calls_not_contain '^bench (--site|get-app|build|setup|list-apps)'
assert_calls_not_contain '^git (ls-remote|fetch|clone|pull)'
printf 'ghost\n' >>"$BENCH/sites/apps.txt"
mkdir -p "$BENCH/apps/stray/stray"; git -C "$BENCH/apps/stray" init -q; printf '' >"$BENCH/apps/stray/stray/__init__.py"
run_fm doctor --json --bench-dir "$BENCH"
assert_eq "fail" "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"]=="apps_txt"][0]["level"]')"
assert_eq "None" "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"]=="apps_txt"][0]["action"]')"
sed_inplace '/^ghost$/d' "$BENCH/sites/apps.txt"
run_fm doctor --json --bench-dir "$BENCH"
assert_contains "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"]=="apps_txt"][0]["message"]')" "apps/stray is a git app that is not in sites/apps.txt"

printf 'test-apps: ok\n'
