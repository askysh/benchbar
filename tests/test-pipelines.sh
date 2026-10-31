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

# ---- no "| grep -q" left in the shell sources (comments and "||" aside)
left="$(grep -nE '(^|[^|])\| *grep -[a-zA-Z]*q' "$ROOT/benchbar" "$ROOT"/lib/frappe-local/*.sh "$ROOT"/0*.sh | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true)"
[[ -z "$left" ]] || fail "producer | grep -q under pipefail; capture the output and test it with fl_has_line or case:"$'\n'"$left"

printf 'test-pipelines: ok\n'
