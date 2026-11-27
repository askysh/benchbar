#!/usr/bin/env bash
# app add, pinned byte for byte (issue 146): the exit code, stdout, stderr and mock calls of the plan
# (fl_app_add_plan: JSON and text) and of the apply (fl__ap_apply: every step, every failure), in
# tests/golden/app-add.txt. A change that only moves code (splitting those functions into steps)
# leaves the file as it is. PIN_UPDATE=1 rewrites it.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=tests/lib/apps-fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apps-fixtures.sh"
# shellcheck source=tests/lib/pin.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/pin.sh"
fail() { printf "FAIL (line %s): %s\n" "${BASH_LINENO[1]}" "$*" >&2; exit 1; }

BENCH="$HOME/frappe-bench"
B=(--bench-dir "$BENCH")
# fresh_bench: a bench with frappe only and one site, and no record of an earlier one
fresh_bench() {
  rm -rf "$BENCH" "$FL_STATE_DIR/benches"
  make_fake_bench "$BENCH" macdev
  printf 'frappe\n' >"$BENCH/sites/apps.txt"
  rmdir "$BENCH/apps/erpnext"
  printf 'frappe 15.0.0\n' >"$BENCH/sites/macdev/installed_apps"
}
for n in acme_crm acme_hr acme_ext; do make_app_remote "$n"; add_policy "$n" main; done
make_app_remote acme_pay acme_crm; add_policy acme_pay main
make_app_remote acme_orphan acme_gone; add_policy acme_orphan main
CRM_SHA="$(git -C "$REMOTES/acme_crm.git" rev-parse main)"

pdir() {
  local e
  e="$(find "$FL_STATE_DIR/benches" -maxdepth 1 -name 'frappe-bench-*' 2>/dev/null | awk 'NR==1')"
  [[ -z "$e" ]] || printf '%s.pending' "${e%.*}"
}
# the apps of the bench, its site's apps and the records, after a run
pstate() {
  local f
  pin_state "$1 apps.txt" "$(tr '\n' ' ' <"$BENCH/sites/apps.txt")"
  pin_state "$1 site apps" "$(tr '\n' ' ' <"$BENCH/sites/macdev/installed_apps")"
  pin_state "$1 folders" "$(cd "$BENCH/apps" && printf '%s ' *)"
  for f in "$(pdir)"/*.json; do
    [[ -n "$(pdir)" && -f "$f" ]] || continue
    pin_state "$1 record $(basename "$f")" "$(cat "$f")"
  done
}
run() { local n="$1"; shift; pin_run "$n" "$@"; pstate "$n"; }
token_of() { printf '%s' "$PIN_STDOUT" | jget - 'd["token"]'; }

# ---- the plan: JSON and text
fresh_bench
run "plan json" app add acme_crm --site macdev --dry-run --json "${B[@]}"
if pin_full; then
  run "plan text" app add acme_crm --site macdev --dry-run "${B[@]}"
  run "plan text, no site" app add acme_crm --dry-run "${B[@]}"
  run "plan json, skip backup" app add acme_crm --site macdev --skip-backup --dry-run --json "${B[@]}"
  run "plan text, skip backup" app add acme_crm --site macdev --skip-backup --dry-run "${B[@]}"
fi
run "plan json, required app" app add acme_pay --site macdev --dry-run --json "${B[@]}"
if pin_full; then
  run "plan text, required app" app add acme_pay --site macdev --dry-run "${B[@]}"
  run "plan json, batch" app add acme_crm acme_hr --site macdev --dry-run --json "${B[@]}"
  run "plan text, batch" app add acme_crm acme_hr --site macdev --dry-run "${B[@]}"
  run "plan json, batch with a shared required app" app add acme_pay acme_crm acme_hr --site macdev --dry-run --json "${B[@]}"
  run "plan json, install-on per app" app add acme_crm --install-on macdev acme_hr --dry-run --json "${B[@]}"
  run "plan json, pinned commit" app add acme_crm --commit "$CRM_SHA" --site macdev --dry-run --json "${B[@]}"
  run "plan text, pinned commit" app add acme_crm --commit "$CRM_SHA" --site macdev --dry-run "${B[@]}"
  run "plan json, all sites" app add acme_crm --all-sites --dry-run --json "${B[@]}"
  run "plan json, a branch" app add acme_crm --branch version-15 --site macdev --dry-run --json "${B[@]}"
  run "plan json, a branch that is not there" app add acme_crm --branch nosuch --site macdev --dry-run --json "${B[@]}"
  run "plan json, an unknown app" app add nosuchapp --site macdev --dry-run --json "${B[@]}"
  run "plan json, a url" app add "file://$REMOTES/acme_hr.git" --branch main --site macdev --dry-run --json "${B[@]}"
  run "plan json, the same app twice" app add acme_crm acme_crm --site macdev --dry-run --json "${B[@]}"
  run "plan json, required app nobody has" app add acme_orphan --site macdev --dry-run --json "${B[@]}"
  run "plan text, required app nobody has" app add acme_orphan --site macdev --dry-run "${B[@]}"
  run "plan, install-on with a stray comma" app add acme_crm --install-on ,macdev --dry-run --json "${B[@]}"
  run "plan, install-on a site that is not there" app add acme_crm --install-on nosite --dry-run --json "${B[@]}"
  run "plan, all sites and a site" app add acme_crm --all-sites --site macdev --dry-run --json "${B[@]}"
  run "plan, an unknown option" app add acme_crm --bogus --dry-run --json "${B[@]}"
  run "plan, no app" app add --dry-run --json "${B[@]}"
  run "json without dry run" app add acme_crm --site macdev --json "${B[@]}"
  use_mocks_without uv
  run "plan json, no uv" app add acme_crm --site macdev --dry-run --json "${B[@]}"
  run "plan text, no uv" app add acme_crm --site macdev --dry-run "${B[@]}"
  use_all_mocks
fi

# ---- refusals of --apply before any work
TOK0="$(printf '%064d' 0)"
if pin_full; then
  run "apply, bad token" app add acme_crm --site macdev --apply nope --yes --json "${B[@]}"
  run "apply, no --yes" app add acme_crm --site macdev --apply "$TOK0" --json "${B[@]}"
  run "apply with dry run" app add acme_crm --site macdev --apply "$TOK0" --dry-run --yes --json "${B[@]}"
  run "apply, token of another plan" app add acme_crm --site macdev --apply "$TOK0" --yes --json "${B[@]}"
fi
run "plan for the next ones" app add acme_crm --site macdev --dry-run --json "${B[@]}"
TOK="$(token_of)"
if pin_full; then
  FL_PLAN_NOW=$((FL_PLAN_NOW + 7200)) run "apply, expired token" app add acme_crm --site macdev --apply "$TOK" --yes --json "${B[@]}"
  run "cancelled at the prompt" app add acme_crm --site macdev "${B[@]}"
fi

# ---- the apply, JSON: one app, its plan and its result; then nothing left to do
run "apply, one app, json" app add acme_crm --site macdev --apply "$TOK" --yes --json "${B[@]}"
if pin_full; then
  run "plan, nothing to do" app add acme_crm --site macdev --dry-run --json "${B[@]}"
  TOK="$(token_of)"
  run "apply, nothing to do, json" app add acme_crm --site macdev --apply "$TOK" --yes --json "${B[@]}"
  run "text, nothing to do" app add acme_crm --site macdev --yes "${B[@]}"
  run "text, nothing to do, dry run" app add acme_crm --site macdev --dry-run "${B[@]}"
  printf '# edited\n' >>"$BENCH/apps/acme_crm/acme_crm/__init__.py"
  run "text, nothing to do, dirty app" app add acme_crm --site macdev --yes "${B[@]}"
  git -C "$BENCH/apps/acme_crm" checkout -q -- .
  run "plan, a stale token after the apply" app add acme_hr --site macdev --dry-run --json "${B[@]}"
  TOK="$(token_of)"
  printf 'acme_other\n' >>"$BENCH/sites/apps.txt"
  run "apply, stale token" app add acme_hr --site macdev --apply "$TOK" --yes --json "${B[@]}"
fi

# ---- the apply, text: one app, a required app, a batch
fresh_bench
if pin_full; then
  run "text apply, one app" app add acme_crm --site macdev --yes "${B[@]}"
  fresh_bench
fi
run "text apply, required app" app add acme_pay --site macdev --yes "${B[@]}"
if pin_full; then
  fresh_bench
  run "text apply, batch" app add acme_crm acme_hr --site macdev --yes "${B[@]}"
  fresh_bench
  run "text apply, no site" app add acme_crm --yes "${B[@]}"
  fresh_bench
  run "text apply, skip backup" app add acme_crm --site macdev --skip-backup --yes "${B[@]}"
  fresh_bench
  run "text apply, pinned commit" app add acme_crm --commit "$CRM_SHA" --site macdev --yes "${B[@]}"
  run "plan json, batch, json apply" app add acme_pay acme_hr --site macdev --dry-run --json "${B[@]}"
  TOK="$(token_of)"
  fresh_bench
  run "plan json again on a fresh bench" app add acme_pay acme_hr --site macdev --dry-run --json "${B[@]}"
  TOK="$(token_of)"
  run "apply, batch with a required app, json" app add acme_pay acme_hr --site macdev --apply "$TOK" --yes --json "${B[@]}"
fi

# ---- failures at each step, the plan that follows, the retry
for spec in "get-app MOCK_BENCH_GET_APP_EXIT" "get-app, early MOCK_BENCH_GET_APP_EARLY_EXIT" "build MOCK_BENCH_BUILD_EXIT" \
  "backup MOCK_BENCH_BACKUP_EXIT" "install MOCK_BENCH_INSTALL_APP_EXIT" "python MOCK_BENCH_REQUIREMENTS_PYTHON_EXIT"; do
  var="${spec##* }"; label="${spec% *}"
  [[ "$label" == install ]] || pin_full || continue
  fresh_bench
  export "$var=1"
  run "fails at ${label}" app add acme_crm --site macdev --yes "${B[@]}"
  unset "$var"
  if pin_full; then
    run "plan after ${label}, text" app add acme_crm --site macdev --dry-run "${B[@]}"
    run "plan after ${label}, json" app add acme_crm --site macdev --dry-run --json "${B[@]}"
  fi
  run "retry after ${label}" app add acme_crm --site macdev --yes "${B[@]}"
  if pin_full; then run "again after the retry, ${label}" app add acme_crm --site macdev --yes "${B[@]}"; fi
done
pin_smoke_end app-add.txt
fresh_bench
run "plan json for a failing apply" app add acme_crm acme_hr --site macdev --dry-run --json "${B[@]}"
TOK="$(token_of)"
MOCK_BENCH_INSTALL_APP_EXIT=1 run "apply fails at install, json" app add acme_crm acme_hr --site macdev --apply "$TOK" --yes --json "${B[@]}"
run "plan after the failed install, json" app add acme_crm acme_hr --site macdev --dry-run --json "${B[@]}"
run "retry, batch" app add acme_crm acme_hr --site macdev --yes "${B[@]}"
# a batch whose second clone fails: the first is kept, the records keep the build
fresh_bench
MOCK_BENCH_GET_APP_FAIL_FOR=acme_hr run "batch, the second clone fails" app add acme_crm acme_hr --site macdev --yes "${B[@]}"
run "plan after the failed clone" app add acme_crm acme_hr --site macdev --dry-run "${B[@]}"
run "retry, the clone works" app add acme_crm acme_hr --site macdev --yes "${B[@]}"
# the required app cannot be cloned: nothing after it runs
fresh_bench
MOCK_BENCH_GET_APP_FAIL_FOR=acme_crm run "the required app fails" app add acme_pay --site macdev --yes "${B[@]}"
run "plan after the failed required app" app add acme_pay --site macdev --dry-run --json "${B[@]}"
# a clone that left a folder behind and then failed (get-app's pip install, typically)
fresh_bench
MOCK_BENCH_GET_APP_EXIT=1 run "batch, get-app fails after the clone" app add acme_crm acme_hr --site macdev --yes "${B[@]}"
run "plan after it" app add acme_crm acme_hr --site macdev --dry-run --json "${B[@]}"
run "retry, batch, json" app add acme_crm acme_hr --site macdev --yes --json "${B[@]}"
# a record that cannot be written: the first write of an apply, and one in the middle of the run
fresh_bench
MOCK_BENCH_INSTALL_APP_EXIT=1 run "a failed add leaves a record" app add acme_hr --site macdev --yes "${B[@]}"
run "plan for the record test" app add acme_crm --site macdev --dry-run --json "${B[@]}"
TOK="$(token_of)"
chmod 500 "$(pdir)"
run "record cannot be written first" app add acme_crm --site macdev --apply "$TOK" --yes --json "${B[@]}"
chmod 700 "$(pdir)"
SHIM="$TMP_DIR/shim"; mkdir -p "$SHIM"
REAL_BENCH="$(command -v bench)"
cat >"$SHIM/bench" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"get-app"*) [[ "\${PIN_SHIM:-}" != "lock" ]] || chmod 500 "\$(find "\$FL_STATE_DIR/benches" -maxdepth 1 -name '*.pending' | awk 'NR==1')" ;;
esac
exec "$REAL_BENCH" "\$@"
SH
chmod +x "$SHIM/bench"
fresh_bench
OLDPATH="$PATH"
PATH="$SHIM:$PATH"
PIN_SHIM=lock run "record cannot be updated" app add acme_crm --site macdev --yes "${B[@]}"
chmod 700 "$(pdir)"
PATH="$OLDPATH"
# the app is gone from the bench when the verify pass looks
fresh_bench
cat >"$SHIM/bench" <<SH
#!/usr/bin/env bash
case "\$*" in
  "build"*) [[ "\${PIN_SHIM:-}" != "undo" ]] || { sed -i.bak '/^acme_crm\$/d' "\$PIN_BENCH/sites/apps.txt"; mv "\$PIN_BENCH/apps/acme_crm" "\$PIN_BENCH/apps/acme_crm.moved"; } ;;
esac
exec "$REAL_BENCH" "\$@"
SH
PATH="$SHIM:$PATH"
PIN_BENCH="$BENCH" PIN_SHIM=undo run "verify cannot find the app" app add acme_crm --site macdev --yes "${B[@]}"
PATH="$OLDPATH"
# a record of an earlier add that lists build, python requirements and a restart
fresh_bench
MOCK_BENCH_INSTALL_APP_EXIT=1 run "a failed add, for its record folder" app add acme_hr --site macdev --yes "${B[@]}"
printf '%s\n' '{"schema_version":1,"op":"app_add","app":"acme_crm","branch":"main","from":"","to":"","steps":[{"kind":"requirements_python","target":"acme_crm","name":"Python requirements"},{"kind":"build","target":"acme_crm","name":"Build"},{"kind":"install","target":"macdev","name":"Install on macdev"},{"kind":"restart","target":"","name":"Restart"}],"failed_step":"build","reason":"left over","url":"","started_at":"2026-10-29T10:00:00Z","updated_at":"2026-10-29T10:00:00Z"}' >"$(pdir)/acme_crm.json"
git clone -q --origin upstream "file://$REMOTES/acme_crm.git" "$BENCH/apps/acme_crm"
printf 'acme_crm\n' >>"$BENCH/sites/apps.txt"
run "plan, a record of an earlier add, text" app add acme_crm --site macdev --dry-run "${B[@]}"
run "plan, a record of an earlier add, json" app add acme_crm --site macdev --dry-run --json "${B[@]}"
run "finish the earlier add" app add acme_crm --site macdev --yes "${B[@]}"
printf 'not json\n' >"$(pdir)/acme_hr.json"
run "plan, a record that cannot be read" app add acme_hr --site macdev --dry-run --json "${B[@]}"

pin_check app-add.txt
echo "test-app-add-pin: ok"
