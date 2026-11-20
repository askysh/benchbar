#!/usr/bin/env bash
# Profiles, locks and app input that someone else wrote (#153): the TOML subset
# (BOM, CRLF, empty and "|" values, repo schemes), the credentials a written URL
# loses, the notice of whose code an install runs, the temp files of a dry run,
# the TSV readers, and a failed step that still changed something.
# shellcheck source=tests/lib/profiles-fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/profiles-fixtures.sh"

unset BENCHBAR_PROFILE_PATH
mock_services_up
ok_repo='repo = "https://example.com/acme/acme_crm.git"'

# profile_text BODY: a team profile with one app
profile_toml() { printf 'base = "v15-lts"\n\n[[apps]]\nname = "acme_crm"\n%s\nbranch = "%s"\n' "$1" "${2-main}"; }

# ---- the parser: a BOM and CRLF are fine, an empty or "|" value is not (APP-16)
printf '\357\273\277' >"$USER_DIR/bom.toml"; profile_toml "$ok_repo" >>"$USER_DIR/bom.toml"
run_fm profile show bom
assert_eq "0" "$CODE" "(a UTF-8 byte order mark is skipped) $OUT"
assert_contains "$OUT" "acme_crm"
profile_toml "$ok_repo" | sed 's/$/\r/' >"$USER_DIR/crlf.toml"
run_fm profile show crlf
assert_eq "0" "$CODE" "(CRLF line ends) $OUT"
profile_toml 'repo = ""' >"$USER_DIR/emptyrepo.toml"
run_fm profile show emptyrepo
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "repo must not be empty"
profile_toml "$ok_repo" "" >"$USER_DIR/emptybranch.toml"
run_fm profile show emptybranch
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "branch must not be empty"
profile_toml "$ok_repo" "main|x" >"$USER_DIR/pipe.toml"
run_fm profile show pipe
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" 'branch must not contain "|"'
profile_toml 'repo = "https://example.com/a|b.git"' >"$USER_DIR/pipe.toml"
run_fm profile show pipe
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" 'repo must not contain "|"'

# ---- repo schemes (APP-14). The person's own profile takes any real address, local or plain http included;
# a transport helper that runs a program is never accepted
for good in "https://example.com/acme/x.git" "ssh://git@example.com/acme/x.git" "git@example.com:acme/x.git" \
  "http://git.lan/acme/x.git" "git://git.lan/acme/x.git" "file://${REMOTES}/acme_crm.git" "/Users/me/dev/x" "../x"; do
  profile_toml "repo = \"${good}\"" >"$USER_DIR/scheme.toml"
  run_fm profile show scheme
  assert_eq "0" "$CODE" "(${good}) $OUT"
done
for bad in "ext::sh -c id" "fd::3"; do
  profile_toml "repo = \"${bad}\"" >"$USER_DIR/scheme.toml"
  run_fm profile show scheme
  assert_eq "1" "$CODE" "(${bad}) $OUT"
  assert_contains "$OUT" "a git transport helper (transport::address) is never accepted"
done
profile_toml 'repo = "example.com/acme/x.git"' >"$USER_DIR/scheme.toml"
run_fm profile show scheme
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "use https://, ssh:// or user@host:path"
# a file from someone else (import, a subscription, a profile folder, a file with a source) takes https, ssh and
# user@host:path only; a local path or http is refused until BENCHBAR_ALLOW_LOCAL_REPOS=1
for foreign in "file://${REMOTES}/acme_crm.git" "/Users/me/dev/x" "http://git.lan/acme/x.git" "git://git.lan/acme/x.git"; do
  profile_toml "repo = \"${foreign}\"" >"$TMP_DIR/foreign.toml"
  BENCHBAR_OFFLINE=1 run_fm profile import "$TMP_DIR/foreign.toml" --as foreign --plan
  assert_eq "1" "$CODE" "(${foreign}) $OUT"
  assert_contains "$OUT" "use https://, ssh:// or user@host:path"
  assert_no_file "$USER_DIR/foreign.toml"
done
profile_toml "repo = \"file://${REMOTES}/acme_crm.git\"" >"$TMP_DIR/foreign.toml"
BENCHBAR_ALLOW_LOCAL_REPOS=1 BENCHBAR_OFFLINE=1 run_fm profile import "$TMP_DIR/foreign.toml" --as foreign --plan
assert_eq "0" "$CODE" "(the person can allow it) $OUT"
mkdir -p "$TMP_DIR/pp"; cp "$TMP_DIR/foreign.toml" "$TMP_DIR/pp/fromfolder.toml"
BENCHBAR_PROFILE_PATH="$TMP_DIR/pp" run_fm profile show fromfolder
assert_eq "1" "$CODE" "(a BENCHBAR_PROFILE_PATH folder is a team's clone) $OUT"
{ printf 'schema = 2\nsource = "https://example.com/x.toml"\n'; profile_toml 'repo = "/Users/me/dev/x"'; } >"$USER_DIR/imported.toml"
run_fm profile show imported
assert_eq "1" "$CODE" "(a file with a source came from someone else) $OUT"
rm -f "$USER_DIR"/{bom,crlf,emptyrepo,emptybranch,pipe,scheme,imported}.toml
# a transport helper typed on the command line is refused too, before any bench or network
make_fake_bench "$HOME/fb" macdev
run_fm app add "ext::sh -c id@x:y" --dry-run --json --bench-dir "$HOME/fb"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "transport helper"
# every benchbar git call turns the ext:: transport off, whatever the user's git config says
write_acme_profile
reset_calls; rm -f "$MOCK_STATE/git-config-env"
run_fm profile check acme
assert_calls_contain '^git ls-remote '
grep -q 'protocol.ext.allow' "$MOCK_STATE/git-config-env" || fail "git ran without protocol.ext.allow"
grep -q '=never' "$MOCK_STATE/git-config-env" || fail "git ran without protocol.ext.allow=never"

# ---- a repo that hangs ends at the deadline and leaves no process behind (APP-24)
SHIM="$TMP_DIR/shim"; mkdir -p "$SHIM"
cat >"$SHIM/git" <<SH
#!/bin/bash
if [[ -n "\${HANG_LSREMOTE:-}" && " \$* " == *" ls-remote "* ]]; then echo \$\$ >"\$HANG_PIDFILE"; exec sleep 60; fi
# the mock passes some commands (config) on to the next git on PATH: that must not be this shim again
PATH="\${PATH#$SHIM:}" exec "$ROOT/tests/mocks/bin/git" "\$@"
SH
chmod +x "$SHIM/git"
SECONDS=0
PATH="$SHIM:$PATH" HANG_LSREMOTE=1 HANG_PIDFILE="$TMP_DIR/hang.pid" FL_PROFILE_NET_SECS=1 FL_PROFILE_REACH_TTL=0 run_js profile check acme --json
assert_eq "0" "$CODE" "$OUT $ERR"
[[ "$SECONDS" -lt 40 ]] || fail "profile check waited ${SECONDS}s for a repo that hangs"
assert_contains "$OUT" "timed out after 1s"
assert_eq "None None" "$(ex '" ".join(str(r["reachable"]) for r in d["repos"])')"
[[ -s "$TMP_DIR/hang.pid" ]] || fail "the hanging git was never started"
! kill -0 "$(head -n1 "$TMP_DIR/hang.pid")" 2>/dev/null || fail "profile check left its hanging git running"

# ---- install, import and subscribe name the repos whose code they run (APP-15)
cat >"$USER_DIR/trust.toml" <<'TOML'
base = "v15-lts"

[[apps]]
name = "acme_crm"
repo = "https://github.com/evil-corp/acme_crm.git"
branch = "main"

[[apps]]
name = "acme_tools"
repo = "git@git.example.com:team/acme_tools.git"
branch = "main"
TOML
BENCHBAR_OFFLINE=1 run_fm install --dry-run --profile trust --bench-dir "$HOME/trust-dry"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "install will run code from these repos"
assert_contains "$OUT" "github.com/evil-corp"
assert_contains "$OUT" "git.example.com/team"
assert_contains "$OUT" "new here"
# a repo the bench already runs code from is not new
BENCHBAR_OFFLINE=1 run_fm profile import "$USER_DIR/trust.toml" --as trust2 --plan
assert_contains "$OUT" "install will run code from these repos: github.com/evil-corp git.example.com/team ("
BENCHBAR_OFFLINE=1 run_js profile import "$USER_DIR/trust.toml" --as trust2 --plan --json
assert_eq "github.com/evil-corp git.example.com/team" "$(ex '" ".join(d["runs_code_from"])')"
assert_eq "github.com/evil-corp git.example.com/team" "$(ex '" ".join(d["new_owners"])')"
# an update that changes a repo says so, with the new owner
cp "$USER_DIR/trust.toml" "$TMP_DIR/trust-v1.toml"
BENCHBAR_OFFLINE=1 run_fm profile import "$TMP_DIR/trust-v1.toml" --as trusted --yes
assert_eq "0" "$CODE" "$OUT"
sed_inplace 's#https://github.com/evil-corp/acme_crm.git#https://github.com/other-corp/acme_crm.git#' "$TMP_DIR/trust-v1.toml"
BENCHBAR_OFFLINE=1 run_fm profile update trusted --plan
assert_contains "$OUT" "this update adds or changes a repo: https://github.com/other-corp/acme_crm.git"
assert_contains "$OUT" "install will run code from these repos: github.com/other-corp"
rm -f "$USER_DIR"/trust.toml "$USER_DIR"/trusted.toml

# ---- a password never reaches a file made to be shared (APP-19)
BENCH="$HOME/frappe-bench"
make_fake_bench "$BENCH" macdev
rmdir "$BENCH/apps/erpnext"
printf 'frappe 15.0.0\n' >"$BENCH/sites/macdev/installed_apps"
printf 'frappe\n' >"$BENCH/sites/apps.txt"
add_policy acme_crm main
run_fm app add acme_crm --site macdev --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
git -C "$BENCH/apps/acme_crm" remote set-url upstream "ssh://deploy:secret@git.example.com/acme/acme_crm.git"
run_fm profile create acme-ssh --from-bench "$BENCH" --dir "$TEAM_REPO" --yes
assert_eq "0" "$CODE" "$OUT"
assert_not_contains "$(cat "$TEAM_REPO/acme-ssh.toml")" "secret"
grep -q '^repo = "ssh://deploy@git.example.com/acme/acme_crm.git"$' "$TEAM_REPO/acme-ssh.toml" || fail "the ssh user name stays, the password goes"
assert_contains "$OUT" "password or token"
git -C "$BENCH/apps/acme_crm" remote set-url upstream "git://user:pw@git.example.com/acme/acme_crm.git"
run_fm profile create acme-git --from-bench "$BENCH" --dir "$TEAM_REPO" --yes
assert_not_contains "$(cat "$TEAM_REPO/acme-git.toml" 2>/dev/null)" "pw@"
# a remote that is a local path or plain http is written, with a warning, and the profile reads back and is shown
for remote in "$REMOTES/acme_crm.git" "http://git.lan/acme/acme_crm.git"; do
  git -C "$BENCH/apps/acme_crm" remote set-url upstream "$remote"
  run_fm profile create acme-local --from-bench "$BENCH" --yes
  assert_eq "0" "$CODE" "(${remote}) $OUT"
  assert_contains "$OUT" "apps/acme_crm: the git remote is a local path or a plain http or git URL; teammates cannot clone this repo"
  grep -q "^repo = \"${remote}\"$" "$USER_DIR/acme-local.toml" || fail "the profile keeps ${remote}"
  run_fm profile show acme-local
  assert_eq "0" "$CODE" "(it reads back) $OUT"
  rm -f "$USER_DIR/acme-local.toml"
done
git -C "$BENCH/apps/acme_crm" remote set-url upstream "file://${REMOTES}/acme_crm.git"

# ---- a dry run leaves no temp file behind (APP-20)
mkdir -p "$TMP_DIR/tmpd"
TMPDIR="$TMP_DIR/tmpd" run_fm app add acme_tools --site acme.localhost --dry-run --json --bench-dir "$BENCH"
[[ -z "$(find "$TMP_DIR/tmpd" -name 'benchbar-siteapps.*' 2>/dev/null)" ]] || fail "a dry run left $(find "$TMP_DIR/tmpd" -name 'benchbar-siteapps.*')"

# ---- the TSV files have no empty cell the readers would collapse (APP-22)
for f in release-profiles app-bundles wkhtmltopdf; do
  awk -F '\t' -v f="$f" 'NR > 1 { for (i = 1; i <= NF; i++) if ($i == "") { printf "%s.tsv line %d column %d is empty\n", f, NR, i; bad = 1 } } END { exit bad }' "$ROOT/config/${f}.tsv" || fail "an empty cell in config/${f}.tsv"
done
awk -F '\t' 'NR == 1 { n = NF } NR > 1 && NF != n { printf "apps.tsv line %d has %d cells, not %d\n", NR, NF, n; bad = 1 } END { exit bad }' "$ROOT/config/apps.tsv" || fail "apps.tsv rows differ in width"
grep -q '^\*\.tsv text eol=lf$' "$ROOT/.gitattributes" || fail ".gitattributes pins tsv to LF"
grep -q '^\*\.toml text eol=lf$' "$ROOT/.gitattributes" || fail ".gitattributes pins toml to LF"
# a bundle with an empty label still reads its apps (read would fold two tabs into one)
printf 'bundle\tlabel\tapps\tnotes\nbare\t\terpnext\tsome notes\n' >"$TMP_DIR/bundles.tsv"
(
  FL_CONFIG_DIR="$TMP_DIR/cfg"; mkdir -p "$FL_CONFIG_DIR"; cp "$TMP_DIR/bundles.tsv" "$FL_CONFIG_DIR/app-bundles.tsv"
  export FL_CONFIG_DIR FL_TESTING=1
  # shellcheck disable=SC1091
  . "$ROOT/lib/frappe-local/ui.sh"; . "$ROOT/lib/frappe-local/version-policy.sh"; . "$ROOT/lib/frappe-local/profiles.sh"
  fl_bundles_json_v out
  # shellcheck disable=SC2154  # set by fl_bundles_json_v
  [[ "$out" == *'"name":"bare","label":null,"apps":["erpnext"],"description":"some notes"'* ]] || { printf 'bundle json: %s\n' "$out" >&2; exit 1; }
) || fail "an empty notes cell broke the bundle reader"

printf 'test-profile-hardening: ok\n'
