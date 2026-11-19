#!/usr/bin/env bash
# benchbar lan-guard on a platform other than macOS: the root steps of the guard name pf, launchd and
# macOS paths, so no subcommand may reach one from Linux. A refusal changes nothing and asks for no sudo.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
use_linux
# the lab's platform list is not under test here (tests/test-labs.sh has it)
export BENCHBAR_LABS=lan-rooms FL_LABS_ANY_PLATFORM=1

BENCH="$HOME/frappe-bench"
make_fake_bench "$BENCH" linuxdev.localhost
lg() { run_fm lan-guard "$@" --bench-dir "$BENCH"; }

# ---------------------------------------------------------------- every subcommand refuses, nothing runs
for sub in install remove allow-node status; do
  reset_calls
  lg "$sub" --yes </dev/null
  assert_eq 1 "$CODE" "($sub) $OUT"
  assert_contains "$OUT" "benchbar lan-guard ${sub} is not available on linux" "($sub)"
  assert_contains "$OUT" "Nothing was changed"
  assert_calls_not_contain '^(sudo|nft|systemctl|pfctl|launchctl|osascript|socketfilterfw)' "($sub)"
done

printf 'test-lan-guard-linux: ok\n'
