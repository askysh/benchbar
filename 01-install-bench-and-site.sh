#!/usr/bin/env bash
#
# 01-install-bench-and-site.sh
#
# Phase 1 for local Frappe/ERPNext development on macOS.
# Creates or repairs a bench, resolves apps from policy, creates a site,
# installs apps idempotently, and records resumable state.

# shellcheck disable=SC2153  # BENCH_DIR, SITE_NAME and passwords may come from the environment
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
# shellcheck source=lib/frappe-local/toml.sh
. "${SCRIPT_DIR}/lib/frappe-local/toml.sh"
# shellcheck source=lib/frappe-local/profiles.sh
. "${SCRIPT_DIR}/lib/frappe-local/profiles.sh"
# shellcheck source=lib/frappe-local/state.sh
. "${SCRIPT_DIR}/lib/frappe-local/state.sh"
# shellcheck source=lib/frappe-local/bench.sh
. "${SCRIPT_DIR}/lib/frappe-local/bench.sh"
# shellcheck source=lib/frappe-local/templates.sh
. "${SCRIPT_DIR}/lib/frappe-local/templates.sh"
# shellcheck source=lib/frappe-local/mariadb.sh
. "${SCRIPT_DIR}/lib/frappe-local/mariadb.sh"
trap fl_on_error ERR

ASSUME_YES=0
PROFILE="${PROFILE:-}"
LIST_PROFILES=0
CHECK_UPDATES=0
OFFLINE=0
ADVANCED=0
DRY_RUN=0
REPAIR_BENCH=0
APP_BUNDLE="${APP_BUNDLE:-}"
APPS="${APPS:-}"

usage() {
  cat <<EOF
Usage: ./01-install-bench-and-site.sh [options]

Recommended:
  ./01-install-bench-and-site.sh
  APP_BUNDLE=common ./01-install-bench-and-site.sh
  APP_BUNDLE=extended ./01-install-bench-and-site.sh

Advanced:
  ./01-install-bench-and-site.sh --profile v16-lts
  ./01-install-bench-and-site.sh --advanced
  APPS="erpnext crm" ./01-install-bench-and-site.sh

Options:
  -y, --yes             Non-interactive; secrets must be supplied by env
  --profile VALUE       Use release profile
  --list-profiles       Print known profiles and exit
  --check-updates       Check remote Frappe/ERPNext version branches
  --offline             Skip remote checks
  --advanced            Prompt for custom branch/tag or commit pins
  --dry-run             Print mutating commands without running them
  --repair-bench        Move incomplete bench aside and re-init
  -h, --help            Show this help
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1; FL_ASSUME_YES=1; shift ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --list-profiles) LIST_PROFILES=1; shift ;;
    --check-updates) CHECK_UPDATES=1; shift ;;
    --offline) OFFLINE=1; shift ;;
    --advanced) ADVANCED=1; shift ;;
    --dry-run) DRY_RUN=1; FL_DRY_RUN=1; shift ;;
    --repair-bench) REPAIR_BENCH=1; shift ;;
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
fl_mariadb_prefer_running

FRAPPE_REF="$FL_FRAPPE_BRANCH"
ERPNEXT_REF="$FL_ERPNEXT_BRANCH"
FRAPPE_COMMIT="${FRAPPE_COMMIT:-}"
ERPNEXT_COMMIT="${ERPNEXT_COMMIT:-}"

prompt_value() {
  local varname="$1" prompt="$2" default="$3"
  if [[ -n "${!varname:-}" ]]; then
    fl_info "using env-provided ${varname}=${!varname}"
  elif [[ "$ASSUME_YES" == "1" ]]; then
    printf -v "$varname" '%s' "$default"
    fl_info "auto-accepted ${varname}=${default}"
  else
    fl_ask "$varname" "$prompt" "$default"
  fi
}

prompt_secret() {
  local varname="$1" prompt="$2"
  if [[ -n "${!varname:-}" ]]; then
    fl_info "using env-provided ${varname} (hidden)"
  elif [[ "$FL_DRY_RUN" == "1" ]]; then
    printf -v "$varname" '%s' "dry-run-placeholder"
    fl_info "dry-run: using placeholder for ${varname}"
  elif [[ "$ASSUME_YES" == "1" ]]; then
    fl_die "Secret '${varname}' must be supplied via env var when using --yes." "Re-run with: ${varname}='...' $0 --yes"
  else
    fl_ask_secret "$varname" "$prompt"
  fi
}

fl_section "PROFILE"
fl_ok "Using ${FL_PROFILE_LABEL} (${FL_PROFILE})"
if [[ "$FL_PROFILE" == "v15-lts" ]]; then
  fl_info "This is the conservative default for a stable local Frappe/ERPNext setup."
  fl_info "Support window: through planned end of ${FL_SUPPORT_END}."
  fl_info "For v16 experiments only, run: ./01-install-bench-and-site.sh --profile v16-lts"
  fl_info "For custom branches/tags/commits, run: ./01-install-bench-and-site.sh --advanced"
else
  fl_warn "${FL_PROFILE} is ${FL_PROFILE_STATUS}; use it only when you intentionally want this version."
fi

if [[ "$ADVANCED" == "1" ]]; then
  fl_section "ADVANCED VERSION MODE"
  if [[ -n "$FRAPPE_COMMIT" || -n "$ERPNEXT_COMMIT" ]]; then
    fl_validate_custom_commit "$FRAPPE_COMMIT"
    fl_validate_custom_commit "$ERPNEXT_COMMIT"
  elif [[ "$ASSUME_YES" == "1" ]]; then
    FRAPPE_REF="${FRAPPE_REF:-$FL_FRAPPE_BRANCH}"
    ERPNEXT_REF="${ERPNEXT_REF:-$FL_ERPNEXT_BRANCH}"
  else
    printf '  1. Branch or tag\n  2. Specific commit\n'
    read -r -p "  Choose [1]: " advanced_choice
    advanced_choice="${advanced_choice:-1}"
    case "$advanced_choice" in
      1)
        fl_ask FRAPPE_REF "Frappe branch/tag" "$FL_FRAPPE_BRANCH"
        fl_ask ERPNEXT_REF "ERPNext branch/tag" "$FL_ERPNEXT_BRANCH"
        ;;
      2)
        fl_ask FRAPPE_COMMIT "Frappe commit hash" ""
        fl_validate_custom_commit "$FRAPPE_COMMIT"
        fl_ask ERPNEXT_COMMIT "ERPNext commit hash" ""
        fl_validate_custom_commit "$ERPNEXT_COMMIT"
        ;;
      *) fl_die "Unknown advanced mode: ${advanced_choice}" ;;
    esac
  fi
fi

if [[ "$CHECK_UPDATES" == "1" ]]; then
  fl_check_updates
fi

fl_platform_init
fl_section "PRECHECK"
fl_preflight_basics "$OFFLINE" "$FL_MIN_DISK_GB" "$HOME"
export PATH="${FL_BREW_PREFIX}/opt/${FL_PYTHON_FORMULA}/bin:${FL_BREW_PREFIX}/opt/${FL_NODE_FORMULA}/bin:${FL_BREW_PREFIX}/opt/${FL_MARIADB_FORMULA}/bin:$HOME/.local/bin:$PATH"
export LDFLAGS="-L${FL_BREW_PREFIX}/opt/openssl@3/lib -L${FL_BREW_PREFIX}/opt/libffi/lib -L${FL_BREW_PREFIX}/opt/zlib/lib"
export CPPFLAGS="-I${FL_BREW_PREFIX}/opt/openssl@3/include -I${FL_BREW_PREFIX}/opt/libffi/include -I${FL_BREW_PREFIX}/opt/zlib/include"
export PKG_CONFIG_PATH="${FL_BREW_PREFIX}/opt/openssl@3/lib/pkgconfig:${FL_BREW_PREFIX}/opt/libffi/lib/pkgconfig:${FL_BREW_PREFIX}/opt/zlib/lib/pkgconfig:${FL_BREW_PREFIX}/opt/mariadb-connector-c/lib/pkgconfig"

if [[ "$OFFLINE" != "1" ]]; then
  if [[ -z "$FRAPPE_COMMIT" ]]; then
    fl_repo_ref_exists "https://github.com/frappe/frappe" "$FRAPPE_REF" || fl_die "Frappe ref not found: ${FRAPPE_REF}"
  fi
  if [[ -z "$ERPNEXT_COMMIT" ]]; then
    fl_repo_ref_exists "https://github.com/frappe/erpnext" "$ERPNEXT_REF" || fl_die "ERPNext ref not found: ${ERPNEXT_REF}"
  fi
else
  fl_warn "Offline mode: skipping remote branch/tag checks. Failures may happen later during git clone."
fi

if [[ "$FL_DRY_RUN" == "1" ]]; then
  for cmd in "$FL_PYTHON_BIN_NAME" node npm yarn mariadb redis-server wkhtmltopdf; do
    if command -v "$cmd" >/dev/null 2>&1; then
      fl_ok "${cmd} found"
    else
      fl_warn "dry-run: ${cmd} not found; real install would stop here"
    fi
  done
  fl_info "dry-run: skipping service checks for mariadbd and redis-server"
else
  fl_require_cmd "$FL_PYTHON_BIN_NAME" "Run ./00-mac-system-deps.sh --profile ${FL_PROFILE}"
  fl_require_cmd node "Run ./00-mac-system-deps.sh --profile ${FL_PROFILE}"
  fl_require_cmd npm "Run ./00-mac-system-deps.sh --profile ${FL_PROFILE}"
  fl_require_cmd yarn "Run ./00-mac-system-deps.sh --profile ${FL_PROFILE}"
  fl_require_cmd mariadb "Run ./00-mac-system-deps.sh --profile ${FL_PROFILE}"
  fl_require_cmd redis-server "Run ./00-mac-system-deps.sh --profile ${FL_PROFILE}"
  if command -v wkhtmltopdf >/dev/null 2>&1; then
    fl_ok "wkhtmltopdf found"
  else
    fl_warn "wkhtmltopdf is not installed: the bench works, PDF printing does not. Run ./00-mac-system-deps.sh to add it later."
  fi
  if fl_port_listening 3306; then
    fl_mariadb_safe_mode_note
  fi
  fl_process_running mariadbd || fl_die "mariadbd is not running." "brew services start ${FL_MARIADB_FORMULA}"
  fl_process_running redis-server || fl_die "redis-server is not running." "brew services start redis"
  fl_ok "system services are running"
fi

fl_section "INPUTS"
prompt_value BENCH_DIR "Bench directory" "${HOME}/frappe-bench"
case "$BENCH_DIR" in
  /*) ;;
  '~'|'~/'*) BENCH_DIR="${HOME}${BENCH_DIR#'~'}" ;;
  *) BENCH_DIR="${PWD}/${BENCH_DIR}" ;;
esac
BENCH_DIR="${BENCH_DIR%/}"
prompt_value SITE_NAME "Site name (lowercase, hostname-like)" "${FL_TEAM_SITE:-macdev}"
if ! [[ "$SITE_NAME" =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
  fl_die "Invalid site name: '${SITE_NAME}'." "Use lowercase letters, digits, '-' and '.' only."
fi
SITE_EXISTS=0
[[ -d "${BENCH_DIR}/sites/${SITE_NAME}" ]] && SITE_EXISTS=1

TEAM_APPS=0
if [[ -n "$APPS" ]]; then
  fl_info "APPS overrides app bundle selection."
elif [[ -n "$FL_TEAM_PROFILE" && "${#FL_TEAM_APPS[@]}" -gt 0 ]]; then
  TEAM_APPS=1
  fl_info "apps from team profile ${FL_TEAM_PROFILE} (${FL_TEAM_PROFILE_FILE})"
  APP_BUNDLE="${APP_BUNDLE:-minimal}"
else
  [[ -n "$APP_BUNDLE" ]] || APP_BUNDLE="$FL_TEAM_BUNDLE"
  if [[ -z "$APP_BUNDLE" ]]; then
    if [[ "$ASSUME_YES" == "1" ]]; then
      APP_BUNDLE="minimal"
    else
      printf '\nInstall bundle:\n'
      fl_list_bundles
      printf '  %-14s %s\n' "custom" "Type apps manually"
      read -r -p "  Bundle [minimal]: " bundle_answer
      bundle_answer="${bundle_answer:-minimal}"
      if [[ "$bundle_answer" == "custom" ]]; then
        fl_ask APPS "Apps to install (space-separated)" "erpnext"
      else
        APP_BUNDLE="$bundle_answer"
      fi
    fi
  fi
fi
[[ -n "$APP_BUNDLE" ]] || APP_BUNDLE="minimal"

if [[ "$TEAM_APPS" == "1" ]]; then
  # the team profile's own list: its repos and branches, in its order
  apps_line=""
  for spec in "${FL_TEAM_APPS[@]}"; do apps_line="${apps_line} ${spec%%|*}"; done
  fl_resolve_selected_apps "$FL_PROFILE" "$APP_BUNDLE" "$apps_line"
else
  fl_resolve_selected_apps "$FL_PROFILE" "$APP_BUNDLE" "$APPS"
fi

CUSTOMIZED_SPECS=()
for spec in "${FL_INSTALL_SPECS[@]}"; do
  IFS='|' read -r app branch repo priority notes <<<"$spec"
  if [[ -z "$branch" ]]; then
    upper="$(printf '%s' "$app" | tr '[:lower:]-' '[:upper:]_')"
    env_branch_var="${upper}_BRANCH"
    env_url_var="${upper}_URL"
    if [[ -n "${!env_branch_var:-}" && -n "${!env_url_var:-}" ]]; then
      branch="${!env_branch_var}"
      repo="${!env_url_var}"
    elif [[ "$ASSUME_YES" == "1" ]]; then
      fl_die "Unknown app '${app}' in --yes mode." "Supply ${env_url_var}=... and ${env_branch_var}=..."
    else
      fl_warn "'${app}' is not in the app registry."
      fl_ask "$env_url_var" "git URL for '${app}'" ""
      fl_ask "$env_branch_var" "branch for '${app}'" "main"
      repo="${!env_url_var}"
      branch="${!env_branch_var}"
    fi
  fi
  CUSTOMIZED_SPECS+=("${app}|${branch}|${repo}|${priority}|${notes}")
done
FL_INSTALL_SPECS=("${CUSTOMIZED_SPECS[@]}")

if [[ "$OFFLINE" != "1" ]]; then
  fl_validate_app_refs_online
fi

if [[ "$SITE_EXISTS" == "1" ]]; then
  fl_info "site ${SITE_NAME} already exists: no passwords needed"
  MARIADB_ROOT_PASSWORD="${MARIADB_ROOT_PASSWORD:-}"
  ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
else
  # environment, then the Keychain (written by phase 00), then a prompt
  # exit 2, the documented "root password unknown" code, not a generic failure
  fl_mariadb_root_password_resolve || fl_die "MariaDB root password needed to create the site." \
    "Re-run with: MARIADB_ROOT_PASSWORD='...' $0 --yes, or run ./00-mac-system-deps.sh once to store it in the Keychain." 2
  MARIADB_ROOT_PASSWORD="$FL_MARIADB_ROOT_PW"
  prompt_secret ADMIN_PASSWORD "Site admin password (Administrator login)"
fi

fl_section "PLAN"
cat <<EOF
  Profile: ${FL_PROFILE}, Frappe ${FRAPPE_REF}, ERPNext ${ERPNEXT_REF}
  Bundle: ${APP_BUNDLE}
  Python: ${FL_PYTHON_FORMULA}
  Node: ${FL_NODE_FORMULA}
  MariaDB: ${FL_MARIADB_FORMULA}
  Bench directory: ${BENCH_DIR}
  Site: ${SITE_NAME}
  Apps: ${FL_SELECTED_APPS[*]}
EOF
if [[ -n "$FRAPPE_COMMIT" || -n "$ERPNEXT_COMMIT" ]]; then
  printf '  Commit pins: frappe=%s erpnext=%s\n' "${FRAPPE_COMMIT:-none}" "${ERPNEXT_COMMIT:-none}"
fi
if [[ -n "$FL_TEAM_PROFILE" ]]; then
  printf '  Team profile: %s (%s)\n' "$FL_TEAM_PROFILE" "$FL_TEAM_PROFILE_FILE"
fi

if [[ "$ASSUME_YES" != "1" && "$FL_DRY_RUN" != "1" ]]; then
  fl_confirm "Proceed?" || { fl_warn "Cancelled."; exit 0; }
fi

if [[ "$FL_DRY_RUN" != "1" && "$SITE_EXISTS" != "1" ]]; then
  fl_section "VERIFY DB CREDENTIALS"
  fl_mariadb_root_verify "$MARIADB_ROOT_PASSWORD" \
    || fl_die "MariaDB root password is wrong." "benchbar mariadb-password prints the stored one; MARIADB_ROOT_PASSWORD='...' overrides it."
  DB_CHARSET="$(fl_mariadb_server_charset "$MARIADB_ROOT_PASSWORD")"
  [[ "$DB_CHARSET" == "utf8mb4" ]] || fl_die "MariaDB character_set_server is '${DB_CHARSET}', expected 'utf8mb4'." "Run ./00-mac-system-deps.sh again (it writes the utf8mb4 drop-in and restarts MariaDB)."
  fl_ok "MariaDB root password verified and charset is utf8mb4"
fi

fl_state_init
# per bench settings; the default bench changes only when there is none yet
# (or --make-default), so a second bench never takes over benchup
fl_bench_state_migrate "$(fl_state_get BENCH_DIR)"
fl_bstate_set_for "$BENCH_DIR" PROFILE "$FL_PROFILE"
[[ -z "$FL_TEAM_PROFILE" ]] || fl_bstate_set_for "$BENCH_DIR" TEAM_PROFILE "$FL_TEAM_PROFILE"
fl_bstate_set_for "$BENCH_DIR" APP_BUNDLE "$APP_BUNDLE"
fl_bstate_set_for "$BENCH_DIR" APPS "${FL_SELECTED_APPS[*]}"
fl_bstate_set_for "$BENCH_DIR" SITE_NAME "$SITE_NAME"
fl_bstate_set_for "$BENCH_DIR" MARIADB_FORMULA "$FL_MARIADB_FORMULA"

fl_install_pipx_if_needed
fl_install_bench_if_needed
fl_bench_init_if_needed "$BENCH_DIR" "$FRAPPE_REF" "$(command -v "$FL_PYTHON_BIN_NAME")" "$REPAIR_BENCH"

if [[ -n "$FRAPPE_COMMIT" && -d "$BENCH_DIR/apps/frappe/.git" ]]; then
  fl_warn "Pinning frappe to ${FRAPPE_COMMIT}"
  fl_run git -C "$BENCH_DIR/apps/frappe" fetch --all --tags
  fl_run git -C "$BENCH_DIR/apps/frappe" checkout "$FRAPPE_COMMIT"
fi

fl_section "GET APPS"
for spec in "${FL_INSTALL_SPECS[@]}"; do
  IFS='|' read -r app branch repo _priority _notes <<<"$spec"
  # a team profile may pin a commit
  pin_commit=""
  for team_spec in ${FL_TEAM_APPS[@]+"${FL_TEAM_APPS[@]}"}; do
    [[ -n "$FL_TEAM_PROFILE" && "${team_spec%%|*}" == "$app" ]] && pin_commit="${team_spec##*|}"
  done
  if [[ -n "$pin_commit" ]]; then
    fl_get_app_if_needed "$BENCH_DIR" "$app" "$branch" "$repo" "$pin_commit" "1"
  else
    fl_get_app_if_needed "$BENCH_DIR" "$app" "$branch" "$repo" "" "0"
  fi
done

if [[ -n "$ERPNEXT_COMMIT" && -d "$BENCH_DIR/apps/erpnext/.git" ]]; then
  fl_warn "Pinning erpnext to ${ERPNEXT_COMMIT}"
  fl_run git -C "$BENCH_DIR/apps/erpnext" fetch --all --tags
  fl_run git -C "$BENCH_DIR/apps/erpnext" checkout "$ERPNEXT_COMMIT"
fi

if [[ -n "$FRAPPE_COMMIT" || -n "$ERPNEXT_COMMIT" ]]; then
  fl_warn "Rebuilding bench after commit pinning"
  fl_bench_run_long "bench setup requirements" "$BENCH_DIR" bench setup requirements
  fl_bench_run_long "bench build" "$BENCH_DIR" bench build
fi

# the bench's Redis runs for new-site and install-app (frappe v16 needs it)
fl_bench_redis_up "$BENCH_DIR"
trap 'fl_bench_redis_down' EXIT
fl_new_site_if_needed "$BENCH_DIR" "$SITE_NAME" "$MARIADB_ROOT_PASSWORD" "$ADMIN_PASSWORD"

fl_section "INSTALL APPS ON SITE"
for spec in "${FL_INSTALL_SPECS[@]}"; do
  IFS='|' read -r app _branch _repo _priority _notes <<<"$spec"
  fl_install_app_if_needed "$BENCH_DIR" "$SITE_NAME" "$app"
done

fl_verify_site_health "$BENCH_DIR" "$SITE_NAME"

# only now, with the site verified: a failed install must not become the
# bench that benchup starts
fl_remember_default "$BENCH_DIR" || fl_info "the default bench stays $(fl_state_get BENCH_DIR); pass --make-default to benchbar install to change it"

fl_section "READY"
if ! grep -qE "^[[:space:]]*127\.0\.0\.1[[:space:]]+(.*[[:space:]])?${SITE_NAME//./\\.}([[:space:]]|$)" "${FL_HOSTS_FILE:-/etc/hosts}" 2>/dev/null; then
  fl_warn "No /etc/hosts entry for ${SITE_NAME} yet; benchbar install (or repair) adds it, or run:"
  printf '  printf "127.0.0.1 %s\\n" | sudo tee -a /etc/hosts\n\n' "$SITE_NAME"
fi
cat <<EOF
Run in the background (recommended):
  ${SCRIPT_DIR}/benchbar service --bench-dir ${BENCH_DIR}
  benchup

Or in the foreground:
  cd ${BENCH_DIR} && bench start

Open:
  http://${SITE_NAME}:8000

Login:
  Administrator / <password you entered>
EOF
