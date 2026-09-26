#!/usr/bin/env bash
# Team profiles: lookup (built in first, then ~/.config/benchbar/profiles,
# then BENCHBAR_PROFILE_PATH), list and show, parse errors, shadowing,
# create from a bench, and install --profile with the team's apps.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=tests/lib/apps-fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apps-fixtures.sh"

USER_DIR="$HOME/.config/benchbar/profiles"
TEAM_REPO="$TMP_DIR/team-config"
mkdir -p "$USER_DIR" "$TEAM_REPO"
make_app_remote acme_crm
make_app_remote acme_tools
PIN="$(git -C "$REMOTES/acme_tools.git" rev-parse main)"

# ---- only the built in profiles
run_fm profile list --json
assert_eq "0" "$CODE" "$OUT"
assert_eq "v15-lts:builtin v16-lts:builtin" "$(printf '%s' "$OUT" | jget - '" ".join(p["name"] + ":" + p["kind"] for p in d["profiles"])')"

# ---- a team profile in the user folder, another in a team config clone
cat >"$USER_DIR/acme.toml" <<TOML
# acme's bench
schema = 1
base = "v15-lts"
description = "Acme ERP"
site = "acme.localhost"
scheduler = true

[[apps]]
name = "acme_crm"
repo = "file://${REMOTES}/acme_crm.git"
branch = "main"

[[apps]]
name = "acme_tools"
repo = "file://${REMOTES}/acme_tools.git"
branch = "version-15"
commit = "${PIN}"
TOML
printf 'base = "v16-lts"\nbundle = "minimal"\n' >"$TEAM_REPO/acme16.toml"
# the same name later on the path is hidden, a built in name is refused
printf 'base = "v15-lts"\nbundle = "minimal"\n' >"$TEAM_REPO/acme.toml"
printf 'base = "v15-lts"\nbundle = "minimal"\n' >"$USER_DIR/v15-lts.toml"
# and a file the strict parser rejects
printf 'base = "v15-lts"\ndescription = { name = "x" }\n' >"$TEAM_REPO/broken.toml"
export BENCHBAR_PROFILE_PATH="$TEAM_REPO"
run_fm profile list --json
assert_eq "0" "$CODE" "$OUT"
j() { printf '%s' "$OUT" | jget - "$1"; }
assert_eq "user True v15-lts Acme ERP" "$(j '" ".join(str(x) for x in [[p for p in d["profiles"] if p["name"]=="acme"][0][k] for k in ("source","valid","base","label")])')"
assert_eq "path True v16-lts" "$(j '" ".join(str(x) for x in [[p for p in d["profiles"] if p["name"]=="acme16"][0][k] for k in ("source","valid","base")])')"
assert_contains "$(j '[p for p in d["profiles"] if p["name"]=="v15-lts" and p["kind"]=="team"][0]["error"]')" "shadows the built in profile v15-lts"
assert_contains "$(j '[p for p in d["profiles"] if p["name"]=="acme" and p["source"]=="path"][0]["error"]')" "hidden by an earlier acme.toml"
assert_contains "$(j '[p for p in d["profiles"] if p["name"]=="broken"][0]["error"]')" "broken.toml:2: not supported: inline tables"
run_fm profile list
assert_contains "$OUT" "acme"
assert_contains "$OUT" "invalid: shadows the built in profile v15-lts"

# ---- show
run_fm profile show acme
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "python@3.11"
assert_contains "$OUT" "acme_tools  version-15  ${PIN}"
run_fm profile show acme16
assert_contains "$OUT" "python@3.14"
assert_contains "$OUT" "minimal: erpnext"
run_fm profile show broken
assert_eq "1" "$CODE"; assert_contains "$OUT" "inline tables"
run_fm profile show nosuch
assert_eq "1" "$CODE"; assert_contains "$OUT" "No profile 'nosuch'"
# a built in name always means the built in profile
run_fm profile show v15-lts
assert_contains "$OUT" "v15-lts (built in)"
# the parser's other refusals
printf 'base = "v15-lts"\n[[apps]]\nname = "x"\nrepo = "https://user:token@github.com/acme/x"\nbranch = "main"\n' >"$TEAM_REPO/tok.toml"
run_fm profile show tok
assert_eq "1" "$CODE"; assert_contains "$OUT" "a user name or token in a repo URL"
printf 'base = "v15-lts"\ndescription = """\nmulti"""\n' >"$TEAM_REPO/ml.toml"
run_fm profile show ml
assert_eq "1" "$CODE"; assert_contains "$OUT" "multi line strings"
printf 'base = "v15-lts"\ndescription = "a \\"quoted\\" word"\n' >"$TEAM_REPO/esc.toml"
run_fm profile show esc
assert_eq "1" "$CODE"; assert_contains "$OUT" "escapes or quotes inside a string"
printf 'base = "v14"\n' >"$TEAM_REPO/old.toml"
run_fm profile show old
assert_eq "1" "$CODE"; assert_contains "$OUT" 'base "v14" is not a built in profile'
rm -f "$TEAM_REPO"/{tok,ml,esc,old,broken}.toml

# ---- install --profile acme: the base's toolchain, the team's apps, site and scheduler
add_proc 900 "mariadbd --datadir=/x"
add_proc 901 "redis-server *:6379"
printf 'mariadb@10.11 started akash file\nredis started akash file\n' >"$MOCK_BREW_SERVICES"
touch "$MOCK_STATE/wkhtml_installed"
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
BENCH="$HOME/acme-bench"
reset_calls
MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw run_fm install --yes --profile acme --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "acme (team, on v15-lts)"
assert_contains "$OUT" "Team profile: acme"
assert_calls_contain "^bench init ${BENCH} --frappe-branch version-15 --python "
assert_calls_contain "^git ls-remote --exit-code --heads --tags file://${REMOTES}/acme_crm.git main$"
assert_calls_contain "^bench get-app --branch main file://${REMOTES}/acme_crm.git$"
assert_calls_contain "^bench get-app --branch version-15 file://${REMOTES}/acme_tools.git$"
assert_calls_contain "checkout ${PIN}$"
assert_calls_not_contain 'get-app .*erpnext'
assert_calls_contain '^bench new-site acme.localhost '
assert_calls_contain '^bench --site acme.localhost install-app acme_tools$'
state="$(ls "$FL_STATE_DIR"/benches/acme-bench-*.env)"
assert_eq "v15-lts" "$(sed -n 's/^PROFILE=//p' "$state")"
assert_eq "acme" "$(sed -n 's/^TEAM_PROFILE=//p' "$state")"
assert_eq "on" "$(sed -n 's/^SCHEDULER=//p' "$state")"
grep -q '^schedule: bench schedule$' "$BENCH/Procfile.lean" || fail "the team profile turns the scheduler on"
# daily commands follow the team profile: its branches are the policy
run_fm app list --json --no-sites --bench-dir "$BENCH"
assert_eq "version-15" "$(printf '%s' "$OUT" | jget - '[a for a in d["apps"] if a["name"]=="acme_tools"][0]["policy_branch"]')"
# the rerun changes nothing
reset_calls
run_fm install --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain '^bench (init|new-site|get-app)'
assert_contains "$OUT" "acme (team, on v15-lts)"

# ---- create: from a bench, read only, written where asked, never a secret
git -C "$BENCH/apps/acme_crm" remote set-url upstream "https://someone:ghp_secret@example.com/acme/acme_crm.git"
snap="$(snapshot "$BENCH")"
reset_calls
run_fm profile create acme-copy --from-bench "$BENCH" --dir "$TEAM_REPO" --dry-run
assert_eq "0" "$CODE" "$OUT"
assert_no_file "$TEAM_REPO/acme-copy.toml"
run_fm profile create acme-copy --from-bench "$BENCH" --dir "$TEAM_REPO" --yes
assert_eq "0" "$CODE" "$OUT"
assert_eq "$snap" "$(snapshot "$BENCH")" "(create reads the bench only)"
assert_calls_not_contain '^bench '
f="$TEAM_REPO/acme-copy.toml"
assert_file "$f"
! grep -q 'ghp_secret\|someone' "$f" || fail "no credentials in a team profile"
grep -q '^base = "v15-lts"$' "$f" || fail "the base comes from the bench"
grep -q '^repo = "https://example.com/acme/acme_crm.git"$' "$f" || fail "the repo without its user info"
grep -q '^site = "acme.localhost"$' "$f" || fail "the default site name"
grep -q '^scheduler = true$' "$f" || fail "the scheduler choice"
! grep -q '^commit' "$f" || fail "a profile is a recipe; commits belong in the lockfile"
run_fm profile show acme-copy
assert_eq "0" "$CODE" "$OUT"
run_fm profile create acme-copy --from-bench "$BENCH" --dir "$TEAM_REPO" --yes
assert_contains "$OUT" "unchanged"
run_fm profile create v16-lts --from-bench "$BENCH" --yes
assert_eq "1" "$CODE"; assert_contains "$OUT" "may not shadow it"

printf 'test-profiles: ok\n'
