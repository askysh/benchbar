#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/frappe-local-bench-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/bench" <<'SH'
#!/usr/bin/env bash
printf 'bench %s\n' "$*" >>"${BENCH_LOG:?}"
if [[ "$1" == "init" ]]; then
  mkdir -p "$2/apps/frappe" "$2/env/bin" "$2/sites"
  touch "$2/sites/apps.txt"
  # new-site runs through the bench's python with its passwords on stdin
  printf '#!/usr/bin/env bash\ncat >/dev/null\nshift 4\nexec bench "$@"\n' >"$2/env/bin/python"
  chmod +x "$2/env/bin/python"
  exit 0
fi
if [[ "$1" == "get-app" ]]; then
  app="${@: -1}"
  app="${app##*/}"
  app="${app%.git}"
  mkdir -p "apps/$app"
  exit 0
fi
if [[ "$1" == "new-site" ]]; then
  mkdir -p "sites/$2"
  touch "sites/$2/installed_apps"
  exit 0
fi
if [[ "$1" == "--site" && "$3" == "list-apps" ]]; then
  [[ -f "sites/$2/installed_apps" ]] && cat "sites/$2/installed_apps"
  exit 0
fi
if [[ "$1" == "--site" && "$3" == "install-app" ]]; then
  mkdir -p "sites/$2"
  printf '%s 1.0.0\n' "$4" >>"sites/$2/installed_apps"
  exit 0
fi
if [[ "$1" == "--site" && "$3" == "doctor" ]]; then
  exit 0
fi
if [[ "$1" == "use" ]]; then
  exit 0
fi
exit 0
SH
chmod +x "$TMP_DIR/bin/bench"
export PATH="$TMP_DIR/bin:$PATH"
export BENCH_LOG="$TMP_DIR/bench.log"
: >"$BENCH_LOG"

. "$ROOT/lib/frappe-local/ui.sh"
. "$ROOT/lib/frappe-local/run.sh"
. "$ROOT/lib/frappe-local/state.sh"
. "$ROOT/lib/frappe-local/platform.sh"
. "$ROOT/lib/frappe-local/version-policy.sh"
. "$ROOT/lib/frappe-local/bench.sh"

assert_eq() {
  [[ "$1" == "$2" ]] || { printf 'Expected [%s], got [%s]\n' "$1" "$2"; exit 1; }
}

assert_fails() {
  if ( "$@" ) >/dev/null 2>&1; then
    printf 'Expected failure: %s\n' "$*"
    exit 1
  fi
}

FL_STATE_DIR="$TMP_DIR/.benchbar"
FL_STATE_FILE="$FL_STATE_DIR/state.env"
fl_state_init

BENCH_DIR="$TMP_DIR/frappe-bench"
fl_bench_init_if_needed "$BENCH_DIR" version-15 /usr/bin/python3 0
[[ -d "$BENCH_DIR/apps/frappe" && -d "$BENCH_DIR/env" && -f "$BENCH_DIR/sites/apps.txt" ]]

before="$(wc -l <"$BENCH_LOG")"
fl_bench_init_if_needed "$BENCH_DIR" version-15 /usr/bin/python3 0
after="$(wc -l <"$BENCH_LOG")"
assert_eq "$before" "$after"

INCOMPLETE="$TMP_DIR/incomplete-bench"
mkdir -p "$INCOMPLETE/apps"
assert_fails fl_bench_init_if_needed "$INCOMPLETE" version-15 /usr/bin/python3 0
fl_bench_init_if_needed "$INCOMPLETE" version-15 /usr/bin/python3 1
[[ -d "$INCOMPLETE/apps/frappe" ]]

fl_get_app_if_needed "$BENCH_DIR" hrms version-15 "" "" 0
[[ -d "$BENCH_DIR/apps/hrms" ]]

fl_new_site_if_needed "$BENCH_DIR" macdev rootpw adminpw
[[ -d "$BENCH_DIR/sites/macdev" ]]

fl_install_app_if_needed "$BENCH_DIR" macdev hrms
installed="$(cd "$BENCH_DIR" && bench --site macdev list-apps)"
case "$installed" in
  *hrms*) ;;
  *) printf 'Expected hrms to be installed\n'; exit 1 ;;
esac

fl_verify_site_health "$BENCH_DIR" macdev

printf 'test-bench-flow: ok\n'
