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
# resolved (/var is /private/var on macOS): the CLI resolves bench paths too
TMP_DIR="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/benchbar-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$TMP_DIR"' EXIT

export HOME="$TMP_DIR/home"
export MOCK_STATE="$TMP_DIR/mock"
export MOCK_LOG="$MOCK_STATE/calls.log"
export MOCK_PROCS="$MOCK_STATE/procs"
export MOCK_LISTEN="$MOCK_STATE/listen"
export MOCK_BREW_PREFIX="$TMP_DIR/brew"
export MOCK_BREW_INSTALLED="python@3.11 node@20 mariadb@10.11 redis openssl@3 libffi zlib pipx pkgconf mariadb-connector-c"
export MOCK_BREW_LEAVES="$MOCK_STATE/leaves"
export MOCK_BREW_SERVICES="$MOCK_STATE/services"
export MOCK_CURL_CODE="000"
export MOCK_PIPX_HOME="$HOME/.local/pipx"
export FL_STATE_DIR="$TMP_DIR/state"
export FL_STATE_FILE="$FL_STATE_DIR/state.env"
export FL_BACKUP_ROOT="$TMP_DIR/state/backups"
export FL_HOSTS_FILE="$TMP_DIR/hosts"
# where the official wkhtmltopdf package would put its binary (tests never look at /usr/local)
export FL_WKHTML_PKG_BIN="$TMP_DIR/usr-local-bin/wkhtmltopdf"
export FL_RC_FILE="$HOME/.zshrc"
export FL_UP_WAIT_SECS=2
export FL_KILL_CMD=mockkill
export BENCHBAR_KILL_CMD=mockkill
export FL_APP_DIRS="$HOME/Applications"
# a name that is on no PATH, so the Mac running the suite does not leak its own Mole
export FL_MOLE_CMDS=benchbar-test-no-mole
export NO_COLOR=1
# the suite may run as root on a Linux machine; the CLI must still see a normal user
export FL_EFFECTIVE_UID=501
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
mkdir -p "$MOCK_BREW_PREFIX/bin"
# on the bench's (launchd) PATH, which does not include tests/mocks/bin
cp "$ROOT/tests/mocks/bin/pkg-config" "$ROOT/tests/mocks/bin/_mocklib.sh" "$MOCK_BREW_PREFIX/bin/"
chmod +x "$MOCK_BREW_PREFIX"/opt/*/bin/*
# MariaDB runs on 3306 on a set up machine (tests of a stopped server clear this)
printf '3306 111 mariadbd 127.0.0.1\n' >"$MOCK_LISTEN"
printf '127.0.0.1 localhost\n' >"$FL_HOSTS_FILE"
printf '[client-server]\n!includedir %s/etc/my.cnf.d\n' "$MOCK_BREW_PREFIX" >"$MOCK_BREW_PREFIX/etc/my.cnf.d/../my.cnf"
printf '# test zshrc\nexport EDITOR=vim\n' >"$HOME/.zshrc"
# the utf8mb4 drop-in is in place on a set up machine; tests of phase 00 remove it first
SCRIPT_DIR="$ROOT" bash -c '. "$1/lib/frappe-local/ui.sh"; . "$1/lib/frappe-local/templates.sh"; fl_template_render mariadb-frappe.cnf' _ "$ROOT" \
  >"$MOCK_BREW_PREFIX/etc/my.cnf.d/frappe.cnf"
# config with the checksum of the mocked wkhtmltopdf download (the curl mock writes "stub download")
export FL_CONFIG_DIR="$TMP_DIR/config"
mkdir -p "$FL_CONFIG_DIR"; cp "$ROOT"/config/*.tsv "$FL_CONFIG_DIR/"
printf 'stub download\n' >"$MOCK_STATE/download_payload"
STUB_SHA="$(shasum -a 256 "$MOCK_STATE/download_payload" | awk '{print $1}')"
sed "s/81a66b77b508fede8dbcaa67127203748376568b3673a17f6611b6d51e9894f8/${STUB_SHA}/" "$ROOT/config/wkhtmltopdf.tsv" >"$FL_CONFIG_DIR/wkhtmltopdf.tsv"
cp "$ROOT/tests/mocks/honcho" "$MOCK_PIPX_HOME/venvs/frappe-bench/bin/honcho"
chmod +x "$MOCK_PIPX_HOME/venvs/frappe-bench/bin/honcho"
export PATH="$ROOT/tests/mocks/bin:$PATH"

FM="$ROOT/benchbar"
# the CLI's own version, so a release bump needs no test edits
VER="$(sed -n 's/^FL_VERSION="\(.*\)"$/\1/p' "$FM")"

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
# BSD stat on macOS, GNU stat on Linux (the suite also runs on Linux machines).
if stat --version >/dev/null 2>&1; then STAT_GNU=1; else STAT_GNU=0; fi
# sed_inplace SCRIPT FILE: edit a file in place without the BSD/GNU "-i" difference
sed_inplace() { sed "$1" "$2" >"$2.tmp" && mv "$2.tmp" "$2"; }
# mtime_of FILE: modification time in seconds
mtime_of() { if [[ "$STAT_GNU" == "1" ]]; then stat -c %Y "$1"; else stat -f %m "$1"; fi; }

# Snapshot of every file (path, size, mtime) under the given dirs, for
# "second run writes nothing" assertions.
snapshot() {
  find "$@" -type f 2>/dev/null | sort | while IFS= read -r f; do
    if [[ "$STAT_GNU" == "1" ]]; then stat -c '%n %s %Y' "$f"; else stat -f '%N %z %m' "$f"; fi
  done
}

# ---------------------------------------------------------------- fake bench

make_fake_bench() {
  local dir="$1" site="${2:-macdev}"
  mkdir -p "$dir/apps/frappe/node_modules/socket.io" "$dir/apps/frappe/frappe/public/dist/js" "$dir/apps/frappe/frappe/public/dist/css" \
    "$dir/sites/$site" "$dir/sites/assets" "$dir/env/bin" "$dir/logs" "$dir/config" "$dir/apps/erpnext"
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
  cp "$ROOT/tests/mocks/env-python" "$dir/env/bin/python"
  chmod +x "$dir/env/bin/python"
}

# add_proc PID CMDLINE: adds a line to the fake process table used by pgrep/pkill
# add_proc PID CMDLINE [CWD]: CWD is what lsof reports as its working folder
add_proc() {
  printf '%s %s\n' "$1" "$2" >>"$MOCK_PROCS"; printf '%s %s\n' "$1" "$2" >>"$MOCK_STATE/ever_procs"
  if [[ -n "${3:-}" ]]; then mkdir -p "$MOCK_STATE/cwd"; printf '%s' "$3" >"$MOCK_STATE/cwd/$1"; fi
}
# add_listener PORT PID CMD ADDR: a fake TCP listener for the lsof mock
add_listener() { printf '%s %s %s %s\n' "$1" "$2" "$3" "${4:-127.0.0.1}" >>"$MOCK_LISTEN"; }
# keychain_get: the MariaDB root password the security mock stored
keychain_get() { cat "$MOCK_STATE/keychain/benchbar-mariadb--root" 2>/dev/null || true; }
# mariadb_pw: the root password the mariadb mock currently expects (empty: none)
mariadb_pw() { cat "$MOCK_STATE/mariadb_root_pw" 2>/dev/null || true; }
# set_agent LABEL STATE PID EXIT: a fake loaded launchd agent
set_agent() {
  printf 'state = %s\npid = %s\nlast exit code = %s\n' "$2" "${3:-}" "${4:-0}" >"$MOCK_STATE/agents/$1"
}

# jget FILE_OR_DASH EXPR: evaluates a Python expression on the parsed JSON
# document `d` (reads stdin for "-"), for asserting JSON output.
jget() {
  local src="$1" expr="$2"
  if [[ "$src" == "-" ]]; then
    python3 -c "import json,sys; d=json.load(sys.stdin); print($expr)"
  else
    python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($expr)" "$src"
  fi
}
