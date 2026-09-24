#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/frappe-local-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/git" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GIT_CALL_LOG:?}"
case "$*" in
  *missing*) exit 2 ;;
  *version-\**) printf 'abc refs/heads/version-15\nabc refs/heads/version-16\n'; exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$TMP_DIR/bin/git"
export PATH="$TMP_DIR/bin:$PATH"
export GIT_CALL_LOG="$TMP_DIR/git.log"
export FL_STATE_DIR="$TMP_DIR/state"
: >"$GIT_CALL_LOG"

. "$ROOT/lib/frappe-local/ui.sh"
. "$ROOT/lib/frappe-local/run.sh"
. "$ROOT/lib/frappe-local/version-policy.sh"

assert_eq() {
  [[ "$1" == "$2" ]] || { printf 'Expected [%s], got [%s]\n' "$1" "$2"; exit 1; }
}

assert_fails() {
  if ( "$@" ) >/dev/null 2>&1; then
    printf 'Expected failure: %s\n' "$*"
    exit 1
  fi
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) printf 'Expected [%s] to contain [%s]\n' "$1" "$2"; exit 1 ;;
  esac
}

assert_eq "v15-lts" "$(fl_default_profile)"
fl_load_profile v15-lts
assert_eq "version-15" "$FL_FRAPPE_BRANCH"
assert_eq "python@3.11" "$FL_PYTHON_FORMULA"
assert_fails fl_load_profile does-not-exist
assert_fails fl_validate_custom_commit "version-15"
fl_validate_custom_commit "5f86b1b"

fl_resolve_selected_apps v15-lts minimal "" 0
assert_eq "erpnext" "${FL_SELECTED_APPS[*]}"
assert_contains "${FL_INSTALL_SPECS[0]}" "erpnext|version-15|"

fl_resolve_selected_apps v15-lts common "" 0
assert_eq "erpnext hrms payments" "${FL_SELECTED_APPS[*]}"

fl_resolve_selected_apps v15-lts extended "" 0
assert_eq "erpnext hrms payments crm helpdesk insights" "${FL_SELECTED_APPS[*]}"

fl_resolve_selected_apps v15-lts common "erpnext hrms" 0
assert_eq "erpnext hrms" "${FL_SELECTED_APPS[*]}"

fl_repo_ref_exists https://example.invalid/repo version-15
assert_fails fl_repo_ref_exists https://example.invalid/repo missing

: >"$GIT_CALL_LOG"
OFFLINE=1 fl_check_updates
if [[ -s "$GIT_CALL_LOG" ]]; then
  printf 'Expected offline update check not to call git\n'
  exit 1
fi

printf 'test-version-policy: ok\n'
