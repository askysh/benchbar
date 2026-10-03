#!/usr/bin/env bash
# Redaction: fl_redact_stream (one set of rules for the report and for
# logs --json), the URL credential filter on the run log, the last command
# and env-provided answers, and the logs --json line cap.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
. "$ROOT/lib/frappe-local/ui.sh"
. "$ROOT/lib/frappe-local/run.sh"
. "$ROOT/lib/frappe-local/report.sh"

# ---- fl_redact_stream: every shape goes, the line count stays
IN="$TMP_DIR/in.log"
cat >"$IN" <<'LOG'
redis_cache: redis://:RedisPw77@127.0.0.1:13000 ready
cloning https://bob:ghp_abcdefghijklmnopqrstuvwxyz0123@github.com/acme/app.git
jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJVadQssw5c in a header
github_pat_11ABCDEFG0123456789abcdefghijkl and ghs_ABCDEFGHIJKLMNOPQRSTUVWXYZ
slack xoxb-1234567890-abcdefghij and openai sk-abcdefghijklmnopqrstuvwxyz1234 and aws AKIAIOSFODNN7EXAMPLE
mail from bob.smith+dev@example.co.uk, cc <alice@example.org>.
frappe.connect(password='pw with space', pwd='short1', passwd="dq pw")
bench new-site x --password=argvPw9 --db-root-password=rootPw8 done
ssh clone git@github.com:acme/app.git ok
plain line with nothing to hide
LOG
out="$(fl_redact_stream <"$IN")"
assert_eq "$(wc -l <"$IN" | tr -d ' ')" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "(the line count is unchanged)"
for secret in RedisPw77 ghp_abcdefghijklmnopqrstuvwxyz0123 'bob:ghp_' SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJVadQssw5c eyJhbGciOiJIUzI1NiJ9 \
  github_pat_11ABCDEFG0123456789abcdefghijkl ghs_ABCDEFGHIJKLMNOPQRSTUVWXYZ xoxb-1234567890-abcdefghij sk-abcdefghijklmnopqrstuvwxyz1234 \
  AKIAIOSFODNN7EXAMPLE bob.smith+dev@example.co.uk alice@example.org 'pw with space' short1 'dq pw' argvPw9 rootPw8; do
  assert_not_contains "$out" "$secret" "(fl_redact_stream must mask it)"
done
# the masked forms stay readable, and what is not a secret stays
assert_contains "$out" "redis://***@127.0.0.1:13000 ready"
assert_contains "$out" "https://***@github.com/acme/app.git"
assert_contains "$out" "mail from <email>, cc <<email>>."
assert_contains "$out" "password=***, pwd=***, passwd=***)"
assert_contains "$out" "bench new-site x --password=***"
assert_contains "$out" "git@github.com:acme/app.git ok" "(an SSH clone URL is not an email)"
assert_contains "$out" "plain line with nothing to hide"
# a stream with no secret comes out byte for byte
printf 'a\nb\n' | fl_redact_stream >"$TMP_DIR/plain"
assert_eq "a
b" "$(cat "$TMP_DIR/plain")"

# token shapes need a left boundary; pwd only as a keyword argument; emails need a dotted domain, never .local
cat >"$IN" <<'LOG'
queue /tmp/task-2026-10-03-worker-default-queue and class .desk-sidebar-item-container-wrapper stay
key sk-abcdefghijklmnopqrstuvwxyz0123456789ABCD goes, x-ghp_abcdefghijklmnopqrstuvwxyz0123 stays, token=ghp_abcdefghijklmnopqrstuvwxyz0123 goes
PWD=/Users/bob/dev/frappe-bench OLDPWD=/Users/bob
db.connect(pwd='kwPw1', host='db') and f(a=1, pwd="kwPw2")
rq:worker:worker@Bobs-MacBook.local started by root@localhost for bob@example.com and eve@mail.example.co.uk
LOG
out="$(fl_redact_stream <"$IN")"
assert_contains "$out" "queue /tmp/task-2026-10-03-worker-default-queue and class .desk-sidebar-item-container-wrapper stay"
assert_contains "$out" "key *** goes, x-ghp_abcdefghijklmnopqrstuvwxyz0123 stays, token=***"
assert_not_contains "$out" "sk-abcdefghijklmnopqrstuvwxyz0123456789ABCD"
assert_contains "$out" "PWD=/Users/bob/dev/frappe-bench OLDPWD=/Users/bob"
assert_contains "$out" "db.connect(pwd=***, host='db') and f(a=1, pwd=***)"
assert_contains "$out" "rq:worker:worker@Bobs-MacBook.local started by root@localhost for <email> and <email>"

# ---- fl_redact_url: only the user:token part of a URL, no process without an @
assert_eq "clone https://***@github.com/x/y.git now" "$(fl_redact_url "clone https://user:tok3n@github.com/x/y.git now")"
assert_eq "redis://***@127.0.0.1:13000" "$(fl_redact_url "redis://:pw@127.0.0.1:13000")"
assert_eq "no url here" "$(fl_redact_url "no url here")"
assert_eq "git@github.com:acme/app.git" "$(fl_redact_url "git@github.com:acme/app.git")"
v=""; fl_redact_url_v v "a https://u:p@h/x b https://q:r@k/y"
assert_eq "a https://***@h/x b https://***@k/y" "$v"

# ---- the run log, the failure message and FL_LAST_COMMAND never carry the token
URL="https://user:tok3n@github.com/x/y.git"
# shellcheck disable=SC2016  # $1 is for the script
printf '#!/usr/bin/env bash\necho "cloning $1"\nexit 3\n' >"$TMP_DIR/failing"; chmod +x "$TMP_DIR/failing"
fl_log_init "$TMP_DIR/logs"
LOGF="$FL_LOG_FILE"
set +e
fl_run_long "clone the app" "$TMP_DIR/failing" "$URL" >"$TMP_DIR/out" 2>&1; code=$?
set -e
out="$(cat "$TMP_DIR/out")"
assert_eq "3" "$code"
assert_not_contains "$out" "tok3n"
assert_contains "$out" "command: ${TMP_DIR}/failing https://***@github.com/x/y.git"
assert_not_contains "$(cat "$LOGF")" "tok3n"
assert_contains "$(cat "$LOGF")" "run: ${TMP_DIR}/failing https://***@github.com/x/y.git"
assert_eq "${TMP_DIR}/failing https://***@github.com/x/y.git" "$FL_LAST_COMMAND"
# fl_run, fl_run_with_timeout and fl_log itself
FL_LAST_COMMAND=""
fl_run "$TMP_DIR/failing" "$URL" >/dev/null 2>&1 || true
assert_eq "${TMP_DIR}/failing https://***@github.com/x/y.git" "$FL_LAST_COMMAND"
set +e
out="$(fl_run_with_timeout 5 "timed clone" "$TMP_DIR/failing" "$URL" 2>&1)"
set -e
assert_not_contains "$out" "tok3n"
fl_log "note: see ${URL} and redis://:pw@127.0.0.1"
assert_not_contains "$(cat "$LOGF")" "tok3n"
assert_contains "$(cat "$LOGF")" "note: see https://***@github.com/x/y.git and redis://***@127.0.0.1"
# fl_on_error prints the redacted command
set +e
out="$( (fl_run "$TMP_DIR/failing" "$URL" >/dev/null 2>&1 || fl_on_error) 2>&1 )"
set -e
assert_contains "$out" "Last command failed with exit code 3: ${TMP_DIR}/failing https://***@github.com/x/y.git"
assert_not_contains "$out" "tok3n"
# an env-provided answer is echoed without its credentials
out="$(APP_URL="$URL" fl_ask APP_URL "App git URL")"
assert_contains "$out" "using env-provided APP_URL=https://***@github.com/x/y.git"
assert_not_contains "$out" "tok3n"
assert_not_contains "$(cat "$LOGF")" "tok3n"
# a hint on fl_die is redacted on the terminal too
set +e
out="$( (fl_die "clone failed" "Run: git clone ${URL}") 2>&1 )"
set -e
assert_contains "$out" "Run: git clone https://***@github.com/x/y.git"
assert_not_contains "$out" "tok3n"

# ---- logs --json: redacted lines, and the line count is capped at 2000
BENCH="$HOME/frappe-bench"
make_fake_bench "$BENCH"
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
{
  i=1
  while [[ "$i" -le 2100 ]]; do printf '10:00:03 worker.1      | job %d\n' "$i"; i=$((i + 1)); done
  printf '10:00:04 redis_cache.1 | redis://:RedisSecret1@127.0.0.1:13000 ready\n'
  printf '10:00:05 web.1         | {"api_key": "ApiLeak2", "db_name": "_abc"}\n'
} >"$BENCH/logs/bench.log"
run_fm logs --json --no-follow -n5000 --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_eq "2000" "$(printf '%s' "$OUT" | jget - 'len(d["lines"])')"
assert_eq "2000" "$(printf '%s' "$OUT" | jget - 'd["truncated_to"]')"
assert_eq "job 2100" "$(printf '%s' "$OUT" | jget - 'd["lines"][-3].split("| ")[1]')" "(the newest lines are kept)"
run_fm logs --json --no-follow -n2000 --bench-dir "$BENCH"
assert_eq "2000" "$(printf '%s' "$OUT" | jget - 'len(d["lines"])')"
assert_eq "False" "$(printf '%s' "$OUT" | jget - '"truncated_to" in d')" "(no key when nothing was clamped)"
run_fm logs --json --no-follow -n2102 --process web --bench-dir "$BENCH"
assert_eq "1" "$(printf '%s' "$OUT" | jget - 'len(d["lines"])')"
assert_eq "2000" "$(printf '%s' "$OUT" | jget - 'd["truncated_to"]')" "(the cap is on the request, whatever the filter leaves)"
run_fm logs --json --no-follow -n2 --bench-dir "$BENCH"
assert_not_contains "$OUT" "RedisSecret1"
assert_not_contains "$OUT" "ApiLeak2"
assert_contains "$OUT" 'redis://***@127.0.0.1:13000 ready'
assert_contains "$OUT" '{\"api_key\": \"***\", \"db_name\": \"_abc\"}'
# the plain text form is the user's own log: untouched
run_fm logs --no-follow -n2 --bench-dir "$BENCH"
assert_contains "$OUT" "RedisSecret1"

printf 'test-redact: ok\n'
