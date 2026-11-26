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

# run_in INPUT ARGS...: benchbar with INPUT on standard input (a pipe, never a terminal)
run_in() {
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

# ---- --background: the detached run reads them from a pipe, and has them in no environment
fresh
set +e
OUT="$(printf 'ADMIN_PASSWORD=%s\nMARIADB_ROOT_PASSWORD=%s\n' "$ADMIN" "$ROOT_PW" | MOCK_ENV_DUMP=1 "$FM" install --offline --background --yes --json --secrets-stdin --bench-dir "$BENCH" --site macdev 2>&1)"
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
