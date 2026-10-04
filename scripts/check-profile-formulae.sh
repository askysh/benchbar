#!/usr/bin/env bash
#
# check-profile-formulae.sh: refuse a release whose profiles name a Homebrew
# formula that is disabled or within 90 days of its disable date.
#
#   scripts/check-profile-formulae.sh            every profile in config/release-profiles.tsv
#   scripts/check-profile-formulae.sh --days 30  a shorter horizon
#
# Homebrew deprecates a formula a year before it disables it, and a disabled
# formula can no longer be installed: a profile that still names it breaks
# every fresh install from that day. The same dates feed doctor's "Formula
# lifecycle" check on a user's Mac; here they stop the release first. Reads
# the local tap (brew info --json=v2), no network.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT"
# shellcheck source=lib/frappe-local/ui.sh
. "${ROOT}/lib/frappe-local/ui.sh"
# shellcheck source=lib/frappe-local/platform.sh
. "${ROOT}/lib/frappe-local/platform.sh"
# shellcheck source=lib/frappe-local/version-policy.sh
. "${ROOT}/lib/frappe-local/version-policy.sh"

HORIZON="$FL_FORMULA_DISABLE_WARN_DAYS"
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --days) HORIZON="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[[ "$HORIZON" =~ ^[0-9]+$ ]] || { printf -- '--days takes a number of days\n' >&2; exit 2; }
command -v brew >/dev/null 2>&1 || { printf '[FAIL] brew is not installed; cannot read the formula dates\n' >&2; exit 1; }

file="$(fl_config_file release-profiles.tsv)"
bad=0; seen=" "
while IFS=$'\t' read -r profile _label _fb _eb py _pybin node _nmaj db _rest; do
  [[ -n "$profile" && "$profile" != "profile" ]] || continue
  for f in "$py" "$node" "$db"; do
    case "$seen" in *" $f "*) continue ;; esac
    seen="${seen}${f} "
    read -r deprecated disabled dep_date dis_date <<<"$(fl_brew_formula_dates "$f")"
    days="$(fl_formula_disable_days_from "$deprecated" "$disabled" "$dis_date")"
    if [[ "$deprecated" == "missing" ]]; then
      printf '[FAIL] %s (profile %s) is unknown to Homebrew (removed from the tap?)\n' "$f" "$profile"; bad=1
    elif [[ -n "$days" && "$days" -lt 0 ]]; then
      printf '[FAIL] %s (profile %s) is disabled by Homebrew (disable date %s)\n' "$f" "$profile" "$dis_date"; bad=1
    elif [[ -n "$days" && "$days" -le "$HORIZON" ]]; then
      printf '[FAIL] %s (profile %s) is disabled by Homebrew on %s, in %s days; move the profile first\n' "$f" "$profile" "$dis_date" "$days"; bad=1
    elif [[ "$deprecated" == "true" ]]; then
      printf '[WARN] %s (profile %s) is deprecated since %s, disabled on %s\n' "$f" "$profile" "$dep_date" "$dis_date"
    else
      printf '[OK] %s (profile %s)\n' "$f" "$profile"
    fi
  done
done <"$file"
[[ "$bad" == "0" ]] || { printf '\n[FAIL] a profile names a formula Homebrew is about to disable; fix config/release-profiles.tsv before releasing\n' >&2; exit 1; }
printf '\n[OK] every profile formula is more than %s days from a Homebrew disable date\n' "$HORIZON"
