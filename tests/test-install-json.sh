#!/usr/bin/env bash
# install --json and adopt --json (docs/json-schema.md): the stream's event
# order, ids and parents, a failed step, exit 2, refusals, a cancelled or
# failed macOS password dialog, one dialog per privileged step with
# awkward paths, progress lines, doctor --prerequisites and profile list.
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
pq() { printf '%s' "$OUT" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); c={x["id"]:x for x in d["prerequisites"]}; print('"$1"')'; }
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

# a second install changes nothing and asks nothing
osa_reset
stream install --json --yes --bench-dir "$BENCH" --site macdev
assert_eq "0" "$CODE"
assert_eq "0" "$(osa_calls)"
assert_eq "False False" "$(sx '" ".join(str(s["will_run"]) for s in e[0]["steps"][:2])')"


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

# ---- without the gui mode, only the value gui switches to the dialogs
BENCHBAR_SUDO='' stream install --json --dry-run --bench-dir "$HOME/term-bench" --site termsite
assert_eq "terminal" "$(sx 'e[0]["sudo_mode"]')"
BENCHBAR_SUDO=other stream install --json --dry-run --bench-dir "$HOME/term-bench" --site termsite
assert_eq "terminal" "$(sx 'e[0]["sudo_mode"]')"
assert_eq "0" "$(osa_calls)"

# ---- adopt --json
AB="$HOME/adopt-bench"
make_fake_bench "$AB" adoptsite
stream adopt "$AB" --json
assert_eq "1" "$CODE"
assert_eq "done" "$(sx '" ".join(x["event"] for x in e)')"
assert_contains "$(sx 'e[0]["error"]')" "needs --yes"
assert_eq "$AB" "$(sx 'e[0]["bench"]')"
assert_no_file "$AB/Procfile.lean"
stream adopt "$AB" --json --dry-run
assert_eq "0" "$CODE" "$(cat "$STREAM.err")"
assert_eq "plan done" "$(sx '" ".join(x["event"] for x in e)')"
assert_no_file "$AB/Procfile.lean"
osa_reset
stream adopt "$AB" --json --yes
assert_eq "0" "$CODE" "$(cat "$STREAM.err")$(tail -n 20 "$(sx 'e[-1]["log"]')")"
assert_eq "plan" "$(sx 'e[0]["event"]')"
assert_eq "False gui $AB adoptsite" "$(sx '" ".join(str(e[0][k]) for k in ("ports_move","sudo_mode","bench","site"))')"
assert_eq "True" "$(sx '[s["n"] for s in e[0]["steps"]] == list(range(1, len(e[0]["steps"]) + 1)) and {"write_procfile","hosts_entry"} <= {s["id"] for s in e[0]["steps"]}')"
assert_eq "True" "$(sx '[s["sudo"] for s in e[0]["steps"] if s["id"]=="hosts_entry"] == [True]')"
assert_eq "True" "$(sx 'all(x["parent"] is None and isinstance(x["n"], int) for x in e if x["event"]=="step")')"
assert_eq "hosts_entry:done" "$(sx '[x["id"]+":"+x["status"] for x in e if x["event"]=="step" and x["id"]=="hosts_entry"][-1]')"
assert_eq "1" "$(osa_calls)"
assert_eq "0 http://adoptsite:8000 []" "$(sx '" ".join(str(e[-1][k]) for k in ("exit","url","skipped"))')"
assert_file "$AB/Procfile.lean"
cp "$STREAM" "$TMP_DIR/stream-adopt.jsonl"
# a cancelled dialog in adopt: skipped with its command, adopt still ends 0
AC="$HOME/adopt-bench2"
make_fake_bench "$AC" adopttwo
osa_reset; touch "$MOCK_STATE/osa_cancel_all"
stream adopt "$AC" --json --yes
assert_eq "0" "$CODE"
assert_eq "skipped" "$(sx '[x["status"] for x in e if x.get("id")=="hosts_entry"][-1]')"
assert_eq "hosts_entry" "$(sx '" ".join(s["id"] for s in e[-1]["skipped"])')"
osa_reset

# ---- ports apply under BENCHBAR_SUDO=gui: one dialog for the hosts lines of every bench
PA="$HOME/Pa A/frappe-bench"; PB="$HOME/Pb B/frappe-bench"
make_fake_bench "$PA" palpha; make_fake_bench "$PB" pbeta
sed_inplace 's/8000/8001/; s/9000/9001/; s/11000/11001/; s/13000/13001/' "$PB/sites/common_site_config.json"
unset MARIADB_ROOT_PASSWORD ADMIN_PASSWORD
run_fm ports plan --json -- "$PA" "$PB"
assert_eq "0" "$CODE" "$OUT"
token="$(printf '%s' "$OUT" | jget - 'd["token"]')"
run_fm ports apply "$token" --yes -- "$PA" "$PB"
assert_eq "0" "$CODE" "$OUT"
assert_eq "1" "$(osa_calls)" "(one dialog for two benches)"
if grep -qx '127.0.0.1 palpha' "$FL_HOSTS_FILE" && grep -qx '127.0.0.1 pbeta' "$FL_HOSTS_FILE"; then :; else fail "both hosts lines"; fi
assert_eq "Add 127.0.0.1 lines for 2 sites to /etc/hosts" "$(sed -n 1p "$MOCK_STATE/osa_reasons")"
# cancelled: both benches are set up, the lines are missing, each step names its command, one dialog
sed_inplace '/palpha/d; /pbeta/d' "$FL_HOSTS_FILE"
osa_reset; touch "$MOCK_STATE/osa_cancel_all"
run_fm ports plan --json -- "$PA" "$PB"
token="$(printf '%s' "$OUT" | jget - 'd["token"]')"
run_fm ports apply "$token" --yes -- "$PA" "$PB"
assert_eq "0" "$CODE" "$OUT"
assert_eq "1" "$(osa_calls)" "(a cancelled dialog is not asked again for the second bench)"
assert_contains "$OUT" "the password dialog was cancelled"
assert_contains "$OUT" "site hosts --bench-dir ${PA}"
assert_contains "$OUT" "site hosts --bench-dir ${PB}"
if grep -q 'palpha' "$FL_HOSTS_FILE"; then fail "no line without the password"; fi
osa_reset
unset BENCHBAR_SUDO

# plain text, and the group in a bench's doctor
run_fm doctor --prerequisites --bench-dir "$HOME/pre-x"
assert_contains "$OUT" "PREREQUISITES"; assert_contains "$OUT" "[OK] Apple Silicon: arm64"
run_fm doctor --bench-dir "$PA"
case "$OUT" in *PREREQUISITES*) ;; *) fail "doctor prints the prerequisites first" ;; esac
run_fm doctor --json --bench-dir "$PA"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'len(d["prerequisites"]) == 9 and sum(d["summary"].values()) == len(d["checks"])')"
# Linux: only the checks that mean something there
( use_linux; pre
  assert_eq "disk_free bench_folder default_ports" "$(pq '" ".join(x["id"] for x in d["prerequisites"])')" ) || exit 1
unset MOCK_XCODE_DIR

# ---- profile list: the versions each profile brings, and the bundles
run_fm profile list --json
assert_eq "0" "$CODE" "$OUT"
assert_eq "3.11 22 10.11" "$(printf '%s' "$OUT" | jget - '" ".join(next(p[k] for p in d["profiles"] if p["name"]=="v15-lts") for k in ("python","node","mariadb"))')"
assert_eq "3.14 24 11.8" "$(printf '%s' "$OUT" | jget - '" ".join(next(p[k] for p in d["profiles"] if p["name"]=="v16-lts") for k in ("python","node","mariadb"))')"
assert_eq "minimal common extended" "$(printf '%s' "$OUT" | jget - '" ".join(b["name"] for b in d["bundles"])')"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["bundles"][0]["apps"] == ["erpnext"] and set(d["bundles"][0]) == {"name","label","apps","description"}')"
mkdir -p "$HOME/.config/benchbar/profiles"
printf 'schema = 1\nbase = "v16-lts"\nbundle = "minimal"\n' >"$HOME/.config/benchbar/profiles/acme.toml"
printf 'base = "v15-lts"\nbogus = 1\n' >"$HOME/.config/benchbar/profiles/broken.toml"
run_fm profile list --json
assert_eq "3.14 24 11.8 True" "$(printf '%s' "$OUT" | jget - '" ".join(str(next(p[k] for p in d["profiles"] if p["name"]=="acme")) for k in ("python","node","mariadb","valid"))')"
assert_eq "None None None False" "$(printf '%s' "$OUT" | jget - '" ".join(str(next(p[k] for p in d["profiles"] if p["name"]=="broken")) for k in ("python","node","mariadb","valid"))')"

# ---- the app's fixtures (macos/BenchBarTests/Fixtures) have the keys the CLI prints, per event type
# (a fixture that is not there yet is skipped)
FIX="$ROOT/macos/BenchBarTests/Fixtures"
same_stream_keys() {
  local pattern="$1" fixtures=() f want got
  shift
  for f in "$FIX"/$pattern; do [[ -e "$f" ]] && fixtures+=("$f"); done
  [[ "${#fixtures[@]}" -gt 0 ]] || { printf 'skipped: no fixture %s yet\n' "$pattern"; return 0; }
  want="$(stream_keys "${fixtures[@]}")"; got="$(stream_keys "$@")"
  [[ "$want" == "$got" ]] || fail "the keys of $pattern and the live stream differ:"$'\n'"fixture: ${want}"$'\n'"live:    ${got}"
}
same_stream_keys 'install-stream-*.jsonl' "$TMP_DIR/stream-success.jsonl" "$TMP_DIR/stream-cancelled.jsonl" "$TMP_DIR/stream-failed.jsonl" "$TMP_DIR/stream-exit2.jsonl" "$TMP_DIR/stream-progress.jsonl"
same_stream_keys 'adopt-stream-*.jsonl' "$TMP_DIR/stream-adopt.jsonl"
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
if [[ -n "${SAMPLE_STREAM_OUT:-}" ]]; then cat "$TMP_DIR/stream-success.jsonl" "$TMP_DIR/stream-cancelled.jsonl" "$TMP_DIR/stream-failed.jsonl" "$TMP_DIR/stream-exit2.jsonl" "$TMP_DIR/stream-adopt.jsonl" >"$SAMPLE_STREAM_OUT"; fi
printf 'test-install-json: ok\n'
