#!/usr/bin/env bash
# JSON strings and numbers (docs/json-schema.md, "Rules for readers"): what the
# shell helpers in ui.sh write is valid JSON whatever the input holds, in
# every locale, under the macOS and the Linux mocks. Each document is parsed
# by a strict reader (python3 -I json.load), the way Swift's JSONDecoder and
# the tray's System.Text.Json parse it.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# parse TEXT: the strict parse of one JSON text, printing the Python repr of the value
parse() { printf '%s' "$1" | python3 -I -c 'import json,sys; print(ascii(json.load(sys.stdin)))'; }
# value TEXT EXPECTED: fl_json_str of TEXT parses to the string whose ascii() is EXPECTED
want() {
  local got
  got="$(parse "$(fl_json_str "$1")")" || fail "fl_json_str of [$(printf '%q' "$1")] is not valid JSON: $(fl_json_str "$1")"
  assert_eq "$2" "$got" "(fl_json_str of $(printf '%q' "$1"))"
}

# the same checks under each locale a run can have: launchd and the app give C (no LANG),
# a Terminal gives UTF-8
run_unit() {
  . "$ROOT/lib/frappe-local/ui.sh"
  # ---- CORE-10: invalid UTF-8
  want $'bad\xffbyte' "'bad\\ufffdbyte'"
  want $'\xe6\x97' "'\\ufffd\\ufffd'"                      # a cut character: lead and one continuation
  want $'ok \xc3\xa9 \xe6\x97\xa5\xe6\x9c\xac \xf0\x9f\x98\x80' "'ok \\xe9 \\u65e5\\u672c \\U0001f600'"
  want $'\xc0\x80' "'\\ufffd\\ufffd'"                      # an overlong NUL
  want $'\xed\xa0\x80' "'\\ufffd\\ufffd\\ufffd'"           # a surrogate
  want $'\xf4\x90\x80\x80' "'\\ufffd\\ufffd\\ufffd\\ufffd'" # above U+10FFFF
  want $'\x80\xbfx' "'\\ufffd\\ufffdx'"                    # lone continuation bytes
  # a valid string is left alone, byte for byte
  assert_eq $'caf\xc3\xa9' "$(fl_json_escape $'caf\xc3\xa9')"
  # the cut: at most MAX bytes, never inside a character
  local c
  fl_json_cut_v c $'ab\xc3\xa9cd' 3; assert_eq "ab" "$c"
  fl_json_cut_v c $'ab\xc3\xa9cd' 4; assert_eq $'ab\xc3\xa9' "$c"
  fl_json_cut_v c $'a\xe6\x97\xa5' 3; assert_eq "a" "$c"
  fl_json_cut_v c $'a\xf0\x9f\x98\x80' 4; assert_eq "a" "$c"
  fl_json_cut_v c "short" 500; assert_eq "short" "$c"
  fl_json_cut_v c "abcdef" 3; assert_eq "abc" "$c"
  local long i
  long=""; for i in $(seq 1 300); do long="${long}"$'\xe6\x97\xa5'; done   # 900 bytes of one character
  for i in 499 500 501; do
    fl_json_cut_v c "$long" "$i"
    [[ "${#c}" -le "$i" ]] || fail "cut to $i bytes left more than $i bytes"
    parse "$(fl_json_str "$c")" >/dev/null || fail "a cut at $i bytes is not valid JSON"
    assert_eq "" "$(printf '%s' "$c" | LC_ALL=C tr -d '\346\227\245')" "(a cut at $i bytes holds whole characters only)"
  done
  # a done line with a long warning that ends in multibyte characters
  FL_DONE_WARNINGS="" FL_DONE_WARNINGS_N=0
  fl_done_warning_add "$(printf 'w%.0s' $(seq 1 499))"$'\xc3\xa9\xe6\x97\xa5'
  parse "[${FL_DONE_WARNINGS}]" >/dev/null || fail "a warning cut inside a character is not valid JSON: ${FL_DONE_WARNINGS}"

  # ---- CORE-11: newline, tab, control characters
  want $'git: fatal: not a repo\nhint: use x' "'git: fatal: not a repo\\nhint: use x'"
  want $'a\tb\rc' "'a\\tb\\rc'"
  want $'bell\x07 nul-ish\x01 us\x02' "'bell\\x07 nul-ish\\x01 us\\x02'"
  # the marks the CLI puts in its own strings (the fix mark, the row separators) never reach a document
  want $'\034benchbar up\036a\037b' "'benchbar upab'"
  want $'q"uo\\te' "'q\"uo\\\\te'"
  want $'\x1b[31mred\x1b[0m plain' "'red plain'"            # a color code goes whole, as before
  want $'lone\x1bESC' "'lone\\x1bESC'"
  want $'del\x7fx' "'del\\x7fx'"
  # 5000 control characters: linear, not quadratic
  long="$(printf 'a\tb\n%.0s' $(seq 1 1500))"
  SECONDS=0; parse "$(fl_json_str "$long")" >/dev/null || fail "a long string with tabs and newlines is not valid JSON"
  [[ "$SECONDS" -le 5 ]] || fail "escaping 6 KB of tabs and newlines took ${SECONDS}s"
  # ---- the empty string rule: null for "no value", "" only from fl_json_text
  assert_eq "null" "$(fl_json_str '')"
  assert_eq '""' "$(fl_json_text '')"
  assert_eq '"x"' "$(fl_json_text x)"
  assert_eq 'null' "$(fl_json_str "")"
  # ---- numbers
  local v
  for v in 0 5 -5 -0 123456; do assert_eq "$v" "$(fl_json_num "$v")" "(a number)"; done
  for v in '' - -- 1-2 007 00 -01 1.5 1e3 +1 ' 1' 1x abc; do assert_eq "null" "$(fl_json_num "$v")" "(not a number: [$v])"; done
  # ---- table cells: a "|" in a path is text
  fl_cell_v c '/a|b/c'
  assert_eq '/a\|b/c' "$c"
  assert_contains "$(fl_table 'Bench|Path' "x|${c}")" "/a|b/c"
  assert_eq "2" "$(fl_table 'A|B' "1|${c}" | wc -l | tr -d ' ')"
}

for loc in C en_US.UTF-8 C.UTF-8; do
  # a UTF-8 locale this host lacks falls back to C: the C pass is the one that matters
  if [[ "$loc" != C ]] && ! locale -a 2>/dev/null | tr 'A-Z' 'a-z' | sed 's/utf8/utf-8/' | grep -qx "$(printf '%s' "$loc" | tr 'A-Z' 'a-z')"; then continue; fi
  ( export LC_ALL="$loc" LANG="$loc"; run_unit ) || fail "unit checks under $loc"
done

# ---- the documents: logs --json with a stray byte, a tab, a cut character; both platforms
run_documents() {
  local platform="$1" BENCH="$2"
  [[ "$platform" != linux ]] || use_linux
  make_fake_bench "$BENCH"
  run_fm service --yes --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
  {
    printf '10:00:01 web.1         | bad byte \xff here\n'
    printf '10:00:02 web.1         | tab\there\n'
    printf '10:00:03 web.1         | colored \033[31mred\033[0m and bell \007 end\n'
    printf '10:00:04 web.1         | caf\xc3\xa9 \xe6\x97\xa5\xe6\x9c\xac\n'
    printf '10:00:05 web.1         | cr only\r\n'
  } >"$BENCH/logs/bench.log"
  run_fm logs --json --no-follow -n10 --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
  printf '%s' "$OUT" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
l = d["lines"]
assert "bad byte � here" in l[0], l
assert "tab\there" in l[1], l
assert "colored red and bell \x07 end" in l[2], l
assert "café 日本" in l[3], l
assert l[4].endswith("cr only\r"), l
' || fail "logs --json lines ($platform)"
  # status --json under the same bench still parses (the polled document)
  run_fm status --json --bench-dir "$BENCH"; assert_eq "0" "$CODE" "$OUT"
  printf '%s' "$OUT" | python3 -I -c 'import json,sys; json.load(sys.stdin)' || fail "status --json ($platform)"
}
( export LC_ALL=C LANG=C; run_documents mac "$HOME/frappe-bench" ) || fail "documents, macOS mocks, C locale"
( export LC_ALL=C LANG=C; run_documents linux "$HOME/dev/linux-bench" ) || fail "documents, Linux mocks, C locale"

# ---- CORE-23: a path directly under / has one slash; doctor's site follows status
. "$ROOT/lib/frappe-local/ui.sh"; . "$ROOT/lib/frappe-local/state.sh"
assert_eq "/nonexistent-benchbar-test" "$(fl_bench_canonical /nonexistent-benchbar-test)"
assert_eq "/nonexistent-benchbar-test" "$(fl_bench_canonical /nonexistent-benchbar-test/)"

NA="$HOME/dev/notadopted"
make_fake_bench "$NA" naSite
run_fm status --json --bench-dir "$NA"; assert_eq "None" "$(printf '%s' "$OUT" | jget - 'd["site"]')" "(status: a folder benchbar does not know has no site)"
run_fm doctor --json --bench-dir "$NA"
assert_eq "None" "$(printf '%s' "$OUT" | jget - 'd["site"]')" "(doctor follows status)"
run_fm doctor --json --bench-dir "$HOME/frappe-bench"
assert_eq "macdev" "$(printf '%s' "$OUT" | jget - 'd["site"]')" "(an adopted bench names its site)"

printf 'test-json-strings: ok\n'
