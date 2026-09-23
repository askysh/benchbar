#!/usr/bin/env bash
#
# harness.sh: shared setup for the mocked tests.
#
# Creates a throwaway HOME, a fake bench, a fake Homebrew prefix and puts
# tests/mocks/bin first on PATH. Every mock appends its call to $MOCK_LOG so
# a test can assert what was (not) run. Nothing touches the real machine.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$ROOT"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/frappe-mac-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

export HOME="$TMP_DIR/home"
export MOCK_STATE="$TMP_DIR/mock"
export MOCK_LOG="$MOCK_STATE/calls.log"
export MOCK_PROCS="$MOCK_STATE/procs"
export MOCK_LISTEN="$MOCK_STATE/listen"
export MOCK_BREW_PREFIX="$TMP_DIR/brew"
export MOCK_BREW_INSTALLED="python@3.11 node@20 mariadb@10.11 redis openssl@3 libffi zlib pipx"
export MOCK_BREW_LEAVES="$MOCK_STATE/leaves"
export MOCK_BREW_SERVICES="$MOCK_STATE/services"
export MOCK_CURL_CODE="000"
export MOCK_PIPX_HOME="$HOME/.local/pipx"
export FL_STATE_DIR="$TMP_DIR/state"
export FL_STATE_FILE="$FL_STATE_DIR/state.env"
export FL_BACKUP_ROOT="$TMP_DIR/state/backups"
export FL_HOSTS_FILE="$TMP_DIR/hosts"
export FL_RC_FILE="$HOME/.zshrc"
export FL_UP_WAIT_SECS=2
export FL_KILL_CMD=mockkill
export FL_APP_DIRS="$HOME/Applications"
export NO_COLOR=1
export SHELL=/bin/zsh
unset BENCH_DIR SITE_NAME FL_DRY_RUN FL_ASSUME_YES 2>/dev/null || true

mkdir -p "$HOME/Library/LaunchAgents" "$MOCK_STATE/agents" "$FL_STATE_DIR" "$MOCK_BREW_PREFIX/etc/my.cnf.d" \
  "$MOCK_BREW_PREFIX/opt/python@3.11/bin" "$MOCK_PIPX_HOME/venvs/frappe-bench/bin" "$HOME/.local/bin"
: >"$MOCK_LOG"; : >"$MOCK_PROCS"; : >"$MOCK_LISTEN"; : >"$MOCK_BREW_SERVICES"
printf 'python@3.11\nnode@20\nmariadb@10.11\nredis\n' >"$MOCK_BREW_LEAVES"
printf "%s\\n" "$MOCK_BREW_INSTALLED" | tr " " "\\n" >"$MOCK_STATE/installed"
mkdir -p "$MOCK_BREW_PREFIX/opt/node@20/bin" "$MOCK_BREW_PREFIX/opt/mariadb@10.11/bin"
cp "$ROOT/tests/mocks/python3.11" "$MOCK_BREW_PREFIX/opt/python@3.11/bin/python3.11"
cp "$ROOT/tests/mocks/node" "$ROOT/tests/mocks/npm" "$ROOT/tests/mocks/yarn" "$MOCK_BREW_PREFIX/opt/node@20/bin/"
cp "$ROOT/tests/mocks/mariadb" "$MOCK_BREW_PREFIX/opt/mariadb@10.11/bin/mariadb"
chmod +x "$MOCK_BREW_PREFIX"/opt/*/bin/*
printf '127.0.0.1 localhost\n' >"$FL_HOSTS_FILE"
printf '[client-server]\n!includedir %s/etc/my.cnf.d\n' "$MOCK_BREW_PREFIX" >"$MOCK_BREW_PREFIX/etc/my.cnf.d/../my.cnf"
printf '# test zshrc\nexport EDITOR=vim\n' >"$HOME/.zshrc"
cp "$ROOT/tests/mocks/honcho" "$MOCK_PIPX_HOME/venvs/frappe-bench/bin/honcho"
chmod +x "$MOCK_PIPX_HOME/venvs/frappe-bench/bin/honcho"
export PATH="$ROOT/tests/mocks/bin:$PATH"

FM="$ROOT/frappe-mac"

# ---------------------------------------------------------------- asserts

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected [$1], got [$2] ${3:-}"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "expected output to contain [$2] ${3:-}"$'\n'"--- output ---"$'\n'"$1" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "expected output NOT to contain [$2] ${3:-}"$'\n'"--- output ---"$'\n'"$1" ;; esac; }
assert_file() { [[ -e "$1" ]] || fail "expected file ${1} ${2:-}"; }
assert_no_file() { [[ ! -e "$1" ]] || fail "expected no file ${1} ${2:-}"; }
assert_calls_contain() { grep -q -E "$1" "$MOCK_LOG" || fail "expected a mock call matching [$1] ${2:-}"$'\n'"--- calls ---"$'\n'"$(cat "$MOCK_LOG")"; }
assert_calls_not_contain() { ! grep -q -E "$1" "$MOCK_LOG" || fail "expected no mock call matching [$1] ${2:-}"$'\n'"--- calls ---"$'\n'"$(cat "$MOCK_LOG")"; }
assert_status() {
  local expected="$1" actual=0
  shift
  set +e; "$@" >/dev/null 2>&1; actual="$?"; set -e
  [[ "$actual" == "$expected" ]] || fail "expected exit ${expected}, got ${actual}: $*"
}
run_fm() {
  # run_fm ARGS...: runs frappe-mac, captures output and exit code in OUT and CODE
  set +e
  OUT="$("$FM" "$@" 2>&1)"
  CODE="$?"
  set -e
}
reset_calls() { : >"$MOCK_LOG"; }

# Snapshot of every file (path, size, mtime) under the given dirs, for
# "second run writes nothing" assertions.
snapshot() {
  find "$@" -type f 2>/dev/null | sort | while IFS= read -r f; do
    stat -f '%N %z %m' "$f"
  done
}

# ---------------------------------------------------------------- fake bench

make_fake_bench() {
  local dir="$1" site="${2:-macdev}"
  mkdir -p "$dir/apps/frappe/node_modules/socket.io" "$dir/apps/frappe/frappe/public/dist/js" "$dir/apps/frappe/frappe/public/dist/css" \
    "$dir/sites/$site" "$dir/sites/assets" "$dir/env/bin" "$dir/logs" "$dir/config"
  printf 'frappe\nerpnext\n' >"$dir/sites/apps.txt"
  printf '%s\n' "$site" >"$dir/sites/currentsite.txt"
  printf '{}\n' >"$dir/sites/$site/site_config.json"
  cat >"$dir/sites/common_site_config.json" <<JSON
{
 "default_site": "$site",
 "redis_cache": "redis://127.0.0.1:13000",
 "redis_queue": "redis://127.0.0.1:11000",
 "socketio_port": 9000,
 "webserver_port": 8000
}
JSON
  printf 'x\n' >"$dir/apps/frappe/frappe/public/dist/js/desk.bundle.ABC123.js"
  printf 'x\n' >"$dir/apps/frappe/frappe/public/dist/css/desk.bundle.DEF456.css"
  ln -s "$dir/apps/frappe/frappe/public" "$dir/sites/assets/frappe"
  cat >"$dir/sites/assets/assets.json" <<JSON
{
    "desk.bundle.js": "/assets/frappe/dist/js/desk.bundle.ABC123.js",
    "desk.bundle.css": "/assets/frappe/dist/css/desk.bundle.DEF456.css"
}
JSON
  make_fake_env_python "$dir"
  printf 'redis_cache: redis-server config/redis_cache.conf\nweb: bench serve --port 8000\n' >"$dir/Procfile"
}

make_fake_env_python() {
  local dir="$1"
  mkdir -p "$dir/env/bin"
  cat >"$dir/env/bin/python" <<'PY'
#!/bin/bash
case "$*" in
  *version_info*) echo "3.11" ;;
  --version) echo "Python 3.11.9" ;;
  *) exit 0 ;;
esac
PY
  chmod +x "$dir/env/bin/python"
}

# add_proc PID CMDLINE: adds a line to the fake process table used by pgrep/pkill
add_proc() { printf '%s %s\n' "$1" "$2" >>"$MOCK_PROCS"; printf '%s %s\n' "$1" "$2" >>"$MOCK_STATE/ever_procs"; }
# add_listener PORT PID CMD ADDR: a fake TCP listener for the lsof mock
add_listener() { printf '%s %s %s %s\n' "$1" "$2" "$3" "${4:-127.0.0.1}" >>"$MOCK_LISTEN"; }
# set_agent LABEL STATE PID EXIT: a fake loaded launchd agent
set_agent() {
  printf 'state = %s\npid = %s\nlast exit code = %s\n' "$2" "${3:-}" "${4:-0}" >"$MOCK_STATE/agents/$1"
}
