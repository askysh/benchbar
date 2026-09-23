#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# benchinfo.sh: find the bench, the site and the ports without asking.
#
# Resolution order for the bench directory:
#   --bench-dir flag, BENCH_DIR env, state.env, auto-detected, default.

FL_BENCH_DIR="${FL_BENCH_DIR:-}"
FL_BENCH_NAME=""
FL_BENCH_SOURCE=""
FL_SITE="${FL_SITE:-}"
FL_SITE_SOURCE=""
FL_WEB_PORT=8000
FL_SOCKETIO_PORT=9000
FL_REDIS_CACHE_PORT=13000
FL_REDIS_QUEUE_PORT=11000

fl_abs_path() {
  local p="$1"
  case "$p" in
    /*) ;;
    '~'|'~/'*) p="${HOME}${p#'~'}" ;;
    *) p="${PWD}/${p}" ;;
  esac
  # collapse a trailing slash
  printf '%s' "${p%/}"
}

fl_is_bench_dir() {
  local d="$1"
  [[ -d "$d" ]] || return 1
  [[ -f "$d/sites/common_site_config.json" || -d "$d/apps/frappe" ]]
}

fl_bench_candidates() {
  local d
  printf '%s\n' "$HOME/frappe-bench" "$HOME/dev/frappe-bench" "${SCRIPT_DIR}/frappe-bench"
  for d in "$HOME"/*/sites/common_site_config.json "$HOME"/dev/*/sites/common_site_config.json; do
    [[ -f "$d" ]] || continue
    printf '%s\n' "${d%/sites/common_site_config.json}"
  done
}

fl_bench_detect() {
  local flag="${1:-}" state cand
  if [[ -n "$flag" ]]; then
    FL_BENCH_DIR="$(fl_abs_path "$flag")"; FL_BENCH_SOURCE="flag"
  elif [[ -n "${BENCH_DIR:-}" ]]; then
    FL_BENCH_DIR="$(fl_abs_path "$BENCH_DIR")"; FL_BENCH_SOURCE="env"
  else
    state="$(fl_state_get BENCH_DIR 2>/dev/null || true)"
    if [[ -n "$state" && -d "$state" ]]; then
      FL_BENCH_DIR="$(fl_abs_path "$state")"; FL_BENCH_SOURCE="state"
    else
      FL_BENCH_DIR=""
      while IFS= read -r cand; do
        [[ -n "$cand" ]] || continue
        if fl_is_bench_dir "$cand"; then FL_BENCH_DIR="$cand"; FL_BENCH_SOURCE="detected"; break; fi
      done < <(fl_bench_candidates)
      if [[ -z "$FL_BENCH_DIR" ]]; then
        FL_BENCH_DIR="$HOME/frappe-bench"; FL_BENCH_SOURCE="default"
      fi
    fi
  fi
  FL_BENCH_NAME="$(basename "$FL_BENCH_DIR" | tr -c 'A-Za-z0-9._-\n' '-')"
}

fl_site_config_value() {
  # fl_site_config_value KEY -> raw JSON value (string without quotes or number)
  local key="$1" file="${FL_BENCH_DIR}/sites/common_site_config.json"
  [[ -f "$file" ]] || return 0
  sed -n "s/^[[:space:]]*\"${key}\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}[[:space:]]*$/\1/p" "$file" | head -n1
}

fl_site_detect() {
  local flag="${1:-}" state d
  if [[ -n "$flag" ]]; then
    FL_SITE="$flag"; FL_SITE_SOURCE="flag"; return 0
  fi
  if [[ -n "${SITE_NAME:-}" ]]; then
    FL_SITE="$SITE_NAME"; FL_SITE_SOURCE="env"; return 0
  fi
  # the remembered site belongs to the remembered bench only
  state="$(fl_state_get SITE_NAME 2>/dev/null || true)"
  if [[ -n "$state" && "$(fl_state_get BENCH_DIR 2>/dev/null || true)" == "$FL_BENCH_DIR" ]]; then
    FL_SITE="$state"; FL_SITE_SOURCE="state"; return 0
  fi
  if [[ -f "${FL_BENCH_DIR}/sites/currentsite.txt" ]]; then
    FL_SITE="$(tr -d '[:space:]' <"${FL_BENCH_DIR}/sites/currentsite.txt")"
    [[ -n "$FL_SITE" ]] && { FL_SITE_SOURCE="currentsite"; return 0; }
  fi
  FL_SITE="$(fl_site_config_value default_site)"
  [[ -n "$FL_SITE" ]] && { FL_SITE_SOURCE="common_site_config"; return 0; }
  for d in "${FL_BENCH_DIR}"/sites/*/site_config.json; do
    [[ -f "$d" ]] || continue
    FL_SITE="$(basename "$(dirname "$d")")"; FL_SITE_SOURCE="detected"; return 0
  done
  FL_SITE="macdev"; FL_SITE_SOURCE="default"
}

fl_ports_detect() {
  local v
  v="$(fl_site_config_value webserver_port)"; [[ "$v" =~ ^[0-9]+$ ]] && FL_WEB_PORT="$v"
  v="$(fl_site_config_value socketio_port)"; [[ "$v" =~ ^[0-9]+$ ]] && FL_SOCKETIO_PORT="$v"
  v="$(fl_site_config_value redis_cache)"; v="${v##*:}"; [[ "$v" =~ ^[0-9]+$ ]] && FL_REDIS_CACHE_PORT="$v"
  v="$(fl_site_config_value redis_queue)"; v="${v##*:}"; [[ "$v" =~ ^[0-9]+$ ]] && FL_REDIS_QUEUE_PORT="$v"
  return 0
}

fl_bench_ports_csv() {
  printf '%s,%s,%s,%s' "$FL_WEB_PORT" "$FL_SOCKETIO_PORT" "$FL_REDIS_QUEUE_PORT" "$FL_REDIS_CACHE_PORT"
}

FL_APP_BUNDLE_ID="com.akashmishra.benchbar"

fl_agent_label() {
  printf 'com.benchbar.%s' "$FL_BENCH_NAME"
}

# The label used by frappe-mac 0.2.0, migrated by "benchbar repair".
fl_agent_label_legacy() {
  printf 'com.frappe-mac.%s' "$FL_BENCH_NAME"
}

fl_agent_plist_path() {
  printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$(fl_agent_label)"
}

fl_launchd_domain() {
  printf 'gui/%s' "$(id -u)"
}

fl_runner_path() { printf '%s/frappe-mac-run.sh' "$FL_BENCH_DIR"; }
fl_procfile_path() { printf '%s/Procfile.lean' "$FL_BENCH_DIR"; }
fl_stop_flag_path() { printf '%s/logs/.bench-stopped' "$FL_BENCH_DIR"; }
fl_starts_path() { printf '%s/logs/.bench-starts' "$FL_BENCH_DIR"; }
fl_bench_log_path() { printf '%s/logs/bench.log' "$FL_BENCH_DIR"; }
