#!/usr/bin/env bash

fl_bench_run() {
  local bench_dir="$1"; shift
  FL_LAST_COMMAND="cd ${bench_dir} && $*"
  if [[ "$FL_DRY_RUN" == "1" ]]; then
    fl_info "dry-run: ${FL_LAST_COMMAND}"
    return 0
  fi
  (cd "$bench_dir" && "$@")
}

fl_install_pipx_if_needed() {
  # uv is preferred for bench itself; pipx is only needed without it
  command -v uv >/dev/null 2>&1 && return 0
  fl_section "PIPX"
  fl_info "Checking pipx"
  if command -v pipx >/dev/null 2>&1; then
    fl_ok "pipx already installed - $(pipx --version)"
  else
    fl_warn "pipx is missing; installing with Homebrew"
    fl_run brew install pipx || fl_die "pipx install failed." "Manual command: brew install pipx"
  fi
  PIPX_BIN_DIR="$(pipx environment --value PIPX_BIN_DIR 2>/dev/null || echo "$HOME/.local/bin")"
  export PATH="${PIPX_BIN_DIR}:$PATH"
  fl_state_set PIPX_BIN_DIR "$PIPX_BIN_DIR"
}

fl_install_bench_if_needed() {
  fl_section "BENCH CLI"
  fl_info "Checking frappe-bench CLI"
  if command -v bench >/dev/null 2>&1; then
    fl_ok "bench at $(command -v bench)"
    return 0
  fi
  if command -v uv >/dev/null 2>&1; then
    # the official docs install bench with uv; uv says where its executables
    # go (UV_TOOL_BIN_DIR, XDG_BIN_HOME, else ~/.local/bin)
    fl_warn "frappe-bench is missing; installing with uv"
    fl_run uv tool install frappe-bench || fl_die "frappe-bench install failed." "Manual command: uv tool install frappe-bench"
    PIPX_BIN_DIR="$(uv tool dir --bin 2>/dev/null || true)"
    PIPX_BIN_DIR="${PIPX_BIN_DIR:-$HOME/.local/bin}"
    export PATH="${PIPX_BIN_DIR}:$PATH"
  elif pipx list 2>/dev/null | grep -q '^   package frappe-bench'; then
    fl_info "frappe-bench already installed via pipx"
  else
    fl_warn "frappe-bench is missing; installing with pipx"
    fl_run pipx install frappe-bench || fl_die "frappe-bench install failed." "Manual command: pipx install frappe-bench"
  fi
  [[ "$FL_DRY_RUN" == "1" ]] && return 0
  command -v bench >/dev/null 2>&1 || fl_die "bench command not found after installing frappe-bench." "Manual check: ls ${PIPX_BIN_DIR:-$HOME/.local/bin}/bench"
  fl_state_set BENCH_BIN "$(command -v bench)"
  fl_ok "bench version: $(bench --version 2>/dev/null || echo installed)"
}

fl_bench_complete() {
  local bench_dir="$1"
  [[ -d "$bench_dir/apps/frappe" && -d "$bench_dir/env" && -f "$bench_dir/sites/apps.txt" ]]
}

# A bench that has real content (apps or sites) must never be moved aside
# by the installer, even when env/ or node_modules are gone.
fl_bench_has_data() {
  local bench_dir="$1" s
  [[ -d "$bench_dir/apps/frappe" ]] && return 0
  for s in "$bench_dir"/sites/*/site_config.json; do
    [[ -f "$s" ]] && return 0
  done
  return 1
}

# fl_bench_run_long LABEL BENCH_DIR COMMAND...: a slow bench command with a spinner
fl_bench_run_long() {
  local label="$1" bench_dir="$2"
  shift 2
  fl_run_long "$label" fl__in_dir "$bench_dir" "$@"
}

fl__in_dir() {
  local dir="$1"
  shift
  (cd "$dir" && "$@")
}

fl_bench_init_if_needed() {
  local bench_dir="$1" frappe_ref="$2" python_bin="$3" repair="${4:-0}" timestamp backup
  local timeout_seconds="${BENCH_INIT_TIMEOUT_SECONDS:-2700}"
  fl_section "BENCH INIT"
  fl_info "Checking bench directory ${bench_dir}"
  if fl_bench_complete "$bench_dir"; then
    fl_ok "${bench_dir} already initialized"
    fl_state_set BENCH_INIT complete
    return 0
  fi
  if [[ -e "$bench_dir" ]]; then
    if fl_bench_has_data "$bench_dir"; then
      fl_die "Bench ${bench_dir} has apps or sites but its env is missing or incomplete." "This is a repair, not a reinstall. Run: ${SCRIPT_DIR}/benchbar repair --bench-dir ${bench_dir}"
    fi
    if [[ "$repair" != "1" ]]; then
      fl_die "Bench directory exists but is incomplete: ${bench_dir}" "Move it aside or rerun with --repair-bench after reading: mv ${bench_dir} ${bench_dir}.incomplete.\$(date +%Y%m%d%H%M%S)"
    fi
    timestamp="$(date +%Y%m%d%H%M%S)"
    backup="${bench_dir}.incomplete.${timestamp}"
    fl_warn "Moving incomplete bench to ${backup}"
    fl_run mv "$bench_dir" "$backup"
  fi
  # --no-backups keeps bench init away from crontab: a dev bench needs no
  # backup cron, and without Full Disk Access the crontab write fails and
  # bench offers to delete the new bench (frappe/bench#1730)
  if fl_crontab_denied; then
    fl_warn "crontab is not readable here (no Full Disk Access); bench init runs with --no-backups, so it is not needed"
    fl_info "for bench setup backups later: System Settings > Privacy & Security > Full Disk Access, add Terminal"
  fi
  fl_info "Running bench init for frappe ref ${frappe_ref}"
  fl_info "bench init timeout: $((timeout_seconds / 60)) minutes"
  fl_run_with_timeout "$timeout_seconds" "bench init" bench init "$bench_dir" --frappe-branch "$frappe_ref" --python "$python_bin" --no-backups --verbose \
    || fl_die "bench init failed." "Manual command: bench init ${bench_dir} --frappe-branch ${frappe_ref} --python ${python_bin} --no-backups --verbose"
  fl_state_set BENCH_INIT complete
}

fl_get_app_if_needed() {
  local bench_dir="$1" app="$2" branch="$3" repo="${4:-}" commit="${5:-}" pin="${6:-0}"
  fl_info "Checking app ${app}"
  if [[ -d "$bench_dir/apps/$app" ]]; then
    fl_ok "apps/${app} already cloned"
  else
    fl_info "Getting ${app} at ${branch}"
    if [[ -n "$repo" ]]; then
      fl_bench_run_long "bench get-app ${app} (${branch})" "$bench_dir" bench get-app --branch "$branch" "$repo" \
        || fl_die "bench get-app failed for ${app}." "Manual command: cd ${bench_dir} && bench get-app --branch ${branch} ${repo}"
    else
      fl_bench_run_long "bench get-app ${app} (${branch})" "$bench_dir" bench get-app --branch "$branch" "$app" \
        || fl_die "bench get-app failed for ${app}." "Manual command: cd ${bench_dir} && bench get-app --branch ${branch} ${app}"
    fi
  fi
  if [[ "$pin" == "1" && -n "$commit" && -d "$bench_dir/apps/$app/.git" ]]; then
    fl_warn "Pinning ${app} to commit ${commit}"
    fl_run git -C "$bench_dir/apps/$app" fetch --all --tags
    fl_run git -C "$bench_dir/apps/$app" checkout "$commit" \
      || fl_die "commit checkout failed for ${app}." "Manual command: git -C ${bench_dir}/apps/${app} checkout ${commit}"
  fi
  fl_state_set "APP_${app}_CLONED" yes
}

# ---------------------------------------------------------------- setup redis
#
# frappe v16 connects to the bench's Redis during new-site and install-app
# (a fresh v16 bench failed "install-app erpnext" with "Connection refused"
# on its redis_queue port). Before the service exists nothing runs them, so
# setup starts the bench's own Redis servers from config/redis_*.conf, and
# afterwards stops only the ones it started.

FL_SETUP_REDIS_PORTS=""

# The working folder of whatever listens on PORT (the bench's own Redis runs
# inside the bench), or nothing when nothing listens or it cannot be read.
fl_port_owner_cwd() {
  local pid
  pid="$(lsof -ti "tcp:$1" -sTCP:LISTEN 2>/dev/null | head -n1 || true)"
  [[ -n "$pid" ]] || return 0
  lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n1
}

fl_bench_redis_up() {
  local bench_dir="$1" conf port owner
  [[ "$FL_DRY_RUN" == "1" ]] && { fl_info "dry-run: start the bench's Redis (config/redis_queue.conf, config/redis_cache.conf) for the site setup"; return 0; }
  for conf in "$bench_dir"/config/redis_queue.conf "$bench_dir"/config/redis_cache.conf; do
    [[ -f "$conf" ]] || continue
    port="$(awk '$1 == "port" {print $2; exit}' "$conf")"
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    if fl_port_listening "$port"; then
      # the bench's own Redis (running bench): use it. Anything else, for
      # example another bench on the same default ports, must not receive
      # this bench's cache and queued install jobs.
      owner="$(fl_port_owner_cwd "$port")"
      case "$owner" in
        "$bench_dir"|"$bench_dir"/*) continue ;;
      esac
      fl_die "Port ${port} (config/$(basename "$conf")) is held by another process$([[ -n "$owner" ]] && printf ' running in %s' "$owner"), not this bench's Redis." \
        "Give this bench its own ports first: benchbar service --port-offset N --bench-dir ${bench_dir}, then run this again."
    fi
    # its complaints (a bad config, a folder it cannot write) go to the run log
    if (cd "$bench_dir" && redis-server "config/$(basename "$conf")" --daemonize yes) >>"${FL_LOG_FILE:-/dev/null}" 2>&1; then
      FL_SETUP_REDIS_PORTS="${FL_SETUP_REDIS_PORTS} ${port}:$(basename "$conf" .conf)"
      fl_info "started the bench's Redis on ${port} for the site setup"
    else
      fl_warn "could not start Redis from ${conf}; site setup may fail"
    fi
  done
  return 0
}

fl_bench_redis_down() {
  local entry port mode
  for entry in $FL_SETUP_REDIS_PORTS; do
    port="${entry%%:*}"
    # the queue keeps jobs an app install enqueued for the first worker; the cache may go
    mode=nosave; [[ "$entry" == *:redis_queue ]] && mode=save
    redis-cli -p "$port" shutdown "$mode" >>"${FL_LOG_FILE:-/dev/null}" 2>&1 || true
    fl_info "stopped the setup Redis on ${port}"
  done
  FL_SETUP_REDIS_PORTS=""
  return 0
}

fl_new_site_if_needed() {
  local bench_dir="$1" site_name="$2" db_password="$3" admin_password="$4"
  fl_section "CREATE SITE"
  fl_info "Checking site ${site_name}"
  if [[ -d "$bench_dir/sites/$site_name" ]]; then
    fl_ok "Site ${site_name} already exists"
    fl_state_set SITE_CREATED yes
    return 0
  fi
  fl_bench_run_long "bench new-site ${site_name}" "$bench_dir" bench new-site "$site_name" \
    --mariadb-root-password "$db_password" \
    --admin-password "$admin_password" \
    --no-mariadb-socket \
    || fl_die "bench new-site failed." "Manual command: cd ${bench_dir} && bench new-site ${site_name} --no-mariadb-socket"
  fl_state_set SITE_CREATED yes
}

fl_install_app_if_needed() {
  local bench_dir="$1" site_name="$2" app="$3" installed
  fl_info "Checking site app ${app}"
  if [[ "$FL_DRY_RUN" == "1" && ! -d "$bench_dir" ]]; then
    installed=""
  else
    # shellcheck disable=SC2015  # an unreadable list means "nothing installed yet"
    installed="$(cd "$bench_dir" && bench --site "$site_name" list-apps 2>/dev/null || true)"
  fi
  if printf '%s\n' "$installed" | awk '{print $1}' | grep -qx "$app"; then
    fl_ok "${app} already installed on ${site_name}"
  else
    fl_bench_run_long "bench install-app ${app} on ${site_name}" "$bench_dir" bench --site "$site_name" install-app "$app" \
      || fl_die "bench install-app failed for ${app}." "Manual command: cd ${bench_dir} && bench --site ${site_name} install-app ${app}"
  fi
  fl_state_set "APP_${app}_INSTALLED" yes
}

fl_verify_site_health() {
  local bench_dir="$1" site_name="$2"
  fl_section "VERIFY SITE"
  fl_bench_run "$bench_dir" bench --site "$site_name" list-apps
  if [[ "$FL_DRY_RUN" == "1" ]]; then
    fl_info "dry-run: cd ${bench_dir} && bench --site ${site_name} doctor"
    fl_info "dry-run: cd ${bench_dir} && bench use ${site_name}"
    return 0
  fi
  if ! (cd "$bench_dir" && bench --site "$site_name" doctor); then
    fl_warn "bench doctor reported issues; the site may still be usable."
  fi
  # bench use rewrites currentsite.txt every time; a rerun must write nothing
  if [[ "$(tr -d '[:space:]' <"$bench_dir/sites/currentsite.txt" 2>/dev/null)" != "$site_name" ]]; then
    fl_bench_run "$bench_dir" bench use "$site_name"
  fi
}
