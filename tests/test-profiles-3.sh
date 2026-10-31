#!/usr/bin/env bash
# Team profiles, part 3 of 3: commit pins for frappe and erpnext (profile keys, show, check, install --frappe-commit).
# shellcheck source=tests/lib/profiles-fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/profiles-fixtures.sh"

unset BENCHBAR_PROFILE_PATH
mock_services_up
# ---- commit pins for frappe and erpnext: profile keys, show, check, install --frappe-commit
G=(git -c user.name=t -c user.email=t@example.com)
mkdir -p "$TMP_DIR/pinref"
"${G[@]}" -C "$TMP_DIR/pinref" init -q
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com \
  GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z" "${G[@]}" -C "$TMP_DIR/pinref" commit -q --allow-empty -m frappe
FSHA="$("${G[@]}" -C "$TMP_DIR/pinref" rev-parse HEAD)"
ESHA="0123456789abcdef0123456789abcdef01234567"
BADSHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
cat >"$USER_DIR/pinned.toml" <<TOML
schema = 1
base = "v15-lts"
frappe_commit = "${FSHA}"
erpnext_commit = "${ESHA}"

[[apps]]
name = "acme_crm"
repo = "file://${REMOTES}/acme_crm.git"
branch = "main"
commit = "$(git -C "$REMOTES/acme_crm.git" rev-parse main)"
TOML
run_fm profile show pinned
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "version-15 at ${FSHA}"
assert_contains "$OUT" "pinned at ${ESHA}"
run_js profile check pinned --json
assert_eq "0" "$CODE" "$OUT $ERR"
assert_eq "$FSHA $ESHA $(git -C "$REMOTES/acme_crm.git" rev-parse main)" "$(ex '" ".join([d["frappe_commit"], d["erpnext_commit"], d["repos"][0]["commit"]])')"
run_fm profile check pinned
assert_contains "$OUT" "frappe is pinned at ${FSHA}"
assert_contains "$OUT" "erpnext is pinned at ${ESHA}"
# a pin is 7 to 40 lower case hex characters, and never an option
printf 'base = "v15-lts"\nfrappe_commit = "HEAD"\n' >"$USER_DIR/badpin.toml"
run_fm profile show badpin
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "frappe_commit must be 7 to 40 lower case hex characters"
printf 'base = "v15-lts"\nerpnext_commit = "--upload-pack=x"\n' >"$USER_DIR/badpin.toml"
run_fm profile show badpin
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" '"erpnext_commit" must not start with "-"'
rm -f "$USER_DIR/badpin.toml"
# install: the pin is validated before anything runs; the plan shows it; flags win over the profile
run_fm install --dry-run --frappe-commit nothex --bench-dir "$HOME/pin-dry"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "Invalid commit hash: nothex"
BENCHBAR_OFFLINE=1 run_fm install --dry-run --profile pinned --bench-dir "$HOME/pin-dry"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "Commit pins: frappe=${FSHA} erpnext=${ESHA}"
BENCHBAR_OFFLINE=1 run_fm install --dry-run --profile pinned --frappe-commit abc1234 --erpnext-commit def5678 --bench-dir "$HOME/pin-dry"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "Commit pins: frappe=abc1234 erpnext=def5678"
run_fm install --dry-run --frappe-commit --bench-dir "$HOME/pin-dry"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "--frappe-commit needs a commit hash"
BENCHBAR_OFFLINE=1 run_fm install --dry-run --profile pinned --bench-dir "$HOME/pin-dry"
assert_contains "$OUT" "an erpnext commit pin is set, but erpnext is not among the apps to install"
# a pin the clone reaches: bench init builds nothing, the checkout comes first, then one build
export MOCK_BENCH_INIT_GIT=1
BENCH3="$HOME/pin-bench"
reset_calls
MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw run_fm install --yes --profile pinned --bench-dir "$BENCH3"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain "^bench init ${BENCH3} --frappe-branch version-15 --python .* --skip-assets\$"
assert_eq "$FSHA" "$(git -C "$BENCH3/apps/frappe" rev-parse HEAD)"
c="$(grep -n "git -C ${BENCH3}/apps/frappe checkout --quiet ${FSHA}\$" "$MOCK_LOG" | head -n1 | cut -d: -f1)"
b="$(grep -n '^bench build$' "$MOCK_LOG" | tail -n1 | cut -d: -f1)"
[[ -n "$c" && -n "$b" && "$c" -lt "$b" ]] || fail "frappe is checked out before the one build (${c} ${b})"
assert_no_file "$BENCH3/logs/.benchbar/needs-build" "(the build was done)"
# a second install is a no-op: the pin is already there, nothing is checked out or built again
reset_calls
MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw run_fm install --yes --profile pinned --bench-dir "$BENCH3"
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain '^bench (build|setup requirements|init|get-app)'
assert_calls_not_contain 'checkout --quiet'
# a pin the clone does not reach is refused before anything is built or created
BENCH4="$HOME/pin-bench-bad"
reset_calls
MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw run_fm install --yes --profile pinned --frappe-commit "$BADSHA" --bench-dir "$BENCH4"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "The pinned commit ${BADSHA} of frappe is not in its clone"
assert_contains "$OUT" "nothing was built"
assert_calls_not_contain '^bench (build|new-site|get-app|setup requirements)'
[[ -f "$BENCH4/logs/.benchbar/needs-build" ]] || fail "the refused install left no needs-build marker"
# a rerun without the pin notices the unbuilt assets and builds
printf 'base = "v15-lts"\n\n[[apps]]\nname = "acme_crm"\nrepo = "file://%s/acme_crm.git"\nbranch = "main"\n' "$REMOTES" >"$USER_DIR/plain.toml"
reset_calls
MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw run_fm install --yes --profile plain --bench-dir "$BENCH4"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^bench build$'
assert_no_file "$BENCH4/logs/.benchbar/needs-build"
# the same for an app of the profile
sed_inplace "s/^commit = \".*\"\$/commit = \"${BADSHA}\"/" "$USER_DIR/pinned.toml"
sed_inplace '/^frappe_commit/d; /^erpnext_commit/d' "$USER_DIR/pinned.toml"
BENCH5="$HOME/pin-bench-app"
reset_calls
MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw run_fm install --yes --profile pinned --bench-dir "$BENCH5"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "The pinned commit ${BADSHA} of acme_crm is not in its clone (branch main) and its remote did not hand it out; nothing was built."
assert_calls_not_contain '^bench (build|new-site|setup requirements)'
unset MOCK_BENCH_INIT_GIT

printf 'test-profiles-3: ok
'
