#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/frappe-local-run-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

. "$ROOT/lib/frappe-local/ui.sh"
. "$ROOT/lib/frappe-local/run.sh"

assert_status() {
  local expected="$1"
  shift
  set +e
  "$@" >/dev/null 2>&1
  actual="$?"
  set -e
  if [[ "$actual" != "$expected" ]]; then
    printf 'Expected exit %s, got %s: %s\n' "$expected" "$actual" "$*"
    exit 1
  fi
}

printf '#!/usr/bin/env bash\nsleep 2\n' >"$TMP_DIR/slow"
chmod +x "$TMP_DIR/slow"

fl_run_with_timeout 0 "true command" true
assert_status 124 fl_run_with_timeout 1 "slow command" "$TMP_DIR/slow"

# a timed command (bench init) is not silent in the JSON stream: a progress line
# every FL_PROGRESS_SECS, with its label and the seconds so far, as fl_run_long
printf '#!/usr/bin/env bash\nsleep 4\n' >"$TMP_DIR/slow4"
chmod +x "$TMP_DIR/slow4"
FL_JSONL=1 FL_PROGRESS_SECS=1 fl_run_with_timeout 20 "bench init" "$TMP_DIR/slow4" 3>"$TMP_DIR/stream" >/dev/null
progress="$(grep -c '"event":"progress".*"label":"bench init"' "$TMP_DIR/stream" || true)"
[[ "$progress" -ge 2 ]] || { printf 'Expected progress lines for the timed command, got %s: %s\n' "$progress" "$(cat "$TMP_DIR/stream")"; exit 1; }
case "$(cat "$TMP_DIR/stream")" in *'"elapsed":'*) ;; *) printf 'Expected elapsed seconds in the progress line\n'; exit 1 ;; esac
# without the stream there is none
FL_JSONL=0 FL_PROGRESS_SECS=1 fl_run_with_timeout 20 "bench init" "$TMP_DIR/slow4" 3>"$TMP_DIR/stream0" >/dev/null
[[ ! -s "$TMP_DIR/stream0" ]] || { printf 'No stream, no progress lines\n'; exit 1; }

ps() {
  printf 'T\n'
}
assert_status 125 fl_run_with_timeout 5 "stopped command" "$TMP_DIR/slow"

# fl_on_error: exit 2 is reserved for "MariaDB root password unknown"; a
# command that happens to fail with 2 ends the run with 1
set +e
out="$(bash -c '. "$0/lib/frappe-local/ui.sh"; . "$0/lib/frappe-local/run.sh"; set -e; trap fl_on_error ERR; FL_LAST_COMMAND="grep pattern file"; bash -c "exit 2"' "$ROOT" 2>&1)"
code=$?
set -e
[[ "$code" == "1" ]] || { printf 'Expected exit 1 for an incidental exit 2, got %s: %s\n' "$code" "$out"; exit 1; }
case "$out" in *"Last command failed with exit code 1"*) ;; *) printf 'Expected the mapped code in the message: %s\n' "$out"; exit 1 ;; esac
set +e
out="$(bash -c '. "$0/lib/frappe-local/ui.sh"; . "$0/lib/frappe-local/run.sh"; set -e; trap fl_on_error ERR; FL_LAST_COMMAND="x"; (exit 7)' "$ROOT" 2>&1)"
code=$?
set -e
[[ "$code" == "7" ]] || { printf 'Expected exit 7 to pass through, got %s\n' "$code"; exit 1; }

# a pool job (profile check) that gets a second TERM while it stops its group still
# finishes: the group is gone when it ends (benchbar sends a job TERM twice, and a
# terminal's INT comes on top). The command ignores TERM, so only the job's KILL ends it.
printf '#!/usr/bin/env bash\ntrap "" TERM\nsleep 30\n' >"$TMP_DIR/deaf"
chmod +x "$TMP_DIR/deaf"
(
  trap fl_bg_job_stop TERM INT HUP
  FL_KILL_GRACE=1
  fl_run_bg_group "$TMP_DIR/deaf.out" "$TMP_DIR/deaf"
  printf '%s\n' "$FL_RUN_PID" >"$TMP_DIR/deaf.pid"
  while :; do sleep 0.05; done
) 2>/dev/null &
job="$!"
for _ in $(seq 1 50); do [[ -s "$TMP_DIR/deaf.pid" ]] && break; sleep 0.1; done
deaf="$(cat "$TMP_DIR/deaf.pid")"
sleep 0.5
kill -TERM "$job"
sleep 0.4
kill -TERM "$job" 2>/dev/null || true
for _ in $(seq 1 60); do kill -0 "$job" 2>/dev/null || break; sleep 0.1; done
set +e; wait "$job" 2>/dev/null; code=$?; set -e
if kill -0 -- "-${deaf}" 2>/dev/null; then
  kill -KILL -- "-${deaf}" 2>/dev/null || true
  printf 'The command of a pool job outlived the second TERM to the job\n'
  exit 1
fi
[[ "$code" == "143" ]] || { printf 'Expected the pool job to end with 143, got %s\n' "$code"; exit 1; }

printf 'test-run: ok\n'
