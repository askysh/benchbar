#!/usr/bin/env bash
# scripts/release-ci-gate.sh: the release job builds from a commit whose
# "CI result" check passed, instead of running the whole suite again.
#   - the last finished run decides (a re-run after a failure passes; a
#     failure after a success fails); a run still in progress does not undo
#     a finished green one (the push to main runs CI again on the commit);
#   - a red, missing or running result on the commit fails;
#   - "CI result" is green on a push that changed only docs, because CI skips
#     the tests there: the gate walks back over docs only commits and needs a
#     green result on the nearest commit that changed code as well.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

GATE="$ROOT/scripts/release-ci-gate.sh"
G="$TMP_DIR/gate"
mkdir -p "$G/results" "$G/bin"

# a fake gh: the "status conclusion" lines a commit's check runs would give after the jq filter
cat >"$G/bin/gh" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in repos/*/commits/*/check-runs*) sha="${a#*/commits/}"; sha="${sha%%/*}" ;; esac; done
# the real installs on macOS have their own check: SHA.real, and passed when a test names none
case "$*" in *'Real install result'*)
  if [[ -f "$GATE_RESULTS/$sha.real" ]]; then cat "$GATE_RESULTS/$sha.real"; else echo "completed success"; fi
  exit 0 ;;
esac
[[ -f "$GATE_RESULTS/$sha" ]] && cat "$GATE_RESULTS/$sha"
exit 0
SH
chmod +x "$G/bin/gh"
# a real git (the harness puts a mock first) and the fake gh
export PATH="$G/bin:/usr/bin:/bin" GATE_RESULTS="$G/results" GH_GATE_REPO=askysh/benchbar

# history, oldest first: A code, B code, D1 docs, D2 docs, C code, D3 docs (README.md)
R="$G/repo"
git init -q "$R"
cd "$R"
g() { git -c user.name=t -c user.email=t@example.com "$@"; }
mkdir -p lib docs
echo a >lib/a.sh; g add -A; g commit -q -m A; A="$(git rev-parse HEAD)"
echo b >lib/a.sh; g commit -q -am B; B="$(git rev-parse HEAD)"
echo 1 >docs/g.md; g add -A; g commit -q -m D1; D1="$(git rev-parse HEAD)"
echo 2 >docs/g.md; echo 2 >README.md; g add -A; g commit -q -m D2; D2="$(git rev-parse HEAD)"
echo c >lib/a.sh; g commit -q -am C; C="$(git rev-parse HEAD)"
echo 3 >README.md; g commit -q -am D3; D3="$(git rev-parse HEAD)"
run() { set +e; OUT="$(bash "$GATE" "$@" 2>&1)"; CODE=$?; set -e; }
res() { printf '%s\n' "$2" >"$G/results/$1"; }
clear_res() { mkdir -p "$G/old"; mv "$G"/results/* "$G/old/" 2>/dev/null || true; }

# nothing known: fails, and says why
run "$B"; assert_eq 1 "$CODE"; assert_contains "$OUT" 'no passed "CI result"'

# green on a code commit
res "$B" "completed success"
run "$B"; assert_eq 0 "$CODE" "$OUT"; assert_contains "$OUT" "CI result passed on ${B:0:9}"

# a red code push followed by a docs push: the docs push is green (CI skipped the
# tests), the code push is red: refused
clear_res
res "$B" "completed failure"; res "$D1" "completed success"
run "$D1"; assert_eq 1 "$CODE"; assert_contains "$OUT" "CI result is failure on ${B:0:9}"
assert_contains "$OUT" "nearest commit that ran the tests"
# the same through two docs commits
res "$D2" "completed success"
run "$D2"; assert_eq 1 "$CODE"; assert_contains "$OUT" "CI result is failure on ${B:0:9}"

# a green code push followed by a docs push: passes, and says which commit ran the tests
clear_res
res "$B" "completed success"; res "$D1" "completed success"
run "$D1"; assert_eq 0 "$CODE" "$OUT"
assert_contains "$OUT" "CI result passed on ${D1:0:9}"; assert_contains "$OUT" "CI result passed on ${B:0:9}"
# two docs commits: the one in between needs no result of its own
clear_res
res "$B" "completed success"; res "$D2" "completed success"
run "$D2"; assert_eq 0 "$CODE" "$OUT"

# a docs push is green but the code push before it has no result: refused
clear_res
res "$D1" "completed success"
run "$D1"; assert_eq 1 "$CODE"; assert_contains "$OUT" "no passed \"CI result\" on ${B:0:9}"
# the tagged docs commit itself must be green too
clear_res
res "$B" "completed success"
run "$D1"; assert_eq 1 "$CODE"; assert_contains "$OUT" "no passed \"CI result\" on ${D1:0:9}"

# the walk stops at the nearest code commit, not an older one (A, B are green, C is not)
clear_res
res "$A" "completed success"; res "$B" "completed success"; res "$D3" "completed success"
run "$D3"; assert_eq 1 "$CODE"; assert_contains "$OUT" "on ${C:0:9}"

# a history of docs only commits: nothing ever ran the tests
G2="$G/docsrepo"
git init -q "$G2"
cd "$G2"
echo 1 >README.md; g add -A; g commit -q -m only
H="$(git rev-parse HEAD)"; res "$H" "completed success"
run "$H"; assert_eq 1 "$CODE"; assert_contains "$OUT" "no commit ran the tests"
cd "$R"

# a red result on the commit fails
clear_res
res "$C" "completed failure"
run "$C"; assert_eq 1 "$CODE"; assert_contains "$OUT" "CI result is failure on ${C:0:9}"
res "$C" "completed cancelled"
run "$C"; assert_eq 1 "$CODE"; assert_contains "$OUT" "cancelled"

# the last finished run wins (a re-run after a failure; a failure after a success)
printf 'completed failure\ncompleted success\n' >"$G/results/$C"
run "$C"; assert_eq 0 "$CODE" "$OUT"
printf 'completed success\ncompleted failure\n' >"$G/results/$C"
run "$C"; assert_eq 1 "$CODE"

# the push to main runs CI again on the same commit: a run in progress after a
# green one does not undo it; with no finished run, in progress fails
printf 'completed success\nin_progress \n' >"$G/results/$C"
run "$C"; assert_eq 0 "$CODE" "$OUT"
echo "queued " >"$G/results/$C"
run "$C"; assert_eq 1 "$CODE"; assert_contains "$OUT" "running"

# the real installs on macOS: their own check, on the commit or on a docs only
# commit under it down to the code commit
clear_res
res "$B" "completed success"; res "$D1" "completed success"; res "$D2" "completed success"
: >"$G/results/$D2.real"; : >"$G/results/$D1.real"; : >"$G/results/$B.real"
run "$D2"; assert_eq 1 "$CODE"; assert_contains "$OUT" 'no passed "Real install result (macOS)"'
assert_contains "$OUT" "gh workflow run real-install.yml"
res "$B.real" "completed success"
run "$D2"; assert_eq 0 "$CODE" "$OUT"; assert_contains "$OUT" "Real install result (macOS) passed on ${B:0:9}"
# the newest finished run decides: a failure on the head is not undone by an older pass
res "$D2.real" "completed failure"
run "$D2"; assert_eq 1 "$CODE"; assert_contains "$OUT" "Real install result (macOS) is failure on ${D2:0:9}"
# a run in progress is not a pass
: >"$G/results/$B.real"; echo "in_progress " >"$G/results/$D2.real"
run "$D2"; assert_eq 1 "$CODE"; assert_contains "$OUT" "running on ${D2:0:9}"
# a pass on a commit below the code commit does not count (A is under B)
clear_res
res "$B" "completed success"; : >"$G/results/$B.real"; res "$A.real" "completed success"
run "$B"; assert_eq 1 "$CODE"; assert_contains "$OUT" 'no passed "Real install result (macOS)"'

# no repository
set +e; OUT="$(GH_GATE_REPO="" GITHUB_REPOSITORY="" bash "$GATE" "$B" 2>&1)"; CODE=$?; set -e
assert_eq 1 "$CODE"; assert_contains "$OUT" "no repository"

printf 'test-release-ci-gate: ok\n'
