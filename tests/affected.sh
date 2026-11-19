#!/usr/bin/env bash
#
# affected.sh: run only the tests a change touches.
#
#   tests/affected.sh                 the change from origin/main to HEAD, plus uncommitted files
#   tests/affected.sh --base REF      the change from REF instead
#   tests/affected.sh --all           every test (tests/run-tests.sh with no names)
#   tests/affected.sh --list          print the chosen names, run nothing
#   tests/affected.sh --machine       print mode=, tests=, shellcheck=, shellcheck_files= lines (CI)
#   tests/affected.sh --lib-coverage  list lib files with no test and no family (test-affected runs it)
#   tests/affected.sh --files "A B"   take the changed files from the argument, not from git
#                                     (a function level diff is not available then: every function
#                                     of a changed lib file counts as touched)
#
# How a changed file picks tests:
#   tests/lib/, tests/mocks/, tests/run-tests.sh, tests/affected.sh, benchbar,
#   frappe-mac, templates/, config/ and the phase scripts (00-*.sh, 01-*.sh,
#   02-*.sh)   the full suite
#   lib/frappe-local/X.sh   tests/test-X.sh when it exists, test-cli and
#                           test-agent-contracts, the tests of its family (lib_family
#                           below: doctor and checks pick the doctor and repair tests, and
#                           so on), and every test that names a function whose
#                           definition the change touched
#   lib/frappe-local/share/*  the LAN share tests
#   lib/frappe-local/mcp.py test-mcp, test-cli, test-agent-contracts
#   A test split into parts (test-X.sh, test-X-2.sh, ...) is picked whole.
#   tests/test-X.sh         itself
#   install.sh              test-install-sh
#   packaging/              test-packaging, test-homebrew
#   macos/BenchBarTests/Fixtures/   the tests that compare CLI output with them
#   windows/tray/fixtures/  test-tray-fixtures (the tray's recorded CLI output)
#   scripts/X.sh            the tests that run it (script_tests below)
#   changelog.d/            test-changelog (it checks the fragments)
#   docs/                   test-docs, test-docs-command
#   any shell file          shellcheck
#   tests/share/            test-share-gateway
#   macos/, windows/, examples/, site/, .github/, .claude/, install.ps1,
#   scripts/app-*.py and *.md   nothing here: the app, tray, shim and Windows installer
#                           jobs, the workflows themselves and the docs site cover them
#   any other file          the full suite (a file nothing maps to is not assumed safe)

set -euo pipefail

ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
cd "$ROOT"

base="origin/main" all=0 list=0 machine=0 files_arg="" have_files=0 lib_coverage=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --base) [[ -n "${2:-}" ]] || { printf 'affected: --base needs a ref\n' >&2; exit 1; }; base="$2"; shift 2 ;;
    --base=*) base="${1#*=}"; shift ;;
    --all) all=1; shift ;;
    --list) list=1; shift ;;
    --lib-coverage) lib_coverage=1; shift ;;
    --machine) machine=1; list=1; shift ;;
    --files) [[ "$#" -ge 2 ]] || { printf 'affected: --files needs a list\n' >&2; exit 1; }; files_arg="$2"; have_files=1; shift 2 ;;
    -h|--help) sed -n '3,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'affected: unknown argument %s (see --help)\n' "$1" >&2; exit 1 ;;
  esac
done

# The family of a lib file: the tests, beyond test-BASE and the touched
# function match, that run the code of lib/frappe-local/BASE.sh. They run the
# command that reaches the file (doctor, repair, install, adopt) and never
# name its functions, so the function match alone misses them. A file with a
# test of its own name needs no entry; every other file needs one
# (tests/test-affected.sh checks that, with --lib-coverage). LIB_CORE is the
# set of end to end tests for code every command runs.
LIB_CORE="test-doctor test-install-json test-phases test-repair test-service test-ports test-adopt test-json test-run-lock test-status-cost test-tray-fixtures"
lib_family() {
  case "$1" in
    checks|doctor) echo "test-doctor test-doctor-hardening test-doctor-linux test-repair test-repair-json test-json" ;;
    doctor-linux|preflight-linux) echo "test-doctor-linux test-doctor test-repair test-wsl-preflight test-install-linux test-prerequisites-linux" ;;
    repair) echo "test-repair test-repair-json test-doctor test-doctor-hardening test-install-json" ;;
    docs) echo "test-docs test-docs-command" ;;
    commands) echo "test-docs test-docs-command test-labs test-json" ;;
    apps|app-plan) echo "test-apps test-app-cli test-app-batch test-app-recovery test-pull" ;;
    bench|benchinfo|benchstate|discovery|freshness) echo "test-bench-flow test-status-cost test-discovery test-multi-bench test-adopt test-json test-freshness test-ports test-port-management test-install-json" ;;
    sites|site-backups|site-restore|pull) echo "test-sites test-site-backups test-site-restore test-pull test-install-json" ;;
    ports|port-management) echo "test-ports test-port-management test-multi-bench test-adopt" ;;
    service|launchd|systemd|templates|shellrc|mariadb|wkhtmltopdf|platform|platform-linux) echo "test-platform test-platform-linux test-systemd test-service test-templates test-shellrc test-wsl-preflight test-install-linux test-install-json test-phases test-sudo-env test-windows-commands test-hygiene test-homebrew" ;;
    sudo|sudo-env) echo "test-sudo-env test-platform-linux test-install-json test-hygiene test-port-management" ;;
    ui|state|run|lock|process|install-kind|toml) echo "$LIB_CORE test-ui test-redact test-input-hygiene test-state-migrate test-process test-runner" ;;
    profiles|teamlock|version-policy) echo "test-profiles test-profile-v16 test-version-policy test-doctor-linux test-self-update" ;;
    labs) echo "test-labs test-labs-share" ;;
    open-as) echo "test-open-as" ;;
    consoles) echo "test-cli" ;;
    report) echo "test-report test-redact" ;;
    selfupdate) echo "test-self-update test-install-sh" ;;
    share|share-admin|share-preflight|share-run|share-site|lan-guard) echo "test-share test-share-admin test-share-preflight test-share-run test-share-gateway test-lan-guard test-labs-share" ;;
    *) return 1 ;;
  esac
}

# script_tests NAME: the tests that run scripts/NAME.sh
script_tests() {
  case "$1" in
    release-notes) echo "test-release-notes" ;;
    changelog-fold) echo "test-changelog test-release-notes" ;;
    app-embed-cli|cli-tarball|homebrew-render) echo "test-packaging test-homebrew" ;;
    check-profile-formulae) echo "test-doctor-hardening test-homebrew" ;;
    ci-plan|ci-timings) echo "test-ci-plan" ;;
  esac
}

# --lib-coverage: every lib file has a test of its own name or a family
if [[ "$lib_coverage" == 1 ]]; then
  rc=0
  for f in lib/frappe-local/*.sh; do
    b="${f##*/}"; b="${b%.sh}"
    if [[ -f "tests/test-$b.sh" ]] || lib_family "$b" >/dev/null; then continue; fi
    printf 'lib/frappe-local/%s.sh: no test-%s.sh and no lib_family entry in tests/affected.sh\n' "$b" "$b"
    rc=1
  done
  exit "$rc"
fi

if [[ "$all" == 1 ]]; then
  if [[ "$machine" == 1 ]]; then
    printf 'mode=full\ntests=\nshellcheck=true\nshellcheck_files=\n'; exit 0
  fi
  printf 'affected: --all, every test\n'
  [[ "$list" == 1 ]] && exit 0
  exec bash "$ROOT/tests/run-tests.sh"
fi

if [[ "$have_files" == 1 ]]; then
  files="$(printf '%s\n' "$files_arg" | tr ' ' '\n' | grep -v '^$' | sort -u || true)"
else
  git rev-parse --verify --quiet "${base}^{commit}" >/dev/null \
    || { printf 'affected: no such ref %s (pass --base REF, or --all)\n' "$base" >&2; exit 1; }
  # the changed files: committed since the merge base, staged, unstaged, untracked
  files="$( {
    git diff --name-only "${base}...HEAD"
    git diff --name-only HEAD
    git ls-files --others --exclude-standard
  } | sort -u)"
fi

# picked NAME: add a test (or shellcheck) once, in order
picked=" "
pick() { case "$picked" in *" $1 "*) ;; *) picked="${picked}$1 " ;; esac; }
# pick_parts NAME: NAME when it exists, then its parts NAME-2, NAME-3, ...
pick_parts() {
  local f
  for f in "tests/$1.sh" "tests/$1"-[0-9]*.sh; do
    [[ -f "$f" ]] && pick "$(t="${f##*/}"; printf '%s' "${t%.sh}")"
  done
  return 0
}
# pick_family WORDS: each name and its parts, for the names that exist
pick_family() {
  local t
  for t in $1; do pick_parts "$t"; done
}

full=0 shell=0 lib=0 funcs="" shfiles_all=""
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  case "$f" in
    tests/lib/* | tests/mocks/* | tests/run-tests.sh | tests/affected.sh | benchbar | frappe-mac | templates/* | config/* | 0[0-2]-*.sh) full=1 ;;
    tests/share/*) pick test-share-gateway ;;
    tests/test-*.sh) [[ -f "$f" ]] && pick "$(t="${f##*/}"; printf '%s' "${t%.sh}")"; shell=1 ;;
    lib/frappe-local/share/*) lib=1; pick_family "$(lib_family share)" ;;
    lib/frappe-local/*.sh)
      lib=1 shell=1
      t="${f##*/}"; t="${t%.sh}"
      pick_parts "test-$t"
      fam="$(lib_family "$t" || true)"
      [[ -n "$fam" ]] || fam="$LIB_CORE"
      pick_family "$fam" ;;
    lib/frappe-local/mcp.py) lib=1; pick_parts test-mcp ;;
    install.sh) pick test-install-sh; shell=1 ;;
    packaging/*) pick test-packaging; pick test-homebrew ;;
    macos/BenchBarTests/Fixtures/*) pick_family "test-json test-install-json test-lock" ;;
    windows/tray/fixtures/* | tests/record-tray-fixtures.sh) pick test-tray-fixtures; shell=1 ;;
    scripts/*.sh)
      shell=1
      t="${f##*/}"; pick_family "$(script_tests "${t%.sh}")" ;;
    changelog.d/*) pick test-changelog ;;
    docs/*) pick_family "test-docs test-docs-command" ;;
    # no CLI test, by design: another job runs it (the app and the tray and shim jobs, the
    # Windows installer test of release-windows.yml for install.ps1, the workflow itself
    # for .github/, docs.yml for site/), or it is prose or agent tooling
    macos/* | windows/* | site/* | examples/* | .github/* | .claude/* | install.ps1 | scripts/app-*.py | *.md | LICENSE) ;;
    # a file nothing above knows: no test is known to cover it, so run them all
    *) full=1 ;;
  esac
  case "$f" in
    *.sh | benchbar | frappe-mac) [[ -f "$f" ]] && shfiles_all="$shfiles_all $f" ;;
  esac
done <<<"$files"

if [[ "$full" == 1 ]]; then
  if [[ "$machine" == 1 ]]; then
    printf 'mode=full\ntests=\nshellcheck=true\nshellcheck_files=\n'; exit 0
  fi
  printf 'affected: a change to the harness, the selector, the entry point, templates, config, the phases or a file no test is known to cover: every test\n'
  [[ "$list" == 1 ]] && exit 0
  exec bash "$ROOT/tests/run-tests.sh"
fi

# functions whose definitions the change touched, in the changed shell files of
# lib/: a "name() {" line added or removed, or the function a hunk sits in
# (git names it in the hunk header). Without git (--files) every function of
# a changed lib file counts.
if [[ "$lib" == 1 ]]; then
  shfiles="$(printf '%s\n' "$files" | grep -E '^lib/frappe-local/[^/]*\.sh$' || true)"
  if [[ -n "$shfiles" && "$have_files" == 1 ]]; then
    # shellcheck disable=SC2086  # one word per path, none has a space
    funcs="$(sed -n -E 's/^([A-Za-z_][A-Za-z0-9_]*)\(\) *\{.*/\1/p' $shfiles 2>/dev/null | sort -u)"
  elif [[ -n "$shfiles" ]]; then
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
  pick_parts test-agent-contracts
fi
[[ "$shell" == 1 ]] && pick shellcheck

# shellcheck disable=SC2086  # the picked names are words
set -- $picked

if [[ "$machine" == 1 ]]; then
  names="" sc=false
  for t in "$@"; do
    if [[ "$t" == shellcheck ]]; then sc=true; else names="${names:+$names }$t"; fi
  done
  if [[ -z "$names" && "$sc" == false ]]; then mode=none; else mode=affected; fi
  printf 'mode=%s\ntests=%s\nshellcheck=%s\nshellcheck_files=%s\n' "$mode" "$names" "$sc" "${shfiles_all# }"
  exit 0
fi

if [[ "$#" -eq 0 ]]; then
  printf 'affected: nothing to test for this change (site, app or tray files only)\n'
  exit 0
fi
printf 'affected: %s\n' "$*"
[[ -z "$funcs" ]] || printf 'affected: functions touched: %s\n' "${funcs//$'\n'/ }"
[[ "$list" == 1 ]] && exit 0
exec bash "$ROOT/tests/run-tests.sh" "$@"
