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

# the runner's CLI_VERSION is unhashed: an upgrade alone does not make every
# runner outdated, while the version still lands in the file (state.json)
runner_with() {
  fl_template_render bench-run.sh "BENCH_DIR=/b" "BENCH_RE=/b" "BENCH_NAME=b" "HONCHO=/h" "PORTS=8000" "SITE=s" \
    "WEB_PORT=$2" "CLI_VERSION=$1" "LABEL=com.benchbar.b" "MAX_STARTS=3" "WINDOW=600"
}
ra="$(runner_with 0.7.0 8000)"; rb="$(runner_with 0.7.1 8000)"; rc="$(runner_with 0.7.0 8001)"
assert_eq "$(fl_template_header_of "$ra")" "$(fl_template_header_of "$rb")" "(a new CLI version alone keeps the runner current)"
[[ "$(fl_template_header_of "$ra")" != "$(fl_template_header_of "$rc")" ]] || fail "another input must still change the runner's hash"
assert_contains "$ra" '"cli_version":"0.7.0"'
assert_contains "$rb" '"cli_version":"0.7.1"'
assert_not_contains "$ra" "#@unhashed"
assert_not_contains "$ra" "__CLI_VERSION__"

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

# the share job: its plist and runner carry the header; a change to either template makes the copy outdated
share_plist() {
  fl_template_render share.plist "LABEL=com.benchbar-share.gateway" "APP_BUNDLE_ID=com.akashmishra.benchbar" "RUNNER=/s/share-run.sh" \
    "SHARE_DIR=/s" "PATH=/usr/bin:/bin" "LOG=/s/share.log"
}
share_runner() {
  fl_template_render share-run.sh "SHARE_DIR=/s" "SOCK=/s/control.sock" "BENCH=/b" "SHARE_SITE=share.localhost" "WEB_PORT=8001" \
    "GATEWAY_PORT=${1:-8443}" "PYTHON=/b/env/bin/python" "LIB=/l" "NODE=/n/node" "BENCHBAR=/x/benchbar" "DNS_SD=/usr/bin/dns-sd" \
    "CAFFEINATE=/usr/bin/caffeinate" "LSOF=/usr/sbin/lsof" "CURL=/usr/bin/curl" "WIPE_SECS=8" "LISTEN_SECS=60" "SOCK_SECS=15" \
    "WARM_SECS=30" "SESSIONS_PY=print(1)" \
    "CONTROL_JS=1;" "SITE_LABEL=macdev" "ROOM_LABEL=Lab"
}
sp="$(share_plist)"; sr="$(share_runner)"
assert_contains "$sp" "benchbar-template: share.plist v1 "
assert_contains "$sr" "benchbar-template: share-run.sh v5 "
assert_not_contains "$sr" "__" "(every value is filled in)"
assert_contains "$(share_runner 9443)" "GATEWAY_PORT=9443" "(Bonjour announces the gateway's port, not a literal)"
assert_not_contains "$(sed -n '/^start_dns()/,/^}/p' "$ROOT/templates/share-run.sh.tmpl")" "8443"
assert_contains "$sp" "<key>RunAtLoad</key><false/>"
assert_contains "$sp" "<key>KeepAlive</key><false/>"
assert_contains "$sp" "<key>Umask</key><integer>63</integer>" "(decimal 63 is octal 077: a plist integer is decimal)"
assert_not_contains "$sp" "__"; assert_not_contains "$sr" "__HEADER__"
fl_template_apply "$TMP_DIR/job.plist" "$sp" 600; fl_template_apply "$TMP_DIR/share-run.sh" "$sr" 700
assert_eq "current current" "$(fl_template_status "$TMP_DIR/job.plist" "$sp") $(fl_template_status "$TMP_DIR/share-run.sh" "$sr")"
mkdir -p "$TMP_DIR/tmpl"; cp "$ROOT"/templates/*.tmpl "$TMP_DIR/tmpl/"
printf '# a change\n' >>"$TMP_DIR/tmpl/share-run.sh.tmpl"
sed_inplace 's#<key>RunAtLoad</key>#<key>RunAtLoad</key> #' "$TMP_DIR/tmpl/share.plist.tmpl"
assert_eq "outdated outdated" "$(FL_TEMPLATE_DIR="$TMP_DIR/tmpl"; fl_template_status "$TMP_DIR/job.plist" "$(share_plist)") $(FL_TEMPLATE_DIR="$TMP_DIR/tmpl"; fl_template_status "$TMP_DIR/share-run.sh" "$(share_runner)")"

printf 'test-templates: ok\n'
