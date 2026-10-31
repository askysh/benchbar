#!/usr/bin/env bash
# Recovery after a partial failure, part 1 of 3 (the others: test-app-recovery-2 and -3): the pending record of app update for a failure at each step, and the retry that runs only what is left. Under the macOS mocks and under use_linux, side by side.
# shellcheck source=tests/lib/recovery-suite.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/recovery-suite.sh"

# ---------------------------------------------------------------- app update
# step NAME, the mock variable that fails it, its kind, and which of backup,
# fast forward, python, node, migrate and build the retry must run (1) or not (0)
for spec in \
  "backup MOCK_BENCH_BACKUP_EXIT backup 1 1 1 1 1 1" \
  "fast_forward MOCK_GIT_MERGE_EXIT fast_forward 0 1 1 1 1 1" \
  "python MOCK_BENCH_REQUIREMENTS_PYTHON_EXIT requirements_python 0 0 1 1 1 1" \
  "node MOCK_BENCH_REQUIREMENTS_NODE_EXIT requirements_node 0 0 0 1 1 1" \
  "migrate MOCK_BENCH_MIGRATE_EXIT migrate 0 0 0 0 1 1" \
  "build MOCK_BENCH_BUILD_EXIT build 0 0 0 0 0 1"; do
  read -r label var kind r_backup r_ff r_py r_node r_migrate r_build <<<"$spec"
  push_commits acme_crm 2
  before="$(app_head "$BENCH/apps/acme_crm")"
  want="$(git -C "$REMOTES/acme_crm.git" rev-parse main)"
  reset_calls
  run_with "$var" 1 app update acme_crm --yes --bench-dir "$BENCH"
  assert_eq "1" "$CODE" "${label}: $OUT"
  assert_file "$(pending_file acme_crm)" "(${label}: the failed update leaves a record)"
  assert_eq "app_update $kind $before $want" "$(pending_get acme_crm 'd["op"] + " " + d["failed_step"] + " " + d["from"] + " " + d["to"]')" "$label"
  assert_eq "1" "$(wc -l <"$(pending_file acme_crm)" | tr -d ' ')" "(${label}: one line)"
  assert_contains "$OUT" "benchbar app update acme_crm"
  # nothing after the failed step ran
  if [[ "$kind" == "backup" || "$kind" == "fast_forward" ]]; then assert_eq "0" "$(calls 'setup requirements')" "$label"; fi
  # the plan says what is left, and the code stays where the run left it
  run_fm app update acme_crm --dry-run --json --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
  assert_eq "$kind" "$(printf '%s' "$OUT" | jget - 'd["pending"]["failed_step"]')" "$label"
  assert_eq "$kind" "$(printf '%s' "$OUT" | jget - 'd["steps"][0]["kind"]')" "(${label}: the plan starts at the failed step)"
  # the retry: only what is left, exit 0, the record gone
  reset_calls
  run_fm app update acme_crm --yes --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "${label}: $OUT"
  assert_eq "$r_backup" "$(calls '^bench --site macdev backup$')" "${label}: backup"
  assert_eq "$r_ff" "$(calls 'merge --ff-only')" "${label}: fast forward"
  assert_eq "$r_py" "$(calls '^bench setup requirements --python acme_crm$')" "${label}: python"
  assert_eq "$r_node" "$(calls '^bench setup requirements --node acme_crm$')" "${label}: node"
  assert_eq "$r_migrate" "$(calls '^bench --site macdev migrate$')" "${label}: migrate"
  assert_eq "$r_build" "$(calls '^bench build --app acme_crm$')" "${label}: build"
  assert_eq "" "$(pending_file acme_crm)" "(${label}: done, no record)"
  assert_eq "$want" "$(app_head "$BENCH/apps/acme_crm")"
  # a second run is a no-op
  reset_calls
  run_fm app update acme_crm --yes --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
  assert_contains "$OUT" "unchanged: acme_crm is up to date"
  assert_calls_not_contain '^bench '
  assert_calls_not_contain 'merge'
done

printf 'test-app-recovery (%s): ok\n' "$RECOVERY_PASS"
