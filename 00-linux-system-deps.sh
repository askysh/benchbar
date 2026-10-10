#!/usr/bin/env bash
#
# 00-linux-system-deps.sh
#
# Phase 0 for local Frappe/ERPNext development on Linux (Ubuntu, Debian,
# WSL). The same sections, flags and exit codes as 00-mac-system-deps.sh:
# MariaDB, Redis and the build libraries come from apt, Python from uv,
# Node from fnm, wkhtmltopdf from the pinned official package.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/frappe-local/install-kind.sh
. "${SCRIPT_DIR}/lib/frappe-local/install-kind.sh"
# shellcheck source=lib/frappe-local/ui.sh
. "${SCRIPT_DIR}/lib/frappe-local/ui.sh"
# shellcheck source=lib/frappe-local/run.sh
. "${SCRIPT_DIR}/lib/frappe-local/run.sh"
# shellcheck source=lib/frappe-local/platform.sh
. "${SCRIPT_DIR}/lib/frappe-local/platform.sh"
# shellcheck source=lib/frappe-local/version-policy.sh
. "${SCRIPT_DIR}/lib/frappe-local/version-policy.sh"
# shellcheck source=lib/frappe-local/toml.sh
. "${SCRIPT_DIR}/lib/frappe-local/toml.sh"
# shellcheck source=lib/frappe-local/profiles.sh
. "${SCRIPT_DIR}/lib/frappe-local/profiles.sh"
# shellcheck source=lib/frappe-local/state.sh
. "${SCRIPT_DIR}/lib/frappe-local/state.sh"
# shellcheck source=lib/frappe-local/templates.sh
. "${SCRIPT_DIR}/lib/frappe-local/templates.sh"
# shellcheck source=lib/frappe-local/shellrc.sh
. "${SCRIPT_DIR}/lib/frappe-local/shellrc.sh"
# shellcheck source=lib/frappe-local/sudo.sh
. "${SCRIPT_DIR}/lib/frappe-local/sudo.sh"
# shellcheck source=lib/frappe-local/mariadb.sh
. "${SCRIPT_DIR}/lib/frappe-local/mariadb.sh"
# shellcheck source=lib/frappe-local/wkhtmltopdf.sh
. "${SCRIPT_DIR}/lib/frappe-local/wkhtmltopdf.sh"
fl_platform_load
fl_is_linux || fl_die "This script is for Linux." "On a Mac run ./00-mac-system-deps.sh"
trap fl_on_error ERR
fl_signal_traps_install
# the last section of a --json install ends with the script
trap 'fl_jsonl_section_exit "$?"; fl_sudo_end' EXIT

PROFILE="${PROFILE:-}"
LIST_PROFILES=0
CHECK_UPDATES=0
# --offline, OFFLINE=1 or BENCHBAR_OFFLINE=1: no remote checks
OFFLINE="${OFFLINE:-0}"; [[ "${BENCHBAR_OFFLINE:-0}" == "1" ]] && OFFLINE=1
DRY_RUN=0
PENDING_STEPS=()
# --yes is a flag, never a value left in the environment
FL_ASSUME_YES=0

UV_INSTALLER_URL="${UV_INSTALLER_URL:-https://astral.sh/uv/install.sh}"
FNM_INSTALLER_URL="${FNM_INSTALLER_URL:-https://fnm.vercel.app/install}"

usage() {
  cat <<EOF
Usage: ./00-linux-system-deps.sh [options]

Recommended:
  ./00-linux-system-deps.sh
  ./00-linux-system-deps.sh --profile v15-lts
  ./00-linux-system-deps.sh --list-profiles

Recovery:
  ./00-linux-system-deps.sh --dry-run

Exit codes:
  0  everything is installed and configured
  2  manual steps remain (they are printed at the end)

Environment:
  MARIADB_ROOT_PASSWORD   Password to set (fresh MariaDB) or to verify (existing one).
                          Otherwise a strong one is generated. It is kept in a 0600 file
                          in the state folder (benchbar mariadb-password prints it).

Options:
  -y, --yes            Do not ask; confirmations are accepted (sudo still asks for its password)
  --profile VALUE      Use release profile (default: v15-lts; the only one on Linux so far)
  --list-profiles      Print known profiles and exit
  --check-updates      Check remote Frappe/ERPNext version branches
  --offline            Skip network checks and use cached update info
  --dry-run            Print mutating commands without running them
  -h, --help           Show this help
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -y|--yes) FL_ASSUME_YES=1; shift ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --list-profiles) LIST_PROFILES=1; shift ;;
    --check-updates) CHECK_UPDATES=1; shift ;;
    --offline) OFFLINE=1; shift ;;
    --dry-run) DRY_RUN=1; FL_DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fl_die "Unknown argument: $1" "Use --help for usage." ;;
  esac
done
export FL_DRY_RUN
# the root password is read here (fl_mariadb_root_setup) and must not reach
# the uv and fnm installers, npm or apt
export -n MARIADB_ROOT_PASSWORD ADMIN_PASSWORD

if [[ "$LIST_PROFILES" == "1" ]]; then
  fl_list_profiles
  exit 0
fi

[[ -n "$PROFILE" ]] || PROFILE="$(fl_default_profile)"
fl_load_profile "$PROFILE"

fl_section "PROFILE"
fl_linux_profile_require
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

# fl_install_script LABEL URL INTERPRETER [ARGS...]: downloads an installer
# script to a temporary file and runs it, instead of piping curl into a shell
fl_install_script() {
  local label="$1" url="$2" interp="$3" tmp code=0
  shift 3
  tmp="$(mktemp "${TMPDIR:-/tmp}/benchbar-installer.XXXXXX")"
  if fl_run_long "download the ${label} installer" curl -fsSL -o "$tmp" "$url"; then
    fl_run_long "install ${label}" env UV_NO_MODIFY_PATH=1 INSTALLER_NO_MODIFY_PATH=1 "$interp" "$tmp" "$@" || code=$?
  else
    code=1
  fi
  rm -f "$tmp"
  return "$code"
}

fl_section "SYSTEM"
fl_preflight_basics "$OFFLINE" "$FL_MIN_DISK_GB" "$HOME"
if [[ "$FL_IS_WSL" == "1" ]]; then
  fl_ok "$(fl_linux_os_summary) detected, running in WSL (${FL_ARCH})"
  fl_info "WSL: open the site in your Windows browser; localhost ports are shared with Windows."
else
  fl_ok "$(fl_linux_os_summary) detected (${FL_ARCH})"
fi
if [[ "$FL_ARCH" != "x86_64" ]]; then
  fl_warn "Architecture is ${FL_ARCH}; the wkhtmltopdf package is x86_64 only, so PDF printing is skipped."
fi
fl_ok "apt-get at $(command -v apt-get)"
fl_linux_systemd_booted || fl_die "systemd is not running, and MariaDB and Redis are systemd services here." \
  "In WSL add '[boot]' and 'systemd=true' to /etc/wsl.conf, then run 'wsl --shutdown' from Windows."
fl_ok "systemd is running"
command -v sudo >/dev/null 2>&1 || fl_warn "sudo was not found; apt and MariaDB need it"

fl_section "PLAN"
cat <<EOF
  Profile: ${FL_PROFILE}, Frappe ${FL_FRAPPE_BRANCH}, ERPNext ${FL_ERPNEXT_BRANCH}
  Python:  ${FL_PYTHON_BIN_NAME#python} from uv (${FL_PYTHON_BIN_NAME})
  Node:    ${FL_NODE_MAJOR} from fnm
  MariaDB: mariadb-server ${FL_MARIADB_MAJOR_MINOR} from apt (unit mariadb)
  Redis:   redis-server from apt (unit redis-server)
EOF

MISSING_PKGS="$(fl_linux_missing_packages)"

SUDO_REASONS=()
while IFS= read -r reason; do
  [[ -n "$reason" ]] && SUDO_REASONS+=("$reason")
done < <(fl_linux_sudo_reasons)
if [[ "${#SUDO_REASONS[@]}" -gt 0 ]]; then
  fl_sudo_begin "${SUDO_REASONS[@]}" || fl_die "sudo is needed to set up the system dependencies." "Run this again from a terminal where sudo can ask for your password."
fi

if [[ "$FL_DRY_RUN" == "1" ]]; then
  fl_section "DRY RUN"
  if [[ -n "$MISSING_PKGS" ]]; then
    fl_run sudo apt-get update
    # shellcheck disable=SC2086  # the package names are words
    fl_run sudo apt-get install -y $MISSING_PKGS
  else
    fl_info "dry-run: every apt package is installed"
  fi
  if ! command -v uv >/dev/null 2>&1 && [[ ! -x "$HOME/.local/bin/uv" ]]; then
    fl_info "dry-run: curl -LsSf ${UV_INSTALLER_URL} | sh   (uv, into ~/.local/bin, no shell edits)"
  fi
  if [[ ! -x "$(fl__python_bin_for "${FL_PYTHON_BIN_NAME#python}")" ]]; then fl_run uv python install "${FL_PYTHON_BIN_NAME#python}"; fi
  if [[ ! -x "$(fl__node_bindir_for "$FL_NODE_MAJOR")/node" ]]; then
    if ! command -v fnm >/dev/null 2>&1 && [[ ! -x "$(fl__fnm_dir)/fnm" ]]; then
      fl_info "dry-run: curl -fsSL ${FNM_INSTALLER_URL} | bash -s -- --skip-shell   (fnm, no shell edits)"
    fi
    fl_run fnm install "$FL_NODE_MAJOR"
  fi
  fl_run npm install -g yarn
  fl_info "dry-run: MariaDB root password: set through sudo mariadb on a fresh server, else the stored one is verified"
  fl_mariadb_dropin_apply mariadb-frappe.cnf "$(fl_mariadb_utf8_dropin_path)"
  [[ "$FL_TEMPLATE_CHANGED" != "1" ]] || fl_mariadb_restart_if_running || true
  exit 0
fi

fl_section "APT PACKAGES"
if [[ -z "$MISSING_PKGS" ]]; then
  fl_ok "unchanged: all apt packages are installed ($FL_LINUX_APT_PACKAGES)"
else
  fl_info "missing: ${MISSING_PKGS}"
  fl_run_long "apt-get update" sudo apt-get update || fl_warn "apt-get update failed; trying the install with the indexes there are"
  # shellcheck disable=SC2086  # the package names are words
  fl_run_long "apt-get install ${MISSING_PKGS}" sudo apt-get install -y $MISSING_PKGS \
    || fl_die "apt-get install failed." "Run it by hand to see why: sudo apt-get install -y ${MISSING_PKGS}"
  STILL_MISSING="$(fl_linux_missing_packages)"
  [[ -z "$STILL_MISSING" ]] || fl_die "apt packages still missing after the install: ${STILL_MISSING}"
  fl_ok "installed ${MISSING_PKGS}"
fi

fl_section "DATABASE"
MARIADB_BIN="$(fl_mariadb_bin)"
[[ -x "$MARIADB_BIN" ]] || MARIADB_BIN="$(command -v mariadb || true)"
[[ -n "$MARIADB_BIN" && -x "$MARIADB_BIN" ]] || fl_die "mariadb client not found." "Try: sudo apt-get install --reinstall mariadb-client"
MARIADB_VERSION_LINE="$("$MARIADB_BIN" --version 2>&1 | head -n1)"
MARIADB_DISTRIB="$(printf '%s\n' "$MARIADB_VERSION_LINE" | fl_parse_mariadb_version | head -n1)"
[[ -n "$MARIADB_DISTRIB" ]] || fl_die "Could not parse MariaDB version from: ${MARIADB_VERSION_LINE}"
case "$MARIADB_DISTRIB" in
  ${FL_MARIADB_MAJOR_MINOR}.*) fl_ok "mariadb - ${MARIADB_DISTRIB} at ${MARIADB_BIN}" ;;
  *) fl_die "Expected MariaDB ${FL_MARIADB_MAJOR_MINOR}.x but got ${MARIADB_DISTRIB}." "apt on this release ships another MariaDB; the Linux install supports ${FL_MARIADB_MAJOR_MINOR} (Ubuntu 24.04) so far." ;;
esac
fl_ensure_service_started mariadb "mariadbd"

if [[ -r "${FL_MARIADB_DATA_DIR}/mariadb_upgrade_info" ]]; then
  DATA_DIR_VER="$(tr -d '\0' < "${FL_MARIADB_DATA_DIR}/mariadb_upgrade_info" | head -n1)"
  DATA_DIR_VER="${DATA_DIR_VER%%-*}"
  DATA_DIR_MAJOR_MINOR="$(printf '%s\n' "$DATA_DIR_VER" | awk -F. '{print $1 "." $2}')"
  if [[ "$DATA_DIR_MAJOR_MINOR" == "$FL_MARIADB_MAJOR_MINOR" ]]; then
    fl_ok "data dir version matches selected profile (${DATA_DIR_VER})"
  else
    fl_warn "data dir was initialized by ${DATA_DIR_VER} but profile expects ${FL_MARIADB_MAJOR_MINOR}."
    fl_warn "Move ${FL_MARIADB_DATA_DIR} aside and re-init before using this profile."
  fi
fi

root_setup_code=0
if fl_mariadb_root_setup; then root_setup_code=0; else root_setup_code=$?; fi
case "$root_setup_code" in
  0) ;;
  2) add_pending "MARIADB_PASSWORD" ;;
  *) fl_die "Could not set up the MariaDB root password." ;;
esac

UTF8_CNF_PATH="$(fl_mariadb_utf8_dropin_path)"
if [[ "$(fl_template_status "$UTF8_CNF_PATH" "$(fl_template_render mariadb-frappe.cnf)")" == "current" ]]; then
  fl_ok "frappe.cnf utf8mb4 config present at ${UTF8_CNF_PATH}"
else
  fl_warn "utf8mb4 config missing or outdated at ${UTF8_CNF_PATH}; writing it"
  fl_mariadb_dropin_apply mariadb-frappe.cnf "$UTF8_CNF_PATH" || fl_die "Could not write ${UTF8_CNF_PATH}."
  fl_mariadb_restart_if_running || true
fi

fl_section "REDIS"
REDIS_BIN="$(command -v redis-server || true)"
[[ -n "$REDIS_BIN" && -x "$REDIS_BIN" ]] || REDIS_BIN="/usr/bin/redis-server"
[[ -x "$REDIS_BIN" ]] || fl_die "redis-server not found." "Try: sudo apt-get install --reinstall redis-server"
REDIS_VERSION="$("$REDIS_BIN" --version | sed -n 's/.*v=\([0-9.]*\).*/\1/p')"
fl_ok "redis-server - ${REDIS_VERSION:-unknown} at ${REDIS_BIN}"
fl_ensure_service_started redis-server "redis-server"

fl_section "PDF"
# ok | skipped (declined on purpose, return 2) | failed (download, checksum,
# install). PDFs are optional either way, but a failure is said out loud
# and listed at the end instead of looking like a choice.
# BENCHBAR_PDF_STEP (from benchbar install, which runs this step first): the
# package was skipped or failed there, or its dry-run plan was shown; say so
# without asking (or printing the plan) again.
WKHTML_STATE=ok
if [[ -n "${BENCHBAR_PDF_STEP:-}" && "$(fl_wkhtmltopdf_state)" != "patched" ]]; then
  WKHTML_STATE="$BENCHBAR_PDF_STEP"
  case "$WKHTML_STATE" in
    dry-run) WKHTML_STATE=ok; fl_info "dry-run: the wkhtmltopdf plan is above (benchbar install showed it)" ;;
    skipped) fl_warn "wkhtmltopdf was skipped above (benchbar install asked already): PDFs will not work until it is installed" ;;
    *) WKHTML_STATE=failed; fl_fail "the wkhtmltopdf install failed above (see benchbar install's output)"; add_pending "WKHTMLTOPDF_FAILED" ;;
  esac
elif fl_wkhtmltopdf_ensure; then WKHTML_STATE=ok; else
  case "$?" in 2) WKHTML_STATE=skipped ;; *) WKHTML_STATE=failed; add_pending "WKHTMLTOPDF_FAILED" ;; esac
fi
# everything that needed root is done: the uv and fnm installers, npm and the
# shell block that follow must not find a cached sudo credential
fl_sudo_drop

fl_section "PYTHON"
export PATH="$HOME/.local/bin:$PATH"
if command -v uv >/dev/null 2>&1; then
  fl_ok "uv at $(command -v uv)"
else
  fl_install_script uv "$UV_INSTALLER_URL" sh || fl_die "The uv install failed." "Install it by hand: curl -LsSf ${UV_INSTALLER_URL} | sh"
  hash -r 2>/dev/null || true
  command -v uv >/dev/null 2>&1 || fl_die "uv not found after its installer ran." "Look for ~/.local/bin/uv, and put ~/.local/bin on your PATH."
  fl_ok "uv installed at $(command -v uv)"
fi
PY_BIN="$(fl_python_bin)"
if [[ ! -x "$PY_BIN" ]]; then
  fl_run_long "uv python install ${FL_PYTHON_BIN_NAME#python}" uv python install "${FL_PYTHON_BIN_NAME#python}" \
    || fl_die "uv python install failed." "Try: uv python install ${FL_PYTHON_BIN_NAME#python}"
  PY_BIN="$(fl_python_bin)"
fi
[[ -n "$PY_BIN" && -x "$PY_BIN" ]] || fl_die "${FL_PYTHON_BIN_NAME} not found after uv python install." "Try: uv python install ${FL_PYTHON_BIN_NAME#python}"
PY_VERSION="$("$PY_BIN" --version 2>&1 | awk '{print $2}')"
case "$PY_VERSION" in
  ${FL_PYTHON_BIN_NAME#python}.*) fl_ok "${FL_PYTHON_BIN_NAME} - ${PY_VERSION} at ${PY_BIN}" ;;
  *) fl_die "Expected ${FL_PYTHON_BIN_NAME}, got ${PY_VERSION} at ${PY_BIN}." ;;
esac
"$PY_BIN" -c 'import venv, ensurepip' >/dev/null 2>&1 || fl_die "venv or ensurepip missing for ${FL_PYTHON_BIN_NAME}."
fl_ok "venv and ensurepip available"

fl_section "NODE"
NODE_BINDIR="$(fl__node_bindir_for "$FL_NODE_MAJOR")"
if [[ ! -x "${NODE_BINDIR}/node" ]]; then
  FNM_BIN="$(command -v fnm || true)"
  if [[ -z "$FNM_BIN" && -x "$(fl__fnm_dir)/fnm" ]]; then FNM_BIN="$(fl__fnm_dir)/fnm"; fi
  if [[ -z "$FNM_BIN" ]]; then
    fl_install_script fnm "$FNM_INSTALLER_URL" bash --install-dir "$(fl__fnm_dir)" --skip-shell \
      || fl_die "The fnm install failed." "Install it by hand: curl -fsSL ${FNM_INSTALLER_URL} | bash -s -- --skip-shell"
    FNM_BIN="$(fl__fnm_dir)/fnm"
    [[ -x "$FNM_BIN" ]] || FNM_BIN="$(command -v fnm || true)"
    [[ -n "$FNM_BIN" && -x "$FNM_BIN" ]] || fl_die "fnm not found after its installer ran." "Look in $(fl__fnm_dir)"
    fl_ok "fnm installed at ${FNM_BIN}"
  fi
  fl_run_long "fnm install ${FL_NODE_MAJOR}" env FNM_DIR="$(fl__fnm_dir)" "$FNM_BIN" install "$FL_NODE_MAJOR" \
    || fl_die "fnm install ${FL_NODE_MAJOR} failed." "Try: fnm install ${FL_NODE_MAJOR}"
  NODE_BINDIR="$(fl__node_bindir_for "$FL_NODE_MAJOR")"
fi
NODE_BIN="$(fl_node_bin)"
NPM_BIN="$(fl_npm_bin)"
[[ -x "$NODE_BIN" ]] || fl_die "node ${FL_NODE_MAJOR} binary not found at ${NODE_BIN}." "Try: fnm install ${FL_NODE_MAJOR}"
# npm's launcher runs "env node": this Node first on PATH
export PATH="${NODE_BINDIR}:$PATH"
NODE_VERSION="$("$NODE_BIN" --version)"
case "$NODE_VERSION" in
  v${FL_NODE_MAJOR}.*) fl_ok "node - ${NODE_VERSION} at ${NODE_BIN}" ;;
  *) fl_die "Expected Node v${FL_NODE_MAJOR}.x but got ${NODE_VERSION}." ;;
esac
NPM_VERSION="$("$NPM_BIN" --version)"
fl_ok "npm - ${NPM_VERSION} at ${NPM_BIN}"
if "$NPM_BIN" ls -g --depth=0 2>/dev/null | grep -q ' yarn@'; then
  fl_info "yarn already globally installed under Node ${FL_NODE_MAJOR}"
else
  fl_run "$NPM_BIN" install -g yarn
fi
YARN_BIN="${NODE_BINDIR}/yarn"
[[ -x "$YARN_BIN" ]] || YARN_BIN="$(command -v yarn || true)"
[[ -n "$YARN_BIN" && -x "$YARN_BIN" ]] || fl_die "yarn not found after install."
YARN_VERSION="$("$YARN_BIN" --version)"
fl_ok "yarn - ${YARN_VERSION} at ${YARN_BIN}"

fl_section "SHELL CONFIG"
RC_FILE="$(fl_rc_file)"
HELPER_BLOCK="$(fl_template_render shell-helpers "PROFILE_EXPORTS=$(fl_profile_path_exports "$FL_PROFILE")" "BENCHBAR=${FL_SELF}")"
case "$(fl_rc_block_status "$RC_FILE" "$HELPER_BLOCK")" in
  current)
    fl_ok "${RC_FILE} has the benchbar block (profile exports and bench helpers)"
    ;;
  outdated|broken)
    # its PATH follows the default bench, which only benchbar service and
    # repair know; this phase must not switch it to another profile
    fl_ok "${RC_FILE} has the benchbar block; benchbar service or repair keeps it current"
    ;;
  *)
    fl_warn "${RC_FILE} needs the benchbar block; writing it (profile exports and bench helpers)"
    fl_rc_block_write "$RC_FILE" "$HELPER_BLOCK"
    if [[ "$FL_DRY_RUN" != "1" ]]; then
      fl_ok "wrote the benchbar block to ${RC_FILE}"
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
printf '%-22s %-22s %s\n' "mariadb" "$MARIADB_DISTRIB" "$MARIADB_BIN"
printf '%-22s %-22s %s\n' "redis-server" "${REDIS_VERSION:-?}" "$REDIS_BIN"
case "$WKHTML_STATE" in
  ok) printf '%-22s %-22s %s\n' "wkhtmltopdf" "$("$(fl_wkhtmltopdf_bin)" --version 2>/dev/null | head -n1 | awk '{print $2}')" "$(fl_wkhtmltopdf_bin)" ;;
  skipped) printf '%-22s %-22s %s\n' "wkhtmltopdf" "skipped" "PDFs will not work until it is installed" ;;
  *) printf '%-22s %-22s %s\n' "wkhtmltopdf" "FAILED" "the install did not succeed; see the step below" ;;
esac

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

   source ${RC_FILE}

EOF
      ;;
    WKHTMLTOPDF_FAILED)
      cat <<EOF
${step_n}) The wkhtmltopdf install failed (not skipped): a download, checksum or
   apt error is printed above. The bench works without it, PDF printing
   does not. Run this again to retry, or install the package by hand:

   https://github.com/wkhtmltopdf/packaging/releases   (0.12.6.1-3, jammy_amd64.deb)
   ${FL_SELF} repair                         (retries the download and install)

EOF
      ;;
    MARIADB_PASSWORD)
      cat <<EOF
${step_n}) MariaDB root already has a password, and neither the environment nor the
   password file ($(fl__secret_file)) knows it. Run this once with the password (it
   is verified, then saved to that file and never asked again):

   MARIADB_ROOT_PASSWORD='the password' ${FL_SELF} install

   Or run ${FL_SELF} install without --yes and type it when asked.
   Forgotten? If this works, set a new one there (it keeps the databases):
     sudo mariadb -e "ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('new-password');"
   If it does not, start the server without grant tables for a moment:
     sudo systemctl stop mariadb
     sudo mariadbd-safe --skip-grant-tables --skip-networking &
     sudo mariadb -e "FLUSH PRIVILEGES; ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('new-password');"
     sudo mariadb-admin shutdown; sudo systemctl start mariadb

EOF
      ;;
  esac
done

printf '%sAfter completing the above, re-run this script to verify.%s\n\n' "$FL_YELLOW$FL_BOLD" "$FL_RESET"
# "source the rc file" and a failed optional PDF tool do not block the next phase
only_soft=1
for step in "${PENDING_STEPS[@]}"; do
  case "$step" in SOURCE_RC|WKHTMLTOPDF_FAILED) ;; *) only_soft=0 ;; esac
done
[[ "$only_soft" == "1" ]] && exit 0
exit 2
