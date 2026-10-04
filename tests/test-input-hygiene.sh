#!/usr/bin/env bash
# Input hygiene: a bench path that bash, XML or a hosts line could read as
# more than text is refused before anything is written; template values are
# escaped per format; the /etc/hosts rewrite happens on the root side and
# fails closed; site names are checked before any sudo; the state store
# decodes its values without eval.
# shellcheck disable=SC2016  # the nasty inputs are meant to stay literal
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# ================================================================ F69: bench paths and templates

GOOD_FOR_DOCTOR="$HOME/plain-bench"; make_fake_bench "$GOOD_FOR_DOCTOR" plainsite

# ---- a path with &, a double quote and $( ) is refused by adopt, exit 1, nothing written
BAD="$HOME/dev/bad & \"quoted\" \$(touch ${TMP_DIR}/pwned-by-path)"
make_fake_bench "$BAD"
mkdir -p "$FL_STATE_DIR/benches"; : >"$FL_STATE_FILE"
snap="$(snapshot "$HOME/Library" "$FL_STATE_DIR/benches" "$FL_STATE_FILE" "$BAD")"
run_fm adopt "$BAD" --yes
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "bench path"
assert_contains "$OUT" "a double quote"
assert_contains "$OUT" "Move the bench"
assert_no_file "$BAD/Procfile.lean"
assert_no_file "$BAD/benchbar-run.sh"
assert_no_file "$TMP_DIR/pwned-by-path"
[[ -z "$(ls "$HOME"/Library/LaunchAgents/*.plist 2>/dev/null)" ]] || fail "no agent may be written for a refused path"
[[ -z "$(sed -n 's/^BENCH_DIR=//p' "$FL_STATE_FILE" 2>/dev/null)" ]] || fail "a refused adopt must not remember the bench"
assert_eq "$snap" "$(snapshot "$HOME/Library" "$FL_STATE_DIR/benches" "$FL_STATE_FILE" "$BAD")" "(a refused path writes nothing)"
# service and repair refuse it too, before rendering anything
run_fm service --yes --bench-dir "$BAD"; assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "a double quote"
run_fm repair --dry-run --bench-dir "$BAD"; assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "a double quote"
assert_eq "$snap" "$(snapshot "$HOME/Library" "$FL_STATE_DIR/benches" "$FL_STATE_FILE" "$BAD")"
# each character is named
DOLLAR="$HOME/dev/with\$dollar"; make_fake_bench "$DOLLAR"
run_fm adopt "$DOLLAR" --yes; assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" 'a dollar sign ($)'
AMP="$HOME/dev/with&amp"; make_fake_bench "$AMP"
run_fm adopt "$AMP" --yes; assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "an ampersand (&)"
# the install phase refuses the same path before bench init
BENCH_DIR="$DOLLAR" SITE_NAME=macdev MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw run_fm install --yes --bench-dir "$DOLLAR" --site macdev
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" 'a dollar sign ($)'
assert_calls_not_contain '^bench init'
# doctor stays read only: a FAIL check names the character, the JSON is whole, nothing dies
run_fm doctor --json --bench-dir "$AMP"
assert_eq "1" "$CODE" "$OUT"
printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
c = [x for x in d["checks"] if x["id"] == "bench_path"]
assert len(c) == 1 and c[0]["level"] == "fail", c
assert "an ampersand (&)" in c[0]["message"] and "benchbar adopt" in c[0]["fix_command"], c[0]
assert c[0]["group"] == "service", c[0]
' || fail "doctor --json must report bench_path: $OUT"
run_fm doctor --bench-dir "$AMP"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "[FAIL] Bench path"; assert_not_contains "$OUT" "Aborting"
# a bench at a plain path passes the check
run_fm doctor --json --bench-dir "$GOOD_FOR_DOCTOR"
assert_eq "ok" "$(printf '%s' "$OUT" | jget - '[c["level"] for c in d["checks"] if c["id"] == "bench_path"][0]')"
rm -rf "$GOOD_FOR_DOCTOR"
# up would start a runner that cannot carry the path: a clear refusal
run_fm up --bench-dir "$AMP"
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "an ampersand (&)"; assert_contains "$OUT" "Move the bench"
assert_calls_not_contain '^launchctl (bootstrap|kickstart)'
run_fm autostart off --bench-dir "$AMP"; assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "an ampersand (&)"
rm -rf "$BAD" "$DOLLAR" "$AMP"

# ---- a space and an apostrophe (Bob's Bench) still work: well formed plist, a runner bash accepts
GOOD="$HOME/dev/Bob's Bench"
make_fake_bench "$GOOD" bobsite
run_fm adopt "$GOOD" --yes
assert_eq "0" "$CODE" "$OUT"
runner="$GOOD/benchbar-run.sh"
assert_file "$runner"
bash -n "$runner"
grep -q -F "BENCH=\"${GOOD}\"" "$runner" || fail "the runner carries the path as it is"
plist="$(ls "$HOME"/Library/LaunchAgents/com.benchbar.Bob-s-Bench*.plist)"
[[ -f "$plist" ]] || fail "plist expected for Bob's Bench"
if command -v xmllint >/dev/null 2>&1; then
  xmllint --noout "$plist" || fail "the plist must be well formed XML"
else
  python3 -c 'import xml.dom.minidom, sys; xml.dom.minidom.parse(sys.argv[1])' "$plist" || fail "the plist must be well formed XML"
fi
grep -q -F "<string>${GOOD}</string>" "$plist" || fail "WorkingDirectory is the path itself"
# the runner runs: the stop flag path is built from BENCH, and state.json names the bench
printf 'manual\n' >"$GOOD/logs/.bench-stopped"
bash "$runner"
assert_eq "$GOOD" "$(jget "$GOOD/logs/.benchbar/state.json" 'd["bench"]')"
# a second adopt is a no-op
run_fm adopt "$GOOD" --yes
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "unchanged: all"

# ---- fl_template_render: escaped per format, byte-identical for ordinary input
. "$ROOT/lib/frappe-local/ui.sh"
. "$ROOT/lib/frappe-local/run.sh"
. "$ROOT/lib/frappe-local/templates.sh"
. "$ROOT/lib/frappe-local/process.sh"
. "$ROOT/lib/frappe-local/bench.sh"
r="$(fl_template_render launchagent.plist 'LABEL=a&b<c>"d' APP_BUNDLE_ID=x RUNNER=/r 'BENCH_DIR=/p&q' PATH=/bin RUN_AT_LOAD=true LOG=/l)"
assert_contains "$r" '<string>a&amp;b&lt;c&gt;&quot;d</string>'
assert_contains "$r" '<string>/p&amp;q</string>'
assert_contains "$r" '<key>RunAtLoad</key><true/>'
NASTY='/p "q" $(x) `y` \z'
r="$(fl_template_render bench-run.sh "BENCH_DIR=${NASTY}" "BENCH_RE=$(fl_regex_escape "/a.b")" BENCH_NAME=b HONCHO=/h PORTS=8000 SITE=s WEB_PORT=8000 CLI_VERSION=1 LABEL=l MAX_STARTS=3 WINDOW=600)"
printf '%s' "$r" >"$TMP_DIR/nasty-runner"
bash -n "$TMP_DIR/nasty-runner"
assert_eq "$NASTY" "$(bash -c 'eval "$(sed -n "/^BENCH=/p" "$1")"; printf "%s" "$BENCH"' _ "$TMP_DIR/nasty-runner")" "(the value survives the double quotes)"
assert_contains "$r" 'pkill -f "^/a\.b/env/bin/python' "(a regex value is not touched)"
# the headers (hash of the rendered body) of ordinary inputs are what the runner rendered before the quoting change
r="$(fl_template_render bench-run.sh "BENCH_DIR=/Users/bob/dev/Bob's Bench" "BENCH_RE=$(fl_regex_escape "/Users/bob/dev/Bob's Bench")" "BENCH_NAME=Bob-s-Bench" \
  "HONCHO=/Users/bob/.local/pipx/venvs/frappe-bench/bin/honcho" "PORTS=8000,9000,11000,13000" "SITE=macdev" "WEB_PORT=8000" "CLI_VERSION=0.7.2" \
  "LABEL=com.benchbar.Bob-s-Bench" "MAX_STARTS=3" "WINDOW=600")"
assert_eq "bench-run.sh v7 1f2195784c50" "$(fl_template_header_of "$r")" "(an ordinary runner renders as before: the hash is the body's, the version is bumped)"
r="$(fl_template_render launchagent.plist "LABEL=com.benchbar.Bob-s-Bench" "APP_BUNDLE_ID=com.akashmishra.benchbar" "RUNNER=/Users/bob/dev/Bob's Bench/benchbar-run.sh" \
  "BENCH_DIR=/Users/bob/dev/Bob's Bench" "PATH=/opt/homebrew/bin:/usr/bin:/bin" "RUN_AT_LOAD=true" "LOG=/Users/bob/dev/Bob's Bench/logs/bench.log")"
assert_eq "launchagent.plist v2 3b09ae107fcf" "$(fl_template_header_of "$r")" "(an ordinary plist renders as before)"
r="$(fl_template_render shell-helpers "PROFILE_EXPORTS=export PATH=\"/opt/homebrew/opt/python@3.11/bin:\$PATH\"" "BENCHBAR=/Users/bob/.local/bin/benchbar")"
assert_eq "shell-helpers v2 db59c9f03a56" "$(fl_template_header_of "$r")" "(the helper block renders as before)"
assert_contains "$r" 'export PATH="/opt/homebrew/opt/python@3.11/bin:$PATH"' "(the exports are raw bash)"
# the same renders under bash 3.2 semantics (BASH_COMPAT=32: a quoted replacement keeps its quotes there, BENCH=""..."")
compat_out="$(BASH_COMPAT=32 SCRIPT_DIR="$ROOT" FL_STATE_DIR="$FL_STATE_DIR" bash -c '
  . "$1/lib/frappe-local/ui.sh"; . "$1/lib/frappe-local/run.sh"; . "$1/lib/frappe-local/templates.sh"; . "$1/lib/frappe-local/process.sh"
  r="$(fl_template_render bench-run.sh "BENCH_DIR=/Users/bob/dev/Bob'"'"'s Bench" "BENCH_RE=$(fl_regex_escape "/Users/bob/dev/Bob'"'"'s Bench")" "BENCH_NAME=Bob-s-Bench" \
    "HONCHO=/Users/bob/.local/pipx/venvs/frappe-bench/bin/honcho" "PORTS=8000,9000,11000,13000" "SITE=macdev" "WEB_PORT=8000" "CLI_VERSION=0.7.2" \
    "LABEL=com.benchbar.Bob-s-Bench" "MAX_STARTS=3" "WINDOW=600")"
  fl_template_header_of "$r"; printf "%s\n" "$r" | grep -c -x "BENCH=\"/Users/bob/dev/Bob'"'"'s Bench\""
  r="$(fl_template_render launchagent.plist "LABEL=com.benchbar.Bob-s-Bench" "APP_BUNDLE_ID=com.akashmishra.benchbar" "RUNNER=/Users/bob/dev/Bob'"'"'s Bench/benchbar-run.sh" \
    "BENCH_DIR=/Users/bob/dev/Bob'"'"'s Bench" "PATH=/opt/homebrew/bin:/usr/bin:/bin" "RUN_AT_LOAD=true" "LOG=/Users/bob/dev/Bob'"'"'s Bench/logs/bench.log")"
  fl_template_header_of "$r"; printf "%s\n" "$r" | grep -c -x "  <key>WorkingDirectory</key><string>/Users/bob/dev/Bob'"'"'s Bench</string>"
  r="$(fl_template_render shell-helpers "PROFILE_EXPORTS=export PATH=\"/opt/homebrew/opt/python@3.11/bin:\$PATH\"" "BENCHBAR=/Users/bob/.local/bin/benchbar")"
  fl_template_header_of "$r"; printf "%s\n" "$r" | grep -c -x "BENCHBAR=\"/Users/bob/.local/bin/benchbar\""
  fl_xml_escape_v x "a&b<c>"; printf "%s\n" "$x"
' _ "$ROOT")"
assert_eq "bench-run.sh v7 1f2195784c50
1
launchagent.plist v2 3b09ae107fcf
1
shell-helpers v2 db59c9f03a56
1
a&amp;b&lt;c&gt;" "$compat_out" "(the renders under BASH_COMPAT=32: the headers, one exact line each, no stray quotes)"
# the validator itself
fl_bench_path_ok "/Users/bob/dev/Bob's Bench" || fail "an apostrophe and a space are fine"
fl_bench_path_ok "/Users/bob/frappe-bench" || fail "an ordinary path is fine"
for p in '/a"b' '/a\b' '/a$b' '/a`b' '/a<b' '/a>b' '/a&b' $'/a\tb' $'/a\nb' $'/a\001b'; do
  ! fl_bench_path_ok "$p" || fail "must refuse: $p"
done

# ================================================================ F44 and F45: the hosts file

BENCH="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH"
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
grep -q -x -F "# >>> benchbar >>>" "$FL_HOSTS_FILE" || fail "the first entry opens the block"
grep -q -x '127.0.0.1 macdev' "$FL_HOSTS_FILE" || fail "hosts entry expected"

# ---- a line inside the existing block: edited as root, checked, moved into place; never a user owned copy
for s in second third; do mkdir -p "$BENCH/sites/$s"; printf '{}\n' >"$BENCH/sites/$s/site_config.json"; done
reset_calls
run_fm site hosts --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain "^sudo env L=127.0.0.1 second E=# <<< benchbar <<< awk "
assert_calls_contain "^sudo tee ${FL_HOSTS_FILE}.benchbar.new\$"
assert_calls_contain "^sudo chmod 644 ${FL_HOSTS_FILE}.benchbar.new\$"
assert_calls_contain "^sudo mv ${FL_HOSTS_FILE}.benchbar.new ${FL_HOSTS_FILE}\$"
assert_calls_not_contain '^sudo cp '
assert_no_file "${FL_HOSTS_FILE}.benchbar.new"
awk '/^# >>> benchbar >>>$/{b=1;next} /^# <<< benchbar <<<$/{b=0} b' "$FL_HOSTS_FILE" | grep -q -x '127.0.0.1 second' || fail "second inside the block"
awk '/^# >>> benchbar >>>$/{b=1;next} /^# <<< benchbar <<<$/{b=0} b' "$FL_HOSTS_FILE" | grep -q -x '127.0.0.1 third' || fail "third inside the block"
assert_eq "1" "$(grep -c -x -F "# >>> benchbar >>>" "$FL_HOSTS_FILE")" "(one block only)"
grep -q -x '127.0.0.1 localhost' "$FL_HOSTS_FILE" || fail "the lines outside the block stay"
# again: unchanged, no sudo at all
reset_calls; snap="$(snapshot "$FL_HOSTS_FILE")"
run_fm site hosts --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "unchanged"
assert_calls_not_contain '^sudo'
assert_eq "$snap" "$(snapshot "$FL_HOSTS_FILE")"

# ---- a hosts file without a trailing newline is still rewritten (and gets one)
printf '%s' "$(cat "$FL_HOSTS_FILE")" >"$FL_HOSTS_FILE"
mkdir -p "$BENCH/sites/fifth"; printf '{}\n' >"$BENCH/sites/fifth/site_config.json"
run_fm site hosts --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
awk '/^# >>> benchbar >>>$/{b=1;next} /^# <<< benchbar <<<$/{b=0} b' "$FL_HOSTS_FILE" | grep -q -x '127.0.0.1 fifth' || fail "fifth inside the block"
[[ "$(tail -c1 "$FL_HOSTS_FILE")" == "" ]] || fail "the rewritten file ends with a newline"
rm -rf "$BENCH/sites/fifth"

# ---- the rewrite fails closed: a hosts file with a line that is not "address names" is left alone
cp "$FL_HOSTS_FILE" "$TMP_DIR/hosts.good"
printf 'this is not a hosts line\n' >>"$FL_HOSTS_FILE"
mkdir -p "$BENCH/sites/fourth"; printf '{}\n' >"$BENCH/sites/fourth/site_config.json"
reset_calls; snap="$(snapshot "$FL_HOSTS_FILE")"
run_fm site hosts --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "not written"
assert_contains "$OUT" "this is not a hosts line"
assert_calls_not_contain '^sudo mv '
assert_no_file "${FL_HOSTS_FILE}.benchbar.new"
assert_eq "$snap" "$(snapshot "$FL_HOSTS_FILE")" "(a refused rewrite changes nothing)"
cp "$TMP_DIR/hosts.good" "$FL_HOSTS_FILE"
rm -rf "$BENCH/sites/fourth"

# ---- removing a line (site drop) goes the same root side way
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
export MARIADB_ROOT_PASSWORD=rootpw
mkdir -p "$BENCH/sites/third/private"
reset_calls
run_fm site drop third --confirm-site third --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "removed '127.0.0.1 third'"
assert_calls_contain "^sudo env S=# >>> benchbar >>> E=# <<< benchbar <<< RE="
assert_calls_contain "^sudo mv ${FL_HOSTS_FILE}.benchbar.new ${FL_HOSTS_FILE}\$"
assert_calls_not_contain '^sudo cp '
assert_no_file "${FL_HOSTS_FILE}.benchbar.new"
! grep -q 'third' "$FL_HOSTS_FILE" || fail "the dropped site's line is gone"
grep -q -x '127.0.0.1 second' "$FL_HOSTS_FILE" || fail "the other line in the block stays"
grep -q -x '127.0.0.1 macdev' "$FL_HOSTS_FILE" || fail "the first line in the block stays"
unset MARIADB_ROOT_PASSWORD

# ---- a hosts file as Apple ships it (tabs, IPv6, a zone id, comments, a CRLF line) takes a line and loses one
printf '##\n# Host Database\n##\n127.0.0.1\tlocalhost\n255.255.255.255\tbroadcasthost\n::1 localhost\nfe80::1%%lo0\tlocalhost\n  # indented comment\n192.168.65.254 host.docker.internal # Added by Docker Desktop\n10.0.0.5 crlf.example\r\n\n# >>> benchbar >>>\n127.0.0.1 macdev\n127.0.0.1 second\n# <<< benchbar <<<\n' >"$FL_HOSTS_FILE"
cp "$FL_HOSTS_FILE" "$TMP_DIR/hosts.apple"
mkdir -p "$BENCH/sites/sixth/private"; printf '{}\n' >"$BENCH/sites/sixth/site_config.json"
reset_calls
run_fm site hosts --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain "^sudo mv ${FL_HOSTS_FILE}.benchbar.new ${FL_HOSTS_FILE}\$"
awk '/^# >>> benchbar >>>$/{b=1;next} /^# <<< benchbar <<<$/{b=0} b' "$FL_HOSTS_FILE" | grep -q -x '127.0.0.1 sixth' || fail "sixth inside the block"
cmp -s "$TMP_DIR/hosts.apple" <(grep -v -x '127.0.0.1 sixth' "$FL_HOSTS_FILE") || fail "every other line must be byte identical after the add"
export MARIADB_ROOT_PASSWORD=rootpw
run_fm site drop sixth --confirm-site sixth --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "removed '127.0.0.1 sixth'"
cmp -s "$TMP_DIR/hosts.apple" "$FL_HOSTS_FILE" || fail "the file is byte identical after the remove"
unset MARIADB_ROOT_PASSWORD

# ---- F45: a site folder named with a literal backslash-n never reaches sudo
EVIL='evil\nx'
mkdir -p "$BENCH/sites/$EVIL"; printf '{}\n' >"$BENCH/sites/$EVIL/site_config.json"
reset_calls; snap="$(snapshot "$FL_HOSTS_FILE")"
run_fm site hosts --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "[WARN]"
assert_contains "$OUT" "sites/${EVIL}"
assert_contains "$OUT" "not a valid site name"
assert_calls_not_contain '^sudo'
assert_eq "$snap" "$(snapshot "$FL_HOSTS_FILE")" "(the hosts file is unchanged)"
assert_eq "0" "$(grep -c 'evil' "$FL_HOSTS_FILE")"
rm -rf "$BENCH/sites/$EVIL"
# the repair action skips an invalid default site name the same way
printf '127.0.0.1 localhost\n' >"$FL_HOSTS_FILE"
reset_calls
run_fm repair --yes --site Evil_Site --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "not a valid site name"
assert_calls_not_contain '^sudo (env|tee|mv|cp|awk)'
assert_eq "127.0.0.1 localhost" "$(cat "$FL_HOSTS_FILE")"

# ---- install --dry-run shows the wkhtmltopdf plan once (the up front sudo step, not phase 00 again)
rm -f "$MOCK_STATE/wkhtml_installed"; touch "$MOCK_STATE/wkhtml_missing"; rm -rf "$FL_STATE_DIR/downloads"
MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw run_fm install --dry-run --yes --bench-dir "$HOME/dev/dry-bench" --site drysite
assert_eq "0" "$CODE" "$OUT"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c 'dry-run: sudo installer -pkg')" "(the PDF plan is printed once)"
rm -f "$MOCK_STATE/wkhtml_missing"; touch "$MOCK_STATE/wkhtml_installed"

# ================================================================ F128: the state store decodes without eval
. "$ROOT/lib/frappe-local/state.sh"
KV="$TMP_DIR/kv.env"
i=0
for v in 'a b' $'a\tb' $'a\nb' "\$(touch ${TMP_DIR}/pwned-rt)" '*' "it's" 'say "hi"' 'back\slash' 'é' '' '-x' '~' '`touch x`' '$HOME' 'a\ b' '$'"'"'x\ny'"'"; do
  i=$((i + 1))
  fl_kv_set "$KV" "K$i" "$v"
  got="$(fl_kv_get "$KV" "K$i")"
  [[ "$got" == "$v" ]] || fail "round trip $i: wrote [$v], read [$got]"
done
assert_no_file "$TMP_DIR/pwned-rt"
assert_no_file "$TMP_DIR/x"
# hand written lines: literal text, no command, no glob, no expansion
cd "$TMP_DIR"
printf 'INJ=$(touch "%s/pwned-kv")\nGLOB=*\nHOME_REF=$HOME\nTILDE=~\nQUOTED=%s\n' "$TMP_DIR" "'single quoted'" >"$KV"
assert_eq "\$(touch \"${TMP_DIR}/pwned-kv\")" "$(fl_kv_get "$KV" INJ)"
assert_no_file "$TMP_DIR/pwned-kv"
assert_eq "*" "$(fl_kv_get "$KV" GLOB)"
assert_eq '$HOME' "$(fl_kv_get "$KV" HOME_REF)"
assert_eq '~' "$(fl_kv_get "$KV" TILDE)"
assert_eq 'single quoted' "$(fl_kv_get "$KV" QUOTED)"
cd "$ROOT"
# the primed per bench cache (status, list) decodes the same way
FL_BENCH_DIR="$BENCH"; FL_CONTEXT_LIGHT=1
fl_bstate_set_for "$BENCH" PROFILE 'v15 "x" $(touch pwned-bs)'
printf 'HONCHO_BIN=$(touch %s/pwned-prime)\n' "$TMP_DIR" >>"$(fl_bench_state_file_for "$BENCH")"
fl_bstate_prime
assert_eq "$BENCH" "$FL_BS_DIR"
assert_eq 'v15 "x" $(touch pwned-bs)' "$(fl_bstate_get_for "$BENCH" PROFILE)"
assert_eq "\$(touch ${TMP_DIR}/pwned-prime)" "$(fl_bstate_get_for "$BENCH" HONCHO_BIN)"
assert_no_file "$TMP_DIR/pwned-prime"
assert_no_file "$ROOT/pwned-bs"
assert_no_file "$TMP_DIR/pwned-bs"

printf 'test-hygiene: ok\n'
