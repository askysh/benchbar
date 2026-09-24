#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# checks.sh: every doctor check as a function chk_<name>. A check never
# changes anything. It sets:
#   CHK_STATUS  ok | warn | fail
#   CHK_MSG     one line for humans
#   CHK_FIX     the exact command a human would run (may be empty)
#   CHK_ACTION  the repair action id that fixes it (may be empty)
#
# Groups (used by "benchbar service" versus "benchbar repair"):
#   system, bench, service, site

FL_CHECK_ORDER="brew python_leaves mariadb_bind redis_6379 cleanmymac env_python bench_version socketio assets logs honcho procfile runner agent stop_flag helpers cli_link legacy_agents hosts port_clash ping"
FL_LOG_WARN_MB="${FL_LOG_WARN_MB:-50}"
FL_HOSTS_FILE="${FL_HOSTS_FILE:-/etc/hosts}"

fl_check_group() {
  case "$1" in
    brew|python_leaves|mariadb_bind|redis_6379|cleanmymac) printf 'system' ;;
    env_python|bench_version|socketio|assets|logs) printf 'bench' ;;
    ping) printf 'site' ;;
    *) printf 'service' ;;
  esac
}

fl_check_label() {
  case "$1" in
    brew) printf 'Homebrew formulae' ;;
    python_leaves) printf 'Python formula' ;;
    env_python) printf 'Bench env' ;;
    bench_version) printf 'bench command' ;;
    socketio) printf 'socket.io module' ;;
    assets) printf 'Built assets' ;;
    honcho) printf 'honcho' ;;
    procfile) printf 'Procfile.lean' ;;
    runner) printf 'Runner script' ;;
    agent) printf 'launchd agent' ;;
    stop_flag) printf 'Stop flag' ;;
    helpers) printf 'Shell helpers' ;;
    cli_link) printf 'benchbar on PATH' ;;
    legacy_agents) printf 'Legacy agents' ;;
    mariadb_bind) printf 'MariaDB bind address' ;;
    redis_6379) printf 'Homebrew redis' ;;
    ping) printf 'Site ping' ;;
    hosts) printf '/etc/hosts entry' ;;
    logs) printf 'Log sizes' ;;
    cleanmymac) printf 'CleanMyMac' ;;
    port_clash) printf 'Port clash' ;;
    *) printf '%s' "$1" ;;
  esac
}

chk__set() { CHK_STATUS="$1"; CHK_MSG="$2"; CHK_FIX="${3:-}"; CHK_ACTION="${4:-}"; }

chk_brew() {
  local missing="" f
  command -v brew >/dev/null 2>&1 || { chk__set fail "Homebrew is not installed" "Install from https://brew.sh"; return 0; }
  for f in "$FL_PYTHON_FORMULA" "$FL_NODE_FORMULA" "$FL_MARIADB_FORMULA" redis; do
    brew list --formula --versions "$f" >/dev/null 2>&1 || missing="${missing} ${f}"
  done
  if [[ -n "$missing" ]]; then
    chk__set fail "missing formulae:${missing}" "${SCRIPT_DIR}/00-mac-system-deps.sh --profile ${FL_PROFILE}"
  else
    chk__set ok "${FL_PYTHON_FORMULA}, ${FL_NODE_FORMULA}, ${FL_MARIADB_FORMULA}, redis installed"
  fi
}

chk_python_leaves() {
  local py ver want
  py="$(fl_python_bin)"
  want="${FL_PYTHON_BIN_NAME#python}"
  if [[ ! -x "$py" ]]; then
    chk__set fail "${py} not found" "brew install ${FL_PYTHON_FORMULA}"
    return 0
  fi
  ver="$("$py" --version 2>&1 | awk '{print $2}')"
  case "$ver" in
    "${want}".*) ;;
    *) chk__set fail "${py} is ${ver}, profile expects ${want}.x" "brew reinstall ${FL_PYTHON_FORMULA}"; return 0 ;;
  esac
  if brew leaves 2>/dev/null | grep -qx "$FL_PYTHON_FORMULA"; then
    chk__set ok "${FL_PYTHON_FORMULA} ${ver} is user-installed (safe from brew autoremove)"
  else
    chk__set warn "${FL_PYTHON_FORMULA} is only a dependency; brew autoremove could delete it" "brew tab --installed-on-request ${FL_PYTHON_FORMULA}" python_leaves
  fi
}

chk_env_python() {
  local py="${FL_BENCH_DIR}/env/bin/python" ver want
  want="${FL_PYTHON_BIN_NAME#python}"
  if [[ ! -e "$py" && ! -L "$py" ]]; then
    chk__set fail "env/bin/python is missing (env deleted, for example by a cleanup tool)" "${SCRIPT_DIR}/benchbar repair" env_rebuild
    return 0
  fi
  if ! ver="$("$py" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)"; then
    chk__set fail "env/bin/python does not run (broken symlink or removed interpreter)" "${SCRIPT_DIR}/benchbar repair" env_rebuild
    return 0
  fi
  if [[ "$ver" != "$want" ]]; then
    chk__set fail "env uses Python ${ver}, profile ${FL_PROFILE} expects ${want}" "${SCRIPT_DIR}/benchbar repair" env_rebuild
    return 0
  fi
  chk__set ok "env/bin/python runs (Python ${ver})"
}

chk_bench_version() {
  local out
  if [[ ! -e "${FL_BENCH_DIR}/env/bin/python" ]]; then
    chk__set fail "skipped: env is missing" "${SCRIPT_DIR}/benchbar repair" env_rebuild
    return 0
  fi
  if out="$(cd "$FL_BENCH_DIR" && bench version 2>&1)"; then
    chk__set ok "bench version works ($(printf '%s' "$out" | grep -m1 -E '^frappe' || printf 'ok'))"
  else
    chk__set fail "bench version fails: $(printf '%s' "$out" | tail -n1)" "${SCRIPT_DIR}/benchbar repair" env_rebuild
  fi
}

chk_socketio() {
  if [[ -d "${FL_BENCH_DIR}/apps/frappe/node_modules/socket.io" ]]; then
    chk__set ok "apps/frappe/node_modules/socket.io present"
  else
    chk__set fail "apps/frappe/node_modules/socket.io is missing (node_modules deleted)" "cd ${FL_BENCH_DIR} && bench setup requirements --node" node_requirements
  fi
}

# Reads sites/assets/assets.json and checks the dist files it references.
fl_assets_missing() {
  local json="${FL_BENCH_DIR}/sites/assets/assets.json" ref rel checked=0 missing=0
  [[ -f "$json" ]] || { printf 'nojson'; return 0; }
  while IFS= read -r ref; do
    rel="${ref#/assets/}"
    checked=$((checked + 1))
    [[ -e "${FL_BENCH_DIR}/sites/assets/${rel}" ]] || missing=$((missing + 1))
  done < <(grep -o '"/assets/[^"]*"' "$json" | tr -d '"' | sort -u)
  printf '%s/%s' "$missing" "$checked"
}

chk_assets() {
  local r
  r="$(fl_assets_missing)"
  case "$r" in
    nojson) chk__set fail "sites/assets/assets.json is missing (never built)" "cd ${FL_BENCH_DIR} && bench build" build ;;
    0/0) chk__set warn "assets.json references no dist files" "cd ${FL_BENCH_DIR} && bench build" build ;;
    0/*) chk__set ok "all ${r#0/} dist files referenced by assets.json exist" ;;
    *) chk__set fail "${r%%/*} of ${r##*/} dist files referenced by assets.json are missing (site loads unstyled)" "cd ${FL_BENCH_DIR} && bench build" build ;;
  esac
}

chk_honcho() {
  if [[ -n "$FL_HONCHO" ]]; then
    chk__set ok "honcho at ${FL_HONCHO}"
  else
    chk__set fail "honcho not found on PATH, in the pipx venv or in env/bin" "uv pip install --python ${FL_BENCH_DIR}/env/bin/python honcho" honcho_install
  fi
}

chk__template() {
  local label="$1" path="$2" rendered="$3" action="$4" status
  status="$(fl_template_status "$path" "$rendered")"
  case "$status" in
    current) chk__set ok "${label} is current ($(fl_template_header_of "$rendered" | awk '{print $3, $4}'))" ;;
    missing) chk__set warn "${label} is missing (${path})" "${SCRIPT_DIR}/benchbar repair" "$action" ;;
    outdated) chk__set warn "${label} is outdated (template or settings changed)" "${SCRIPT_DIR}/benchbar repair" "$action" ;;
    foreign) chk__set warn "${label} exists but was not written by benchbar" "${SCRIPT_DIR}/benchbar repair" "$action" ;;
  esac
}

chk_procfile() { chk__template "Procfile.lean" "$(fl_procfile_path)" "$FL_R_PROCFILE" write_procfile; }
chk_runner() {
  chk__template "runner" "$(fl_runner_path)" "$FL_R_RUNNER" write_runner
  # frappe-mac-run.sh from before 0.3.0, left behind if a repair was interrupted
  if [[ "$CHK_STATUS" == "ok" && -f "$(fl_runner_path_legacy)" ]] && ! fl_runner_legacy_in_use; then
    chk__set warn "the old runner $(fl_runner_path_legacy) is still in the bench" "${SCRIPT_DIR}/benchbar repair" write_runner
  fi
}

chk_agent() {
  local plist state pid code
  plist="$(fl_agent_plist_path)"
  chk__template "agent plist" "$plist" "$FL_R_PLIST" write_plist
  [[ "$CHK_STATUS" == "ok" ]] || return 0
  if ! fl_agent_loaded; then
    chk__set warn "agent $(fl_agent_label) is written but not loaded" "launchctl bootstrap $(fl_launchd_domain) ${plist}" write_plist
    return 0
  fi
  state="$(fl_agent_field state)"; pid="$(fl_agent_field pid)"; code="$(fl_agent_field 'last exit code')"
  if [[ "$state" == "running" ]]; then
    chk__set ok "agent $(fl_agent_label) loaded, running (pid ${pid:-?})"
  elif [[ -n "$code" && "$code" != "0" && "$code" != "(never exited)" ]]; then
    chk__set warn "agent loaded, ${state:-not running}, last exit code ${code}" "${SCRIPT_DIR}/benchbar logs"
  else
    chk__set ok "agent $(fl_agent_label) loaded, ${state:-not running}"
  fi
}

chk_stop_flag() {
  local flag reason
  flag="$(fl_stop_flag_path)"
  if [[ ! -f "$flag" ]]; then
    chk__set ok "no stop flag: auto-restart is armed"
    return 0
  fi
  reason="$(tr -d '[:space:]' <"$flag")"
  case "$reason" in
    manual) chk__set ok "stopped on purpose (benchdown); start with benchup" ;;
    crash) chk__set warn "auto-restart paused after repeated crashes" "${SCRIPT_DIR}/benchbar logs, fix the cause, then benchup" ;;
    broken) chk__set warn "auto-restart paused: honcho or env was missing" "${SCRIPT_DIR}/benchbar repair, then benchup" ;;
    *) chk__set warn "stop flag has unknown content '${reason}'" "rm ${flag}" ;;
  esac
}

chk_helpers() {
  local rc status legacy
  rc="$(fl_rc_file)"
  status="$(fl_rc_block_status "$rc" "$FL_R_HELPERS")"
  legacy="$(fl_rc_legacy_blocks "$rc" | tr '\n' ',' | sed 's/,$//')"
  case "$status" in
    current) chk__set ok "helper block in ${rc} is current" ;;
    missing) chk__set warn "helper block missing from ${rc}" "${SCRIPT_DIR}/benchbar repair" write_helpers ;;
    outdated) chk__set warn "helper block in ${rc} is outdated" "${SCRIPT_DIR}/benchbar repair" write_helpers ;;
    broken) chk__set warn "benchbar markers in ${rc} are malformed; a fresh block will be appended" "${SCRIPT_DIR}/benchbar repair" write_helpers ;;
  esac
  if [[ -n "$legacy" ]]; then
    [[ "$CHK_STATUS" == "ok" ]] && CHK_STATUS=warn
    CHK_MSG="${CHK_MSG}; old block(s) still present: ${legacy} (remove by hand, the benchbar block wins because it comes later)"
    [[ -n "$CHK_FIX" ]] || CHK_FIX="open ${rc} and delete the old '${legacy}' block"
  fi
}

fl_cli_link_path() { printf '%s/.local/bin/%s' "$HOME" "${1:-benchbar}"; }

# A link is current when it resolves to this checkout's benchbar. The
# frappe-mac alias may point at either name in the checkout.
fl_cli_link_ok() {
  local link="$1" have
  [[ -L "$link" ]] || return 1
  have="$(readlink "$link")"
  [[ "$have" == "${SCRIPT_DIR}/benchbar" || "$have" == "${SCRIPT_DIR}/frappe-mac" ]]
}

chk_cli_link() {
  local name link bad="" foreign="" target="${SCRIPT_DIR}/benchbar"
  for name in benchbar frappe-mac; do
    link="$(fl_cli_link_path "$name")"
    fl_cli_link_ok "$link" && continue
    if [[ -e "$link" && ! -L "$link" ]]; then
      foreign="${foreign}${foreign:+, }${link}"
    elif [[ -L "$link" ]]; then
      bad="${bad}${bad:+; }${link} points to $(readlink "$link")"
    else
      bad="${bad}${bad:+; }no ${link} yet"
    fi
  done
  if [[ -n "$bad" ]]; then
    chk__set warn "${bad} (so 'benchbar' and 'frappe-mac' work from any folder)" "${SCRIPT_DIR}/benchbar repair" write_cli_link
  elif [[ -n "$foreign" ]]; then
    chk__set warn "${foreign} exists and is not a symlink; leaving it alone" "mv ${foreign%%,*} ${foreign%%,*}.bak && ln -s ${target} ${foreign%%,*}"
  else
    chk__set ok "~/.local/bin/benchbar and ~/.local/bin/frappe-mac point to this checkout"
  fi
}

chk_legacy_agents() {
  local list n desc="" path label state code
  list="$(fl_legacy_agents_list)"
  if [[ -z "$list" ]]; then
    chk__set ok "no legacy per-process agents"
    return 0
  fi
  n=0
  while IFS='|' read -r path label state code; do
    [[ -n "$path" ]] || continue
    n=$((n + 1))
    desc="${desc}${desc:+; }${label} (${state}, last exit ${code})"
  done <<<"$list"
  chk__set warn "${n} legacy agent(s): ${desc}" "${SCRIPT_DIR}/benchbar repair (moves them to ${FL_LEGACY_DIR})" legacy_migrate
}

fl_mariadb_dropin_path() {
  printf '%s/etc/my.cnf.d/frappe-mac-local-only.cnf' "${FL_BREW_PREFIX:-/opt/homebrew}"
}

chk_mariadb_bind() {
  local addrs exposed="" a dropin
  dropin="$(fl_mariadb_dropin_path)"
  addrs="$(fl_port_listen_addresses 3306)"
  if [[ -n "$addrs" ]]; then
    while IFS= read -r a; do
      case "$a" in
        127.0.0.1:*|"[::1]:"*|localhost:*) ;;
        *) exposed="${exposed} ${a}" ;;
      esac
    done <<<"$addrs"
    if [[ -n "$exposed" ]]; then
      chk__set warn "MariaDB listens on${exposed} (reachable from the network)" "${SCRIPT_DIR}/benchbar repair (writes ${dropin} and restarts MariaDB)" mariadb_bind
    else
      chk__set ok "MariaDB listens on 127.0.0.1 only"
    fi
    return 0
  fi
  if [[ -f "$dropin" ]] || grep -qs 'bind-address[[:space:]]*=[[:space:]]*127\.0\.0\.1' "${FL_BREW_PREFIX:-/opt/homebrew}"/etc/my.cnf.d/*.cnf 2>/dev/null; then
    chk__set ok "MariaDB is not running; bind-address drop-in present"
  else
    chk__set warn "MariaDB is not running and no bind-address drop-in exists" "${SCRIPT_DIR}/benchbar repair" mariadb_bind
  fi
}

chk_redis_6379() {
  local who
  who="$(fl_port_listener_summary 6379)"
  if [[ -z "$who" ]]; then
    chk__set ok "nothing on 6379 (bench uses its own redis on ${FL_REDIS_QUEUE_PORT} and ${FL_REDIS_CACHE_PORT})"
  else
    chk__set warn "redis on 6379 (${who}) is not used by the bench" "brew services stop redis (only if nothing else needs it)" redis_stop
  fi
}

fl_site_ping_code() {
  local code
  code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' -H "Host: ${FL_SITE}" "http://127.0.0.1:${FL_WEB_PORT}/api/method/ping" 2>/dev/null || true)"
  case "$code" in
    [0-9][0-9][0-9]) printf '%s' "$code" ;;
    *) printf '000' ;;
  esac
}

fl_hosts_has_site() {
  local site_re
  site_re="$(printf '%s' "$FL_SITE" | sed 's/\./\\./g')"
  grep -qE "^[[:space:]]*127\.0\.0\.1[[:space:]]+(.*[[:space:]])?${site_re}([[:space:]]|$)" "$FL_HOSTS_FILE" 2>/dev/null
}

chk_ping() {
  local code reason
  code="$(fl_site_ping_code)"
  if [[ "$code" == "200" ]]; then
    chk__set ok "http://${FL_SITE}:${FL_WEB_PORT}/api/method/ping returned 200"
    return 0
  fi
  reason="$(fl_stop_flag_reason)"
  if fl_bench_is_running; then
    chk__set fail "bench processes are running but ping returned ${code}" "${SCRIPT_DIR}/benchbar logs"
  elif [[ "$reason" == "manual" || -z "$reason" && ! -f "$(fl_runner_path)" ]]; then
    chk__set ok "bench is stopped; start it with benchup"
  elif [[ "$reason" == "crash" || "$reason" == "broken" ]]; then
    chk__set warn "bench is paused (${reason}); fix, then benchup" "${SCRIPT_DIR}/benchbar logs"
  else
    chk__set warn "bench is not running (ping ${code})" "benchup"
  fi
}

chk_hosts() {
  if fl_hosts_has_site; then
    chk__set ok "${FL_HOSTS_FILE} maps ${FL_SITE} to 127.0.0.1"
  else
    chk__set warn "${FL_HOSTS_FILE} has no entry for ${FL_SITE}" "printf '127.0.0.1 ${FL_SITE}\\n' | sudo tee -a ${FL_HOSTS_FILE}" hosts_entry
  fi
}

fl_file_mb() {
  local f="$1" bytes
  [[ -f "$f" ]] || { printf '0'; return 0; }
  bytes="$(stat -f %z "$f" 2>/dev/null || wc -c <"$f")"
  printf '%d' $((bytes / 1024 / 1024))
}

chk_logs() {
  local f mb big=""
  for f in bench.log worker.log worker.error.log; do
    mb="$(fl_file_mb "${FL_BENCH_DIR}/logs/${f}")"
    [[ "$mb" -ge "$FL_LOG_WARN_MB" ]] && big="${big} ${f} (${mb} MB)"
  done
  if [[ -n "$big" ]]; then
    chk__set warn "large logs:${big}" "${SCRIPT_DIR}/benchbar repair (moves them aside)" rotate_logs
  else
    chk__set ok "bench.log and worker logs are under ${FL_LOG_WARN_MB} MB"
  fi
}

FL_APP_DIRS="${FL_APP_DIRS:-/Applications:$HOME/Applications}"

chk_cleanmymac() {
  local app found="" dir dirs
  dirs="$FL_APP_DIRS"
  while [[ -n "$dirs" ]]; do
    dir="${dirs%%:*}"
    [[ "$dirs" == *:* ]] && dirs="${dirs#*:}" || dirs=""
    for app in "$dir"/CleanMyMac*.app; do
      [[ -d "$app" ]] && found="$app"
    done
  done
  if [[ -n "$found" ]]; then
    chk__set warn "$(basename "$found") is installed; its cleanup can delete env/, node_modules and public/dist" "In CleanMyMac, add ${FL_BENCH_DIR} to the Ignore List before running any cleanup"
  else
    chk__set ok "CleanMyMac not installed"
  fi
}

chk_port_clash() {
  local f other label state wd ports clash=""
  for f in "$HOME"/Library/LaunchAgents/com.benchbar.*.plist "$HOME"/Library/LaunchAgents/com.frappe-mac.*.plist; do
    [[ -f "$f" ]] || continue
    label="$(fl_plist_label "$f")"
    [[ "$label" == "$(fl_agent_label)" || "$label" == "$(fl_agent_label_legacy)" ]] && continue
    state="$(fl_agent_field state "$(fl_launchd_domain)/${label}")"
    [[ "$state" == "running" ]] || continue
    wd="$(fl_plist_working_dir "$f")"
    [[ -n "$wd" && "$wd" != "$FL_BENCH_DIR" && -f "$wd/sites/common_site_config.json" ]] || continue
    ports="$(sed -E -n 's/^[[:space:]]*"webserver_port"[[:space:]]*:[[:space:]]*([0-9]*).*/\1/p' "$wd/sites/common_site_config.json"; sed -E -n 's/^[[:space:]]*"socketio_port"[[:space:]]*:[[:space:]]*([0-9]*).*/\1/p' "$wd/sites/common_site_config.json")"
    for other in $ports; do
      if [[ "$other" == "$FL_WEB_PORT" || "$other" == "$FL_SOCKETIO_PORT" ]]; then clash="${clash} ${label}:${other}"; fi
    done
  done
  if [[ -n "$clash" ]]; then
    chk__set warn "another running bench uses the same port:${clash}" "stop the other bench or change webserver_port in sites/common_site_config.json"
  else
    chk__set ok "no other benchbar bench is running on ${FL_WEB_PORT}/${FL_SOCKETIO_PORT}"
  fi
}
