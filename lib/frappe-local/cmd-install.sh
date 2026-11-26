#!/usr/bin/env bash
#
# cmd-install.sh: the body of "benchbar install" and the helpers it is made of (the plan, the
# privileged steps, the sudo reasons, the boxes it ends with). fl_next_steps_box and
# fl_remember_bench are also called by cmd-service.sh and cmd-adopt.sh. Moved out of the entry
# point as it was (CORE-18, issue 151). A lean start does not load this file.

fl_next_steps_box() {
  fl_box "Next steps" \
    "$(fl_rc_source_hint "      (once, so benchup and friends exist)")" \
    "benchup                     start the bench in the background" \
    "$(fl_open_cmd) $(fl_site_url)" \
    "benchstatus / benchlogs     check on it" \
    "benchrestart                after changing Python code" \
    "benchwatch                  while editing JS or CSS"
}

# after an install that did not finish its service step: the fix first, and
# benchup only once it is done (a bench with no loaded service cannot start)
fl_install_fix_box() {
  local bd=""
  [[ "$FL_BENCH_DIR" == "$(fl_state_get BENCH_DIR 2>/dev/null || true)" ]] || bd=" --bench-dir ${FL_BENCH_DIR}"
  fl_box "Next steps" \
    "benchbar repair${bd}    fix what failed above" \
    "benchbar doctor${bd}    what is left, if repair says it is done" \
    "then: benchup, and $(fl_open_cmd) $(fl_site_url)"
}

# One sudo prompt for the whole install: ask up front when a step ahead will
# need it (the wkhtmltopdf package, the /etc/hosts line). The two privileged
# steps run right after (fl_install_privileged_steps) and the credential is
# dropped before the phases run any third party code.
# fl_install_sudo_reasons: what this run needs sudo for, one per line (none
# on a set up machine, and none under BENCHBAR_SUDO=gui on a Mac: each of the
# two steps asks in its own dialog, when it runs)
fl_install_sudo_reasons() {
  local reason
  if fl_is_linux; then
    # apt, the MariaDB admin step, its drop-in and the .deb: only what this
    # run needs (a set up machine asks for nothing); no /etc/hosts line
    while IFS= read -r reason; do [[ -n "$reason" ]] && printf '%s\n' "$reason"; done < <(fl_linux_sudo_reasons)
    return 0
  fi
  fl_sudo_gui && return 0
  # only when phase 00 will get as far as the installer in this run: without
  # Rosetta and without a way to agree to it, or after a declined download,
  # the package is skipped and a sudo prompt for it would be asked for nothing
  fl_wkhtmltopdf_will_install && printf '%s\n' "install the patched wkhtmltopdf package (installer -pkg)"
  fl_hosts_has_site || printf '%s\n' "add '127.0.0.1 ${FL_SITE}' to ${FL_HOSTS_FILE}"
  return 0
}

fl_install_sudo_upfront() {
  local reasons=() reason
  [[ "$FL_DRY_RUN" == "1" ]] && return 0
  while IFS= read -r reason; do [[ -n "$reason" ]] && reasons+=("$reason"); done < <(fl_install_sudo_reasons)
  [[ "${#reasons[@]}" -gt 0 ]] || return 0
  fl_sudo_begin "${reasons[@]}" || true
}

# The only two things that run as root, done first and together: the patched
# wkhtmltopdf package and the /etc/hosts line. Same questions and skips as
# phase 00 and repair (a declined Rosetta or package, a refused sudo); phase
# 00 then finds the package in place and the service pass finds the line.
# Sets FL_INSTALL_PDF_STEP to skipped or failed for phase 00's summary when
# the package is not there afterwards.
fl_install_privileged_steps() {
  local code=0 state from start hosts_before=0
  FL_INSTALL_PDF_STEP=""
  # nothing to do for a patched build (phase 00 reports it); otherwise the
  # same Rosetta, download and install flow as phase 00 and repair
  state="$(fl_wkhtmltopdf_state)"
  if [[ "$state" != "patched" ]]; then
    fl_log_lines_v from; start="$SECONDS"
    fl_jsonl_step "" wkhtmltopdf_install "" "$FL_INSTALL_PDF_NAME" running
    FL_SKIP_COMMAND=""
    fl_wkhtmltopdf_ensure || code=$?
    fl_install_priv_end wkhtmltopdf_install "$FL_INSTALL_PDF_NAME" "$code" "$from" "$start"
  fi
  case "$code" in
    0) [[ "$FL_DRY_RUN" == "1" && "$state" != "patched" ]] && FL_INSTALL_PDF_STEP=dry-run ;;  # the plan was shown here, once
    2) FL_INSTALL_PDF_STEP=skipped ;;
    *) FL_INSTALL_PDF_STEP=failed ;;
  esac
  # a refused sudo is not asked again in this run: the line waits for a later repair
  # (Linux has no hosts line: *.localhost resolves without one)
  if fl_is_linux; then return 0; fi
  if fl_hosts_has_site || ! fl_site_name_ok "$FL_SITE"; then hosts_before=1; fi
  if [[ "$hosts_before" == "0" ]]; then
    fl_log_lines_v from; start="$SECONDS"
    fl_jsonl_step "" hosts_entry "" "$(fl_install_hosts_name)" running
  fi
  code=0
  FL_STEP_RESULT="done"
  FL_SKIP_COMMAND=""
  act_hosts_entry || { code=$?; fl_warn "the /etc/hosts line could not be added now; run '${FL_SELF} repair' later, it asks for sudo again"; }
  if [[ "$hosts_before" == "0" ]]; then
    [[ "$code" != "0" || "$FL_STEP_RESULT" != "skipped" ]] || code=2
    fl_install_priv_end hosts_entry "$(fl_install_hosts_name)" "$code" "$from" "$start"
  fi
  return 0
}

# the two privileged steps, by name (the plan's and the dialog's)
FL_INSTALL_PDF_NAME="Install the patched wkhtmltopdf package"
fl_install_hosts_name() { fl_hosts_gui_reason "$FL_SITE"; }

# fl_install_priv_end ID NAME CODE LOG_FROM START: the end of a privileged step on
# the stream. CODE 0 done, 2 skipped (with the command to run by hand), else
# failed; the message is the CLI's own [WARN] or [FAIL] line.
fl_install_priv_end() {
  local id="$1" name="$2" code="$3" from="$4" start="$5" status="done" msg="" cmd=""
  case "$code" in
    0) ;;
    2) status=skipped; cmd="$FL_SKIP_COMMAND" ;;
    *) status=failed ;;
  esac
  [[ "$status" == "done" ]] || msg="$(fl_log_step_message "$from")"
  [[ "$status" != "skipped" ]] || fl_jsonl_skipped_add "$id" "$cmd"
  fl_jsonl_step "" "$id" "" "$name" "$status" "$((SECONDS - start))" "$msg" "$cmd"
}

# fl_remember_bench: this bench's own settings, and the default bench when
# fl_remember_default allows it. Returns 1 when another bench stays default.
fl_remember_bench() {
  local code=0
  fl_bench_state_migrate "$FL_BENCH_DIR"
  fl_remember_default "$FL_BENCH_DIR" || code=1
  fl_bstate_set SITE_NAME "$FL_SITE"
  fl_bstate_set PROFILE "$FL_PROFILE"
  # the team profile it follows (PROFILE is its base); a built in --profile clears it
  if [[ -n "$FL_TEAM_PROFILE" || -n "$OPT_PROFILE" ]]; then fl_bstate_set TEAM_PROFILE "$FL_TEAM_PROFILE"; fi
  # a bench set up before 0.4 has no MariaDB formula stored: the running
  # server's, when the profile accepts it, else the profile's own
  if [[ -z "$(fl_bstate_get MARIADB_FORMULA)" ]]; then
    fl_mariadb_prefer_running
    [[ "$FL_MARIADB_SOURCE" == "running" ]] && fl_bstate_set MARIADB_FORMULA "$FL_MARIADB_FORMULA"
  fi
  # the shell block follows the default bench, which may just have changed
  fl_render_all
  return "$code"
}

# fl_install_port_plan: the port block the new bench gets, chosen before any
# step runs so that the plan knows it: --port-offset, else the next free
# block when another bench or program has the default one (phase 01 writes
# it right after bench init). Sets INSTALL_PORT_OFFSET, INSTALL_PORT_BLOCK
# ("web socketio queue cache", empty for the bench's own ports),
# INSTALL_PORT_FREE (the offset to announce when the defaults are taken) and
# INSTALL_PORT_ERR=1 when no block is free. Prints nothing.
fl_install_port_plan() {
  local free
  INSTALL_PORT_BLOCK=""; INSTALL_PORT_FREE=""; INSTALL_PORT_ERR=0
  INSTALL_PORT_OFFSET=$((FL_WEB_PORT - FL_PORT_BASE_WEB))
  if [[ "$OPT_PORT_OFFSET" =~ ^[0-9]+$ ]]; then
    INSTALL_PORT_OFFSET="$OPT_PORT_OFFSET"
    INSTALL_PORT_BLOCK="$(fl_port_block "$OPT_PORT_OFFSET")"
  elif [[ ! -f "$FL_BENCH_DIR/sites/common_site_config.json" && -n "$(fl_port_block_conflicts 0)" ]]; then
    if free="$(fl_port_next_free_offset)"; then
      INSTALL_PORT_OFFSET="$free"; INSTALL_PORT_FREE="$free"
      INSTALL_PORT_BLOCK="$(fl_port_block "$free")"
    else
      INSTALL_PORT_ERR=1; INSTALL_PORT_OFFSET=""
    fi
  fi
}

# fl_install_plan_json BUNDLE: the plan line of install --json
fl_install_plan_json() {
  local pdf_run=0 hosts_run=0 pl_steps="" mode=terminal web_port team="null" label i=0 id sudo n token token_data
  # the plan describes the --yes run that follows a dry run
  if [[ "$(fl_wkhtmltopdf_state)" != "patched" ]] && FL_ASSUME_YES=1 fl_wkhtmltopdf_will_install; then pdf_run=1; fi
  if ! fl_is_linux && ! fl_hosts_has_site && fl_site_name_ok "$FL_SITE"; then hosts_run=1; fi
  fl_sudo_gui && mode=gui
  web_port="${INSTALL_PORT_BLOCK%% *}"; [[ -n "$web_port" ]] || web_port="$FL_WEB_PORT"
  [[ -z "$FL_TEAM_PROFILE" ]] || team="$(fl_json_str "$FL_TEAM_PROFILE")"
  local blockers="" warnings="" bl_id bl_msg bl_fix
  while IFS='|' read -r bl_id bl_msg bl_fix; do
    [[ -n "$bl_id" ]] || continue
    blockers="${blockers}${blockers:+,}{\"id\":$(fl_json_str "$bl_id"),\"message\":$(fl_json_str "$bl_msg"),\"fix\":$(fl_json_str "$bl_fix")}"
  done <<<"$FL_INSTALL_BLOCKERS"
  while IFS='|' read -r bl_id bl_msg bl_fix; do
    [[ -n "$bl_id" ]] || continue
    warnings="${warnings}${warnings:+,}{\"id\":$(fl_json_str "$bl_id"),\"message\":$(fl_json_str "$bl_msg"),\"fix\":$(fl_json_str "$bl_fix")}"
  done <<<"$FL_INSTALL_WARNINGS"
  pl_steps="{\"n\":null,\"id\":\"wkhtmltopdf_install\",\"name\":$(fl_json_str "$FL_INSTALL_PDF_NAME"),\"sudo\":true,\"will_run\":$(fl_json_bool "$pdf_run")}"
  pl_steps="${pl_steps},{\"n\":null,\"id\":\"hosts_entry\",\"name\":$(fl_json_str "$(fl_install_hosts_name)"),\"sudo\":true,\"will_run\":$(fl_json_bool "$hosts_run")}"
  for label in "${FL_STEP_LABELS[@]}"; do
    id="${FL_STEP_IDS[$i]}"; i=$((i + 1)); n="$i"
    pl_steps="${pl_steps},{\"n\":${n},\"id\":\"${id}\",\"name\":$(fl_json_str "$label"),\"sudo\":false,\"will_run\":true}"
  done
  FL_JSONL_URL="http://${FL_SITE}:${web_port}"
  # the token of the plan: its steps and the inputs that decide them (the bench, the site, the
  # profile, the bundle, the pins, the ports, the blockers); install --apply TOKEN --yes is refused
  # here, before any dialog or step, when the plan made now is another one
  token_data="$(printf 'install\n'; printf '%s\n' "$FL_BENCH_DIR" "$FL_SITE" "$FL_PROFILE" "$FL_TEAM_PROFILE" "$1" "$INSTALL_PORT_OFFSET" "$web_port" "$pl_steps" "$blockers" "${OPT_FRAPPE_COMMIT:-}" "${OPT_ERPNEXT_COMMIT:-}" "${FL_MAKE_DEFAULT:-0}" "${OPT_SCRATCH:-0}" "${OPT_TTL:-}" "${OPT_REPAIR_BENCH:-0}" "${FL_SCHEDULER:-}")"
  fl_plan_apply_check "$token_data" "install" "benchbar install --dry-run --json --bench-dir ${FL_BENCH_DIR}"
  fl_plan_token_v token "$token_data"
  fl_jsonl plan ",\"bench\":$(fl_json_str "$FL_BENCH_DIR"),\"site\":$(fl_json_str "$FL_SITE"),\"profile\":$(fl_json_str "$FL_PROFILE"),\"team_profile\":${team},\"bundle\":$(fl_json_str "$1"),\"port_offset\":$(fl_json_num "$INSTALL_PORT_OFFSET"),\"web_url\":$(fl_json_str "$FL_JSONL_URL"),\"dry_run\":$(fl_json_bool "$FL_DRY_RUN"),\"sudo_mode\":\"${mode}\",\"steps\":[${pl_steps}],\"blockers\":[${blockers}],\"warnings\":[${warnings}],\"token\":\"${token}\",\"log\":$(fl_json_str "${FL_LOG_FILE:-}")"
  FL_JSONL_PLAN_SENT=1
  [[ "$FL_DRY_RUN" != "1" ]] || FL_JSONL_QUIET=1
  export FL_JSONL_QUIET
}

# fl_install_warnings_print: what the plan warns about (the run goes on), each
# with its fix line
fl_install_warnings_print() {
  local id msg fix
  [[ -n "$FL_INSTALL_WARNINGS" ]] || return 0
  while IFS='|' read -r id msg fix; do
    [[ -n "$id" ]] || continue
    fl_warn "${id}: ${msg}"
    fl_info "fix: ${fix}"
  done <<<"$FL_INSTALL_WARNINGS"
}

# fl_install_blockers_die: every blocker is listed, the first one ends the run
# with its error_id and fix (the done line carries both); nothing was changed
fl_install_blockers_die() {
  local id msg fix first_id="" first_msg="" first_fix=""
  [[ -n "$FL_INSTALL_BLOCKERS" ]] || return 0
  while IFS='|' read -r id msg fix; do
    [[ -n "$id" ]] || continue
    fl_fail "blocker ${id}: ${msg}"
    fl_info "fix: ${fix}"
    [[ -n "$first_id" ]] || { first_id="$id"; first_msg="$msg"; first_fix="$fix"; }
  done <<<"$FL_INSTALL_BLOCKERS"
  FL_ERROR_ID="$first_id"; FL_ERROR_FIX="$first_fix"
  fl_die "$first_msg" "$first_fix"
}

# fl_install_rerun_hint: how to start the install again, with a path that works
# even when "benchbar" is not on PATH in this shell yet
fl_install_rerun_hint() {
  local link
  link="$(fl_cli_link_path)"
  if [[ -x "$link" || -L "$link" ]]; then
    fl_info "Run it again: ${link} install$([[ -z "$(fl_rc_file)" ]] || printf '   (a new terminal, or: source %s, puts benchbar on PATH)' "$(fl_rc_file)")"
  fi
}

cmd_install() {
  local code=0 args00=() args01=() bundle phase00 phase_code=0
  local profile_name
  fl_plan_apply_parse install
  fl_context_init "$OPT_BENCH_DIR" "$OPT_SITE" "$OPT_PROFILE"
  fl_require_plain_bench
  # --scratch and --ttl are checked before any prompt or step
  SCRATCH_DAYS=""
  if [[ "$OPT_SCRATCH" == "1" ]]; then
    [[ "$FL_MAKE_DEFAULT" != "1" ]] || fl_die "--scratch and --make-default do not go together: a scratch bench expires, the default bench never does." "Leave one of them out."
    fl_lc_ttl_days_v SCRATCH_DAYS "$OPT_TTL"
  elif [[ -n "$OPT_TTL" ]]; then
    fl_die "--ttl goes with --scratch." "Example: benchbar install --scratch --ttl 3"
  fi
  # a password with a line break would be cut off on its pipe: refused before any work
  fl_secrets_single_line ADMIN_PASSWORD MARIADB_ROOT_PASSWORD
  # a malformed pin is refused before any prompt or step
  [[ -z "$OPT_FRAPPE_COMMIT" ]] || fl_validate_custom_commit "$OPT_FRAPPE_COMMIT"
  [[ -z "$OPT_ERPNEXT_COMMIT" ]] || fl_validate_custom_commit "$OPT_ERPNEXT_COMMIT"
  profile_name="$FL_PROFILE"
  # a profile Linux cannot install yet is refused before any prompt or step
  if fl_is_linux; then fl_linux_profile_require; fi
  if [[ -n "$FL_TEAM_PROFILE" ]]; then
    # the team profile's site name, unless one was given or remembered
    [[ -n "$FL_TEAM_SITE" && "$FL_SITE_SOURCE" == "default" ]] && FL_SITE="$FL_TEAM_SITE"
    if [[ -z "$FL_SCHEDULER" && -n "$FL_TEAM_SCHEDULER" && -z "$(fl_bstate_get SCHEDULER)" ]]; then
      FL_SCHEDULER=off; [[ "$FL_TEAM_SCHEDULER" == "true" ]] && FL_SCHEDULER=on
    fi
    profile_name="$FL_TEAM_PROFILE"
    fl_header "benchbar install" "$(fl_mode_name)" "${FL_TEAM_PROFILE} (team, on ${FL_PROFILE})" "$FL_BENCH_DIR" "$FL_SITE"
    fl_info "team profile ${FL_TEAM_PROFILE_FILE}"
    fl_profile_trust_print "install"
  else
    fl_header "benchbar install" "$(fl_mode_name)" "$(fl_profile_display)" "$FL_BENCH_DIR" "$FL_SITE"
  fi
  phase00="$(fl_phase00_script)"
  # the phase scripts are child processes: what they create (the bench, the site,
  # its apps) comes back through this file into changed[]
  FL_CHANGED_FILE="$(mktemp "${TMPDIR:-/tmp}/benchbar-changed.XXXXXX")"; FL_CHANGED_OWNER="$$"
  export FL_CHANGED_FILE FL_CHANGED_OWNER
  FL_JSONL_BENCH="$FL_BENCH_DIR"; FL_JSONL_SITE="$FL_SITE"
  # the passwords of a stream cannot be asked for: refused before anything runs
  if [[ "$FL_JSONL" == "1" && "$FL_DRY_RUN" != "1" && ! -d "${FL_BENCH_DIR}/sites/${FL_SITE}" && -z "${ADMIN_PASSWORD:-}" ]]; then
    fl_die "ADMIN_PASSWORD is not set: the new site ${FL_SITE} needs the Administrator password." \
      "Pass it in the environment: ADMIN_PASSWORD='...' benchbar install --json --yes"
  fi
  bundle="${OPT_BUNDLE:-$(fl_bstate_get APP_BUNDLE 2>/dev/null || true)}"
  bundle="${bundle:-$FL_TEAM_BUNDLE}"
  # Windows' listening ports and the hosts the install downloads from, looked at
  # once here (WSL; a few seconds at most), before the plan and its port block
  fl_install_preflight_load
  fl_install_port_plan
  # a port another program holds, no systemd, a bench on the Windows file system
  # or no way to github.com and apt stop the run here, before sudo and step 1
  FL_INSTALL_BLOCKERS="$(fl_install_port_blockers; fl_install_env_blockers)"
  FL_INSTALL_WARNINGS="$(fl_install_env_warnings)"
  fl_steps_define "System dependencies (${phase00})" "Bench and site (01-install-bench-and-site.sh)" "Background service"
  fl_steps_ids system_deps bench_site service
  fl_install_plan_json "${bundle:-minimal}"
  fl_steps_print_plan
  fl_install_warnings_print
  fl_install_blockers_die
  fl_install_sudo_upfront
  fl_install_privileged_steps
  # Linux: lingering, so the bench's systemd user unit can run without a login
  # session (a wsl.exe start has none) and after a reboot. Here, while the sudo
  # credential or the BENCHBAR_SUDO=env password is still there: phase 00 drops
  # it. A refusal is a warning with the fix, not a failure.
  fl_linger_ensure sudo
  # the user manager lingering starts: without it the service step at the end
  # cannot work (sudo -iu, su - and cron have no login session), so the run
  # stops here with the reason and the fix instead of after steps 1 and 2
  if [[ "$FL_DRY_RUN" != "1" ]] && ! fl_user_bus_wait; then
    FL_ERROR_ID="user_bus_unreachable"
    FL_ERROR_FIX="$(fl_user_manager_fix)"
    fl_die "$(fl_user_manager_msg). No package or bench was changed." "$FL_ERROR_FIX"
  fi
  # from here on nothing runs as root: brew, pip, npm, yarn and bench get-app
  # must not find a cached sudo credential. On Linux the apt and MariaDB
  # steps are phase 00 itself: it drops the credential when they are done
  # (before the uv and fnm installers), and it is dropped again after it.
  fl_is_linux || fl_sudo_drop

  # the phases load a team profile themselves (its base for 00, its apps for 01)
  args00=(--profile "$profile_name"); args01=(--profile "$profile_name")
  [[ "$FL_DRY_RUN" == "1" ]] && { args00+=(--dry-run); args01+=(--dry-run); }
  [[ "$FL_ASSUME_YES" == "1" ]] && { args00+=(--yes); args01+=(--yes); }
  [[ "$OFFLINE" == "1" ]] && { args00+=(--offline); args01+=(--offline); }
  [[ "$FL_MAKE_DEFAULT" == "1" ]] && args01+=(--make-default)
  [[ "$OPT_REPAIR_BENCH" == "1" ]] && args01+=(--repair-bench)
  [[ -z "$OPT_FRAPPE_COMMIT" ]] || args01+=(--frappe-commit "$OPT_FRAPPE_COMMIT")
  [[ -z "$OPT_ERPNEXT_COMMIT" ]] || args01+=(--erpnext-commit "$OPT_ERPNEXT_COMMIT")

  fl_step_begin 0
  if BENCHBAR_PDF_STEP="$FL_INSTALL_PDF_STEP" FL_JSONL_PARENT=system_deps \
     fl_run_phase_script "${SCRIPT_DIR}/${phase00}" "${args00[@]}"; then
    phase_code=0
  else
    phase_code=$?
  fi
  fl_sudo_phase_done
  if [[ "$phase_code" == "0" ]]; then
    fl_step_end "done"
    # benchbar on PATH from here on, not only after the whole install: a run that stops
    # in the bench step (or is cut short) is started again with "benchbar install"
    # (issue 112: "command not found" until the first install had finished)
    [[ "$FL_DRY_RUN" == "1" ]] || act_write_cli_link || fl_warn "could not link benchbar into ~/.local/bin; run: ${FL_SELF} repair"
  else
    code="$phase_code"
    if [[ "$code" == "2" ]]; then
      fl_step_end warning "manual steps pending"
      fl_steps_summary
      fl_box "Stopped" "Complete the PENDING MANUAL STEPS printed above, then run this command again." \
        "System dependencies were set up as far as possible; no bench or site was created."
      return 2
    fi
    fl_step_end failed
    fl_steps_summary
    return "$code"
  fi

  fl_step_begin 1
  # the port block of a new bench (chosen above, fl_install_port_plan)
  local web_port="" port_block="$INSTALL_PORT_BLOCK"
  if [[ "$INSTALL_PORT_ERR" == "1" ]]; then
    fl_step_end failed; fl_steps_summary; fl_die "no free port block between 0 and ${FL_PORT_MAX_OFFSET}"
  fi
  [[ -z "$INSTALL_PORT_FREE" ]] || fl_info "the default ports are taken; the new bench gets port block ${INSTALL_PORT_FREE} (web ${port_block%% *})"
  [[ -n "$port_block" ]] && web_port="${port_block%% *}"
  if BENCH_DIR="$FL_BENCH_DIR" SITE_NAME="$FL_SITE" APP_BUNDLE="${bundle:-minimal}" BENCHBAR_WEB_PORT="$web_port" \
     BENCHBAR_PORT_BLOCK="$port_block" FL_JSONL_PARENT=bench_site BENCHBAR_PLAN_STEP1="$([[ "$FL_DRY_RUN" == "1" ]] && printf '%s' "$phase00")" \
     fl_run_phase_script "${SCRIPT_DIR}/01-install-bench-and-site.sh" "${args01[@]}"; then
    # the site exists: nothing after it needs the Administrator password
    unset ADMIN_PASSWORD
    fl_step_end "done"
  else
    code=$?
    if [[ "$code" == "2" ]]; then
      fl_step_end warning "manual steps pending"
      fl_steps_summary
      fl_box "Stopped" "The MariaDB root password is unknown; see above for how to pass it," "then run this command again. No bench or site was created."
      return 2
    fi
    if [[ "$code" == "3" ]]; then
      # declined at the plan: no bench, so nothing to remember and no service
      fl_step_end skipped "cancelled"
      fl_steps_summary
      fl_warn "Cancelled. No bench or site was created; the system dependencies of step 1 stay in place."
      return 1
    fi
    fl_step_end failed
    fl_steps_summary
    fl_install_rerun_hint
    return "$code"
  fi
  fl_remember_bench || fl_info "the default bench stays $(fl_state_get BENCH_DIR) (--make-default changes it)"
  # install --scratch: this bench expires (benchbar bench gc removes it, never when it is the default bench)
  if [[ "$OPT_SCRATCH" == "1" && "$FL_DRY_RUN" != "1" ]]; then
    fl_lc_scratch_mark "$FL_BENCH_DIR" "$SCRATCH_DAYS" install
    fl_ok "scratch bench: expires in ${SCRATCH_DAYS} day(s); benchbar bench scratch ${FL_BENCH_DIR} --clear keeps it"
  fi
  if [[ -n "$FL_SCHEDULER" ]]; then fl_bstate_set SCHEDULER "$FL_SCHEDULER"; fi

  fl_step_begin 2
  fl_context_init "$FL_BENCH_DIR" "$FL_SITE" "$FL_PROFILE"
  # no MariaDB formula saved yet (a dry run saves nothing): check against the
  # server phase 00 chose, not the profile default. Setup may look at 3306.
  [[ -n "$FL_MARIADB_FORMULA_PINNED" ]] || fl_mariadb_prefer_running
  if [[ "$FL_DRY_RUN" == "1" && ! -d "$FL_BENCH_DIR" ]]; then
    fl_info "dry-run: the bench does not exist yet, so the service plan is shown against an empty bench"
  fi
  FL_SKIP_PLAN_CONFIRM=1
  if [[ -d "$FL_BENCH_DIR/sites" ]]; then
    fl_ports_plan "$OPT_PORT_OFFSET" || { fl_step_end failed; fl_steps_summary; return 1; }
  elif [[ "$FL_DRY_RUN" == "1" && -n "$OPT_PORT_OFFSET" ]]; then
    # the bench is not there yet: show the plan with the ports it will get,
    # not the defaults (the real run moves them once the bench exists)
    fl_ports_plan "$OPT_PORT_OFFSET" || { fl_step_end failed; fl_steps_summary; return 1; }
    if [[ -n "$FL_PORT_TARGET" ]]; then
      read -r FL_WEB_PORT FL_SOCKETIO_PORT FL_REDIS_QUEUE_PORT FL_REDIS_CACHE_PORT <<<"$(fl_port_block "$FL_PORT_TARGET")"
      FL_REDIS_SOCKETIO_PORT="$FL_REDIS_CACHE_PORT"
      fl_info "dry-run: the new bench gets port block ${FL_PORT_TARGET} (web ${FL_WEB_PORT}, socketio ${FL_SOCKETIO_PORT})"
      FL_PORT_TARGET=""
      fl_render_all
    fi
  fi
  # the engine lists and times its own actions; the install's three steps
  # come back afterwards for the one Summary at the end
  fl_steps_push
  if FL_ENGINE_NO_SUMMARY=1 FL_PLAN_CHECKS="port_block" FL_ENGINE_PARENT=service FL_ENGINE_QUIET_ACTIONS="hosts_entry wkhtmltopdf_install" \
     fl_repair_engine "Background service" system service; then
    fl_steps_pop
    fl_pm_remember
    fl_step_end "done"
  else
    fl_steps_pop
    # an action that failed is a failure (the [FAIL] line above says which);
    # "warning" is for a run whose actions worked and whose verify pass still has
    # something to look at
    if [[ "$FL_ENGINE_ACTION_FAILED" == "1" ]]; then fl_step_end failed; else fl_step_end warning "see above"; fi
    code=1
  fi
  fl_steps_summary
  if [[ "$code" == "0" ]]; then fl_next_steps_box; else fl_install_fix_box; fi
  return "$code"
}
