#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/benchbar-test.XXXXXX")"
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

# ---- one fl_version_lt (CORE-16): the entry point (which also loads
# selfupdate.sh) and the phase scripts (version-policy.sh alone) give the same
# answer, and a dependency spec ignores a prerelease tag, as fl_dep_fits says
assert_eq "1" "$(cat "$ROOT"/lib/frappe-local/*.sh | grep -c '^fl_version_lt()')"
lt_as() { bash -c 'set -euo pipefail; SCRIPT_DIR="$1"; shift; for f in $1; do . "$SCRIPT_DIR/lib/frappe-local/$f.sh"; done; shift; "$@"' _ "$ROOT" "$@"; }
for libs in "ui run version-policy" "ui run version-policy selfupdate"; do
  lt_as "$libs" fl_version_lt 0.9.0-rc.1 0.9.0 || { printf 'a prerelease comes before its release (%s)\n' "$libs"; exit 1; }
  lt_as "$libs" fl_version_lt v0.5.8 0.6.0 || { printf 'v0.5.8 < 0.6.0 (%s)\n' "$libs"; exit 1; }
  lt_as "$libs" fl_version_lt 0.9.0 0.10.0 || { printf '0.9 < 0.10 (%s)\n' "$libs"; exit 1; }
  ! lt_as "$libs" fl_version_lt 0.6.0 0.6.0-beta.1 || { printf 'a release is newer than its prerelease (%s)\n' "$libs"; exit 1; }
  lt_as "$libs" fl_dep_fits ">=16.0.0-dev,<17.0.0-dev" 16.0.0-dev || { printf '16.0.0-dev fits >=16.0.0-dev (%s)\n' "$libs"; exit 1; }
  lt_as "$libs" fl_dep_fits ">=15.0.0,<16.0.0" 15.88.1 || { printf '15.88.1 fits 15.x (%s)\n' "$libs"; exit 1; }
  ! lt_as "$libs" fl_dep_fits ">=15.0.0,<16.0.0" 16.0.0-dev || { printf '16.0.0-dev does not fit <16.0.0 (%s)\n' "$libs"; exit 1; }
done

printf 'test-version-policy: ok\n'
