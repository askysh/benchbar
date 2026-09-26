#!/usr/bin/env bash
# The team lockfile: lock write (refusals, diff, unchanged), lock check
# (every drift kind, JSON), lock apply (clone, branch, fast forward,
# skips, dry run, unchanged), the parser's refusals, --lock and the
# doctor checks.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=tests/lib/apps-fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apps-fixtures.sh"

BENCH="$HOME/frappe-bench"
LOCK="$BENCH/benchbar.toml"
make_fake_bench "$BENCH" macdev
rmdir "$BENCH/apps/erpnext"
printf 'frappe 15.0.0\n' >"$BENCH/sites/macdev/installed_apps"
# frappe as a real clone, like bench init leaves it
make_app_remote frappe
mv "$BENCH/apps/frappe" "$TMP_DIR/frappe-fake"
git clone -q --origin upstream --branch version-15 "file://$REMOTES/frappe.git" "$BENCH/apps/frappe"
printf 'frappe\n' >"$BENCH/sites/apps.txt"
make_app_remote acme_crm
make_app_remote acme_base
make_app_remote acme_new
add_policy acme_crm main
add_policy acme_base version-15
add_policy acme_new main
run_fm app add acme_crm --site macdev --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
run_fm app add acme_base --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
export MOCK_BENCH_VERSION=5.31.0
drift_kinds() { run_fm lock check --json --bench-dir "$BENCH"; printf '%s' "$OUT" | jget - '" ".join(x["kind"] + ":" + (x["app"] or x["site"] or "-") for x in d["drift"])'; }

# ---- no lockfile yet
run_fm lock check --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "No lockfile for"
run_fm doctor --json --bench-dir "$BENCH"
assert_eq "no benchbar.toml for this bench" "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"]=="lock_parse"][0]["message"]')"

# ---- write: refuses local changes, a dry run writes nothing, then the file
printf 'x\n' >>"$BENCH/apps/acme_crm/acme_crm/__init__.py"
run_fm lock write --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE"; assert_contains "$OUT" "apps/acme_crm has local changes"
assert_no_file "$LOCK"
git -C "$BENCH/apps/acme_crm" checkout -q -- .
run_fm lock write --dry-run --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "New file ${LOCK}"
assert_no_file "$LOCK"
run_fm lock write --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_file "$LOCK"
grep -q '^frappe_bench = "5.31.0"$' "$LOCK" || fail "the bench CLI version"
grep -q "^commit = \"$(app_head "$BENCH/apps/acme_crm")\"$" "$LOCK" || fail "acme_crm is pinned"
grep -q '^apps = \["acme_crm"\]$' "$LOCK" || fail "the site's apps, frappe left out"
grep -q '^default = true$' "$LOCK" || fail "the default site"
assert_eq "frappe acme_crm acme_base" "$(sed -n 's/^name = "\(.*\)"$/\1/p' "$LOCK" | head -n3 | tr '\n' ' ' | sed 's/ $//')" "(apps.txt order)"
run_fm lock write --yes --bench-dir "$BENCH"
assert_contains "$OUT" "unchanged"
run_fm lock check --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "in sync"
run_fm lock check --json --bench-dir "$BENCH"
assert_eq "True 0" "$(printf '%s' "$OUT" | jget - 'str(d["in_sync"]) + " " + str(len(d["drift"]))')"
# lock check is read only and offline
reset_calls; snap="$(snapshot "$BENCH" "$FL_STATE_DIR")"
run_fm lock check --bench-dir "$BENCH"
assert_eq "$snap" "$(snapshot "$BENCH" "$FL_STATE_DIR")" "(check writes nothing)"
assert_calls_not_contain '^git (fetch|ls-remote|clone|pull)|^bench --site'
cp "$LOCK" "$TMP_DIR/lock.good"

# ---- every drift kind
sed_inplace 's/^profile = "v15-lts"$/profile = "v16-lts"/' "$LOCK"
assert_contains "$(drift_kinds)" "profile_mismatch:-"
MOCK_BENCH_VERSION=5.30.0 run_fm lock check --json --bench-dir "$BENCH"
assert_contains "$OUT" '"kind":"bench_version_mismatch"'
cp "$TMP_DIR/lock.good" "$LOCK"
# the same repo over SSH and HTTPS is no drift; another repo is
git -C "$BENCH/apps/acme_crm" remote set-url upstream "https://example.com/acme/acme_crm"
sed_inplace "s#^repo = \"file://${REMOTES}/acme_crm.git\"#repo = \"git@example.com:acme/acme_crm.git\"#" "$LOCK"
assert_eq "" "$(drift_kinds)"
sed_inplace 's#^repo = "git@example.com:acme/acme_crm.git"#repo = "git@example.com:other/acme_crm.git"#' "$LOCK"
assert_eq "repo_mismatch:acme_crm" "$(drift_kinds)"
git -C "$BENCH/apps/acme_crm" remote set-url upstream "file://${REMOTES}/acme_crm.git"
cp "$TMP_DIR/lock.good" "$LOCK"
# behind: the pin is newer than the checkout
git -C "$BENCH/apps/acme_crm" commit -q --allow-empty -m "local one"
run_fm lock write --yes --allow-dirty --bench-dir "$BENCH"
git -C "$BENCH/apps/acme_crm" reset -q --hard HEAD~1
assert_eq "commit_behind:acme_crm" "$(drift_kinds)"
run_fm lock check --bench-dir "$BENCH"
assert_eq "1" "$CODE" "(drift exits 1)"
assert_contains "$OUT" "fix: benchbar lock apply"
# apply fast forwards it, a second apply is unchanged
reset_calls
run_fm lock apply --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain 'merge --ff-only --quiet [0-9a-f]{40}$'
assert_calls_contain '^bench setup requirements --python acme_crm$'
assert_calls_contain '^bench build --app acme_crm$'
assert_calls_not_contain '^bench (new-site|update|--site .* (install-app|migrate))'
assert_eq "" "$(drift_kinds)"
reset_calls
run_fm lock apply --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "unchanged: the apps match"
assert_calls_not_contain '^bench (setup|build)'
# ahead: local work outranks the lock
git -C "$BENCH/apps/acme_crm" commit -q --allow-empty -m "local two"
assert_eq "commit_ahead:acme_crm" "$(drift_kinds)"
run_fm lock apply --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "skipped: acme_crm: apps/acme_crm is ahead of the pinned"
# diverged
pinned="$(sed -n '/name = "acme_crm"/,/^$/s/^commit = "\(.*\)"$/\1/p' "$LOCK")"
git -C "$BENCH/apps/acme_crm" reset -q --hard HEAD~2
git -C "$BENCH/apps/acme_crm" commit -q --allow-empty -m "other work"
assert_eq "commit_diverged:acme_crm" "$(drift_kinds)"
git -C "$BENCH/apps/acme_crm" reset -q --hard "$pinned"
assert_eq "" "$(drift_kinds)"
# unknown: pinned to a remote commit the clone never fetched; apply fetches it
git -C "$BENCH/apps/acme_crm" reset -q --hard upstream/main
run_fm lock write --yes --bench-dir "$BENCH"
pinned="$(app_head "$BENCH/apps/acme_crm")"
push_commits acme_crm 2
newest="$(git -C "$REMOTES/acme_crm.git" rev-parse main)"
sed_inplace "s/^commit = \"${pinned}\"$/commit = \"${newest}\"/" "$LOCK"
assert_eq "commit_unknown:acme_crm" "$(drift_kinds)"
run_fm lock apply --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "$newest" "$(app_head "$BENCH/apps/acme_crm")"
# dirty: reported, and apply leaves the app alone
cp "$LOCK" "$TMP_DIR/lock.good"
printf 'y\n' >>"$BENCH/apps/acme_crm/acme_crm/__init__.py"
assert_eq "dirty:acme_crm" "$(drift_kinds)"
git -C "$BENCH/apps/acme_crm" reset -q --hard HEAD~1
printf 'y\n' >>"$BENCH/apps/acme_crm/acme_crm/__init__.py"
run_fm lock apply --yes --bench-dir "$BENCH"
assert_contains "$OUT" "skipped: acme_crm: local changes in apps/acme_crm"
assert_eq "local" "$(git -C "$BENCH/apps/acme_crm" status --porcelain -uno | awk '{print $1}' | sed 's/M/local/')"
git -C "$BENCH/apps/acme_crm" checkout -q -- .
run_fm lock apply --yes --bench-dir "$BENCH"
assert_eq "" "$(drift_kinds)"
# branch: acme_base follows version-15, the lock says main; apply switches the clean tree
sed_inplace '/name = "acme_base"/,/^$/s/^branch = "version-15"$/branch = "main"/' "$LOCK"
sed_inplace '/name = "acme_base"/,/^$/{/^commit = /d;}' "$LOCK"
assert_eq "branch_mismatch:acme_base" "$(drift_kinds)"
run_fm lock apply --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "main" "$(git -C "$BENCH/apps/acme_base" symbolic-ref --short HEAD)"
assert_eq "upstream/main" "$(git -C "$BENCH/apps/acme_base" rev-parse --abbrev-ref '@{upstream}')"
# missing: the lock has an app the bench does not; apply clones it, never installs it
printf '\n[[app]]\nname = "acme_new"\nrepo = "file://%s/acme_new.git"\nbranch = "main"\ncommit = "%s"\n' "$REMOTES" "$(git -C "$REMOTES/acme_new.git" rev-parse main)" >>"$LOCK"
assert_eq "app_missing:acme_new" "$(drift_kinds)"
run_fm lock check --json --bench-dir "$BENCH"
assert_eq "fail 1" "$(printf '%s' "$OUT" | jget - 'd["drift"][0]["level"] + " " + str(d["summary"]["fail"])')"
snap="$(snapshot "$BENCH")"
run_fm lock apply --dry-run --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "bench get-app --skip-assets --branch main file://${REMOTES}/acme_new.git"
assert_eq "$snap" "$(snapshot "$BENCH")" "(apply --dry-run changes nothing)"
reset_calls
run_fm lock apply --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain "^bench get-app --skip-assets --branch main file://${REMOTES}/acme_new.git$"
assert_calls_contain '^bench build --app acme_new$'
assert_calls_not_contain 'install-app|migrate|new-site'
assert_eq "" "$(drift_kinds)"
# extra: an app the lock does not have
make_app_remote acme_extra
add_policy acme_extra main
run_fm app add acme_extra --yes --bench-dir "$BENCH"
assert_eq "app_extra:acme_extra" "$(drift_kinds)"
run_fm lock apply --yes --bench-dir "$BENCH"
assert_contains "$OUT" "acme_extra is in the bench but not in the lock; it stays"
assert_file "$BENCH/apps/acme_extra"
run_fm lock write --yes --bench-dir "$BENCH"
assert_eq "" "$(drift_kinds)"
# sites: a site the bench lacks, an app a site lacks; apply prints the steps, never runs them
sed_inplace 's/^apps = \["acme_crm"\]$/apps = ["acme_crm", "acme_base"]/' "$LOCK"
printf '\n[[site]]\nname = "ghost"\napps = ["acme_crm"]\n' >>"$LOCK"
assert_eq "site_app_missing:acme_base site_missing:ghost" "$(drift_kinds)"
reset_calls
run_fm lock apply --yes --bench-dir "$BENCH"
assert_contains "$OUT" "benchbar app install acme_base --site macdev"
assert_contains "$OUT" 'benchbar site add ghost --apps "acme_crm"'
assert_calls_not_contain 'install-app|new-site'

# ---- the parser: only the strict subset, with the line
bad() { printf '%b' "$1" >"$LOCK"; run_fm lock check --bench-dir "$BENCH"; assert_eq "1" "$CODE"; assert_contains "$OUT" "$2"; }
bad 'schema = 1\n[bench]\nprofile = { a = "b" }\n' "benchbar.toml:3: not supported: inline tables"
bad 'schema = 1\n[bench]\nprofile = """\nx"""\n' "benchbar.toml:3: not supported: multi line strings"
bad 'schema = 1\n[bench]\nprofile = "v15\\\\-lts"\n' "benchbar.toml:3: not supported: escapes or quotes inside a string"
bad 'schema = 1\n[[app]]\nname = "x"\nrepo = "https://user:ghp_token@github.com/acme/x"\nbranch = "main"\n' "benchbar.toml:4: not supported: a user name or token in a repo URL"
bad 'schema = 1\n[[app]]\nname = "x"\nbranch = "main"\n' "[[app]] needs repo"
bad 'schema = 2\n' "schema 2"
bad 'schema = 1\n[bench.x]\n' "benchbar.toml:2: not supported: table header"
bad 'schema = 1\n[[app]]\nname = "x"\nrepo = "r"\nbranch = "b"\ncommit = "xyz"\n' "commit must be 7 to 40 lower case hex characters"
# doctor fails on it, without a repair action
run_fm doctor --json --bench-dir "$BENCH"
assert_eq "fail None" "$(printf '%s' "$OUT" | jget - '" ".join(str(c[k]) for c in d["checks"] if c["id"]=="lock_parse" for k in ("level","action"))')"

# ---- --lock: the file in the team's app, remembered; that app's commit is not pinned
rm -f "$LOCK"
run_fm lock write --lock apps/acme_crm/benchbar.toml --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
TEAM_LOCK="$BENCH/apps/acme_crm/benchbar.toml"
assert_file "$TEAM_LOCK"
! sed -n '/name = "acme_crm"/,/^$/p' "$TEAM_LOCK" | grep -q '^commit' || fail "the app holding the lockfile is not pinned"
run_fm lock check --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "$TEAM_LOCK"
run_fm list --json
assert_eq "$TEAM_LOCK" "$(printf '%s' "$OUT" | jget - 'd["benches"][0]["lock_file"]')"
# doctor reads it too, and reports drift without bench, git network or database calls
git -C "$BENCH/apps/acme_base" commit -q --allow-empty -m "ahead"
reset_calls
run_fm doctor --json --bench-dir "$BENCH"
assert_eq "warn None" "$(printf '%s' "$OUT" | jget - '" ".join(str(c[k]) for c in d["checks"] if c["id"]=="lock_drift" for k in ("level","action"))')"
assert_contains "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"]=="lock_drift"][0]["message"]')" "commit_ahead acme_base"
assert_calls_not_contain '^bench (--version|--site|list-apps)'
assert_calls_not_contain '^git (fetch|ls-remote|clone|pull)'
# BENCHBAR_LOCK points elsewhere for one run
cp "$TMP_DIR/lock.good" "$TMP_DIR/other.toml"
BENCHBAR_LOCK="$TMP_DIR/other.toml" run_fm lock check --json --bench-dir "$BENCH"
assert_eq "$TMP_DIR/other.toml" "$(printf '%s' "$OUT" | jget - 'd["lock_file"]')"

printf 'test-lock: ok\n'
