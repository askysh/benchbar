#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# repair.sh: repair actions in dependency order, each with a backup, plus
# the check -> plan -> apply -> verify engine shared by "repair" and
# "service" (the background phase).

FL_ACTION_ORDER="python_leaves node_install yarn_install env_rebuild env_setuptools honcho_install honcho_setuptools node_requirements build clear_cache mariadb_bind mariadb_utf8 wkhtmltopdf_install legacy_migrate port_block write_procfile write_runner write_plist write_helpers write_cli_link hosts_entry rotate_logs redis_stop"
# actions whose check may stay a warning after a run without failing it:
# the user may decline them (or sudo) on purpose
FL_OPTIONAL_ACTIONS="wkhtmltopdf_install hosts_entry redis_stop"
# actions that are only a question to the person (nothing to apply under --yes)
fl_action_is_question() { [[ "$1" == "redis_stop" ]]; }
FL_NEED_CLEAR_CACHE=0
# set by legacy_migrate when it booted out an agent that was running the
# bench, so write_plist starts the bench again under the new agent
FL_MIGRATED_RUNNING=0

fl_action_label() {
  # Linux words the actions that name a package manager or the service manager
  if fl_is_linux; then
    case "$1" in
      node_install) printf 'fnm install %s (the Node of profile %s; an older Node is not removed)' "$FL_NODE_MAJOR" "$FL_PROFILE"; return 0 ;;
      yarn_install) printf 'install yarn under Node %s (npm install -g yarn)' "$FL_NODE_MAJOR"; return 0 ;;
      wkhtmltopdf_install) printf 'install the patched wkhtmltopdf package (apt, sudo)'; return 0 ;;
      write_plist) printf 'write and load the systemd user unit'; return 0 ;;
    esac
  fi
  case "$1" in
    python_leaves) printf 'mark %s as user-installed' "$FL_PYTHON_FORMULA" ;;
    node_install) printf 'brew install %s (the Node of profile %s; an older node formula is not removed)' "$FL_NODE_FORMULA" "$FL_PROFILE" ;;
    yarn_install) printf 'install yarn under %s (npm install -g yarn)' "$FL_NODE_FORMULA" ;;
    honcho_install) printf 'install honcho into the bench env' ;;
    honcho_setuptools) printf "install setuptools into honcho's venv" ;;
    env_rebuild) printf 'rebuild the bench env (old env moved aside)' ;;
    env_setuptools) printf "install 'setuptools<70' into the bench env (pkg_resources for Frappe v15)" ;;
    node_requirements) printf 'bench setup requirements --node' ;;
    build) printf 'bench build' ;;
    clear_cache) printf 'bench clear-cache and clear-website-cache' ;;
    mariadb_bind) printf 'bind MariaDB to 127.0.0.1%s%s' "$(fl_is_linux && printf ' (sudo)')" "$(fl_mariadb_restart_note)" ;;
    mariadb_utf8) printf 'write the utf8mb4 MariaDB drop-in%s%s' "$(fl_is_linux && printf ' (sudo)')" "$(fl_mariadb_restart_note)" ;;
    wkhtmltopdf_install) printf 'install the patched wkhtmltopdf package (sudo)' ;;
    legacy_migrate) printf 'migrate legacy launchd agents' ;;
    port_block) printf 'move the bench to port block %s (bench set-config, bench setup redis)' "${FL_PORT_TARGET:-?}" ;;
    write_procfile) printf 'write Procfile.lean' ;;
    write_runner) printf 'write the runner script' ;;
    write_plist) printf 'write and load the launchd agent' ;;
    write_helpers) printf 'write the shell helper block' ;;
    write_cli_link)
      if [[ -n "$(fl_brew_cli)" ]]; then printf 'point ~/.local/bin/benchbar and frappe-mac at %s' "$FL_SELF"
      else printf 'link benchbar and frappe-mac into ~/.local/bin'; fi ;;
    hosts_entry) printf 'add %s to /etc/hosts (sudo)' "$FL_SITE" ;;
    rotate_logs) printf 'copy large logs aside and truncate them' ;;
    redis_stop) printf 'stop Homebrew redis on 6379' ;;
    *) printf '%s' "$1" ;;
  esac
}

fl_bench_env_exports() {
  local brew="${FL_BREW_PREFIX:-/opt/homebrew}"
  export PATH="${brew}/opt/${FL_PYTHON_FORMULA}/bin:${brew}/opt/${FL_NODE_FORMULA}/bin:${brew}/opt/${FL_MARIADB_FORMULA}/bin:$HOME/.local/bin:${brew}/bin:$PATH"
  export LDFLAGS="-L${brew}/opt/openssl@3/lib -L${brew}/opt/libffi/lib -L${brew}/opt/zlib/lib"
  export CPPFLAGS="-I${brew}/opt/openssl@3/include -I${brew}/opt/libffi/include -I${brew}/opt/zlib/include"
  export PKG_CONFIG_PATH="${brew}/opt/openssl@3/lib/pkgconfig:${brew}/opt/libffi/lib/pkgconfig:${brew}/opt/zlib/lib/pkgconfig:${brew}/opt/mariadb-connector-c/lib/pkgconfig"
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
    fl_bstate_set HONCHO_BIN "$FL_HONCHO"
    fl_render_all
    return 0
  fi
  fl_honcho_install || return 1
  [[ -n "$FL_HONCHO" ]] && fl_bstate_set HONCHO_BIN "$FL_HONCHO"
  fl_render_all
}

# setuptools goes into the venv honcho runs from (pipx, uv or env), nowhere else
act_honcho_setuptools() {
  local py
  py="$(fl_honcho_python)"
  [[ -n "$py" ]] || { fl_fail "honcho's Python was not found"; return 1; }
  if command -v uv >/dev/null 2>&1; then
    fl_run_long "install setuptools for honcho (uv)" uv pip install --python "$py" setuptools || return 1
  else
    fl_run_long "install setuptools for honcho (pip)" "$py" -m pip install setuptools || return 1
  fi
}

# The env is rebuilt with the profile's Python. Two refusals come first: a
# profile that is only the default (no profile matches this bench's Frappe,
# so its Python is a guess) and a running bench (its processes run from the
# env that would move aside). Both are said, neither is worked around.
act_env_rebuild() {
  local py
  if fl_profile_is_guess; then
    fl_fail "refusing to rebuild env: no profile matches this bench's Frappe, so ${FL_PROFILE} (the default) is a guess at its Python"
    fl_fix "benchbar install --profile NAME --bench-dir ${FL_BENCH_DIR}   (or: cd ${FL_BENCH_DIR} && bench setup env --python /path/to/pythonX.Y)"
    return 1
  fi
  if fl_bench_is_running; then
    if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
      fl_info "dry-run: would refuse to rebuild env while the bench runs (stop it first: ${FL_SELF} down)"
      return 0
    fi
    fl_fail "refusing to rebuild env while the bench is running: its processes run from the env that would move aside"
    fl_fix "${FL_SELF} down --bench-dir ${FL_BENCH_DIR}, then ${FL_SELF} repair, then benchup"
    return 1
  fi
  py="$(fl_python_bin)"
  # Linux: the profile's Python comes from uv, which can fetch it now (no sudo)
  if fl_is_linux && [[ ! -x "$py" ]] && command -v uv >/dev/null 2>&1; then
    fl_run_long "uv python install ${FL_PYTHON_BIN_NAME#python}" uv python install "${FL_PYTHON_BIN_NAME#python}" || return 1
    py="$(fl_python_bin)"
  fi
  [[ -x "$py" ]] || py="$(command -v "$FL_PYTHON_BIN_NAME" || true)"
  [[ -n "$py" ]] || { fl_fail "${FL_PYTHON_BIN_NAME} not found; run $(fl_is_linux && printf '00-linux-system-deps.sh' || printf '00-mac-system-deps.sh') first"; return 1; }
  fl_bench_env_exports
  fl_move_aside "${FL_BENCH_DIR}/env" broken || return 1
  fl_run_long "bench setup env --python ${py}" fl_in_bench bench setup env --python "$py" || return 1
  fl_run_long "bench setup requirements --python" fl_in_bench bench setup requirements --python || return 1
  # Frappe v15 imports pkg_resources, which setuptools 70+ no longer ships
  [[ "$(fl_profile_major)" != "15" ]] || act_env_setuptools || return 1
  FL_NEED_CLEAR_CACHE=1
  if ! fl_honcho_resolve; then
    fl_info "honcho lived in the old env; installing it into the new one"
    fl_honcho_install || return 1
  fi
  [[ -n "$FL_HONCHO" ]] && fl_bstate_set HONCHO_BIN "$FL_HONCHO"
  fl_render_all
}

# The profile's Node formula (a profile that moved to a newer Node, for
# example v15-lts from node@20 to node@22 before Homebrew disabled node@20).
# Only an install: the old formula stays for whatever else uses it, and the
# bench's PATH (shell block, agent plist) puts the profile's first.
act_node_install() {
  local verb="install"
  if brew list --formula --versions "$FL_NODE_FORMULA" >/dev/null 2>&1; then
    if [[ -x "$(fl_node_bin)" ]]; then
      fl_info "${FL_NODE_FORMULA} is already installed"
      return 0
    fi
    # brew knows the formula but its node is gone (a damaged keg or opt
    # link): install would be a no-op, reinstall puts the files back
    verb="reinstall"
  fi
  fl_run_long "brew ${verb} ${FL_NODE_FORMULA}" brew "$verb" "$FL_NODE_FORMULA" || return 1
  [[ -x "$(fl_node_bin)" || "${FL_DRY_RUN:-0}" == "1" ]] || { fl_fail "${FL_NODE_FORMULA} installed, but $(fl_node_bin) is missing"; return 1; }
  return 0
}

# yarn is global to a node formula: a new Node needs its own.
act_yarn_install() {
  local npm
  npm="$(fl_npm_bin)"
  [[ -x "$npm" || "${FL_DRY_RUN:-0}" == "1" ]] || { fl_fail "no npm at ${npm}; install ${FL_NODE_FORMULA} first"; return 1; }
  fl_run_long "npm install -g yarn (${FL_NODE_FORMULA})" "$npm" install -g yarn || return 1
  return 0
}

# 'setuptools<70' into the bench env: pkg_resources for honcho and bench on
# Frappe v15 (a fresh env with Python 3.12+ has no setuptools at all)
act_env_setuptools() {
  local py="${FL_BENCH_DIR}/env/bin/python"
  if fl_profile_is_guess; then
    fl_fail "refusing to change the env: no profile matches this bench's Frappe"
    return 1
  fi
  [[ -x "$py" || "${FL_DRY_RUN:-0}" == "1" ]] || { fl_fail "no env/bin/python to install setuptools into"; return 1; }
  # already there (an env rebuild in this run installed it): nothing to do
  if [[ -x "$py" ]] && "$py" -c 'import pkg_resources' >/dev/null 2>&1; then
    FL_STEP_RESULT="unchanged"
    return 0
  fi
  fl_bench_env_exports
  fl_bench_env_setuptools "$FL_BENCH_DIR"
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

act_mariadb_bind() {
  fl_mariadb_dropin_apply mariadb-local-only.cnf "$(fl_mariadb_dropin_path)" || return 1
  if [[ -n "$(fl_port_listen_addresses 3306)" ]]; then
    fl_mariadb_restart_if_running || return 1
  fi
}

act_mariadb_utf8() {
  fl_mariadb_dropin_apply mariadb-frappe.cnf "$(fl_mariadb_utf8_dropin_path)" || return 1
  if [[ "$FL_TEMPLATE_CHANGED" == "1" ]]; then
    fl_mariadb_restart_if_running || return 1
  fi
}

# PDFs are optional: a skip (Rosetta or the package declined, no sudo) is
# not a failed step, only a real error is.
act_wkhtmltopdf_install() {
  # benchbar install ran this step up front: in a dry run the plan is already
  # on the screen, once
  if [[ "${FL_INSTALL_PDF_STEP:-}" == "dry-run" ]]; then
    fl_info "dry-run: the wkhtmltopdf plan is above (shown once by install)"
    return 0
  fi
  local code=0
  fl_wkhtmltopdf_ensure || code=$?
  [[ "$code" == "2" ]] && { FL_STEP_RESULT="skipped"; return 0; }
  return "$code"
}

act_legacy_migrate() {
  local list path label state code failed=0
  list="$(fl_legacy_agents_list)"
  [[ -n "$list" ]] || return 0
  fl_bench_is_running && FL_MIGRATED_RUNNING=1
  while IFS='|' read -r path label state code; do
    [[ -n "$path" ]] || continue
    fl_info "${label}: ${state}, last exit code ${code}"
    fl_legacy_agent_migrate "$path" "$label" || failed=1
  done <<<"$list"
  [[ "$failed" == "0" ]] || { fl_fail "a legacy agent could not be migrated; run benchbar repair again once launchd has let go of it"; return 1; }
  # the old runner is free once no legacy agent runs it (the write_runner
  # and write_plist steps retire it too, but they may have nothing to write)
  fl_runner_legacy_retire || return 1
  return 0
}

# Runs before write_procfile and the runner: fl_ports_apply re-renders them
# with the new ports.
act_port_block() {
  local running=0
  fl_bench_is_running && running=1
  fl_ports_apply "$FL_PORT_TARGET" || return 1
  # the Procfile and the runner carry the ports; they may have been current
  # when the plan was made, so they are not in it
  act_write_procfile && act_write_runner || return 1
  [[ "$running" == "1" && "${FL_DRY_RUN:-0}" != "1" ]] && fl_warn "the bench is running on its old ports; run: benchbar restart --bench-dir ${FL_BENCH_DIR}"
  return 0
}

act_write_procfile() {
  fl_template_apply "$(fl_procfile_path)" "$FL_R_PROCFILE" 644 || return 1
  [[ "$FL_TEMPLATE_CHANGED" == "1" && "${FL_DRY_RUN:-0}" != "1" ]] && fl_ok "wrote $(fl_procfile_path)"
  return 0
}

act_write_runner() {
  [[ "${FL_DRY_RUN:-0}" == "1" ]] || mkdir -p "${FL_BENCH_DIR}/logs" 2>/dev/null || { fl_fail "could not create ${FL_BENCH_DIR}/logs"; return 1; }
  fl_template_apply "$(fl_runner_path)" "$FL_R_RUNNER" 755 || return 1
  [[ "$FL_TEMPLATE_CHANGED" == "1" && "${FL_DRY_RUN:-0}" != "1" ]] && fl_ok "wrote $(fl_runner_path)"
  fl_runner_legacy_retire || return 1
  return 0
}

# Backs up and removes frappe-mac-run.sh (the runner's name before 0.3.0),
# but only once no installed agent runs it: write_plist calls this again
# after it has loaded the agent that points at benchbar-run.sh.
fl_runner_legacy_retire() {
  local old
  old="$(fl_runner_path_legacy)"
  [[ -f "$old" ]] || return 0
  fl_runner_legacy_in_use && return 0
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would move the old runner ${old} to the backups"
    return 0
  fi
  fl_backup_file "$old" || return 1
  rm -f "$old"
  fl_ok "retired the old runner ${old} (backup: ${FL_LAST_BACKUP})"
}

# Writes the plist and (re)loads the agent. A bench that is not running
# gets a "manual" stop flag first so the reload never starts it by surprise.
# So does one running outside BenchBar (bench start): the runner's cleanup
# would stop that session's processes.
act_write_plist() {
  local plist was_running=0 flag
  plist="$(fl_agent_plist_path)"
  flag="$(fl_stop_flag_path)"
  # running under the legacy agent that was just migrated, under this
  # bench's agent (launchd says so), or by processes benchbar can prove are
  # this bench's; a session outside the agent is left alone
  if [[ "$FL_MIGRATED_RUNNING" == "1" ]]; then was_running=1
  elif fl_bench_running_outside_benchbar; then
    fl_warn "this bench is running outside BenchBar's agent (bench start or benchfg); its processes are left alone and the agent is installed stopped"
    fl_info "stop that session (Ctrl+C), then run benchup"
  elif [[ "$(fl_agent_field state 2>/dev/null)" == "running" ]] || fl_bench_is_running; then was_running=1; fi
  if [[ "$was_running" == "0" && ! -f "$flag" ]]; then
    if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
      fl_info "dry-run: would write 'manual' to ${flag} so the agent does not auto-start"
    else
      mkdir -p "$(dirname "$flag")"
      printf 'manual\n' >"$flag"
    fi
  fi
  [[ "${FL_DRY_RUN:-0}" == "1" ]] || mkdir -p "$(dirname "$plist")" 2>/dev/null || { fl_fail "could not create $(dirname "$plist")"; return 1; }
  fl_template_apply "$plist" "$FL_R_PLIST" 644 || return 1
  [[ "$FL_TEMPLATE_CHANGED" == "1" && "${FL_DRY_RUN:-0}" != "1" ]] && fl_ok "wrote ${plist}"
  if fl_agent_loaded; then
    [[ "$FL_TEMPLATE_CHANGED" == "1" ]] || return 0
    fl_agent_bootout || {
      fl_fail "${FL_AGENT_MANAGER} did not let go of $(fl_agent_label) within ${FL_BOOTOUT_WAIT_SECS} s; run benchbar repair again"
      return 1
    }
  fi
  fl_agent_bootstrap "$plist" || { fl_fail "${FL_AGENT_CTL} could not load ${plist}"; return 1; }
  if [[ "$was_running" == "1" ]]; then
    # RunAtLoad starts it unless autostart is off; kickstart is a no-op when it already runs
    fl_agent_kickstart >/dev/null 2>&1 || true
    fl_ok "agent reloaded; the bench restarts under the new agent"
  else
    fl_ok "agent loaded (bench stays stopped until benchup)"
  fi
  fl_runner_legacy_retire
}

act_write_helpers() {
  local rc recorded own=""
  rc="$(fl_rc_file)"
  # under Homebrew a block that runs a checkout with its own state stays:
  # rewritten, benchup would start without that state (chk_helpers)
  if [[ "${FL_INSTALL_KIND:-}" == homebrew ]]; then
    recorded="$(fl_rc_block_extract "$rc" | sed -n 's/^BENCHBAR="\(.*\)"$/\1/p' | head -n 1)"
    [[ -z "$recorded" || ! -e "$recorded" ]] || fl_cli_own_state_v own "$recorded"
    if [[ -n "$own" ]]; then
      fl_warn "the helper block in ${rc} runs ${recorded}, a checkout with its own state (${own}); left as is"
      return 0
    fi
  fi
  fl_rc_block_write "$rc" "$FL_R_HELPERS" || return 1
  [[ "${FL_DRY_RUN:-0}" == "1" ]] || fl_ok "helper block written to ${rc} (open a new shell or: source ${rc})"
}

# Links ~/.local/bin/benchbar and frappe-mac to FL_SELF. A link that leads
# elsewhere is pointed at it, the old one kept in the backups. With
# Homebrew's benchbar installed a missing link stays missing: brew's bin
# folder already puts benchbar on PATH (chk_cli_link).
act_write_cli_link() {
  local name link dir old brew own=""
  dir="$(dirname "$(fl_cli_link_path)")"
  brew="$(fl_brew_cli)"
  for name in benchbar frappe-mac; do
    link="$(fl_cli_link_path "$name")"
    fl_cli_link_ok "$link" && continue
    [[ -e "$link" && ! -L "$link" ]] && { fl_warn "${link} is a regular file; not touching it"; continue; }
    if [[ "${FL_INSTALL_KIND:-}" == homebrew && -L "$link" ]]; then
      fl_cli_own_state_v own "$(readlink "$link")"
      if [[ -n "$own" ]]; then fl_warn "${link} leads to a checkout with its own state (${own}); not touching it"; continue; fi
    fi
    if [[ -L "$link" ]]; then
      old="$(readlink "$link")"
      if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
        fl_info "dry-run: ln -sfn ${FL_SELF} ${link}   (now a link to ${old}, kept in the backups)"
        continue
      fi
      fl_backup_link "$link"
      ln -sfn "$FL_SELF" "$link"
      fl_ok "pointed ${link} at ${FL_SELF} (it led to ${old}; backup: ${FL_LAST_BACKUP})"
      continue
    fi
    [[ -z "$brew" ]] || continue
    if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
      fl_info "dry-run: ln -sfn ${FL_SELF} ${link}"
      continue
    fi
    mkdir -p "$dir"
    ln -sfn "$FL_SELF" "$link"
    fl_ok "linked ${link}"
  done
  [[ "${FL_DRY_RUN:-0}" == "1" || -n "$brew" ]] && return 0
  case ":$PATH:" in
    *":${dir}:"*) ;;
    *) fl_info "${dir} is not on PATH in this shell; the helper block adds it for new shells" ;;
  esac
}

FL_HOSTS_START="# >>> benchbar >>>"
FL_HOSTS_END="# <<< benchbar <<<"

# fl_hosts_rewrite DELTA AWK_PROGRAM [NAME=VALUE...]: FL_HOSTS_FILE rewritten
# by AWK_PROGRAM, on the root side. awk runs as root with the NAME=VALUE
# pairs in its environment (the program reads them through ENVIRON[], so no
# backslash in a value is ever processed) and writes FL_HOSTS_FILE.benchbar.new
# through sudo tee: the new content is never in a file this user could swap
# under a copy. The new file is then checked, as root: every line empty, a
# comment or "address names" (an IPv6 zone id, fe80::1%lo0, and a CRLF line
# included), and exactly DELTA lines more (or fewer) than
# before. Only then is it moved into place (same folder, one rename). Any
# other outcome removes the new file and changes nothing.
fl_hosts_rewrite() {
  local delta="$1" prog="$2" new="${FL_HOSTS_FILE}.benchbar.new" before after bad
  shift 2
  # awk's count on both sides: wc -l would miss a last line without a newline
  before="$(awk 'END { print NR }' "$FL_HOSTS_FILE")"
  if ! sudo env "$@" awk "$prog" "$FL_HOSTS_FILE" | sudo tee "$new" >/dev/null; then
    sudo rm -f "$new" 2>/dev/null || true
    fl_fail "could not write ${new}; ${FL_HOSTS_FILE} is not written"
    return 1
  fi
  bad="$(sudo awk 'NF == 0 { next } /^[[:space:]]*#/ { next } $1 ~ /^[0-9A-Fa-f.:]+(%[A-Za-z0-9_.-]+)?\r?$/ { next } { print; exit }' "$new" 2>/dev/null || true)"
  after="$(sudo awk 'END { print NR }' "$new" 2>/dev/null || printf 'unknown')"
  if [[ -n "$bad" ]]; then
    sudo rm -f "$new" 2>/dev/null || true
    fl_fail "${FL_HOSTS_FILE} is not written: the result holds a line that is not 'address names': ${bad}"
    fl_note "fix that line in ${FL_HOSTS_FILE} by hand, then run the command again"
    return 1
  fi
  if [[ "$after" != "$((before + delta))" ]]; then
    sudo rm -f "$new" 2>/dev/null || true
    fl_fail "${FL_HOSTS_FILE} is not written: expected ${before} + (${delta}) lines, the result has ${after}"
    return 1
  fi
  sudo chmod 644 "$new" || { sudo rm -f "$new" 2>/dev/null || true; fl_fail "sudo chmod failed; ${FL_HOSTS_FILE} is not written"; return 1; }
  sudo mv "$new" "$FL_HOSTS_FILE" || { sudo rm -f "$new" 2>/dev/null || true; fl_fail "sudo mv failed; ${FL_HOSTS_FILE} is not written"; return 1; }
}

# BENCHBAR_SUDO=gui: the root side of the /etc/hosts lines as one script
# (fl_root_run), arguments: file, mode (append: no benchbar block yet, the
# block is written at the end; rewrite: the lines go inside it), the block's
# two marker lines, the lines (newline separated) and how many they are. The
# checks are those of fl_hosts_rewrite, made by root on the new file: every
# line empty, a comment or "address names", exactly the expected line count,
# and only then one mv.
fl_hosts_root_script() {
  cat <<'ROOT'
set -u
f="$1" mode="$2" start="$3" end="$4" lines="$5" delta="$6"
new="${f}.benchbar.new"
bail() { /bin/rm -f "$new"; printf '%s\n' "$1" >&2; exit 1; }
if [ "$mode" = append ]; then
  printf '\n%s\n%s\n%s\n' "$start" "$lines" "$end" >>"$f" || bail "could not append to $f"
  exit 0
fi
before="$(/usr/bin/awk 'END { print NR }' "$f")"
L="$lines" E="$end" /usr/bin/awk '$0 == ENVIRON["E"] { print ENVIRON["L"] } { print }' "$f" >"$new" || bail "could not write $new; $f is not written"
bad="$(/usr/bin/awk 'NF == 0 { next } /^[[:space:]]*#/ { next } $1 ~ /^[0-9A-Fa-f.:]+(%[A-Za-z0-9_.-]+)?\r?$/ { next } { print; exit }' "$new" 2>/dev/null || true)"
after="$(/usr/bin/awk 'END { print NR }' "$new" 2>/dev/null || printf unknown)"
[ -z "$bad" ] || bail "$f is not written: the result holds a line that is not 'address names': $bad"
[ "$after" = "$((before + delta))" ] || bail "$f is not written: expected $before + ($delta) lines, the result has $after"
/bin/chmod 644 "$new" || bail "chmod failed; $f is not written"
/bin/mv "$new" "$f" || bail "mv failed; $f is not written"
ROOT
}

# fl_hosts_gui_reason NAME...: the dialog's title, which is also the step's name
fl_hosts_gui_reason() {
  if [[ "$#" == "1" ]]; then printf 'Add 127.0.0.1 %s to /etc/hosts' "$1"; else printf 'Add 127.0.0.1 lines for %d sites to /etc/hosts' "$#"; fi
}

# fl_hosts_add_gui NAME...: the lines for every NAME (valid, not there yet)
# in one dialog. Sets FL_STEP_RESULT=skipped, and FL_SKIP_COMMAND, when the
# dialog is cancelled; returns 1 when the script fails.
fl_hosts_add_gui() {
  local reason lines="" n mode=rewrite code=0 last
  reason="$(fl_hosts_gui_reason "$@")"
  for n in "$@"; do lines="${lines}${lines:+$'\n'}127.0.0.1 ${n}"; done
  # one dialog per run for the lines, whoever asks: a cancelled or failed one
  # is not asked again (FL_ROOT_KIND=hosts)
  if fl_root_was_cancelled hosts; then code=2
  elif fl_root_was_failed hosts; then code=1; FL_ROOT_OUTPUT="the script failed earlier in this run"
  else
    fl_backup_file "$FL_HOSTS_FILE" || return 1
    [[ "$(fl_rc_markers_state "$FL_HOSTS_FILE" "$FL_HOSTS_START" "$FL_HOSTS_END")" == "present" ]] || mode=append
    FL_ROOT_KIND=hosts fl_root_run "$reason" "$(fl_hosts_root_script)" "$FL_HOSTS_FILE" "$mode" "$FL_HOSTS_START" "$FL_HOSTS_END" "$lines" "$#" || code=$?
  fi
  case "$code" in
    0) ;;
    2)
      FL_SKIP_COMMAND="${FL_SELF} site hosts --bench-dir ${FL_BENCH_DIR}"
      fl_warn "the password dialog was cancelled; the line was not added"
      fl_fix "$FL_SKIP_COMMAND"
      FL_STEP_RESULT="skipped"
      return 0 ;;
    *)
      last="$(printf '%s\n' "$FL_ROOT_OUTPUT" | grep -v '^[[:space:]]*$' | tail -n 1)"
      fl_fail "could not write ${FL_HOSTS_FILE}${last:+: ${last}}"
      return 1 ;;
  esac
  for n in "$@"; do
    fl_hosts_has_name "$n" || { fl_fail "${FL_HOSTS_FILE} still has no entry for ${n}"; return 1; }
  done
  fl_ok "added $(printf "'127.0.0.1 %s' " "$@" | sed 's/ $//') to ${FL_HOSTS_FILE} (backup: ${FL_LAST_BACKUP:-none})"
}

# Adds "127.0.0.1 <site>" inside a marker block in /etc/hosts. Missing block:
# appended with sudo tee -a. Existing block: the line goes inside it and the
# file is rewritten on the root side (fl_hosts_rewrite). A backup comes first.
# A name that is not a site name is skipped with a warning and never reaches
# sudo.
act_hosts_entry() {
  local line
  if fl_hosts_has_site; then
    return 0
  fi
  if ! fl_site_name_ok "$FL_SITE"; then
    fl_warn "no hosts line for sites/${FL_SITE}: not a valid site name (lowercase letters, digits, '-' and '.' only)"
    FL_STEP_RESULT="skipped"
    return 0
  fi
  line="127.0.0.1 ${FL_SITE}"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would add '${line}' inside the '${FL_HOSTS_START}' block of ${FL_HOSTS_FILE} (sudo, backup first)"
    return 0
  fi
  if ! fl_confirm "Add '${line}' to ${FL_HOSTS_FILE} with sudo?"; then
    # declined: the step is skipped, not done; the fix keeps the line inside
    # benchbar's block, where site drop can remove it again
    fl_warn "skipped; run: ${FL_SELF} repair --bench-dir ${FL_BENCH_DIR}   (adds '${line}' inside the benchbar block)"
    FL_STEP_RESULT="skipped"
    FL_SKIP_COMMAND="${FL_SELF} site hosts --bench-dir ${FL_BENCH_DIR}"
    return 0
  fi
  # BENCHBAR_SUDO=gui: one password dialog, one root script
  if fl_sudo_gui; then fl_hosts_add_gui "$FL_SITE"; return $?; fi
  if ! fl_sudo_begin "add '${line}' to ${FL_HOSTS_FILE}"; then
    fl_warn "skipped without sudo; run: ${FL_SELF} repair --bench-dir ${FL_BENCH_DIR}   (adds '${line}' inside the benchbar block)"
    FL_STEP_RESULT="skipped"
    FL_SKIP_COMMAND="${FL_SELF} site hosts --bench-dir ${FL_BENCH_DIR}"
    return 0
  fi
  fl_backup_file "$FL_HOSTS_FILE" || return 1
  if [[ "$(fl_rc_markers_state "$FL_HOSTS_FILE" "$FL_HOSTS_START" "$FL_HOSTS_END")" == "present" ]]; then
    # shellcheck disable=SC2016  # an awk program
    fl_hosts_rewrite 1 '$0 == ENVIRON["E"] { print ENVIRON["L"] } { print }' "L=${line}" "E=${FL_HOSTS_END}" || return 1
  else
    printf '\n%s\n%s\n%s\n' "$FL_HOSTS_START" "$line" "$FL_HOSTS_END" | sudo tee -a "$FL_HOSTS_FILE" >/dev/null || { fl_fail "sudo tee failed"; return 1; }
  fi
  fl_hosts_has_site || { fl_fail "${FL_HOSTS_FILE} still has no entry for ${FL_SITE}"; return 1; }
  fl_ok "added '${line}' to ${FL_HOSTS_FILE} (backup: ${FL_LAST_BACKUP:-none})"
}

# The logs are open while the bench runs (bench.log is launchd's
# StandardOutPath, the worker logs are Procfile redirections), so a rename
# would take the writers along and the live file would stay empty for good.
# Copy, then truncate in place: the writers keep their file. At most
# FL_LOG_KEEP_OLD copies stay; older ones go, oldest first.
FL_LOG_KEEP_OLD="${FL_LOG_KEEP_OLD:-3}"
act_rotate_logs() {
  local f mb src dest olds total i
  for f in bench.log worker.log worker.error.log; do
    src="${FL_BENCH_DIR}/logs/${f}"
    mb="$(fl_file_mb "$src")"
    [[ "$mb" -ge "$FL_LOG_WARN_MB" ]] || continue
    dest="${src}.old.$(fl_backup_stamp)"
    if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
      fl_info "dry-run: would copy ${src} to ${dest} and truncate it in place (the bench keeps writing to it)"
      continue
    fi
    cp -p "$src" "$dest" 2>/dev/null || { fl_fail "could not copy ${src} to ${dest}"; return 1; }
    : >"$src" 2>/dev/null || { fl_fail "could not truncate ${src}"; return 1; }
    fl_log "rotated ${src} -> ${dest}"
    fl_info "rotated: ${dest} (the live ${f} starts empty)"
    # the oldest copies past the cap: the stamp in the name sorts by time,
    # so the glob's order is oldest first
    olds=("${src}".old.*)
    total=0
    [[ -e "${olds[0]}" ]] && total="${#olds[@]}"
    i=0
    while [[ $((total - i)) -gt "$FL_LOG_KEEP_OLD" ]]; do
      rm -f "${olds[$i]}" && fl_info "removed the old copy ${olds[$i]} (keeping ${FL_LOG_KEEP_OLD})"
      i=$((i + 1))
    done
  done
}

act_redis_stop() {
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would offer to stop Homebrew redis on 6379"
    return 0
  fi
  if [[ "${FL_ASSUME_YES:-0}" == "1" || ! -t 0 ]]; then
    # a question nobody can answer: the step is skipped, never "done"
    fl_info "not stopping redis on 6379 without being asked; run: brew services stop redis   (only if nothing else needs it)"
    FL_STEP_RESULT="skipped"
    return 0
  fi
  if fl_confirm "Stop Homebrew redis on 6379? (only if nothing else on this Mac uses it)"; then
    fl_run brew services stop redis || return 1
    fl_ok "stopped Homebrew redis"
  else
    fl_info "left redis running"
  fi
}

# ---------------------------------------------------------------- JSON events
#
# repair --json streams one JSON object per line on fd 3 (the command's real
# stdout; the human text goes to the run's log): a plan, a step per action
# (running, then done, skipped or failed), and done with the exit code.

FL_JSON_EVENTS="${FL_JSON_EVENTS:-0}"

fl_event() {
  [[ "$FL_JSON_EVENTS" == "1" ]] || return 0
  printf '%s\n' "$1" >&3
}

# Actions that need sudo: the app cannot type a password, so it shows them
# as "run in Terminal" and the run skips them without a terminal.
fl_action_needs_sudo() {
  case "$1" in hosts_entry|wkhtmltopdf_install) return 0 ;; esac
  return 1
}

fl_event_plan() {
  local actions="$1" a sep="" fixes f fsep
  [[ "$FL_JSON_EVENTS" == "1" ]] || return 0
  local body=""
  for a in $actions; do
    fixes=""; fsep=""
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      fixes="${fixes}${fsep}$(fl_json_str "$f")"; fsep=","
    done < <(fl_doctor_checks_for_action "$a")
    body="${body}${sep}{\"id\":\"${a}\",\"label\":$(fl_json_str "$(fl_action_label "$a")"),\"fixes\":[${fixes}],\"sudo\":$(fl_json_bool "$(fl_action_needs_sudo "$a" && printf 1 || printf 0)")}"
    sep=","
  done
  fl_event "{\"event\":\"plan\",\"schema_version\":${FL_SCHEMA_VERSION:-1},\"cli_version\":\"${FL_VERSION:-0}\",\"bench\":$(fl_json_str "$FL_BENCH_DIR"),\"dry_run\":$(fl_json_bool "${FL_DRY_RUN:-0}"),\"actions\":[${body}],\"backups\":$(fl_json_str "${FL_BACKUP_ROOT}"),\"log\":$(fl_json_str "${FL_LOG_FILE:-}")}"
}

fl_event_step() {
  fl_event "{\"event\":\"step\",\"action\":\"$1\",\"status\":\"$2\",\"message\":$(fl_json_str "$3")}"
}

# ---------------------------------------------------------------- engine

# fl_repair_engine TITLE [GROUP...]: check, plan, confirm, apply, verify.
# Returns 0 when everything is healthy afterwards, 1 when something failed.
fl_repair_engine() {
  shift
  local actions action i n=0 rows=() unchanged remaining status labels step_from optional_left="" ids
  fl_doctor_run "$@"
  actions=""
  for action in $(fl_doctor_actions); do
    # FL_ENGINE_SKIP_ACTIONS: actions a command refuses to run (adopt never installs into env)
    case " ${FL_ENGINE_SKIP_ACTIONS:-} " in *" $action "*) continue ;; esac
    # an action that is only a question (stop the Homebrew redis?) is left
    # out when nobody can answer it (--yes, no terminal): it would be
    # "skipped" on every run and a second repair could never say unchanged
    if fl_action_is_question "$action" && [[ "${FL_ASSUME_YES:-0}" == "1" || ! -t 0 ]] && [[ "${FL_DRY_RUN:-0}" != "1" ]]; then
      optional_left="${optional_left}${optional_left:+, }$(fl_action_label "$action")"
      continue
    fi
    actions="${actions}${actions:+ }${action}"
  done
  unchanged=$(( ${#FL_D_IDS[@]} - $(fl_doctor_count warn) - $(fl_doctor_count fail) ))
  # the MariaDB labels name the running benches: one scan, before the labels' subshells
  case " $actions " in *" mariadb_"*) fl_mariadb_running_benches_prime ;; esac

  printf '\n%sPlan%s\n' "$FL_BOLD" "$FL_RESET"
  fl_doctor_print compact
  if [[ -z "$actions" ]]; then
    fl_event_plan ""
    [[ -z "${FL_ENGINE_PLAN_HOOK:-}" ]] || "$FL_ENGINE_PLAN_HOOK" ""
    printf '\n'
    if [[ "$(fl_doctor_count fail)" != "0" ]]; then
      fl_warn "unchanged: nothing benchbar can repair automatically; follow the fix lines above"
      return 1
    fi
    if [[ "$(fl_doctor_count warn)" != "0" ]]; then
      fl_ok "unchanged: $(fl_doctor_count ok) checks pass, $(fl_doctor_count warn) warning(s) need a manual step (see above)"
      [[ -z "$optional_left" ]] || fl_info "optional, not asked without a terminal or under --yes: ${optional_left}"
      return 0
    fi
    fl_ok "unchanged: all ${#FL_D_IDS[@]} checks pass, nothing to do"
    return 0
  fi

  fl_event_plan "$actions"
  [[ -z "${FL_ENGINE_PLAN_HOOK:-}" ]] || "$FL_ENGINE_PLAN_HOOK" "$actions"
  if [[ ( "$FL_JSON_EVENTS" == "1" || "$FL_JSONL" == "1" ) && "${FL_DRY_RUN:-0}" == "1" ]]; then
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
  if [[ "$FL_JSONL" == "1" ]]; then
    # the stream gets one step line per action: numbered from 1 (adopt), or
    # nested under FL_ENGINE_PARENT without a number (install's service
    # step). An action in FL_ENGINE_QUIET_ACTIONS has its own step already.
    ids=()
    for action in $actions; do
      case " ${FL_ENGINE_QUIET_ACTIONS:-} " in *" $action "*) ids+=("") ;; *) ids+=("$action") ;; esac
    done
    if [[ -n "${FL_ENGINE_PARENT:-}" ]]; then fl_steps_ids -n -p "$FL_ENGINE_PARENT" "${ids[@]}"; else fl_steps_ids "${ids[@]}"; fi
  fi
  i=0
  status=0
  for action in $actions; do
    fl_step_begin "$i"
    # an action may report "skipped" (or "unchanged") through FL_STEP_RESULT
    FL_STEP_RESULT="done"
    step_from="$(wc -l <"${FL_LOG_FILE:-/dev/null}" 2>/dev/null | tr -d ' ')"
    fl_event_step "$action" running "$(fl_action_label "$action")"
    if "act_${action}"; then
      fl_step_end "$FL_STEP_RESULT"
      if [[ "$FL_STEP_RESULT" == "done" ]]; then
        fl_event_step "$action" "done" "$(fl_action_label "$action")"
      else
        fl_event_step "$action" "$FL_STEP_RESULT" "$(fl_log_step_message "${step_from:-0}")"
      fi
    else
      fl_step_end failed
      fl_event_step "$action" failed "$(fl_log_step_message "${step_from:-0}")"
      status=1
      case "$action" in
        # a legacy agent that is still loaded must not get a second agent for
        # the same bench next to it (two runners, two honchos)
        env_rebuild|honcho_install|node_install|legacy_migrate) fl_warn "stopping: later steps depend on this one"; break ;;
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
    # every action finished; a failure from here on is a check, not a command
    FL_LAST_COMMAND=""
    fl_doctor_run "$@"
    fl_doctor_print compact
    remaining=""
    for action in $(fl_doctor_actions); do
      case " $FL_OPTIONAL_ACTIONS ${FL_ENGINE_SKIP_ACTIONS:-} " in *" $action "*) continue ;; esac
      remaining="${remaining} ${action}"
    done
  fi
  # inside install the outer run prints the one summary, of its own steps
  [[ "${FL_ENGINE_NO_SUMMARY:-0}" == "1" ]] || fl_steps_summary
  if [[ "$status" != "0" ]]; then
    return 1
  fi
  if [[ -n "$remaining" && "${FL_DRY_RUN:-0}" != "1" ]]; then
    fl_warn "some checks still need attention; see the fix lines above"
    return 1
  fi
  # a FAIL with no action (a disabled formula, a missing tool) is named
  # once more; the exit code says what repair did (doctor's says the state)
  if [[ "${FL_DRY_RUN:-0}" != "1" && "$(fl_doctor_count fail)" != "0" ]]; then
    fl_warn "some checks still fail and need a manual step; see the fix lines above (doctor exits 1 while they do)"
  fi
  return 0
}
