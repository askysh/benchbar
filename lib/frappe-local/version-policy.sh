#!/usr/bin/env bash

FL_PROFILE=""
FL_PROFILE_LABEL=""
FL_FRAPPE_BRANCH=""
FL_ERPNEXT_BRANCH=""
FL_PYTHON_FORMULA=""
FL_PYTHON_BIN_NAME=""
FL_NODE_FORMULA=""
FL_NODE_MAJOR=""
FL_MARIADB_FORMULA=""
FL_MARIADB_MAJOR_MINOR=""
FL_PROFILE_STATUS=""
FL_SUPPORT_END=""
FL_MARIADB_MIN=""
FL_MARIADB_MAX=""

# every profile builds mysqlclient (pinned by frappe v16) against these
FL_BUILD_FORMULAE="pkgconf mariadb-connector-c"

FL_SELECTED_APPS=()
FL_INSTALL_SPECS=()

# FL_CONFIG_DIR overrides the config folder (the tests pin their own checksums)
fl_config_file() {
  printf '%s/%s\n' "${FL_CONFIG_DIR:-${SCRIPT_DIR}/config}" "$1"
}

fl_load_profile() {
  local profile="$1" file row
  file="$(fl_config_file release-profiles.tsv)"
  row="$(awk -F '\t' -v p="$profile" 'NR > 1 && $1 == p {print}' "$file")"
  [[ -n "$row" ]] || fl_die "Unknown release profile: ${profile}" "Run with --list-profiles."
  IFS=$'\t' read -r FL_PROFILE FL_PROFILE_LABEL FL_FRAPPE_BRANCH FL_ERPNEXT_BRANCH \
    FL_PYTHON_FORMULA FL_PYTHON_BIN_NAME FL_NODE_FORMULA FL_NODE_MAJOR \
    FL_MARIADB_FORMULA FL_MARIADB_MAJOR_MINOR FL_PROFILE_STATUS FL_SUPPORT_END _default \
    FL_MARIADB_MIN FL_MARIADB_MAX <<<"$row"
  FL_MARIADB_MIN="${FL_MARIADB_MIN:-10.6}"; FL_MARIADB_MAX="${FL_MARIADB_MAX:-$FL_MARIADB_MAJOR_MINOR}"
}

# The Frappe major version of the loaded profile: 15 for version-15.
fl_profile_major() {
  local v="${FL_FRAPPE_BRANCH#version-}"
  case "$v" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$v" ;; esac
}

# fl_profile_detect DIR: the profile whose Frappe branch matches the major
# version of DIR/apps/frappe (15.113.4 -> version-15 -> v15-lts), or nothing.
fl_profile_detect() {
  local init="$1/apps/frappe/frappe/__init__.py" major
  [[ -f "$init" ]] || return 0
  major="$(sed -n 's/^__version__[[:space:]]*=[[:space:]]*["'"'"']\([0-9][0-9]*\)\..*/\1/p' "$init" | head -n1)"
  [[ -n "$major" ]] || return 0
  awk -F '\t' -v b="version-${major}" 'NR > 1 && $3 == b {print $1; exit}' "$(fl_config_file release-profiles.tsv)"
}

fl_default_profile() {
  awk -F '\t' 'NR > 1 && $13 == "yes" {print $1; exit}' "$(fl_config_file release-profiles.tsv)"
}

fl_list_profiles() {
  awk -F '\t' 'NR == 1 {next} {printf "  %-10s %-28s support-through=%s default=%s status=%s\n", $1, $2, $12, $13, $11}' \
    "$(fl_config_file release-profiles.tsv)"
}

fl_repo_ref_exists() {
  local repo="$1" ref="$2"
  git ls-remote --exit-code --heads --tags "$repo" "$ref" >/dev/null 2>&1
}

fl_validate_custom_commit() {
  local value="$1"
  [[ "$value" =~ ^[0-9a-fA-F]{7,40}$ ]] || fl_die "Invalid commit hash: ${value}" "Use a 7-40 character hex commit."
}

fl_expand_policy_ref() {
  local ref="$1"
  # shellcheck disable=SC2016
  case "$ref" in
    '${frappe_branch}') printf '%s\n' "$FL_FRAPPE_BRANCH" ;;
    '${erpnext_branch}') printf '%s\n' "$FL_ERPNEXT_BRANCH" ;;
    *) printf '%s\n' "$ref" ;;
  esac
}

fl_lookup_app_policy() {
  local app="$1" profile="$2" file row repo v15 v16 priority notes branch
  file="$(fl_config_file apps.tsv)"
  row="$(awk -F '\t' -v a="$app" 'NR > 1 && $1 == a {printf "%s|%s|%s|%s|%s\n", $2, $3, $4, $5, $6}' "$file")"
  [[ -n "$row" ]] || return 1
  IFS='|' read -r repo v15 v16 priority notes <<<"$row"
  case "$profile" in
    v15-lts) branch="$v15" ;;
    v16-lts) branch="$v16" ;;
    *) branch="$v15" ;;
  esac
  branch="$(fl_expand_policy_ref "$branch")"
  printf '%s|%s|%s|%s\n' "$branch" "$repo" "$priority" "$notes"
}

fl_bundle_apps() {
  local bundle="$1" file
  file="$(fl_config_file app-bundles.tsv)"
  awk -F '\t' -v b="$bundle" 'NR > 1 && $1 == b {print $3; exit}' "$file"
}

fl_list_bundles() {
  awk -F '\t' 'NR == 1 {next} {printf "  %-14s %-24s %s\n", $1, $2, $4}' "$(fl_config_file app-bundles.tsv)"
}

fl_resolve_selected_apps() {
  local profile="$1" bundle="$2" raw_apps="${3:-}"
  local app apps policy repo branch priority notes
  FL_SELECTED_APPS=()
  FL_INSTALL_SPECS=()

  if [[ -n "$raw_apps" ]]; then
    apps="$raw_apps"
  else
    apps="$(fl_bundle_apps "$bundle")"
  fi
  [[ -n "$apps" ]] || fl_die "Unknown app bundle: ${bundle}" "Run with APP_BUNDLE=minimal, common, extended, or APPS=\"erpnext\"."

  for app in $apps; do
    FL_SELECTED_APPS+=("$app")
    if policy="$(fl_lookup_app_policy "$app" "$profile")"; then
      IFS='|' read -r branch repo priority notes <<<"$policy"
    else
      branch=""
      repo=""
      priority="999"
      notes="custom app"
    fi
    FL_INSTALL_SPECS+=("${app}|${branch}|${repo}|${priority}|${notes}")
  done
}

fl_validate_app_refs_online() {
  local spec app branch repo _priority _notes
  for spec in "${FL_INSTALL_SPECS[@]}"; do
    IFS='|' read -r app branch repo _priority _notes <<<"$spec"
    [[ -n "$repo" && -n "$branch" ]] || continue
    if ! fl_repo_ref_exists "$repo" "$branch"; then
      fl_die "Branch/tag '${branch}' not found for ${app}." "Cannot access ${repo} at ${branch}. Check the app repo, choose another bundle, or run with APPS=\"erpnext\" for the minimal setup."
    fi
  done
}

fl_update_cache_file() {
  date "+${FL_STATE_DIR}/update-check.%Y%m%d.txt"
}

fl_print_newest_update_cache() {
  local newest
  # shellcheck disable=SC2012
  newest="$(ls -t "${FL_STATE_DIR}"/update-check.*.txt 2>/dev/null | head -n1 || true)"
  if [[ -n "$newest" ]]; then
    fl_warn "Offline mode: printing newest cached update check from ${newest}"
    cat "$newest"
  else
    fl_warn "Offline mode: no cached update check found."
  fi
}

fl_check_updates() {
  local cache frappe_heads erpnext_heads default_profile default_support max_support max_profile
  mkdir -p "${FL_STATE_DIR}"
  cache="$(fl_update_cache_file)"
  if [[ "${OFFLINE:-0}" == "1" ]]; then
    fl_print_newest_update_cache
    return 0
  fi

  frappe_heads="$(git ls-remote --heads https://github.com/frappe/frappe 'version-*' 2>/dev/null | awk -F/ '{print $NF}' | sort -u | tr '\n' ' ')"
  erpnext_heads="$(git ls-remote --heads https://github.com/frappe/erpnext 'version-*' 2>/dev/null | awk -F/ '{print $NF}' | sort -u | tr '\n' ' ')"
  {
    printf 'Known local profiles:\n'
    fl_list_profiles
    printf '\nRemote version branches found:\n'
    printf '  frappe: %s\n' "${frappe_heads:-unknown}"
    printf '  erpnext: %s\n' "${erpnext_heads:-unknown}"
  } | tee "$cache"

  default_profile="$(fl_default_profile)"
  default_support="$(awk -F '\t' -v p="$default_profile" 'NR > 1 && $1 == p {print $12; exit}' "$(fl_config_file release-profiles.tsv)")"
  max_support="$default_support"
  max_profile="$default_profile"
  while IFS=$'\t' read -r profile _label _fb _eb _pf _pb _nf _nm _mf _mm _status support _default; do
    [[ "$profile" == "profile" ]] && continue
    if [[ "$support" > "$max_support" ]]; then
      max_support="$support"
      max_profile="$profile"
    fi
  done <"$(fl_config_file release-profiles.tsv)"
  if [[ "$max_profile" != "$default_profile" ]]; then
    fl_warn "${max_profile} is available and has a later public support window than ${default_profile}."
    fl_warn "v15-lts remains the conservative default; use newer profiles only when you intentionally want them."
  fi
}
