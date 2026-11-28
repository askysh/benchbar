#!/usr/bin/env bash
# The web server and socketio listen on 127.0.0.1 by default (SVC-2, SHARE-1, issue 117), with a
# per bench switch back (benchbar listen all), and doctor warns about a bench on every interface.
# The two start files are run for real (python3 with a stand-in werkzeug, node with a real socket
# on an ephemeral loopback port): what they do to the address is the whole point of the change.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH"
mkdir -p "$HOME/Library/LaunchAgents"

# ---- a new service: Procfile.lean starts the web and socketio lines through the listen files
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
procfile="$BENCH/Procfile.lean"
# shellcheck disable=SC2016  # the text of the Procfile line, not a shell expansion
web_env_start='PYTHONPATH="$PWD/config/benchbar-listen'
listen_dir="$BENCH/config/benchbar-listen"
assert_file "$listen_dir/sitecustomize.py"
assert_file "$listen_dir/socketio.js"
web_line="$(grep '^web: ' "$procfile")"
socketio_line="$(grep '^socketio: ' "$procfile")"
# shellcheck disable=SC2016  # the text of the Procfile line, not a shell expansion
assert_contains "$web_line" 'PYTHONPATH="$PWD/config/benchbar-listen${PYTHONPATH:+:$PYTHONPATH}" bench serve --port 8000'
# shellcheck disable=SC2016
assert_contains "$socketio_line" 'NODE_OPTIONS="--require \"$PWD/config/benchbar-listen/socketio.js\" ${NODE_OPTIONS:-}" bench socketio'
grep -q 'benchbar-template: Procfile.lean v2 ' "$procfile" || fail "Procfile.lean must carry the v2 header"
grep -q 'benchbar-template: listen-sitecustomize.py v1 ' "$listen_dir/sitecustomize.py" || fail "sitecustomize.py needs its header"
grep -q 'benchbar-template: listen-socketio.js v1 ' "$listen_dir/socketio.js" || fail "socketio.js needs its header"
assert_eq "worker: bench worker 1>> logs/worker.log 2>> logs/worker.error.log" "$(grep '^worker: ' "$procfile")"

# status and doctor: local, nothing exposed
run_fm status --json --bench-dir "$BENCH"
assert_eq "local" "$(printf '%s' "$OUT" | jget - 'd["listen"]')"
run_fm listen --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "listen is local"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[OK] Procfile.lean: Procfile.lean and its listen files are current"
assert_contains "$OUT" "[OK] Listen address: the web server and socketio start on 127.0.0.1 only"

# ---- what the two files do, run for real
# honcho runs a Procfile line with the bench folder as the working directory, but "bench serve" then
# changes into sites/ (bench/cli.py) before it starts the dev server, so the files must be found
# from there too. in_sites stands for that: the env prefix of the line is evaluated in DIR (default
# the bench), the command it prefixes then starts in DIR/sites.
mkdir -p "$BENCH/sites"
printf '#!/usr/bin/env bash\ncd sites || exit 1\nexec "$@"\n' >"$TMP_DIR/in-sites.sh"
# run_line PREFIX CMD...: PREFIX is what comes before "bench serve" or "bench socketio" in the Procfile line
run_line() {
  local prefix="$1"; shift
  (cd "${LINE_DIR:-$BENCH}" && bash -c "${prefix}\"\$@\"" _ bash "$TMP_DIR/in-sites.sh" "$@")
}
# the web line: a python3 that calls run_simple the way frappe.app.serve does
stub="$TMP_DIR/werkzeug-stub"
mkdir -p "$stub/werkzeug"
: >"$stub/werkzeug/__init__.py"
cat >"$stub/werkzeug/serving.py" <<'PY'
def run_simple(hostname, port, application, **kwargs):
    print("run_simple", hostname, port, application, sorted(kwargs.items()))
PY
web_prefix="${web_line#web: }"
web_prefix="${web_prefix%bench serve*}"
call_serve='import werkzeug.serving as s; s.run_simple("0.0.0.0", 8000, "app", use_debugger=True, use_reloader=False)'
out="$(PYTHONPATH="$stub" run_line "$web_prefix" python3 -c "$call_serve")"
assert_eq "run_simple 127.0.0.1 8000 app [('use_debugger', True), ('use_reloader', False)]" "$out" "(from sites/: 0.0.0.0 becomes 127.0.0.1, every other argument stays)"
# a host that is not a wildcard is left alone, and without the prefix nothing changes
out="$(PYTHONPATH="$stub" run_line "$web_prefix" python3 -c 'import werkzeug.serving as s; s.run_simple("192.0.2.7", 1, "a")')"
assert_eq "run_simple 192.0.2.7 1 a []" "$out"
out="$(PYTHONPATH="$stub" run_line "" python3 -c "$call_serve")"
assert_eq "run_simple 0.0.0.0 8000 app [('use_debugger', True), ('use_reloader', False)]" "$out" "(no prefix, no change)"
# a Python without werkzeug starts as it always did
out="$(run_line "$web_prefix" python3 -c 'print("started")')"
assert_eq "started" "$out"
# a bench path with spaces (and a PYTHONPATH of the person, which stays on the path)
spaced="$TMP_DIR/a bench"
mkdir -p "$spaced/config" "$spaced/sites" "$TMP_DIR/mine"
cp -R "$listen_dir" "$spaced/config/benchbar-listen"
out="$(LINE_DIR="$spaced" PYTHONPATH="$stub:$TMP_DIR/mine" run_line "$web_prefix" python3 -c "$call_serve; import sys; print(any(p.endswith('/mine') for p in sys.path))")"
assert_contains "$out" "run_simple 127.0.0.1 8000 app"
assert_contains "$out" "True"

# the socketio line: node with the NODE_OPTIONS of the rendered line
node_real="$(command -v node || true)"
if [[ -n "$node_real" && "$("$node_real" -e 'process.stdout.write(typeof require("node:net").Server)' 2>/dev/null)" == "function" ]]; then
  socketio_prefix="${socketio_line#socketio: }"
  socketio_prefix="${socketio_prefix%bench socketio*}"
  js='const http = require("node:http"); const s = http.createServer(); s.listen(0, () => { console.log("bound", s.address().address); s.close(); });'
  out="$(run_line "$socketio_prefix" node -e "$js")"
  assert_eq "bound 127.0.0.1" "$out" "(from sites/: listen(port) with no host binds loopback)"
  out="$(LINE_DIR="$spaced" run_line "$socketio_prefix" node -e "$js")"
  assert_eq "bound 127.0.0.1" "$out" "(a bench path with spaces)"
  js='const http = require("node:http"); const s = http.createServer(); s.listen(0, "127.0.0.1", 16, () => { console.log("bound", s.address().address); s.close(); });'
  out="$(run_line "$socketio_prefix" node -e "$js")"
  assert_eq "bound 127.0.0.1" "$out" "(host and backlog arguments pass through)"
  js='const http = require("node:http"); const s = http.createServer(); s.listen({ port: 0, host: "::1" }, () => { console.log("bound", s.address().address); s.close(); }); s.on("error", (e) => console.log("error", e.code));'
  out="$(run_line "$socketio_prefix" node -e "$js")"
  case "$out" in "bound ::1"|"error EADDRNOTAVAIL") ;; *) fail "an options object must be left alone, got [$out]" ;; esac
  js='const http = require("node:http"); const s = http.createServer(); s.listen(0, () => { console.log("bound", s.address().address); s.close(); });'
  out="$(run_line "" env NODE_OPTIONS="" node -e "$js")"
  case "$out" in "bound ::"|"bound 0.0.0.0") ;; *) fail "without the file node listens on every interface, got [$out]" ;; esac
  # an existing NODE_OPTIONS of the person survives
  out="$(NODE_OPTIONS="--max-old-space-size=256" run_line "$socketio_prefix" node -e 'console.log(process.execArgv.length, process.env.NODE_OPTIONS.includes("--max-old-space-size=256"))')"
  assert_contains "$out" "true"
else
  printf 'SKIP: no node on PATH, the socketio file was not run\n'
fi

# ---- doctor: a listener that is not on loopback
add_listener 8000 900 Python '*'
add_listener 9000 901 node '*'
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] Listen address: the web server or socketio listens on *:8000 *:9000, not on 127.0.0.1 only"
assert_contains "$OUT" "restart --bench-dir $BENCH"
assert_not_contains "$OUT" "repair --bench-dir $BENCH, then" "(the Procfile is current: only a restart)"
: >"$MOCK_LISTEN"
add_listener 8000 900 Python 127.0.0.1
add_listener 9000 901 node '[::1]'
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[OK] Listen address: the web server and socketio listen on 127.0.0.1 only"
: >"$MOCK_LISTEN"

# the Python realtime server (uvicorn on every interface) is not patched: a restart is not the fix
add_listener 8000 900 Python 127.0.0.1
add_listener 9000 901 Python '*'
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] Listen address: the realtime server is the Python one"
assert_contains "$OUT" "does not cover that backend yet"
assert_contains "$OUT" "switch to the node socketio server"
assert_not_contains "$OUT" "restart --bench-dir $BENCH" "(a restart does not fix the Python backend)"
: >"$MOCK_LISTEN"

# a stopped bench with the Procfile of before 0.9.0 is not "ok": its next start binds every interface
cp "$procfile" "$TMP_DIR/Procfile.current"
sed 's/^#@version 2$/#@version 1/; s/Procfile.lean v2 /Procfile.lean v1 /' "$TMP_DIR/Procfile.current" >"$procfile"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] Listen address: Procfile.lean is not the 0.9.0 one"
assert_contains "$OUT" "repair --bench-dir $BENCH"
assert_not_contains "$OUT" "[OK] Listen address" "(a stopped bench with the old Procfile)"
cp "$TMP_DIR/Procfile.current" "$procfile"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[OK] Listen address: the web server and socketio start on 127.0.0.1 only"

# an older Procfile (the one from before 0.9.0) is outdated, and repair writes it and the listen files
rm_listen() { rm -f "$listen_dir/sitecustomize.py" "$listen_dir/socketio.js"; }
rm_listen
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] Procfile.lean: the listen file $listen_dir/sitecustomize.py is missing"
run_fm repair --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_file "$listen_dir/sitecustomize.py"
assert_file "$listen_dir/socketio.js"
add_listener 8000 900 Python '*'
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "restart --bench-dir $BENCH"
: >"$MOCK_LISTEN"

# ---- a bench from before 0.9.0 (issue 188): up and restart write Procfile.lean and the listen files
# again, so the next start is on 127.0.0.1 without a repair in between
# old_procfile: the file 0.8.3 wrote for this bench (its header and hash included), and no listen files
old_procfile() {
  cat >"$procfile" <<'OLD'
# benchbar-template: Procfile.lean v1 92548cf35913
# Generated by benchbar: a lean Procfile with no watch and no schedule.
# "bench setup procfile" and "bench update" rewrite Procfile, never this file.
# Run "benchbar watch" (benchwatch) for asset rebuilds.
redis_cache: redis-server config/redis_cache.conf
redis_queue: redis-server config/redis_queue.conf
web: bench serve --port 8000
socketio: bench socketio
worker: bench worker 1>> logs/worker.log 2>> logs/worker.error.log
OLD
  rm_listen
}
assert_listen_local() {
  grep -qF "$web_env_start" "$procfile" || fail "Procfile.lean must start the web line through the listen files ${1:-}"$'\n'"$(cat "$procfile")"
  assert_file "$listen_dir/sitecustomize.py" "${1:-}"
  assert_file "$listen_dir/socketio.js" "${1:-}"
}
old_procfile
MOCK_KICKSTART_PING=200 run_fm up --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_listen_local "(up on a bench of 0.8.3)"
assert_contains "$OUT" "[WARN] Procfile.lean was the one of before 0.9.0"
assert_contains "$OUT" "now listen on 127.0.0.1 only"
assert_contains "$OUT" "listen all"
grep -rq 'Procfile.lean v1 92548cf35913' "$FL_BACKUP_ROOT" || fail "the old Procfile.lean must be in the backups before it is replaced"
run_fm down --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
# a second up has nothing to write and says nothing about it
MOCK_KICKSTART_PING=200 run_fm up --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_not_contains "$OUT" "before 0.9.0"
run_fm down --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
# restart does the same
old_procfile
MOCK_KICKSTART_PING=200 run_fm restart --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_listen_local "(restart on a bench of 0.8.3)"
assert_contains "$OUT" "[WARN] Procfile.lean was the one of before 0.9.0"
run_fm down --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
# under --for-agent the line is in warnings[] of the done line and the write in changed[]
old_procfile
# (stdout alone: the text lines of a stream go to stderr)
OUT="$(MOCK_KICKSTART_PING=200 "$FM" up --for-agent --bench-dir "$BENCH" 2>/dev/null)" || fail "up --for-agent failed: $OUT"
done_line="$(printf '%s\n' "$OUT" | grep '"event":"done"' | tail -n1)"
assert_contains "$(printf '%s' "$done_line" | jget - '" | ".join(d["warnings"])')" "Procfile.lean was the one of before 0.9.0"
assert_contains "$(printf '%s' "$done_line" | jget - '" | ".join(c["kind"] + " " + c["detail"] for c in d["changed"])')" "service Procfile.lean written again"
assert_not_contains "$OUT" "[WARN]" "(stdout holds JSON lines only)"
assert_listen_local "(up --for-agent)"
run_fm down --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
# a dry run writes nothing
old_procfile
run_fm up --dry-run --bench-dir "$BENCH"
assert_eq "web: bench serve --port 8000" "$(grep '^web: ' "$procfile")" "(a dry run must not write)"
assert_no_file "$listen_dir/sitecustomize.py"
# up on a bench that runs is still a no-op: it says what the running bench does and how to change it
add_proc 4242 "honcho start -f Procfile.lean" "$BENCH"
run_fm up --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "already running"
assert_contains "$OUT" "[WARN] the running bench was started with the Procfile.lean of before 0.9.0"
assert_contains "$OUT" "restart --bench-dir $BENCH"
assert_eq "web: bench serve --port 8000" "$(grep '^web: ' "$procfile")" "(up on a running bench writes nothing)"
: >"$MOCK_PROCS"
# a missing listen file under a current Procfile.lean is written again too (the bench would not start without it)
cp "$TMP_DIR/Procfile.current" "$procfile"
rm_listen
MOCK_KICKSTART_PING=200 run_fm up --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_listen_local "(up with the listen files gone)"
assert_not_contains "$OUT" "before 0.9.0"
run_fm down --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
# a Procfile.lean benchbar did not write is left alone
printf 'web: bench serve --port 8000\n' >"$procfile"
MOCK_KICKSTART_PING=200 run_fm up --bench-dir "$BENCH"
assert_eq "web: bench serve --port 8000" "$(cat "$procfile")" "(a foreign Procfile.lean is not replaced by up)"
run_fm down --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
cp "$TMP_DIR/Procfile.current" "$procfile"

# ---- listen all: a person's decision, per bench, back with listen local
BENCHBAR_NONINTERACTIVE=1 run_fm listen all --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "a person's decision"
grep -qF "$web_env_start" "$procfile" || fail "a refused listen all must change nothing"
run_fm listen all --dry-run --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
grep -qF "$web_env_start" "$procfile" || fail "a dry run must change nothing"
run_fm status --json --bench-dir "$BENCH"
assert_eq "local" "$(printf '%s' "$OUT" | jget - 'd["listen"]')"

reset_calls
run_fm listen all --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "listen all"
assert_eq "web: bench serve --port 8000" "$(grep '^web: ' "$procfile")" "(the Procfile of before 0.9.0)"
assert_eq "socketio: bench socketio" "$(grep '^socketio: ' "$procfile")"
run_fm listen --bench-dir "$BENCH"
assert_contains "$OUT" "listen is all"
run_fm status --json --bench-dir "$BENCH"
assert_eq "all" "$(printf '%s' "$OUT" | jget - 'd["listen"]')"
# up and restart keep it too: a bench set to all is not rewritten and not warned, old Procfile.lean or not
cp "$procfile" "$TMP_DIR/Procfile.all"
old_procfile
old_sum="$(cksum <"$procfile")"
MOCK_KICKSTART_PING=200 run_fm up --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "$old_sum" "$(cksum <"$procfile")" "(listen all: up must not write Procfile.lean)"
assert_no_file "$listen_dir/sitecustomize.py"
assert_not_contains "$OUT" "before 0.9.0"
MOCK_KICKSTART_PING=200 run_fm restart --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "$old_sum" "$(cksum <"$procfile")" "(listen all: restart must not write Procfile.lean)"
assert_not_contains "$OUT" "before 0.9.0"
run_fm down --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
cp "$TMP_DIR/Procfile.all" "$procfile"
# repair keeps the choice, and doctor names it with the fix
run_fm repair --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "web: bench serve --port 8000" "$(grep '^web: ' "$procfile")" "(repair keeps listen all)"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] Listen address: listen is set to all"
assert_contains "$OUT" "listen local --bench-dir $BENCH"
add_listener 8000 900 Python '*'
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[WARN] Listen address: the web server and socketio listen on *:8000"
: >"$MOCK_LISTEN"
# the choice is per bench: a second bench stays local
BENCH2="$HOME/dev/other-bench"
make_fake_bench "$BENCH2" other
run_fm listen --bench-dir "$BENCH2"
assert_contains "$OUT" "listen is local"

# a running bench is told to restart
add_proc 4242 "honcho start -f Procfile.lean" "$BENCH"
add_listener 8000 4242 Python '*'
run_fm listen local --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "the running bench still listens as before; run: benchbar restart"
: >"$MOCK_PROCS"; : >"$MOCK_LISTEN"
grep -qF "$web_env_start" "$procfile" || fail "listen local must put the listen files back into the Procfile"
run_fm status --json --bench-dir "$BENCH"
assert_eq "local" "$(printf '%s' "$OUT" | jget - 'd["listen"]')"
run_fm listen sideways --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "Usage: benchbar listen [local|all]"

# ---- uninstall-service takes the listen files with it, each backed up first
run_fm uninstall-service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_no_file "$listen_dir/sitecustomize.py"
assert_no_file "$listen_dir/socketio.js"
assert_no_file "$procfile"
grep -rq 'benchbar-template: listen-socketio.js' "$FL_BACKUP_ROOT" || fail "the listen files must be backed up before they go"

printf 'test-listen: ok\n'
