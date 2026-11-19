#!/usr/bin/env bash
# scripts/release-ci-gate.sh: the release job builds from a commit whose
# "CI result" check passed, instead of running the whole suite again. A
# merge commit whose CI is still running counts when a parent has the same
# tree and passed; a red, missing or running result on every such commit
# fails; the last of several runs wins.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

GATE="$ROOT/scripts/release-ci-gate.sh"
G="$TMP_DIR/gate"
mkdir -p "$G/results" "$G/bin"

# a fake gh: the "status conclusion" line a commit's check runs would give after the jq filter
cat >"$G/bin/gh" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in repos/*/commits/*/check-runs*) sha="${a#*/commits/}"; sha="${sha%%/*}" ;; esac; done
[[ -f "$GATE_RESULTS/$sha" ]] && cat "$GATE_RESULTS/$sha"
exit 0
SH
chmod +x "$G/bin/gh"
export PATH="$G/bin:/usr/bin:/bin" GATE_RESULTS="$G/results" GH_GATE_REPO=askysh/benchbar

# main:  A --- B (next-release tip) ; M = merge of A and B (same tree as B); X = a commit with another tree
R="$G/repo"
git init -q "$R"
cd "$R"
g() { git -c user.name=t -c user.email=t@example.com "$@"; }
echo a >f; g add f; g commit -q -m A; A="$(git rev-parse HEAD)"
git branch -q -M main
git checkout -q -b next-release
echo b >f; g commit -q -am B; B="$(git rev-parse HEAD)"
git checkout -q main
g merge -q --no-ff -m M next-release; M="$(git rev-parse HEAD)"
echo x >f; g commit -q -am X; X="$(git rev-parse HEAD)"
run() { set +e; OUT="$(bash "$GATE" "$@" 2>&1)"; CODE=$?; set -e; }

# nothing known: fails, and says why
run "$B"; assert_eq 1 "$CODE"; assert_contains "$OUT" 'no passed "CI result"'

# green on the commit itself
echo "completed success" >"$G/results/$B"
run "$B"; assert_eq 0 "$CODE" "$OUT"; assert_contains "$OUT" "CI result passed on ${B:0:9}"

# the merge commit has no result yet (running): its parent B has the same tree and passed
echo "in_progress " >"$G/results/$M"
run "$M"; assert_eq 0 "$CODE" "$OUT"; assert_contains "$OUT" "same tree as ${M:0:9}"

# a parent with another tree does not count
echo "completed success" >"$G/results/$A"
rm -f "$G/results/$B"
run "$M"; assert_eq 1 "$CODE"; assert_not_contains "$OUT" "${A:0:9}: success"

# a red result on the commit fails, whatever its parent says
echo "completed success" >"$G/results/$B"
echo "completed failure" >"$G/results/$M"
run "$M"; assert_eq 1 "$CODE"; assert_contains "$OUT" "CI result is failure on ${M:0:9}"
echo "completed cancelled" >"$G/results/$M"
run "$M"; assert_eq 1 "$CODE"; assert_contains "$OUT" "cancelled"

# the last of several runs wins (a re-run after a failure)
printf 'completed failure\ncompleted success\n' >"$G/results/$X"
run "$X"; assert_eq 0 "$CODE" "$OUT"
printf 'completed success\ncompleted failure\n' >"$G/results/$X"
run "$X"; assert_eq 1 "$CODE"

# still running, and no parent to ask
echo "queued " >"$G/results/$X"
run "$X"; assert_eq 1 "$CODE"; assert_contains "$OUT" "running"

# no repository
set +e; OUT="$(GH_GATE_REPO="" GITHUB_REPOSITORY="" bash "$GATE" "$B" 2>&1)"; CODE=$?; set -e
assert_eq 1 "$CODE"; assert_contains "$OUT" "no repository"

printf 'test-release-ci-gate: ok\n'
