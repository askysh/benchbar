#!/usr/bin/env bash
# benchbar mcp: the module compiles (py_compile) and its unit tests pass (tests/test_mcp_unit.py: the tool
# table and its side tables, validate, scrub, cap, tool_call and dispatch).
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# the compiled file goes to the test's own folder, never into the checkout
OUT="$(PYTHONPYCACHEPREFIX="$TMP_DIR/pycache" python3 -I -m py_compile "$ROOT/lib/frappe-local/mcp.py" "$ROOT/tests/test_mcp_unit.py" 2>&1)" || fail "py_compile: $OUT"
OUT="$(PYTHONPYCACHEPREFIX="$TMP_DIR/pycache" BENCHBAR_VERSION=0 python3 "$ROOT/tests/test_mcp_unit.py" 2>&1)" || fail "unit tests: $OUT"
assert_contains "$OUT" "OK"
echo "ok"
