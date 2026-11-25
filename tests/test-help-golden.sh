#!/usr/bin/env bash
# The help text is held byte for byte: benchbar --help (also with no command, and as `help`) and
# benchbar COMMAND --help for every command and subcommand of the table, with the experiments off
# and on (a command of a lab that is off prints its refusal, not its help). The expected text is in
# tests/golden/help.txt, written from the hand written help of 0.8.3 (CORE-18): generating the
# global help from the table must not change one character of it.
#
# After an intended change of a help text: HELP_GOLDEN_WRITE=tests/golden/help.txt bash tests/test-help-golden.sh
# writes the new file; read its diff before committing it.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

DOCS="https://benchbar.akashmishra.com"
GOLDEN="$ROOT/tests/golden/help.txt"
ACTUAL="$TMP_DIR/help-actual.txt"
: >"$ACTUAL"

# note FORM: the output of the last run_fm under a heading, the version and the docs URL as words
note() {
  local text="$OUT"
  text="${text//"$VER"/@VERSION@}"
  text="${text//"$DOCS"/@DOCS@}"
  printf '=== %s (exit %s)\n%s\n' "$1" "$CODE" "$text" >>"$ACTUAL"
}

keys="$(bash -c '. "$0/lib/frappe-local/ui.sh"; . "$0/lib/frappe-local/commands.sh"; fl_cmd_table' "$ROOT" | awk -F'~' '$1 == "cmd" { print $2 }')"
[[ -n "$keys" ]] || fail "no cmd record in the table"

# every `use` record of the global help names a command of the table, or - (a heading, a blank line, an option)
ukeys="$(bash -c '. "$0/lib/frappe-local/ui.sh"; . "$0/lib/frappe-local/commands.sh"; fl_usage_table' "$ROOT" | awk -F'~' '$1 == "use" && $2 != "-" { print $2 }' | sort -u)"
while IFS= read -r k; do
  [[ -z "$k" ]] || grep -qxF -- "$k" <<<"$keys" || fail "a use record names $k, which is not a command of the table"
done <<<"$ukeys"

for labs in "" "lan-rooms,quick-switch"; do
  export BENCHBAR_LABS="$labs"
  tag="labs: ${labs:-none}"
  run_fm --help; note "benchbar --help [$tag]"
  run_fm -h; note "benchbar -h [$tag]"
  run_fm help; note "benchbar help [$tag]"
  run_fm; note "benchbar [$tag]"
  while IFS= read -r key; do
    # shellcheck disable=SC2086  # the key is one to three words
    run_fm $key --help; note "benchbar $key --help [$tag]"
  done <<<"$keys"
done
unset BENCHBAR_LABS

if [[ -n "${HELP_GOLDEN_WRITE:-}" ]]; then
  cp "$ACTUAL" "$HELP_GOLDEN_WRITE"
  printf 'wrote %s (%s lines)\n' "$HELP_GOLDEN_WRITE" "$(wc -l <"$ACTUAL" | tr -d ' ')"
  exit 0
fi

[[ -f "$GOLDEN" ]] || fail "tests/golden/help.txt is missing"
if ! cmp -s "$GOLDEN" "$ACTUAL"; then
  fail "the help text differs from tests/golden/help.txt: $(diff "$GOLDEN" "$ACTUAL" | head -20)"
fi
assert_eq "$(grep -c '^=== ' "$GOLDEN")" "$(grep -c '^=== ' "$ACTUAL")" "(one section per form)"
