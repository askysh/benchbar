#!/usr/bin/env bash
# The neutralisation routine (lib/frappe-local/neutralise.sh) that benchbar
# pull and the rooms copy (share setup) both run: its list is declarative with
# a comment per entry, its Python runs under a stand-in frappe on sqlite, and
# both callers use the one routine.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/frappe-local-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected [$1], got [$2] ${3:-}"; }

FILE="$ROOT/lib/frappe-local/neutralise.sh"
[[ -f "$FILE" ]] || fail "lib/frappe-local/neutralise.sh is missing"

# the list: every entry line has the comment line of its own right above it
entries="$(grep -c '^    ("[a-z_]*", ' "$FILE" || true)"
[[ "$entries" -ge 30 ]] || fail "the list has only ${entries} entries"
bad="$(awk '/^    \("[a-z_]*", / { if (prev !~ /^    # /) print NR ": " $0 } { prev = $0 }' "$FILE")"
[[ -z "$bad" ]] || fail "entries without a comment line above them:"$'\n'"$bad"
# no dash in the file (the project writes none)
! grep -q -e $'\xe2\x80\x94' -e $'\xe2\x80\x93' "$FILE" || fail "an em or en dash in neutralise.sh"

# the Python, under a stand-in frappe
# shellcheck source=lib/frappe-local/neutralise.sh
. "$FILE"
printf '%s' "$FL_PY_NEUTRALISE_RUN" >"$TMP_DIR/snippet.py"
assert_eq "neutralise_stub: ok" "$(python3 "$ROOT/tests/share/neutralise_stub.py" "$TMP_DIR/snippet.py" 2>&1 | tail -n1)"

# one routine: the rooms copy and pull run the same Python, neither has a list of its own
. "$ROOT/lib/frappe-local/share-site.sh"
case "$FL_PY_SHARE_HARDEN" in *"$FL_PY_NEUTRALISE"*) ;; *) fail "the share hardening does not carry the neutralisation routine" ;; esac
case "$FL_PY_SHARE_HARDEN" in *"neutralise(frappe"*) ;; *) fail "the share hardening does not call neutralise()" ;; esac
case "$FL_PY_SHARE_HARDEN_BODY" in *"switch_off"*|*"Social Login Key"*|*"Webhook"*|*"Email Account"*) fail "the share hardening still keeps its own list" ;; esac
grep -q 'fl_neutralise_run_v' "$ROOT/lib/frappe-local/pull.sh" || fail "pull does not run the shared routine"
! grep -q 'Social Login Key\|"Webhook"' "$ROOT/lib/frappe-local/pull.sh" || fail "pull keeps a list of its own"

printf 'ok: test-neutralise\n'
