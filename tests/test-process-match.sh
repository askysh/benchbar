#!/usr/bin/env bash
# One process matcher for down, restart, the port checks and the runner: it
# matches what is stable (the frappe entry point on the command line, then the
# working folder), never the interpreter path. A Homebrew Python re-executes
# itself, so a Mac's bench processes show the framework's Python and no bench
# path; under uv on Linux they show the venv's python or uv's own. A user's
# "bench migrate" or "bench console" and another bench's processes never match.
# shellcheck disable=SC2016  # bash -c scripts are quoted on purpose
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/frappe-bench"
OTHER="$HOME/other-bench"
make_fake_bench "$BENCH"
make_fake_bench "$OTHER" other
mkdir -p "$HOME/Library/LaunchAgents"
FL_BENCH_DIR="$BENCH"
FL_WEB_PORT=8000; FL_SOCKETIO_PORT=9000; FL_REDIS_QUEUE_PORT=11000; FL_REDIS_CACHE_PORT=13000

# what `ps -o command` shows on a Mac with Homebrew Python 3.11 (read from a
# live bench): the framework's interpreter, no bench path, working folder
# <bench>/sites
PYFW="/opt/homebrew/Cellar/python@3.11/3.11.18/Frameworks/Python.framework/Versions/3.11/Resources/Python.app/Contents/MacOS/Python"
HELPER="-m frappe.utils.bench_helper frappe"

# lib_run CODE: runs CODE with the libraries loaded the way benchbar loads them
# (the platform last, so Linux replaces the Mac's functions) and this bench's variables
lib_run() {
  SCRIPT_DIR="$ROOT" FL_BENCH_DIR="$BENCH" FL_WEB_PORT=8000 FL_SOCKETIO_PORT=9000 FL_REDIS_QUEUE_PORT=11000 FL_REDIS_CACHE_PORT=13000 FL_LOG_FILE=/dev/null \
    bash -c 'for f in ui run platform benchinfo process port-management; do . "$SCRIPT_DIR/lib/frappe-local/$f.sh"; done; fl_platform_load; eval "$1"' _ "$1"
}
# in_bench: the pids the one matcher finds for $BENCH, sorted, one line
in_bench() { lib_run 'fl_bench_helper_pids | sort -n | tr "\n" " "'; }
# the same through the full scan that down and the waits use
scan() { lib_run 'fl_bench_process_pids | sort -n | tr "\n" " "'; }
status_pids() { lib_run 'fl_bench_status_pids | sort -n | tr "\n" " "'; }

# ---- macOS: the framework interpreter
add_proc 101 "$PYFW $HELPER serve --port 8000 --noreload" "$BENCH/sites"
add_proc 102 "$PYFW $HELPER worker --queue default" "$BENCH/sites"
add_proc 103 "$PYFW $HELPER schedule" "$BENCH/sites"
add_proc 104 "$PYFW $HELPER socketio" "$BENCH/sites" # not a bench_helper command: must not match
add_proc 200 "$PYFW $HELPER --site macdev migrate" "$BENCH/sites"
add_proc 201 "$PYFW $HELPER --site macdev console" "$BENCH/sites"
add_proc 202 "$PYFW $HELPER serve --port 8100" "$OTHER/sites"
add_proc 203 "$PYFW $HELPER worker" "$OTHER/sites"
add_proc 204 "$PYFW $HELPER worker --queue short" # folder unreadable: proves nothing
rm -f "$MOCK_STATE/cwd/204"
add_proc 205 "$PYFW $HELPER servers" "$BENCH/sites" # a longer word is not serve
assert_eq "101 102 103 " "$(in_bench)" "(serve, worker and schedule of this bench under the framework Python; not migrate, console, another bench, an unreadable folder)"
assert_eq "101 102 103 " "$(scan)" "(the full scan down and the waits use finds them too)"

# the status check and the Linux copy use the same entry point pattern
assert_eq "101 102 103 " "$(status_pids)" "(the status path uses the same entry point pattern)"

# a worker alone is a running bench: is_running, is_serving and the port
# manager's check see it (they all missed it before)
: >"$MOCK_PROCS"; : >"$MOCK_STATE/killed"
add_proc 301 "$PYFW $HELPER worker" "$BENCH/sites"
for fn in fl_bench_is_running fl_bench_is_serving fl_pm_running; do
  lib_run "$fn" || fail "$fn must see a worker that runs under the framework Python"
done

# fl_bench_kill_processes stops the framework workers and nothing else
: >"$MOCK_PROCS"; : >"$MOCK_STATE/killed"
add_proc 101 "$PYFW $HELPER serve --port 8000" "$BENCH/sites"
add_proc 102 "$PYFW $HELPER worker" "$BENCH/sites"
add_proc 103 "$PYFW $HELPER schedule" "$BENCH/sites"
add_proc 200 "$PYFW $HELPER --site macdev migrate" "$BENCH/sites"
add_proc 201 "$PYFW $HELPER --site macdev console" "$BENCH/sites"
add_proc 202 "$PYFW $HELPER serve --port 8100" "$OTHER/sites"
add_proc 203 "$PYFW $HELPER worker" "$OTHER/sites"
lib_run "fl_bench_kill_processes TERM"
for pid in 101 102 103; do ! grep -q "^${pid} " "$MOCK_PROCS" || fail "pid ${pid} (framework Python, this bench) should have been stopped"; done
for pid in 200 201 202 203; do grep -q "^${pid} " "$MOCK_PROCS" || fail "pid ${pid} (a user's command or another bench) must survive"; done

# benchbar down end to end: the orphaned worker and scheduler die, migrate and console live
: >"$MOCK_PROCS"; : >"$MOCK_STATE/killed"
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
add_proc 401 "$PYFW $HELPER worker" "$BENCH/sites"
add_proc 402 "$PYFW $HELPER schedule" "$BENCH/sites"
add_proc 403 "$PYFW $HELPER --site macdev migrate" "$BENCH/sites"
add_proc 404 "$PYFW $HELPER --site macdev console" "$BENCH/sites"
run_fm down --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
for pid in 401 402; do ! grep -q "^${pid} " "$MOCK_PROCS" || fail "down left the orphaned pid ${pid} running"; done
for pid in 403 404; do grep -q "^${pid} " "$MOCK_PROCS" || fail "down killed the user's own pid ${pid}"; done
: >"$MOCK_PROCS"

# the runner template carries the CLI's pattern, byte for byte: one matcher
pattern="$(lib_run 'fl_bench_helper_pattern')"
grep -q -F -- "pgrep -f '${pattern}'" "$ROOT/templates/bench-run.sh.tmpl" || fail "the runner template's pattern differs from fl_bench_helper_pattern ($pattern)"

# the rendered runner clears the same leftovers (and only them) before it starts honcho
. "$ROOT/lib/frappe-local/ui.sh"; . "$ROOT/lib/frappe-local/run.sh"; . "$ROOT/lib/frappe-local/templates.sh"; . "$ROOT/lib/frappe-local/process.sh"
RB="$TMP_DIR/runner-bench"
make_fake_bench "$RB"
runner="$RB/benchbar-run.sh"
fl_template_render bench-run.sh "BENCH_DIR=$RB" "BENCH_NAME=runner-bench" \
  "HONCHO=$MOCK_PIPX_HOME/venvs/frappe-bench/bin/honcho" "PORTS=8000,9000,11000,13000" "LABEL=com.benchbar.runner-bench" \
  "MAX_STARTS=3" "WINDOW=600" "SITE=macdev" "WEB_PORT=8000" "CLI_VERSION=9.9.9" >"$runner"
chmod +x "$runner"
export BENCHBAR_STATE_LOG="$TMP_DIR/transitions.log" BENCHBAR_PING_EVERY=0 BENCHBAR_PING_TRIES=2
add_proc 501 "$PYFW $HELPER serve --port 8000" "$RB/sites"
add_proc 502 "$PYFW $HELPER worker" "$RB/sites"
add_proc 503 "$PYFW $HELPER schedule" "$RB/sites"
add_proc 504 "$PYFW $HELPER --site macdev migrate" "$RB/sites"
add_proc 505 "$PYFW $HELPER worker" "$OTHER/sites"
add_proc 506 "$PYFW $HELPER worker" # unreadable folder
rm -f "$MOCK_STATE/cwd/506"
"$runner" >/dev/null 2>&1 || true
for pid in 501 502 503; do ! grep -q "^${pid} " "$MOCK_PROCS" || fail "the runner left the stale pid ${pid} of its bench"; done
for pid in 504 505 506; do grep -q "^${pid} " "$MOCK_PROCS" || fail "the runner cleared pid ${pid}: a user's command, another bench or an unreadable folder"; done
: >"$MOCK_PROCS"

# ---- Linux: uv Python. argv[0] is the venv's python when it is started through
# the venv, uv's own interpreter when it is not; the folder is <bench>/sites
use_linux
UVPY="$HOME/.local/share/uv/python/cpython-3.11.9-linux-x86_64-gnu/bin/python3.11"
: >"$MOCK_PROCS"
add_proc 601 "$BENCH/env/bin/python $HELPER serve --port 8000" "$BENCH/sites"
add_proc 602 "$UVPY $HELPER worker --queue default" "$BENCH/sites"
add_proc 603 "$UVPY $HELPER schedule" "$BENCH/sites"
add_proc 604 "$BENCH/env/bin/python $HELPER --site linuxdev.localhost migrate" "$BENCH/sites"
add_proc 605 "$UVPY $HELPER --site linuxdev.localhost console" "$BENCH/sites"
add_proc 606 "$UVPY $HELPER worker" "$OTHER/sites"
add_proc 607 "$UVPY $HELPER worker"
assert_eq "601 602 603 " "$(in_bench)" "(Linux: the venv python and uv's interpreter both match; not migrate, console, another bench, a pid with no /proc folder)"
assert_eq "601 602 603 " "$(scan)" "(Linux: the full scan)"
assert_eq "601 602 603 " "$(status_pids)" "(Linux: the status path agrees)"
lib_run "fl_bench_kill_processes TERM"
for pid in 601 602 603; do ! grep -q "^${pid} " "$MOCK_PROCS" || fail "pid ${pid} (Linux, this bench) should have been stopped"; done
for pid in 604 605 606 607; do grep -q "^${pid} " "$MOCK_PROCS" || fail "pid ${pid} (a user's command, another bench or no folder) must survive"; done

# ---- CORE-25: test seams are read only under FL_TESTING=1. A production run
# (no FL_TESTING) ignores every one of them, so a variable in the environment
# cannot change what benchbar kills, renders, runs or believes.
unset FL_PLATFORM 2>/dev/null || true
export FL_PLATFORM=macos
seam() { # seam ASSIGNMENTS... -- CODE: CODE with the libraries loaded, the assignments exported and FL_TESTING as given
  local code="${*: -1}"; local -a env_args=()
  local a; for a in "${@:1:$#-1}"; do env_args+=("$a"); done
  env "${env_args[@]}" bash -c 'for f in ui run platform benchinfo version-policy templates sudo lock freshness benchstate process; do . "$SCRIPT_DIR/lib/frappe-local/$f.sh"; done; eval "$1"' _ "$code"
}
export SCRIPT_DIR="$ROOT"
# kill -0 goes through FL_KILL_CMD (a function that always fails) only when testing
assert_eq "alive" "$(seam FL_TESTING= FL_KILL_CMD=false 'fl_pid_alive $$ && echo alive || echo dead')" "(production: the kill builtin answers, FL_KILL_CMD is ignored)"
assert_eq "dead" "$(seam FL_TESTING=1 FL_KILL_CMD=false 'fl_pid_alive $$ && echo alive || echo dead')" "(testing: FL_KILL_CMD answers)"
assert_eq "$ROOT/config/apps.tsv" "$(seam FL_TESTING= FL_CONFIG_DIR=/elsewhere 'fl_config_file apps.tsv')" "(production: the config folder is the CLI's own)"
assert_eq "/elsewhere/apps.tsv" "$(seam FL_TESTING=1 FL_CONFIG_DIR=/elsewhere 'fl_config_file apps.tsv')"
assert_eq "$ROOT/templates" "$(seam FL_TESTING= FL_TEMPLATE_DIR=/elsewhere 'printf %s "$FL_TEMPLATE_DIR"')" "(production: the template folder is the CLI's own)"
assert_eq "/elsewhere" "$(seam FL_TESTING=1 FL_TEMPLATE_DIR=/elsewhere 'printf %s "$FL_TEMPLATE_DIR"')"
assert_eq "/usr/bin/osascript" "$(seam FL_TESTING= FL_OSASCRIPT=/tmp/fake 'printf %s "$FL_OSASCRIPT"')" "(production: the real osascript)"
assert_eq "/tmp/fake" "$(seam FL_TESTING=1 FL_OSASCRIPT=/tmp/fake 'printf %s "$FL_OSASCRIPT"')"
assert_eq "5" "$(seam FL_TESTING= FL_LOCK_GRACE_SECS=0 'printf %s "$FL_LOCK_GRACE_SECS"')" "(production: the lock grace period is 5 seconds)"
assert_eq "0" "$(seam FL_TESTING=1 FL_LOCK_GRACE_SECS=0 'printf %s "$FL_LOCK_GRACE_SECS"')"
assert_eq "$(date +%s | cut -c1-6)" "$(seam FL_TESTING= FL_NOW=1000 'fl_now' | cut -c1-6)" "(production: the clock is the machine's)"
assert_eq "1000" "$(seam FL_TESTING=1 FL_NOW=1000 'fl_now')"
assert_eq "on" "$(seam FL_TESTING= FL_LOCAL_PROBES=0 'fl_local_probes_off && echo off || echo on')" "(production: the local probes run)"
assert_eq "off" "$(seam FL_TESTING=1 FL_LOCAL_PROBES=0 'fl_local_probes_off && echo off || echo on')"
# running as root is judged by the real uid in production; the test uid answers only under FL_TESTING
assert_eq "ok" "$(seam FL_TESTING= FL_EFFECTIVE_UID=0 '( fl_preflight_not_root ) >/dev/null 2>&1 && echo ok || echo refused')" "(production: the real uid, not FL_EFFECTIVE_UID)"
assert_eq "refused" "$(seam FL_TESTING=1 FL_EFFECTIVE_UID=0 '( fl_preflight_not_root ) >/dev/null 2>&1 && echo ok || echo refused')"
# the runner's stop command: BENCHBAR_KILL_CMD only under FL_TESTING. A pid no machine has
# (above any pid_max) shows it: the real kill cannot stop it, the table's mockkill can.
: >"$MOCK_PROCS"
add_proc 2147483001 "$PYFW $HELPER worker" "$RB/sites"
env -u FL_TESTING "$runner" >/dev/null 2>&1 || true
grep -q "^2147483001 " "$MOCK_PROCS" || fail "a production runner used BENCHBAR_KILL_CMD"
FL_TESTING=1 "$runner" >/dev/null 2>&1 || true
! grep -q "^2147483001 " "$MOCK_PROCS" || fail "the runner ignored BENCHBAR_KILL_CMD under FL_TESTING=1"
: >"$MOCK_PROCS"

# ---- fl_process_running NAME: a process of that name, not an editor or a tail that mentions it
: >"$MOCK_PROCS"
add_proc 4301 "vim /opt/homebrew/etc/my.cnf.d/mariadbd.cnf"
add_proc 4302 "tail -f /opt/homebrew/var/mysql/mariadbd.log"
assert_eq "no" "$(lib_run 'fl_process_running mariadbd && echo yes || echo no')" "(an editor and a tail are no MariaDB)"
add_proc 4303 "/opt/homebrew/opt/mariadb@10.11/bin/mariadbd --datadir=/opt/homebrew/var/mysql"
assert_eq "yes" "$(lib_run 'fl_process_running mariadbd && echo yes || echo no')" "(the server itself is)"
assert_eq "yes" "$(lib_run 'fl_process_running "mariadbd --datadir" && echo yes || echo no')" "(a pattern with more than a name still matches the command line)"
: >"$MOCK_PROCS"

# ---- fl_port_listening sees a listener of another user (root): lsof as a normal
# user does not list it, netstat does
: >"$MOCK_LISTEN"; rm -f "$MOCK_STATE/netstat_listen"
assert_eq "no" "$(lib_run 'fl_port_listening 8000 && echo yes || echo no')" "(nothing listens)"
printf '8000 *\n' >"$MOCK_STATE/netstat_listen"
assert_eq "yes" "$(lib_run 'fl_port_listening 8000 && echo yes || echo no')" "(a root owned listener on 8000 counts)"
assert_eq "no" "$(lib_run 'fl_port_listening 80 && echo yes || echo no')" "(80 is not 8000)"
assert_eq "no" "$(lib_run 'fl_port_listening 18000 && echo yes || echo no')" "(18000 is not 8000)"
rm -f "$MOCK_STATE/netstat_listen"

printf 'test-process-match: ok\n'
