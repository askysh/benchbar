#!/usr/bin/env bash
#
# agent-contracts-fixtures.sh: the setup shared by test-agent-contracts, -2 and -3
# (a fake bench with its service, the root password, the stream helpers).

# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
# shellcheck source=tests/lib/install-stream.sh
. "$(dirname "${BASH_SOURCE[0]}")/install-stream.sh"

BENCH="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH" macdev
printf 'port 11000\n' >"$BENCH/config/redis_queue.conf"; printf 'port 13000\n' >"$BENCH/config/redis_cache.conf"
printf '127.0.0.1 macdev\n' >>"$FL_HOSTS_FILE"
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
export MARIADB_ROOT_PASSWORD=rootpw
# the launchctl mock starts honcho; its working folder is this bench's
mkdir -p "$MOCK_STATE/cwd"; printf '%s' "$BENCH" >"$MOCK_STATE/cwd/4242"

# lines(): how many lines the last stream has; done_count(): its done lines
done_count() { sx 'len([x for x in e if x["event"] == "done"])'; }


# run_json ARGS...: stdout in OUT, stderr in ERR, apart
run_json() { set +e; OUT="$("$FM" "$@" 2>"$MOCK_STATE/stderr" </dev/null)"; CODE="$?"; ERR="$(cat "$MOCK_STATE/stderr")"; set -e; }

# make_second_bench: a second bench with its service (parts 2 and 3 need it;
# part 1 builds the same one inline, with its assertions)
make_second_bench() {
  B2="$HOME/dev/second-bench"
  make_fake_bench "$B2" second
  printf 'port 11001\n' >"$B2/config/redis_queue.conf"; printf 'port 13001\n' >"$B2/config/redis_cache.conf"
  stream service --json --yes --bench-dir "$B2"
}

# make_log_bench: a bench with a bench.log, its mtime fixed (parts 2 and 3)
make_log_bench() {
  LB="$HOME/log-bench"
  make_fake_bench "$LB" logsite
  cat >"$LB/logs/bench.log" <<'LOG'
23:59:58 system | web.1 started (pid=11)
23:59:59 web.1        | * Running on http://127.0.0.1:8000
00:00:02 worker.1     | job done
00:00:03 web.1        | Traceback (most recent call last):
  File "x.py", line 1, in <module>
00:00:04 socketio.1   | listening on 9000
LOG
  TZ=UTC touch -t 202610290000.10 "$LB/logs/bench.log"
}

# run_events ARGS...: the JSON lines in $STREAM, stderr in $STREAM.err; ev EXPR: EXPR over the events e
run_events() {
  set +e
  "$FM" "$@" >"$STREAM" 2>"$STREAM.err" </dev/null
  CODE=$?
  set -e
}
ev() { python3 -I -c '
import json, sys
e = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(eval(sys.argv[2]))' "$STREAM" "$1"; }

logs_now() { find "$FL_STATE_DIR/logs" -type f 2>/dev/null | wc -l | tr -d ' '; }
