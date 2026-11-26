#!/usr/bin/env bash
# profile update, pinned byte for byte (issue 146): the exit code, stdout, stderr and mock calls of every way
# the command ends, in tests/golden/profile-update.txt. A change that only moves code (splitting
# fl_cmd_profile_update into steps) leaves the file as it is. PIN_UPDATE=1 rewrites it, PIN_SMOKE=1 runs the smoke scenarios only.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=tests/lib/apps-fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/apps-fixtures.sh"
# shellcheck source=tests/lib/pin.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/pin.sh"
fail() { printf "FAIL (line %s): %s\n" "${BASH_LINENO[1]}" "$*" >&2; exit 1; }

# a file source and a subscribed repo are local folders here: files from others take a local repo only with this
export BENCHBAR_ALLOW_LOCAL_REPOS=1
USER_DIR="$HOME/.config/benchbar/profiles"
mkdir -p "$USER_DIR"
SRC="$TMP_DIR/src"
mkdir -p "$SRC"
REMOTE="$TMP_DIR/remotes/team-config.git"
TEAM="$TMP_DIR/team-config"
SUB_URL="file://$REMOTE"
SUB_DIR="$HOME/.config/benchbar/sources/remotes-team-config"
T0="$(printf '%064d' 0)"

# the profile file an import wrote, and the clone of a subscription, after a run
pstate() {
  pin_state "$1 shared.toml" "$([[ -f "$USER_DIR/shared.toml" ]] && grep '^description' "$USER_DIR/shared.toml" || printf none)"
  if [[ -d "$SUB_DIR/.git" ]]; then
    pin_state "$1 clone" "$(git -C "$SUB_DIR" rev-parse --short HEAD) $(grep '^description' "$SUB_DIR/profiles/team-a.toml")"
  else
    pin_state "$1 clone" none
  fi
}
run() { local n="$1"; shift; pin_run "$n" "$@"; pstate "$n"; }
digest_of() { printf '%s' "$PIN_STDOUT" | jget - 'd["digest"]'; }
src_text() { printf 'base = "v15-lts"\ndescription = "%s"\nsite = "shared.localhost"\n' "$1" >"$SRC/shared.toml"; }
# fresh_import: the user's file "shared" imported from a source that says "Shared"
fresh_import() {
  rm -f "$USER_DIR/shared.toml"
  src_text "Shared"
  "$FM" profile import "$SRC/shared.toml" --as shared --yes >/dev/null 2>&1 || fail "setup: profile import"
}
# team_commit TEXT: a commit of the team repo that says TEXT, pushed
team_commit() {
  pin_date
  (
    cd "$TEAM" || exit 1
    printf 'base = "v15-lts"\ndescription = "%s"\n' "$1" >profiles/team-a.toml
    git commit -q -am "$1"
    git push -q origin main
  )
}
mkdir -p "$TEAM/profiles"
pin_date
(
  cd "$TEAM" || exit 1
  git init -q -b main .
  printf 'base = "v15-lts"\ndescription = "Team A"\n' >profiles/team-a.toml
  git add -A && git commit -q -m "team profiles"
  git init -q --bare "$REMOTE"
  git remote add origin "$SUB_URL"
  git push -q origin main
)
git --git-dir="$REMOTE" symbolic-ref HEAD refs/heads/main

# ---- usage and refusals before any fetch
if pin_full; then
  run "no target" profile update
  run "unknown option" profile update --bogus
  run "invalid name" profile update "Bad Name"
fi
run "no such profile" profile update nosuch
printf 'base = "v15-lts"\n' >"$USER_DIR/own.toml"
if pin_full; then run "a file of your own, not imported" profile update own; fi

# ---- an import: the source is a file
fresh_import
if pin_full; then
  run "imported, up to date, plan" profile update shared --plan
  run "imported, up to date, plan json" profile update shared --plan --json
  run "imported, up to date" profile update shared --yes
fi
src_text "Shared 2"
if pin_full; then
  run "imported, changed, plan" profile update shared --plan
fi
run "imported, changed, plan json" profile update shared --plan --json
DIG="$(digest_of)"
if pin_full; then
  run "imported, changed, dry run" profile update shared --dry-run
  run "imported, changed, cancelled at the prompt" profile update shared
  BENCHBAR_NONINTERACTIVE=1 run "imported, changed, nothing can ask" profile update shared
  run "imported, changed, a digest of another review" profile update shared --expect "$T0" --yes
  run "imported, changed, the digest as --expect=" profile update shared "--expect=$T0" --yes
fi
run "imported, changed, apply with its digest, json" profile update shared --expect "$DIG" --yes --json
if pin_full; then
  run "imported, after the apply" profile update shared --plan
  src_text "Shared 3"
  run "imported, apply without a digest" profile update shared --yes
  src_text "Shared 4"
  chmod 400 "$USER_DIR/shared.toml"
  run "imported, the file cannot be written" profile update shared --yes
  chmod 600 "$USER_DIR/shared.toml"
  mv "$SRC/shared.toml" "$SRC/shared.moved"
  run "imported, the source cannot be read" profile update shared --yes
  run "imported, the source cannot be read, plan json" profile update shared --plan --json
  printf 'plugin = 1\n' >"$SRC/shared.toml"
  run "imported, the source no longer parses" profile update shared --yes
  rm -f "$SRC/shared.toml" "$SRC/shared.moved"
fi
# the file as the chapters below find it, however far the one above went
fresh_import

# ---- a subscription: a git repo of profiles
"$FM" profile subscribe "$SUB_URL" --yes >/dev/null 2>&1 || fail "setup: profile subscribe"
if pin_full; then
  run "subscribed, up to date, plan" profile update team-a --plan
  run "subscribed, up to date" profile update team-a --yes
fi
team_commit "Team A v2"
if pin_full; then
  run "subscribed, behind, plan" profile update team-a --plan
fi
run "subscribed, behind, plan json" profile update team-a --plan --json
DIG="$(digest_of)"
if pin_full; then
  run "subscribed, behind, dry run" profile update team-a --dry-run
  run "subscribed, behind, cancelled at the prompt" profile update team-a
  BENCHBAR_NONINTERACTIVE=1 run "subscribed, behind, nothing can ask" profile update team-a
  run "subscribed, behind, a digest of another review" profile update team-a --expect "$T0" --yes
  run "subscribed, behind, by the name of the subscription" profile update remotes-team-config --plan
fi
run "subscribed, behind, apply with its digest, json" profile update team-a --expect "$DIG" --yes --json
if pin_full; then
  run "subscribed, after the apply" profile update team-a --yes
fi
# a local commit in the clone and a new one upstream: not a fast forward
team_commit "Team A v3"
git -C "$SUB_DIR" commit -q --allow-empty -m "local work"
if pin_full; then
  run "subscribed, not a fast forward" profile update team-a --yes
  run "subscribed, not a fast forward, json" profile update team-a --yes --json
fi
git -C "$SUB_DIR" reset -q --hard HEAD~1
git -C "$SUB_DIR" pull -q --ff-only origin main
# the remote is gone: the last fetch is shown
if pin_full; then
  mv "$REMOTE" "$REMOTE.moved"
  run "subscribed, the remote cannot be fetched" profile update team-a --plan
  mv "$REMOTE.moved" "$REMOTE"
fi

# ---- every import and subscription
fresh_import
src_text "Shared 5"
team_commit "Team A v4"
run "all, plan" profile update --all --plan
if pin_full; then
  run "all, plan json" profile update --all --plan --json
  run "all, dry run" profile update --all --dry-run
  BENCHBAR_NONINTERACTIVE=1 run "all, nothing can ask" profile update --all
  run "all, cancelled at the prompt" profile update --all
  run "all, apply" profile update --all --yes
  run "all, after the apply" profile update --all --plan
fi

pin_check profile-update.txt
echo "test-profile-update-pin: ok"
