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
FL_BENCH_DIR_CANON=""
FL_SITE="${FL_SITE:-}"
FL_SITE_SOURCE=""
FL_WEB_PORT=8000
FL_SOCKETIO_PORT=9000
FL_REDIS_CACHE_PORT=13000
FL_REDIS_QUEUE_PORT=11000
FL_REDIS_SOCKETIO_PORT=""

fl_abs_path() {
  local p="$1"
  case "$p" in
    /*) ;;
    '~'|'~/'*) p="${HOME}${p#'~'}" ;;
    *) p="${PWD}/${p}" ;;
  esac
  # one spelling per bench: symlinks, "." and ".." resolved (fl_bench_canonical),
  # so state, ports and agents never see the same bench twice
  [[ "$p" == / ]] && { printf '/'; return 0; }
  fl_bench_canonical "${p%/}"
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
        # resolved like the other sources: the runner and the ownership test compare it with lsof's real folders
        if fl_is_bench_dir "$cand"; then FL_BENCH_DIR="$(fl_abs_path "$cand")"; FL_BENCH_SOURCE="detected"; break; fi
      done < <(fl_bench_candidates)
      if [[ -z "$FL_BENCH_DIR" ]]; then
        FL_BENCH_DIR="$HOME/frappe-bench"; FL_BENCH_SOURCE="default"
      fi
    fi
  fi
  # fl_abs_path resolved it (cd -P into a folder that exists): fl_bench_canonical
  # may skip the cd for it. A bench not created yet (install) is resolved again later.
  FL_BENCH_DIR_CANON=""
  if [[ "$FL_BENCH_SOURCE" =~ ^(flag|env|state)$ && -d "$FL_BENCH_DIR" ]]; then FL_BENCH_DIR_CANON="$FL_BENCH_DIR"; fi
  fl_bench_name_v FL_BENCH_NAME "$FL_BENCH_DIR"
}

# common_site_config.json, read a line at a time as before 0.6.1 (the first
# line that holds only "KEY": value), in bash. The read only commands
# (FL_CONTEXT_LIGHT=1) read the file once, into FL_SCC_*.
FL_SCC_FILE=""
FL_SCC_KEYS=()
FL_SCC_VALS=()
FL_SCC_LINE_RE='^[[:space:]]*"([^"]*)"[[:space:]]*:[[:space:]]*"?([^",]*)"?,?[[:space:]]*$'
fl_site_config_prime() {
  local file="${FL_BENCH_DIR}/sites/common_site_config.json" line
  FL_SCC_FILE=""; FL_SCC_KEYS=(); FL_SCC_VALS=()
  [[ "${FL_CONTEXT_LIGHT:-0}" == "1" && -f "$file" && -r "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ $FL_SCC_LINE_RE ]] || continue
    FL_SCC_KEYS+=("${BASH_REMATCH[1]}"); FL_SCC_VALS+=("${BASH_REMATCH[2]}")
  done <"$file"
  FL_SCC_FILE="$file"
}

# fl_site_config_value_v VAR KEY: VAR gets KEY's raw JSON value (a string
# without quotes, or a number), empty when the file or the key is missing
fl_site_config_value_v() {
  local __file="${FL_BENCH_DIR}/sites/common_site_config.json" __line __v="" __i
  if [[ -n "$FL_SCC_FILE" && "$FL_SCC_FILE" == "$__file" ]]; then
    for ((__i = 0; __i < ${#FL_SCC_KEYS[@]}; __i++)); do
      [[ "${FL_SCC_KEYS[$__i]}" == "$2" ]] && { __v="${FL_SCC_VALS[$__i]}"; break; }
    done
  elif [[ -f "$__file" && -r "$__file" ]]; then
    while IFS= read -r __line || [[ -n "$__line" ]]; do
      [[ "$__line" =~ $FL_SCC_LINE_RE && "${BASH_REMATCH[1]}" == "$2" ]] && { __v="${BASH_REMATCH[2]}"; break; }
    done <"$__file"
  fi
  printf -v "$1" '%s' "$__v"
}

fl_site_config_value() {
  # fl_site_config_value KEY -> raw JSON value (string without quotes or number)
  local v
  fl_site_config_value_v v "$1"
  [[ -n "$v" ]] && printf '%s\n' "$v"
  return 0
}

fl_site_detect() {
  local flag="${1:-}" state d
  if [[ -n "$flag" ]]; then
    FL_SITE="$flag"; FL_SITE_SOURCE="flag"; return 0
  fi
  if [[ -n "${SITE_NAME:-}" ]]; then
    FL_SITE="$SITE_NAME"; FL_SITE_SOURCE="env"; return 0
  fi
  # the site remembered for this bench (its own state file)
  state="$(fl_bstate_get SITE_NAME 2>/dev/null || true)"
  if [[ -n "$state" ]]; then
    FL_SITE="$state"; FL_SITE_SOURCE="state"; return 0
  fi
  if [[ -f "${FL_BENCH_DIR}/sites/currentsite.txt" ]]; then
    FL_SITE=""
    IFS= read -r -d '' FL_SITE <"${FL_BENCH_DIR}/sites/currentsite.txt" || true
    FL_SITE="${FL_SITE//[[:space:]]/}"
    [[ -n "$FL_SITE" ]] && { FL_SITE_SOURCE="currentsite"; return 0; }
  fi
  fl_site_config_value_v FL_SITE default_site
  [[ -n "$FL_SITE" ]] && { FL_SITE_SOURCE="common_site_config"; return 0; }
  for d in "${FL_BENCH_DIR}"/sites/*/site_config.json; do
    [[ -f "$d" ]] || continue
    FL_SITE="$(basename "$(dirname "$d")")"; FL_SITE_SOURCE="detected"; return 0
  done
  FL_SITE="$(fl_default_site)"; FL_SITE_SOURCE="default"
}

fl_ports_detect() {
  local v
  fl_site_config_value_v v webserver_port; [[ "$v" =~ ^[0-9]+$ ]] && FL_WEB_PORT="$v"
  fl_site_config_value_v v socketio_port; [[ "$v" =~ ^[0-9]+$ ]] && FL_SOCKETIO_PORT="$v"
  fl_site_config_value_v v redis_cache; v="${v##*:}"; [[ "$v" =~ ^[0-9]+$ ]] && FL_REDIS_CACHE_PORT="$v"
  fl_site_config_value_v v redis_queue; v="${v##*:}"; [[ "$v" =~ ^[0-9]+$ ]] && FL_REDIS_QUEUE_PORT="$v"
  # bench keeps redis_socketio equal to redis_cache; frappe v15 and v16 never use it
  FL_REDIS_SOCKETIO_PORT="$FL_REDIS_CACHE_PORT"
  fl_site_config_value_v v redis_socketio; v="${v##*:}"; [[ "$v" =~ ^[0-9]+$ ]] && FL_REDIS_SOCKETIO_PORT="$v"
  return 0
}

fl_bench_ports_csv() {
  printf '%s,%s,%s,%s' "$FL_WEB_PORT" "$FL_SOCKETIO_PORT" "$FL_REDIS_QUEUE_PORT" "$FL_REDIS_CACHE_PORT"
}

FL_APP_BUNDLE_ID="com.akashmishra.benchbar"

# The bench's launchd label. Every command asks for it many times, most of
# them inside $(...), so fl_context_init and fl_bench_load compute it once
# (fl_agent_label_prime) and fl_agent_label answers from FL_AGENT_LABEL for
# that bench.
FL_AGENT_LABEL=""
FL_AGENT_LABEL_DIR=""
fl_agent_label() {
  if [[ -n "$FL_AGENT_LABEL" && "$FL_AGENT_LABEL_DIR" == "$FL_BENCH_DIR" ]]; then printf '%s' "$FL_AGENT_LABEL"; return 0; fi
  fl_agent_label_compute
}
fl_agent_label_v() {
  if [[ -n "$FL_AGENT_LABEL" && "$FL_AGENT_LABEL_DIR" == "$FL_BENCH_DIR" ]]; then printf -v "$1" '%s' "$FL_AGENT_LABEL"; return 0; fi
  printf -v "$1" '%s' "$(fl_agent_label_compute)"
}
fl_agent_label_prime() {
  fl_bench_hash_prime
  FL_AGENT_LABEL=""
  FL_AGENT_LABEL="$(fl_agent_label_compute)"
  FL_AGENT_LABEL_DIR="$FL_BENCH_DIR"
}
fl_agent_label_compute() {
  local base="com.benchbar.${FL_BENCH_NAME}" hash hashed f owner d name
  if [[ "$FL_BENCH_HASH_DIR" == "$FL_BENCH_DIR" && -n "$FL_BENCH_HASH" ]]; then hash="$FL_BENCH_HASH"; else fl_path_hash_v hash "$FL_BENCH_DIR"; fi
  hashed="${base}-${hash}"
  # Keep an installed label stable. Never claim another bench's plist merely
  # because both directories are named frappe-bench.
  for f in "$hashed" "$base"; do
    if [[ -f "$HOME/Library/LaunchAgents/${f}.plist" ]]; then
      owner="$(fl_plist_working_dir "$HOME/Library/LaunchAgents/${f}.plist")"
      if fl_same_path "$owner" "$FL_BENCH_DIR"; then printf '%s' "$f"; return 0; fi
    fi
  done
  if [[ -f "$HOME/Library/LaunchAgents/${base}.plist" ]]; then printf '%s' "$hashed"; return 0; fi
  while IFS= read -r d; do
    [[ -n "$d" && "$d" != "$FL_BENCH_DIR" ]] || continue
    fl_bench_name_v name "$d"
    if [[ "$name" == "$FL_BENCH_NAME" ]]; then printf '%s' "$hashed"; return 0; fi
  done <<<"$(fl_known_benches_cached)"
  printf '%s' "$base"
}

# fl_known_benches once per run: fl_agent_label runs in many $(...) subshells,
# so list, scan and fl_context_init fill this before those calls.
FL_KNOWN_BENCHES_CACHE=""
FL_KNOWN_BENCHES_CACHED=0
fl_known_benches_prime() {
  # its pipeline ends on the last candidate's test, so a non-bench there is not a failure
  FL_KNOWN_BENCHES_CACHE="$(fl_known_benches)" || true
  FL_KNOWN_BENCHES_CACHED=1
}
fl_known_benches_cached() {
  if [[ "$FL_KNOWN_BENCHES_CACHED" == "1" ]]; then printf '%s\n' "$FL_KNOWN_BENCHES_CACHE"; else fl_known_benches; fi
}

# The label used by frappe-mac 0.2.0, migrated by "benchbar repair".
fl_agent_label_legacy() {
  printf 'com.frappe-mac.%s' "$FL_BENCH_NAME"
}

fl_agent_plist_path() {
  printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$(fl_agent_label)"
}

fl_launchd_domain() {
  # bash's EUID is what `id -u` prints, without the process
  printf 'gui/%s' "$EUID"
}

fl_runner_path() { printf '%s/benchbar-run.sh' "$FL_BENCH_DIR"; }

# The runner's name before 0.3.0. Repair retires it once no agent points at it.
fl_runner_path_legacy() { printf '%s/frappe-mac-run.sh' "$FL_BENCH_DIR"; }

# True while an installed agent plist of this bench still runs the old runner.
fl_runner_legacy_in_use() {
  local old plist
  old="$(fl_runner_path_legacy)"
  for plist in "$(fl_agent_plist_path)" "$HOME/Library/LaunchAgents/$(fl_agent_label_legacy).plist"; do
    [[ -f "$plist" ]] && grep -q -F "$old" "$plist" 2>/dev/null && return 0
  done
  return 1
}
fl_procfile_path() { printf '%s/Procfile.lean' "$FL_BENCH_DIR"; }
fl_stop_flag_path() { printf '%s/logs/.bench-stopped' "$FL_BENCH_DIR"; }
fl_starts_path() { printf '%s/logs/.bench-starts' "$FL_BENCH_DIR"; }
fl_bench_log_path() { printf '%s/logs/bench.log' "$FL_BENCH_DIR"; }
