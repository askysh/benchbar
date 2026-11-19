#!/usr/bin/env bash
# scripts/release-promote.sh cuts a release by a fast forward of main to
# next-release. When main is not an ancestor it syncs only docs commits (one merge
# commit of main into next-release, pushed to next-release) and refuses anything
# else (it never forces); it refuses too when the version is a candidate or disagrees, when the tag exists
# or when "CI result" is not green; a dry run and a "no" push nothing; a yes
# runs one plain `git push origin SHA:refs/heads/main`. A real git on local
# folders stands in for the remote; gh is a fake and git is wrapped to log
# its calls. No network.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

PROMOTE="$ROOT/scripts/release-promote.sh"
G="$TMP_DIR/promote"
mkdir -p "$G/bin" "$G/results"

# fake gh: the check runs of a commit come from a file named after it
cat >"$G/bin/gh" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in repos/*/commits/*/check-runs*) sha="${a#*/commits/}"; sha="${sha%%/*}" ;; esac; done
if [[ -f "$GATE_RESULTS/$sha" ]]; then cat "$GATE_RESULTS/$sha"
elif [[ -f "$GATE_RESULTS/default" ]]; then cat "$GATE_RESULTS/default"; fi
exit 0
SH
# git wrapper: logs every call, then runs the real git
cat >"$G/bin/git" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GIT_LOG"
exec /usr/bin/git "$@"
SH
chmod +x "$G/bin/gh" "$G/bin/git"
export PATH="$G/bin:/usr/bin:/bin" GATE_RESULTS="$G/results" GIT_LOG="$G/git.log" GH_GATE_REPO=askysh/benchbar

g() { git -c user.name=t -c user.email=t@example.com "$@"; }

# write_tree VERSION: the files check-version.sh reads, saying VERSION
write_tree() {
  local v="$1"
  mkdir -p macos .github/ISSUE_TEMPLATE changelog.d lib
  printf 'FL_VERSION="%s"\n' "$v" >benchbar
  printf '  MARKETING_VERSION: "%s"\n' "$v" >macos/project.yml
  for f in bug_report bug_report_windows; do printf '      placeholder: benchbar %s\n' "$v" >".github/ISSUE_TEMPLATE/$f.yml"; done
  printf '# Changelog\n\n## Unreleased\n\n## %s - 2026-01-01\n\n- a change\n' "$v" >CHANGELOG.md
  printf 'Release %s\n' "$v" >README.md
  printf 'Release %s\n' "$v" >ROADMAP.md
  printf 'fragments go here\n' >changelog.d/README.md
}

# setup: a bare remote with main at 0.8.3 (tagged) and next-release one commit on, 0.9.0
setup() {
  cd "$G"
  rm -rf "$G/remote.git" "$G/work" "$G/results" "$GIT_LOG"
  mkdir -p "$G/results"
  git init -q --bare "$G/remote.git"
  git init -q "$G/work"
  cd "$G/work"
  git remote add origin "$G/remote.git"
  g checkout -q -b main
  write_tree 0.8.3; g add -A; g commit -q -m "0.8.3"; MAIN0="$(git rev-parse HEAD)"
  g tag v0.8.3
  g checkout -q -b next-release
  echo x >lib/x.sh; g add -A; g commit -q -m "feature"
  write_tree 0.9.0; g add -A; g commit -q -m "Release 0.9.0"; NEXT="$(git rev-parse HEAD)"
  git push -q origin main next-release --tags 2>/dev/null
  : >"$GIT_LOG"
}
remote_main() { /usr/bin/git --git-dir="$G/remote.git" rev-parse main; }
ci() { printf '%s\n' "$2" >"$G/results/$1"; }
run() { set +e; OUT="$(bash "$PROMOTE" "$@" 2>&1 </dev/null)"; CODE=$?; set -e; }
runin() { local input="$1"; shift; set +e; OUT="$(printf '%s\n' "$input" | bash "$PROMOTE" "$@" 2>&1)"; CODE=$?; set -e; }
pushed() { grep -c '^push origin [0-9a-f]*:refs/heads/main' "$GIT_LOG" || true; }
pushed_next() { grep -c '^push origin [0-9a-f]*:refs/heads/next-release' "$GIT_LOG" || true; }
remote_next() { /usr/bin/git --git-dir="$G/remote.git" rev-parse next-release; }
# main_ahead KIND: main gets one more commit than next-release (docs, docs2: a docs file; code: lib/y.sh)
main_ahead() {
  (
    cd "$G/work"; g checkout -q main
    case "$1" in
      docs) mkdir -p docs; echo "a fixed typo" >docs/fix.md ;;
      docs2) echo "more docs" >site-note.md ;;
      code) mkdir -p lib; echo hotfix >lib/y.sh ;;
    esac
    g add -A; g commit -q -m "fix on main ($1)"
    git push -q origin main 2>/dev/null
  )
  MAIN1="$(remote_main)"; : >"$GIT_LOG"
}
assert_untouched() { assert_eq "$MAIN0" "$(remote_main)" "main moved: $1"; assert_eq 0 "$(pushed)" "a push happened: $1"; }

# ---- a dry run shows the plan and pushes nothing
setup; ci "$NEXT" "completed success"
run --dry-run; assert_eq 0 "$CODE" "$OUT"
assert_contains "$OUT" "version  0.9.0 (a final release)"
assert_contains "$OUT" "main     ${MAIN0:0:9} to ${NEXT:0:9}, 2 commit(s), a fast forward"
assert_contains "$OUT" "CI result passed on ${NEXT:0:9}"
assert_contains "$OUT" "git push origin ${NEXT:0:9}:refs/heads/main"
assert_contains "$OUT" "Dry run: nothing was pushed"
assert_untouched "dry run"

# ---- no answer, no, and end of input push nothing
runin "n" ; assert_eq 1 "$CODE"; assert_contains "$OUT" "Cancelled"; assert_untouched "no"
run; assert_eq 1 "$CODE"; assert_contains "$OUT" "Cancelled"; assert_untouched "no input"

# ---- yes (typed, or --yes) fast forwards main with one plain push, no force, no merge
runin "y"; assert_eq 0 "$CODE" "$OUT"
assert_eq "$NEXT" "$(remote_main)"; assert_eq 1 "$(pushed)"
assert_contains "$OUT" "main is at ${NEXT:0:9}"
push_line="$(grep '^push origin [0-9a-f]*:refs/heads/main' "$GIT_LOG")"
assert_eq "push origin ${NEXT}:refs/heads/main" "$push_line"
assert_not_contains "$(cat "$GIT_LOG")" "--force"
assert_not_contains "$(cat "$GIT_LOG")" " merge "
assert_not_contains "$(cat "$GIT_LOG")" "+refs/heads/main:refs/heads/main"
assert_eq 0 "$(/usr/bin/git --git-dir="$G/remote.git" rev-list --merges "$MAIN0..main" | wc -l | tr -d ' ')" "a merge commit on main"
assert_eq "$(/usr/bin/git --git-dir="$G/remote.git" rev-parse next-release)" "$(remote_main)"

setup; ci "$NEXT" "completed success"
run --yes; assert_eq 0 "$CODE" "$OUT"; assert_eq "$NEXT" "$(remote_main)"

# already the same commit
run --yes; assert_eq 1 "$CODE"; assert_contains "$OUT" "nothing to release"

# ---- main has a commit that next-release has not: refused, never merged or forced
setup; ci "$NEXT" "completed success"
(
  cd "$G/work"; g checkout -q main; echo hotfix >hotfix.txt; g add -A; g commit -q -m "hotfix on main"
  git push -q origin main 2>/dev/null
)
HOT="$(remote_main)"
: >"$GIT_LOG"
run --yes; assert_eq 1 "$CODE"
assert_contains "$OUT" "has commits that next-release"
assert_contains "$OUT" "will not merge or force it"
assert_contains "$OUT" "hotfix on main"
assert_eq "$HOT" "$(remote_main)"; assert_eq 0 "$(pushed)"
assert_not_contains "$(cat "$GIT_LOG")" "merge "

# ---- main ahead by docs only: sync (one merge commit into next-release), then the fast forward
setup; main_ahead docs; ci default "completed success"
run --yes; assert_eq 0 "$CODE" "$OUT"
assert_contains "$OUT" "main has 1 docs commit(s) next-release has not"
assert_contains "$OUT" "next-release is at"
assert_contains "$OUT" "main is at"
M="$(remote_next)"
assert_eq "$M" "$(remote_main)" "main and next-release equal"
assert_eq "$NEXT" "$(/usr/bin/git --git-dir="$G/remote.git" rev-parse "$M^1")" "first parent is the old next-release"
assert_eq "$MAIN1" "$(/usr/bin/git --git-dir="$G/remote.git" rev-parse "$M^2")" "second parent is main"
assert_eq 2 "$(/usr/bin/git --git-dir="$G/remote.git" rev-list --parents -n 1 "$M" | wc -w | tr -d ' ' | awk '{print $1-1}')" "two parents"
assert_eq 1 "$(pushed_next)" "one push to next-release"; assert_eq 1 "$(pushed)" "one push to main"
assert_contains "$(grep '^push origin [0-9a-f]*:refs/heads/next-release' "$GIT_LOG")" "push origin ${M}:refs/heads/next-release"
assert_not_contains "$(cat "$GIT_LOG")" "--force"
assert_not_contains "$(grep '^push ' "$GIT_LOG")" "+refs"
assert_eq "a fixed typo" "$(/usr/bin/git --git-dir="$G/remote.git" show "main:docs/fix.md")"
assert_eq "$(( $(/usr/bin/git --git-dir="$G/remote.git" rev-list --count "$NEXT..$M") ))" 2 "the merge and the docs commit"
# the checkout the script ran in is untouched (branch and files)
assert_eq "main" "$(cd "$G/work" && git rev-parse --abbrev-ref HEAD)"

# without --yes: two questions; no to the sync pushes nothing, a yes to the sync and a no to main stops between
setup; main_ahead docs; ci default "completed success"
runin "n"; assert_eq 1 "$CODE"; assert_contains "$OUT" "Cancelled"; assert_eq 0 "$(pushed_next)"; assert_eq "$NEXT" "$(remote_next)"; assert_eq "$MAIN1" "$(remote_main)"
runin $'y\nn'; assert_eq 1 "$CODE"; assert_eq 1 "$(pushed_next)"; assert_eq 0 "$(pushed)"; assert_eq "$MAIN1" "$(remote_main)"
# then main is behind next-release: the second run is a plain fast forward with no sync
: >"$GIT_LOG"; M="$(remote_next)"
run --yes; assert_eq 0 "$CODE" "$OUT"; assert_not_contains "$OUT" "docs commit(s)"; assert_eq 0 "$(pushed_next)"; assert_eq "$M" "$(remote_main)"

# the merge has no CI result yet: the run stops after the sync, main untouched, the second run passes
setup; main_ahead docs; ci "$NEXT" "completed success"
run --yes; assert_eq 1 "$CODE"; assert_contains "$OUT" "Wait for \"CI result\" on next-release"
assert_eq 1 "$(pushed_next)"; assert_eq 0 "$(pushed)"; assert_eq "$MAIN1" "$(remote_main)"
M="$(remote_next)"; ci "$M" "completed success"
run --yes; assert_eq 0 "$CODE" "$OUT"; assert_eq "$M" "$(remote_main)"

# next-release itself red: refused before the sync, nothing pushed
setup; main_ahead docs; ci "$NEXT" "completed failure"
run --yes; assert_eq 1 "$CODE"; assert_contains "$OUT" "CI result is failure on ${NEXT:0:9}"
assert_eq 0 "$(pushed_next)"; assert_eq 0 "$(pushed)"; assert_eq "$NEXT" "$(remote_next)"

# two docs commits on main
setup; main_ahead docs; main_ahead docs2; ci default "completed success"
run --yes; assert_eq 0 "$CODE" "$OUT"; assert_contains "$OUT" "2 docs commit(s)"
assert_eq "$(remote_next)" "$(remote_main)"

# ---- main ahead by a code commit: refused, nothing pushed, nothing merged
setup; main_ahead code; ci default "completed success"
run --yes; assert_eq 1 "$CODE"
assert_contains "$OUT" "not only docs"; assert_contains "$OUT" "fix on main (code)"; assert_contains "$OUT" "changes lib/y.sh"
assert_eq 0 "$(pushed_next)"; assert_eq 0 "$(pushed)"; assert_eq "$NEXT" "$(remote_next)"; assert_eq "$MAIN1" "$(remote_main)"
assert_not_contains "$(cat "$GIT_LOG")" "commit-tree"
# a docs commit and a code commit: the code one stops it
setup; main_ahead docs; main_ahead code; ci default "completed success"
run --yes; assert_eq 1 "$CODE"; assert_contains "$OUT" "fix on main (code)"; assert_not_contains "$OUT" "fix on main (docs)"
assert_eq 0 "$(pushed_next)"; assert_eq 0 "$(pushed)"

# ---- a sync conflict (both sides changed the same docs file) stops it and pushes nothing
setup; ci default "completed success"
(
  cd "$G/work"; g checkout -q next-release; echo "next side" >docs.md; g add -A; g commit -q -m "docs.md on next-release"; git push -q origin next-release 2>/dev/null
  g checkout -q main; echo "main side" >docs.md; g add -A; g commit -q -m "docs.md on main"; git push -q origin main 2>/dev/null
)
NEXT="$(remote_next)"; MAIN1="$(remote_main)"; : >"$GIT_LOG"
run --yes; assert_eq 1 "$CODE"
assert_contains "$OUT" "conflicts"; assert_contains "$OUT" "by pull request"
assert_eq 0 "$(pushed_next)"; assert_eq 0 "$(pushed)"; assert_eq "$NEXT" "$(remote_next)"; assert_eq "$MAIN1" "$(remote_main)"
assert_not_contains "$(cat "$GIT_LOG")" "commit-tree"

# ---- --dry-run with main ahead: shows the sync, pushes nothing, moves nothing
setup; main_ahead docs; ci default "completed success"
run --dry-run; assert_eq 0 "$CODE" "$OUT"
assert_contains "$OUT" "sync     main has 1 docs commit(s) next-release has not; one merge commit"
assert_contains "$OUT" "fix on main (docs)"
assert_contains "$OUT" ":refs/heads/next-release   (a fast forward of next-release"
assert_contains "$OUT" ":refs/heads/main   (no force"
assert_contains "$OUT" "Dry run: nothing was pushed"
assert_eq 0 "$(pushed_next)"; assert_eq 0 "$(pushed)"; assert_eq "$NEXT" "$(remote_next)"; assert_eq "$MAIN1" "$(remote_main)"
assert_eq "main" "$(cd "$G/work" && git rev-parse --abbrev-ref HEAD)"
# a dry run with a code commit on main refuses, as a real run does
setup; main_ahead code; ci default "completed success"
run --dry-run; assert_eq 1 "$CODE"; assert_contains "$OUT" "not only docs"

# ---- a release candidate never goes to main
setup; ci "$NEXT" "completed success"
(
  cd "$G/work"; g checkout -q next-release; write_tree 0.9.0-rc.1; g add -A; g commit -q -m "rc"
  git push -q origin next-release 2>/dev/null
)
NEXT="$(/usr/bin/git --git-dir="$G/remote.git" rev-parse next-release)"; ci "$NEXT" "completed success"
run --yes; assert_eq 1 "$CODE"; assert_contains "$OUT" "release candidate"; assert_untouched "candidate"

# ---- the version places disagree, or a fragment is left
setup
(
  cd "$G/work"; g checkout -q next-release; printf 'MARKETING_VERSION: "9.9.9"\n' >macos/project.yml
  g add -A; g commit -q -m "drift"; git push -q origin next-release 2>/dev/null
)
NEXT="$(/usr/bin/git --git-dir="$G/remote.git" rev-parse next-release)"; ci "$NEXT" "completed success"
run --yes; assert_eq 1 "$CODE"; assert_contains "$OUT" "MARKETING_VERSION in macos/project.yml"; assert_contains "$OUT" "disagree"; assert_untouched "drift"
setup
(
  cd "$G/work"; g checkout -q next-release; printf 'a fragment\n' >changelog.d/1-x.md; g add -A; g commit -q -m "fragment"; git push -q origin next-release 2>/dev/null
)
NEXT="$(/usr/bin/git --git-dir="$G/remote.git" rev-parse next-release)"; ci "$NEXT" "completed success"
run --yes; assert_eq 1 "$CODE"; assert_contains "$OUT" "fragments are left"; assert_untouched "fragment"

# ---- the tag exists already: a release with no new version
setup; ci "$NEXT" "completed success"
(
  cd "$G/work"; g tag v0.9.0 "$NEXT"; git push -q origin v0.9.0 2>/dev/null
)
run --yes; assert_eq 1 "$CODE"; assert_contains "$OUT" "v0.9.0 is tagged already"; assert_untouched "tag exists"

# ---- CI: red, missing, running
setup; ci "$NEXT" "completed failure"
run --yes; assert_eq 1 "$CODE"; assert_contains "$OUT" "CI result is failure on ${NEXT:0:9}"; assert_untouched "red"
setup
run --yes; assert_eq 1 "$CODE"; assert_contains "$OUT" 'no passed "CI result"'; assert_untouched "none"
ci "$NEXT" "in_progress "
run --yes; assert_eq 1 "$CODE"; assert_contains "$OUT" "running"; assert_untouched "running"

# ---- CI is green on a docs only head but red on the code commit before it
setup
(
  cd "$G/work"; g checkout -q next-release; echo more >docs.md; g add -A; g commit -q -m "docs"; git push -q origin next-release 2>/dev/null
)
DOCS="$(/usr/bin/git --git-dir="$G/remote.git" rev-parse next-release)"
ci "$DOCS" "completed success"; ci "$NEXT" "completed failure"
run --yes; assert_eq 1 "$CODE"; assert_contains "$OUT" "CI result is failure on ${NEXT:0:9}"; assert_untouched "docs after red code"
ci "$NEXT" "completed success"
run --dry-run; assert_eq 0 "$CODE" "$OUT"; assert_contains "$OUT" "CI result passed on ${NEXT:0:9}"

# ---- a push the remote refuses is reported, never forced
setup; ci "$NEXT" "completed success"
printf '#!/bin/sh\necho "remote: main is protected" >&2\nexit 1\n' >"$G/work/.git/hooks/pre-push"
chmod +x "$G/work/.git/hooks/pre-push"
run --yes; assert_eq 1 "$CODE"; assert_contains "$OUT" "the push was refused"; assert_contains "$OUT" "Nothing was forced"
assert_eq "$MAIN0" "$(remote_main)"
assert_not_contains "$(cat "$GIT_LOG")" "--force"

# ---- usage
run --nope; assert_eq 2 "$CODE"

printf 'test-release-promote: ok\n'
