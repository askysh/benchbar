#!/usr/bin/env bash
# install --json without the gui mode, adopt --json, ports apply under the dialogs
# and profile list (docs/json-schema.md). Without the gui mode only the value gui
# switches to the dialogs; the stream never prompts, it uses sudo -n and skips the
# root steps with their commands, or uses a cached credential. Split
# from test-install-json.sh, which would not fit the 600 s a test may take.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=tests/lib/install-stream.sh
. "$ROOT/tests/lib/install-stream.sh"

stream_machine
BENCH="$HOME/frappe-bench"
export MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw BENCHBAR_SUDO=gui

fresh_pdf() { rm -f "$MOCK_STATE/wkhtml_installed" "$MOCK_STATE/rosetta"; touch "$MOCK_STATE/wkhtml_missing"; find "$FL_STATE_DIR/downloads" -type f -delete 2>/dev/null || true; }
# the doctor --prerequisites helpers of the first half
PRE="$TMP_DIR/pre-home"; mkdir -p "$PRE"
pre() { set +e; OUT="$(cd "$PRE" && "$FM" doctor --prerequisites --json "$@" 2>"$TMP_DIR/pre.err")"; CODE=$?; set -e; }
pq() { printf '%s' "$OUT" | python3 -I -c 'import json,re,sys; d=json.load(sys.stdin); c={x["id"]:x for x in d["prerequisites"]}; print('"$1"')'; }
printf '%s' 52428800 >"$MOCK_STATE/df_avail_kb"
export MOCK_XCODE_DIR="$TMP_DIR"
# MariaDB knows the password, as it does when the first half gets here
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"; mkdir -p "$MOCK_STATE/keychain"; printf 'rootpw\n' >"$MOCK_STATE/keychain/benchbar-mariadb--root"
osa_reset
# ---- without the gui mode, only the value gui switches to the dialogs
BENCHBAR_SUDO='' stream install --json --dry-run --bench-dir "$HOME/term-bench" --site termsite
assert_eq "terminal" "$(sx 'e[0]["sudo_mode"]')"
BENCHBAR_SUDO=other stream install --json --dry-run --bench-dir "$HOME/term-bench" --site termsite
assert_eq "terminal" "$(sx 'e[0]["sudo_mode"]')"
assert_eq "0" "$(osa_calls)"

# ---- without the gui mode the stream never prompts: sudo -n only, else the steps are skipped
fresh_pdf; osa_reset
unset BENCHBAR_SUDO
rm -f "$MOCK_STATE/sudo_cred"
reset_calls
stream install --json --yes --bench-dir "$HOME/nogui-bench" --site noguisite
assert_eq "0" "$CODE" "$(cat "$STREAM.err")"
assert_eq "terminal" "$(sx 'e[0]["sudo_mode"]')"
assert_eq "wkhtmltopdf_install hosts_entry" "$(sx '" ".join(s["id"] for s in e[-1]["skipped"])')"
assert_contains "$(sx 'e[-1]["skipped"][0]["command"]')" "sudo installer -pkg"
assert_contains "$(sx 'e[-1]["skipped"][1]["command"]')" "site hosts --bench-dir"
assert_eq "skipped skipped" "$(sx '" ".join(x["status"] for x in e if x.get("id") in ("wkhtmltopdf_install","hosts_entry") and x["status"]=="skipped")')"
assert_eq "0" "$(osa_calls)"
# only the probe: nothing that could ask for a password (sudo -v, sudo CMD) was run
if grep '^sudo ' "$MOCK_LOG" | grep -v -x 'sudo -n true' | grep -q .; then fail "the stream must not run sudo beyond the probe: $(grep '^sudo ' "$MOCK_LOG")"; fi
# a cached credential works without asking
fresh_pdf; touch "$MOCK_STATE/sudo_cred"
stream install --json --yes --bench-dir "$HOME/nogui-bench2" --site nogui2
assert_eq "0" "$CODE"
assert_eq "[]" "$(sx 'e[-1]["skipped"]')"
assert_calls_contain '^sudo installer -pkg'
grep -qx '127.0.0.1 nogui2' "$FL_HOSTS_FILE" || fail "the hosts line with a cached credential"
export BENCHBAR_SUDO=gui

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

# every check that is not ok names its fix, and the exit code follows the fails
FL_ARCH=x86_64 pre; assert_eq "fail 1 BenchBar needs an Apple Silicon Mac" "$(pq 'c["apple_silicon"]["level"]') $CODE $(pq 'c["apple_silicon"]["fix_command"]')"
MOCK_SW_VERS=13.4 pre; assert_eq "update macOS in System Settings, Software Update" "$(pq 'c["macos_version"]["fix_command"]')"
printf '%s' 5242880 >"$MOCK_STATE/df_avail_kb"; pre; assert_eq "free space on the volume of $HOME" "$(pq 'c["disk_free"]["fix_command"]')"
printf '%s' 52428800 >"$MOCK_STATE/df_avail_kb"
pre --bench-dir "$HOME/Desktop/x"; assert_eq "choose a folder outside iCloud Drive, Desktop and Documents, such as ~/frappe-bench" "$(pq 'c["bench_folder"]["fix_command"]')"
add_listener 8000 4242 ForeignApp
pre; assert_eq "True" "$(pq 're.fullmatch(r"the new bench gets port block (\d+) \(--port-offset \1\)", c["default_ports"]["fix_command"]) is not None')"
printf '3306 111 mariadbd 127.0.0.1\n' >"$MOCK_LISTEN"
mkdir -p "$HOME/Applications/CleanMyMac X.app"; pre
assert_eq "True" "$(pq 'all(x["level"] == "ok" or bool(x["fix_command"]) for x in d["prerequisites"])')"
rmdir "$HOME/Applications/CleanMyMac X.app"
# plain text and the bench's doctor
run_fm doctor --prerequisites --bench-dir "$HOME/pre-x"
assert_contains "$OUT" "PREREQUISITES"; assert_contains "$OUT" "[OK] Apple Silicon: arm64"
run_fm doctor --bench-dir "$PA"
assert_not_contains "$OUT" "PREREQUISITES" "(a plain doctor keeps its fix line promise: no prerequisites group)"
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

# ---- the app's fixtures for adopt's stream
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
same_stream_keys 'adopt-stream-*.jsonl' "$TMP_DIR/stream-adopt.jsonl"

if [[ -n "${SAMPLE_STREAM_OUT:-}" ]]; then cat "$TMP_DIR/stream-adopt.jsonl" >"${SAMPLE_STREAM_OUT}.adopt"; fi
printf 'test-install-json-2: ok\n'
