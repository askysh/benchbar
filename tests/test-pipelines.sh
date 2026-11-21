#!/usr/bin/env bash
# Pipelines under pipefail: "producer | grep -q" fails when grep quits on the
# first match and the producer then dies of SIGPIPE (141). The code captures
# the output and tests it without a pipe (fl_has_line, case). This pins the
# helper's matching and keeps the pattern from coming back.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
. "$ROOT/lib/frappe-local/ui.sh"
. "$ROOT/lib/frappe-local/profiles.sh"
. "$ROOT/lib/frappe-local/wkhtmltopdf.sh"

# ---- fl_has_line: a whole line, fixed string, first/middle/last/only line
fl_has_line $'a\nb\nc' a || fail "first line"
fl_has_line $'a\nb\nc' b || fail "middle line"
fl_has_line $'a\nb\nc' c || fail "last line"
fl_has_line "only" only || fail "only line"
! fl_has_line $'ab\nc' a || fail "a prefix is not a line"
! fl_has_line $'ab\nc' b || fail "a suffix is not a line"
! fl_has_line "" a || fail "empty text"
fl_has_line $'x\na.c\ny' 'a.c' || fail "fixed string"
! fl_has_line $'x\nabc\ny' 'a.c' || fail "the dot is not a wildcard"
fl_has_line $'x\na*\ny' 'a*' || fail "a star is literal"
# a long list whose match is on the first line: no pipe, nothing to SIGPIPE
big="first"; i=0; while [[ $i -lt 20000 ]]; do big="${big}"$'\n'"line-$i"; i=$((i + 1)); done
fl_has_line "$big" first || fail "first line of a long list"
fl_has_line "$big" line-19999 || fail "last line of a long list"
( set -o pipefail; for _ in 1 2 3 4 5 6 7 8 9 10; do fl_has_line "$big" first || exit 1; done ) || fail "stable under pipefail"

# ---- case insensitive matches that used grep -qi
fl_profile_offline_msg "fatal: Could Not Resolve host: github.com" || fail "offline message, mixed case"
fl_profile_offline_msg "Connection TIMED OUT" || fail "offline message, upper case"
! fl_profile_offline_msg "permission denied" || fail "not an offline message"
fl__wk_text_patched "wkhtmltopdf 0.12.6 (With Patched Qt)" || fail "patched, mixed case"
! fl__wk_text_patched "wkhtmltopdf 0.12.6" || fail "unpatched"

# ---- first line of a long producer: awk reads it all, head would SIGPIPE it
( set -o pipefail; v="$(seq 1 300000 | awk 'NR==1')" && [[ "$v" == 1 ]] ) || fail "awk NR==1 under pipefail"
( set -o pipefail; v="$(seq 1 300000 | awk 'NR<=20' | tail -n1)" && [[ "$v" == 20 ]] ) || fail "awk NR<=20 under pipefail"

# ---- no "| grep -q" left in the shell sources (comments and "||" aside)
left="$(grep -nE '(^|[^|])\| *grep -[a-zA-Z]*q' "$ROOT/benchbar" "$ROOT"/lib/frappe-local/*.sh "$ROOT"/0*.sh | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true)"
[[ -z "$left" ]] || fail "producer | grep -q under pipefail; capture the output and test it with fl_has_line or case:"$'\n'"$left"

# ---- no "| head -n" after a producer that can write more (pull.sh reads a
# dump through "head -n 40" on purpose, its status is ignored)
heads="$(grep -nE '\| *head -n' "$ROOT/benchbar" "$ROOT"/lib/frappe-local/*.sh "$ROOT"/0*.sh | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' | grep -v 'head -n 40' || true)"
[[ -z "$heads" ]] || fail "producer | head under pipefail gets SIGPIPE (141); use awk 'NR==1' or take the first line of a captured variable:"$'\n'"$heads"

# ---- no "| awk '... exit'" left in the shell sources: an awk that quits at its match closes the
# pipe on a writer that still has lines to print (bash writes a line at a time). The writer then
# dies of SIGPIPE (141 under pipefail) or, in a shell whose parent ignores SIGPIPE (GitHub Actions,
# an app), fails with "printf: write error: Broken pipe": install with a team profile ended that
# way in CI (profiles.sh, fl_profile_check_loaded). Keep a flag instead ("&& !f { print; f = 1 }"),
# so awk reads to the end. "END { exit ... }" is fine: the input is read by then.
awks="$(grep -nE "\\| *awk [^|]*exit" "$ROOT/benchbar" "$ROOT"/lib/frappe-local/*.sh "$ROOT"/0*.sh | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' | grep -vE 'END *\{[^}]*exit' || true)"
[[ -z "$awks" ]] || fail "producer | awk '... exit' closes the pipe on its writer; use a flag so awk reads it all:"$'\n'"$awks"

# ---- the command table is read from the variable, never through a pipe: a reader that returns at
# its match left "printf: write error: Broken pipe" in the output of every command with --json
# when SIGPIPE was ignored (test-homebrew and test-state-migrate in CI). With SIGPIPE ignored and
# stderr in the output, as CI has it, nothing but the document may come out.
left="$(grep -n '<(fl_cmd_table)' "$ROOT/benchbar" "$ROOT"/lib/frappe-local/*.sh || true)"
[[ -z "$left" ]] || fail "a loop over <(fl_cmd_table): read <<<\"\$FL_CMD_TABLE\" instead:"$'\n'"$left"
i=0
while [[ "$i" -lt 15 ]]; do
  out="$(trap '' PIPE; "$FM" commands --json 2>&1 >/dev/null; "$FM" list --json 2>&1 >/dev/null; "$FM" help list 2>&1 >/dev/null)" || true
  assert_not_contains "$out" "Broken pipe" "(round $i)"
  i=$((i + 1))
done

# ---- the tests themselves: the same rule, the same reason. Under
# "set -o pipefail" (tests/lib/harness.sh) a writer that is cut off by "| head"
# or by "| grep -q" / "| grep -m1" dies of SIGPIPE, and on the bash 3.2
# container leg the test then ends with exit 141 and no message (test-apps,
# test-release-workflows). Use "grep -q PAT <<<"$VAR"", "grep -m1 ... FILE",
# "${VAR%%$'\n'*}" for the first line of a variable, or awk 'NR==1' (reads it
# all). A line that has to keep a pipe goes in the list below, with the reason.
#   test-systemd.sh: the text of bench-run.sh.tmpl's CWD_OF, asserted as is
#   (a change to the template moves its pinned hash; not a pipe of this test)
TEST_PIPE_EXCEPTIONS=(
  "test-systemd.sh:*sed -n 's/^n//p' | head -n1)*in*"
)
# a pipe (not ||, with or without spaces, also |&) into head, or into grep, egrep or fgrep with -q, -m,
# --quiet or --max-count anywhere in its arguments; `command` and a path in front count too
PIPE_RE='(^|[^|])\|&? *(command +)?([^[:space:]|]*/)?(head($|[[:space:];)&])|[ef]?grep([[:space:]][^|]*)?[[:space:]](-[a-zA-Z]*[qm][a-zA-Z0-9]*|--quiet|--max-count)([[:space:]]|$|=))'
test_files=()
for f in "$ROOT"/tests/*.sh "$ROOT"/tests/lib/*.sh "$ROOT"/tests/mocks/* "$ROOT"/tests/mocks/bin/*; do
  [[ -f "$f" && "$f" != "$ROOT/tests/test-pipelines.sh" ]] && test_files[${#test_files[@]}]="$f"
done
test_pipes="$(cd "$ROOT/tests" && grep -nE "$PIPE_RE" "${test_files[@]#"$ROOT/tests/"}" /dev/null | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true)"
test_hits=""
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  skip=0
  for pat in "${TEST_PIPE_EXCEPTIONS[@]}"; do
    # shellcheck disable=SC2053
    [[ "$line" == $pat ]] && skip=1
  done
  [[ "$skip" == 1 ]] || test_hits="${test_hits}${line}"$'\n'
done <<<"$test_pipes"
[[ -z "$test_hits" ]] || fail "a test pipes into head or grep -q/-m under pipefail (SIGPIPE, exit 141 on bash 3.2); see the note above this check:"$'\n'"$test_hits"

# the check sees what it should: a pipe into head or grep -q is a hit, a
# here string or grep -m1 on a file is not
line_hits() { grep -cE "$PIPE_RE" <<<"$1" || true; }
# shellcheck disable=SC2016  # the samples are text, not code to expand
assert_eq "1" "$(line_hits 'x="$(seq 5 | head -n1)"')" "(head)"
assert_eq "1" "$(line_hits 'seq 5 | grep -q 3')" "(grep -q)"
assert_eq "1" "$(line_hits 'seq 5 | grep -F -q -- 3')" "(grep -F -q)"
assert_eq "1" "$(line_hits 'seq 5 | grep -m1 3')" "(grep -m1)"
assert_eq "1" "$(line_hits 'seq 5 | grep -qE 3')" "(grep -qE)"
# shellcheck disable=SC2016  # the samples are text, not code to expand
assert_eq "0" "$(line_hits 'grep -q 3 <<<"$v"')" "(here string)"
# shellcheck disable=SC2016  # the samples are text, not code to expand
assert_eq "0" "$(line_hits 'grep -m1 -n 3 "$FILE" | cut -d: -f1')" "(grep on a file)"
assert_eq "0" "$(line_hits "seq 5 | awk 'NR==1'")" "(awk)"
assert_eq "0" "$(line_hits 'seq 5 | grep -v 3 | tr a b')" "(grep -v)"

printf 'test-pipelines: ok\n'
