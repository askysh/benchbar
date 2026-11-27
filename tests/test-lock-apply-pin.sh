#!/usr/bin/env bash
# lock apply, pinned byte for byte (issue 146): the exit code, stdout, stderr and mock calls of every way
# the command ends, in tests/golden/lock-apply.txt. A change that only moves code (splitting
# fl_cmd_lock_apply into steps) leaves the file as it is. PIN_UPDATE=1 rewrites it.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=tests/lib/apps-fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apps-fixtures.sh"
# shellcheck source=tests/lib/pin.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/pin.sh"
fail() { printf "FAIL (line %s): %s\n" "${BASH_LINENO[1]}" "$*" >&2; exit 1; }

BENCH="$HOME/frappe-bench"
LOCK="$BENCH/benchbar.toml"
B=(--bench-dir "$BENCH")
make_fake_bench "$BENCH" macdev
rmdir "$BENCH/apps/erpnext"
printf 'frappe 15.0.0\n' >"$BENCH/sites/macdev/installed_apps"
make_app_remote frappe
mv "$BENCH/apps/frappe" "$TMP_DIR/frappe-fake"
git clone -q --origin upstream --branch version-15 "file://$REMOTES/frappe.git" "$BENCH/apps/frappe"
printf 'frappe\n' >"$BENCH/sites/apps.txt"
for n in acme_crm acme_base acme_new acme_old acme_pin; do make_app_remote "$n"; done
add_policy acme_crm main; add_policy acme_base version-15; add_policy acme_new main; add_policy acme_old main; add_policy acme_pin main
"$FM" app add acme_crm --site macdev --yes "${B[@]}" >/dev/null 2>&1 || fail "setup: app add acme_crm"
"$FM" app add acme_base --yes "${B[@]}" >/dev/null 2>&1 || fail "setup: app add acme_base"
export MOCK_BENCH_VERSION=5.31.0
"$FM" lock write --yes "${B[@]}" >/dev/null 2>&1 || fail "setup: lock write"
cp "$LOCK" "$TMP_DIR/lock.good"

# the heads of the apps, after a run
pstate() {
  local a
  for a in acme_crm acme_base acme_new acme_old acme_pin; do
    [[ -d "$BENCH/apps/$a" ]] || continue
    pin_state "$1 $a" "$(git -C "$BENCH/apps/$a" rev-parse --short HEAD) $(git -C "$BENCH/apps/$a" symbolic-ref --short -q HEAD || printf detached)"
  done
  pin_state "$1 apps.txt" "$(tr '\n' ' ' <"$BENCH/sites/apps.txt")"
}
run() { local n="$1"; shift; pin_run "$n" "$@"; pstate "$n"; }
token_of() { printf '%s' "$PIN_STDOUT" | jget - 'd["token"]'; }
head_of() { git -C "$BENCH/apps/$1" rev-parse HEAD; }

# ---- usage and refusals before any work
TOK0="$(printf '%064d' 0)"
if pin_full; then
  run "unknown option" lock apply --bogus "${B[@]}"
  run "apply, bad token" lock apply --apply nope --yes "${B[@]}"
  run "apply, no --yes" lock apply --apply "$TOK0" "${B[@]}"
  run "apply with dry run" lock apply --apply "$TOK0" --dry-run --yes "${B[@]}"
  run "apply, nothing to do, token of nothing" lock apply --apply "$TOK0" --yes "${B[@]}"
fi
run "no lockfile at the path" lock apply --lock "$TMP_DIR/none.toml" --yes "${B[@]}"

# ---- in sync
if pin_full; then
  run "in sync" lock apply --yes "${B[@]}"
  run "in sync, dry run" lock apply --dry-run "${B[@]}"
fi
run "in sync, dry run json" lock apply --dry-run --json "${B[@]}"
if pin_full; then
  run "in sync, other profile in the lock" lock apply --yes "${B[@]}"
  sed_inplace 's/^profile = "v15-lts"$/profile = "v16-lts"/' "$LOCK"
  run "in sync, the lock names another profile" lock apply --yes "${B[@]}"
  cp "$TMP_DIR/lock.good" "$LOCK"
fi
# (--lock keeps the path for the bench: the scenarios below see a bench that has one)
run "in sync, --lock given" lock apply --lock "$LOCK" --yes "${B[@]}"

# ---- behind: the lock pins a newer commit than the checkout has
pin_commit "$WORK/acme_crm" acme_crm 2
NEWEST="$(git -C "$REMOTES/acme_crm.git" rev-parse main)"
OLD="$(head_of acme_crm)"
sed_inplace "s/^commit = \"${OLD}\"$/commit = \"${NEWEST}\"/" "$LOCK"
cp "$LOCK" "$TMP_DIR/lock.behind"
if pin_full; then run "behind, dry run" lock apply --dry-run "${B[@]}"; fi
run "behind, dry run json" lock apply --dry-run --json "${B[@]}"
TOK="$(token_of)"
if pin_full; then
  run "behind, cancelled at the prompt" lock apply "${B[@]}"
  FL_PLAN_NOW=$((FL_PLAN_NOW + 7200)) run "behind, apply with an expired token" lock apply --apply "$TOK" --yes "${B[@]}"
  run "behind, apply with a token of another plan" lock apply --apply "$TOK0" --yes "${B[@]}"
  MOCK_BENCH_REQUIREMENTS_PYTHON_EXIT=1 run "behind, requirements fail" lock apply --yes "${B[@]}"
  git -C "$BENCH/apps/acme_crm" reset -q --hard "$OLD"
  MOCK_BENCH_BUILD_EXIT=1 run "behind, build fails" lock apply --yes "${B[@]}"
  git -C "$BENCH/apps/acme_crm" reset -q --hard "$OLD"
  MOCK_GIT_MERGE_EXIT=1 run "behind, the fast forward fails" lock apply --yes "${B[@]}"
  git -C "$BENCH/apps/acme_crm" reset -q --hard "$OLD"
else
  # what the failed applies above leave: the pinned commit is in the clone (a fetch), so the apply below needs no fetch
  git -C "$BENCH/apps/acme_crm" fetch -q upstream "$NEWEST"
fi
run "behind, apply with its token" lock apply --apply "$TOK" --yes --json "${B[@]}"
if pin_full; then
  git -C "$BENCH/apps/acme_crm" reset -q --hard "$OLD"
  run "behind, text apply" lock apply --yes "${B[@]}"
  run "behind, after the apply" lock apply --yes "${B[@]}"
fi

# ---- ahead and diverged: local work outranks the lock, and is skipped
git -C "$BENCH/apps/acme_crm" commit -q --allow-empty -m "local two"
run "ahead, skipped" lock apply --yes "${B[@]}"
if pin_full; then run "ahead, dry run json" lock apply --dry-run --json "${B[@]}"; fi
git -C "$BENCH/apps/acme_crm" reset -q --hard HEAD~3
git -C "$BENCH/apps/acme_crm" commit -q --allow-empty -m "other work"
if pin_full; then run "diverged, skipped" lock apply --yes "${B[@]}"; fi
git -C "$BENCH/apps/acme_crm" reset -q --hard "$NEWEST"

# ---- dirty, and a folder that is not a listed git app
if pin_full; then
  printf 'y\n' >>"$BENCH/apps/acme_crm/acme_crm/__init__.py"
  run "dirty, nothing else to do" lock apply --yes "${B[@]}"
  git -C "$BENCH/apps/acme_crm" reset -q --hard HEAD~1
  printf 'y\n' >>"$BENCH/apps/acme_crm/acme_crm/__init__.py"
  run "dirty and behind, skipped" lock apply --yes "${B[@]}"
  git -C "$BENCH/apps/acme_crm" checkout -q -- .
  git -C "$BENCH/apps/acme_crm" reset -q --hard "$NEWEST"
  mv "$BENCH/apps/acme_base/.git" "$TMP_DIR/base.git.moved"
  run "a folder that is not a git app" lock apply --yes "${B[@]}"
  mv "$TMP_DIR/base.git.moved" "$BENCH/apps/acme_base/.git"
fi

# ---- branch: acme_base follows version-15, the lock says main
cp "$TMP_DIR/lock.behind" "$LOCK"
cp "$LOCK" "$TMP_DIR/lock.good2"
if pin_full; then
  sed_inplace '/name = "acme_base"/,/^$/s/^branch = "version-15"$/branch = "main"/' "$LOCK"
  sed_inplace '/name = "acme_base"/,/^$/{/^commit = /d;}' "$LOCK"
  run "branch, dry run" lock apply --dry-run "${B[@]}"
  run "branch, apply" lock apply --yes "${B[@]}"
  run "branch, again" lock apply --yes "${B[@]}"
  # a detached HEAD with commits no branch holds
  git -C "$BENCH/apps/acme_base" checkout -q --detach
  git -C "$BENCH/apps/acme_base" commit -q --allow-empty -m "work on a detached head"
  sed_inplace '/name = "acme_base"/,/^$/s/^branch = "main"$/branch = "version-15"/' "$LOCK"
  run "detached with work, skipped step" lock apply --yes "${B[@]}"
  git -C "$BENCH/apps/acme_base" switch -q -c detached-work
  run "branch back, after the detached work was kept" lock apply --yes "${B[@]}"
fi

# ---- missing: a new repo, and the pin behind its tip
cp "$TMP_DIR/lock.good2" "$LOCK"
printf '\n[[app]]\nname = "acme_new"\nrepo = "file://%s/acme_new.git"\nbranch = "main"\ncommit = "%s"\n' "$REMOTES" "$(git -C "$REMOTES/acme_new.git" rev-parse main)" >>"$LOCK"
if pin_full; then
  run "missing, dry run" lock apply --dry-run "${B[@]}"
  run "missing, dry run json" lock apply --dry-run --json "${B[@]}"
  TOK="$(token_of)"
fi
run "missing, apply" lock apply --yes "${B[@]}"
pin_smoke_end lock-apply.txt
run "missing, after the clone" lock apply --yes "${B[@]}"
OLD_PIN="$(git -C "$REMOTES/acme_old.git" rev-parse main)"
pin_commit "$WORK/acme_old" acme_old 2
printf '\n[[app]]\nname = "acme_old"\nrepo = "file://%s/acme_old.git"\nbranch = "main"\ncommit = "%s"\n' "$REMOTES" "$OLD_PIN" >>"$LOCK"
run "missing, the pin is behind the tip" lock apply --yes "${B[@]}"
printf '\n[[app]]\nname = "acme_pin"\nrepo = "file://%s/acme_pin.git"\nbranch = "main"\ncommit = "%s"\n' "$REMOTES" "0123456789abcdef0123456789abcdef01234567" >>"$LOCK"
run "missing, the pin is not on the remote" lock apply --yes "${B[@]}"
sed_inplace "s/0123456789abcdef0123456789abcdef01234567/$(git -C "$REMOTES/acme_pin.git" rev-parse main)/" "$LOCK"
run "missing, the pin is corrected" lock apply --yes "${B[@]}"
MOCK_BENCH_GET_APP_FAIL_FOR=acme_zzz run "missing, a clone that fails" lock apply --yes "${B[@]}"
make_app_remote acme_late
printf '\n[[app]]\nname = "acme_late"\nrepo = "file://%s/acme_late.git"\nbranch = "main"\n' "$REMOTES" >>"$LOCK"
MOCK_BENCH_GET_APP_FAIL_FOR=acme_late run "missing, get-app fails" lock apply --yes "${B[@]}"
run "missing, no pin, clone works" lock apply --yes "${B[@]}"

# ---- extra, and what a site lacks
make_app_remote acme_extra
add_policy acme_extra main
"$FM" app add acme_extra --yes "${B[@]}" >/dev/null 2>&1 || fail "setup: app add acme_extra"
run "extra app stays" lock apply --yes "${B[@]}"
printf '\n[[site]]\nname = "ghost"\napps = ["acme_crm"]\n' >>"$LOCK"
run "a site the bench lacks" lock apply --yes "${B[@]}"

pin_check lock-apply.txt
echo "test-lock-apply-pin: ok"
