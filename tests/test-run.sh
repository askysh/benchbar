#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/frappe-local-run-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

. "$ROOT/lib/frappe-local/ui.sh"
. "$ROOT/lib/frappe-local/run.sh"

assert_status() {
  local expected="$1"
  shift
  set +e
  "$@" >/dev/null 2>&1
  actual="$?"
  set -e
  if [[ "$actual" != "$expected" ]]; then
    printf 'Expected exit %s, got %s: %s\n' "$expected" "$actual" "$*"
    exit 1
  fi
}

printf '#!/usr/bin/env bash\nsleep 2\n' >"$TMP_DIR/slow"
chmod +x "$TMP_DIR/slow"

fl_run_with_timeout 0 "true command" true
assert_status 124 fl_run_with_timeout 1 "slow command" "$TMP_DIR/slow"

ps() {
  printf 'T\n'
}
assert_status 125 fl_run_with_timeout 5 "stopped command" "$TMP_DIR/slow"

# fl_on_error: exit 2 is reserved for "MariaDB root password unknown"; a
# command that happens to fail with 2 ends the run with 1
set +e
out="$(bash -c '. "$0/lib/frappe-local/ui.sh"; . "$0/lib/frappe-local/run.sh"; set -e; trap fl_on_error ERR; FL_LAST_COMMAND="grep pattern file"; bash -c "exit 2"' "$ROOT" 2>&1)"
code=$?
set -e
[[ "$code" == "1" ]] || { printf 'Expected exit 1 for an incidental exit 2, got %s: %s\n' "$code" "$out"; exit 1; }
case "$out" in *"Last command failed with exit code 1"*) ;; *) printf 'Expected the mapped code in the message: %s\n' "$out"; exit 1 ;; esac
set +e
out="$(bash -c '. "$0/lib/frappe-local/ui.sh"; . "$0/lib/frappe-local/run.sh"; set -e; trap fl_on_error ERR; FL_LAST_COMMAND="x"; (exit 7)' "$ROOT" 2>&1)"
code=$?
set -e
[[ "$code" == "7" ]] || { printf 'Expected exit 7 to pass through, got %s\n' "$code"; exit 1; }

printf 'test-run: ok\n'
