#!/usr/bin/env bash
# install --json and adopt --json (docs/json-schema.md): the stream's event
# order, ids and parents, a failed step, exit 2, refusals, a cancelled or
# failed macOS password dialog, one dialog per privileged step with
# awkward paths, progress lines, doctor --prerequisites and profile list.
# The no gui mode (sudo -n only), adopt --json, ports apply under the dialogs and
# profile list are in test-install-json-2.sh: together they would not fit the
# 600 s a test may take.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=tests/lib/install-stream.sh
. "$ROOT/tests/lib/install-stream.sh"

stream_machine
BENCH="$HOME/frappe-bench"
export MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw BENCHBAR_SUDO=gui

# ---- refusals before the plan: one done line, nothing written, no lock
snap="$(snapshot "$HOME" "$FL_STATE_DIR")"
stream install --json --bench-dir "$BENCH" --site macdev
assert_eq "1" "$CODE"
assert_eq "done" "$(sx '" ".join(x["event"] for x in e)')"
assert_eq "1" "$(sx 'e[0]["exit"]')"
assert_contains "$(sx 'e[0]["error"]')" "needs --yes"
assert_eq "None" "$(sx 'e[0]["log"]')"
assert_eq "$snap" "$(snapshot "$HOME" "$FL_STATE_DIR")" "(a refusal writes nothing)"
assert_no_file "$FL_STATE_DIR/lock"
assert_eq "0" "$(osa_calls)"

# a site that does not exist needs ADMIN_PASSWORD
ADMIN_PASSWORD='' stream install --json --yes --bench-dir "$BENCH" --site macdev
assert_eq "1" "$CODE"
assert_eq "done" "$(sx '" ".join(x["event"] for x in e)')"
assert_contains "$(sx 'e[0]["error"]')" "ADMIN_PASSWORD"
assert_no_file "$BENCH"

# ---- dry run: plan, then done
stream install --json --dry-run --bench-dir "$BENCH" --site macdev
assert_eq "0" "$CODE" "$(cat "$STREAM.err")"
assert_eq "plan done" "$(sx '" ".join(x["event"] for x in e)')"
assert_eq "True" "$(sx 'e[0]["dry_run"] and e[1]["dry_run"]')"
assert_eq "gui" "$(sx 'e[0]["sudo_mode"]')"
assert_eq "wkhtmltopdf_install hosts_entry system_deps bench_site service" "$(sx '" ".join(s["id"] for s in e[0]["steps"])')"
assert_eq "[None, None, 1, 2, 3]" "$(sx '[s["n"] for s in e[0]["steps"]]')"
assert_eq "True True" "$(sx '" ".join(str(s["will_run"]) for s in e[0]["steps"][:2])')"
assert_eq "0 http://macdev:8000 minimal v15-lts None" "$(sx '" ".join(str(e[0][k]) for k in ("port_offset","web_url","bundle","profile","team_profile"))')"
assert_file "$(sx 'e[0]["log"]')"
assert_no_file "$BENCH"
assert_eq "0" "$(osa_calls)"

# ---- doctor --prerequisites: no bench needed, each id, levels from the mocked conditions
PRE="$TMP_DIR/pre-home"; mkdir -p "$PRE"
pre() { set +e; OUT="$(cd "$PRE" && "$FM" doctor --prerequisites --json "$@" 2>"$TMP_DIR/pre.err")"; CODE=$?; set -e; }
pq() { printf '%s' "$OUT" | python3 -I -c 'import json,re,sys; d=json.load(sys.stdin); c={x["id"]:x for x in d["prerequisites"]}; print('"$1"')'; }
printf '%s' 52428800 >"$MOCK_STATE/df_avail_kb"
export MOCK_XCODE_DIR="$TMP_DIR"
snap="$(snapshot "$HOME" "$FL_STATE_DIR")"
pre --bench-dir "$HOME/not-created-yet"
assert_eq "0" "$CODE" "$OUT"
printf '%s\n' "$OUT" >"$TMP_DIR/prereq.json"
assert_eq "apple_silicon macos_version command_line_tools homebrew disk_free bench_folder cleanmymac mole default_ports" "$(pq '" ".join(x["id"] for x in d["prerequisites"])')"
assert_eq "True" "$(pq 'all(set(x) >= {"id","label","level","message","fix_command"} for x in d["prerequisites"])')"
assert_eq "ok ok ok ok ok ok ok ok ok" "$(pq '" ".join(x["level"] for x in d["prerequisites"])')"
assert_eq "50 0 $HOME/not-created-yet" "$(pq '" ".join(str(v) for v in (c["disk_free"]["free_gb"], c["default_ports"]["port_offset"], c["bench_folder"]["message"]))')"
assert_eq '{"ok": 9, "warn": 0, "fail": 0}' "$(pq 'json.dumps(d["summary"])')"
assert_eq "$snap" "$(snapshot "$HOME" "$FL_STATE_DIR")" "(prerequisites write nothing)"
assert_no_file "$HOME/not-created-yet"
pre
assert_eq "$HOME/frappe-bench" "$(pq 'd["bench"]')"
# each condition
MOCK_SW_VERS=13.4 pre; assert_eq "1 fail" "$CODE $(pq 'c["macos_version"]["level"]')"
MOCK_XCODE_NONE=1 pre; assert_eq "fail xcode-select --install" "$(pq 'c["command_line_tools"]["level"]') $(pq 'c["command_line_tools"]["fix_command"]')"
MOCK_XCODE_DIR="$TMP_DIR/not there" pre; assert_eq "fail" "$(pq 'c["command_line_tools"]["level"]')"
printf '%s' 15728640 >"$MOCK_STATE/df_avail_kb"; pre; assert_eq "warn 15" "$(pq 'c["disk_free"]["level"]') $(pq 'c["disk_free"]["free_gb"]')"; assert_eq "0" "$CODE"
printf '%s' 5242880 >"$MOCK_STATE/df_avail_kb"; pre; assert_eq "fail 5 1" "$(pq 'c["disk_free"]["level"]') $(pq 'c["disk_free"]["free_gb"]') $CODE"
printf '%s' 52428800 >"$MOCK_STATE/df_avail_kb"
pre --bench-dir "$HOME/Desktop/frappe-bench"; assert_eq "warn 0" "$(pq 'c["bench_folder"]["level"]') $CODE"
pre --bench-dir "$HOME/Documents/x"; assert_eq "warn" "$(pq 'c["bench_folder"]["level"]')"
pre --bench-dir "$HOME/Library/Mobile Documents/com~apple~CloudDocs/b"; assert_eq "fail 1" "$(pq 'c["bench_folder"]["level"]') $CODE"
pre --bench-dir "$HOME/we\"ird"; assert_eq "fail 1" "$(pq 'c["bench_folder"]["level"]') $CODE"
assert_contains "$(pq 'c["bench_folder"]["message"]')" "double quote"
mkdir -p "$HOME/Applications/CleanMyMac X.app"; pre; assert_eq "warn" "$(pq 'c["cleanmymac"]["level"]')"; rmdir "$HOME/Applications/CleanMyMac X.app"
mkdir -p "$TMP_DIR/molebin"; printf '#!/bin/sh\nexit 0\n' >"$TMP_DIR/molebin/mole"; chmod +x "$TMP_DIR/molebin/mole"
PATH="$TMP_DIR/molebin:$PATH" FL_MOLE_CMDS=mole pre; assert_eq "warn" "$(pq 'c["mole"]["level"]')"
add_listener 8000 4242 ForeignApp
pre; assert_eq "warn 1" "$(pq 'c["default_ports"]["level"]') $(pq 'c["default_ports"]["port_offset"]')"; assert_eq "0" "$CODE"
# every block taken (only block 0 allowed here): a fail, no --port-offset remedy
FL_PORT_MAX_OFFSET=0 pre; assert_eq "fail None 1" "$(pq 'c["default_ports"]["level"]') $(pq 'c["default_ports"]["port_offset"]') $CODE"
assert_not_contains "$(pq 'c["default_ports"]["fix_command"]')" "--port-offset"
printf '3306 111 mariadbd 127.0.0.1\n' >"$MOCK_LISTEN"
FL_BREW_ALT_BIN="$TMP_DIR/nobrew" PATH="/usr/bin:/bin" pre; assert_eq "fail" "$(pq 'c["homebrew"]["level"]')"
assert_contains "$(pq 'c["homebrew"]["fix_command"]')" "Homebrew/install"
# ---- success, with the password dialogs: exactly two, one per privileged step
stream install --json --yes --bench-dir "$BENCH" --site macdev
assert_eq "0" "$CODE" "$(cat "$STREAM.err")$(tail -n 30 "$(sx 'e[-1]["log"]')")"
assert_eq "plan" "$(sx 'e[0]["event"]')"
assert_eq "done" "$(sx 'e[-1]["event"]')"
assert_eq "0 http://macdev:8000 []" "$(sx '" ".join(str(e[-1][k]) for k in ("exit","url","skipped"))')"
assert_eq "2" "$(osa_calls)"
assert_eq "Install the patched wkhtmltopdf package" "$(sed -n 1p "$MOCK_STATE/osa_reasons")"
assert_eq "Add 127.0.0.1 macdev to /etc/hosts" "$(sed -n 2p "$MOCK_STATE/osa_reasons")"
assert_calls_not_contain '^sudo'
# Rosetta rides in the package's dialog
assert_calls_contain '^softwareupdate --install-rosetta --agree-to-license$'
assert_calls_contain '^installer -pkg /tmp/benchbar-wkhtmltopdf\.[A-Za-z0-9]+/wkhtmltox'
grep -q '^127.0.0.1 macdev$' "$FL_HOSTS_FILE" || fail "the hosts line"
# the top level steps, in order, each running then ended
assert_eq "wkhtmltopdf_install:running wkhtmltopdf_install:done hosts_entry:running hosts_entry:done system_deps:running" \
  "$(sx '" ".join(x["id"]+":"+x["status"] for x in e if x["event"]=="step")' | cut -d' ' -f1-5)"
assert_eq "system_deps:done bench_site:running bench_site:done service:running service:done" \
  "$(sx '" ".join(x["id"]+":"+x["status"] for x in e if x["event"]=="step" and x["parent"] is None and x["n"])' | sed 's/system_deps:running //')"
# the sections of the phase scripts and the service actions are nested
assert_eq "True" "$(sx '{"python","node","database","redis","pdf"} <= {x["id"] for x in e if x["event"]=="step" and x["parent"]=="system_deps"}')"
assert_eq "True" "$(sx '{"precheck","inputs","plan","get_apps","install_apps_on_site","ready"} <= {x["id"] for x in e if x["event"]=="step" and x["parent"]=="bench_site"}')"
assert_eq "True" "$(sx 'any(x.get("parent")=="service" and x["n"] is None and x["id"]=="write_procfile" for x in e)')"
assert_eq "PYTHON" "$(sx '[x["name"] for x in e if x.get("id")=="python" and x["status"]=="running"][0]')"
# no hosts_entry or wkhtmltopdf_install twice
assert_eq "2" "$(sx 'sum(1 for x in e if x["event"]=="step" and x["status"]=="running" and x["id"] in ("hosts_entry","wkhtmltopdf_install"))')"
assert_eq "True" "$(sx 'all("secs" in x for x in e if x["event"]=="step" and x["status"] in ("done","unchanged","warning","failed","skipped"))')"
assert_file "$BENCH/benchbar-run.sh"
cp "$STREAM" "$TMP_DIR/stream-success.jsonl"
# changed[] names what the phase scripts created: the bench and the site (children report through FL_CHANGED_FILE)
assert_eq "True" "$(sx '{"bench", "site"} <= {x["kind"] for x in e[-1]["changed"]} and all(x["name"] for x in e[-1]["changed"])')"
assert_eq "True" "$(sx 'any(x["kind"] == "site" and x["name"] == "macdev" for x in e[-1]["changed"])')"

# a second install changes nothing and asks nothing
osa_reset
stream install --json --yes --bench-dir "$BENCH" --site macdev
assert_eq "0" "$CODE"
assert_eq "0" "$(osa_calls)"
assert_eq "False False" "$(sx '" ".join(str(s["will_run"]) for s in e[0]["steps"][:2])')"
# nothing was created the second time: no bench, site or app in changed[]
assert_eq "[]" "$(sx '[x for x in e[-1]["changed"] if x["kind"] in ("bench", "site", "app")]')"


# ---- a cancelled dialog: the step is skipped with its command, the run goes on, each step asks once
fresh_pdf() { rm -f "$MOCK_STATE/wkhtml_installed" "$MOCK_STATE/rosetta"; touch "$MOCK_STATE/wkhtml_missing"; find "$FL_STATE_DIR/downloads" -type f -delete 2>/dev/null || true; }
fresh_pdf; osa_reset
CB="$HOME/cancel-bench"
printf 'Add 127.0.0.1 canc to /etc/hosts\n' >"$MOCK_STATE/osa_cancel"
stream install --json --yes --bench-dir "$CB" --site canc
assert_eq "0" "$CODE" "$(cat "$STREAM.err")"
assert_eq "2" "$(osa_calls)" "(the engine does not ask for the line again)"
assert_eq "skipped" "$(sx '[x["status"] for x in e if x.get("id")=="hosts_entry"][-1]')"
assert_contains "$(sx '[x.get("message") for x in e if x.get("id")=="hosts_entry"][-1]')" "[WARN] the password dialog was cancelled"
assert_eq "benchbar site hosts --bench-dir $CB" "$(sx '[x.get("command") for x in e if x.get("id")=="hosts_entry"][-1]' | sed "s#^.*/benchbar #benchbar #")"
assert_eq "hosts_entry" "$(sx '" ".join(s["id"] for s in e[-1]["skipped"])')"
assert_eq "done" "$(sx '[x["status"] for x in e if x.get("id")=="wkhtmltopdf_install"][-1]')"
assert_eq "done" "$(sx '[x["status"] for x in e if x.get("id")=="service" and x["parent"] is None][-1]')"
assert_eq "0 http://canc:8000" "$(sx '" ".join(str(e[-1][k]) for k in ("exit","url"))')"
assert_eq "0" "$(sx 'sum(1 for x in e if x.get("parent")=="service" and x["id"]=="hosts_entry")')"
if grep -q '^127.0.0.1 canc$' "$FL_HOSTS_FILE"; then fail "a cancelled dialog must not write the line"; fi
cp "$STREAM" "$TMP_DIR/stream-cancelled.jsonl"

# both dialogs cancelled: two skipped steps, each with a command; two dialogs in all
fresh_pdf; osa_reset; touch "$MOCK_STATE/osa_cancel_all"
stream install --json --yes --bench-dir "$HOME/cancel-bench2" --site canctwo
assert_eq "0" "$CODE"
assert_eq "2" "$(osa_calls)"
assert_eq "wkhtmltopdf_install hosts_entry" "$(sx '" ".join(s["id"] for s in e[-1]["skipped"])')"
assert_contains "$(sx 'e[-1]["skipped"][0]["command"]')" "softwareupdate --install-rosetta --agree-to-license && sudo installer -pkg"
assert_eq "None" "$(sx 'e[-1]["fix"]')"

# a dialog whose script fails: the steps are failed, with the CLI's line, no dialog is repeated
fresh_pdf; osa_reset; touch "$MOCK_STATE/osa_fail"
stream install --json --yes --bench-dir "$HOME/fail-bench" --site failsite
assert_eq "1" "$CODE"
assert_eq "2" "$(osa_calls)" "(the service step does not ask again)"
assert_eq "failed failed" "$(sx '" ".join(x["status"] for x in e if x.get("id") in ("wkhtmltopdf_install","hosts_entry") and x["status"]=="failed")')"
assert_contains "$(sx '[x["message"] for x in e if x.get("id")=="wkhtmltopdf_install" and x["status"]=="failed"][0]')" "[FAIL]"
assert_eq "[]" "$(sx 'e[-1]["skipped"]')"
osa_reset

# ---- a failed step: done 1, the failed section is named
fresh_pdf
MOCK_BENCH_NEW_SITE_EXIT=1 stream install --json --yes --bench-dir "$HOME/fail-bench2" --site failtwo
assert_eq "1" "$CODE"
assert_eq "1 None" "$(sx '" ".join(str(e[-1][k]) for k in ("exit","url"))')"
assert_eq "failed" "$(sx '[x["status"] for x in e if x.get("id")=="bench_site" and x["parent"] is None][-1]')"
assert_eq "failed" "$(sx '[x["status"] for x in e if x.get("id")=="create_site" and x["parent"]=="bench_site"][-1]')"
assert_contains "$(sx '[x["message"] for x in e if x.get("id")=="bench_site" and x["status"]=="failed"][-1]')" "[FAIL]"
assert_eq "done" "$(sx 'e[-1]["event"]')"
cp "$STREAM" "$TMP_DIR/stream-failed.jsonl"

# ---- exit 2: the MariaDB root password is unknown
fresh_pdf
rm -f "$MOCK_STATE/keychain/benchbar-mariadb--root"; printf 'mystery' >"$MOCK_STATE/mariadb_root_pw"
MARIADB_ROOT_PASSWORD='' stream install --json --yes --bench-dir "$HOME/two-bench" --site twosite
assert_eq "2" "$CODE"
assert_eq "2" "$(sx 'e[-1]["exit"]')"
assert_contains "$(sx 'e[-1]["fix"]')" "MARIADB_ROOT_PASSWORD"
assert_eq "warning" "$(sx '[x["status"] for x in e if x.get("id")=="system_deps" and x["parent"] is None][-1]')"
assert_eq "None" "$(sx 'e[-1]["url"]')"
assert_no_file "$HOME/two-bench"
cp "$STREAM" "$TMP_DIR/stream-exit2.jsonl"
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"; printf 'rootpw\n' >"$MOCK_STATE/keychain/benchbar-mariadb--root"

# ---- quoting: paths with spaces, single and double quotes reach root intact, one dialog per step
fresh_pdf; osa_reset
ODD_HOSTS="$TMP_DIR/ho sts \"x\" it's/hosts"
mkdir -p "$(dirname "$ODD_HOSTS")"; printf '127.0.0.1 localhost\n# >>> benchbar >>>\n127.0.0.1 other\n# <<< benchbar <<<\n' >"$ODD_HOSTS"
ODD_DL="$TMP_DIR/dl \"q\" it's"
ODD_BENCH="$HOME/my bench's"
FL_HOSTS_FILE="$ODD_HOSTS" FL_WKHTML_DOWNLOAD_DIR="$ODD_DL" stream install --json --yes --bench-dir "$ODD_BENCH" --site oddsite
assert_eq "0" "$CODE" "$(cat "$STREAM.err")$(tail -n 20 "$(sx 'e[-1]["log"]')")"
assert_eq "2" "$(osa_calls)"
python3 -I - "$MOCK_STATE/osa_cmd.1" "$MOCK_STATE/osa_cmd.2" "$ODD_DL" "$ODD_HOSTS" <<'PY' || fail "the command lines do not quote their paths"
import shlex, sys
c1 = shlex.split(open(sys.argv[1]).read()); c2 = shlex.split(open(sys.argv[2]).read())
assert c1[:2] == ["/bin/bash", "-c"] and c1[3] == "benchbar-root", c1[:4]
assert c1[4].startswith(sys.argv[3] + "/") and c1[4].endswith(".pkg"), c1[4]
assert c2[4] == sys.argv[4], c2[4]
PY
grep -qx '127.0.0.1 oddsite' "$ODD_HOSTS" || fail "the line is in the odd hosts file"
assert_eq "1" "$(grep -c '^# >>> benchbar >>>$' "$ODD_HOSTS")"
awk '/^# >>> benchbar >>>$/{b=1;next} /^# <<< benchbar <<<$/{b=0} b' "$ODD_HOSTS" | grep -qx '127.0.0.1 oddsite' || fail "the line sits inside the block"
assert_file "$ODD_BENCH/benchbar-run.sh"

# ---- progress lines: every FL_PROGRESS_SECS while a long command runs, bytes for the download
fresh_pdf; osa_reset
MOCK_DOWNLOAD_SLEEP=3 FL_PROGRESS_SECS=1 stream install --json --yes --bench-dir "$HOME/prog-bench" --site progsite
assert_eq "0" "$CODE"
cp "$STREAM" "$TMP_DIR/stream-progress.jsonl"
assert_eq "True" "$(sx 'any(x["event"]=="progress" and x["step"]=="wkhtmltopdf_install" and isinstance(x["bytes"], int) and x["bytes"] > 0 and x["total"] is None and x["elapsed"] >= 1 and "download wkhtmltopdf" in x["label"] for x in e)')"
osa_reset

# ---- the root scripts' safety bails, run by the fake osascript as the test user
cat >"$TMP_DIR/bail.sh" <<'BAILSH'
#!/usr/bin/env bash
# bail.sh FUNCTION ARGS...: a CLI function with the libraries loaded
set -o pipefail
SCRIPT_DIR="$ROOT"
. "$ROOT/lib/frappe-local/install-kind.sh"
for f in ui run platform version-policy state templates shellrc benchinfo process launchd benchstate discovery ports checks sudo mariadb repair service sites wkhtmltopdf; do . "$ROOT/lib/frappe-local/$f.sh"; done
FL_PLAIN=1; fl_ui_init
FL_SELF=benchbar; FL_BENCH_DIR="$BENCH_FOR_BAIL"; FL_SITE=bailsite
FL_STEP_RESULT=done
wrong_delta() { fl_root_run "Add" "$(fl_hosts_root_script)" "$FL_HOSTS_FILE" rewrite "$FL_HOSTS_START" "$FL_HOSTS_END" "127.0.0.1 a" 2; }
"$@"
code=$?
printf 'code=%s result=%s\n' "$code" "$FL_STEP_RESULT"
printf 'output=%s\n' "${FL_ROOT_OUTPUT:-}" | head -n 3
BAILSH
bail() { set +e; OUT="$(ROOT="$ROOT" BENCH_FOR_BAIL="$HOME/bail-bench" bash "$TMP_DIR/bail.sh" "$@" 2>&1)"; CODE=$?; set -e; }
osa_reset
# checksum mismatch of the root owned copy: nothing installed, the download deleted, the folder gone
BPKG="$TMP_DIR/bail dl/wkhtmltox-0.12.6-2.macos-cocoa.pkg"
mkdir -p "$(dirname "$BPKG")"; printf 'not the pinned package\n' >"$BPKG"
count_root_tmp() { find /tmp -maxdepth 1 -name 'benchbar-wkhtmltopdf.*' | wc -l | tr -d ' '; }
before_tmp="$(count_root_tmp)"
reset_calls
FL_WKHTML_PKG="$BPKG" FL_WKHTML_FILE="wkhtmltox-0.12.6-2.macos-cocoa.pkg" FL_WKHTML_SHA256="0000000000000000000000000000000000000000000000000000000000000000" \
  FL_WKHTML_DOWNLOAD_DIR="$(dirname "$BPKG")" bail fl_wkhtmltopdf_install_gui
assert_contains "$OUT" "code=1"
assert_contains "$OUT" "checksum mismatch on the root owned copy"
assert_no_file "$BPKG"
assert_calls_not_contain '^installer'
assert_eq "$before_tmp" "$(count_root_tmp)" "(the root folder is removed)"
assert_eq "1" "$(osa_calls)"

# /etc/hosts: a line that is not "address names" in the result: nothing is written
osa_reset
BH="$TMP_DIR/bail hosts"
printf '127.0.0.1 localhost\n# >>> benchbar >>>\nsomehost 127.0.0.1\n# <<< benchbar <<<\n' >"$BH"
cp "$BH" "$BH.before"
FL_HOSTS_FILE="$BH" bail fl_hosts_add_gui bailsite
assert_contains "$OUT" "code=1"
assert_contains "$OUT" "address names"
assert_eq "$(cat "$BH.before")" "$(cat "$BH")" "(the address names bail leaves the file as it was)"
assert_no_file "$BH.benchbar.new"

# the line count: a script told to expect two lines while the rewrite adds one
osa_reset
printf '127.0.0.1 localhost\n# >>> benchbar >>>\n# <<< benchbar <<<\n' >"$BH"
cp "$BH" "$BH.before"
FL_HOSTS_FILE="$BH" bail wrong_delta
assert_contains "$OUT" "code=1"
assert_contains "$OUT" "expected 3 + (2) lines, the result has 4"
assert_eq "$(cat "$BH.before")" "$(cat "$BH")"
assert_no_file "$BH.benchbar.new"

# no benchbar block yet: the block is appended with the line inside
osa_reset
printf '127.0.0.1 localhost\n::1 localhost\n' >"$BH"
FL_HOSTS_FILE="$BH" bail fl_hosts_add_gui bailsite
assert_contains "$OUT" "code=0"
assert_eq "$(printf '127.0.0.1 localhost\n::1 localhost\n\n# >>> benchbar >>>\n127.0.0.1 bailsite\n# <<< benchbar <<<')" "$(cat "$BH")"
osa_reset

# a failed batch dialog is remembered: the second bench opens no dialog of its own
QA="$HOME/Qa/frappe-bench"; QB="$HOME/Qb/frappe-bench"
make_fake_bench "$QA" qalpha; make_fake_bench "$QB" qbeta
sed_inplace 's/8000/8001/; s/9000/9001/; s/11000/11001/; s/13000/13001/' "$QB/sites/common_site_config.json"
touch "$MOCK_STATE/osa_fail"
run_fm ports plan --json -- "$QA" "$QB"
token="$(printf '%s' "$OUT" | jget - 'd["token"]')"
run_fm ports apply "$token" --yes -- "$QA" "$QB"
assert_eq "1" "$(osa_calls)" "(a failed batch dialog is not repeated for a bench)"
assert_contains "$OUT" "could not write"
if grep -q 'qalpha' "$FL_HOSTS_FILE"; then fail "a failed dialog writes nothing"; fi
osa_reset

# ---- the app's fixtures (macos/BenchBarTests/Fixtures) have the keys the CLI prints, per event type
# (a fixture that is not there yet is skipped)
FIX="$ROOT/macos/BenchBarTests/Fixtures"
same_stream_keys() {
  local pattern="$1" fixtures=() f want got
  shift
  for f in "$FIX"/$pattern; do [[ -e "$f" ]] && fixtures+=("$f"); done
  [[ "${#fixtures[@]}" -gt 0 ]] || { printf 'skipped: no fixture %s yet\n' "$pattern"; return 0; }
  want="$(stream_keys "${fixtures[@]}")"; got="$(stream_keys "$@")"
  # every event and key of the fixture is still printed; new keys are fine
  local missing
  missing="$(stream_keys_missing "$want" "$got")"
  [[ -z "$missing" ]] || fail "the live stream lacks keys of $pattern:"$'\n'"${missing}"$'\n'"fixture: ${want}"$'\n'"live:    ${got}"
}
same_stream_keys 'install-stream-*.jsonl' "$TMP_DIR/stream-success.jsonl" "$TMP_DIR/stream-cancelled.jsonl" "$TMP_DIR/stream-failed.jsonl" "$TMP_DIR/stream-exit2.jsonl" "$TMP_DIR/stream-progress.jsonl"
if [[ -e "$FIX/doctor-prerequisites.json" ]]; then
  python3 -I - "$FIX/doctor-prerequisites.json" "$TMP_DIR/prereq.json" <<'PY' || fail "doctor --prerequisites --json and the app fixture disagree"
import json, sys
fixture = json.load(open(sys.argv[1])); live = json.load(open(sys.argv[2]))
assert set(live) == set(fixture), set(live) ^ set(fixture)
assert set(live["summary"]) == set(fixture["summary"])
keys = lambda d: set().union(*[set(c) for c in d["prerequisites"]])
assert keys(live) == keys(fixture), keys(live) ^ keys(fixture)
assert [c["id"] for c in live["prerequisites"]] == [c["id"] for c in fixture["prerequisites"]]
PY
else printf 'skipped: no fixture doctor-prerequisites.json yet\n'; fi

# the streams of these runs, for the app's fixtures and the docs
if [[ -n "${SAMPLE_STREAM_OUT:-}" ]]; then cat "$TMP_DIR/stream-success.jsonl" "$TMP_DIR/stream-cancelled.jsonl" "$TMP_DIR/stream-failed.jsonl" "$TMP_DIR/stream-exit2.jsonl" >"$SAMPLE_STREAM_OUT"; fi
printf 'test-install-json: ok\n'
