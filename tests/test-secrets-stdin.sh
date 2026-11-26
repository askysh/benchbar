#!/usr/bin/env bash
# The secret channel (askysh/benchbar#167): install --secrets-stdin takes the
# Administrator and MariaDB root passwords from standard input, so they are
# never in the environment of benchbar, a phase script or any child (where
# /proc/PID/environ shows them for the whole run). Held here: they reach the
# step that needs them, they are in no environment (a mock dumps what it
# sees, and on Linux the ancestors' /proc/PID/environ), no output, run log,
# history or op record, an unknown key is refused before anything changes, the
# environment still works, --background hands them on a pipe, and a command
# that does not take the flag refuses it.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

add_proc 900 "mariadbd --datadir=/x"
add_proc 901 "redis-server *:6379"
printf 'mariadb@10.11 started akash file\nredis started akash file\n' >"$MOCK_BREW_SERVICES"
BENCH="$HOME/frappe-bench"
ADMIN='Adm1n-sTdIn-0451'
ROOT_PW='rootpw'

# run_in INPUT ARGS...: benchbar with INPUT and then an empty line on standard input (a pipe, never a terminal);
# run_raw sends INPUT as it is
run_in() {
  local input="$1"
  shift
  set +e
  OUT="$(printf '%s
' "$input" | "$FM" "$@" 2>&1)"
  CODE=$?
  set -e
}
run_raw() {
  local input="$1"
  shift
  set +e
  OUT="$(printf '%s' "$input" | "$FM" "$@" 2>&1)"
  CODE=$?
  set -e
}
fresh() {
  rm -rf "$BENCH" "$MOCK_STATE/env" "$MOCK_STATE/sudo_probe" "$MOCK_STATE/stdin-new-site"
  rm -f "$MOCK_STATE/keychain/benchbar-mariadb--root" "$MOCK_STATE/sudo_cred" "$FL_STATE_DIR/history.jsonl"
  printf '%s' "$ROOT_PW" >"$MOCK_STATE/mariadb_root_pw"
  touch "$MOCK_STATE/wkhtml_missing"; rm -f "$MOCK_STATE/wkhtml_installed"
  printf '127.0.0.1 localhost\n' >"$FL_HOSTS_FILE"
  : >"$FL_STATE_FILE"
  reset_calls
}
# leaked NAME: the password variables a mock saw in its environment
leaked() { grep -E '^(MARIADB_ROOT_PASSWORD|ADMIN_PASSWORD)=' "$MOCK_STATE/env/$1" 2>/dev/null || true; }
# ancestors: the processes above a mock that had a password in /proc/PID/environ (Linux only)
ancestors() { cat "$MOCK_STATE"/env/* 2>/dev/null | grep '^ancestor ' || true; }
# no_secret LABEL: the passwords are in no output, no run log, no history, no op record
no_secret() {
  assert_not_contains "$OUT" "$ADMIN" "(output) $1"
  assert_not_contains "$(cat "$MOCK_LOG")" "$ADMIN" "(mock calls) $1"
  if grep -rqF -- "$ADMIN" "$FL_STATE_DIR" 2>/dev/null; then fail "the Administrator password is in the state folder: $1 ($(grep -rlF -- "$ADMIN" "$FL_STATE_DIR" | tr '\n' ' '))"; fi
  if grep -rqF -- "$ROOT_PW" "$FL_STATE_DIR/logs" "$FL_STATE_DIR/history.jsonl" "$FL_STATE_DIR/ops" 2>/dev/null; then fail "the root password is in a log, the history or an op record: $1"; fi
}

# ---- the passwords on stdin reach the step that needs them, and no environment has them
fresh
MOCK_ENV_DUMP=1 run_in "ADMIN_PASSWORD=${ADMIN}
MARIADB_ROOT_PASSWORD=${ROOT_PW}
" install --offline --yes --secrets-stdin --bench-dir "$BENCH" --site macdev
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain "^bench new-site macdev"
assert_eq "${ROOT_PW} ${ADMIN}" "$(tr '\n' ' ' <"$MOCK_STATE/stdin-new-site" | sed 's/ $//')" "(new-site got both on its stdin)"
assert_file "$MOCK_STATE/env/bench" "(the bench mock must have run)"
assert_eq "" "$(leaked bench)" "(bench saw a password variable)"
assert_eq "" "$(leaked brew)" "(brew saw a password variable)"
assert_eq "" "$(leaked yarn)" "(yarn saw a password variable)"
assert_eq "" "$(ancestors)" "(a process above a mock had a password in /proc/PID/environ)"
assert_no_file "$MOCK_STATE/mysql_pwd_seen" "(a mariadb client got MYSQL_PWD in its environment)"
assert_calls_contain "^mariadb --defaults-extra-file=/dev/fd/[0-9]+ -u root" "(the root password went in an option file that is a pipe, the first option)"
assert_calls_not_contain "^mariadb .*( --password| -p)" "(no client call carries it on its command line)"
no_secret "stdin install"

# the same run as a stream: the done line and the plan carry no password either
fresh
run_in "ADMIN_PASSWORD=${ADMIN}
MARIADB_ROOT_PASSWORD=${ROOT_PW}
" install --offline --yes --json --secrets-stdin --bench-dir "$BENCH" --site macdev
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" '"event":"done"'
no_secret "stdin install --json"

# an empty line ends the list: what follows is not read as a secret (it stays on stdin for the caller)
fresh
run_in "ADMIN_PASSWORD=${ADMIN}
MARIADB_ROOT_PASSWORD=${ROOT_PW}

not-a-secret-line
" install --offline --yes --secrets-stdin --bench-dir "$BENCH" --site macdev
assert_eq "0" "$CODE" "$OUT"

# ---- refusals: before anything is changed, and never with the value in the message
fresh
snap="$(find "$HOME" -type f 2>/dev/null | wc -l | tr -d ' ')"
for bad in "FOO=bar" "ADMIN_PASSWORD=${ADMIN}
ADMIN_PASSWORD=${ADMIN}" "${ADMIN}" "ADMIN_PASSWORD=${ADMIN}"$'\r'; do
  run_in "$bad
" install --offline --yes --secrets-stdin --bench-dir "$BENCH" --site macdev
  assert_eq "64" "$CODE" "$OUT"
  assert_contains "$OUT" "standard input"
  assert_contains "$OUT" "Nothing was changed"
  assert_not_contains "$OUT" "$ADMIN" "(a refusal must not print the line)"
  assert_not_contains "$OUT" "FOO" "(nor the key it refused)"
  assert_no_file "$BENCH"
done
assert_contains "$OUT" "carriage return"
run_in "FOO=bar
" install --offline --yes --json --secrets-stdin --bench-dir "$BENCH" --site macdev
assert_eq "64" "$CODE" "$OUT"
assert_contains "$OUT" "secrets_stdin_invalid"
assert_eq "$snap" "$(find "$HOME" -type f 2>/dev/null | wc -l | tr -d ' ')" "(a refusal writes nothing)"
assert_calls_not_contain "^(brew|bench|sudo) "

# the same refusals on every bash: a half value, an empty list, a long line, a joined key
for bad in "ADMIN_PASSWORD=half" "" "ADMIN_PASSWORD=$(printf 'a%.0s' $(seq 1 5000))
" "ADMIN_PASSWORD MARIADB_ROOT_PASSWORD=x
" "BENCHBAR_SUDO_PASSWORD=x
" "admin_password=x
"; do
  run_raw "$bad" install --offline --yes --secrets-stdin --bench-dir "$BENCH" --site macdev
  assert_eq "64" "$CODE" "${OUT:0:300}"
  assert_contains "$OUT" "Nothing was changed"
  assert_not_contains "$OUT" "half" "(a refusal must not print the value)"
  assert_no_file "$BENCH"
done
assert_contains "$OUT" "not accepted" "(lower case is not a key)"
run_raw "ADMIN_PASSWORD=half" install --offline --yes --secrets-stdin --bench-dir "$BENCH" --site macdev
assert_contains "$OUT" "no LF"
run_in "" install --offline --yes --secrets-stdin --bench-dir "$BENCH" --site macdev
assert_contains "$OUT" "empty"
run_raw "" install --offline --yes --secrets-stdin --bench-dir "$BENCH" --site macdev
assert_contains "$OUT" "not ended by an empty line"
run_raw "ADMIN_PASSWORD=${ADMIN}
" install --offline --yes --secrets-stdin --bench-dir "$BENCH" --site macdev
assert_contains "$OUT" "not ended by an empty line" "(a closed input without the empty line)"
run_in "BENCHBAR_SUDO_PASSWORD=x
" install --offline --yes --secrets-stdin --bench-dir "$BENCH" --site macdev
assert_contains "$OUT" "BENCHBAR_SUDO=env"
# a caller that keeps stdin open and never ends the list: a timeout is a refusal, not the end of the list
set +e
OUT="$( (printf 'ADMIN_PASSWORD=x
'; sleep 4) | FL_SECRETS_WAIT=1 "$FM" install --offline --yes --secrets-stdin --bench-dir "$BENCH" --site macdev 2>&1)"
CODE=$?
set -e
assert_eq "64" "$CODE" "$OUT"
assert_contains "$OUT" "not ended by an empty line"
assert_no_file "$BENCH"
# a missing password under --secrets-stdin says how to send it
run_in "MARIADB_ROOT_PASSWORD=${ROOT_PW}
" install --offline --yes --json --secrets-stdin --bench-dir "$BENCH" --site macdev
assert_contains "$OUT" "ADMIN_PASSWORD was not sent"

# bash -x: the trace of the channel's own code (read, take, hand over) shows no value. A dry run goes
# through all of it: the parent reads stdin, the phase scripts read fd 7
fresh
trace="$(printf 'ADMIN_PASSWORD=%s
MARIADB_ROOT_PASSWORD=%s

' "$ADMIN" "R00t-xTrace-77" | bash -x "$FM" install --offline --dry-run --yes --secrets-stdin --bench-dir "$BENCH" --site macdev 2>&1 >/dev/null || true)"
assert_contains "$trace" "fl__secrets_read" "(the trace is the run's)"
assert_not_contains "$trace" "$ADMIN" "(xtrace)"
assert_not_contains "$trace" "R00t-xTrace-77" "(xtrace)"

# ---- the examples of the docs run as written (a copied example must not exit 64)
# the block of docs/reference/cli/install.md, with benchbar replaced by this checkout, and a dry run added
fresh
block="$(awk '/^### Passwords without the environment/{f=1} f&&/^```bash/{b=1;next} b&&/^```/{exit} b' "$ROOT/docs/reference/cli/install.md")"
[[ -n "$block" ]] || fail "no example under 'Passwords without the environment' in docs/reference/cli/install.md"
assert_contains "$block" "--secrets-stdin"
example="${block//benchbar install/\"\$FM\" install --offline --dry-run --bench-dir \"\$BENCH\" --site macdev}"
set +e
OUT="$(ADMIN="$ADMIN" ROOT="$ROOT_PW" FM="$FM" BENCH="$BENCH" bash -c "$example" 2>&1)"
CODE=$?
set -e
assert_eq "0" "$CODE" "(the example of the install reference) $OUT"
# every printf example of a secret list in the docs ends the list with an empty line
for doc in docs/reference/cli/install.md docs/guides/agents.md docs/windows.md docs/windows-tray.md AGENTS.md; do
  while IFS= read -r l; do
    case "$l" in
      *'\n\n'*) ;;
      *) fail "$doc: an example of the secret list has no empty line at its end: $l" ;;
    esac
  done < <(grep -F "printf 'ADMIN_PASSWORD=" "$ROOT/$doc" || true)
done
assert_not_contains "$(grep -rh "secrets-stdin" "$ROOT/lib/frappe-local/secrets.sh" "$ROOT/docs" "$ROOT/AGENTS.md" "$ROOT/changelog.d/167-secrets-stdin.md")" "or the end of the input" "(the old rule is gone from every text)"

# ---- xtrace: the code a phase script and the libraries run once they hold the passwords prints none
fresh
X_ADMIN='Adm1n-xT-5521'; X_ROOT='R00t-xT-5521'
# a phase script run by hand, as benchbar starts it: the passwords on fd 7, the whole script traced
for ph in 00-mac-system-deps.sh 01-install-bench-and-site.sh; do
  trace="$(BENCH_DIR="$BENCH" SITE_NAME=macdev FL_SECRETS_FD=7 bash -x "$ROOT/$ph" --yes --offline --dry-run 7< <(printf 'ADMIN_PASSWORD=%s\nMARIADB_ROOT_PASSWORD=%s\n\n' "$X_ADMIN" "$X_ROOT") 2>&1 >/dev/null || true)"
  assert_contains "$trace" "fl_secrets_fd_take" "($ph: the trace is the script's)"
  assert_not_contains "$trace" "$X_ADMIN" "($ph under bash -x)"
  assert_not_contains "$trace" "$X_ROOT" "($ph under bash -x)"
done
# the functions that take a password, called with a known one after the channel gave it
cat >"$TMP_DIR/xtrace-libs.sh" <<'XT'
. "$ROOT/lib/frappe-local/ui.sh"
. "$ROOT/lib/frappe-local/run.sh"
. "$ROOT/lib/frappe-local/platform.sh"
. "$ROOT/lib/frappe-local/secrets.sh"
. "$ROOT/lib/frappe-local/state.sh"
. "$ROOT/lib/frappe-local/mariadb.sh"
fl_secrets_fd_take
fl_mariadb_root_verify "$MARIADB_ROOT_PASSWORD" || true
fl_mariadb_db_exists "$MARIADB_ROOT_PASSWORD" _abc123 || true
fl_mariadb_db_fresh "$MARIADB_ROOT_PASSWORD" _abc123 || true
fl_mariadb_server_charset "$MARIADB_ROOT_PASSWORD" >/dev/null || true
echo "[$(fl_mariadb_cnf "$MARIADB_ROOT_PASSWORD" | wc -l | tr -d ' ')]"
XT
trace="$(ROOT="$ROOT" FL_SECRETS_FD=7 bash -x "$TMP_DIR/xtrace-libs.sh" 7< <(printf 'MARIADB_ROOT_PASSWORD=%s\n\n' "$X_ROOT") 2>&1 || true)"
assert_contains "$trace" "fl_secrets_fd_take" "(the trace is the script's)"
assert_contains "$trace" "[2]" "(the option file has two lines: the functions ran)"
assert_not_contains "$trace" "$X_ROOT" "(the libraries under bash -x)"

# ---- the option file: a line break, a backslash, a quote and a hash are escaped, never lost
cat >"$TMP_DIR/cnf.sh" <<'XT'
. "$ROOT/lib/frappe-local/mariadb.sh"
fl_mariadb_cnf "$1"
XT
nlpw=$'ab\ncd'
assert_eq '[client]
password="ab\ncd"' "$(ROOT="$ROOT" bash "$TMP_DIR/cnf.sh" "$nlpw")" "(a line break is written \n)"
assert_eq '[client]
password="a\\b\"c#d e"' "$(ROOT="$ROOT" bash "$TMP_DIR/cnf.sh" 'a\b"c#d e')" "(backslash, quote, hash and space)"

# a terminal on stdin is refused at once, not waited on
run_fm_tty install --offline --yes --secrets-stdin --bench-dir "$BENCH" --site macdev
assert_eq "64" "$CODE" "$OUT"
assert_contains "$OUT" "is a terminal"

# a command that has no secret does not take the flag
run_in "ADMIN_PASSWORD=x
" up --secrets-stdin
assert_eq "64" "$CODE" "$OUT"
assert_contains "$OUT" "Unknown option for up: --secrets-stdin"
# the flag is in the command table for the ones that take it: the tray looks for it there
run_fm install --help
assert_contains "$OUT" "--secrets-stdin"
run_fm commands --json
assert_contains "$OUT" "--secrets-stdin"

# ---- the environment keeps working, and the phase scripts still do not pass it on
fresh
MOCK_ENV_DUMP=1 MARIADB_ROOT_PASSWORD="$ROOT_PW" ADMIN_PASSWORD="$ADMIN" run_fm install --offline --yes --bench-dir "$BENCH" --site macdev
assert_eq "0" "$CODE" "$OUT"
assert_eq "${ROOT_PW} ${ADMIN}" "$(tr '\n' ' ' <"$MOCK_STATE/stdin-new-site" | sed 's/ $//')"
assert_eq "" "$(leaked bench)" "(bench saw a password variable)"
assert_eq "" "$(leaked brew)" "(brew saw a password variable)"
assert_no_file "$MOCK_STATE/mysql_pwd_seen" "(a mariadb client got MYSQL_PWD in its environment)"

# ---- --background: the detached run reads them from a pipe, and has them in no environment
fresh
set +e
OUT="$(printf 'ADMIN_PASSWORD=%s\nMARIADB_ROOT_PASSWORD=%s\n\n' "$ADMIN" "$ROOT_PW" | MOCK_ENV_DUMP=1 "$FM" install --offline --background --yes --json --secrets-stdin --bench-dir "$BENCH" --site macdev 2>&1)"
CODE=$?
set -e
assert_eq "0" "$CODE" "$OUT"
BG="$(printf '%s' "$OUT" | sed -n 's/.*"op_id":"\([^"]*\)".*/\1/p')"
[[ -n "$BG" ]] || fail "no op_id in: $OUT"
set +e
WAIT="$("$FM" op wait "$BG" --timeout 120 --json 2>&1 </dev/null)"
CODE=$?
set -e
assert_eq "0" "$CODE" "$WAIT"
assert_eq "${ROOT_PW} ${ADMIN}" "$(tr '\n' ' ' <"$MOCK_STATE/stdin-new-site" | sed 's/ $//')" "(the detached run created the site with them)"
assert_eq "" "$(leaked bench)" "(bench saw a password variable)"
assert_eq "" "$(ancestors)" "(the detached run had a password in /proc/PID/environ)"
OUT="$OUT$WAIT"
no_secret "stdin install --background"
