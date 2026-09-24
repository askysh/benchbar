#!/usr/bin/env bash
#
# 00-mac-system-deps.sh
#
# Phase 0 for local Frappe/ERPNext development on macOS.
# Installs and verifies profile-driven system dependencies.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/frappe-local/ui.sh
. "${SCRIPT_DIR}/lib/frappe-local/ui.sh"
# shellcheck source=lib/frappe-local/run.sh
. "${SCRIPT_DIR}/lib/frappe-local/run.sh"
# shellcheck source=lib/frappe-local/platform.sh
. "${SCRIPT_DIR}/lib/frappe-local/platform.sh"
# shellcheck source=lib/frappe-local/version-policy.sh
. "${SCRIPT_DIR}/lib/frappe-local/version-policy.sh"
# shellcheck source=lib/frappe-local/state.sh
. "${SCRIPT_DIR}/lib/frappe-local/state.sh"
# shellcheck source=lib/frappe-local/templates.sh
. "${SCRIPT_DIR}/lib/frappe-local/templates.sh"
# shellcheck source=lib/frappe-local/shellrc.sh
. "${SCRIPT_DIR}/lib/frappe-local/shellrc.sh"
trap fl_on_error ERR

PROFILE="${PROFILE:-}"
LIST_PROFILES=0
CHECK_UPDATES=0
OFFLINE=0
DRY_RUN=0
PENDING_STEPS=()

usage() {
  cat <<EOF
Usage: ./00-mac-system-deps.sh [options]

Recommended:
  ./00-mac-system-deps.sh
  ./00-mac-system-deps.sh --profile v15-lts
  ./00-mac-system-deps.sh --list-profiles

Recovery:
  ./00-mac-system-deps.sh --dry-run

Exit codes:
  0  everything is installed and configured
  2  manual steps remain (they are printed at the end)

Options:
  --profile VALUE      Use release profile (default: v15-lts)
  --list-profiles      Print known profiles and exit
  --check-updates      Check remote Frappe/ERPNext version branches
  --offline            Skip network checks and use cached update info
  --dry-run            Print mutating commands without running them
  -h, --help           Show this help
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --list-profiles) LIST_PROFILES=1; shift ;;
    --check-updates) CHECK_UPDATES=1; shift ;;
    --offline) OFFLINE=1; shift ;;
    --dry-run) DRY_RUN=1; FL_DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fl_die "Unknown argument: $1" "Use --help for usage." ;;
  esac
done

if [[ "$LIST_PROFILES" == "1" ]]; then
  fl_list_profiles
  exit 0
fi

[[ -n "$PROFILE" ]] || PROFILE="$(fl_default_profile)"
fl_load_profile "$PROFILE"

fl_section "PROFILE"
fl_ok "Using ${FL_PROFILE_LABEL} (${FL_PROFILE})"
if [[ "$FL_PROFILE" == "v15-lts" ]]; then
  fl_info "Conservative default for a stable local Frappe/ERPNext setup."
  fl_info "Support window: through planned end of ${FL_SUPPORT_END}."
else
  fl_warn "${FL_PROFILE} is ${FL_PROFILE_STATUS}; use only for explicit migration work."
fi

if [[ "$CHECK_UPDATES" == "1" ]]; then
  fl_check_updates
fi

fl_platform_init

add_pending() { PENDING_STEPS+=("$1"); }

fl_section "SYSTEM"
fl_preflight_basics "$OFFLINE" "$FL_MIN_DISK_GB" "$HOME"
MACOS_VERSION="$(sw_vers | awk -F':[[:space:]]*' '$1 == "ProductVersion" { print $2 }')"
fl_ok "macOS detected (${MACOS_VERSION})"
if [[ "$FL_ARCH" != "arm64" ]]; then
  fl_warn "Architecture is ${FL_ARCH}; this script is tuned for Apple Silicon."
else
  fl_ok "Apple Silicon (${FL_ARCH})"
fi

if xcode-select -p >/dev/null 2>&1; then
  fl_ok "Xcode Command Line Tools at $(xcode-select -p)"
elif [[ "$FL_DRY_RUN" == "1" ]]; then
  fl_warn "Xcode CLT not found; dry-run would launch xcode-select --install."
else
  fl_warn "Xcode CLT not found; launching installer."
  xcode-select --install || true
  fl_die "Xcode CLT install was launched." "Complete the GUI installer, then re-run this script."
fi
fl_ok "Homebrew $(brew --version | head -n1 | awk '{print $2}') at ${FL_BREW_PREFIX}"

fl_section "PLAN"
cat <<EOF
  Profile: ${FL_PROFILE}, Frappe ${FL_FRAPPE_BRANCH}, ERPNext ${FL_ERPNEXT_BRANCH}
  Python:  ${FL_PYTHON_FORMULA} (${FL_PYTHON_BIN_NAME})
  Node:    ${FL_NODE_FORMULA}
  MariaDB: ${FL_MARIADB_FORMULA}
  Redis:   redis
EOF

for formula in "$FL_PYTHON_FORMULA" "$FL_NODE_FORMULA" "$FL_MARIADB_FORMULA"; do
  fl_brew_formula_available "$formula" || fl_die "Homebrew formula unavailable: ${formula}" "The selected profile may be newer than this script's Homebrew mapping. Run --profile v15-lts or update config/release-profiles.tsv after verifying Frappe docs."
done

if [[ "$FL_DRY_RUN" == "1" ]]; then
  fl_section "DRY RUN"
  fl_run brew install "$FL_PYTHON_FORMULA"
  fl_run brew install "$FL_NODE_FORMULA"
  fl_run brew install "$FL_MARIADB_FORMULA"
  fl_run brew install redis
  fl_run brew install openssl@3
  fl_run brew install libffi
  fl_run brew install zlib
  exit 0
fi

fl_section "PYTHON"
fl_brew_ensure "$FL_PYTHON_FORMULA"
PY_BIN="$(fl_python_bin)"
[[ -x "$PY_BIN" ]] || PY_BIN="$(command -v "$FL_PYTHON_BIN_NAME" || true)"
[[ -n "$PY_BIN" && -x "$PY_BIN" ]] || fl_die "${FL_PYTHON_BIN_NAME} not found after brew install." "Try: brew reinstall ${FL_PYTHON_FORMULA}"
PY_VERSION="$("$PY_BIN" --version 2>&1 | awk '{print $2}')"
case "$PY_VERSION" in
  ${FL_PYTHON_BIN_NAME#python}.*) fl_ok "${FL_PYTHON_BIN_NAME} - ${PY_VERSION} at ${PY_BIN}" ;;
  *) fl_die "Expected ${FL_PYTHON_BIN_NAME}, got ${PY_VERSION} at ${PY_BIN}." ;;
esac
"$PY_BIN" -m pip --version >/dev/null 2>&1 || fl_die "pip not available for ${FL_PYTHON_BIN_NAME}."
"$PY_BIN" -c 'import venv' >/dev/null 2>&1 || fl_die "venv module missing for ${FL_PYTHON_BIN_NAME}."
fl_ok "pip and venv available"

fl_section "NODE"
fl_brew_ensure "$FL_NODE_FORMULA"
NODE_BIN="$(fl_node_bin)"
NPM_BIN="$(fl_npm_bin)"
[[ -x "$NODE_BIN" ]] || fl_die "${FL_NODE_FORMULA} binary not found at ${NODE_BIN}." "Try: brew reinstall ${FL_NODE_FORMULA}"
NODE_VERSION="$("$NODE_BIN" --version)"
case "$NODE_VERSION" in
  v${FL_NODE_MAJOR}.*) fl_ok "node - ${NODE_VERSION} at ${NODE_BIN}" ;;
  *) fl_die "Expected Node v${FL_NODE_MAJOR}.x but got ${NODE_VERSION}." ;;
esac
NPM_VERSION="$("$NPM_BIN" --version)"
fl_ok "npm - ${NPM_VERSION} at ${NPM_BIN}"
if "$NPM_BIN" ls -g --depth=0 2>/dev/null | grep -q ' yarn@'; then
  fl_info "yarn already globally installed under ${FL_NODE_FORMULA}"
else
  fl_run "$NPM_BIN" install -g yarn
fi
YARN_BIN="$(fl_formula_prefix "$FL_NODE_FORMULA")/bin/yarn"
[[ -x "$YARN_BIN" ]] || YARN_BIN="$(command -v yarn || true)"
[[ -n "$YARN_BIN" && -x "$YARN_BIN" ]] || fl_die "yarn not found after install."
YARN_VERSION="$("$YARN_BIN" --version)"
fl_ok "yarn - ${YARN_VERSION} at ${YARN_BIN}"

fl_section "DATABASE"
fl_brew_ensure "$FL_MARIADB_FORMULA"
if fl_port_listening 3306; then
  fl_mariadb_safe_mode_note
fi
MARIADB_BIN="$(fl_mariadb_bin)"
[[ -x "$MARIADB_BIN" ]] || MARIADB_BIN="$(command -v mariadb || true)"
[[ -n "$MARIADB_BIN" && -x "$MARIADB_BIN" ]] || fl_die "mariadb client not found." "Try: brew reinstall ${FL_MARIADB_FORMULA}"
MARIADB_VERSION_LINE="$("$MARIADB_BIN" --version 2>&1 | head -n1)"
MARIADB_DISTRIB="$(printf '%s\n' "$MARIADB_VERSION_LINE" | fl_parse_mariadb_version | head -n1)"
[[ -n "$MARIADB_DISTRIB" ]] || fl_die "Could not parse MariaDB version from: ${MARIADB_VERSION_LINE}"
case "$MARIADB_DISTRIB" in
  ${FL_MARIADB_MAJOR_MINOR}.*) fl_ok "mariadb - ${MARIADB_DISTRIB} at ${MARIADB_BIN}" ;;
  *) fl_die "Expected MariaDB ${FL_MARIADB_MAJOR_MINOR}.x but got ${MARIADB_DISTRIB}." ;;
esac
fl_ensure_service_started "$FL_MARIADB_FORMULA" "mariadbd"

MARIADB_DATA_DIR="${FL_BREW_PREFIX}/var/mysql"
if [[ -f "${MARIADB_DATA_DIR}/mariadb_upgrade_info" ]]; then
  DATA_DIR_VER="$(tr -d '\0' < "${MARIADB_DATA_DIR}/mariadb_upgrade_info" | head -n1)"
  DATA_DIR_VER="${DATA_DIR_VER%%-*}"
  DATA_DIR_MAJOR_MINOR="$(printf '%s\n' "$DATA_DIR_VER" | awk -F. '{print $1 "." $2}')"
  if [[ "$DATA_DIR_MAJOR_MINOR" == "$FL_MARIADB_MAJOR_MINOR" ]]; then
    fl_ok "data dir version matches selected profile (${DATA_DIR_VER})"
  else
    fl_warn "data dir was initialized by ${DATA_DIR_VER} but profile expects ${FL_MARIADB_MAJOR_MINOR}."
    fl_warn "Move ${MARIADB_DATA_DIR} aside and re-init before using this profile."
  fi
fi

if "$MARIADB_BIN" -u root --connect-timeout=2 -e "SELECT 1" >/dev/null 2>&1; then
  fl_warn "MariaDB root@localhost has no password or uses socket auth."
  add_pending "MARIADB_PASSWORD"
else
  fl_ok "MariaDB root@localhost requires a password or is OS-restricted"
fi

UTF8_CNF_PATH="${FL_BREW_PREFIX}/etc/my.cnf.d/frappe.cnf"
MY_CNF_PATH="${FL_BREW_PREFIX}/etc/my.cnf"
if [[ -f "$UTF8_CNF_PATH" ]] && grep -q 'character-set-server.*utf8mb4' "$UTF8_CNF_PATH"; then
  fl_ok "frappe.cnf utf8mb4 config present at ${UTF8_CNF_PATH}"
else
  fl_warn "utf8mb4 config not found at ${UTF8_CNF_PATH}; writing it"
  if [[ -f "$MY_CNF_PATH" ]] && ! grep -q "^!includedir ${FL_BREW_PREFIX}/etc/my.cnf.d" "$MY_CNF_PATH"; then
    if [[ "$FL_DRY_RUN" == "1" ]]; then
      fl_info "dry-run: would append '!includedir ${FL_BREW_PREFIX}/etc/my.cnf.d' to ${MY_CNF_PATH}"
    else
      fl_backup_file "$MY_CNF_PATH"
      printf '\n!includedir %s/etc/my.cnf.d\n' "$FL_BREW_PREFIX" >>"$MY_CNF_PATH"
      fl_ok "added !includedir to ${MY_CNF_PATH}"
    fi
  elif [[ ! -f "$MY_CNF_PATH" && "$FL_DRY_RUN" != "1" ]]; then
    mkdir -p "$(dirname "$MY_CNF_PATH")"
    printf '[client-server]\n!includedir %s/etc/my.cnf.d\n' "$FL_BREW_PREFIX" >"$MY_CNF_PATH"
    fl_ok "created ${MY_CNF_PATH}"
  fi
  fl_template_apply "$UTF8_CNF_PATH" "$(fl_template_render mariadb-frappe.cnf)" 644
  if [[ "$FL_DRY_RUN" == "1" ]]; then
    fl_info "dry-run: brew services restart ${FL_MARIADB_FORMULA}"
  else
    fl_ok "wrote ${UTF8_CNF_PATH}"
    fl_run_long "brew services restart ${FL_MARIADB_FORMULA}" brew services restart "$FL_MARIADB_FORMULA" \
      || fl_warn "restart failed; run: brew services restart ${FL_MARIADB_FORMULA}"
  fi
fi

fl_section "REDIS"
fl_brew_ensure redis
REDIS_BIN="$(command -v redis-server || true)"
[[ -n "$REDIS_BIN" && -x "$REDIS_BIN" ]] || REDIS_BIN="${FL_BREW_PREFIX}/opt/redis/bin/redis-server"
[[ -x "$REDIS_BIN" ]] || fl_die "redis-server not found." "Try: brew reinstall redis"
REDIS_VERSION="$("$REDIS_BIN" --version | sed -n 's/.*v=\([0-9.]*\).*/\1/p')"
fl_ok "redis-server - ${REDIS_VERSION:-unknown} at ${REDIS_BIN}"
fl_ensure_service_started redis "redis-server"

fl_section "PDF"
WKHTML_BIN="$(command -v wkhtmltopdf || true)"
if [[ -z "$WKHTML_BIN" ]]; then
  fl_warn "wkhtmltopdf not installed."
  add_pending "WKHTMLTOPDF"
else
  WKHTML_RAW="$("$WKHTML_BIN" --version 2>&1 || true)"
  if printf '%s' "$WKHTML_RAW" | grep -qi 'with patched qt'; then
    fl_ok "wkhtmltopdf patched Qt build at ${WKHTML_BIN}"
  else
    fl_warn "wkhtmltopdf is not the patched-Qt build: $(printf '%s\n' "$WKHTML_RAW" | head -n1)"
    add_pending "WKHTMLTOPDF"
  fi
fi

fl_section "BUILD DEPS"
for formula in openssl@3 libffi zlib; do
  fl_brew_ensure "$formula"
  fl_ok "$formula - $(brew list --versions "$formula" | head -n1)"
done

fl_section "SHELL CONFIG"
ZSHRC="$(fl_rc_file)"
HELPER_BLOCK="$(fl_template_render shell-helpers "PROFILE_EXPORTS=$(fl_profile_path_exports)" "BENCHBAR=${SCRIPT_DIR}/benchbar")"
case "$(fl_rc_block_status "$ZSHRC" "$HELPER_BLOCK")" in
  current)
    fl_ok "${ZSHRC} has the benchbar block (profile exports and bench helpers)"
    ;;
  *)
    fl_warn "${ZSHRC} needs the benchbar block; writing it (profile exports and bench helpers)"
    fl_rc_block_write "$ZSHRC" "$HELPER_BLOCK"
    if [[ "$FL_DRY_RUN" != "1" ]]; then
      fl_ok "wrote the benchbar block to ${ZSHRC}"
      add_pending "SOURCE_RC"
    fi
    ;;
esac

fl_section "SUMMARY"
printf '%-22s %-22s %s\n' "DEP" "VERSION" "PATH"
printf '%-22s %-22s %s\n' "----" "-------" "----"
printf '%-22s %-22s %s\n' "profile" "$FL_PROFILE" "$FL_PROFILE_LABEL"
printf '%-22s %-22s %s\n' "$FL_PYTHON_BIN_NAME" "$PY_VERSION" "$PY_BIN"
printf '%-22s %-22s %s\n' "node" "$NODE_VERSION" "$NODE_BIN"
printf '%-22s %-22s %s\n' "$FL_MARIADB_FORMULA" "$MARIADB_DISTRIB" "$MARIADB_BIN"
printf '%-22s %-22s %s\n' "redis-server" "${REDIS_VERSION:-?}" "$REDIS_BIN"

if (( ${#PENDING_STEPS[@]} == 0 )); then
  fl_section "READY"
  printf '\n%sAll dependencies are configured.%s Next: ./01-install-bench-and-site.sh\n\n' "$FL_GREEN$FL_BOLD" "$FL_RESET"
  exit 0
fi

fl_section "PENDING MANUAL STEPS"
step_n=0
for step in "${PENDING_STEPS[@]}"; do
  step_n=$((step_n + 1))
  case "$step" in
    SOURCE_RC)
      cat <<EOF
${step_n}) Load the new shell block into this terminal (or open a new one):

   source ${ZSHRC}

EOF
      ;;
    MARIADB_PASSWORD)
      cat <<EOF
${step_n}) Set a MariaDB root password:

   mariadb-secure-installation

   If socket auth or an old data dir blocks login, back up and re-init:
     brew services stop ${FL_MARIADB_FORMULA}
     mv ${FL_BREW_PREFIX}/var/mysql ${FL_BREW_PREFIX}/var/mysql.bak.\$(date +%s)
     ${FL_BREW_PREFIX}/opt/${FL_MARIADB_FORMULA}/bin/mariadb-install-db \\
       --user=\$(whoami) --basedir=${FL_BREW_PREFIX}/opt/${FL_MARIADB_FORMULA} \\
       --datadir=${FL_BREW_PREFIX}/var/mysql --auth-root-authentication-method=normal
     brew services start ${FL_MARIADB_FORMULA}
     mariadb-secure-installation

EOF
      ;;
    WKHTMLTOPDF)
      cat <<EOF
${step_n}) Install patched-Qt wkhtmltopdf:

   Download from: https://github.com/wkhtmltopdf/packaging/releases
   Verify with: wkhtmltopdf --version
   Output must include: with patched qt

EOF
      ;;
  esac
done

printf '%sAfter completing the above, re-run this script to verify.%s\n\n' "$FL_YELLOW$FL_BOLD" "$FL_RESET"
# only "source the rc file" left: that is not a blocker for the next phase
only_source=1
for step in "${PENDING_STEPS[@]}"; do [[ "$step" == "SOURCE_RC" ]] || only_source=0; done
[[ "$only_source" == "1" ]] && exit 0
exit 2
