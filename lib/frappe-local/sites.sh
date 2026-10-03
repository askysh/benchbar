#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# sites.sh: the sites of a bench.
#
#   benchbar site list [--json]    every site, the default marked
#   benchbar site add NAME         bench new-site, the hosts line, optional apps
#   benchbar site default NAME     the site benchup waits for and the app opens
#   benchbar site hosts            a hosts line for every site
#   benchbar site backup|backups|drop   see site-backups.sh
#
# The default site is the one benchbar remembers for the bench (its state
# file), which "site default" keeps in step with currentsite.txt through
# "bench use". benchup's wait, the runner's ping and status all use it.

# Every site folder of the bench (it has a site_config.json), sorted. The
# glob is in bash; sort runs only for two or more sites, since a glob's
# order differs from sort's in a UTF-8 locale (upper and lower case).
fl_sites_list() {
  local d names=()
  for d in "${FL_BENCH_DIR}"/sites/*/site_config.json; do
    [[ -f "$d" ]] || continue
    d="${d%/site_config.json}"
    names+=("${d##*/}")
  done
  case "${#names[@]}" in
    0) ;;
    1) printf '%s\n' "${names[0]}" ;;
    *) printf '%s\n' "${names[@]}" | sort ;;
  esac
}

# fl_site_ping_code_for SITE: HTTP code of the ping with SITE as Host, 000
# when nothing answers. Nothing is tried when no one listens on the web port,
# so a stopped bench costs no timeouts.
fl_site_ping_code_for() {
  if [[ -z "$(fl_port_listener_pid "$FL_WEB_PORT")" ]]; then printf '000'; return 0; fi
  fl_site_curl_code "$1" 3
}

# fl_site_curl_code SITE SECONDS: one ping with SITE as Host, 000 when nothing answers
fl_site_curl_code() {
  local code
  code="$(curl -s -o /dev/null -m "$2" -w '%{http_code}' -H "Host: $1" "http://127.0.0.1:${FL_WEB_PORT}/api/method/ping" 2>/dev/null || true)"
  case "$code" in [0-9][0-9][0-9]) printf '%s' "$code" ;; *) printf '000' ;; esac
}

# A "127.0.0.1 ... NAME" line in the hosts file, read in bash (list and
# status ask this for every site).
fl_hosts_has_name() {
  local re line
  re="^[[:space:]]*127\\.0\\.0\\.1[[:space:]]+(.*[[:space:]])?${1//./\\.}([[:space:]]|\$)"
  [[ -f "$FL_HOSTS_FILE" && -r "$FL_HOSTS_FILE" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ $re ]] && return 0
  done <"$FL_HOSTS_FILE"
  return 1
}

# fl_sites_json_v VAR [PINGS] [DB]: [{"name":..,"default":..,"hosts_entry":..,"ping_code":..}]
#   none  ping_code null (list; status without --ping), no lsof, no curl
#   ask   one curl per site; the default site reuses FL_DEFAULT_PING when set (status --ping)
#   ping  one curl per site when something listens on the web port (site list)
# DB=1 (site list) adds db_name (from the site's site_config.json, null when
# missing) and db_port (the site's, else the bench's, else 3306); never the
# password. list and status leave them out: they poll.
FL_DEFAULT_PING=""
fl_sites_json_v() {
  local __mode="${2:-none}" __db="${3:-0}" __out="[" __sep="" __s __ping __listening=1 __jn __jd __jh __jp __def __hosts __dbn __dbp __dbj __bench_port
  if [[ "$__mode" == "ping" && -z "$(fl_port_listener_pid "$FL_WEB_PORT")" ]]; then __listening=0; fi
  if [[ "$__db" == "1" ]]; then fl_site_config_value_v __bench_port db_port; fi
  while IFS= read -r __s; do
    [[ -n "$__s" ]] || continue
    __ping=""
    if [[ "$__mode" == "ask" || ( "$__mode" == "ping" && "$__listening" == "1" ) ]]; then
      if [[ "$__s" == "$FL_SITE" && -n "$FL_DEFAULT_PING" ]]; then __ping="$FL_DEFAULT_PING"; else __ping="$(fl_site_curl_code "$__s" 3)"; fi
      [[ "$__ping" == "000" ]] && __ping=""
    fi
    __def=0; [[ "$__s" == "$FL_SITE" ]] && __def=1
    __hosts=0; fl_hosts_has_name "$__s" && __hosts=1
    fl_json_str_v __jn "$__s"; fl_json_bool_v __jd "$__def"; fl_json_bool_v __jh "$__hosts"; fl_json_num_v __jp "$__ping"
    __dbj=""
    if [[ "$__db" == "1" ]]; then
      fl_site_file_value_v __dbn "${FL_BENCH_DIR}/sites/${__s}/site_config.json" db_name
      fl_site_file_value_v __dbp "${FL_BENCH_DIR}/sites/${__s}/site_config.json" db_port
      [[ "$__dbp" =~ ^[0-9]+$ ]] || __dbp="$__bench_port"
      [[ "$__dbp" =~ ^[0-9]+$ ]] || __dbp=3306
      fl_json_str_v __dbn "$__dbn"
      __dbj=",\"db_name\":${__dbn},\"db_port\":${__dbp}"
    fi
    __out="${__out}${__sep}{\"name\":${__jn},\"default\":${__jd},\"hosts_entry\":${__jh},\"ping_code\":${__jp}${__dbj}}"
    __sep=","
  done < <(fl_sites_list)
  printf -v "$1" '%s]' "$__out"
}

# fl_site_file_value_v VAR FILE KEY: KEY's raw value from a site_config.json,
# read a line at a time like common_site_config.json; empty when missing
fl_site_file_value_v() {
  local __line __v=""
  if [[ -f "$2" && -r "$2" ]]; then
    while IFS= read -r __line || [[ -n "$__line" ]]; do
      [[ "$__line" =~ $FL_SCC_LINE_RE && "${BASH_REMATCH[1]}" == "$3" ]] && { __v="${BASH_REMATCH[2]}"; break; }
    done <"$2"
  fi
  printf -v "$1" '%s' "$__v"
}

# fl_sites_json [PINGS]: the same, printed, with the database name and port; site list asks every site
fl_sites_json() { local j; fl_sites_json_v j "${1:-ping}" 1; printf '%s' "$j"; }

# fl_site_name_ok NAME: lowercase letters, digits, '-' and '.', starting
# with a letter or digit; what a hosts line and a runner can carry
fl_site_name_ok() { [[ "$1" =~ ^[a-z0-9][a-z0-9.-]*$ ]]; }
fl_site_valid_name() {
  fl_site_name_ok "$1" || fl_die "Invalid site name: '$1'." "Use lowercase letters, digits, '-' and '.' only."
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
  for n in "$@"; do
    # a folder name that is not a site name never reaches the hosts file (or sudo)
    if ! fl_site_name_ok "$n"; then fl_warn "skipped sites/${n}: not a valid site name (lowercase letters, digits, '-' and '.' only); no hosts line for it"; continue; fi
    fl_hosts_has_name "$n" || missing+=("$n")
  done
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
  fl_require_plain_bench
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
  fl_require_plain_bench
  [[ -n "$name" ]] || fl_die "Usage: benchbar site add NAME [--bundle NAME | --apps \"app1 app2\"]"
  fl_site_valid_name "$name"
  [[ -n "$bundle" && -z "$apps" ]] && { apps="$(fl_bundle_apps "$bundle")"; [[ -n "$apps" ]] || fl_die "Unknown app bundle: ${bundle}"; }
  for app in $apps; do
    [[ -d "${FL_BENCH_DIR}/apps/${app}" ]] || fl_die "${app} is not in ${FL_BENCH_DIR}/apps." "Get it first: cd ${FL_BENCH_DIR} && bench get-app ${app}"
  done
  fl_header "benchbar site add" "$(fl_mode_name)" "$FL_PROFILE" "$FL_BENCH_DIR" "$name"
  if fl_site_incomplete "$FL_BENCH_DIR" "$name"; then return 1; fi
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
    fl_bench_redis_up "$FL_BENCH_DIR"
    fl_new_site_if_needed "$FL_BENCH_DIR" "$name" "$FL_MARIADB_ROOT_PW" "$ADMIN_PASSWORD" || { fl_bench_redis_down; return 1; }
  fi
  [[ -n "$apps" && -z "$FL_SETUP_REDIS_PORTS" ]] && fl_bench_redis_up "$FL_BENCH_DIR"
  for app in $apps; do
    fl_install_app_if_needed "$FL_BENCH_DIR" "$name" "$app"
  done
  fl_bench_redis_down
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
    backup) fl_cmd_site_backup "$@" ;;
    backups) fl_cmd_site_backups "$@" ;;
    drop) fl_cmd_site_drop "$@" ;;
    *) fl_die "Unknown site command: ${sub}" "Use: benchbar site list | add NAME | default NAME | hosts | backup NAME | backups NAME | drop NAME" ;;
  esac
}
