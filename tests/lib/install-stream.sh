#!/usr/bin/env bash
# Helpers for the tests of install --json and adopt --json: a fresh machine
# under the mocks, the fake osascript, a run that saves the stream, and a
# way to read it. Sourced after harness.sh.
export FL_OSASCRIPT="$ROOT/tests/mocks/osascript-gui"

# stream_machine: MariaDB and Redis run, wkhtmltopdf and Rosetta are missing
stream_machine() {
  add_proc 900 "mariadbd --datadir=/x"
  add_proc 901 "redis-server *:6379"
  printf 'mariadb@10.11 started akash file\nredis started akash file\n' >"$MOCK_BREW_SERVICES"
  touch "$MOCK_STATE/wkhtml_missing"
  rm -f "$MOCK_STATE/wkhtml_installed" "$MOCK_STATE/rosetta"
}

# stream ARGS...: runs benchbar, stdout (the stream) in $STREAM, stderr in
# $STREAM.err, exit code in CODE; stdin closed
STREAM="$TMP_DIR/stream.jsonl"
stream() {
  set +e
  "$FM" "$@" >"$STREAM" 2>"$STREAM.err" </dev/null
  CODE=$?
  set -e
}

# sx EXPR: a Python expression on the list of events `e` of the last stream;
# every line must be one JSON object with schema_version, cli_version and event
sx() {
  python3 -I -c '
import json, sys
e = []
for line in open(sys.argv[1]):
    if not line.strip():
        continue
    o = json.loads(line)
    assert isinstance(o, dict) and o["schema_version"] == 1 and o["cli_version"] == sys.argv[3] and o["event"], o
    e.append(o)
print(eval(sys.argv[2]))' "$STREAM" "$1" "$VER"
}

# stream_keys FILE: per event type, the union of the keys, as "type:key,key" lines
stream_keys() {
  python3 -I -c '
import json, sys
ignore = {"error", "dry_run"}
u = {}
for f in sys.argv[1:]:
    for line in open(f):
        if line.strip():
            o = json.loads(line)
            u.setdefault(o["event"], set()).update(set(o) - ignore)
for k in sorted(u):
    print(k + ":" + ",".join(sorted(u[k])))' "$@"
}

osa_calls() { [[ -f "$MOCK_STATE/osa_reasons" ]] && wc -l <"$MOCK_STATE/osa_reasons" | tr -d ' ' || printf 0; }
osa_reset() { rm -f "$MOCK_STATE"/osa_reasons "$MOCK_STATE"/osa_cmd.* "$MOCK_STATE"/osa_cancel "$MOCK_STATE"/osa_cancel_all "$MOCK_STATE"/osa_fail; }
