#!/usr/bin/env bash
# Git safety of the app commands (issue 152, APP-4 to APP-10, APP-17, APP-18):
# the user's own ssh command is kept, network git has a deadline, the branch
# check happens before get-app, a lock pin gets its own requirements, a team
# profile moves erpnext with frappe, apps.tsv names real branches, an app
# that needs another Frappe is refused, ls-remote matches the exact ref and a
# deleted upstream branch is named as such.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=tests/lib/apps-fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apps-fixtures.sh"
# shellcheck source=lib/frappe-local/ui.sh
. "$ROOT/lib/frappe-local/ui.sh"
# shellcheck source=lib/frappe-local/run.sh
. "$ROOT/lib/frappe-local/run.sh"

git config --global user.email me@example.com
run_json() { set +e; OUT="$("$FM" "$@" 2>"$MOCK_STATE/stderr")"; CODE="$?"; ERR="$(cat "$MOCK_STATE/stderr")"; set -e; }
remote_head() { git -C "$REMOTES/$1.git" rev-parse "${2:-main}"; }

# ---------------------------------------------------------------- APP-4: the user's ssh command
# a git in front of everything: ls-remote prints the ssh command it was given
SHIM="$TMP_DIR/shim"
mkdir -p "$SHIM"
# the real git behind the shims (the git mock would find a shim as "the real git" and loop)
REAL_GIT=""
for c in /usr/bin/git /opt/homebrew/bin/git /usr/local/bin/git; do [[ -x "$c" ]] && { REAL_GIT="$c"; break; }; done
cat >"$SHIM/git" <<SH
#!/bin/bash
case " \$* " in *" ls-remote "*) printf '%s\n' "\${GIT_SSH_COMMAND:-}"; exit 0 ;; esac
exec "$REAL_GIT" "\$@"
SH
chmod +x "$SHIM/git"
OLD_PATH="$PATH"
PATH="$SHIM:$PATH"
unset GIT_SSH_COMMAND
assert_eq "ssh -o BatchMode=yes -o ConnectTimeout=${FL_GIT_CONNECT_SECS}" "$(fl_git_net ls-remote x)" "(nothing of the user's: plain ssh)"
git config --global core.sshCommand "ssh -i /keys/work -o IdentitiesOnly=yes"
assert_eq "ssh -i /keys/work -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=${FL_GIT_CONNECT_SECS}" "$(fl_git_net ls-remote x)" "(core.sshCommand is kept)"
mkdir "$TMP_DIR/sshrepo"
git -C "$TMP_DIR/sshrepo" init -q
git -C "$TMP_DIR/sshrepo" config core.sshCommand "ssh -i /keys/local"
assert_eq "ssh -i /keys/local -o BatchMode=yes -o ConnectTimeout=${FL_GIT_CONNECT_SECS}" "$(fl_git_net -C "$TMP_DIR/sshrepo" ls-remote x)" "(a repo's own core.sshCommand wins)"
assert_eq "ssh -F /my/config -o BatchMode=yes -o ConnectTimeout=${FL_GIT_CONNECT_SECS}" "$(GIT_SSH_COMMAND="ssh -F /my/config" fl_git_net ls-remote x)" "(GIT_SSH_COMMAND wins over core.sshCommand)"
git config --global --unset core.sshCommand
PATH="$OLD_PATH"

# ---------------------------------------------------------------- the bench
BENCH="$HOME/frappe-bench"
make_fake_bench "$BENCH" macdev
printf 'frappe\n' >"$BENCH/sites/apps.txt"
rmdir "$BENCH/apps/erpnext"
printf 'frappe 15.0.0\n' >"$BENCH/sites/macdev/installed_apps"
mkdir -p "$BENCH/apps/frappe/frappe"
printf '__version__ = "15.113.4"\n' >"$BENCH/apps/frappe/frappe/__init__.py"
plan() { run_json app add "$@" --dry-run --json --bench-dir "$BENCH"; }
apply() { run_json app add "$@" --apply "$TOKEN" --yes --json --bench-dir "$BENCH"; }

# a git in front that hangs on fetch (HANG_FETCH) and moves a remote once
# (MOVE_HOOK) right after the plan's own clone has read the branch
cat >"$SHIM/git" <<SH
#!/bin/bash
if [[ -n "\${HANG_FETCH:-}" && " \$* " == *" fetch "* ]]; then sleep 60; exit 1; fi
"$REAL_GIT" "\$@"
code=\$?
if [[ -n "\${MOVE_HOOK:-}" && -f "\$MOVE_HOOK" && " \$* " == *" --no-checkout "* ]]; then bash "\$MOVE_HOOK"; rm -f "\$MOVE_HOOK"; fi
exit \$code
SH
export PATH="$SHIM:$PATH"

# ---------------------------------------------------------------- APP-5: a fetch that hangs is cut
make_app_remote acme_up
add_policy acme_up main
run_json app add acme_up --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT $ERR"
push_commits acme_up 1
SECONDS=0
HANG_FETCH=1 FL_GIT_CLONE_TIMEOUT=1 run_json app update acme_up --yes --skip-backup --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT $ERR"
assert_contains "$OUT$ERR" "timed out after 1s"
[[ "$SECONDS" -lt 40 ]] || fail "app update waited ${SECONDS}s for a hanging fetch"

# ---------------------------------------------------------------- APP-18: the upstream branch is gone
make_app_remote acme_gone
add_policy acme_gone version-15
run_json app add acme_gone --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT $ERR"
git -C "$REMOTES/acme_gone.git" branch -q -D version-15
run_json app update acme_gone --yes --skip-backup --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT $ERR"
assert_contains "$ERR$OUT" "no longer has the branch version-15"
assert_contains "$ERR$OUT" "remote branches: main"
assert_contains "$ERR$OUT" "git -C"
assert_not_contains "$ERR$OUT" "ssh-add"

# ---------------------------------------------------------------- APP-17: the exact ref
git init -q --bare "$REMOTES/acme_fm.git"
(
  cd "$WORK" && rm -rf acme_fm && git init -q -b feature/main acme_fm && cd acme_fm || exit 1
  mkdir acme_fm; printf 'app_name = "acme_fm"\n' >acme_fm/hooks.py
  git add -A && git commit -q -m first && git push -q "file://$REMOTES/acme_fm.git" feature/main
)
plan "file://$REMOTES/acme_fm.git" --branch main
assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')" "$OUT $ERR"
assert_contains "$(printf '%s' "$OUT" | jget - 'd["errors"][0]')" "branch main not found"

# ---------------------------------------------------------------- APP-6: the branch moved after the plan
make_app_remote acme_mv
add_policy acme_mv main
plan acme_mv --site macdev
assert_eq "0" "$CODE" "$ERR"
TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
cat >"$TMP_DIR/move.sh" <<SH
cd "$WORK/acme_mv" && printf 'x\n' >>acme_mv/changes.txt && git add -A && git commit -q -m moved && git push -q origin main
SH
export MOVE_HOOK="$TMP_DIR/move.sh"
reset_calls
apply acme_mv --site macdev
unset MOVE_HOOK
assert_eq "1" "$CODE" "$ERR"
assert_calls_not_contain '^bench get-app'
assert_contains "$ERR" "moved after the plan was made"
assert_contains "$ERR" "nothing was cloned"
assert_not_contains "$(cat "$BENCH/sites/apps.txt")" "acme_mv"

# ---------------------------------------------------------------- APP-6: a pin behind the tip gets its requirements
make_app_remote acme_pn
add_policy acme_pn main
P1="$(remote_head acme_pn)"
push_commits acme_pn 2
plan acme_pn --commit "$P1" --site macdev
assert_eq "0" "$CODE" "$ERR"
TOKEN="$(printf '%s' "$OUT" | jget - 'd["token"]')"
reset_calls
apply acme_pn --commit "$P1" --site macdev
assert_eq "0" "$CODE" "$ERR"
assert_eq "$P1" "$(app_head "$BENCH/apps/acme_pn")"
assert_calls_contain '^bench setup requirements --python acme_pn$'
assert_calls_contain '^bench setup requirements --node acme_pn$'

# ---------------------------------------------------------------- APP-7: lock apply on a fresh bench
LOCK="$BENCH/benchbar.toml"
make_app_remote frappe
mv "$BENCH/apps/frappe" "$TMP_DIR/frappe-fake"
git clone -q --origin upstream --branch version-15 "file://$REMOTES/frappe.git" "$BENCH/apps/frappe"
printf 'frappe\n' >"$BENCH/sites/apps.txt"
export MOCK_BENCH_VERSION=5.31.0
run_json lock write --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT $ERR"
make_app_remote acme_lk
L1="$(remote_head acme_lk)"
push_commits acme_lk 2
printf '\n[[app]]\nname = "acme_lk"\nrepo = "file://%s/acme_lk.git"\nbranch = "main"\ncommit = "%s"\n' "$REMOTES" "$L1" >>"$LOCK"
reset_calls
run_json lock apply --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT $ERR"
assert_eq "$L1" "$(app_head "$BENCH/apps/acme_lk")"
assert_calls_contain '^bench setup requirements --python acme_lk$'
assert_calls_contain '^bench setup requirements --node acme_lk$'

# ---------------------------------------------------------------- APP-5: lock apply does not hang on a fetch
make_app_remote acme_lh
L2="$(remote_head acme_lh)"
git clone -q --origin upstream --branch main "file://$REMOTES/acme_lh.git" "$BENCH/apps/acme_lh"
printf 'acme_lh\n' >>"$BENCH/sites/apps.txt"
push_commits acme_lh 1
NEW="$(remote_head acme_lh)"
printf '\n[[app]]\nname = "acme_lh"\nrepo = "file://%s/acme_lh.git"\nbranch = "main"\ncommit = "%s"\n' "$REMOTES" "$NEW" >>"$LOCK"
SECONDS=0
HANG_FETCH=1 FL_GIT_CLONE_TIMEOUT=1 run_json lock apply --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT $ERR"
assert_contains "$OUT$ERR" "timed out after 1s"
[[ "$SECONDS" -lt 60 ]] || fail "lock apply waited ${SECONDS}s for a hanging fetch"
assert_eq "$L2" "$(app_head "$BENCH/apps/acme_lh")" "(nothing moved)"

# ---------------------------------------------------------------- APP-10: an app for another Frappe
printf '__version__ = "15.113.4"\n' >"$BENCH/apps/frappe/frappe/__init__.py"
make_app_remote acme_f16
printf '[project]\nname = "acme_f16"\n\n[tool.bench.frappe-dependencies]\nfrappe = ">=16.0.0-dev,<17.0.0"\n' >"$WORK/acme_f16/pyproject.toml"
git -C "$WORK/acme_f16" commit -q -am "needs frappe 16" && git -C "$WORK/acme_f16" push -q origin main
add_policy acme_f16 main
plan acme_f16
assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')" "$OUT $ERR"
assert_contains "$(printf '%s' "$OUT" | jget - 'd["errors"][0]')" "needs frappe >=16.0.0-dev,<17.0.0"
assert_contains "$(printf '%s' "$OUT" | jget - 'd["errors"][0]')" "frappe 15.113.4"
printf '__version__ = "16.2.0"\n' >"$BENCH/apps/frappe/frappe/__init__.py"
plan acme_f16
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')" "(a Frappe 16 bench takes it) $OUT $ERR"
printf '__version__ = "15.113.4"\n' >"$BENCH/apps/frappe/frappe/__init__.py"

# ---------------------------------------------------------------- APP-8: a team profile moves erpnext with frappe
USER_DIR="$HOME/.config/benchbar/profiles"
mkdir -p "$USER_DIR"
printf 'schema = 1\nbase = "v15-lts"\nfrappe_branch = "develop"\nbundle = "minimal"\n' >"$USER_DIR/dev.toml"
printf 'schema = 1\nbase = "v15-lts"\nfrappe_branch = "version-16"\nbundle = "common"\n' >"$USER_DIR/v16.toml"
printf 'schema = 1\nbase = "v15-lts"\nfrappe_branch = "my-fork"\nbundle = "minimal"\n' >"$USER_DIR/fork.toml"
printf 'schema = 1\nbase = "v15-lts"\nfrappe_branch = "my-fork"\nerpnext_branch = "my-erp"\nbundle = "minimal"\n' >"$USER_DIR/fork2.toml"
printf 'schema = 1\nbase = "v15-lts"\nfrappe_branch = "my-fork"\n\n[[apps]]\nname = "x_app"\nrepo = "https://example.com/x.git"\nbranch = "main"\n' >"$USER_DIR/fork3.toml"
field() { printf '%s\n' "$OUT" | awk -v k="$1" '$1 == k {print $2; exit}'; }
run_json profile show dev
assert_eq "0" "$CODE" "$OUT $ERR"
assert_eq "develop" "$(field erpnext)"
run_json profile show v16
assert_eq "version-16 version-16" "$(field frappe) $(field erpnext)"
run_json profile show fork
assert_eq "1" "$CODE" "$OUT $ERR"
assert_contains "$OUT$ERR" "set erpnext_branch"
run_json profile show fork2
assert_eq "0" "$CODE" "$OUT $ERR"
assert_eq "my-erp" "$(field erpnext)"
run_json profile show fork3
assert_eq "0" "$CODE" "(no erpnext in the profile, nothing to pair) $OUT $ERR"

# ---------------------------------------------------------------- APP-9: apps.tsv names real branches
tsv="$ROOT/config/apps.tsv"
row() { awk -F '\t' -v a="$1" '$1 == a {print $3 " " $4}' "$tsv"; }
assert_eq "master master" "$(row builder)" "(frappe/builder has develop and master, no main)"
assert_eq "version-15 version-16" "$(row crm)"
assert_eq "version-15 version-16" "$(row helpdesk)"
assert_eq "version-15 version-16" "$(row lms)"
# the checker: every repo and branch of a table answers to ls-remote
mkdir -p "$TMP_DIR/cfg"
{
  printf 'app\trepo\tv15-lts\tv16-lts\tpriority\tnotes\n'
  printf 'acme_up\tfile://%s/acme_up.git\tmain\tmain\t10\tgood\n' "$REMOTES"
  printf 'acme_bad\tfile://%s/acme_up.git\tnope\tmain\t20\tbad\n' "$REMOTES"
} >"$TMP_DIR/cfg/apps.tsv"
set +e; OUT="$(bash "$ROOT/scripts/check-apps-branches.sh" "$TMP_DIR/cfg/apps.tsv" 2>&1)"; CODE=$?; set -e
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "acme_bad: branch nope (v15-lts) not found"
assert_not_contains "$OUT" "acme_up:"
head -2 "$TMP_DIR/cfg/apps.tsv" >"$TMP_DIR/cfg/ok.tsv"
set +e; OUT="$(bash "$ROOT/scripts/check-apps-branches.sh" "$TMP_DIR/cfg/ok.tsv" 2>&1)"; CODE=$?; set -e
assert_eq "0" "$CODE" "$OUT"

printf 'ok\n'
