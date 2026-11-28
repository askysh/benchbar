#!/usr/bin/env bash
# What the service files cost a command (issue 137). Every rendered file is one hash (a program: shasum,
# or sha256sum on Linux), and a render is most of a command's time on a bench that is set up: a runner of
# 288 lines, the agent's plist, the shell helpers, the Procfile and its two listen files. A command renders
# only the files it reads:
#   - status, list, logs, down and the site and app lists read none: no hash at all;
#   - up and restart read the Procfile and the listen files (is the 0.9.0 Procfile in place, issue 188):
#     3 hashes, not the 6 of the whole set;
#   - what is written is the same bytes as before, and a command that needs no file leaves them alone.
# The hash program is counted by logging shims that run the real one first on PATH, as in test-status-cost.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

SHIMS="$TMP_DIR/shims"
mkdir -p "$SHIMS"
# the real programs, never a tests/mocks one (the sha256sum mock stands in on hosts without it)
real_of() { local p; while IFS= read -r p; do case "$p" in "$ROOT"/tests/mocks/*|"$SHIMS"/*) ;; *) printf '%s' "$p"; return 0 ;; esac; done < <(type -ap "$1" 2>/dev/null); return 1; }
REAL_SHASUM="$(real_of shasum || true)"
REAL_SHA256SUM="$(real_of sha256sum || true)"
[[ -n "$REAL_SHASUM$REAL_SHA256SUM" ]] || fail "no shasum and no sha256sum on this machine"
if [[ -n "$REAL_SHASUM" ]]; then
  cat >"$SHIMS/shasum" <<SHIM
#!/bin/bash
printf 'exec shasum\n' >>"\$MOCK_LOG"
exec "$REAL_SHASUM" "\$@"
SHIM
fi
if [[ -n "$REAL_SHA256SUM" ]]; then
  cat >"$SHIMS/sha256sum" <<SHIM
#!/bin/bash
printf 'exec sha256sum\n' >>"\$MOCK_LOG"
exec "$REAL_SHA256SUM" "\$@"
SHIM
fi
chmod +x "$SHIMS"/*

# hashes: how many content hashes the last run started
hashes() { grep -c -E '^exec (shasum|sha256sum)$' "$MOCK_LOG" || true; }
# hashed ARGS...: run benchbar with the logging shims first; the count lands in HASHES, the run in OUT and CODE
hashed() {
  local saved="$PATH"
  reset_calls
  PATH="$SHIMS:$PATH"
  run_fm "$@"
  PATH="$saved"
  HASHES="$(hashes)"
}
# at_most MAX WHAT ARGS...: the run hashed at most MAX files
at_most() {
  local max="$1" what="$2"
  shift 2
  hashed "$@"
  printf '%s: %s hashes, budget %s\n' "$what" "$HASHES" "$max"
  [[ "$HASHES" -le "$max" ]] || fail "$what: $HASHES files hashed, budget $max"$'\n'"$OUT"
}

BENCH="$HOME/work/a/frappe-bench"
make_fake_bench "$BENCH" macdev
mkdir -p "$BENCH/sites/two.localhost"
printf '{}\n' >"$BENCH/sites/two.localhost/site_config.json"
printf '127.0.0.1 macdev two.localhost\n' >>"$FL_HOSTS_FILE"
run_fm register "$BENCH"
assert_eq "0" "$CODE" "$OUT"
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
for i in $(seq 1 20); do printf '10:00:%02d web.1 | line %s\n' "$i" "$i"; done >"$BENCH/logs/bench.log"
procfile="$BENCH/Procfile.lean"
listen_dir="$BENCH/config/benchbar-listen"
runner="$BENCH/benchbar-run.sh"
plist="$HOME/Library/LaunchAgents/com.benchbar.frappe-bench.plist"
for f in "$procfile" "$listen_dir/sitecustomize.py" "$listen_dir/socketio.js" "$runner" "$plist"; do assert_file "$f"; done

# ---- the reads render nothing
at_most 0 "status --json" status --json --bench-dir "$BENCH"
at_most 0 "list --json" list --json
at_most 0 "logs --no-follow" logs --no-follow --bench-dir "$BENCH"
at_most 0 "down --dry-run" down --dry-run --bench-dir "$BENCH"
at_most 0 "site list --json" site list --json --bench-dir "$BENCH"
at_most 0 "app list --json" app list --json --bench-dir "$BENCH"

# ---- up and restart read the Procfile and the two listen files, not the runner, the plist and the helpers
snap_before="$(snapshot "$procfile" "$listen_dir" "$runner" "$plist")"
at_most 3 "up --dry-run" up --dry-run --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "$snap_before" "$(snapshot "$procfile" "$listen_dir" "$runner" "$plist")" "(up --dry-run on a current bench writes no service file)"
MOCK_KICKSTART_PING=200 at_most 3 "up" up --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "$snap_before" "$(snapshot "$procfile" "$listen_dir" "$runner" "$plist")" "(up on a current bench writes no service file)"
MOCK_KICKSTART_PING=200 at_most 3 "restart" restart --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "$snap_before" "$(snapshot "$procfile" "$listen_dir" "$runner" "$plist")" "(restart on a current bench writes no service file)"

# ---- Linux: the hash is sha256sum, not the Perl script shasum (20 ms a start, 6 starts a render of everything)
if [[ "$OSTYPE" == linux* && -n "$REAL_SHA256SUM" ]]; then
  hashed up --dry-run --bench-dir "$BENCH"
  assert_calls_not_contain '^exec shasum$' "(up --dry-run hashes with sha256sum on Linux)"
fi

# ---- what is written is what the whole render wrote: the bytes of Procfile.lean and the listen files
mkdir -p "$TMP_DIR/ref"
cp "$procfile" "$TMP_DIR/ref/Procfile.lean"
cp "$listen_dir/sitecustomize.py" "$TMP_DIR/ref/sitecustomize.py"
cp "$listen_dir/socketio.js" "$TMP_DIR/ref/socketio.js"
cp "$runner" "$TMP_DIR/ref/runner"
cp "$plist" "$TMP_DIR/ref/plist"
runner_snap="$(snapshot "$runner" "$plist")"
# a bench of before 0.9.0: another Procfile.lean of ours, no listen files
sed 's/^#@version 2$/#@version 1/; s/Procfile.lean v2 /Procfile.lean v1 /' "$TMP_DIR/ref/Procfile.lean" >"$procfile"
rm -rf "$listen_dir"
MOCK_KICKSTART_PING=200 at_most 3 "up on an old Procfile.lean" up --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
cmp "$procfile" "$TMP_DIR/ref/Procfile.lean" || fail "up wrote another Procfile.lean than the whole render does"
cmp "$listen_dir/sitecustomize.py" "$TMP_DIR/ref/sitecustomize.py" || fail "up wrote another sitecustomize.py than the whole render does"
cmp "$listen_dir/socketio.js" "$TMP_DIR/ref/socketio.js" || fail "up wrote another socketio.js than the whole render does"
cmp "$runner" "$TMP_DIR/ref/runner" || fail "up changed the runner"
cmp "$plist" "$TMP_DIR/ref/plist" || fail "up changed the plist"
assert_eq "$runner_snap" "$(snapshot "$runner" "$plist")" "(up renders the runner and the plist for nobody: they are not written)"

# ---- the whole set is still rendered where a command reads it: doctor hashes all six, and finds them current
hashed doctor --bench-dir "$BENCH"
[[ "$HASHES" -ge 6 ]] || fail "doctor hashed $HASHES files, the six service files are expected"
assert_contains "$OUT" "[OK] Procfile.lean: Procfile.lean and its listen files are current"

printf 'test-render-cost: ok\n'
