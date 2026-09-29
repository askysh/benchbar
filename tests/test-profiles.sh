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
assert_eq "user None True v15-lts Acme ERP 1" "$(j '" ".join(str(x) for x in [[p for p in d["profiles"] if p["name"]=="acme"][0][k] for k in ("source","source_url","valid","base","label","schema")])')"
assert_eq "path True v16-lts None None" "$(j '" ".join(str(x) for x in [[p for p in d["profiles"] if p["name"]=="acme16"][0][k] for k in ("source","valid","base","subscription","shadowed_by")])')"
assert_contains "$(j '[p for p in d["profiles"] if p["name"]=="v15-lts" and p["kind"]=="team"][0]["error"]')" "shadows the built in profile v15-lts"
assert_contains "$(j '[p for p in d["profiles"] if p["name"]=="acme" and p["source"]=="path"][0]["error"]')" "hidden by an earlier acme.toml"
assert_eq "$USER_DIR/acme.toml" "$(j '[p for p in d["profiles"] if p["name"]=="acme" and p["source"]=="path"][0]["shadowed_by"]')"
assert_eq "builtin None None" "$(j '" ".join(str(p[k]) for p in d["profiles"] if p["name"]=="v16-lts" and p["kind"]=="builtin" for k in ("source","source_url","schema"))')"
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
# a repo git would read as an option (it runs a command) is refused before git sees it
printf 'base = "v15-lts"\n\n[[apps]]\nname = "evil"\nrepo = "--upload-pack=touch %s/PWNED;git-upload-pack"\nbranch = "."\n' "$TMP_DIR" >"$USER_DIR/evil.toml"
run_fm profile show evil
assert_eq "1" "$CODE"
assert_contains "$OUT" '"repo" must not start with "-"'
run_fm install --profile evil --dry-run --bench-dir "$HOME/evil-bench"
assert_no_file "$TMP_DIR/PWNED" "(no command from a profile file ever runs)"
rm "$USER_DIR/evil.toml"
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
assert_calls_contain "^git ls-remote --exit-code --heads --tags -- file://${REMOTES}/acme_crm.git main$"
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
assert_eq "0" "$CODE" "app list: $OUT"
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

# ================================================================ sharing
# Network remotes are local bare repos: the git mock maps their URLs
# (tests/mocks/bin/git), ssh -G resolves aliases from ssh_hosts, and curl
# serves $MOCK_STATE/http. Nothing leaves the machine.
unset BENCHBAR_PROFILE_PATH
rm -f "$USER_DIR/v15-lts.toml"
# stdout only in OUT (the JSON), stderr in ERR
run_js() { set +e; OUT="$("$FM" "$@" 2>"$TMP_DIR/stderr")"; CODE="$?"; ERR="$(cat "$TMP_DIR/stderr")"; set -e; }
http_put() { mkdir -p "$MOCK_STATE/http"; cp "$2" "$MOCK_STATE/http/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"; }
head_to() { git --git-dir="$REMOTES/$1.git" symbolic-ref HEAD "refs/heads/$2"; }
make_app_remote acme_base
make_app_remote acme_ecr acme_base
make_app_remote tool
make_app_remote erpnext
( cd "$WORK/erpnext" && git branch develop && git push -q origin develop )
head_to acme_base main; head_to acme_ecr main; head_to tool main; head_to erpnext develop
{
  printf 'https://github.com/acme/acme_base.git\t%s\tpublic\n' "$REMOTES/acme_base.git"
  printf 'git@github.com:acme/acme_ecr.git\t%s\tprivate\n' "$REMOTES/acme_ecr.git"
  printf 'https://github.com/acme/acme_ecr.git\t%s\tprivate\n' "$REMOTES/acme_ecr.git"
  printf 'git@github.com:someone/tool.git\t%s\tprivate\n' "$REMOTES/tool.git"
  printf 'https://github.com/someone/tool.git\t%s\tprivate\n' "$REMOTES/tool.git"
  printf 'https://github.com/frappe/erpnext\t%s\tpublic\n' "$REMOTES/erpnext.git"
  printf 'https://github.com/acme/ghost.git\t%s\tgone\n' "$REMOTES/nothing.git"
  printf 'https://github.com/acme/far.git\t%s\toffline\n' "$REMOTES/nothing.git"
} >"$MOCK_STATE/git_remotes"
printf 'github-acme\tgithub.com\t22\n' >"$MOCK_STATE/ssh_hosts"
printf '{\n  "login": "someone",\n  "type": "User"\n}\n' >"$TMP_DIR/user.json"
printf '{\n  "login": "acme",\n  "type": "Organization"\n}\n' >"$TMP_DIR/org.json"
http_put https://api.github.com/users/someone "$TMP_DIR/user.json"
http_put https://api.github.com/users/acme "$TMP_DIR/org.json"

cat >"$USER_DIR/share.toml" <<'TOML'
base = "v15-lts"
description = "Acme ECR"

[[apps]]
name = "erpnext"
repo = "https://github.com/frappe/erpnext"
branch = "version-15"

[[apps]]
name = "acme_base"
repo = "https://github.com/acme/acme_base.git"
branch = "feature-x"

[[apps]]
name = "acme_ecr"
repo = "git@github-acme:acme/acme_ecr.git"
branch = "wip"

[[apps]]
name = "tool"
repo = "git@github.com:someone/tool.git"
branch = "main"
TOML
# requires come from the bench's hooks.py (read only)
SHARE_BENCH="$HOME/share-bench"
make_fake_bench "$SHARE_BENCH"
cp -R "$WORK/acme_ecr" "$SHARE_BENCH/apps/acme_ecr"

# ---- export --plan: read only, the contract's fields
reset_calls
snap="$(snapshot "$USER_DIR" "$SHARE_BENCH")"
run_js profile export share --plan --json --bench-dir "$SHARE_BENCH"
assert_eq "0" "$CODE" "$OUT $ERR"
assert_eq "$snap" "$(snapshot "$USER_DIR" "$SHARE_BENCH")" "(export --plan writes nothing)"
ex() { printf '%s' "$OUT" | jget - "$1"; }
assert_eq "share v15-lts 4" "$(ex '" ".join(str(x) for x in (d["name"], d["base"], len(d["apps"])))')"
assert_eq "feature-x main main True public [] True" "$(ex '" ".join(str(a[k]) for a in d["apps"] if a["name"]=="acme_base" for k in ("current_branch","exported_branch","default_branch","branch_verified","access","requires","keep"))')"
assert_eq "git@github.com:acme/acme_ecr.git private ['acme_base']" "$(ex '" ".join(str(a[k]) for a in d["apps"] if a["name"]=="acme_ecr" for k in ("exported_repo","access","requires"))')"
assert_eq "personal" "$(ex '[a for a in d["apps"] if a["name"]=="tool"][0]["access"]')"
assert_eq "version-15 develop True" "$(ex '" ".join(str(a[k]) for a in d["apps"] if a["name"]=="erpnext" for k in ("exported_branch","default_branch","branch_verified"))')"
assert_contains "$(ex '"|".join(d["warnings"])')" "keeps version-15"
assert_contains "$(ex '"|".join(d["warnings"])')" "personal GitHub account"
assert_calls_contain '^ssh -G github-acme'
# overrides, and a drop that a kept app requires is refused
run_js profile export share --plan --json --branch acme_base=version-15 --drop tool --bench-dir "$SHARE_BENCH"
assert_eq "version-15 True False" "$(ex '" ".join(str(x) for x in ([a["exported_branch"] for a in d["apps"] if a["name"]=="acme_base"][0], [a["branch_verified"] for a in d["apps"] if a["name"]=="acme_base"][0], [a["keep"] for a in d["apps"] if a["name"]=="tool"][0]))')"
run_js profile export share --drop acme_base --out "$TMP_DIR/x.toml" --yes --json --bench-dir "$SHARE_BENCH"
assert_eq "1" "$CODE"
assert_eq "acme_base ['acme_ecr']" "$(ex '" ".join(str(b[k]) for b in d["blocked"] for k in ("app","required_by"))')"
assert_contains "$(ex 'd["error"]')" "required by"
assert_no_file "$TMP_DIR/x.toml"
run_fm profile export share --branch nope=main --plan
assert_eq "1" "$CODE"; assert_contains "$OUT" "share has no app nope"

# ---- the default branch is read through the URL as it is on this Mac: an
# SSH alias carries the key of another account, the real host may refuse it
make_app_remote alias_app
make_app_remote compliance
( cd "$WORK/alias_app" && git branch develop && git push -q origin develop )
( cd "$WORK/compliance" && git branch develop && git push -q origin develop )
head_to alias_app develop; head_to compliance develop
{
  printf 'git@github-acme:acme/alias_app.git\t%s\tprivate\n' "$REMOTES/alias_app.git"
  printf 'git@github.com:acme/alias_app.git\t%s\tgone\n' "$REMOTES/alias_app.git"
  printf 'https://github.com/acme/alias_app.git\t%s\tprivate\n' "$REMOTES/alias_app.git"
  printf 'https://github.com/acme/compliance.git\t%s\tpublic\n' "$REMOTES/compliance.git"
} >>"$MOCK_STATE/git_remotes"
cat >"$USER_DIR/share2.toml" <<'TOML'
base = "v15-lts"

[[apps]]
name = "alias_app"
repo = "git@github-acme:acme/alias_app.git"
branch = "wip"

[[apps]]
name = "compliance"
repo = "https://github.com/acme/compliance.git"
branch = "version-15"
TOML
run_js profile export share2 --plan --json
assert_eq "0" "$CODE" "$OUT $ERR"
assert_eq "git@github.com:acme/alias_app.git develop develop True" "$(ex '" ".join(str(a[k]) for a in d["apps"] if a["name"]=="alias_app" for k in ("exported_repo","exported_branch","default_branch","branch_verified"))')"
# an app outside the registry on the base's release branch keeps it too
assert_eq "version-15 develop True" "$(ex '" ".join(str(a[k]) for a in d["apps"] if a["name"]=="compliance" for k in ("exported_branch","default_branch","branch_verified"))')"
rm "$USER_DIR/share2.toml"

# ---- export writes a schema 2 file that reads back
EXPORTED="$TMP_DIR/out/share.toml"
run_js profile export share --drop tool --out "$EXPORTED" --yes --json --bench-dir "$SHARE_BENCH"
assert_eq "0" "$CODE" "$OUT $ERR"
assert_eq "$EXPORTED 3 ['tool']" "$(ex '" ".join(str(d[k]) for k in ("path","apps","dropped"))')"
grep -q '^schema = 2$' "$EXPORTED" || fail "an export is schema 2"
grep -q "^exported_from = \"benchbar ${VER}, " "$EXPORTED" || fail "exported_from names the version"
grep -q '^repo = "git@github.com:acme/acme_ecr.git"$' "$EXPORTED" || fail "the SSH alias is resolved"
grep -q '^requires = \["acme_base"\]$' "$EXPORTED" || fail "requires from hooks.py"
! grep -q 'github-acme\|someone/tool' "$EXPORTED" || fail "no alias, no dropped app"
# a schema 1 file may not use the schema 2 keys
printf 'base = "v15-lts"\n[[apps]]\nname = "x"\nrepo = "https://example.com/x"\nbranch = "main"\naccess = "public"\n' >"$USER_DIR/old1.toml"
run_fm profile show old1
assert_eq "1" "$CODE"; assert_contains "$OUT" "access needs schema = 2"
printf 'schema = 3\nbase = "v15-lts"\nbundle = "minimal"\n' >"$USER_DIR/old1.toml"
run_fm profile show old1
assert_eq "1" "$CODE"; assert_contains "$OUT" "reads schema 1 and 2"
printf 'schema = 2\nbase = "v15-lts"\n[[apps]]\nname = "x"\nrepo = "https://example.com/x"\nbranch = "main"\naccess = "secret"\n' >"$USER_DIR/old1.toml"
run_fm profile show old1
assert_eq "1" "$CODE"; assert_contains "$OUT" 'access "secret"'
rm "$USER_DIR/old1.toml"

# ---- import a file: plan (with check), then write with its source
snap="$(snapshot "$USER_DIR")"
run_js profile import "$EXPORTED" --as shared --plan --json
assert_eq "0" "$CODE" "$OUT $ERR"
assert_eq "$snap" "$(snapshot "$USER_DIR")" "(import --plan writes nothing)"
assert_eq "shared $EXPORTED False None v15-lts 3" "$(ex '" ".join(str(x) for x in (d["name"], d["source"], d["exists"], d["diff"], d["base"], len(d["apps"])))')"
assert_eq "acme_ecr private ['acme_base']" "$(ex '" ".join(str(a[k]) for a in d["apps"] if a["name"]=="acme_ecr" for k in ("name","access","requires"))')"
assert_eq "True True True []" "$(ex '" ".join(str(x) for x in [r["reachable"] for r in d["check"]["repos"]] + [d["skipped_apps"]])')"
run_js profile import "$EXPORTED" --as shared --yes --json
assert_eq "0" "$CODE" "$OUT $ERR"
assert_eq "shared $USER_DIR/shared.toml $EXPORTED" "$(ex '" ".join(d[k] for k in ("name","path","source"))')"
grep -q "^source = \"${EXPORTED}\"$" "$USER_DIR/shared.toml" || fail "the import records its source"
[[ "$(grep -c '^schema = ' "$USER_DIR/shared.toml")" == "1" ]] || fail "one schema line"
run_fm profile import "$EXPORTED" --as shared --yes
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "unchanged"
run_js profile list --json
assert_eq "imported $EXPORTED 2" "$(ex '" ".join(str(p[k]) for p in d["profiles"] if p["name"]=="shared" for k in ("source","source_url","schema"))')"
# a changed source: the plan shows the diff, and a non interactive run without --yes writes nothing
sed_inplace 's/^description = "Acme ECR"$/description = "Acme ECR 2"/' "$EXPORTED"
run_js profile import "$EXPORTED" --as shared --plan --json
assert_eq "True" "$(ex 'd["exists"]')"
assert_contains "$(ex 'd["diff"]')" '+description = "Acme ECR 2"'
run_fm profile import "$EXPORTED" --as shared
assert_eq "1" "$CODE"
grep -q '^description = "Acme ECR"$' "$USER_DIR/shared.toml" || fail "not confirmed, not written"
# update of an import fetches the source again
run_js profile update shared --plan --json
assert_eq "0" "$CODE" "$OUT $ERR"
assert_eq "shared imported None" "$(ex '" ".join(str(u[k]) for u in d["updates"] for k in ("name","kind","behind"))')"
assert_contains "$(ex 'd["updates"][0]["diff"]')" "Acme ECR 2"
run_js profile update shared --yes --json
assert_eq "True" "$(ex 'd["applied"]')"
grep -q '^description = "Acme ECR 2"$' "$USER_DIR/shared.toml" || fail "update wrote the new file"
ls "$FL_BACKUP_ROOT"/*/*shared.toml >/dev/null 2>&1 || fail "update backed up the old file"

# ---- import refusals
run_fm profile import "http://example.com/a.toml"
assert_eq "1" "$CODE"; assert_contains "$OUT" "only https URLs"
run_fm profile import "$EXPORTED" --as v15-lts
assert_eq "1" "$CODE"; assert_contains "$OUT" "may not shadow it"
head -c 70000 /dev/zero | tr '\0' '#' >"$TMP_DIR/big.toml"
run_fm profile import "$TMP_DIR/big.toml"
assert_eq "1" "$CODE"; assert_contains "$OUT" "larger than 64 KB"
printf 'base = "v15-lts"\nplugin = "x"\n' >"$TMP_DIR/bad.toml"
run_fm profile import "$TMP_DIR/bad.toml" --yes
assert_eq "1" "$CODE"; assert_contains "$OUT" "not a valid team profile"
assert_no_file "$USER_DIR/bad.toml"
# GitHub pages are fetched raw; the name comes from the file
printf 'base = "v16-lts"\nbundle = "minimal"\n' >"$TMP_DIR/team.toml"
http_put https://raw.githubusercontent.com/acme/config/main/profiles/team.toml "$TMP_DIR/team.toml"
reset_calls
run_js profile import https://github.com/acme/config/blob/main/profiles/team.toml --plan --json
assert_eq "0" "$CODE" "$OUT $ERR"
assert_eq "team v16-lts" "$(ex '" ".join(d[k] for k in ("name","base"))')"
assert_calls_contain 'curl .*--proto =https .*https://raw.githubusercontent.com/acme/config/main/profiles/team.toml$'
http_put https://gist.githubusercontent.com/someone/abc123/raw "$TMP_DIR/team.toml"
run_fm profile import https://gist.github.com/someone/abc123
assert_eq "1" "$CODE"; assert_contains "$OUT" "--as NAME"
run_js profile import https://gist.github.com/someone/abc123 --as gisty --yes --json
assert_eq "0" "$CODE" "$OUT $ERR"
assert_eq "https://gist.github.com/someone/abc123" "$(ex 'd["source"]')"

# ---- check: unreachable, offline, and the apps that need them
cat >"$USER_DIR/spotty.toml" <<TOML
schema = 2
base = "v15-lts"

[[apps]]
name = "acme_crm"
repo = "file://${REMOTES}/acme_crm.git"
branch = "main"

[[apps]]
name = "ghost"
repo = "https://github.com/acme/ghost.git"
branch = "main"

[[apps]]
name = "ghost_ui"
repo = "file://${REMOTES}/acme_tools.git"
branch = "main"
requires = ["ghost"]

[[apps]]
name = "far"
repo = "https://github.com/acme/far.git"
branch = "main"
TOML
run_js profile check spotty --json
assert_eq "0" "$CODE" "$OUT $ERR"
assert_eq "True False True None" "$(ex '" ".join(str(r["reachable"]) for r in d["repos"])')"
assert_contains "$(ex 'd["repos"][1]["reason"]')" "not found"
assert_contains "$(ex 'd["repos"][3]["reason"]')" "Could not resolve host"
assert_eq "['ghost', 'ghost_ui']" "$(ex 'd["skipped_apps"]')"
run_fm profile check spotty
assert_contains "$OUT" "install --profile leaves out ghost_ui (needs ghost)"
BENCHBAR_OFFLINE=1 run_js profile check spotty --json
assert_eq "None None None None" "$(ex '" ".join(str(r["reachable"]) for r in d["repos"])')"
# install --profile leaves them out and says so
# (without the offline one: install stops on a repo it cannot tell about)
awk '/^\[\[apps\]\]$/ {n++} n < 4' "$USER_DIR/spotty.toml" >"$TMP_DIR/sp" && mv "$TMP_DIR/sp" "$USER_DIR/spotty.toml"
run_fm profile show spotty
assert_eq "0" "$CODE" "$OUT"
BENCH2="$HOME/spotty-bench"
reset_calls
MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw run_fm install --yes --profile spotty --bench-dir "$BENCH2"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "Skipped apps: ghost (unreachable: "
assert_contains "$OUT" "ghost_ui (needs ghost)"
assert_calls_contain "^bench get-app --branch main file://${REMOTES}/acme_crm.git$"
assert_calls_not_contain 'get-app .*(ghost|acme_tools)'

# ---- subscribe: a team config repo, only its *.toml read
mkdir -p "$WORK/team-config/profiles"
(
  cd "$WORK/team-config" || exit 1
  git init -q -b main .
  printf 'base = "v15-lts"\ndescription = "Team A"\n\n[[apps]]\nname = "acme_crm"\nrepo = "file://%s/acme_crm.git"\nbranch = "main"\n' "$REMOTES" >profiles/team-a.toml
  printf 'base = "v15-lts"\nplugin = 1\n' >profiles/broken.toml
  printf '#!/bin/sh\ntouch %s/HOOK_RAN\n' "$TMP_DIR" >profiles/post-checkout
  git add -A && git commit -q -m "team profiles"
  git init -q --bare "$REMOTES/team-config.git"
  git remote add origin "file://$REMOTES/team-config.git"
  git push -q origin main
)
head_to team-config main
SUB_URL="file://$REMOTES/team-config.git"
SUB_DIR="$HOME/.config/benchbar/sources/remotes-team-config"
run_js profile subscribe "$SUB_URL" --plan --json
assert_eq "0" "$CODE" "$OUT $ERR"
assert_eq "$SUB_URL $SUB_DIR ['team-a']" "$(ex '" ".join(str(d[k]) for k in ("repo","dir","profiles"))')"
assert_no_file "$SUB_DIR"
assert_contains "$ERR" "broken.toml is invalid"
run_fm profile subscribe "$SUB_URL"
assert_eq "1" "$CODE"; assert_no_file "$SUB_DIR" "(not confirmed)"
run_js profile subscribe "$SUB_URL" --yes --json
assert_eq "0" "$CODE" "$OUT $ERR"
assert_eq "['team-a']" "$(ex 'd["profiles"]')"
assert_file "$SUB_DIR/profiles/team-a.toml"
assert_no_file "$TMP_DIR/HOOK_RAN"
assert_eq "remotes-team-config	$SUB_URL" "$(cat "$HOME/.config/benchbar/sources.list")"
run_fm profile subscribe "$SUB_URL" --yes
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "already subscribed"
run_js profile list --json
assert_eq "subscribed $SUB_URL $SUB_URL $SUB_DIR 0 0 True" "$(ex '" ".join(str(x) for p in d["profiles"] if p["name"]=="team-a" for x in (p["source"], p["source_url"], p["subscription"]["repo"], p["subscription"]["dir"], p["subscription"]["behind"], p["subscription"]["days"], p["subscription"]["fetched_at"].endswith("Z")))')"
run_fm profile show team-a
assert_contains "$OUT" "Team A"
# a user file of the same name comes first; list names the file it hides
printf 'base = "v15-lts"\nbundle = "minimal"\n' >"$USER_DIR/team-a.toml"
run_js profile list --json
assert_eq "$USER_DIR/team-a.toml" "$(ex '[p for p in d["profiles"] if p["name"]=="team-a" and p["source"]=="subscribed"][0]["shadowed_by"]')"
run_fm profile list
assert_contains "$OUT" "[WARN] shadowed: team-a: $SUB_DIR/profiles/team-a.toml is hidden by $USER_DIR/team-a.toml"
rm "$USER_DIR/team-a.toml"

# ---- a new commit upstream: list and doctor see it, update asks
( cd "$WORK/team-config" && sed_inplace 's/Team A/Team A v2/' profiles/team-a.toml && git commit -q -am "v2" && git push -q origin main )
run_js profile update team-a --plan --json
assert_eq "0" "$CODE" "$OUT $ERR"
assert_eq "team-a subscribed 1" "$(ex '" ".join(str(u[k]) for u in d["updates"] for k in ("name","kind","behind"))')"
assert_contains "$(ex 'd["updates"][0]["diff"]')" '+description = "Team A v2"'
run_js profile list --json
assert_eq "1" "$(ex '[p for p in d["profiles"] if p["name"]=="team-a"][0]["subscription"]["behind"]')"
# doctor: the bench follows team-a; doctor never fetches without --fetch
state="$(ls "$FL_STATE_DIR"/benches/acme-bench-*.env)"
sed_inplace 's/^TEAM_PROFILE=.*/TEAM_PROFILE=team-a/' "$state"
reset_calls
run_js doctor --json --bench-dir "$BENCH"
assert_eq "warn benchbar profile update team-a" "$(ex '" ".join(str(c[k]) for c in d["checks"] if c["id"]=="profile_outdated" for k in ("level","fix_command"))')"
assert_contains "$(ex '[c["message"] for c in d["checks"] if c["id"]=="profile_outdated"][0]')" "1 commit(s)"
assert_calls_not_contain 'fetch'
printf '0\n' >"$SUB_DIR/.git/benchbar-fetched"
reset_calls
run_js doctor --json --bench-dir "$BENCH"
assert_calls_not_contain 'fetch'
assert_contains "$(ex '[c["message"] for c in d["checks"] if c["id"]=="profile_outdated"][0]')" "run benchbar doctor --fetch"
reset_calls
run_js doctor --fetch --json --bench-dir "$BENCH"
assert_calls_contain "fetch --quiet --no-tags" "(doctor --fetch fetches the subscription)"
BENCHBAR_OFFLINE=1 run_js doctor --json --bench-dir "$BENCH"
assert_eq "warn" "$(ex '[c["level"] for c in d["checks"] if c["id"]=="profile_outdated"][0]')"
run_js profile update team-a --yes --json
assert_eq "0" "$CODE" "$OUT $ERR"
assert_eq "True" "$(ex 'd["applied"]')"
grep -q 'Team A v2' "$SUB_DIR/profiles/team-a.toml" || fail "update fast forwarded the clone"
run_js doctor --json --bench-dir "$BENCH"
assert_eq "ok" "$(ex '[c["level"] for c in d["checks"] if c["id"]=="profile_outdated"][0]')"
sed_inplace 's/^TEAM_PROFILE=.*/TEAM_PROFILE=acme/' "$state"
run_js profile update --all --plan --json
assert_eq "gisty:imported shared:imported remotes-team-config:subscribed" "$(ex '" ".join(u["name"] + ":" + u["kind"] for u in d["updates"])')"
run_fm profile update acme
assert_eq "1" "$CODE"; assert_contains "$OUT" "was not imported or subscribed"

# ---- remove: moved aside, never deleted
run_fm profile remove acme --yes
assert_eq "1" "$CODE"; assert_contains "$OUT" "your own file"
run_js profile remove team-a --yes --json
assert_eq "0" "$CODE" "$OUT $ERR"
moved="$(ex 'd["moved_to"]')"
assert_eq "team-a" "$(ex 'd["name"]')"
assert_file "$moved/profiles/team-a.toml"
assert_no_file "$SUB_DIR"
[[ -z "$(cat "$HOME/.config/benchbar/sources.list")" ]] || fail "the subscription left sources.list"
run_js profile remove shared --yes --json
assert_file "$(ex 'd["moved_to"]')"
assert_no_file "$USER_DIR/shared.toml"
run_fm profile show team-a
assert_eq "1" "$CODE"

printf 'test-profiles: ok\n'
