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
# SERVED=1 (status) adds "served": true, false (the web process answers 404 for
# the site's Host) or null (the bench is stopped, or nothing answered). The
# default site's answer and a --ping answer are reused; any other site gets one
# GET in bash (fl_http_code_v, a subshell, no other program), only while the bench
# runs and its default site answered, one second each within a shared 2 second budget.
FL_DEFAULT_PING=""
fl_sites_json_v() {
  local __mode="${2:-none}" __db="${3:-0}" __served="${4:-0}" __out="[" __sep="" __s __ping __listening=1 __jn __jd __jh __jp __def __hosts __dbn __dbp __dbj __bench_port __code __sv __sj __end __c
  if [[ "$__mode" == "ping" && -z "$(fl_port_listener_pid "$FL_WEB_PORT")" ]]; then __listening=0; fi
  if [[ "$__db" == "1" ]]; then fl_site_config_value_v __bench_port db_port; fi
  __end=$((SECONDS + 2))
  while IFS= read -r __s; do
    [[ -n "$__s" ]] || continue
    __ping=""; __code=""
    if [[ "$__mode" == "ask" && "${ST_PROCS:-1}" == "1" ]] || [[ "$__mode" == "ping" && "$__listening" == "1" ]]; then
      if [[ "$__s" == "$FL_SITE" && -n "$FL_DEFAULT_PING" ]]; then __ping="$FL_DEFAULT_PING"; else __ping="$(fl_site_curl_code "$__s" 3)"; fi
      __code="$__ping"
      [[ "$__ping" == "000" ]] && __ping=""
    fi
    __sj=""
    if [[ "$__served" == "1" ]]; then
      __sv=null
      if [[ "${ST_PROCS:-0}" == "1" ]]; then
        if [[ "$__s" == "$FL_SITE" && -n "$FL_DEFAULT_PING" ]]; then fl_site_served_v __sv "$__s" "$FL_DEFAULT_PING"
        elif [[ "$__mode" == "ask" ]]; then fl_site_served_v __sv "$__s" "$__code"
        elif [[ -n "$FL_DEFAULT_PING" && "$FL_DEFAULT_PING" != "000" && "$SECONDS" -lt "$__end" ]]; then
          # the web process answers the default site: ask the others, one second
          # each, within one shared budget (what is left stays null)
          fl_http_code_v __c "$__s" "$FL_WEB_PORT" /api/method/ping 1
          fl_site_served_v __sv "$__s" "$__c"
        fi
      fi
      __sj=",\"served\":${__sv}"
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
    __out="${__out}${__sep}{\"name\":${__jn},\"default\":${__jd},\"hosts_entry\":${__jh},\"ping_code\":${__jp}${__sj}${__dbj}}"
    __sep=","
  done < <(fl_sites_list)
  printf -v "$1" '%s]' "$__out"
}

# fl_site_served_v VAR SITE [CODE]: "true", "false" or "null" for whether the
# bench's web process serves SITE. CODE is a ping answer already at hand
# (empty or 000: nothing answered); without it SITE is asked once, in bash.
# Frappe answers 404 for a Host it has no site folder for, so 404 is the one
# code that says "not served"; every other answer (500 included) is a site
# that is served, however badly. Callers ask only while the bench runs.
fl_site_served_v() {
  local __c="${3:-}"
  if [[ "$#" -lt 3 ]]; then fl_http_code_v __c "$2" "$FL_WEB_PORT" /api/method/ping 2; fi
  case "$__c" in
    404) printf -v "$1" '%s' false ;;
    ""|000) printf -v "$1" '%s' null ;;
    *) printf -v "$1" '%s' true ;;
  esac
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
    printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"default_site":%s,"sites":%s}\n' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$FL_SITE")" "$(fl_sites_json)"
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
  # BENCHBAR_SUDO=gui: every line in one dialog
  if fl_sudo_gui && [[ "${FL_DRY_RUN:-0}" != "1" ]]; then
    fl_hosts_add_gui "${missing[@]}" || code=1
    return "$code"
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
  if [[ "$name" == "$FL_SITE" && "$({ tr -d '[:space:]' <"${FL_BENCH_DIR}/sites/currentsite.txt"; } 2>/dev/null)" == "$name" ]]; then
    fl_ok "unchanged: ${name} is already the default site"
    fl_site_result_doc 0 "$name" false
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
  fl_changed site "$name" "now the default site"
  fl_ok "default site is ${name}: $(fl_site_url)"
  fl_site_result_doc 0 "$name" false
}

# fl_site_result_doc CODE NAME CREATED: the document of a site command's
# stream (the done line merges it): the site and the bench's default site
# after the run, which only "site default" ever moves
fl_site_result_doc() {
  [[ "${FL_JSONL:-0}" == "1" ]] || return 0
  fl_doc_emit "$1" "$(printf '{"schema_version":%d,"cli_version":"%s","bench":%s,"site":%s,"default_site":%s,"created":%s}' \
    "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$2")" "$(fl_json_str "$FL_SITE")" "$(fl_json_bool "$3")")"
}

# fl_site_default_file_v VAR: the default site as bench has it (currentsite.txt)
fl_site_default_file_v() {
  local __v=""
  if [[ -r "${FL_BENCH_DIR}/sites/currentsite.txt" ]]; then IFS= read -r -d '' __v <"${FL_BENCH_DIR}/sites/currentsite.txt" || true; fi
  printf -v "$1" '%s' "${__v//[[:space:]]/}"
}

# fl__site_apps_json "a b": the space separated app names as a JSON array
fl__site_apps_json() {
  local a out="" sep=""
  for a in $1; do out="${out}${sep}$(fl_json_str "$a")"; sep=","; done
  printf '[%s]' "$out"
}

# fl_site_add_plan NAME APPS: the plan of a site add, read only. Sets SA_JSON
# (one document with its token) and SA_TOKEN. The token is a hash of the
# plan and of the bench's site list, apps.txt and default site, so a site
# that appeared or a default that moved since makes it stale.
fl_site_add_plan() {
  local name="$1" apps="$2" exists=0 app steps="" sep="" touches="" default state body hosts=0
  fl_site_default_file_v default
  [[ -d "${FL_BENCH_DIR}/sites/${name}" ]] && exists=1
  if [[ "$exists" == "0" ]]; then
    steps="{\"kind\":\"new_site\",\"name\":$(fl_json_str "Create ${name}"),\"command\":$(fl_json_str "bench new-site ${name} (with the MariaDB root password benchbar keeps; it is never shown)")}"; sep=","
    touches="\"database\",\"site_folder\""
  fi
  for app in $apps; do
    # a new site has none; an existing one is asked from the last list-apps read
    if [[ "$exists" == "1" ]] && fl_site_has_app "$name" "$app" 2>/dev/null; then continue; fi
    steps="${steps}${sep}{\"kind\":\"install\",\"name\":$(fl_json_str "Install ${app}"),\"command\":$(fl_json_str "bench --site ${name} install-app ${app}")}"; sep=","
    case ",${touches}," in *'"database"'*) ;; *) touches="${touches}${touches:+,}\"database\"" ;; esac
  done
  if ! fl_hosts_has_name "$name" 2>/dev/null; then
    hosts=1
    if ! fl_is_linux; then
      steps="${steps}${sep}{\"kind\":\"hosts\",\"name\":$(fl_json_str "Add 127.0.0.1 ${name} to ${FL_HOSTS_FILE}"),\"command\":$(fl_json_str "benchbar site hosts (sudo)")}"; sep=","
      touches="${touches}${touches:+,}\"hosts\""
    fi
  fi
  body="$(printf '"bench":%s,"site":%s,"exists":%s,"apps":%s,"default_site":%s,"default_moves":false,"backup":null,"hosts_entry":%s,"steps":[%s],"touches":[%s],"changes":%s' \
    "$(fl_json_str "$FL_BENCH_DIR")" "$(fl_json_str "$name")" "$(fl_json_bool "$exists")" "$(fl__site_apps_json "$apps")" \
    "$(fl_json_str "$default")" "$(fl_json_bool "$([[ "$hosts" == "0" ]] && printf 1 || printf 0)")" "$steps" "$touches" "$(fl_json_bool "$([[ -n "$steps" ]] && printf 1 || printf 0)")")"
  state="$(printf 'sites\n%s\napps.txt\n%s\ndefault\n%s\n' "$(fl_sites_list)" "$(fl_apps_txt 2>/dev/null)" "$default")"
  SA_TOKEN="$(printf '%s\n%s\n' "$body" "$state" | shasum -a 256 | awk '{print $1}')"
  SA_JSON="$(printf '{"schema_version":%d,"cli_version":"%s","dry_run":true,%s,"token":"%s"}' "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "$body" "$SA_TOKEN")"
}

# site add NAME [--bundle B | --apps "a b"]: a new site on the bench's
# MariaDB with the Keychain password, its hosts line, and apps that are
# already in apps/. The default site does not change. --dry-run --json is
# the plan with its token; --apply TOKEN --yes runs it, refused when stale.
fl_cmd_site_add() {
  local name="" apps="" bundle="${OPT_BUNDLE:-}" app created=false default_before default_after code msg token="" apply=0
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --apps) apps="${2:-}"; shift 2 ;;
      --apps=*) apps="${1#*=}"; shift ;;
      --bundle) bundle="${2:-}"; shift 2 ;;
      --bundle=*) bundle="${1#*=}"; shift ;;
      --apply) apply=1; token="${2:-}"; shift 2 || shift ;;
      --apply=*) apply=1; token="${1#*=}"; shift ;;
      -*) fl_die "Unknown option for site add: $1" ;;
      *) [[ -z "$name" ]] && name="$1"; shift ;;
    esac
  done
  fl_require_bench
  fl_require_plain_bench
  [[ -n "$name" ]] || fl_die "Usage: benchbar site add NAME [--bundle NAME | --apps \"app1 app2\"]"
  fl_site_valid_name "$name"
  if [[ "$apply" == "1" ]]; then
    [[ "$token" =~ ^[0-9a-f]{64}$ ]] || fl_die "--apply needs the token of a plan." "benchbar site add ${name} --dry-run --json prints it"
    [[ "${FL_DRY_RUN:-0}" != "1" ]] || fl_die "--apply runs the plan; --dry-run shows it. Pass one of them."
    [[ "${FL_ASSUME_YES:-0}" == "1" ]] || fl_die "Review the plan (site add ${name} --dry-run --json), then pass its token with --apply TOKEN --yes."
  fi
  # the plan: a dry run with --json prints it (one document, the text on
  # stderr); --apply compares its token first
  [[ "$apply" == "1" || "${FL_DRY_RUN:-0}" != "1" || "$OPT_JSON" != "1" ]] || fl_json_doc_begin
  if [[ "$apply" == "1" || ( "${FL_DRY_RUN:-0}" == "1" && "$OPT_JSON" == "1" ) ]]; then
    [[ -n "$bundle" && -z "$apps" ]] && { apps="$(fl_bundle_apps "$bundle")"; [[ -n "$apps" ]] || fl_die "Unknown app bundle: ${bundle}"; }
    # the same refusal as the run itself, before a plan that could not apply
    for app in $apps; do
      [[ -d "${FL_BENCH_DIR}/apps/${app}" ]] || fl_die "${app} is not in ${FL_BENCH_DIR}/apps." "Get it first: cd ${FL_BENCH_DIR} && bench get-app ${app}"
    done
    fl_site_add_plan "$name" "$apps"
    if [[ "$apply" == "0" ]]; then
      fl_doc_emit 0 "$SA_JSON" plan
      return 0
    fi
    [[ "$token" == "$SA_TOKEN" ]] || fl_die "The site add plan changed since it was shown (the sites, apps.txt or the default site). Nothing was changed." \
      "Review a fresh plan: benchbar site add ${name} --dry-run --json, then pass its token."
  fi
  # the Administrator password of a new site is the first thing asked for:
  # a run that cannot ask says so before it checks anything else
  if [[ ! -d "${FL_BENCH_DIR}/sites/${name}" && -z "${ADMIN_PASSWORD:-}" && "${FL_DRY_RUN:-0}" != "1" ]]; then
    if [[ "${FL_ASSUME_YES:-0}" == "1" || ! -t 0 ]] || fl_noninteractive; then
      # exit 2 when the MariaDB root password is unknown too (AGENTS.md), whatever the mode
      code=1
      [[ -n "${MARIADB_ROOT_PASSWORD:-}" || -n "$(fl_keychain_get 2>/dev/null || true)" ]] || code=2
      msg="The Administrator password for ${name} is needed."
      [[ "$code" != "2" ]] || msg="${msg} The MariaDB root password is unknown too."
      fl_die "$msg" "Re-run with: ADMIN_PASSWORD='...' MARIADB_ROOT_PASSWORD='...' benchbar site add ${name} --yes" "$code"
    fi
  fi
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
      else fl_ask_secret ADMIN_PASSWORD "Administrator password for ${name}"; fi
    fi
    fl_bench_env_exports
    fl_bench_redis_up "$FL_BENCH_DIR"
    fl_site_default_file_v default_before
    fl_new_site_if_needed "$FL_BENCH_DIR" "$name" "$FL_MARIADB_ROOT_PW" "$ADMIN_PASSWORD" || { fl_bench_redis_down; return 1; }
    # a dry run creates nothing (its done line says dry_run)
    [[ "${FL_DRY_RUN:-0}" == "1" ]] || created=true
    # a new site never becomes the default: if bench moved it, it goes back
    fl_site_default_file_v default_after
    if [[ "${FL_DRY_RUN:-0}" != "1" && "$default_after" != "$default_before" ]]; then
      if [[ -z "$default_before" ]]; then
        fl_warn "bench set the default site to ${default_after}; the bench had none before, so nothing is put back"
      else
        fl_warn "bench moved the default site to ${default_after}; putting it back to ${default_before}"
        (cd "$FL_BENCH_DIR" && bench use "$default_before") >>"${FL_LOG_FILE:-/dev/null}" 2>&1 || true
        fl_site_default_file_v default_after
        # what bench says (currentsite.txt) is compared with what it said before; the
        # remembered site is the user's own business (a "bench use other" is fine)
        if [[ "$default_after" != "$default_before" ]]; then
          fl_fail "could not put the default site back to ${default_before} (currentsite.txt says ${default_after:-nothing})"
          fl_fix "cd ${FL_BENCH_DIR} && bench use ${default_before}"
          return 1
        fi
      fi
    fi
  fi
  [[ -n "$apps" && -z "$FL_SETUP_REDIS_PORTS" ]] && fl_bench_redis_up "$FL_BENCH_DIR"
  for app in $apps; do
    fl_install_app_if_needed "$FL_BENCH_DIR" "$name" "$app"
  done
  fl_bench_redis_down
  fl_hosts_add_names "$name"
  fl_ok "site ${name}: http://${name}:${FL_WEB_PORT} (the default site stays ${FL_SITE}; benchbar site default ${name} changes it)"
  fl_site_result_doc 0 "$name" "$created"
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
    restore) fl_cmd_site_restore "$@" ;;
    drop) fl_cmd_site_drop "$@" ;;
    *) fl_die "Unknown site command: ${sub}" "Use: benchbar site list | add NAME | default NAME | hosts | backup NAME | backups NAME | restore NAME | drop NAME" ;;
  esac
}
