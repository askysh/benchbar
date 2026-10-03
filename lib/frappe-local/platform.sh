#!/usr/bin/env bash

FL_BREW_PREFIX="${FL_BREW_PREFIX:-}"
FL_ARCH="${FL_ARCH:-}"
FL_MIN_DISK_GB="${FL_MIN_DISK_GB:-10}"
FL_CONNECTIVITY_URL="${FL_CONNECTIVITY_URL:-https://1.1.1.1}"

fl_platform_init() {
  [[ "$(uname -s)" == "Darwin" ]] || fl_die "Not running on macOS." "This installer targets macOS."
  fl_require_cmd brew "Install Homebrew from https://brew.sh"
  FL_BREW_PREFIX="$(brew --prefix)"
  FL_ARCH="$(uname -m)"
}

fl_preflight_not_root() {
  local effective_uid="${FL_EFFECTIVE_UID:-$EUID}"
  [[ "$effective_uid" != "0" ]] || fl_die "Do not run this installer as root." "Run it as your normal macOS user; the scripts will ask for sudo only where macOS requires it."
  fl_ok "Running as a regular user"
}

fl_preflight_disk_space() {
  local min_gb="${1:-$FL_MIN_DISK_GB}" path="${2:-$HOME}" available_gb
  if [[ -n "${FL_DISK_AVAILABLE_GB:-}" ]]; then
    available_gb="$FL_DISK_AVAILABLE_GB"
  else
    available_gb="$(df -Pk "$path" | awk 'NR == 2 { print int($4 / 1024 / 1024) }')"
  fi
  [[ -n "$available_gb" ]] || fl_die "Could not determine free disk space." "Check disk availability and re-run."
  if [[ "$available_gb" -lt "$min_gb" ]]; then
    fl_die "At least ${min_gb} GB free disk space is required; found ${available_gb} GB." "Free disk space and re-run."
  fi
  fl_ok "${available_gb} GB free disk space available"
}

fl_preflight_internet() {
  local offline="${1:-0}"
  if [[ "$offline" == "1" || "$FL_DRY_RUN" == "1" ]]; then
    fl_warn "Skipping internet connectivity check."
    return 0
  fi
  fl_require_cmd curl "Install curl or check your macOS base tools."
  curl -fsSL --max-time 5 "$FL_CONNECTIVITY_URL" >/dev/null \
    || fl_die "No internet connection detected." "Connect to the internet, or re-run supported commands with --offline where available."
  fl_ok "Internet connectivity available"
}

fl_preflight_basics() {
  local offline="${1:-0}" min_gb="${2:-$FL_MIN_DISK_GB}" path="${3:-$HOME}"
  fl_preflight_not_root
  fl_preflight_disk_space "$min_gb" "$path"
  fl_preflight_internet "$offline"
}

# bench init writes a crontab (python-crontab). On macOS 14 and later a
# process without Full Disk Access gets "Operation not permitted", and bench
# offers to delete the new bench. "crontab -l" shows the same denial.
fl_crontab_denied() {
  local out
  out="$(crontab -l 2>&1 </dev/null || true)"
  case "$out" in *"Operation not permitted"*|*"not permitted"*) return 0 ;; esac
  return 1
}

fl_brew_ensure() {
  local formula="$1"
  if brew list --formula --versions "$formula" >/dev/null 2>&1; then
    fl_info "$formula already installed ($(brew list --versions "$formula" | head -n1))"
  else
    fl_run_long "brew install ${formula}" brew install "$formula"
  fi
}

# fl_brew_formula_dates FORMULA: "deprecated disabled deprecation_date
# disable_date" from `brew info --json=v2` (local tap data, no network;
# "-" for an unknown or null value). Homebrew deprecates a formula a year
# before it disables it, and a disabled formula can no longer be installed:
# the profiles must move before that date, and doctor says how close it is.
# "missing - - -" when brew knows no such formula (removed from the tap,
# which Homebrew does about a year after disabling one).
fl_brew_formula_dates() {
  local json deprecated disabled dep_date dis_date
  json="$(HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 brew info --json=v2 --formula "$1" 2>/dev/null | tr -d '\n')" || true
  [[ -n "$json" ]] || { printf 'missing - - -'; return 0; }
  # BSD sed has no alternation in a BRE: match the word, not true|false
  deprecated="$(printf '%s' "$json" | sed -n 's/.*"deprecated":[[:space:]]*\([a-z]*\).*/\1/p')"
  disabled="$(printf '%s' "$json" | sed -n 's/.*"disabled":[[:space:]]*\([a-z]*\).*/\1/p')"
  dep_date="$(printf '%s' "$json" | sed -n 's/.*"deprecation_date":[[:space:]]*"\([0-9-]*\)".*/\1/p')"
  dis_date="$(printf '%s' "$json" | sed -n 's/.*"disable_date":[[:space:]]*"\([0-9-]*\)".*/\1/p')"
  printf '%s %s %s %s' "${deprecated:--}" "${disabled:--}" "${dep_date:--}" "${dis_date:--}"
}

# fl_date_epoch YYYY-MM-DD: seconds since the epoch at midnight UTC of that
# day (BSD date on macOS, GNU date elsewhere), nothing for a bad date.
fl_date_epoch() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 0
  TZ=UTC date -j -f '%Y-%m-%d %H:%M:%S' "$1 00:00:00" +%s 2>/dev/null || TZ=UTC date -d "$1 00:00:00" +%s 2>/dev/null || true
}

# fl_formula_disable_days_from DEPRECATED DISABLED DISABLE_DATE: how many
# days until Homebrew disables the formula (0 on the day itself, negative
# after; brew install fails from day 0), -1 for a formula that is disabled
# with no date or that brew no longer knows, nothing when no date is set.
FL_FORMULA_DISABLE_WARN_DAYS=90
fl_formula_disable_days_from() {
  local deprecated="$1" disabled="$2" dis_date="$3" at now
  if [[ "$deprecated" == "missing" ]] || [[ "$disabled" == "true" && "$dis_date" == "-" ]]; then printf -- '-1'; return 0; fi
  [[ "$dis_date" != "-" ]] || return 0
  at="$(fl_date_epoch "$dis_date")"
  [[ -n "$at" ]] || return 0
  # FL_NOW: the tests' clock (freshness.sh's fl_now reads it too)
  now="${FL_NOW:-$(date +%s)}"
  if [[ "$now" -ge "$at" ]]; then printf '%s' "$(( (now - at) / 86400 * -1 - 1 ))"; else printf '%s' "$(( (at - now) / 86400 ))"; fi
}

# fl_formula_disable_days FORMULA: the same, from one brew info call
fl_formula_disable_days() {
  local deprecated disabled dep_date dis_date
  read -r deprecated disabled dep_date dis_date <<<"$(fl_brew_formula_dates "$1")"
  fl_formula_disable_days_from "$deprecated" "$disabled" "$dis_date"
}

fl_brew_formula_available() {
  local formula="$1"
  brew list --formula --versions "$formula" >/dev/null 2>&1 || brew info "$formula" >/dev/null 2>&1
}

fl_process_running() {
  pgrep -qf "$1" 2>/dev/null
}

fl_brew_service_running() {
  local svc="$1"
  brew services list 2>/dev/null | awk -v s="$svc" '$1==s {print $2}' | grep -q '^started$'
}

fl_port_listening() {
  local port="$1"
  lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
}

fl_mariadb_safe_mode_note() {
  fl_warn "Existing MariaDB/MySQL may already be using port 3306."
  fl_info "Safe path: keep the existing database untouched, verify the root password, and let the bench script reuse it."
  fl_info "This installer does not delete MariaDB data or reset root auth automatically."
}

fl_ensure_service_started() {
  local formula="$1" proc_pattern="$2" tmpfile
  tmpfile="$(mktemp "${TMPDIR:-/tmp}/frappe-local-brew.XXXXXX")"
  if fl_process_running "$proc_pattern" || fl_brew_service_running "$formula"; then
    fl_ok "${formula} is running"
    rm -f "$tmpfile"
    return 0
  fi
  fl_warn "${formula} is not running; starting now"
  if ! brew services start "$formula" >"$tmpfile" 2>&1; then
    if ! grep -q -E 'already (loaded|bootstrapped)|exited with 5' "$tmpfile"; then
      cat "$tmpfile"
      rm -f "$tmpfile"
      fl_die "brew services start ${formula} failed."
    fi
  fi
  rm -f "$tmpfile"
  sleep 2
  fl_process_running "$proc_pattern" || fl_brew_service_running "$formula" || fl_die "${formula} did not come up."
  fl_ok "${formula} is running"
}

fl_parse_mariadb_version() {
  sed -n -e 's/.*[^0-9]\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)-MariaDB.*/\1/p' \
         -e 's/.*Distrib \([0-9][0-9.]*\).*/\1/p'
}

fl_formula_prefix() {
  local formula="$1"
  printf '%s/opt/%s\n' "$FL_BREW_PREFIX" "$formula"
}

fl_python_bin() {
  printf '%s/bin/%s\n' "$(fl_formula_prefix "$FL_PYTHON_FORMULA")" "$FL_PYTHON_BIN_NAME"
}

fl_node_bin() {
  printf '%s/bin/node\n' "$(fl_formula_prefix "$FL_NODE_FORMULA")"
}

fl_npm_bin() {
  printf '%s/bin/npm\n' "$(fl_formula_prefix "$FL_NODE_FORMULA")"
}

fl_mariadb_bin() {
  printf '%s/bin/mariadb\n' "$(fl_formula_prefix "$FL_MARIADB_FORMULA")"
}

# fl_profile_path_exports [PROFILE]: the shell block's exports, for the
# loaded profile or the one named (the block follows the default bench).
fl_profile_path_exports() {
  local py="$FL_PYTHON_FORMULA" node="$FL_NODE_FORMULA" db="$FL_MARIADB_FORMULA" row
  if [[ -n "${1:-}" && "${1:-}" != "$FL_PROFILE" ]]; then
    row="$(awk -F '\t' -v p="$1" 'NR > 1 && $1 == p {print $5 "|" $7 "|" $9}' "$(fl_config_file release-profiles.tsv)")"
    if [[ -n "$row" ]]; then
      IFS='|' read -r py node db <<<"$row"
    fi
  fi
  cat <<EOF
export PATH="${FL_BREW_PREFIX}/opt/${py}/bin:\$PATH"
export PATH="${FL_BREW_PREFIX}/opt/${node}/bin:\$PATH"
export PATH="${FL_BREW_PREFIX}/opt/${db}/bin:\$PATH"
export LDFLAGS="-L${FL_BREW_PREFIX}/opt/openssl@3/lib -L${FL_BREW_PREFIX}/opt/libffi/lib -L${FL_BREW_PREFIX}/opt/zlib/lib"
export CPPFLAGS="-I${FL_BREW_PREFIX}/opt/openssl@3/include -I${FL_BREW_PREFIX}/opt/libffi/include -I${FL_BREW_PREFIX}/opt/zlib/include"
export PKG_CONFIG_PATH="${FL_BREW_PREFIX}/opt/openssl@3/lib/pkgconfig:${FL_BREW_PREFIX}/opt/libffi/lib/pkgconfig:${FL_BREW_PREFIX}/opt/zlib/lib/pkgconfig:${FL_BREW_PREFIX}/opt/mariadb-connector-c/lib/pkgconfig"
EOF
}
