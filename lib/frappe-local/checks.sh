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

FL_CHECK_ORDER="brew python_leaves mariadb_bind mariadb_utf8 pdf_engine redis_6379 cleanmymac full_disk_access env_python bench_version toolchain_node toolchain_yarn mariadb_version toolchain_pkgconfig socketio assets apps_txt app_branch_policy lock_parse lock_drift logs honcho honcho_setuptools procfile runner agent fork_safety scheduler stop_flag helpers cli_link legacy_agents hosts port_clash orphans ping"
FL_LOG_WARN_MB="${FL_LOG_WARN_MB:-50}"
FL_HOSTS_FILE="${FL_HOSTS_FILE:-/etc/hosts}"

# port_block only exists while a plan moves this bench's ports
# (FL_PORT_TARGET, set by fl_ports_plan); doctor never shows it.
chk_port_block() {
  if [[ -n "${FL_PORT_TARGET:-}" && "$FL_PORT_TARGET" != "$(fl_port_offset_current)" ]]; then
    chk__set warn "ports move to block ${FL_PORT_TARGET}: $(fl_port_block "$FL_PORT_TARGET" | tr ' ' '/')" "${SCRIPT_DIR}/benchbar service --port-offset ${FL_PORT_TARGET} --bench-dir ${FL_BENCH_DIR}" port_block
  else
    chk__set ok "ports stay ${FL_WEB_PORT}/${FL_SOCKETIO_PORT}/${FL_REDIS_QUEUE_PORT}/${FL_REDIS_CACHE_PORT}"
  fi
}

fl_check_group() {
  case "$1" in
    brew|python_leaves|mariadb_bind|mariadb_utf8|pdf_engine|redis_6379|cleanmymac|full_disk_access) printf 'system' ;;
    env_python|bench_version|toolchain_*|socketio|assets|apps_txt|app_branch_policy|lock_parse|lock_drift|logs) printf 'bench' ;;
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
    mariadb_utf8) printf 'MariaDB utf8mb4' ;;
    pdf_engine) printf 'PDF engine' ;;
    redis_6379) printf 'Homebrew redis' ;;
    ping) printf 'Site ping' ;;
    hosts) printf '/etc/hosts entry' ;;
    logs) printf 'Log sizes' ;;
    cleanmymac) printf 'CleanMyMac' ;;
    port_clash) printf 'Port clash' ;;
    port_block) printf 'Port block' ;;
    scheduler) printf 'Scheduler' ;;
    full_disk_access) printf 'Full Disk Access' ;;
    toolchain_node) printf 'Node' ;;
    toolchain_yarn) printf 'yarn' ;;
    mariadb_version) printf 'MariaDB server' ;;
    toolchain_pkgconfig) printf 'pkg-config' ;;
    honcho_setuptools) printf 'honcho imports' ;;
    fork_safety) printf 'Fork safety env' ;;
    orphans) printf 'Stale processes' ;;
    apps_txt) printf 'Apps in apps.txt' ;;
    app_branch_policy) printf 'App branches' ;;
    lock_parse) printf 'benchbar.toml' ;;
    lock_drift) printf 'Lockfile drift' ;;
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
    return 0
  fi
  # build formulae: mysqlclient (a frappe v16 dependency) compiles against them
  for f in $FL_BUILD_FORMULAE; do
    brew list --formula --versions "$f" >/dev/null 2>&1 || missing="${missing} ${f}"
  done
  if [[ -n "$missing" ]]; then
    chk__set warn "${FL_PYTHON_FORMULA}, ${FL_NODE_FORMULA}, ${FL_MARIADB_FORMULA}, redis installed; missing build formulae:${missing} (needed to build mysqlclient for frappe v16)" "brew install${missing}"
  else
    chk__set ok "${FL_PYTHON_FORMULA}, ${FL_NODE_FORMULA}, ${FL_MARIADB_FORMULA}, redis, pkgconf, mariadb-connector-c installed"
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
  # installed on request, not "a leaf": brew leaves hides a formula another
  # formula depends on (python@3.14 under pipx or uv) even when it was asked for
  if brew list --formula --installed-on-request 2>/dev/null | grep -qx "$FL_PYTHON_FORMULA"; then
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
    chk__set ok "bench version works ($(printf '%s' "$out" | grep -m1 -E '^frappe' || printf 'ok'); bench installed by $(fl_bench_owner))"
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

chk_mariadb_utf8() {
  local dropin status mycnf
  dropin="$(fl_mariadb_utf8_dropin_path)"
  mycnf="${FL_BREW_PREFIX:-/opt/homebrew}/etc/my.cnf"
  status="$(fl_template_status "$dropin" "$(fl_template_render mariadb-frappe.cnf)")"
  case "$status" in
    current) chk__set ok "utf8mb4 drop-in ${dropin} is current" ;;
    foreign)
      if grep -q 'character-set-server[[:space:]]*=[[:space:]]*utf8mb4' "$dropin" 2>/dev/null; then
        chk__set ok "${dropin} sets utf8mb4 (not written by benchbar, left alone)"
      else
        chk__set warn "${dropin} exists but does not set utf8mb4" "${SCRIPT_DIR}/benchbar repair" mariadb_utf8
        return 0
      fi ;;
    *) chk__set warn "utf8mb4 drop-in is ${status} (${dropin}); Frappe needs utf8mb4 server wide" "${SCRIPT_DIR}/benchbar repair" mariadb_utf8; return 0 ;;
  esac
  # the drop-in only counts when my.cnf pulls the folder in. The server's
  # live charset is not queried: doctor is read only and must never read the
  # Keychain (the app runs it on a timer).
  if ! fl_mariadb_includedir_present; then
    chk__set warn "${mycnf} is missing or has no '!includedir' for my.cnf.d, so the utf8mb4 drop-in is ignored" "${SCRIPT_DIR}/benchbar repair" mariadb_utf8
  fi
}

# The Chromium frappe v16 uses for Print Formats set to "chrome": the
# chromium_path from common_site_config.json, else <bench>/chromium, where
# "bench setup-chrome" (or the first chrome PDF) downloads it.
fl_chromium_path() {
  local p
  p="$(fl_site_config_value chromium_path)"
  if [[ -n "$p" ]]; then
    [[ "$p" == /* ]] || p="$(command -v "$p" 2>/dev/null || printf '%s' "$p")"
    printf '%s' "$p"
    return 0
  fi
  printf '%s/chromium/chrome-mac/headless_shell' "$FL_BENCH_DIR"
}

# wkhtmltopdf is the default PDF engine on every profile (frappe v16 still
# defaults Print Formats to it); from v16 on a Print Format can use Chromium.
chk_pdf_engine() {
  local shadow chrome="" chrome_ok=1 bin
  if [[ "$(fl_profile_major)" -ge 16 ]]; then
    bin="$(fl_chromium_path)"
    if [[ -x "$bin" ]]; then chrome="; Chromium at ${bin}"; else chrome_ok=0; chrome="; Chromium for chrome Print Formats is not downloaded yet"; fi
  fi
  case "$(fl_wkhtmltopdf_state)" in
    patched)
      shadow="$(fl_wkhtmltopdf_shadow)"
      if [[ -n "$shadow" ]]; then
        chk__set warn "patched build at $(fl_wkhtmltopdf_bin), but ${shadow} comes first on PATH and is not patched${chrome}" "brew uninstall wkhtmltopdf"
      elif [[ "$chrome_ok" == "0" ]]; then
        chk__set warn "wkhtmltopdf: patched Qt build at $(fl_wkhtmltopdf_bin)${chrome}" "cd ${FL_BENCH_DIR} && bench setup-chrome"
      else
        chk__set ok "wkhtmltopdf: patched Qt build at $(fl_wkhtmltopdf_bin)${chrome}"
      fi ;;
    unpatched) chk__set warn "$(fl_wkhtmltopdf_bin) is not the patched Qt build; PDFs will crash${chrome}" "${SCRIPT_DIR}/benchbar repair (installs the official package, sudo)" wkhtmltopdf_install ;;
    *) chk__set warn "wkhtmltopdf is not installed; PDF printing will not work${chrome}" "${SCRIPT_DIR}/benchbar repair (installs the official package, sudo)" wkhtmltopdf_install ;;
  esac
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
  # wc, not stat: BSD and GNU stat disagree on -f, and the suite runs on both
  bytes="$(wc -c <"$f" | tr -d ' ')"
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

# Running benchbar benches that use this bench's web or socketio port, as
# " label:port" words; "benchbar up" asks before starting next to one.
fl_port_clash_running() {
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
  printf '%s' "$clash"
}

# Another bench with the same ports: a warning while it runs, and also when
# it is only configured that way (then only one of them can run at a time).
chk_port_clash() {
  local running configured next
  running="$(fl_port_clash_running)"
  # "third: 8000, 9000, 11000, 13000; other: 8000"
  configured="$(fl_port_clashes_with_benches | awk '{ if (!($2 in seen)) { order[++k] = $2; seen[$2] = $1 } else seen[$2] = seen[$2] ", " $1 }
    END { for (i = 1; i <= k; i++) { n = order[i]; sub(/.*\//, "", n); printf "%s%s: %s", (i > 1 ? "; " : ""), n, seen[order[i]] } }')"
  next="$(fl_port_next_free_offset 2>/dev/null || printf 'N')"
  if [[ -n "$running" ]]; then
    chk__set warn "another running bench uses the same port:${running}" "${SCRIPT_DIR}/benchbar service --port-offset ${next} --bench-dir ${FL_BENCH_DIR}   (or stop the other bench)"
  elif [[ -n "$configured" ]]; then
    chk__set warn "another bench is set up with the same ports (${configured}); only one of them can run at a time" "${SCRIPT_DIR}/benchbar service --port-offset ${next} --bench-dir ${FL_BENCH_DIR}"
  else
    chk__set ok "no other benchbar bench uses ${FL_WEB_PORT}, ${FL_SOCKETIO_PORT}, ${FL_REDIS_QUEUE_PORT} or ${FL_REDIS_CACHE_PORT}"
  fi
}

# ------------------------------------------------------------- 0.4 checks

# Reported, never flagged: the scheduler is a choice. A Procfile that does
# not match the choice shows up as "Procfile.lean is outdated".
chk_scheduler() {
  if fl_scheduler_enabled; then
    chk__set ok "on: Procfile.lean runs bench schedule (off: benchbar service --without-schedule)"
  else
    chk__set ok "off, scheduled jobs do not run (on: benchbar service --with-schedule)"
  fi
}

chk_full_disk_access() {
  # Full Disk Access belongs to the app that runs bench init (Terminal);
  # BenchBar never needs it, so its own answer would only mislead
  if [[ "${__CFBundleIdentifier:-}" == "$FL_APP_BUNDLE_ID" ]]; then
    chk__set ok "not checked from BenchBar (it matters for the Terminal that runs bench init)"
    return 0
  fi
  if fl_crontab_denied; then
    chk__set warn "crontab is not readable (Operation not permitted): bench init and bench setup backups fail without Full Disk Access" \
      "System Settings > Privacy & Security > Full Disk Access: add Terminal (or the app that runs benchbar), then open a new window"
  else
    chk__set ok "crontab is readable"
  fi
}

# The tools as the bench's processes see them: launchd's PATH, not the
# caller's. nvm's node lives in a shell PATH only, so bench never sees it.
fl_bench_which() {
  PATH="$(fl_launchd_path_value)" command -v "$1" 2>/dev/null || true
}

chk_toolchain_node() {
  local node where ver major
  if [[ -x "${FL_BENCH_DIR}/env/bin/node" ]]; then node="${FL_BENCH_DIR}/env/bin/node"; where="env/bin/node"
  else node="$(fl_bench_which node)"; where="$node"; fi
  if [[ -z "$node" ]]; then
    if [[ -d "$HOME/.nvm" ]]; then
      chk__set warn "no node on the bench's PATH (nvm's node is only on your shell's PATH, bench does not see it)" "brew install ${FL_NODE_FORMULA}"
    else
      chk__set warn "no node on the bench's PATH" "brew install ${FL_NODE_FORMULA}"
    fi
    return 0
  fi
  ver="$("$node" --version 2>/dev/null | tr -d 'v' || true)"
  major="${ver%%.*}"
  if [[ "$major" == "$FL_NODE_MAJOR" ]]; then
    chk__set ok "Node ${ver} at ${where}, profile ${FL_PROFILE} expects ${FL_NODE_MAJOR}"
  else
    chk__set warn "Node ${ver:-unknown} at ${where}, profile ${FL_PROFILE} expects ${FL_NODE_MAJOR}" "brew install ${FL_NODE_FORMULA}   (the bench's PATH puts ${FL_BREW_PREFIX}/opt/${FL_NODE_FORMULA}/bin first)"
  fi
}

chk_toolchain_yarn() {
  local yarn ver
  yarn="$(fl_bench_which yarn)"
  if [[ -z "$yarn" ]]; then
    chk__set warn "no yarn on the bench's PATH (bench build needs it)" "$(fl_npm_bin) install -g yarn"
    return 0
  fi
  ver="$("$yarn" --version 2>/dev/null || true)"
  chk__set ok "yarn ${ver:-found} at ${yarn}"
}

# The version of the MariaDB server listening on 3306: its own binary when
# ps can name it, else the installed mariadb formula. Never logs in, so the
# Keychain is never read.
fl_mariadb_server_version() {
  local pid bin f
  pid="$(fl_port_listener_pid 3306)"
  if [[ -n "$pid" ]]; then
    bin="$(ps -o command= -p "$pid" 2>/dev/null | awk '{print $1}' || true)"
    if [[ "$bin" == */mariadbd && -x "$bin" ]]; then
      "$bin" --version 2>/dev/null | fl_parse_mariadb_version | head -n1
      return 0
    fi
  fi
  for f in "$FL_MARIADB_FORMULA" mariadb@11.8 mariadb@11.4 mariadb@10.11 mariadb@10.6 mariadb; do
    if [[ -x "${FL_BREW_PREFIX}/opt/${f}/bin/mariadb" ]]; then
      "${FL_BREW_PREFIX}/opt/${f}/bin/mariadb" --version 2>/dev/null | fl_parse_mariadb_version | head -n1
      return 0
    fi
  done
}

# The range each profile accepts (release-profiles.tsv): v16's is frappe's
# own check_compatible_versions (10.6 to 11.8); v15's code warns above 10.8,
# a stale bound, so its range ends at the 10.11 the v15 docs install.
# Outside the range is a warning, as it is in frappe.
fl_mm_num() { printf '%s' "$1" | awk -F. '{printf "%d%03d", $1, $2}'; }

chk_mariadb_version() {
  local ver mm
  if [[ -z "$(fl_port_listener_pid 3306)" ]]; then
    chk__set warn "nothing listens on 3306: MariaDB is not running" "brew services start ${FL_MARIADB_FORMULA}"
    return 0
  fi
  ver="$(fl_mariadb_server_version)"
  mm="$(fl_mm_num "$ver")"
  if [[ -z "$ver" ]]; then
    chk__set ok "MariaDB listens on 3306 (version not readable)"
  elif [[ "$mm" -lt "$(fl_mm_num "$FL_MARIADB_MIN")" ]]; then
    chk__set warn "MariaDB ${ver} is older than ${FL_MARIADB_MIN}, the oldest profile ${FL_PROFILE} supports" "brew install ${FL_MARIADB_FORMULA}"
  elif [[ "$mm" -gt "$(fl_mm_num "$FL_MARIADB_MAX")" ]]; then
    chk__set warn "MariaDB ${ver} is newer than ${FL_MARIADB_MAX}, the newest profile ${FL_PROFILE} is tested with" "brew install ${FL_MARIADB_FORMULA}"
  else
    chk__set ok "MariaDB ${ver} on 3306 (profile ${FL_PROFILE} accepts ${FL_MARIADB_MIN} to ${FL_MARIADB_MAX})"
  fi
}

chk_toolchain_pkgconfig() {
  local pc ver
  pc="$(fl_bench_which pkg-config)"
  if [[ -z "$pc" ]]; then
    chk__set warn "no pkg-config on the bench's PATH (mysqlclient for frappe v16 needs it)" "brew install pkgconf mariadb-connector-c"
    return 0
  fi
  ver="$("$pc" --version 2>/dev/null || true)"
  if PKG_CONFIG_PATH="${FL_BREW_PREFIX}/opt/mariadb-connector-c/lib/pkgconfig" "$pc" --exists libmariadb 2>/dev/null; then
    chk__set ok "pkg-config ${ver} finds mariadb-connector-c"
  else
    chk__set warn "pkg-config ${ver} does not find mariadb-connector-c (libmariadb)" "brew install mariadb-connector-c"
  fi
}

# The interpreter named in honcho's shebang, when it is a Python.
fl_honcho_python() {
  local line py
  [[ -n "$FL_HONCHO" && -f "$FL_HONCHO" ]] || return 0
  line="$(head -n1 "$FL_HONCHO" 2>/dev/null || true)"
  py="${line#\#!}"; py="${py%% *}"
  case "$py" in */python*) [[ -x "$py" ]] && printf '%s' "$py" ;; esac
  return 0
}

# honcho 1.x imports pkg_resources, which Python 3.12 and later only have
# with setuptools installed; honcho 2.0 no longer needs it.
chk_honcho_setuptools() {
  local py
  py="$(fl_honcho_python)"
  if [[ -z "$py" ]]; then
    chk__set ok "skipped: honcho is not a Python script here"
    return 0
  fi
  if "$py" -c 'import honcho.command' >/dev/null 2>&1; then
    chk__set ok "honcho imports cleanly with ${py}"
  elif "$py" -c 'import pkg_resources' >/dev/null 2>&1; then
    chk__set warn "honcho does not import with ${py}" "${py} -c 'import honcho.command'   (shows the error)"
  else
    chk__set warn "honcho needs pkg_resources, which ${py} lacks (No module named 'pkg_resources')" "${SCRIPT_DIR}/benchbar repair (installs setuptools into honcho's venv only)" honcho_setuptools
  fi
}

# OBJC_DISABLE_INITIALIZE_FORK_SAFETY and NO_PROXY keep macOS from killing
# forked workers; the agent plist sets them and honcho's children inherit.
chk_fork_safety() {
  local plist missing=""
  plist="$(fl_agent_plist_path)"
  if [[ ! -f "$plist" ]]; then
    chk__set ok "skipped: no agent plist yet"
    return 0
  fi
  grep -A1 -F '<key>OBJC_DISABLE_INITIALIZE_FORK_SAFETY</key>' "$plist" | grep -q -F '<string>YES</string>' || missing="${missing} OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES"
  grep -A1 -F '<key>NO_PROXY</key>' "$plist" | grep -q -F '<string>*</string>' || missing="${missing} NO_PROXY=*"
  if [[ -n "$missing" ]]; then
    chk__set warn "the agent does not pass${missing} to the workers" "${SCRIPT_DIR}/benchbar repair" write_plist
  else
    chk__set ok "the agent passes OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES and NO_PROXY=* to every process"
  fi
}

# A killed "bench start" leaves redis, socketio or gunicorn on the bench's
# ports; the agent then cannot start. honcho running (benchfg or the agent)
# means the listeners are its own.
chk_orphans() {
  local port who held=""
  [[ "$(fl_agent_field state)" == "running" ]] && { chk__set ok "the agent runs this bench"; return 0; }
  if [[ -n "$(fl_bench_honcho_pids)" ]]; then
    chk__set ok "honcho is running (benchfg or bench start)"
    return 0
  fi
  for port in $(fl_bench_ports_csv | tr ',' ' '); do
    who="$(fl_port_listener_summary "$port")"
    [[ -n "$who" ]] && held="${held}${held:+, }${port} (pid ${who% *} ${who#* })"
  done
  if [[ -n "$held" ]]; then
    chk__set warn "stale processes hold this bench's ports: ${held}" "${SCRIPT_DIR}/benchbar down   (or benchbar restart)"
  else
    chk__set ok "no stale process holds ${FL_WEB_PORT}, ${FL_SOCKETIO_PORT}, ${FL_REDIS_QUEUE_PORT} or ${FL_REDIS_CACHE_PORT}"
  fi
}

# Apps: local reads only (apps.txt, the folders, git), never bench or the
# network. repair has no action for them: changing code is a person's call.
chk_apps_txt() {
  local app missing="" unlisted n=0
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    n=$((n + 1))
    [[ -d "$(fl_app_path "$app")" ]] || missing="${missing}${missing:+ }${app}"
  done < <(fl_apps_txt)
  unlisted="$(fl_apps_unlisted | tr '\n' ' ')"; unlisted="${unlisted% }"
  if [[ -n "$missing" ]]; then
    chk__set fail "sites/apps.txt lists ${missing} but apps/ has no such folder (every bench command fails to import it)" "benchbar app add ${missing%% *} --bench-dir ${FL_BENCH_DIR}"
  elif [[ -n "$unlisted" ]]; then
    chk__set warn "apps/${unlisted// /, apps/} is a git app that is not in sites/apps.txt (a get-app that did not finish?)" "mv ${FL_BENCH_DIR}/apps/${unlisted%% *} ~/${unlisted%% *}.aside, then: benchbar app add <its git URL>"
  else
    chk__set ok "${n} apps in sites/apps.txt, all present"
  fi
}

chk_app_branch_policy() {
  local app want cur off="" fix="" n=0
  while IFS= read -r app; do
    if [[ -z "$app" ]] || ! fl_app_has_git "$app"; then continue; fi
    want="$(fl_app_policy_branch "$app")"
    [[ -n "$want" ]] || continue
    cur="$(fl_app_branch "$app")"
    [[ -n "$cur" ]] || continue
    n=$((n + 1))
    if [[ "$cur" != "$want" ]]; then
      off="${off}${off:+, }${app} is on ${cur} (policy ${want})"
      [[ -n "$fix" ]] || fix="cd ${FL_BENCH_DIR}/apps/${app} && git fetch $(fl_app_remote "$app") ${want} && git checkout ${want}   (only if you meant to follow the policy)"
    fi
  done < <(fl_apps_txt)
  if [[ -n "$off" ]]; then
    chk__set warn "${off}" "$fix"
  elif [[ "$n" == "0" ]]; then
    chk__set ok "no app with a branch policy is a git checkout"
  else
    chk__set ok "${n} app(s) on the branch config/apps.tsv names for ${FL_PROFILE}"
  fi
}
