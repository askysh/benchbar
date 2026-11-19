#!/usr/bin/env bash
# CORE-3: an unknown flag is an error (exit 2, the flag and the command's usage line named), a flag
# with no value is an error, BENCHBAR_LENIENT_FLAGS=1 turns the error into a warning, and every
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
  assert_eq "2" "$CODE" "benchbar $cmd $flag: $OUT"
  assert_contains "$OUT" "Unknown option for ${cmd}: ${flag}" "($cmd $flag)"
  assert_contains "$OUT" "Usage: benchbar ${cmd}" "($cmd $flag)"
done
# a typo of --dry-run next to --yes changes nothing
reset_calls
run_fm repair --dry-rn --yes --bench-dir "$BENCH"
assert_eq "2" "$CODE" "$OUT"
assert_calls_not_contain '^(launchctl|brew|sudo)' "(nothing ran)"
assert_no_file "$BENCH/Procfile.lean"
# the same, with --json and --for-agent: the refusal is on stderr, stdout stays empty
out="$("$FM" repair --dry-rn --yes --json --bench-dir "$BENCH" 2>/dev/null)" && code=0 || code=$?
assert_eq "2" "$code"; assert_eq "" "$out"
out="$("$FM" status --bogus --for-agent --bench-dir "$BENCH" 2>/dev/null)" && code=0 || code=$?
assert_eq "2" "$code"; assert_eq "" "$out"
# a subcommand names its own key
run_fm site list --bogus --bench-dir "$BENCH"
assert_eq "2" "$CODE" "$OUT"; assert_contains "$OUT" "Unknown option for site list: --bogus"
# after -- everything is a path
run_fm ports plan --json --bench-dir "$BENCH" -- --not-a-flag
assert_not_contains "$OUT" "Unknown option"
# no command at all
run_fm --nope; assert_eq "2" "$CODE"; assert_contains "$OUT" "Unknown option: --nope"
# a value flag spelled with = and a glued short flag are known
run_fm logs -n5 --no-follow --bench-dir "$BENCH"; assert_not_contains "$OUT" "Unknown option"
run_fm logs --process=web --since=09:00 --no-follow --bench-dir "$BENCH"; assert_not_contains "$OUT" "Unknown option"

# ---- a value flag without its value
run_fm where --bench-dir; assert_eq "2" "$CODE" "$OUT"; assert_contains "$OUT" "--bench-dir needs a value"
run_fm where --bench-dir --json; assert_eq "2" "$CODE" "$OUT"; assert_contains "$OUT" "--bench-dir needs a value"
run_fm status --site; assert_eq "2" "$CODE" "$OUT"; assert_contains "$OUT" "--site needs a value"
run_fm status --ack; assert_eq "2" "$CODE" "$OUT"; assert_contains "$OUT" "--ack needs a value"
run_fm where --bench-dir="$BENCH" --json; assert_eq "0" "$CODE" "$OUT"

# ---- the switch back: a warning on stderr, the command runs as before
out="$(BENCHBAR_LENIENT_FLAGS=1 "$FM" status --bogus --json --bench-dir "$BENCH" 2>"$TMP_DIR/err")" && code=0 || code=$?
assert_eq "0" "$code" "$out"
assert_contains "$(cat "$TMP_DIR/err")" "Ignoring unknown option for status: --bogus"
assert_contains "$(cat "$TMP_DIR/err")" "BENCHBAR_LENIENT_FLAGS"
case "$out" in '{'*) ;; *) fail "status --json must still print its document: $out" ;; esac
BENCHBAR_LENIENT_FLAGS=0 run_fm status --bogus --bench-dir "$BENCH"; assert_eq "2" "$CODE" "(only 1 turns it on)"

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

echo "ok"
