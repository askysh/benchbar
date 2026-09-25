#!/usr/bin/env bash
# Two benches on one Mac: each keeps its own profile, site and autostart,
# the default bench only changes on request, the shell block follows the
# default bench, and settings from before 0.4 still count.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

A="$HOME/frappe-bench"
B="$HOME/dev/v16-bench"
make_fake_bench "$A" macdev
make_fake_bench "$B" v16dev
mkdir -p "$B/apps/frappe/frappe"; printf '__version__ = "16.35.0"\n' >"$B/apps/frappe/frappe/__init__.py"
printf '127.0.0.1 macdev\n127.0.0.1 v16dev\n' >>"$FL_HOSTS_FILE"
bstate() { cat "$FL_STATE_DIR/benches/$1"-????????.env 2>/dev/null | sed -n "s/^$2=//p"; }
gstate() { sed -n "s/^$1=//p" "$FL_STATE_FILE"; }

# ---- settings from before 0.4: everything in state.env, for bench A
printf 'BENCH_DIR=%s\nSITE_NAME=macdev\nPROFILE=v15-lts\nAUTOSTART=off\nPIPX_BIN_DIR=%s\n' "$A" "$HOME/.local/bin" >"$FL_STATE_FILE"
run_fm doctor --bench-dir "$A"
assert_contains "$OUT" "profile  v15-lts"
snap="$(snapshot "$FL_STATE_DIR")"
run_fm doctor --bench-dir "$B"
assert_eq "$snap" "$(snapshot "$FL_STATE_DIR")" "(doctor never migrates state)"

# ---- the profile of a bench without state comes from its frappe version
assert_contains "$OUT" "profile  v16-lts"
assert_contains "$OUT" "site     v16dev"

# ---- service on A keeps its old settings (autostart off), now in its own file
run_fm service --yes --bench-dir "$A"
assert_eq "0" "$CODE" "$OUT"
grep -q '<key>RunAtLoad</key><false/>' "$HOME/Library/LaunchAgents/com.benchbar.frappe-bench.plist" || fail "A keeps autostart off"
assert_eq "off" "$(bstate frappe-bench AUTOSTART)"
assert_eq "" "$(gstate AUTOSTART)" "(moved out of state.env)"
assert_eq "$A" "$(gstate BENCH_DIR)"
grep -q 'opt/python@3.11/bin' "$HOME/.zshrc" || fail "shell block follows A (v15)"

# ---- a second bench: its own profile and site, A stays the default
run_fm service --yes --bench-dir "$B"
assert_eq "0" "$CODE" "$OUT"
assert_eq "$A" "$(gstate BENCH_DIR)" "(a second bench never takes over the default)"
assert_eq "v16-lts" "$(bstate v16-bench PROFILE)"
assert_eq "v16dev" "$(bstate v16-bench SITE_NAME)"
grep -q '<key>RunAtLoad</key><true/>' "$HOME/Library/LaunchAgents/com.benchbar.v16-bench.plist" || fail "B has its own autostart (on)"
grep -q 'opt/python@3.11/bin' "$HOME/.zshrc" || fail "the shell block still follows the default bench"
! grep -q 'opt/python@3.14/bin' "$HOME/.zshrc" || fail "B's profile must not reach the shell block"
run_fm list --json
assert_eq "$A" "$(printf '%s' "$OUT" | jget - 'd["default_bench"]')"
assert_eq "macdev v16dev" "$(printf '%s' "$OUT" | jget - '" ".join(b["site"] for b in d["benches"])')"

# ---- both doctors agree on the shell block: no flip flop
run_fm doctor --bench-dir "$A"; assert_contains "$OUT" "[OK] Shell helpers"
run_fm doctor --bench-dir "$B"; assert_contains "$OUT" "[OK] Shell helpers"
assert_contains "$OUT" "profile  v16-lts"

# ---- autostart is per bench
run_fm autostart off --bench-dir "$B"
assert_eq "off" "$(bstate v16-bench AUTOSTART)"
run_fm autostart on --bench-dir "$A"
assert_eq "on" "$(bstate frappe-bench AUTOSTART)"
assert_eq "off" "$(bstate v16-bench AUTOSTART)"

# ---- --make-default: dry run changes nothing, then B becomes the default
snap="$(snapshot "$FL_STATE_DIR" "$HOME/.zshrc")"
run_fm service --dry-run --make-default --bench-dir "$B"
assert_eq "$snap" "$(snapshot "$FL_STATE_DIR" "$HOME/.zshrc")" "(dry run)"
assert_contains "$OUT" "Shell helpers: helper block" "(the dry run shows the block change the real run makes)"
run_fm service --yes --make-default --bench-dir "$B"
assert_eq "0" "$CODE" "$OUT"
assert_eq "$B" "$(gstate BENCH_DIR)"
grep -q 'opt/python@3.14/bin' "$HOME/.zshrc" || fail "the shell block follows the new default (v16)"
run_fm doctor --bench-dir "$A"
assert_contains "$OUT" "profile  v15-lts"
assert_contains "$OUT" "[OK] Shell helpers"

# ---- same folder name, different paths: separate state files
D="$HOME/dev/frappe-bench"
make_fake_bench "$D" other
run_fm service --yes --bench-dir "$D" --profile v16-lts
run_fm doctor --bench-dir "$A"
assert_contains "$OUT" "profile  v15-lts"
assert_eq "2" "$(find "$FL_STATE_DIR/benches" -name 'frappe-bench-*.env' | wc -l | tr -d ' ')"

# ---- another spelling of the same path finds the same settings
run_fm doctor --bench-dir "$HOME/dev/./v16-bench"
assert_contains "$OUT" "profile  v16-lts"
# a plain <name>.env from the first 0.4 builds is read, then renamed on the next write
E="$HOME/dev/early"; make_fake_bench "$E" early
printf 'PROFILE=v16-lts\nAUTOSTART=off\n' >"$FL_STATE_DIR/benches/early.env"
prev_default="$(gstate BENCH_DIR)"
sed_inplace "s#^BENCH_DIR=.*#BENCH_DIR=${E}#" "$FL_STATE_FILE"
run_fm doctor --bench-dir "$E"
assert_contains "$OUT" "profile  v16-lts"
run_fm service --yes --bench-dir "$E"
assert_no_file "$FL_STATE_DIR/benches/early.env"
assert_eq "off" "$(bstate early AUTOSTART)"
sed_inplace "s#^BENCH_DIR=.*#BENCH_DIR=${prev_default}#" "$FL_STATE_FILE"

# ---- a symlinked spelling is the same bench: same state file, no port clash with itself
ln -s "$B" "$HOME/v16link"
run_fm doctor --bench-dir "$HOME/v16link"
assert_contains "$OUT" "profile  v16-lts"
assert_not_contains "$OUT" "v16-bench: 8000" "(a bench never clashes with its own symlink)"
assert_not_contains "$OUT" "v16link"
[[ -z "$(find "$FL_STATE_DIR/benches" -name 'v16link-*')" ]] || fail "a symlink must not get its own state file"

# ---- a plain <name>.env belongs to the default bench only, never to a namesake
printf 'PROFILE=v16-lts\n' >"$FL_STATE_DIR/benches/v16-bench.env"
N="$HOME/other/v16-bench"; make_fake_bench "$N" namesake
run_fm doctor --bench-dir "$N"
assert_contains "$OUT" "profile  v15-lts"
run_fm service --yes --bench-dir "$N"
assert_file "$FL_STATE_DIR/benches/v16-bench.env" "(a namesake never claims the old file)"
rm -f "$FL_STATE_DIR/benches/v16-bench.env"

# ---- a registered non-default bench with a unique name claims its plain <name>.env too
U="$HOME/dev/unique"; make_fake_bench "$U" unique
printf 'AUTOSTART=off\n' >"$FL_STATE_DIR/benches/unique.env"
run_fm service --yes --bench-dir "$U"
assert_no_file "$FL_STATE_DIR/benches/unique.env"
assert_eq "off" "$(bstate unique AUTOSTART)"

# ---- phase 00 never rewrites an existing block to its own profile
before="$(cat "$HOME/.zshrc")"
set +e; OUT="$("$ROOT/00-mac-system-deps.sh" --yes --profile v15-lts 2>&1)"; set -e
assert_eq "$before" "$(cat "$HOME/.zshrc")" "(00 leaves the block to service and repair)"

printf 'test-multi-bench: ok\n'
