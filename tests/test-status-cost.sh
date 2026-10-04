#!/usr/bin/env bash
# What one status --json or list --json costs. The app runs them for every
# bench on a timer, so a process here is a process on every poll. The mock
# call log counts the mocked programs (lsof, launchctl, curl, pgrep, brew,
# pipx); shims count every other external program benchbar starts.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# calls NAME: how often NAME ran since the last reset_calls
calls() { grep -c -E "^$1( |\$)" "$MOCK_LOG" || true; }
# budget NAME MAX WHAT: NAME ran at most MAX times
budget() {
  local n
  n="$(calls "$1")"
  [[ "$n" -le "$2" ]] || fail "$3: $1 ran $n times, budget $2"$'\n'"$(cat "$MOCK_LOG")"
}
# execs: every program benchbar started, mocked or shimmed, except its own
# interpreter (env and bash from the shebang). mockkill stands in for the
# kill builtin, which starts nothing outside the tests.
execs() { grep -v -c -E '^mockkill ' "$MOCK_LOG" || true; }
# summary: "curl 1, launchctl 1" for the output of the test
summary() { awk '{ print ($1 == "exec") ? $2 : $1 }' "$MOCK_LOG" | sort | uniq -c | awk '{ printf "%s%s %s", (NR > 1 ? ", " : ""), $2, $1 }'; }
# status_of FIELDS...: the named fields of the last status JSON, space separated
status_of() { printf '%s' "$OUT" | jget - "$1" | tr -d "(),'"; }

# shims: log "exec NAME" and run the real program. Programs a mock starts
# are not logged (every mock sources _mocklib.sh, which exports
# BENCHBAR_TEST_MOCK). A mock calls dirname on its own path before that,
# so dirname skips paths of the mocks.
SHIMS="$TMP_DIR/shims"
mkdir -p "$SHIMS"
for n in sed awk tr head tail cut sort uniq grep cat cksum basename dirname id uname shasum date readlink wc mktemp mv rm cp ls stat touch mkdir find xargs sleep python3 perl ruby; do
  real="$(command -v "$n" 2>/dev/null)" || continue
  cat >"$SHIMS/$n" <<SHIM
#!/bin/bash
if [[ -z "\${BENCHBAR_TEST_MOCK:-}" && "$n \${1:-}" != "dirname $ROOT/tests/mocks/bin/"* ]]; then printf 'exec %s\n' "$n" >>"\$MOCK_LOG"; fi
exec "$real" "\$@"
SHIM
  chmod +x "$SHIMS/$n"
done
# shimmed CMD ARGS...: runs a command with the shims first on PATH
shimmed() {
  local saved="$PATH"
  PATH="$SHIMS:$PATH"
  "$@"
  PATH="$saved"
}

# two benches that only registration finds (not under ~ or ~/dev), two sites each
BENCH="$HOME/work/a/frappe-bench"
OTHER="$HOME/work/b/second"
make_fake_bench "$BENCH" macdev
make_fake_bench "$OTHER" secondsite
sed_inplace 's/"webserver_port": 8000/"webserver_port": 8001/; s/"socketio_port": 9000/"socketio_port": 9001/' "$OTHER/sites/common_site_config.json"
for b in "$BENCH" "$OTHER"; do
  mkdir -p "$b/sites/two.localhost"
  printf '{}\n' >"$b/sites/two.localhost/site_config.json"
done
printf '127.0.0.1 macdev secondsite two.localhost\n' >>"$FL_HOSTS_FILE"
run_fm register "$BENCH" "$OTHER"
assert_eq "0" "$CODE" "$OUT"
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
label="$("$FM" status --json --bench-dir "$BENCH" 2>/dev/null | jget - 'd["label"]')"
assert_eq "com.benchbar.frappe-bench" "$label"

# write_state STATE PID: state.json as the runner writes it
write_state() {
  mkdir -p "$BENCH/logs/.benchbar"
  printf '{"schema_version":1,"cli_version":"%s","bench":"%s","name":"frappe-bench","site":"macdev","label":"%s","state":"%s","stop_reason":null,"pid":%s,"started_at":"2026-09-30T05:00:00Z","last_exit_code":null,"web_url":"http://macdev:8000","web_ping_code":200,"updated_at":"2026-09-30T05:00:04Z","source":"runner"}\n' \
    "$VER" "$BENCH" "$label" "$1" "$2" >"$BENCH/logs/.benchbar/state.json"
}
# a Homebrew Python re-executes itself: serve's command line starts with the
# framework's interpreter, and it runs in the bench's sites folder
PYFW="/opt/homebrew/Cellar/python@3.11/3.11.16/Frameworks/Python.framework/Versions/3.11/Resources/Python.app/Contents/MacOS/Python"

# ---- running under its agent, as the runner leaves it: state.json names the
# runner, launchd runs that pid, honcho and its children listen
rm -f "$BENCH/logs/.bench-stopped"
set_agent "$label" running 4241 0
add_proc 4241 "/bin/bash $BENCH/benchbar-run.sh" "$BENCH"
add_proc 4242 "honcho start -f Procfile.lean" "$BENCH"
add_proc 4243 "$PYFW -m frappe.utils.bench_helper frappe serve --port 8000 --noreload" "$BENCH/sites"
add_proc 4244 "node apps/frappe/socketio.js" "$BENCH"
add_proc 4245 "redis-server config/redis_queue.conf" "$BENCH"
add_proc 4246 "redis-server config/redis_cache.conf" "$BENCH"
add_listener 8000 4243 python
add_listener 9000 4244 node
add_listener 11000 4245 redis-server
add_listener 13000 4246 redis-server
write_state running 4241
export MOCK_CURL_CODE=200

reset_calls
shimmed run_fm status --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "running 4241 200 True True running" \
  "$(status_of 'd["state"], d["pid"], d["web_ping_code"], d["processes_running"], d["agent_loaded"], d["agent_state"]')"
# without --ping no site is asked beyond the default's web_ping_code
assert_eq "macdev:True:True:None two.localhost:False:True:None" \
  "$(printf '%s' "$OUT" | jget - '" ".join("%s:%s:%s:%s" % (s["name"], s["default"], s["hosts_entry"], s["ping_code"]) for s in d["sites"])')"
# the runner and launchd agree: no process scan at all (the brief's budget is
# at most one of each; the trusted path needs none)
budget lsof 0 "status, running"
budget pgrep 0 "status, running"
budget launchctl 1 "status, running"
budget curl 1 "status, running"
budget brew 0 "status, running"
budget pipx 0 "status, running"
# 12 with env and bash, which start every command; today cksum, curl,
# launchctl and sort (two sites)
[[ "$(execs)" -le 5 ]] || fail "status, running: $(execs) programs started, budget 5"$'\n'"$(cat "$MOCK_LOG")"
assert_calls_not_contain '^exec (python3|perl|ruby|shasum|uname|dirname|sed|awk|tr|head|tail|basename|grep|cat|id)( |$)'
printf 'status --json, running: %s programs (%s)\n' "$(execs)" "$(summary)"
checkout_programs="$(summary)"

# ---- the same status from a Homebrew CLI (a keg copy run by its opt path,
# its state folder ~/.local/state/benchbar, here a link to the pinned one,
# the bench its remembered default; the installer's folder is there too,
# its state moved): the install kind and the state folder start no program
KEG="$MOCK_BREW_PREFIX/Cellar/benchbar/$VER"
mkdir -p "$KEG/libexec" "$HOME/.local/state" "$HOME/.local/share/benchbar"
cp -R "$ROOT/benchbar" "$ROOT/lib" "$ROOT/templates" "$ROOT/config" "$KEG/libexec/"
ln -sfn "../Cellar/benchbar/$VER" "$MOCK_BREW_PREFIX/opt/benchbar"
ln -s "$FL_STATE_DIR" "$HOME/.local/state/benchbar"
ln -s "$HOME/.local/state/benchbar" "$HOME/.local/share/benchbar/.benchbar"
reset_calls
set +e
OUT="$(PATH="$SHIMS:$PATH" env -u FL_STATE_DIR -u FL_STATE_FILE -u FL_BACKUP_ROOT \
  "$MOCK_BREW_PREFIX/opt/benchbar/libexec/benchbar" status --json 2>&1)"; CODE=$?
set -e
assert_eq "0" "$CODE" "$OUT"
assert_eq "$BENCH running 4241" "$(status_of 'd["bench"], d["state"], d["pid"]')"
assert_eq "$checkout_programs" "$(summary)" "(a Homebrew CLI's status starts the same programs)"
rm -f "$HOME/.local/state/benchbar"; rm -rf "$HOME/.local/share/benchbar"

# ---- --ping asks every site once: the default site's ping is reused
reset_calls
run_fm status --json --ping --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "macdev:200 two.localhost:200" \
  "$(printf '%s' "$OUT" | jget - '" ".join("%s:%s" % (s["name"], s["ping_code"]) for s in d["sites"])')"
assert_eq "2" "$(calls curl)" "status --ping pings each site once"
assert_calls_contain '^curl .*-H Host: two\.localhost '

# ---- launchd runs another pid than state.json names: state.json is stale,
# so one scan decides, and the pid is launchd's
set_agent "$label" running 4240 0
reset_calls
run_fm status --json --bench-dir "$BENCH"
assert_eq "running 4240 True" "$(status_of 'd["state"], d["pid"], d["processes_running"]')"
assert_eq "1" "$(calls pgrep)" "a state.json launchd disagrees with takes one scan"
budget lsof 1 "status, stale state.json"
set_agent "$label" running 4241 0

# ---- no state.json (a runner from before 0.3, or benchbar fg): one pgrep for
# the bench's processes and one lsof for all their folders, never one per pid
rm -f "$BENCH/logs/.benchbar/state.json"
reset_calls
run_fm status --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "running 4241 True" "$(status_of 'd["state"], d["pid"], d["processes_running"]')"
budget pgrep 1 "status, no state.json"
budget lsof 1 "status, no state.json"
budget curl 1 "status, no state.json"
assert_calls_not_contain '^lsof .*tcp:'

# ---- a state.json whose runner is gone counts for nothing
printf '{"state":"running","pid":999999}\n' >"$BENCH/logs/.benchbar/state.json"
: >"$MOCK_PROCS"
set_agent "$label" "not running" "" 0
reset_calls
run_fm status --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "stopped False None" "$(status_of 'd["state"], d["processes_running"], d["web_ping_code"]')"
budget curl 0 "status, stopped"
budget lsof 0 "status, stopped"
budget pgrep 1 "status, stopped"

# ---- no agent, no honcho: a serve started by hand still reads as running,
# found by its folder (sites/ of this bench), not by its interpreter's path;
# another bench's serve does not count
rm -f "$BENCH/logs/.benchbar/state.json"
add_proc 5001 "$PYFW -m frappe.utils.bench_helper frappe serve --port 8000" "$BENCH/sites"
add_proc 5002 "$PYFW -m frappe.utils.bench_helper frappe serve --port 8001" "$OTHER/sites"
add_proc 5003 "node apps/frappe/socketio.js" "$OTHER"
add_listener 8000 5001 python
reset_calls
run_fm status --json --bench-dir "$BENCH"
assert_eq "running 5001 True" "$(status_of 'd["state"], d["pid"], d["processes_running"]')"
budget pgrep 1 "status, serve by hand"
budget lsof 1 "status, serve by hand"
{ grep -v -E '^5001 ' "$MOCK_PROCS" || true; } >"$MOCK_PROCS.tmp"; mv "$MOCK_PROCS.tmp" "$MOCK_PROCS"
run_fm status --json --bench-dir "$BENCH"
assert_eq "stopped False" "$(status_of 'd["state"], d["processes_running"]')"
# a candidate whose folder lsof does not report (it exited between pgrep
# and lsof, or another bench's) is not this bench's: status keeps only
# pids proven to run inside the bench
add_proc 5004 "honcho start -f Procfile.lean"
run_fm status --json --bench-dir "$BENCH"
assert_eq "stopped False" "$(status_of 'd["state"], d["processes_running"]')" "(an unproven pid does not make the bench run)"
{ grep -v -E '^5004 ' "$MOCK_PROCS" || true; } >"$MOCK_PROCS.tmp"; mv "$MOCK_PROCS.tmp" "$MOCK_PROCS"

# ---- the pid of a bench without its agent is honcho's, the root of the
# tree the app samples, even with a lower serve pid
add_proc 5100 "$PYFW -m frappe.utils.bench_helper frappe worker --queue default" "$BENCH/sites"
add_proc 5105 "honcho start -f Procfile.lean" "$BENCH"
run_fm status --json --bench-dir "$BENCH"
assert_eq "running 5105" "$(status_of 'd["state"], d["pid"]')"

# ---- list --json: two benches, nothing pinged, nothing looked up in launchd
reset_calls
shimmed run_fm list --json
assert_eq "0" "$CODE" "$OUT"
assert_eq "2" "$(printf '%s' "$OUT" | jget - 'len(d["benches"])')"
assert_eq "None None None None" "$(printf '%s' "$OUT" | jget - '" ".join(str(s["ping_code"]) for b in d["benches"] for s in b["sites"])')"
assert_eq "True True True True" "$(printf '%s' "$OUT" | jget - '" ".join(str(s["hosts_entry"]) for b in d["benches"] for s in b["sites"])')"
budget lsof 0 "list"
budget curl 0 "list"
budget launchctl 0 "list"
budget pgrep 0 "list"
[[ "$(execs)" -le 6 ]] || fail "list: $(execs) programs started, budget 6"$'\n'"$(cat "$MOCK_LOG")"
printf 'list --json, 2 benches: %s programs (%s)\n' "$(execs)" "$(summary)"

# ---- site list --json still asks every site, as before
: >"$MOCK_PROCS"
add_proc 4243 "$PYFW -m frappe.utils.bench_helper frappe serve --port 8000 --noreload" "$BENCH/sites"
reset_calls
run_fm site list --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "macdev:200 two.localhost:200" \
  "$(printf '%s' "$OUT" | jget - '" ".join("%s:%s" % (s["name"], s["ping_code"]) for s in d["sites"])')"

# ---- the bash readers give the bytes the tools they replaced gave: a
# different bench name or regex would rename state files and mark every
# rendered runner outdated. Both locales, since bash ranges follow them.
cat >"$TMP_DIR/wd-inline.plist" <<'PLIST'
<dict>
  <key>Label</key><string>com.benchbar.x</string>
  <key>WorkingDirectory</key><string>/Users/a b/dev/frappe-bench</string>
</dict>
PLIST
cat >"$TMP_DIR/wd-next.plist" <<'PLIST'
<dict>
  <key>WorkingDirectory</key>
  <string>/Users/someone/work/bench &amp; co</string>
</dict>
PLIST
cat >"$TMP_DIR/scc.json" <<'JSON'
{
 "background_workers": 1,
 "default_site": "macdev",
 "nested": {"webserver_port": 1},
 "redis_cache": "redis://127.0.0.1:13000",
 "socketio_port": 9000,
 "webserver_port": 8000
}
JSON
export ROOT TMP_DIR FL_STATE_DIR
for loc in en_US.UTF-8 C; do
  # the names a non-ASCII folder had in 0.6.0 on macOS, whose tr reads
  # characters in UTF-8 and bytes in C (GNU tr would give bytes in both)
  if [[ "$loc" == C ]]; then names='b--nch-dir.x_y-Z-1|------'; else names='b-nch-dir.x_y-Z-1|--'; fi
  NAMES="$names" SCRIPT_DIR="$ROOT" LC_ALL="$loc" LANG="$loc" bash -c '
    set -euo pipefail
    . "$ROOT/lib/frappe-local/ui.sh"; . "$ROOT/lib/frappe-local/state.sh"; . "$ROOT/lib/frappe-local/benchinfo.sh"
    . "$ROOT/lib/frappe-local/process.sh"; . "$ROOT/lib/frappe-local/doctor.sh"; . "$ROOT/lib/frappe-local/launchd.sh"
    for s in "/Users/a b/[x](y).z*+?^\$|{}\\q" "/Users/akash/dev/frappe-bench" "/x/bénch/日本"; do
      [[ "$(fl_regex_escape "$s")" == "$(printf "%s" "$s" | sed -e "s/[][\\.*^\$+?(){}|\\\\]/\\\\&/g")" ]] || { echo "regex escape differs for $s"; exit 1; }
    done
    # the reference: the sed | tr the bash reader replaced, with a whole terminal
    # control sequence removed first (0.7.3: the ESC no longer goes alone); the
    # byte ranges of that sed need the C locale
    esc="$(printf "\\033")"
    for s in "a\\b\"c" $'"'"'tab\there\nnl\x1b[0m'"'"' "é日本 plain"; do
      [[ "$(fl_json_escape "$s")" == "$(printf "%s" "$s" | sed -e "s/\\\\/\\\\\\\\/g" -e "s/\"/\\\\\"/g" | LC_ALL=C sed -e "s#${esc}\\[[0-?]*[ -/]*[@-~]##g" | tr -d "\\000-\\037")" ]] || { echo "json escape differs for $s"; exit 1; }
    done
    # a colored 20 KB log line (logs --json escapes every line): linear, not quadratic
    long="$(printf "%0.s[x]" $(seq 1 5000))"$'"'"'\x1b[0m end\x01'"'"'
    SECONDS=0
    [[ "$(fl_json_escape "$long")" == "$(printf "%s" "$long" | LC_ALL=C sed -e "s#${esc}\\[[0-?]*[ -/]*[@-~]##g" | tr -d "\\000-\\037")" ]] || { echo "json escape differs for a long line"; exit 1; }
    [[ "$SECONDS" -le 2 ]] || { echo "json escape of a 20 KB line took ${SECONDS}s"; exit 1; }
    for s in "/x/a[b]c/" "/x/frappe-bench" "/Users/a b/dev/My Bench"; do
      [[ "$(fl_bench_name_of "$s")" == "$(basename "$s" | tr -c "A-Za-z0-9._\\n-" "-")" ]] || { echo "bench name differs for $s"; exit 1; }
    done
    [[ "$(fl_bench_name_of "/x/bénch dir.x_y-Z@1")|$(fl_bench_name_of "/x/日本")" == "$NAMES" ]] || { echo "non-ASCII bench names differ"; exit 1; }
    for f in "$TMP_DIR/wd-inline.plist" "$TMP_DIR/wd-next.plist"; do
      [[ "$(fl_plist_working_dir "$f")" == "$(awk "/<key>WorkingDirectory<\\/key>/ { l = \$0; if (l !~ /<string>/) getline l; sub(/.*<string>/, \"\", l); sub(/<\\/string>.*/, \"\", l); print l; exit }" "$f")" ]] || { echo "plist folder differs for $f"; exit 1; }
    done
    mkdir -p "$TMP_DIR/scc/sites"; cp "$TMP_DIR/scc.json" "$TMP_DIR/scc/sites/common_site_config.json"; FL_BENCH_DIR="$TMP_DIR/scc"
    for k in default_site redis_cache socketio_port webserver_port background_workers missing; do
      for FL_CONTEXT_LIGHT in 0 1; do
        fl_site_config_prime
        [[ "$(fl_site_config_value "$k")" == "$(sed -n "s/^[[:space:]]*\"${k}\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}[[:space:]]*\$/\1/p" "$TMP_DIR/scc.json" | head -n1)" ]] || { echo "config value differs for $k (light $FL_CONTEXT_LIGHT)"; exit 1; }
      done
    done
  ' || fail "a bash reader differs from the tool it replaced ($loc)"
done

printf 'test-status-cost: ok\n'
