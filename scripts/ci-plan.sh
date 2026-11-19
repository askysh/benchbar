#!/usr/bin/env bash
#
# ci-plan.sh: decide what a CI run does. The "changes" job of
# .github/workflows/ci.yml runs it and appends its stdout to $GITHUB_OUTPUT.
#
# Inputs (environment):
#   EVENT          pull_request, push, schedule or workflow_dispatch
#   BASE_SHA       the commit to diff against: the pull request's base, or the
#                  push's "before" (empty or all zeros: unknown, so code changed)
#   LABELS         the pull request's labels, space separated (test-macos, test-linux)
#   INPUT_TESTS    workflow_dispatch: test names to run, space separated (empty: all)
#   INPUT_LEGS     workflow_dispatch: legs to run, space separated, any of
#                  linux bash32 macos shellcheck app shim real (empty: all, or
#                  only linux and bash32 when INPUT_TESTS is set)
#   FILES          the changed files, space separated (tests; default: git diff)
#   PLAN_SUMMARY   a file to append a readable table to (the job summary)
#
# Output, one key=value per line: for each of linux, bash32 and macos the
# tests (empty: the whole suite), skip (the tests that platform leaves out),
# n (the shard count) and shards (a JSON array for the matrix, [] when the leg
# does not run); shellcheck and shellcheck_files; app, shim, shim_win,
# shim_arm, wsl, real,
# full (every leg runs everything) and code (anything beyond docs changed).
#
# The rules (docs/DECISIONS.md, "CI tiering"):
#   pull request   the tests tests/affected.sh picks, on Linux and in the
#                  bash 3.2 container. macOS only when a path that needs macOS
#                  changed (macos_paths below), or the label test-macos is on.
#                  A selected test that every planned leg skips (the LAN share
#                  tests, picked through a shared lib file) turns macOS on; one
#                  no leg can run fails the plan.
#                  The harness, the mocks, run-tests.sh, affected.sh, the entry
#                  point, templates, config, the phases or the CI files
#                  themselves run everything everywhere.
#   push, schedule everything everywhere (push: unless only docs, site or *.md changed)
#   dispatch       what INPUT_TESTS and INPUT_LEGS say
# The shard count of a leg follows its weight in the tables of
# tests/run-tests.sh: one shard per TARGET table seconds, at most MAX.

set -euo pipefail

ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
cd "$ROOT"

EVENT="${EVENT:-pull_request}"
BASE_SHA="${BASE_SHA:-}"
LABELS="${LABELS:-}"
INPUT_TESTS="${INPUT_TESTS:-}"
INPUT_LEGS="${INPUT_LEGS:-}"

# the tests each platform leaves out: the Linux layer on macOS and in the container
# (the Linux shards run it on the bash Linux users have), the macOS only LAN
# share on Linux, and the Linux layer's WSL and sudo tests on macOS
SKIP_LINUX="test-share test-share-run test-share-admin test-share-preflight test-lan-guard"
SKIP_BASH32="test-install-linux test-doctor-linux test-systemd test-platform-linux test-share test-share-run test-share-admin test-share-preflight test-lan-guard"
SKIP_MACOS="test-install-linux test-doctor-linux test-systemd test-platform-linux test-wsl-preflight test-windows-commands test-sudo-env"
# table seconds one shard takes (about 150 s of wall time on its runner) and the most shards
TARGET_LINUX=600 MAX_LINUX=8
TARGET_BASH32=600 MAX_BASH32=8
TARGET_MACOS=900 MAX_MACOS=4

# the paths a pull request needs macOS for: BSD tools, launchd, the Keychain,
# pf and the installers. Everything else is the same bash on Linux.
macos_paths='^(lib/frappe-local/(platform|launchd|lan-guard|mariadb|sudo|wkhtmltopdf|share[a-z-]*)\.sh|lib/frappe-local/share/.*|00-mac-system-deps\.sh|install\.sh|packaging/.*|templates/(launchagent|share)\.plist\.tmpl|tests/test-(platform|lan-guard|share[a-z-]*|hygiene|service|templates|shellrc|install-sh|homebrew|packaging)\.sh)$'
app_paths='^(macos/.*|examples/.*|scripts/(macos-[a-z-]+|release-local|app-[a-z-]+|ci-annotate)\.sh|scripts/app-[a-z-]+\.py)$'
shim_paths='^(windows/shim/.*|lib/frappe-local/commands\.sh)$'
ci_paths='^(\.github/workflows/ci\.yml|scripts/ci-plan\.sh)$'
docs_paths='^(docs/.*|site/.*|.*\.md|LICENSE)$'

out() { printf '%s=%s\n' "$1" "$2"; }
has_word() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }
# keep only names that look like a test (file names in a pull request are not trusted)
clean_names() {
  local t r=""
  for t in $1; do
    [[ "$t" =~ ^[a-z0-9][a-z0-9-]*$ ]] && r="${r:+$r }$t"
  done
  printf '%s' "$r"
}

# ---- the changed files
files="${FILES:-}"
files_given=0
[[ -z "${FILES+x}" ]] || files_given=1
files_known=1
if [[ "$files_given" == 0 ]]; then
  files_known=0
  case "$BASE_SHA" in
    "" | 0000000000000000000000000000000000000000) ;;
    *) if git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
         files="$(git diff --name-only "$BASE_SHA" HEAD | tr '\n' ' ')"; files_known=1
       fi ;;
  esac
else
  files_known=1
fi

all_match() { # REGEX: every changed file matches
  local f
  for f in $files; do [[ "$f" =~ $1 ]] || return 1; done
  return 0
}
any_match() { # REGEX: some changed file matches
  local f
  for f in $files; do [[ "$f" =~ $1 ]] && return 0; done
  return 1
}

# code: anything beyond docs, site and markdown changed (unknown: yes)
code=true
if [[ "$files_known" == 1 && -n "${files// /}" ]] && all_match "$docs_paths"; then code=false; fi
if [[ "$files_known" == 1 && -z "${files// /}" && "$EVENT" != schedule && "$EVENT" != workflow_dispatch ]]; then code=false; fi

# ---- the scope
full=false mode=none tests="" shellcheck=false shellcheck_files=""
macos=false app=false shim=false real=false
run_linux=false run_bash32=false run_macos=false

case "$EVENT" in
  schedule)
    full=true; run_linux=true; run_bash32=true; run_macos=true; shellcheck=true; app=true; shim=true; real=true ;;
  push)
    if [[ "$code" == true ]]; then
      full=true; run_linux=true; run_bash32=true; run_macos=true; shellcheck=true; app=true; shim=true; real=true
    fi ;;
  workflow_dispatch)
    legs="$INPUT_LEGS"
    if [[ -z "$legs" ]]; then
      if [[ -n "$INPUT_TESTS" ]]; then legs="linux bash32"; else legs="linux bash32 macos shellcheck app shim real"; fi
    fi
    tests="$(clean_names "$INPUT_TESTS")"
    [[ -n "$tests" || -z "$INPUT_TESTS" ]] || { printf 'ci-plan: INPUT_TESTS has no valid test name\n' >&2; exit 1; }
    [[ -n "$tests" ]] || full=true
    if [[ -n "$tests" ]]; then mode=affected; else mode=full; fi
    has_word "$legs" linux && run_linux=true
    has_word "$legs" bash32 && run_bash32=true
    has_word "$legs" macos && run_macos=true
    has_word "$legs" shellcheck && shellcheck=true
    has_word "$legs" app && app=true
    has_word "$legs" shim && shim=true
    has_word "$legs" real && real=true ;;
  *)
    # pull request (and anything unknown): what the change reaches
    ci_changed=false
    if [[ "$files_known" == 1 ]]; then
      any_match "$ci_paths" && ci_changed=true
      if [[ "$ci_changed" == true ]]; then
        mode=full
      elif [[ "$files_given" == 1 ]]; then
        affected="$(bash tests/affected.sh --machine --files "$files")"
        mode="$(printf '%s\n' "$affected" | sed -n 's/^mode=//p')"
      else
        affected="$(bash tests/affected.sh --machine --base "$BASE_SHA")"
        mode="$(printf '%s\n' "$affected" | sed -n 's/^mode=//p')"
      fi
      if [[ "$ci_changed" != true ]]; then
        tests="$(clean_names "$(printf '%s\n' "$affected" | sed -n 's/^tests=//p')")"
        shellcheck="$(printf '%s\n' "$affected" | sed -n 's/^shellcheck=//p')"
        shellcheck_files="$(printf '%s\n' "$affected" | sed -n 's/^shellcheck_files=//p')"
      fi
    else
      mode=full   # no base to diff against: be safe
    fi
    if [[ "$mode" == full ]]; then
      full=true; run_linux=true; run_bash32=true; run_macos=true; shellcheck=true; shellcheck_files=""; tests=""
      # the app and the shim have their own paths; only the CI files themselves run them all
      if [[ "$ci_changed" == true ]]; then app=true; shim=true; fi
      any_match "$app_paths" && app=true
      any_match "$shim_paths" && shim=true
    else
      [[ -n "$tests" ]] && { run_linux=true; run_bash32=true; }
      if [[ -n "$tests" ]] && { any_match "$macos_paths" || has_word "$LABELS" test-macos; }; then run_macos=true; fi
      any_match "$app_paths" && app=true
      any_match "$shim_paths" && shim=true
    fi
    ;;
esac
has_word "$LABELS" test-linux && [[ "$EVENT" == pull_request && "$code" == true ]] && real=true

# ---- every selected test runs on at least one leg
# A test one platform leaves out (the LAN share is macOS only) can be picked through a
# shared lib file that macos_paths does not match. When every leg of the plan skips it,
# the macOS leg is turned on for it. A test no leg can run, or a dispatch that names the
# legs and leaves it out, fails the plan: a green run must never mean "not run".
leg_runs() { # TEST: a leg that runs, and does not skip it
  [[ "$run_linux" == true ]] && ! has_word "$SKIP_LINUX" "$1" && return 0
  [[ "$run_bash32" == true ]] && ! has_word "$SKIP_BASH32" "$1" && return 0
  [[ "$run_macos" == true ]] && ! has_word "$SKIP_MACOS" "$1" && return 0
  return 1
}
macos_for=""
for t in $tests; do
  if leg_runs "$t"; then continue; fi
  if ! has_word "$SKIP_MACOS" "$t" && [[ "$EVENT" != workflow_dispatch || -z "$INPUT_LEGS" ]]; then
    run_macos=true; macos_for="${macos_for:+$macos_for }$t"; continue
  fi
  printf 'ci-plan: %s would run on no leg (every leg of the plan leaves it out)\n' "$t" >&2
  exit 1
done

# ---- shards
# weight LEG: the table seconds of the leg's tests
weight() { # PLATFORM SKIP
  TEST_PLATFORM="$1" SKIP_TESTS="$2" ONLY_TESTS="$tests" SECS_ONLY=1 SHELLCHECK=0 bash tests/run-tests.sh
}
# shard_plan RUN PLATFORM SKIP TARGET MAX: prints "N JSON"
shard_plan() {
  local run="$1" platform="$2" skip="$3" target="$4" max="$5" w n k json
  if [[ "$run" != true ]]; then printf '0 []'; return 0; fi
  w="$(weight "$platform" "$skip")"
  if [[ "$w" -eq 0 ]]; then printf '0 []'; return 0; fi
  n=$(((w + target - 1) / target)); [[ "$n" -ge 1 ]] || n=1; [[ "$n" -le "$max" ]] || n="$max"
  json="["; k=1
  while [[ "$k" -le "$n" ]]; do json="${json}${k}"; [[ "$k" -lt "$n" ]] && json="${json},"; k=$((k + 1)); done
  printf '%s %s]' "$n" "$json"
}
# a full leg without a test list keeps the whole table; weight() above sees ONLY_TESTS empty then
read -r n_linux j_linux <<<"$(shard_plan "$run_linux" linux "$SKIP_LINUX" "$TARGET_LINUX" "$MAX_LINUX")"
read -r n_bash32 j_bash32 <<<"$(shard_plan "$run_bash32" linux "$SKIP_BASH32" "$TARGET_BASH32" "$MAX_BASH32")"
read -r n_macos j_macos <<<"$(shard_plan "$run_macos" mac "$SKIP_MACOS" "$TARGET_MACOS" "$MAX_MACOS")"
[[ -n "$n_linux" && -n "$n_bash32" && -n "$n_macos" ]] || { printf 'ci-plan: could not size the shards\n' >&2; exit 1; }

# wsl, shim_win, shim_arm: the hosted Windows jobs (the real distro, go test on
# windows-latest, go test on the Arm runner) run whenever the shim job does
wsl="$shim"
shim_win="$shim"
shim_arm="$shim"

out code "$code"
out full "$full"
out tests "$tests"
out linux_skip "$SKIP_LINUX"
out linux_n "$n_linux"
out linux_shards "$j_linux"
out bash32_skip "$SKIP_BASH32"
out bash32_n "$n_bash32"
out bash32_shards "$j_bash32"
out macos_skip "$SKIP_MACOS"
out macos_n "$n_macos"
out macos_shards "$j_macos"
out shellcheck "$shellcheck"
out shellcheck_files "$shellcheck_files"
out app "$app"
out shim "$shim"
out shim_win "$shim_win"
out shim_arm "$shim_arm"
out wsl "$wsl"
out real "$real"

if [[ -n "${PLAN_SUMMARY:-}" ]]; then
  # shellcheck disable=SC2016  # the backticks are markdown
  {
    printf '### CI plan\n\n'
    printf 'Event `%s`, mode `%s`, %s changed file(s).\n\n' "$EVENT" "$mode" "$(printf '%s\n' "$files" | tr ' ' '\n' | grep -c . || true)"
    printf '| Leg | Runs | Shards |\n|---|---|---|\n'
    printf '| Linux (bash 5) | %s | %s |\n' "$run_linux" "$n_linux"
    printf '| bash 3.2 container | %s | %s |\n' "$run_bash32" "$n_bash32"
    printf '| macOS | %s | %s |\n' "$run_macos" "$n_macos"
    printf '| shellcheck | %s | |\n| app (macOS) | %s | |\n| Windows shim | %s | |\n| real install | %s | |\n\n' "$shellcheck" "$app" "$shim" "$real"
    [[ -z "$macos_for" ]] || printf 'macOS is on because only it runs: `%s`.\n\n' "$macos_for"
    if [[ -n "$tests" ]]; then printf 'Tests: `%s`\n' "$tests"; elif [[ "$full" == true ]]; then printf 'Tests: the whole suite.\n'; else printf 'Tests: none.\n'; fi
  } >>"$PLAN_SUMMARY"
fi
