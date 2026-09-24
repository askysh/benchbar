#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# repair.sh: repair actions in dependency order, each with a backup, plus
# the check -> plan -> apply -> verify engine shared by "repair" and
# "service" (the background phase).

FL_ACTION_ORDER="python_leaves env_rebuild honcho_install node_requirements build clear_cache mariadb_bind legacy_migrate write_procfile write_runner write_plist write_helpers write_cli_link hosts_entry rotate_logs redis_stop"
FL_NEED_CLEAR_CACHE=0
# set by legacy_migrate when it booted out an agent that was running the
# bench, so write_plist starts the bench again under the new agent
FL_MIGRATED_RUNNING=0

fl_action_label() {
  case "$1" in
    python_leaves) printf 'mark %s as user-installed' "$FL_PYTHON_FORMULA" ;;
    honcho_install) printf 'install honcho into the bench env' ;;
    env_rebuild) printf 'rebuild the bench env (old env moved aside)' ;;
    node_requirements) printf 'bench setup requirements --node' ;;
    build) printf 'bench build' ;;
    clear_cache) printf 'bench clear-cache and clear-website-cache' ;;
    mariadb_bind) printf 'bind MariaDB to 127.0.0.1' ;;
    legacy_migrate) printf 'migrate legacy launchd agents' ;;
    write_procfile) printf 'write Procfile.lean' ;;
    write_runner) printf 'write the runner script' ;;
    write_plist) printf 'write and load the launchd agent' ;;
    write_helpers) printf 'write the shell helper block' ;;
    write_cli_link) printf 'link benchbar and frappe-mac into ~/.local/bin' ;;
    hosts_entry) printf 'add %s to /etc/hosts (sudo)' "$FL_SITE" ;;
    rotate_logs) printf 'move large logs aside' ;;
    redis_stop) printf 'stop Homebrew redis on 6379' ;;
    *) printf '%s' "$1" ;;
  esac
}

fl_bench_env_exports() {
  local brew="${FL_BREW_PREFIX:-/opt/homebrew}"
  export PATH="${brew}/opt/${FL_PYTHON_FORMULA}/bin:${brew}/opt/${FL_NODE_FORMULA}/bin:${brew}/opt/${FL_MARIADB_FORMULA}/bin:$HOME/.local/bin:${brew}/bin:$PATH"
  export LDFLAGS="-L${brew}/opt/openssl@3/lib -L${brew}/opt/libffi/lib -L${brew}/opt/zlib/lib"
  export CPPFLAGS="-I${brew}/opt/openssl@3/include -I${brew}/opt/libffi/include -I${brew}/opt/zlib/include"
  export PKG_CONFIG_PATH="${brew}/opt/openssl@3/lib/pkgconfig:${brew}/opt/libffi/lib/pkgconfig:${brew}/opt/zlib/lib/pkgconfig"
}

fl_in_bench() {
  (cd "$FL_BENCH_DIR" && "$@")
}

act_python_leaves() {
  if brew tab --help >/dev/null 2>&1; then
    fl_run brew tab --installed-on-request "$FL_PYTHON_FORMULA"
  else
    fl_run_long "brew reinstall ${FL_PYTHON_FORMULA}" brew reinstall "$FL_PYTHON_FORMULA"
  fi
}

act_honcho_install() {
  if fl_honcho_resolve; then
    fl_ok "honcho already available at ${FL_HONCHO}"
    fl_state_set HONCHO_BIN "$FL_HONCHO"
    fl_render_all
    return 0
  fi
  fl_honcho_install || return 1
  [[ -n "$FL_HONCHO" ]] && fl_state_set HONCHO_BIN "$FL_HONCHO"
  fl_render_all
}

act_env_rebuild() {
  local py
  py="$(fl_python_bin)"
  [[ -x "$py" ]] || py="$(command -v "$FL_PYTHON_BIN_NAME" || true)"
  [[ -n "$py" ]] || { fl_fail "${FL_PYTHON_BIN_NAME} not found; run 00-mac-system-deps.sh first"; return 1; }
  fl_bench_env_exports
  fl_move_aside "${FL_BENCH_DIR}/env" broken
  fl_run_long "bench setup env --python ${py}" fl_in_bench bench setup env --python "$py" || return 1
  fl_run_long "bench setup requirements --python" fl_in_bench bench setup requirements --python || return 1
  FL_NEED_CLEAR_CACHE=1
  if ! fl_honcho_resolve; then
    fl_info "honcho lived in the old env; installing it into the new one"
    fl_honcho_install || return 1
  fi
  [[ -n "$FL_HONCHO" ]] && fl_state_set HONCHO_BIN "$FL_HONCHO"
  fl_render_all
}

act_node_requirements() {
  fl_bench_env_exports
  fl_run_long "bench setup requirements --node" fl_in_bench bench setup requirements --node || return 1
  FL_NEED_CLEAR_CACHE=1
}

act_build() {
  fl_bench_env_exports
  fl_run_long "bench build" fl_in_bench bench build || return 1
  FL_NEED_CLEAR_CACHE=1
}

act_clear_cache() {
  fl_bench_env_exports
  fl_run_long "bench --site all clear-cache" fl_in_bench bench --site all clear-cache || true
  fl_run_long "bench --site all clear-website-cache" fl_in_bench bench --site all clear-website-cache || true
  FL_NEED_CLEAR_CACHE=0
}

fl_mariadb_service_formula() {
  local f
  f="$(brew services list 2>/dev/null | awk '$1 ~ /^mariadb/ && $2 == "started" {print $1; exit}' || true)"
  printf '%s' "${f:-$FL_MARIADB_FORMULA}"
}

act_mariadb_bind() {
  local brew="${FL_BREW_PREFIX:-/opt/homebrew}" mycnf dropin rendered formula
  mycnf="${brew}/etc/my.cnf"
  dropin="$(fl_mariadb_dropin_path)"
  if [[ -f "$mycnf" ]] && ! grep -q "^!includedir ${brew}/etc/my.cnf.d" "$mycnf"; then
    if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
      fl_info "dry-run: would append '!includedir ${brew}/etc/my.cnf.d' to ${mycnf}"
    else
      fl_backup_file "$mycnf"
      printf '\n!includedir %s/etc/my.cnf.d\n' "$brew" >>"$mycnf"
      fl_ok "added !includedir to ${mycnf}"
    fi
  elif [[ ! -f "$mycnf" ]]; then
    if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
      fl_info "dry-run: would create ${mycnf} with !includedir"
    else
      mkdir -p "$(dirname "$mycnf")"
      printf '[client-server]\n!includedir %s/etc/my.cnf.d\n' "$brew" >"$mycnf"
      fl_ok "created ${mycnf}"
    fi
  fi
  rendered="$(fl_template_render mariadb-local-only.cnf)"
  fl_template_apply "$dropin" "$rendered" 644
  [[ "$FL_TEMPLATE_CHANGED" == "1" && "${FL_DRY_RUN:-0}" != "1" ]] && fl_ok "wrote ${dropin}"
  if [[ -n "$(fl_port_listen_addresses 3306)" ]]; then
    formula="$(fl_mariadb_service_formula)"
    fl_run_long "brew services restart ${formula}" brew services restart "$formula" || return 1
  fi
}

act_legacy_migrate() {
  local list path label state code
  list="$(fl_legacy_agents_list)"
  [[ -n "$list" ]] || return 0
  fl_bench_is_running && FL_MIGRATED_RUNNING=1
  while IFS='|' read -r path label state code; do
    [[ -n "$path" ]] || continue
    fl_info "${label}: ${state}, last exit code ${code}"
    fl_legacy_agent_migrate "$path" "$label"
  done <<<"$list"
}

act_write_procfile() {
  fl_template_apply "$(fl_procfile_path)" "$FL_R_PROCFILE" 644
  [[ "$FL_TEMPLATE_CHANGED" == "1" && "${FL_DRY_RUN:-0}" != "1" ]] && fl_ok "wrote $(fl_procfile_path)"
  return 0
}

act_write_runner() {
  [[ "${FL_DRY_RUN:-0}" == "1" ]] || mkdir -p "${FL_BENCH_DIR}/logs"
  fl_template_apply "$(fl_runner_path)" "$FL_R_RUNNER" 755
  [[ "$FL_TEMPLATE_CHANGED" == "1" && "${FL_DRY_RUN:-0}" != "1" ]] && fl_ok "wrote $(fl_runner_path)"
  return 0
}

# Writes the plist and (re)loads the agent. A bench that is not running
# gets a "manual" stop flag first so the reload never starts it by surprise.
act_write_plist() {
  local plist was_running=0 flag
  plist="$(fl_agent_plist_path)"
  flag="$(fl_stop_flag_path)"
  if fl_bench_is_running || [[ "$FL_MIGRATED_RUNNING" == "1" ]]; then was_running=1; fi
  if [[ "$was_running" == "0" && ! -f "$flag" ]]; then
    if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
      fl_info "dry-run: would write 'manual' to ${flag} so the agent does not auto-start"
    else
      mkdir -p "$(dirname "$flag")"
      printf 'manual\n' >"$flag"
    fi
  fi
  [[ "${FL_DRY_RUN:-0}" == "1" ]] || mkdir -p "$(dirname "$plist")"
  fl_template_apply "$plist" "$FL_R_PLIST" 644
  [[ "$FL_TEMPLATE_CHANGED" == "1" && "${FL_DRY_RUN:-0}" != "1" ]] && fl_ok "wrote ${plist}"
  if fl_agent_loaded; then
    [[ "$FL_TEMPLATE_CHANGED" == "1" ]] || return 0
    fl_agent_bootout
  fi
  fl_agent_bootstrap "$plist" || { fl_fail "launchctl could not load ${plist}"; return 1; }
  if [[ "$was_running" == "1" ]]; then
    # RunAtLoad starts it unless autostart is off; kickstart is a no-op when it already runs
    fl_agent_kickstart >/dev/null 2>&1 || true
    fl_ok "agent reloaded; the bench restarts under the new agent"
  else
    fl_ok "agent loaded (bench stays stopped until benchup)"
  fi
}

act_write_helpers() {
  local rc
  rc="$(fl_rc_file)"
  fl_rc_block_write "$rc" "$FL_R_HELPERS"
  [[ "${FL_DRY_RUN:-0}" == "1" ]] || fl_ok "helper block written to ${rc} (open a new shell or: source ${rc})"
}

act_write_cli_link() {
  local name link dir
  dir="$(dirname "$(fl_cli_link_path)")"
  for name in benchbar frappe-mac; do
    link="$(fl_cli_link_path "$name")"
    fl_cli_link_ok "$link" && continue
    if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
      fl_info "dry-run: ln -sfn ${SCRIPT_DIR}/benchbar ${link}"
      continue
    fi
    [[ -e "$link" && ! -L "$link" ]] && { fl_warn "${link} is a regular file; not touching it"; continue; }
    mkdir -p "$dir"
    ln -sfn "${SCRIPT_DIR}/benchbar" "$link"
    fl_ok "linked ${link}"
  done
  [[ "${FL_DRY_RUN:-0}" == "1" ]] && return 0
  case ":$PATH:" in
    *":${dir}:"*) ;;
    *) fl_info "${dir} is not on PATH in this shell; the helper block adds it for new shells" ;;
  esac
}

act_hosts_entry() {
  if fl_hosts_has_site; then
    return 0
  fi
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would run: printf '127.0.0.1 ${FL_SITE}\\n' | sudo tee -a ${FL_HOSTS_FILE}"
    return 0
  fi
  if ! fl_confirm "Add '127.0.0.1 ${FL_SITE}' to ${FL_HOSTS_FILE} with sudo?"; then
    fl_warn "skipped; run: printf '127.0.0.1 ${FL_SITE}\\n' | sudo tee -a ${FL_HOSTS_FILE}"
    return 0
  fi
  fl_backup_file "$FL_HOSTS_FILE"
  printf '127.0.0.1 %s\n' "$FL_SITE" | sudo tee -a "$FL_HOSTS_FILE" >/dev/null || { fl_fail "sudo tee failed"; return 1; }
  fl_ok "added ${FL_SITE} to ${FL_HOSTS_FILE}"
}

act_rotate_logs() {
  local f mb
  for f in bench.log worker.log worker.error.log; do
    mb="$(fl_file_mb "${FL_BENCH_DIR}/logs/${f}")"
    [[ "$mb" -ge "$FL_LOG_WARN_MB" ]] || continue
    fl_move_aside "${FL_BENCH_DIR}/logs/${f}" old
  done
}

act_redis_stop() {
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would offer to stop Homebrew redis on 6379"
    return 0
  fi
  if [[ "${FL_ASSUME_YES:-0}" == "1" ]]; then
    fl_info "not stopping redis on 6379 automatically under --yes; run: brew services stop redis"
    return 0
  fi
  if fl_confirm "Stop Homebrew redis on 6379? (only if nothing else on this Mac uses it)"; then
    fl_run brew services stop redis || return 1
    fl_ok "stopped Homebrew redis"
  else
    fl_info "left redis running"
  fi
}

# ---------------------------------------------------------------- engine

# fl_repair_engine TITLE [GROUP...]: check, plan, confirm, apply, verify.
# Returns 0 when everything is healthy afterwards, 1 when something failed.
fl_repair_engine() {
  shift
  local actions action i n=0 rows=() unchanged remaining status labels
  fl_doctor_run "$@"
  actions="$(fl_doctor_actions)"
  unchanged=$(( ${#FL_D_IDS[@]} - $(fl_doctor_count warn) - $(fl_doctor_count fail) ))

  printf '\n%sPlan%s\n' "$FL_BOLD" "$FL_RESET"
  fl_doctor_print compact
  if [[ -z "$actions" ]]; then
    printf '\n'
    if [[ "$(fl_doctor_count fail)" != "0" ]]; then
      fl_warn "unchanged: nothing benchbar can repair automatically; follow the fix lines above"
      return 1
    fi
    if [[ "$(fl_doctor_count warn)" != "0" ]]; then
      fl_ok "unchanged: $(fl_doctor_count ok) checks pass, $(fl_doctor_count warn) warning(s) need a manual step (see above)"
      return 0
    fi
    fl_ok "unchanged: all ${#FL_D_IDS[@]} checks pass, nothing to do"
    return 0
  fi

  rows+=("#|Action|Fixes")
  for action in $actions; do
    n=$((n + 1))
    labels="$(fl_doctor_checks_for_action "$action" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
    rows+=("${n}|$(fl_action_label "$action")|${labels}")
  done
  printf '\n'
  fl_table "${rows[@]}"
  printf '\n  %s%d unchanged, %d to update%s\n' "$FL_BOLD" "$unchanged" "$n" "$FL_RESET"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    printf '\n'
    fl_info "dry-run: nothing will be changed; the steps below only describe what would happen"
  elif [[ "${FL_SKIP_PLAN_CONFIRM:-0}" == "1" ]]; then
    fl_info "applying ${n} change(s)"
  elif ! fl_confirm "Apply ${n} change(s)?"; then
    fl_warn "Cancelled. Nothing was changed."
    return 1
  fi

  labels=()
  for action in $actions; do labels+=("$(fl_action_label "$action")"); done
  [[ "$FL_NEED_CLEAR_CACHE" == "1" ]] || true
  fl_steps_define "${labels[@]}"
  i=0
  status=0
  for action in $actions; do
    fl_step_begin "$i"
    if "act_${action}"; then
      fl_step_end "done"
    else
      fl_step_end failed
      status=1
      case "$action" in
        env_rebuild|honcho_install) fl_warn "stopping: later steps depend on this one"; break ;;
      esac
    fi
    i=$((i + 1))
  done
  if [[ "$FL_NEED_CLEAR_CACHE" == "1" && "$status" == "0" ]]; then
    fl_info "clearing caches after the rebuild"
    act_clear_cache || true
  fi

  remaining=""
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: skipping the verify pass because nothing was changed"
  else
    printf '\n%sVerify%s\n' "$FL_BOLD" "$FL_RESET"
    fl_doctor_run "$@"
    fl_doctor_print compact
    remaining="$(fl_doctor_actions)"
  fi
  fl_steps_summary
  if [[ "$status" != "0" ]]; then
    return 1
  fi
  if [[ -n "$remaining" && "${FL_DRY_RUN:-0}" != "1" ]]; then
    fl_warn "some checks still need attention; see the fix lines above"
    return 1
  fi
  return 0
}
