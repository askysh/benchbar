#!/usr/bin/env bash
#
# apps-fixtures.sh: real git repos for the app and lock tests. Remotes are
# bare repos in the test's temp folder, reached over file://; the git mock
# passes every call to the real git (MOCK_GIT_REAL=1) and the bench mock's
# get-app really clones. No network.

export MOCK_GIT_REAL=1
export GIT_AUTHOR_NAME=Tester GIT_AUTHOR_EMAIL=tester@example.com
export GIT_COMMITTER_NAME=Tester GIT_COMMITTER_EMAIL=tester@example.com
export GIT_CONFIG_NOSYSTEM=1
REMOTES="$TMP_DIR/remotes"
WORK="$TMP_DIR/work"
mkdir -p "$REMOTES" "$WORK"

# make_app_remote NAME [REQUIRED_APP...]: a Frappe app repo (package, hooks.py,
# pyproject.toml) with main and version-15, pushed to $REMOTES/NAME.git
make_app_remote() {
  local name="$1" req="" r
  shift
  for r in "$@"; do req="${req}${req:+, }\"${r}\""; done
  rm -rf "${WORK:?}/$name"
  mkdir -p "$WORK/$name/$name"
  (
    cd "$WORK/$name" || exit 1
    git init -q -b main .
    printf '[project]\nname = "%s"\n' "$name" >pyproject.toml
    printf '__version__ = "1.0.0"\n' >"$name/__init__.py"
    printf 'app_name = "%s"\nrequired_apps = [%s]\n' "$name" "$req" >"$name/hooks.py"
    git add -A && git commit -q -m "${name}: first"
    git branch version-15
    git init -q --bare "$REMOTES/$name.git"
    git remote add origin "file://$REMOTES/$name.git"
    git push -q origin main version-15
  )
}

# push_commits NAME N [BRANCH]: N new commits on the remote's BRANCH
push_commits() {
  local name="$1" n="$2" branch="${3:-main}" i
  (
    cd "$WORK/$name" || exit 1
    git checkout -q "$branch"
    for i in $(seq 1 "$n"); do
      printf '%s %s\n' "$i" "$RANDOM" >>"$name/changes.txt"
      git add -A && git commit -q -m "${name}: change ${i} on ${branch}"
    done
    git push -q origin "$branch"
  )
}

# a policy line in the test's apps.tsv: name, file:// repo, branch for both profiles
add_policy() { printf '%s\tfile://%s/%s.git\t%s\t%s\t500\ttest app\n' "$1" "$REMOTES" "$1" "$2" "$2" >>"$FL_CONFIG_DIR/apps.tsv"; }

app_head() { git -C "$1" rev-parse HEAD; }
