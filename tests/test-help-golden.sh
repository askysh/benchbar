#!/usr/bin/env bash
# The help text is held byte for byte: benchbar --help (also with no command, and as `help`) and
# benchbar COMMAND --help for every command and subcommand of the table, with the experiments off
# and, for the commands of a lab, on (a command of a lab that is off prints its refusal, not its help). The expected text is in
# tests/golden/help.txt. The global help is printed from the commands table and the layout in
# lib/frappe-local/help-layout.txt (#371); that every help record names a command of the table is held by
# tests/test-help-source.sh.
#
# After an intended change of a help text: HELP_GOLDEN_WRITE=tests/golden/help.txt bash tests/test-help-golden.sh
# writes the new file; read its diff before committing it.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

DOCS="https://benchbar.akashmishra.com"
GOLDEN="$ROOT/tests/golden/help.txt"
ACTUAL="$TMP_DIR/help-actual.txt"
: >"$ACTUAL"

# note FORM: the output of the last run_fm under a heading, the version and the docs URL as words. The version
# is replaced in the banner line only ("benchbar X.Y.Z:"): a help text that names a version as a fact ("a line
# written by 0.8.3") stays as it is, or the golden would hold @VERSION@ there while that version is the current
# one and differ at the next bump.
note() {
  local text="$OUT"
  text="${text//"benchbar ${VER}:"/benchbar @VERSION@:}"
  text="${text//"$DOCS"/@DOCS@}"
  printf '=== %s (exit %s)\n%s\n' "$1" "$CODE" "$text" >>"$ACTUAL"
}

keys="$(bash -c '. "$0/lib/frappe-local/ui.sh"; . "$0/lib/frappe-local/commands.sh"; fl_cmd_table' "$ROOT" | awk -F'~' '$1 == "cmd" { print $2 }')"
[[ -n "$keys" ]] || fail "no cmd record in the table"

# The second pass (the experiments on) runs the global help and the commands whose help was a
# refusal (a nonzero exit) in the first one: every other command prints the same in both.
gated=""
for labs in "" "lan-rooms,quick-switch"; do
  export BENCHBAR_LABS="$labs"
  tag="labs: ${labs:-none}"
  run_fm --help; note "benchbar --help [$tag]"
  run_fm -h; note "benchbar -h [$tag]"
  run_fm help; note "benchbar help [$tag]"
  run_fm; note "benchbar [$tag]"
  while IFS= read -r key; do
    if [[ -n "$labs" ]]; then
      case "
$gated
" in *"
$key
"*) ;; *) continue ;; esac
    fi
    # shellcheck disable=SC2086  # the key is one to three words
    run_fm $key --help; note "benchbar $key --help [$tag]"
    if [[ -z "$labs" && "$CODE" != "0" ]]; then gated="${gated}${gated:+
}${key}"; fi
  done <<<"$keys"
done
unset BENCHBAR_LABS

if [[ -n "${HELP_GOLDEN_WRITE:-}" ]]; then
  cp "$ACTUAL" "$HELP_GOLDEN_WRITE"
  printf 'wrote %s (%s lines)\n' "$HELP_GOLDEN_WRITE" "$(wc -l <"$ACTUAL" | tr -d ' ')"
  exit 0
fi

# no line of the help of a command is wider than 100 columns (the global help has its own limit, when it is generated)
wide="$(awk '/^=== /{ g = ($0 ~ /^=== benchbar (--help |-h |help )?\[labs/) } !g && length($0) > 100 { printf "%d (%d): %s\n", NR, length($0), substr($0, 1, 60) }' "$ACTUAL")"
[[ -z "$wide" ]] || fail "help lines over 100 columns (line of the output, width): $wide"

[[ -f "$GOLDEN" ]] || fail "tests/golden/help.txt is missing"
if ! cmp -s "$GOLDEN" "$ACTUAL"; then
  fail "the help text differs from tests/golden/help.txt: $(diff "$GOLDEN" "$ACTUAL" | sed -n 1,20p)"
fi
assert_eq "$(grep -c '^=== ' "$GOLDEN")" "$(grep -c '^=== ' "$ACTUAL")" "(one section per form)"
