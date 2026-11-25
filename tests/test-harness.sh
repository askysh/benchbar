#!/usr/bin/env bash
# The test harness's own behaviour (#138, CI-9 and CI-16):
#   - fail() stops the test, unless the test asked for soft assertions: then every failure
#     is listed and the test still exits 1 at its end; fail_now and soft_checkpoint stop it
#   - run_fm keeps its merged OUT; run_fm_split keeps stdout (OUT) and stderr (ERR) apart
#   - the ps mock never asks the real ps about a pid a test made up
# Each case is a small test file of its own, run with the bash that runs this test.
set -euo pipefail

ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/benchbar-test-harness.XXXXXX")" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "expected [$1], got [$2] ${3:-}"; }
has() { case "$1" in *"$2"*) ;; *) fail "expected [$2] in: $1 ${3:-}" ;; esac; }
hasnt() { case "$1" in *"$2"*) fail "did not expect [$2] in: $1 ${3:-}" ;; esac; }

# case NAME BODY: writes a test file that sources the harness, runs it; sets OUT (both streams) and CODE
run_case() {
  local f="$WORK/$1.sh"
  { printf '#!/usr/bin/env bash\n. "%s/tests/lib/harness.sh"\n' "$ROOT"; cat; } >"$f"
  set +e; OUT="$("$BASH" "$f" 2>&1)"; CODE="$?"; set -e
}

# ---- hard by default: the first failed assertion ends the file
run_case hard <<'EOF'
assert_eq a b "(first)"
printf 'reached\n'
EOF
eq 1 "$CODE"
has "$OUT" "expected [a], got [b] (first)"
hasnt "$OUT" reached

# ---- soft: every failure is listed, the code is 1 at the end, the file ran to its last line
run_case soft <<'EOF'
soft_asserts on
assert_eq a b "(first)"
assert_contains "text" "nope" "(second)"
assert_file "$TMP_DIR/none" "(third)"
assert_eq same same
printf 'reached\n'
EOF
eq 1 "$CODE"
has "$OUT" "(first)"; has "$OUT" "(second)"; has "$OUT" "(third)"
has "$OUT" reached
has "$OUT" "3 assertion(s) failed"

# ---- soft with nothing failing is a pass
run_case softok <<'EOF'
soft_asserts on
assert_eq a a
printf 'reached\n'
EOF
eq 0 "$CODE" "$OUT"

# ---- a failure inside $(...) counts too, and a test that fails for its own reason keeps its code
run_case sub <<'EOF'
soft_asserts on
x="$(assert_eq a b "(in a subshell)"; printf done)"
printf 'x=%s\n' "$x"
EOF
eq 1 "$CODE"
has "$OUT" "x=done"
run_case ownexit <<'EOF'
soft_asserts on
assert_eq a b
exit 7
EOF
eq 7 "$CODE" "(the test's own exit code stays)"

# ---- the hard stops: fail_now, soft_checkpoint, soft_asserts off
run_case now <<'EOF'
soft_asserts on
fail_now "needed"
printf 'reached\n'
EOF
eq 1 "$CODE"; has "$OUT" "FAIL: needed"; hasnt "$OUT" reached
run_case checkpoint <<'EOF'
soft_asserts on
assert_eq a b "(early)"
assert_eq c d "(also early)"
soft_checkpoint
printf 'reached\n'
EOF
eq 1 "$CODE"; has "$OUT" "(early)"; has "$OUT" "(also early)"; has "$OUT" "2 assertion(s) failed before this point"; hasnt "$OUT" reached
run_case off <<'EOF'
soft_asserts on
assert_eq a b "(soft)"
soft_asserts off
assert_eq c d "(hard)"
printf 'reached\n'
EOF
eq 1 "$CODE"; has "$OUT" "(soft)"; has "$OUT" "(hard)"; hasnt "$OUT" reached

# ---- BENCHBAR_SOFT_ASSERTS=1 is soft mode for a file that never asked
BENCHBAR_SOFT_ASSERTS=1 run_case env <<'EOF'
assert_eq a b "(one)"
assert_eq c d "(two)"
printf 'reached\n'
EOF
eq 1 "$CODE"; has "$OUT" "(one)"; has "$OUT" "(two)"; has "$OUT" reached

# ---- run_fm merges the streams (OUT as before); run_fm_split keeps them apart
run_case streams <<'EOF'
printf '#!/bin/bash\nprintf "to stdout\\n"\nprintf "to stderr\\n" >&2\nexit 3\n' >"$TMP_DIR/fm"
chmod +x "$TMP_DIR/fm"
FM="$TMP_DIR/fm"
run_fm
assert_eq 3 "$CODE"
assert_contains "$OUT" "to stdout"
assert_contains "$OUT" "to stderr"
run_fm_split
assert_eq 3 "$CODE"
assert_eq "to stdout" "$OUT"
assert_eq "to stderr" "$ERR"
assert_eq "to stderr" "$(cat "$MOCK_STATE/stderr")"
printf 'streams ok\n'
EOF
eq 0 "$CODE" "$OUT"; has "$OUT" "streams ok"

# ---- the ps mock: a pid a test made up is never looked up in the real process table
run_case ps <<'EOF'
# $$ is a real process of this machine; the test says it is a fake one
add_proc "$$" "honcho start -f Procfile.lean"
got="$(ps -o command= -p "$$")" && code=0 || code=$?
assert_eq 1 "$code" "(ps answered for a made up pid: $got)"
assert_eq "" "$got"
got="$(ps -o lstart= -p "$$")" && code=0 || code=$?
assert_eq 1 "$code" "(lstart for a made up pid)"
# a recorded answer still wins
mkdir -p "$MOCK_STATE/ps"; printf '/usr/bin/honcho start\n' >"$MOCK_STATE/ps/$$"
assert_eq "/usr/bin/honcho start" "$(ps -o command= -p "$$")"
rm -f "$MOCK_STATE/ps/$$"
# a pid nobody made up still goes to the real ps (the lock tests ask it about real processes)
sleep 30 &
real=$!
got="$(ps -o command= -p "$real")"
kill "$real" 2>/dev/null || true
assert_contains "$got" "sleep"
printf 'ps ok\n'
EOF
eq 0 "$CODE" "$OUT"; has "$OUT" "ps ok"

# ---- cleanup goes through on_exit: the harness owns the EXIT trap, so a soft failure still fails the
# test when the file has cleanup of its own (a trap of its own replaced harness_exit and failed open)
run_case onexit <<'EOF'
soft_asserts on
on_exit 'printf "cleanup one\n"'
on_exit 'printf "cleanup two\n"'
assert_eq a b "(soft)"
printf 'reached\n'
EOF
eq 1 "$CODE" "(a soft failure with on_exit cleanup must fail the test: $OUT)"
has "$OUT" "cleanup one"; has "$OUT" "cleanup two"; has "$OUT" reached
# the cleanup runs before the folder is removed, and a failing command does not stop the rest
run_case onexitdir <<'EOF'
on_exit 'test -d "$TMP_DIR" && printf "dir still there\n"'
on_exit 'false'
on_exit 'printf "after a failure\n"'
EOF
eq 0 "$CODE" "$OUT"; has "$OUT" "dir still there"; has "$OUT" "after a failure"

# ---- a cleanup cannot end the handler or change the status: each runs in a subshell
run_case cleanexit <<'EOF'
soft_asserts on
on_exit 'exit 0'
on_exit 'printf "second ran\n"'
assert_eq a b "(soft)"
EOF
eq 1 "$CODE" "(on_exit 'exit 0' hid a soft failure: $OUT)"; has "$OUT" "second ran"
run_case cleanown <<'EOF'
on_exit 'exit 0'
on_exit 'printf "second ran\n"'
exit 3
EOF
eq 3 "$CODE" "(on_exit 'exit 0' changed the test's own exit code: $OUT)"; has "$OUT" "second ran"
run_case cleanunset <<'EOF'
set -u
soft_asserts on
on_exit 'printf "%s\n" "${UNSET_CLEANUP_VARIABLE}"'
on_exit 'printf "second ran\n"'
assert_eq a b "(soft)"
EOF
eq 1 "$CODE" "(a set -u abort in a cleanup hid a soft failure: $OUT)"; has "$OUT" "second ran"
run_case cleanunsetok <<'EOF'
set -u
on_exit 'printf "%s\n" "${UNSET_CLEANUP_VARIABLE}"'
on_exit 'printf "second ran\n"'
EOF
eq 0 "$CODE" "$OUT"; has "$OUT" "second ran"

# ---- no test that sources the harness (and no tests/lib file but the harness) sets its own EXIT
# trap: it replaces harness_exit and a soft failure then passes. Use on_exit CMD. The scan drops
# heredoc bodies, and a line marked "trap in a child shell" (itself or the line above) is a trap of
# a bash -c child, not of the test.
trap_hits() {
  awk '
    hd != "" { t = $0; sub(/^[ \t]+/, "", t); if (t == hd) hd = ""; prev = $0; next }
    {
      line = $0; keep = line
      if (line ~ /trap in a child shell/ || prev ~ /trap in a child shell/) keep = ""
      print FILENAME ":" FNR ": " keep
      if (match(line, /<<-?[ \t]*["\047]?[A-Za-z_][A-Za-z_0-9]*["\047]?/) && substr(line, RSTART - 1, 1) != "<" && RSTART > 0) {
        hd = substr(line, RSTART, RLENGTH); gsub(/<<-?[ \t]*["\047]?/, "", hd); gsub(/["\047]/, "", hd)
      }
      prev = line
    }' "$@" | grep -E "(^|[;&|({[:space:]])trap[[:space:]]+(-|'[^']*'|\"([^\"\\\\]|\\\\.)*\"|[^[:space:]'\";&|]+)([[:space:]]+[A-Za-z0-9]+)*[[:space:]]+(EXIT|0)([[:space:];&)]|\$)" || true
}
cat >"$WORK/traps-bad.sh" <<'EOF'
trap 'x' EXIT
  trap x 0
f() {
  trap "a; b" EXIT
}
(trap - EXIT)
trap 'x' INT EXIT
if true; then trap 'x' EXIT; fi
EOF
eq 6 "$(trap_hits "$WORK/traps-bad.sh" | wc -l | tr -d ' ')" "(the scan missed a trap form)"
# shellcheck disable=SC2016  # the sample text is not meant to expand
{
  printf '%s\n' "trap 'x' INT" "trap 'exit 143' TERM; wait; exit 0 ;;" "x=\$((1<<3)); y=<<<abc" \
    "cat <<'TXT'" "trap 'x' EXIT" "TXT" "bash -c 'a" "  # trap in a child shell" "  trap x EXIT'" "trap x EXIT # trap in a child shell"
} >"$WORK/traps-ok.sh"
eq "" "$(trap_hits "$WORK/traps-ok.sh")" "(the scan flagged text that is not a trap of the test)"
files=()
for f in "$ROOT"/tests/test-*.sh; do
  grep -qE '^(\.|source) .*lib/harness\.sh' "$f" && files+=("$f")
done
for f in "$ROOT"/tests/lib/*.sh; do
  [[ "${f##*/}" == harness.sh ]] || files+=("$f")
done
hits="$(trap_hits "${files[@]}")"
eq "" "$hits" "(a trap of its own replaces harness_exit and a soft failure then passes: use on_exit CMD)"

# ---- no test picks a "free" port by binding port 0 and closing it: the number is in the system's
# ephemeral range, where a test running beside this one can be handed it before the listener binds.
# Keep the listener open (the port is then held), or pick below that range as test-services-served does.
hits="$(grep -nE 'bind\(\("127\.0\.0\.1", 0\)\).*close\(\)' "$ROOT"/tests/*.sh || true)"
eq "" "$hits" "(a test closes a port it bound to port 0; see test-services-served.sh for a range pick)"

printf 'test-harness: ok\n'
