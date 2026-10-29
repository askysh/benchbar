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
  printf '#!/usr/bin/env bash\ncat >/dev/null\nshift 4\ncd .. && exec bench "$@"\n' >"$2/env/bin/python"
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

. "$ROOT/lib/frappe-local/install-kind.sh"
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

# ---- commit pins (install --frappe-commit, --erpnext-commit, a profile's pins)
G=(git -c user.name=t -c user.email=t@example.com)
PINNED="$BENCH_DIR/apps/pinned"
mkdir -p "$PINNED"
"${G[@]}" -C "$PINNED" init -q -b main
printf 'one\n' >"$PINNED/f"; "${G[@]}" -C "$PINNED" add f; "${G[@]}" -C "$PINNED" commit -q -m one
FIRST="$("${G[@]}" -C "$PINNED" rev-parse HEAD)"
printf 'two\n' >"$PINNED/f"; "${G[@]}" -C "$PINNED" commit -q -a -m two
SECOND="$("${G[@]}" -C "$PINNED" rev-parse HEAD)"
: >"$BENCH_LOG"
# a commit the clone reaches is checked out
assert_eq "0" "$FL_PINS_APPLIED"
fl_get_app_if_needed "$BENCH_DIR" pinned main "" "${FIRST:0:10}" 1 >/dev/null
assert_eq "$FIRST" "$("${G[@]}" -C "$PINNED" rev-parse HEAD)"
assert_eq "1" "$FL_PINS_APPLIED"
# a commit it does not reach stops the run before anything is built, the clone stays where it was
"${G[@]}" -C "$PINNED" checkout -q "$SECOND"
out="$( (fl_get_app_if_needed "$BENCH_DIR" pinned main "" deadbeefdeadbeef 1) 2>&1 || true)"
case "$out" in *"The pinned commit deadbeefdeadbeef of pinned is not in its clone (branch main) and its remote did not hand it out; nothing was built."*) ;; *) printf 'Expected the unreachable pin to be refused, got:\n%s\n' "$out"; exit 1 ;; esac
assert_fails fl_get_app_if_needed "$BENCH_DIR" pinned main "" deadbeefdeadbeef 1
assert_eq "$SECOND" "$("${G[@]}" -C "$PINNED" rev-parse HEAD)"
if grep -q -E '^bench (build|setup)' "$BENCH_LOG"; then printf 'Expected no build after a refused pin\n'; exit 1; fi
# a pin that is already checked out changes nothing, and does not ask for a rebuild
FL_PINS_APPLIED=0
"${G[@]}" -C "$PINNED" checkout -q "$FIRST"
: >"$BENCH_LOG"
fl_get_app_if_needed "$BENCH_DIR" pinned main "" "$FIRST" 1 >/dev/null
assert_eq "0" "$FL_PINS_APPLIED"
assert_eq "$FIRST" "$("${G[@]}" -C "$PINNED" rev-parse HEAD)"
"${G[@]}" -C "$PINNED" checkout -q "$SECOND"
# a fresh clone with a pin is fetched without the first build (the caller builds once, after the checkout)
fl_get_app_if_needed "$BENCH_DIR" freshpin main "" "$FIRST" 1 >/dev/null
grep -q -- '^bench get-app --branch main --skip-assets freshpin$' "$BENCH_LOG" || { printf 'Expected get-app --skip-assets for a pinned app\n'; cat "$BENCH_LOG"; exit 1; }
fl_get_app_if_needed "$BENCH_DIR" unpinned main "" "" 0 >/dev/null
grep -q -- '^bench get-app --branch main unpinned$' "$BENCH_LOG" || { printf 'Expected a plain get-app for an unpinned app\n'; cat "$BENCH_LOG"; exit 1; }
# and leaves a marker, so a run that stops before its build is noticed by the next one
[[ -f "$(fl_needs_build_marker "$BENCH_DIR")" ]] || { printf 'Expected a needs-build marker after a get-app without assets\n'; exit 1; }
rm -f "$(fl_needs_build_marker "$BENCH_DIR")"
fl_get_app_if_needed "$BENCH_DIR" freshpin main "" "$FIRST" 1 >/dev/null
[[ ! -f "$(fl_needs_build_marker "$BENCH_DIR")" ]] || { printf 'Expected no marker for an app that was there already\n'; exit 1; }
# bench init for a frappe pin builds nothing until the pin is checked out
PINBENCH="$TMP_DIR/pin-bench"
fl_bench_init_if_needed "$PINBENCH" version-15 /usr/bin/python3 0 1 >/dev/null
grep -q -- "^bench init ${PINBENCH} .* --skip-assets\$" "$BENCH_LOG" || { printf 'Expected bench init --skip-assets\n'; cat "$BENCH_LOG"; exit 1; }
[[ -f "$(fl_needs_build_marker "$PINBENCH")" ]] || { printf 'Expected a needs-build marker after bench init --skip-assets\n'; exit 1; }
# a commit on another branch than a single branch shallow clone fetched: the remote hands it out
REMOTE="$TMP_DIR/remote-repo"
mkdir -p "$REMOTE"
"${G[@]}" -C "$REMOTE" init -q -b main
printf 'a\n' >"$REMOTE/f"; "${G[@]}" -C "$REMOTE" add f; "${G[@]}" -C "$REMOTE" commit -q -m a
"${G[@]}" -C "$REMOTE" checkout -q -b other
printf 'b\n' >"$REMOTE/f"; "${G[@]}" -C "$REMOTE" commit -q -a -m b
OTHER_SHA="$("${G[@]}" -C "$REMOTE" rev-parse HEAD)"
"${G[@]}" -C "$REMOTE" checkout -q main
git clone -q --depth 1 --single-branch --branch main "file://$REMOTE" "$TMP_DIR/shallow-clone"
fl_commit_present "$TMP_DIR/shallow-clone" "$OTHER_SHA" && { printf 'The shallow clone should not have the other branch\n'; exit 1; }
fl_commit_reach "$TMP_DIR/shallow-clone" "$OTHER_SHA" || { printf 'Expected the commit to be fetched by its hash\n'; exit 1; }
# the same repo checked through fl_commit_reach: reachable, not reachable
fl_commit_reach "$PINNED" "$FIRST" || { printf 'Expected the first commit to be reachable\n'; exit 1; }
assert_fails fl_commit_reach "$PINNED" 0123456789abcdef0123456789abcdef01234567

printf 'test-bench-flow: ok\n'
