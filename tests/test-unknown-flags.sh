#!/usr/bin/env bash
# CORE-3: an unknown flag is an error (exit 64, EX_USAGE, never 2 which means the MariaDB root password is
# unknown; the flag and the command's usage line named), a flag with no value is an error too, BENCHBAR_LENIENT_FLAGS=1 turns the error into a warning, and every
# flag a command really accepts is in the table (benchbar COMMAND --help, commands --json).
# shellcheck disable=SC2016  # single quoted snippets expand inside the child bash
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/frappe-bench"; make_fake_bench "$BENCH"

# ---- the typos that used to run for real
for pair in "status|--bogus" "list|--bogus" "doctor|--dry-rn" "down|--force" "restart|--hard" \
            "repair|--dry-rn" "path|--bogus" "where|--bogus" "install|--dryrun"; do
  cmd="${pair%%|*}"; flag="${pair##*|}"
  run_fm "$cmd" "$flag" --yes --bench-dir "$BENCH"
  assert_eq "64" "$CODE" "benchbar $cmd $flag: $OUT"
  assert_contains "$OUT" "Unknown option for ${cmd}: ${flag}" "($cmd $flag)"
  assert_contains "$OUT" "Usage: benchbar ${cmd}" "($cmd $flag)"
done
# a typo of --dry-run next to --yes changes nothing
reset_calls
run_fm repair --dry-rn --yes --bench-dir "$BENCH"
assert_eq "64" "$CODE" "$OUT"
assert_calls_not_contain '^(launchctl|brew|sudo)' "(nothing ran)"
assert_no_file "$BENCH/Procfile.lean"
# the same, with --json, --jsonl and --for-agent: the text is on stderr, stdout holds the JSON refusal
# (one document for a command that reads, a done line for one that changes things)
json_field() { python3 -I -c 'import json,sys; d=json.loads(sys.stdin.read()); v=d
for k in sys.argv[1].split("."): v=v[k]
print(v)' "$1"; }
check_refusal() { # LABEL EXPECTED_ID EXPECTED_EVENT(- for a document) ARGS...
  local label="$1" id="$2" ev="$3" so se
  shift 3
  so="$("$FM" "$@" 2>"$TMP_DIR/err")" && code=0 || code=$?
  assert_eq "64" "$code" "$label"
  assert_eq "1" "$(printf '%s\n' "$so" | wc -l | tr -d ' ')" "$label: stdout is one JSON line: $so"
  assert_eq "64" "$(json_field exit <<<"$so")" "$label"
  assert_eq "$id" "$(json_field error_id <<<"$so")" "$label"
  assert_contains "$(json_field error <<<"$so")" "$([[ "$id" == unknown_flag ]] && echo "Unknown option" || echo "needs a value")" "$label"
  assert_contains "$(json_field fix <<<"$so")" "benchbar" "$label"
  assert_contains "$so" '"schema_version":' "$label"
  if [[ "$ev" == "-" ]]; then
    case "$so" in *'"event"'*) fail "$label: a read command answers with one document, not a done line: $so" ;; esac
  else
    assert_eq "$ev" "$(json_field event <<<"$so")" "$label"
  fi
  assert_contains "$(cat "$TMP_DIR/err")" "[FAIL]" "$label: the text is on stderr"
}
check_refusal "status --json (document)" unknown_flag - status --bogus --json --bench-dir "$BENCH"
check_refusal "status --for-agent (read: document)" unknown_flag - status --bogus --for-agent --bench-dir "$BENCH"
check_refusal "repair --json (stream)" unknown_flag "done" repair --dry-rn --yes --json --bench-dir "$BENCH"
check_refusal "repair --for-agent (stream)" unknown_flag "done" repair --dry-rn --for-agent --bench-dir "$BENCH"
check_refusal "up --jsonl (stream)" unknown_flag "done" up --bogus --jsonl --bench-dir "$BENCH"
check_refusal "status --jsonl (document asked as a stream)" unknown_flag "done" status --bogus --jsonl --bench-dir "$BENCH"
check_refusal "where --bench-dir --json (missing value)" missing_value - where --bench-dir --json
check_refusal "up --site --for-agent (missing value, stream)" missing_value "done" up --for-agent --site
# a subcommand names its own key
run_fm site list --bogus --bench-dir "$BENCH"
assert_eq "64" "$CODE" "$OUT"; assert_contains "$OUT" "Unknown option for site list: --bogus"
# after -- everything is a path
run_fm ports plan --json --bench-dir "$BENCH" -- --not-a-flag
assert_not_contains "$OUT" "Unknown option"
# no command at all
run_fm --nope; assert_eq "64" "$CODE"; assert_contains "$OUT" "Unknown option: --nope"
# a value flag spelled with = and a glued short flag are known
run_fm logs -n5 --no-follow --bench-dir "$BENCH"; assert_not_contains "$OUT" "Unknown option"
run_fm logs --process=web --since=09:00 --no-follow --bench-dir "$BENCH"; assert_not_contains "$OUT" "Unknown option"

# ---- a value flag without its value
run_fm where --bench-dir; assert_eq "64" "$CODE" "$OUT"; assert_contains "$OUT" "--bench-dir needs a value"
run_fm where --bench-dir --json; assert_eq "64" "$CODE" "$OUT"; assert_contains "$OUT" "--bench-dir needs a value"
run_fm status --site; assert_eq "64" "$CODE" "$OUT"; assert_contains "$OUT" "--site needs a value"
run_fm status --ack; assert_eq "64" "$CODE" "$OUT"; assert_contains "$OUT" "--ack needs a value"
run_fm where --bench-dir="$BENCH" --json; assert_eq "0" "$CODE" "$OUT"

# the switch covers an unknown option, not a missing value
BENCHBAR_LENIENT_FLAGS=1 run_fm where --bench-dir; assert_eq "64" "$CODE" "$OUT"; assert_contains "$OUT" "--bench-dir needs a value"
# exit 2 stays "the MariaDB root password is unknown": a usage error is never 2 or 1
run_fm status --bogus --bench-dir "$BENCH"; assert_eq "64" "$CODE" "(not 2, not 1)"

# ---- the switch back: a warning on stderr, the command runs as before
out="$(BENCHBAR_LENIENT_FLAGS=1 "$FM" status --bogus --json --bench-dir "$BENCH" 2>"$TMP_DIR/err")" && code=0 || code=$?
assert_eq "0" "$code" "$out"
assert_contains "$(cat "$TMP_DIR/err")" "Ignoring unknown option for status: --bogus"
assert_contains "$(cat "$TMP_DIR/err")" "BENCHBAR_LENIENT_FLAGS"
case "$out" in '{'*) ;; *) fail "status --json must still print its document: $out" ;; esac
BENCHBAR_LENIENT_FLAGS=0 run_fm status --bogus --bench-dir "$BENCH"; assert_eq "64" "$CODE" "(only 1 turns it on)"

# ---- every flag of the table is accepted, every command refuses an unknown one
# (one shell walks the table: fl_cmd_flag_check is the function the entrypoint calls)
WALK="$(bash -c '
  . "$0/lib/frappe-local/ui.sh"; . "$0/lib/frappe-local/commands.sh"
  fails=""; walked=0; keys=0
  check() { # WANT KEY ARG...
    local want="$1" key="$2" got
    shift 2
    if fl_cmd_flag_check "$key" "$@"; then got="ok"; else got="bad:${FL_BAD_FLAGS}"; fi
    [[ "$got" == "$want" ]] || fails="${fails}benchbar ${key} $*: want ${want}, got ${got}"$'"'"'\n'"'"'
  }
  while IFS= read -r key; do
    keys=$((keys + 1))
    while IFS="~" read -r kind k name value _; do
      [[ "$kind" == flag && "$k" == "$key" ]] || continue
      if [[ -n "$value" ]]; then check ok "$key" "$name" x; else check ok "$key" "$name"; fi
      case "$name" in --*) check ok "$key" "${name}=x" ;; esac
      walked=$((walked + 1))
    done <<<"$FL_CMD_TABLE"
    check "bad:--no-such-flag" "$key" --no-such-flag
    check "bad:--no-such-flag --also-bad" "$key" --no-such-flag --also-bad
    check "bad:-zz" "$key" -zz
    # help and a lone dash are never errors; everything after -- is data
    check ok "$key" -h; check ok "$key" -; check ok "$key" -- --anything
  done < <(awk -F"~" "\$1 == \"cmd\" { print \$2 }" <<<"$FL_CMD_TABLE")
  printf "%s %s\n%s" "$keys" "$walked" "$fails"
' "$ROOT")"
read -r KEYS_N WALKED <<<"$(head -1 <<<"$WALK")"
[[ "$KEYS_N" -gt 60 ]] || fail "the table lists fewer than 60 commands (${KEYS_N})"
[[ "$WALKED" -gt 150 ]] || fail "walked only ${WALKED} flags"
[[ -z "$(tail -n +2 <<<"$WALK")" ]] || fail "the flag table and the check disagree:"$'\n'"$(tail -n +2 <<<"$WALK")"

# ---- a flag a command's usage line shows has a record of its own (aliases like share revoke
# share a parser with another entry: the check is per entry)
MAINLOOP="$(sed -n '/^while \[\[ "\$#" -gt 0 \]\]; do/,/^done/p' "$FM" | grep -oE '^\s+-[-a-z|=*]+\)' | tr -d ' )*=' | tr '|' ' ')"
UNDOC="$(bash -c '. "$0/lib/frappe-local/ui.sh"; . "$0/lib/frappe-local/commands.sh"; fl_cmd_table' "$ROOT" | python3 -I -c '
import re, sys
main = set(sys.argv[1].split())
recs = {}
usage = {}
for line in sys.stdin:
    f = line.rstrip("\n").split("~")
    if f[0] == "cmd": usage[f[1]] = f[2]
    elif f[0] == "flag": recs.setdefault(f[1], set()).add(f[2])
for key, u in usage.items():
    for flag in re.findall(r"--[a-z][a-z-]*", u):
        if flag not in main and flag not in recs.get(key, set()):
            print("%s %s" % (key, flag))
' "$MAINLOOP")"
[[ -z "$UNDOC" ]] || fail "a flag in a usage line has no flag record of its own:"$'\n'"$UNDOC"

# ---- a flag the code reads is in the table: every long option named in a case pattern of the
# entrypoint or a library (the parsers) is a flag of some command, or one of the global flags
KNOWN="$TMP_DIR/known"
bash -c '. "$0/lib/frappe-local/ui.sh"; . "$0/lib/frappe-local/commands.sh"; fl_cmd_table; fl_cmd_global_flags' "$ROOT" \
  | awk -F'~' '$1 == "flag" { print $3 } $1 != "flag" && $1 != "cmd" && $1 != "env" { print $1 }' | sed 's/, /\n/g' | sort -u >"$KNOWN"
# the flags the main loop of the entrypoint takes for every command
sed -n '/^while \[\[ "\$#" -gt 0 \]\]; do/,/^done/p' "$FM" | grep -oE '^\s+-[-a-z|=*]+\)' | tr -d ' )*=' | tr '|' '\n' | sort -u >>"$KNOWN"
sort -u -o "$KNOWN" "$KNOWN"
missing=""
while IFS= read -r flag; do
  [[ -n "$flag" ]] || continue
  grep -qxF -- "$flag" "$KNOWN" || missing="${missing} ${flag}"
done < <(cat "$ROOT"/lib/frappe-local/*.sh | grep -E '^\s+(-[a-zA-Z0-9-]+(=\*)?\|?)+\)' | grep -v '^\s*-[kKVhn]|' \
  | grep -oE -- '--[a-z][a-z0-9-]+' | sort -u)
# flags of other tools that a case pattern lists (sudo, git, curl) are not the CLI's
for ignore in --version --help --check --stdin --short --porcelain --quiet-fail; do missing="${missing// ${ignore}/}"; done
[[ -z "$missing" ]] || fail "flags read by the code but missing from lib/frappe-local/commands.sh:${missing}"

# ---- MCP-16: per command, not only in the union: every long option pull.sh parses has a record of
# pull itself (the five that were missing: --no-migrate --before-migrate --skip-app --confirm-site --no-files)
PULL_RECORDS="$(bash -c '. "$0/lib/frappe-local/ui.sh"; . "$0/lib/frappe-local/commands.sh"; fl_cmd_table' "$ROOT" | awk -F'~' '$1 == "flag" && $2 == "pull" { print $3 }')"
PULL_PARSED="$(grep -oE -- '--[a-z][a-z0-9-]+' < <(grep -E '^\s+(--[a-z][a-z0-9-]*(=\*)?\|?)+\)' "$ROOT/lib/frappe-local/pull.sh") | sort -u)"
PULL_MISSING=""
for flag in $PULL_PARSED; do
  case "
${PULL_RECORDS}
" in *"
${flag}
"*) ;; *) PULL_MISSING="${PULL_MISSING} ${flag}" ;; esac
done
[[ -n "$PULL_PARSED" ]] || fail "test setup: no option found in pull.sh"
[[ -z "$PULL_MISSING" ]] || fail "pull parses options its records do not list:${PULL_MISSING}"

echo "ok"
