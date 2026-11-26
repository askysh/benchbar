#!/usr/bin/env bash
# tests/lib/pin.sh: the full and smoke modes of a pin test. A tiny pin test runs here against a golden file of its own:
# nothing set runs every scenario, PIN_SMOKE=1 (or a list with its name) only the smoke ones, PIN_UPDATE=1 writes
# every scenario whatever PIN_SMOKE says, a smoke run compares each scenario it ran with its part of the golden file,
# and a full run compares the whole file.
set -euo pipefail

ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
TMP_DIR="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/benchbar-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected [$1], got [$2] ${3:-}"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "expected [$2] in [$1] ${3:-}" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "expected no [$2] in [$1] ${3:-}" ;; esac; }

GOLD="$TMP_DIR/golden"
mkdir -p "$GOLD"
# the mini pin test: a and c are smoke scenarios, b and d are not (d is after the end of the smoke set)
cat >"$TMP_DIR/mini.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
MOCK_STATE="$TMP_DIR/state"; MOCK_LOG="$MOCK_STATE/calls"
mkdir -p "$MOCK_STATE"
reset_calls() { : >"$MOCK_LOG"; }
FM="$TMP_DIR/fm"
printf '#!/bin/sh\necho "out $*"\n' >"$FM"; chmod +x "$FM"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# shellcheck source=tests/lib/pin.sh
. "$ROOT/tests/lib/pin.sh"
pin_run "a" one
if pin_full; then
  pin_run "b" two
  [[ -z "${MINI_DUP:-}" ]] || pin_run "a" again
fi
pin_run "c" three
pin_smoke_end mini.txt
pin_run "d" four
pin_check mini.txt
echo "mini: ok"
EOF
# mini ENV...: run it with a clean environment; OUT and CODE hold the result
mini() { OUT="$(env -i PATH="$PATH" HOME="$HOME" ROOT="$ROOT" TMP_DIR="$TMP_DIR" PIN_GOLDEN_DIR="$GOLD" "$@" bash "$TMP_DIR/mini.sh" 2>&1)" && CODE=0 || CODE=$?; }
names() { sed -n 's/^=== //p' "$GOLD/mini.txt" | tr '\n' ' '; }

# PIN_UPDATE=1 alone writes the whole file, and also with PIN_SMOKE=1 and with a list that names this test
mini PIN_UPDATE=1
assert_eq "0" "$CODE" "$OUT"
assert_eq "a b c d " "$(names)" "(PIN_UPDATE=1 writes every scenario)"
mini PIN_UPDATE=1 PIN_SMOKE=1
assert_eq "a b c d " "$(names)" "(PIN_UPDATE=1 with PIN_SMOKE=1)"
mini PIN_UPDATE=1 PIN_SMOKE=mini
assert_eq "a b c d " "$(names)" "(PIN_UPDATE=1 with PIN_SMOKE naming the test)"

# nothing set (a person, a push, a release build, a job nobody told about pins) runs every scenario
mini
assert_eq "0" "$CODE" "$OUT"; assert_contains "$OUT" "mini: ok"; assert_not_contains "$OUT" "smoke"
# so do an empty PIN_SMOKE, 0, and a list that does not name this test (a name is a whole word)
for v in "" 0 test-other min minimal "test-a-pin test-b-pin"; do
  mini "PIN_SMOKE=$v"
  assert_eq "0" "$CODE" "$OUT (PIN_SMOKE=$v)"; assert_contains "$OUT" "mini: ok" "(PIN_SMOKE=$v)"; assert_not_contains "$OUT" "smoke"
done

# PIN_SMOKE=1 and a list with this test: a and c ran, b is skipped, d is never reached
for v in 1 mini "test-other mini" "mini test-other"; do
  mini "PIN_SMOKE=$v"
  assert_eq "0" "$CODE" "$OUT (PIN_SMOKE=$v)"
  assert_contains "$OUT" "pin: smoke, 2 of 4 scenarios of mini.txt"; assert_contains "$OUT" "mini.sh: ok (smoke)"
done
# a smoke run does not write the golden file, whatever it ran
assert_eq "a b c d " "$(names)" "(a smoke run leaves the file alone)"

# a scenario outside the smoke set that changed: only a full run sees it
cp "$GOLD/mini.txt" "$TMP_DIR/mini.good"
sed 's/^out two$/out TWO/' "$TMP_DIR/mini.good" >"$GOLD/mini.txt"
mini PIN_SMOKE=1
assert_eq "0" "$CODE" "$OUT (a smoke run does not look at b)"
mini
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "the output of the pinned scenarios changed: mini.txt"
# a smoke scenario that changed: both see it
sed 's/^out one$/out ONE/' "$TMP_DIR/mini.good" >"$GOLD/mini.txt"
mini PIN_SMOKE=1
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "the output of the pinned scenarios changed: mini.txt"
mini
assert_eq "1" "$CODE" "$OUT"
# a scenario the golden file lacks (a smoke one): the run fails, it does not pass on nothing
awk '/^=== c$/ { skip = 1 } /^=== d$/ { skip = 0 } !skip' "$TMP_DIR/mini.good" >"$GOLD/mini.txt"
mini PIN_SMOKE=1
assert_eq "1" "$CODE" "$OUT"
# no golden file at all
unlink "$GOLD/mini.txt"
mini PIN_SMOKE=1
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "no golden file"
# a golden file that holds a name twice (a stale file): the smoke run says which, it does not just fail the compare
{ cat "$TMP_DIR/mini.good"; awk '/^=== a$/ { on = 1 } /^=== b$/ { on = 0 } on' "$TMP_DIR/mini.good"; } >"$GOLD/mini.txt"
mini PIN_SMOKE=1
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "has two blocks called 'a'"
# two scenarios with one name in a run: the name is how a smoke run finds its part
cp "$TMP_DIR/mini.good" "$GOLD/mini.txt"
mini MINI_DUP=1
assert_eq "1" "$CODE" "$OUT"; assert_contains "$OUT" "two scenarios are called 'a'"

printf 'test-pin-lib: ok\n'
