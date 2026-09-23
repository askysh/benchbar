#!/usr/bin/env bash
# Marker block handling in shell rc files.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
. "$ROOT/lib/frappe-local/ui.sh"
. "$ROOT/lib/frappe-local/run.sh"
. "$ROOT/lib/frappe-local/templates.sh"
. "$ROOT/lib/frappe-local/shellrc.sh"

rc="$TMP_DIR/zshrc"
printf 'export A=1\n' >"$rc"
c1="$(fl_template_render shell-helpers "PROFILE_EXPORTS=export P=1" "BENCHBAR=/x/benchbar")"
c2="$(fl_template_render shell-helpers "PROFILE_EXPORTS=export P=2" "BENCHBAR=/x/benchbar")"

assert_eq "missing" "$(fl_rc_block_status "$rc" "$c1")"
fl_rc_block_write "$rc" "$c1"
assert_eq "present" "$(fl_rc_block_state "$rc")"
assert_eq "current" "$(fl_rc_block_status "$rc" "$c1")"
assert_eq "outdated" "$(fl_rc_block_status "$rc" "$c2")"
assert_eq "1" "$(grep -c -x -F "$FL_RC_START" "$rc")"
grep -q '^export A=1$' "$rc" || fail "user content must survive"

# replace in place: still exactly one block, new content, user content intact
printf 'export Z=9\n' >>"$rc"
fl_rc_block_write "$rc" "$c2"
assert_eq "1" "$(grep -c -x -F "$FL_RC_START" "$rc")"
assert_eq "1" "$(grep -c -x -F "$FL_RC_END" "$rc")"
grep -q '^export P=2$' "$rc" || fail "block content must be replaced"
! grep -q '^export P=1$' "$rc" || fail "old block content must be gone"
grep -q '^export Z=9$' "$rc" || fail "content after the block must survive"
assert_eq "current" "$(fl_rc_block_status "$rc" "$c2")"
[[ -n "$(find "$FL_BACKUP_ROOT" -type f | head -n1)" ]] || fail "rc file must be backed up before a write"

# the block is valid zsh and bash
fl_rc_block_extract "$rc" >"$TMP_DIR/block.sh"
bash -n "$TMP_DIR/block.sh"
command -v zsh >/dev/null 2>&1 && zsh -n "$TMP_DIR/block.sh"

# broken markers: append a fresh block and warn, never edit in place
printf 'export A=1\n%s\nbroken\n# <<< frappe-mac <\n' "$FL_RC_START" >"$rc"
assert_eq "broken" "$(fl_rc_block_state "$rc")"
out="$(fl_rc_block_write "$rc" "$c1")"
assert_contains "$out" "[WARN]"
grep -q '^broken$' "$rc" || fail "malformed block must be left alone"
assert_eq "2" "$(grep -c -x -F "$FL_RC_START" "$rc")"

# legacy blocks from older setups are reported
printf '# >>> frappe-bench helpers >>>\nbenchup() { :; }\n# <<< frappe-bench helpers <\n' >>"$rc"
assert_eq "frappe-bench helpers" "$(fl_rc_legacy_blocks "$rc")"

# remove
printf 'export A=1\n' >"$rc"
fl_rc_block_write "$rc" "$c1"
fl_rc_block_remove "$rc"
assert_eq "missing" "$(fl_rc_block_state "$rc")"
grep -q '^export A=1$' "$rc" || fail "user content must survive removal"

# dry-run writes nothing
printf 'export A=1\n' >"$rc"
FL_DRY_RUN=1 fl_rc_block_write "$rc" "$c1" >/dev/null
assert_eq "missing" "$(fl_rc_block_state "$rc")"

printf 'test-shellrc: ok\n'
