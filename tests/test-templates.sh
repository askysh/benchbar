#!/usr/bin/env bash
# Template rendering, hash headers, current/outdated/foreign detection, backups.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
. "$ROOT/lib/frappe-local/ui.sh"
. "$ROOT/lib/frappe-local/run.sh"
. "$ROOT/lib/frappe-local/templates.sh"

r1="$(fl_template_render Procfile.lean WEB_PORT=8000)"
r2="$(fl_template_render Procfile.lean WEB_PORT=8000)"
r3="$(fl_template_render Procfile.lean WEB_PORT=8001)"
assert_eq "$r1" "$r2" "(render is deterministic)"
assert_contains "$r1" "benchbar-template: Procfile.lean v1 "
assert_contains "$r1" "web: bench serve --port 8000"
assert_not_contains "$r1" "#@version"
assert_not_contains "$r1" "__HEADER__"
[[ "$(fl_template_header_of "$r1")" != "$(fl_template_header_of "$r3")" ]] || fail "hash must change with inputs"

target="$TMP_DIR/Procfile.lean"
assert_eq "missing" "$(fl_template_status "$target" "$r1")"
fl_template_apply "$target" "$r1" 644
assert_eq "1" "$FL_TEMPLATE_CHANGED"
assert_eq "current" "$(fl_template_status "$target" "$r1")"
assert_eq "outdated" "$(fl_template_status "$target" "$r3")"

# a file written before 0.3.0 says frappe-mac-template: the word alone is
# not a change, so nothing (like a MariaDB drop-in) is rewritten for it
old_copy="$TMP_DIR/old-Procfile.lean"
printf '%s' "${r1/benchbar-template:/frappe-mac-template:}" >"$old_copy"
grep -q 'frappe-mac-template: Procfile.lean v1 ' "$old_copy" || fail "fixture must carry the old word"
assert_eq "current" "$(fl_template_status "$old_copy" "$r1")"
assert_eq "outdated" "$(fl_template_status "$old_copy" "$r3")"

# unchanged apply writes nothing
before="$(mtime_of "$target")"
sleep 1
fl_template_apply "$target" "$r1" 644
assert_eq "0" "$FL_TEMPLATE_CHANGED"
assert_eq "$before" "$(mtime_of "$target")" "(no rewrite when current)"

# outdated apply backs up the old copy first
fl_template_apply "$target" "$r3" 644
assert_eq "1" "$FL_TEMPLATE_CHANGED"
[[ -n "$(find "$FL_BACKUP_ROOT" -type f -name '*Procfile.lean' | head -n1)" ]] || fail "backup of the old Procfile.lean expected"
assert_eq "current" "$(fl_template_status "$target" "$r3")"

# a user's own file is foreign and is backed up before replacement
printf 'web: my own thing\n' >"$TMP_DIR/foreign"
assert_eq "foreign" "$(fl_template_status "$TMP_DIR/foreign" "$r1")"
out="$(fl_template_apply "$TMP_DIR/foreign" "$r1" 644)"
assert_contains "$out" "[WARN]"
grep -q 'my own thing' "$FL_BACKUP_ROOT"/*/*foreign || fail "foreign file must be backed up"

# dry-run changes nothing
FL_DRY_RUN=1
out="$(fl_template_apply "$TMP_DIR/dry" "$r1" 644)"
assert_contains "$out" "dry-run: would write"
assert_no_file "$TMP_DIR/dry"
out="$(fl_move_aside "$target" broken)"
assert_file "$target"
FL_DRY_RUN=0

# move aside keeps the original content under a new name
fl_move_aside "$target" broken
assert_no_file "$target"
[[ -n "$(ls "$TMP_DIR"/Procfile.lean.broken.* 2>/dev/null)" ]] || fail "moved-aside copy expected"

printf 'test-templates: ok\n'
