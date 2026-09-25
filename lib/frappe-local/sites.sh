#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# sites.sh: the sites of a bench.
#
#   benchbar site list [--json]    every site, the default marked
#   benchbar site add NAME         bench new-site, the hosts line, optional apps
#   benchbar site default NAME     the site benchup waits for and the app opens
#   benchbar site hosts            a hosts line for every site
#
# The default site is the one benchbar remembers for the bench (its state
# file), which "site default" keeps in step with currentsite.txt through
# "bench use". benchup's wait, the runner's ping and status all use it.

# Every site folder of the bench (it has a site_config.json), sorted.
fl_sites_list() {
  local d
  for d in "${FL_BENCH_DIR}"/sites/*/site_config.json; do
    [[ -f "$d" ]] || continue
    basename "$(dirname "$d")"
  done | sort
}

# fl_site_ping_code_for SITE: HTTP code of the ping with SITE as Host, 000
# when nothing answers. Nothing is tried when no one listens on the web port,
# so a stopped bench costs no timeouts.
fl_site_ping_code_for() {
  local code
  if [[ -z "$(fl_port_listener_pid "$FL_WEB_PORT")" ]]; then printf '000'; return 0; fi
  code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' -H "Host: $1" "http://127.0.0.1:${FL_WEB_PORT}/api/method/ping" 2>/dev/null || true)"
  case "$code" in [0-9][0-9][0-9]) printf '%s' "$code" ;; *) printf '000' ;; esac
}

fl_hosts_has_name() {
  local re
  re="$(printf '%s' "$1" | sed 's/\./\\./g')"
  grep -qE "^[[:space:]]*127\.0\.0\.1[[:space:]]+(.*[[:space:]])?${re}([[:space:]]|$)" "$FL_HOSTS_FILE" 2>/dev/null
}

# [{"name":..,"default":..,"hosts_entry":..,"ping_code":..}] for list and status
fl_sites_json() {
  local s sep="" ping
  printf '['
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    ping="$(fl_site_ping_code_for "$s")"; [[ "$ping" == "000" ]] && ping=""
    printf '%s{"name":%s,"default":%s,"hosts_entry":%s,"ping_code":%s}' "$sep" "$(fl_json_str "$s")" \
      "$(fl_json_bool "$([[ "$s" == "$FL_SITE" ]] && printf 1 || printf 0)")" \
      "$(fl_json_bool "$(fl_hosts_has_name "$s" && printf 1 || printf 0)")" "$(fl_json_num "$ping")"
    sep=","
  done < <(fl_sites_list)
  printf ']'
}

fl_site_valid_name() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || fl_die "Invalid site name: '$1'." "Use lowercase letters, digits, '-' and '.' only."
}

fl_site_require() {
  [[ -f "${FL_BENCH_DIR}/sites/$1/site_config.json" ]] || fl_die "No site '$1' in ${FL_BENCH_DIR}." "Sites: $(fl_sites_list | tr '\n' ' ')"
}

fl_cmd_site_list() {
  local json="$1" s rows=()
  fl_require_bench
  if [[ "$json" == "1" ]]; then
    printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"sites":%s}\n' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_sites_json)"
    return 0
  fi
  rows+=("Site|Default|Hosts|URL")
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    rows+=("${s}|$([[ "$s" == "$FL_SITE" ]] && printf yes)|$(fl_hosts_has_name "$s" && printf ok || printf missing)|http://${s}:${FL_WEB_PORT}")
  done < <(fl_sites_list)
  fl_table "${rows[@]}"
}

# fl_hosts_add_names NAME...: the hosts lines that are missing, after one
# question and one sudo prompt for all of them.
fl_hosts_add_names() {
  local n missing=() site_saved="$FL_SITE" code=0
  for n in "$@"; do fl_hosts_has_name "$n" || missing+=("$n"); done
  if [[ "${#missing[@]}" == "0" ]]; then fl_ok "unchanged: ${FL_HOSTS_FILE} maps every site to 127.0.0.1"; return 0; fi
  if [[ "${FL_DRY_RUN:-0}" != "1" ]] && ! fl_confirm "Add ${missing[*]} to ${FL_HOSTS_FILE} with sudo?"; then
    fl_warn "skipped; run: benchbar site hosts --bench-dir ${FL_BENCH_DIR}"
    return 0
  fi
  for n in "${missing[@]}"; do
    FL_SITE="$n"
    FL_ASSUME_YES=1 act_hosts_entry || code=1
  done
  FL_SITE="$site_saved"
  return "$code"
}

fl_cmd_site_hosts() {
  local sites=()
  fl_require_bench
  while IFS= read -r s; do [[ -n "$s" ]] && sites+=("$s"); done < <(fl_sites_list)
  [[ "${#sites[@]}" -gt 0 ]] || { fl_info "no sites in ${FL_BENCH_DIR}"; return 0; }
  fl_hosts_add_names "${sites[@]}"
}

# site default NAME: bench use (currentsite.txt), the remembered site, and the
# runner, whose ping uses it. The processes keep running.
fl_cmd_site_default() {
  local name="$1"
  fl_require_bench
  [[ -n "$name" ]] || fl_die "Usage: benchbar site default NAME"
  fl_site_require "$name"
  if [[ "$name" == "$FL_SITE" && "$(tr -d '[:space:]' <"${FL_BENCH_DIR}/sites/currentsite.txt" 2>/dev/null)" == "$name" ]]; then
    fl_ok "unchanged: ${name} is already the default site"
    return 0
  fi
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: cd ${FL_BENCH_DIR} && bench use ${name}; remember ${name} and rewrite the runner"
    return 0
  fi
  fl_bench_env_exports
  (cd "$FL_BENCH_DIR" && bench use "$name") >>"${FL_LOG_FILE:-/dev/null}" 2>&1 || fl_die "bench use ${name} failed." "Run: cd ${FL_BENCH_DIR} && bench use ${name}"
  FL_SITE="$name"
  fl_bstate_set SITE_NAME "$name"
  fl_render_all
  act_write_runner
  fl_ok "default site is ${name}: $(fl_site_url)"
}

# site add NAME [--bundle B | --apps "a b"]: a new site on the bench's
# MariaDB with the Keychain password, its hosts line, and apps that are
# already in apps/. The default site does not change.
fl_cmd_site_add() {
  local name="" apps="" bundle="${OPT_BUNDLE:-}" app
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --apps) apps="${2:-}"; shift 2 ;;
      --apps=*) apps="${1#*=}"; shift ;;
      --bundle) bundle="${2:-}"; shift 2 ;;
      --bundle=*) bundle="${1#*=}"; shift ;;
      -*) fl_die "Unknown option for site add: $1" ;;
      *) [[ -z "$name" ]] && name="$1"; shift ;;
    esac
  done
  fl_require_bench
  [[ -n "$name" ]] || fl_die "Usage: benchbar site add NAME [--bundle NAME | --apps \"app1 app2\"]"
  fl_site_valid_name "$name"
  [[ -n "$bundle" && -z "$apps" ]] && { apps="$(fl_bundle_apps "$bundle")"; [[ -n "$apps" ]] || fl_die "Unknown app bundle: ${bundle}"; }
  for app in $apps; do
    [[ -d "${FL_BENCH_DIR}/apps/${app}" ]] || fl_die "${app} is not in ${FL_BENCH_DIR}/apps." "Get it first: cd ${FL_BENCH_DIR} && bench get-app ${app}"
  done
  fl_header "benchbar site add" "$(fl_mode_name)" "$FL_PROFILE" "$FL_BENCH_DIR" "$name"
  if [[ -d "${FL_BENCH_DIR}/sites/${name}" ]]; then
    fl_ok "site ${name} already exists"
  else
    fl_mariadb_root_password_resolve || fl_die "MariaDB root password needed to create the site." "Re-run with: MARIADB_ROOT_PASSWORD='...' benchbar site add ${name}" 2
    if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
      if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then ADMIN_PASSWORD="dry-run-placeholder"
      elif [[ "${FL_ASSUME_YES:-0}" == "1" || ! -t 0 ]]; then fl_die "The Administrator password for ${name} is needed." "Re-run with: ADMIN_PASSWORD='...' benchbar site add ${name} --yes"
      else fl_ask_secret ADMIN_PASSWORD "Administrator password for ${name}"; fi
    fi
    fl_bench_env_exports
    fl_new_site_if_needed "$FL_BENCH_DIR" "$name" "$FL_MARIADB_ROOT_PW" "$ADMIN_PASSWORD"
  fi
  for app in $apps; do
    fl_install_app_if_needed "$FL_BENCH_DIR" "$name" "$app"
  done
  fl_hosts_add_names "$name"
  fl_ok "site ${name}: http://${name}:${FL_WEB_PORT} (the default site stays ${FL_SITE}; benchbar site default ${name} changes it)"
}

fl_cmd_site() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    list|"") fl_cmd_site_list "$OPT_JSON" ;;
    add) fl_cmd_site_add "$@" ;;
    default) fl_cmd_site_default "${1:-}" ;;
    hosts) fl_cmd_site_hosts ;;
    *) fl_die "Unknown site command: ${sub}" "Use: benchbar site list | add NAME | default NAME | hosts" ;;
  esac
}
