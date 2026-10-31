#!/usr/bin/env bash
#
# affected.sh: run only the tests a change touches.
#
#   tests/affected.sh                 the change from origin/main to HEAD, plus uncommitted files
#   tests/affected.sh --base REF      the change from REF instead
#   tests/affected.sh --all           every test (tests/run-tests.sh with no names)
#   tests/affected.sh --list          print the chosen names, run nothing
#
# How a changed file picks tests:
#   tests/lib/, tests/mocks/, tests/run-tests.sh, benchbar, templates/, config/
#   and the phase scripts (00-*.sh, 01-*.sh, 02-*.sh)   the full suite
#   lib/frappe-local/X.sh   tests/test-X.sh when it exists, test-cli and
#                           test-agent-contracts, and every test that names
#                           a function whose definition the change touched
#   lib/frappe-local/mcp.py test-mcp, test-cli, test-agent-contracts
#   tests/test-X.sh         itself
#   install.sh              test-install-sh
#   packaging/              test-packaging, test-homebrew
#   any shell file          shellcheck
#   docs/, site/ and the rest (macos/, windows/, .github/, *.md)   nothing

set -euo pipefail

ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
cd "$ROOT"

base="origin/main" all=0 list=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --base) [[ -n "${2:-}" ]] || { printf 'affected: --base needs a ref\n' >&2; exit 1; }; base="$2"; shift 2 ;;
    --base=*) base="${1#*=}"; shift ;;
    --all) all=1; shift ;;
    --list) list=1; shift ;;
    -h|--help) sed -n '3,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'affected: unknown argument %s (see --help)\n' "$1" >&2; exit 1 ;;
  esac
done

if [[ "$all" == 1 ]]; then
  printf 'affected: --all, every test\n'
  [[ "$list" == 1 ]] && exit 0
  exec bash "$ROOT/tests/run-tests.sh"
fi

git rev-parse --verify --quiet "${base}^{commit}" >/dev/null \
  || { printf 'affected: no such ref %s (pass --base REF, or --all)\n' "$base" >&2; exit 1; }

# the changed files: committed since the merge base, staged, unstaged, untracked
files="$( {
  git diff --name-only "${base}...HEAD"
  git diff --name-only HEAD
  git ls-files --others --exclude-standard
} | sort -u)"

# picked NAME: add a test (or shellcheck) once, in order
picked=" "
pick() { case "$picked" in *" $1 "*) ;; *) picked="${picked}$1 " ;; esac; }

full=0 shell=0 lib=0 funcs=""
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  case "$f" in
    tests/lib/* | tests/mocks/* | tests/run-tests.sh | benchbar | templates/* | config/* | 0[0-2]-*.sh) full=1 ;;
    tests/affected.sh) pick test-affected; shell=1 ;;
    tests/test-*.sh) [[ -f "$f" ]] && pick "$(t="${f##*/}"; printf '%s' "${t%.sh}")"; shell=1 ;;
    lib/frappe-local/*.sh)
      lib=1 shell=1
      t="${f##*/}"; t="test-${t%.sh}"
      [[ -f "tests/${t}.sh" ]] && pick "$t" ;;
    lib/frappe-local/mcp.py) lib=1; pick test-mcp ;;
    install.sh) pick test-install-sh; shell=1 ;;
    packaging/*) pick test-packaging; pick test-homebrew ;;
    scripts/*.sh) shell=1 ;;
  esac
done <<<"$files"

if [[ "$full" == 1 ]]; then
  printf 'affected: a change to the harness, the entry point, templates or the phases: every test\n'
  [[ "$list" == 1 ]] && exit 0
  exec bash "$ROOT/tests/run-tests.sh"
fi

# functions whose definitions the change touched, in the changed shell files of
# lib/: a "name() {" line added or removed, or the function a hunk sits in
# (git names it in the hunk header)
if [[ "$lib" == 1 ]]; then
  shfiles="$(printf '%s\n' "$files" | grep -E '^lib/frappe-local/.*\.sh$' || true)"
  if [[ -n "$shfiles" ]]; then
    # shellcheck disable=SC2086  # one word per path, none has a space
    funcs="$( {
      git diff -U0 "${base}...HEAD" -- $shfiles
      git diff -U0 HEAD -- $shfiles
      for f in $shfiles; do git ls-files --error-unmatch "$f" >/dev/null 2>&1 || sed 's/^/+/' "$f" 2>/dev/null || true; done
    } | sed -n -E 's/^[-+]([A-Za-z_][A-Za-z0-9_]*)\(\) *\{.*/\1/p; s/^@@[^@]*@@ ([A-Za-z_][A-Za-z0-9_]*)\(\) *\{.*/\1/p' | sort -u)"
  fi
  for fn in $funcs; do
    for t in $(grep -l -w -- "$fn" tests/test-*.sh 2>/dev/null || true); do
      t="${t##*/}"; pick "${t%.sh}"
    done
  done
  pick test-cli
  pick test-agent-contracts
fi
[[ "$shell" == 1 ]] && pick shellcheck

# shellcheck disable=SC2086  # the picked names are words
set -- $picked
if [[ "$#" -eq 0 ]]; then
  printf 'affected: nothing to test for this change (docs, site, app or tray files only)\n'
  exit 0
fi
printf 'affected: %s\n' "$*"
[[ -z "$funcs" ]] || printf 'affected: functions touched: %s\n' "${funcs//$'\n'/ }"
[[ "$list" == 1 ]] && exit 0
exec bash "$ROOT/tests/run-tests.sh" "$@"
