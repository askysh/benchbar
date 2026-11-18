#!/usr/bin/env bash
#
# bench-apps-speed.sh: how long "app list --json" and "profile check" take
# on a big bench, with no network and no real bench.
#
#   bash scripts/bench-apps-speed.sh [APPS] [PROFILE_APPS]    (36 and 23 by default)
#
# It builds a throwaway bench in a temp folder (the test harness' HOME, mocks
# and config): APPS local git repos cloned from local bare remotes (half of
# them shallow, one dirty, one on another branch, a few with a commit of your
# user.email), and a team profile with PROFILE_APPS repos on local bare remotes.
# Then it times
#
#   benchbar app list --json --no-sites     the focus inference and the git reads
#   benchbar app list --json                the same, with the site list of the cache (plain)
#   benchbar profile check NAME --json      one ls-remote per app
#
# A local ls-remote returns at once, so a real round trip is faked: the git on
# PATH sleeps BENCH_NET_DELAY seconds (default 2) before an ls-remote, which
# is what 23 SSH and HTTPS repos cost on a fast line (50 s in all). With
# BENCH_COUNT_GIT=1 it also counts the git processes the commands start.
# Nothing here touches ~/dev/frappe-bench, a real MariaDB or the network.

set -euo pipefail
N_APPS="${1:-36}"
N_PROFILE="${2:-23}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
. "$ROOT/tests/lib/harness.sh"
# shellcheck source=tests/lib/apps-fixtures.sh
. "$ROOT/tests/lib/apps-fixtures.sh"

# the harness puts its git mock first on PATH: swap it for a real git that only
# delays ls-remote (and counts calls) so the timings are the CLI's own
SHIM="$TMP_DIR/shim"
mkdir -p "$SHIM"
for f in "$ROOT"/tests/mocks/bin/*; do [[ "${f##*/}" == "git" ]] || ln -s "$f" "$SHIM/${f##*/}"; done
REAL_GIT="$(PATH="/usr/bin:/opt/homebrew/bin:/usr/local/bin" command -v git)"
cat >"$SHIM/git" <<SH
#!/bin/bash
[[ -n "\${BENCH_COUNT_GIT:-}" ]] && printf '%s\n' "\$*" >>"$TMP_DIR/git-calls.log"
case " \$* " in *" ls-remote "*) sleep "\${BENCH_NET_DELAY:-2}" ;; esac
exec "$REAL_GIT" "\$@"
SH
chmod +x "$SHIM/git"
# plain: real git directly (no shim process), for the commands that only read local repos
PLAIN="$TMP_DIR/plain"
mkdir -p "$PLAIN"
for f in "$ROOT"/tests/mocks/bin/*; do [[ "${f##*/}" == "git" ]] || ln -s "$f" "$PLAIN/${f##*/}"; done
ln -s "$REAL_GIT" "$PLAIN/git"
BASE_PATH="${PATH#"$ROOT/tests/mocks/bin:"}"
if [[ -n "${BENCH_COUNT_GIT:-}" ]]; then LOCAL_PATH="$SHIM:$BASE_PATH"; else LOCAL_PATH="$PLAIN:$BASE_PATH"; fi
export PATH="$LOCAL_PATH"

# timed LABEL COMMAND...: runs it, prints wall time and CPU time (user + system).
# On a busy machine the wall time says more about the machine than about the
# command; the CPU time and the process counts do not move with the load.
timed() {
  local label="$1" tm code=0
  shift
  TIMEFORMAT='%R %U %S'
  tm="$( { time "$@" >"$TMP_DIR/out.txt" 2>"$TMP_DIR/err.txt" || echo "$?" >"$TMP_DIR/code.txt"; } 2>&1 )"
  if [[ -s "$TMP_DIR/code.txt" ]]; then code="$(cat "$TMP_DIR/code.txt")"; : >"$TMP_DIR/code.txt"; fi
  printf '%-40s wall %7.2f s  cpu %6.2f s  (exit %s)\n' "$label" "$(awk '{print $1}' <<<"$tm")" "$(awk '{print $2 + $3}' <<<"$tm")" "$code"
}

# BENCH_COUNT_GIT=1 also counts the other programs the shell scripts start
if [[ -n "${BENCH_COUNT_GIT:-}" ]]; then
  for t in awk sed tr grep cat mktemp date sleep wc sort head tail cut basename dirname; do
    real="$(PATH="/usr/bin:/bin" command -v "$t" || true)"
    [[ -n "$real" ]] || continue
    # BENCH_EXEC_DETAIL=1 also logs the start of the arguments (which awk program, which tr set)
    cat >"$SHIM/$t" <<SH
#!/bin/bash
a="\$*"; a="\${a//\$'\\n'/ }"
printf '%s\\n' "$t \${BENCH_EXEC_DETAIL:+\${a:0:70}}" >>"$TMP_DIR/exec.log"
exec "$real" "\$@"
SH
    chmod +x "$SHIM/$t"
  done
fi

git config --global user.email me@example.com
BENCH="$HOME/bench36"
make_fake_bench "$BENCH" macdev
rmdir "$BENCH/apps/erpnext"
printf 'frappe\n' >"$BENCH/sites/apps.txt"
printf '{\n  "frappe": {\n    "resolution": {},\n    "version": "15.0.0"\n  }\n}\n' >"$BENCH/sites/apps.json"

i=0
prev=""
while [[ "$i" -lt "$N_APPS" ]]; do
  a="bapp_$i"
  make_app_remote "$a" ${prev:+"$prev"}
  add_policy "$a" main
  depth=(); [[ $((i % 2)) == 0 ]] && depth=(--depth 1)
  git clone -q --origin upstream ${depth[@]+"${depth[@]}"} --branch main "file://${REMOTES}/${a}.git" "$BENCH/apps/$a"
  printf '%s\n' "$a" >>"$BENCH/sites/apps.txt"
  prev=""; [[ $((i % 3)) == 0 ]] && prev="$a"
  i=$((i + 1))
done
# one dirty app, one on another branch, three with a commit of mine, five behind
printf 'x\n' >>"$BENCH/apps/bapp_1/pyproject.toml"
git -C "$BENCH/apps/bapp_2" checkout -q -b feature-x
for a in bapp_3 bapp_4 bapp_5; do
  (cd "$BENCH/apps/$a" && printf 'x\n' >mine.txt && git add mine.txt && git commit -q -m mine)
done
for a in bapp_6 bapp_7 bapp_8 bapp_9 bapp_10; do push_commits "$a" 3; git -C "$BENCH/apps/$a" fetch -q upstream; done

# the profile: PROFILE_APPS repos
mkdir -p "$HOME/.config/benchbar/profiles"
{
  printf 'schema = 1\nbase = "v15-lts"\ndescription = "benchmark"\nsite = "bench.localhost"\n'
  i=0
  while [[ "$i" -lt "$N_PROFILE" ]]; do
    make_app_remote "papp_$i"
    printf '\n[[apps]]\nname = "papp_%s"\nrepo = "file://%s/papp_%s.git"\nbranch = "main"\n' "$i" "$REMOTES" "$i"
    i=$((i + 1))
  done
} >"$HOME/.config/benchbar/profiles/bigprofile.toml"

printf 'bench with %s apps, profile with %s repos, fake ls-remote delay %s s\n\n' "$N_APPS" "$N_PROFILE" "${BENCH_NET_DELAY:-2}"
export FL_NOW
FL_NOW="$(date +%s)"
if [[ -n "${BENCH_COUNT_GIT:-}" ]]; then : >"$TMP_DIR/git-calls.log"; : >"$TMP_DIR/exec.log"; fi
timed "app list --json --no-sites" "$FM" app list --json --no-sites --bench-dir "$BENCH"
[[ -z "${BENCH_COUNT_GIT:-}" ]] || printf '  git processes: %s, others: %s\n' "$(wc -l <"$TMP_DIR/git-calls.log" | tr -d ' ')" "$(awk '{c[$1]++} END {for (k in c) printf "%s %s, ", k, c[k]}' "$TMP_DIR/exec.log")"
[[ -z "${BENCH_EXEC_DETAIL:-}" ]] || sort "$TMP_DIR/exec.log" | uniq -c | sort -rn | head -30
timed "app list --json (plain, with sites)" "$FM" app list --json --bench-dir "$BENCH"
timed "app list --no-sites (text)" "$FM" app list --no-sites --bench-dir "$BENCH"
timed "app focus --json" "$FM" app focus --json --bench-dir "$BENCH"
if [[ -n "${BENCH_COUNT_GIT:-}" ]]; then : >"$TMP_DIR/git-calls.log"; fi
PATH="$SHIM:$BASE_PATH" timed "profile check bigprofile --json" "$FM" profile check bigprofile --json --bench-dir "$BENCH"
[[ -z "${BENCH_COUNT_GIT:-}" ]] || printf '  git processes: %s\n' "$(wc -l <"$TMP_DIR/git-calls.log" | tr -d ' ')"
printf '  repos reported: %s\n' "$(printf '%s' "$(cat "$TMP_DIR/out.txt")" | grep -o '"reachable":true' | wc -l | tr -d ' ')"
if [[ -n "${BENCH_KEEP_OUT:-}" ]]; then cp "$TMP_DIR/out.txt" "$BENCH_KEEP_OUT"; fi
