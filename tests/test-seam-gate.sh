#!/usr/bin/env bash
# CORE-25 (#142): test seams read from the environment count only under
# FL_TESTING=1. The runner's timing and log variables, and the Linux files
# the platform layer reads (FL_PROC_DIR and its kin), are ignored in a run
# without it.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# ---- the Linux file seams: honoured with FL_TESTING=1, the real path without
PROBE=". '$ROOT/lib/frappe-local/ui.sh'; . '$ROOT/lib/frappe-local/platform-linux.sh'; printf '%s %s %s %s' \"\$FL_PROC_DIR\" \"\$FL_PROC_VERSION\" \"\$FL_OS_RELEASE\" \"\$FL_USER_RUN_BASE\""
SEAMS=(FL_PROC_DIR=/fake/proc FL_PROC_VERSION=/fake/version FL_OS_RELEASE=/fake/os FL_USER_RUN_BASE=/fake/run)
assert_eq "/fake/proc /fake/version /fake/os /fake/run" "$(env FL_TESTING=1 "${SEAMS[@]}" bash -c "$PROBE" 2>/dev/null)" "(the tests' seams)"
assert_eq "/proc /proc/version /etc/os-release /run/user" "$(env FL_TESTING=0 "${SEAMS[@]}" bash -c "$PROBE" 2>/dev/null)" "(a production run ignores them)"
assert_eq "/proc /proc/version /etc/os-release /run/user" "$(env -u FL_TESTING "${SEAMS[@]}" bash -c "$PROBE" 2>/dev/null)" "(no FL_TESTING at all)"

# ---- the bench runner: BENCHBAR_STATE_LOG records transitions only under FL_TESTING=1
. "$ROOT/lib/frappe-local/ui.sh"; . "$ROOT/lib/frappe-local/run.sh"; . "$ROOT/lib/frappe-local/templates.sh"
RB="$TMP_DIR/runner-bench"
make_fake_bench "$RB"
runner="$RB/benchbar-run.sh"
fl_template_render bench-run.sh "BENCH_DIR=$RB" "BENCH_NAME=runner-bench" \
  "HONCHO=$MOCK_PIPX_HOME/venvs/frappe-bench/bin/honcho" "PORTS=8000,9000,11000,13000" "LABEL=com.benchbar.runner-bench" \
  "MAX_STARTS=3" "WINDOW=600" "SITE=macdev" "WEB_PORT=8000" "CLI_VERSION=9.9.9" >"$runner"
chmod +x "$runner"
# no BENCHBAR_ variable is read at the top level of a runner: only inside the FL_TESTING block
if grep -E '^[A-Z_]+="\$\{BENCHBAR_' "$runner" "$ROOT/templates/share-run.sh.tmpl"; then fail "a BENCHBAR_ seam is read outside the FL_TESTING block"; fi
export BENCHBAR_STATE_LOG="$TMP_DIR/transitions.log" BENCHBAR_PING_EVERY=0 BENCHBAR_PING_TRIES=2
: >"$BENCHBAR_STATE_LOG"
FL_TESTING=1 "$runner" >/dev/null 2>&1 || true
[[ -s "$BENCHBAR_STATE_LOG" ]] || fail "under FL_TESTING=1 the runner did not write BENCHBAR_STATE_LOG"
: >"$BENCHBAR_STATE_LOG"
env -u FL_TESTING "$runner" >/dev/null 2>&1 &
RPID=$!
sleep 6
kill "$RPID" 2>/dev/null || true
wait "$RPID" 2>/dev/null || true
[[ ! -s "$BENCHBAR_STATE_LOG" ]] || fail "without FL_TESTING=1 the runner wrote BENCHBAR_STATE_LOG"
printf 'test-seam-gate: ok\n'
