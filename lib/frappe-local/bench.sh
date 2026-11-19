#!/usr/bin/env bash

# fl_text_plain_ok TEXT: true when TEXT is plain text to bash (inside double
# quotes), to XML and to a hosts line: no double quote, backslash, dollar
# sign, backtick, <, >, & and no control character. Otherwise
# FL_TEXT_PROBLEM names the first character in the way.
FL_TEXT_PROBLEM=""
fl_text_plain_ok() {
  local t="$1" nl=$'\n' tab=$'\t'
  FL_TEXT_PROBLEM=""
  case "$t" in
    *'"'*) FL_TEXT_PROBLEM='a double quote (")' ;;
    *"\\"*) FL_TEXT_PROBLEM="a backslash (\\)" ;;
    *'$'*) FL_TEXT_PROBLEM='a dollar sign ($)' ;;
    *'`'*) FL_TEXT_PROBLEM='a backtick (`)' ;;
    *'<'*) FL_TEXT_PROBLEM='a less-than sign (<)' ;;
    *'>'*) FL_TEXT_PROBLEM='a greater-than sign (>)' ;;
    *'&'*) FL_TEXT_PROBLEM='an ampersand (&)' ;;
    *"$nl"*) FL_TEXT_PROBLEM='a newline' ;;
    *"$tab"*) FL_TEXT_PROBLEM='a tab' ;;
    *[[:cntrl:]]*) FL_TEXT_PROBLEM='a control character' ;;
  esac
  [[ -z "$FL_TEXT_PROBLEM" ]]
}

# A bench path lands inside the runner's double quotes (BENCH="..."), in the
# agent's plist and in pkill patterns: one check, before anything renders.
fl_bench_path_ok() { fl_text_plain_ok "$1"; }
fl_bench_path_valid() {
  fl_bench_path_ok "$1" || fl_die "The bench path ${1} contains ${FL_TEXT_PROBLEM}, which the runner script, the launchd agent and the hosts file cannot carry as plain text." \
    "Move the bench to a folder whose path has none of \" \\ \$ \` < > & and no control characters, then run the command again."
}

# The default site lands in the runner (SITE="...", the ping's Host header)
# and in the hosts line: plain text, and no whitespace.
fl_site_render_valid() {
  local s="$1"
  if ! fl_text_plain_ok "$s"; then
    fl_die "The site name '${s}' contains ${FL_TEXT_PROBLEM}, which the runner script and the hosts file cannot carry as plain text." \
      "Pick the site with --site NAME, or rename the site folder; lowercase letters, digits, '-' and '.' are safe."
  fi
  case "$s" in
    *[[:space:]]*) fl_die "The site name '${s}' contains whitespace, which the runner script and the hosts file cannot carry." \
      "Pick the site with --site NAME, or rename the site folder; lowercase letters, digits, '-' and '.' are safe." ;;
  esac
}

# fl_require_plain_bench: the current bench's path and default site, refused
# with a message when the service files cannot carry them. Called by the
# commands that write them or start the bench; doctor only reports
# (chk_bench_path), so it stays read only for every bench.
fl_require_plain_bench() {
  # shellcheck disable=SC2153  # set by fl_context_init (state.sh)
  fl_bench_path_valid "$FL_BENCH_DIR"
  fl_site_render_valid "$FL_SITE"
}

fl_bench_run() {
  local bench_dir="$1"; shift
  fl_redact_url_v FL_LAST_COMMAND "cd ${bench_dir} && $*"
  if [[ "$FL_DRY_RUN" == "1" ]]; then
    fl_info "dry-run: ${FL_LAST_COMMAND}"
    return 0
  fi
  (cd "$bench_dir" && "$@")
}

# fl_dry_run_pending TOOL: true in a dry run when TOOL is missing and step 1
# of benchbar install (BENCHBAR_PLAN_STEP1 names its script) would install it;
# says so as a note, not a warning, so the plan stays a plan
fl_dry_run_pending() {
  [[ "${FL_DRY_RUN:-0}" == "1" ]] || return 1
  fl_info "dry-run: $1 is not installed yet; step 1 (${BENCHBAR_PLAN_STEP1:-the system dependencies}) will install it"
}

fl_install_pipx_if_needed() {
  # uv is preferred for bench itself; pipx is only needed without it
  command -v uv >/dev/null 2>&1 && return 0
  if [[ -n "${BENCHBAR_PLAN_STEP1:-}" ]] && ! command -v pipx >/dev/null 2>&1; then
    fl_dry_run_pending uv && return 0
  fi
  fl_section "PIPX"
  fl_info "Checking pipx"
  if command -v pipx >/dev/null 2>&1; then
    fl_ok "pipx already installed - $(pipx --version)"
  else
    # Linux has uv from phase 00 and never uses Homebrew
    if fl_is_linux; then fl_die "Neither uv nor pipx is installed." "Run ./$(fl_phase00_script) (it installs uv)"; fi
    fl_warn "pipx is missing; installing with Homebrew"
    fl_run brew install pipx || fl_die "pipx install failed." "Manual command: brew install pipx"
  fi
  PIPX_BIN_DIR="$(pipx environment --value PIPX_BIN_DIR 2>/dev/null || echo "$HOME/.local/bin")"
  export PATH="${PIPX_BIN_DIR}:$PATH"
  fl_state_set PIPX_BIN_DIR "$PIPX_BIN_DIR"
}

# Who installed the bench command on PATH: uv, pipx or other (nothing when
# there is no bench). Existing pipx installs are reported, never migrated.
fl_bench_owner() {
  local bin dir target
  bin="$(command -v bench 2>/dev/null || true)"
  [[ -n "$bin" ]] || return 0
  target="$bin"
  while [[ -L "$target" ]]; do
    dir="$(cd "$(dirname "$target")" && pwd)"
    target="$(readlink "$target")"
    [[ "$target" == /* ]] || target="${dir}/${target}"
  done
  case "$target" in
    */uv/tools/*) printf 'uv' ;;
    */pipx/venvs/*|*/pipx/*/venvs/*) printf 'pipx' ;;
    *) printf 'other' ;;
  esac
}

# pipx lists frappe-bench as an indented "package frappe-bench" line
fl__pipx_has_bench() {
  local listed
  listed="$(pipx list 2>/dev/null || true)"
  [[ "$listed" == '   package frappe-bench'* || "$listed" == *$'\n   package frappe-bench'* ]]
}

fl_install_bench_if_needed() {
  fl_section "BENCH CLI"
  fl_info "Checking frappe-bench CLI"
  if command -v bench >/dev/null 2>&1; then
    # a bench that is on PATH but does not run (its venv's Python was
    # upgraded away) would fail at bench init with a stack trace; say so
    # here with the reinstall for whichever tool owns it
    local ver reinstall="uv tool install --reinstall frappe-bench"
    [[ "$(fl_bench_owner)" == "pipx" ]] && reinstall="pipx reinstall frappe-bench"
    if ! ver="$(bench --version 2>/dev/null)"; then
      fl_die "bench at $(command -v bench) does not run (bench --version failed)." "Reinstall it: ${reinstall}"
    fi
    ver="$(printf '%s' "$ver" | tr -d '[:space:]')"
    fl_ok "bench ${ver:-(version unknown)} at $(command -v bench)"
    if [[ -n "$ver" && -n "${FL_BENCH_MIN:-}" ]] && fl_version_lt "$ver" "$FL_BENCH_MIN"; then
      fl_warn "bench ${ver} is older than ${FL_BENCH_MIN}, the oldest known to handle profile ${FL_PROFILE}; a newer one is safer"
      if [[ "$reinstall" == pipx* ]]; then fl_fix "pipx upgrade frappe-bench"; else fl_fix "uv tool upgrade frappe-bench"; fi
    fi
    return 0
  fi
  if [[ -n "${BENCHBAR_PLAN_STEP1:-}" ]] && ! command -v uv >/dev/null 2>&1 && ! command -v pipx >/dev/null 2>&1; then
    fl_dry_run_pending uv && { fl_info "dry-run: frappe-bench is then installed with: uv tool install frappe-bench"; return 0; }
  fi
  if command -v uv >/dev/null 2>&1; then
    # the official docs install bench with uv; uv says where its executables
    # go (UV_TOOL_BIN_DIR, XDG_BIN_HOME, else ~/.local/bin)
    fl_warn "frappe-bench is missing; installing with uv"
    fl_run uv tool install frappe-bench || fl_die "frappe-bench install failed." "Manual command: uv tool install frappe-bench"
    PIPX_BIN_DIR="$(uv tool dir --bin 2>/dev/null || true)"
    PIPX_BIN_DIR="${PIPX_BIN_DIR:-$HOME/.local/bin}"
    export PATH="${PIPX_BIN_DIR}:$PATH"
  elif fl__pipx_has_bench; then
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

# fl_bench_require_uv: bench init needs uv (it runs "uv venv"), also when bench
# itself came from pipx. Stops, with the fix, before pipx, bench or bench init
# cost any time (issue 112: the install ran 15 minutes of phase 00, then failed
# at "uv venv" and left a folder that blocked every rerun). A dry run says which
# step installs it.
fl_bench_require_uv() {
  fl_uv_on_path && return 0
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    if [[ -n "${BENCHBAR_PLAN_STEP1:-}" ]]; then
      fl_info "dry-run: uv is not installed yet; step 1 (${BENCHBAR_PLAN_STEP1}) will install it"
    else
      fl_warn "dry-run: uv not found; bench init needs it and a real run would stop here"
    fi
    return 0
  fi
  local hint="brew install uv"
  fl_is_linux && hint="curl -LsSf https://astral.sh/uv/install.sh | sh"
  fl_die "uv is not installed, and bench init needs it to make the bench's environment." \
    "Run ./$(fl_phase00_script) --profile ${FL_PROFILE:-v15-lts} (it installs uv), or by hand: ${hint}"
}

fl_bench_complete() {
  local bench_dir="$1"
  [[ -d "$bench_dir/apps/frappe" && -d "$bench_dir/env" && -f "$bench_dir/sites/apps.txt" ]]
}

# A bench that has real content (apps or sites) is never moved aside by a
# plain rerun, even when env/ or node_modules are gone: it stops with the
# repair hint. The one exception is fl_bench_incomplete_init (frappe alone,
# no site: nothing of anyone's in it).
fl_bench_has_data() {
  local bench_dir="$1" s
  [[ -d "$bench_dir/apps/frappe" ]] && return 0
  for s in "$bench_dir"/sites/*/site_config.json; do
    [[ -f "$s" ]] && return 0
  done
  return 1
}

# fl_bench_incomplete_init DIR: DIR is a bench init that stopped half way:
# frappe was cloned (apps/frappe) but the env or sites/apps.txt never got
# made, no site exists and apps/ holds no app but frappe. Nothing in it is
# anyone's data, so a rerun moves it aside and starts over. A folder that
# holds a site, or any other app (maybe with uncommitted work), is never one.
fl_bench_incomplete_init() {
  local bench_dir="$1" s a
  [[ -d "$bench_dir/apps/frappe" ]] || return 1
  for a in "$bench_dir"/apps/* "$bench_dir"/apps/.[!.]*; do
    [[ -e "$a" ]] || continue
    [[ "${a##*/}" == frappe ]] || return 1
  done
  [[ ! -f "$bench_dir/sites/apps.txt" || ! -e "$bench_dir/env/bin/python" ]] || return 1
  for s in "$bench_dir"/sites/*/site_config.json; do
    [[ -f "$s" ]] && return 1
  done
  return 0
}

# fl_bench_is_skeleton DIR: what a bench init that failed before it cloned
# frappe leaves (uv missing, no network, a crontab refusal): folders and
# nothing in them. No app in apps/, no site in sites/, no file that has
# content outside logs/ and env/ (a log, a half made venv: a rerun makes
# both again), no link, so nothing in it is anyone's. A rerun moves it
# aside, as it does a half init (fl_bench_incomplete_init).
fl_bench_is_skeleton() {
  local bench_dir="$1" e
  [[ -d "$bench_dir" && ! -L "$bench_dir" ]] || return 1
  for e in "$bench_dir"/apps/* "$bench_dir"/apps/.[!.]* "$bench_dir"/sites/* "$bench_dir"/sites/.[!.]*; do
    [[ -e "$e" || -L "$e" ]] && return 1
  done
  [[ -z "$(find "$bench_dir" \( -path "$bench_dir/logs" -o -path "$bench_dir/env" -o -path "$bench_dir/.benchbar.lock" \) -prune -o \
    \( -type l -o \( -type f -size +0 \) \) -print 2>/dev/null | awk 'NR==1')" ]]
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

# fl_bench_init_if_needed DIR FRAPPE_REF PYTHON [REPAIR] [SKIP_ASSETS]: SKIP_ASSETS=1
# (a frappe commit pin) leaves the first build to the caller, which builds
# once the pinned commit is checked out, so a commit the clone does not
# reach is found before anything is built.
fl_bench_init_if_needed() {
  local bench_dir="$1" frappe_ref="$2" python_bin="$3" repair="${4:-0}" skip_assets="${5:-0}" timestamp backup init_extra=()
  [[ "$skip_assets" == "1" ]] && init_extra+=(--skip-assets)
  local timeout_seconds="${BENCH_INIT_TIMEOUT_SECONDS:-2700}" init_code=0
  # BENCH_INIT_TIMEOUT_SECONDS: seconds, 0 for no limit; anything else is the default
  [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || timeout_seconds=2700
  fl_section "BENCH INIT"
  fl_info "Checking bench directory ${bench_dir}"
  if fl_bench_complete "$bench_dir"; then
    fl_ok "${bench_dir} already initialized"
    fl_state_set BENCH_INIT complete
    return 0
  fi
  fl_bench_require_uv
  if [[ -e "$bench_dir" ]]; then
    timestamp="$(date +%Y%m%d%H%M%S)"
    backup="${bench_dir}.incomplete.${timestamp}"
    if fl_bench_incomplete_init "$bench_dir"; then
      # an earlier bench init (a failure, a timeout, a closed window) left a half built
      # bench with no site: moved aside, never deleted, so a rerun starts over by itself
      fl_warn "An earlier bench init stopped half way in ${bench_dir} (no env or no apps.txt, and no site); moving it to ${backup} and starting over"
      fl_run mv "$bench_dir" "$backup"
    elif fl_bench_is_skeleton "$bench_dir"; then
      # a bench init that failed early (no uv, no network) made the folders and nothing else
      fl_warn "An earlier bench init stopped before it cloned frappe (${bench_dir} holds only empty folders); moving it to ${backup} and starting over"
      fl_run mv "$bench_dir" "$backup"
    else
      if fl_bench_has_data "$bench_dir"; then
        fl_die "Bench ${bench_dir} has apps or sites but its env is missing or incomplete." "This is a repair, not a reinstall. Run: ${FL_SELF} repair --bench-dir ${bench_dir}"
      fi
      if [[ "$repair" != "1" ]]; then
        fl_die "Bench directory exists but is incomplete: ${bench_dir}" "Move it aside or rerun with --repair-bench after reading: mv ${bench_dir} ${bench_dir}.incomplete.\$(date +%Y%m%d%H%M%S)"
      fi
      fl_warn "Moving incomplete bench to ${backup}"
      fl_run mv "$bench_dir" "$backup"
    fi
  fi
  # --no-backups keeps bench init away from crontab: a dev bench needs no
  # backup cron, and without Full Disk Access the crontab write fails and
  # bench offers to delete the new bench (frappe/bench#1730)
  if fl_crontab_denied; then
    fl_warn "crontab is not readable here (no Full Disk Access); bench init runs with --no-backups, so it is not needed"
    fl_info "for bench setup backups later: System Settings > Privacy & Security > Full Disk Access, add Terminal"
  fi
  fl_info "Running bench init for frappe ref ${frappe_ref}"
  if [[ "$timeout_seconds" -gt 0 ]]; then fl_info "bench init timeout: $((timeout_seconds / 60)) minutes (BENCH_INIT_TIMEOUT_SECONDS changes it)"; else fl_info "bench init has no time limit"; fi
  fl_run_with_timeout "$timeout_seconds" "bench init" bench init "$bench_dir" --frappe-branch "$frappe_ref" --python "$python_bin" --no-backups --verbose ${init_extra[@]+"${init_extra[@]}"} || init_code=$?
  if [[ "$init_code" == "124" ]]; then
    fl_die "bench init did not finish within $(fl_fmt_secs "$timeout_seconds")." \
      "Run benchbar install again: the half built bench is moved aside and init starts over. On a slow network or disk give it more time: BENCH_INIT_TIMEOUT_SECONDS=5400 benchbar install"
  elif [[ "$init_code" != "0" ]]; then
    fl_die "bench init failed." "Run benchbar install again (a half built bench is moved aside and init starts over), or by hand: bench init ${bench_dir} --frappe-branch ${frappe_ref} --python ${python_bin} --no-backups --verbose${init_extra[*]:+ ${init_extra[*]}}"
  fi
  [[ "$skip_assets" != "1" ]] || fl_needs_build_mark "$bench_dir"
  fl_state_set BENCH_INIT complete
  fl_changed bench "$bench_dir" "created with frappe ${frappe_ref}"
}

# fl_commit_present DIR SHA: SHA is a commit of the clone in DIR
fl_commit_present() {
  git -C "$1" cat-file -e "${2}^{commit}" >/dev/null 2>&1
}

# fl_commit_reach DIR SHA: true when the clone in DIR has commit SHA, after
# fetching it when it does not (every remote's branches and tags, then the
# rest of a shallow history). Git never asks a question here.
fl_commit_reach() {
  local dir="$1" sha="$2" remote
  fl_commit_present "$dir" "$sha" && return 0
  fl_git_in "$dir" fetch --all --tags --quiet || true
  fl_commit_present "$dir" "$sha" && return 0
  if [[ "$(git -C "$dir" rev-parse --is-shallow-repository 2>/dev/null || true)" == "true" ]]; then
    fl_git_in "$dir" fetch --all --tags --unshallow --quiet || true
  fi
  fl_commit_present "$dir" "$sha" && return 0
  # a single branch clone has not seen a commit that is on another branch: the
  # remote may hand out a commit it has by its hash (GitHub does)
  for remote in $(git -C "$dir" remote 2>/dev/null || true); do
    fl_git_in "$dir" fetch --quiet "$remote" "$sha" || true
    fl_commit_present "$dir" "$sha" && return 0
  done
  return 1
}

# A build that was left for later (bench init or get-app with --skip-assets,
# then a refused pin or a failure): the marker tells the next run to build.
fl_needs_build_marker() { printf '%s/logs/.benchbar/needs-build' "$1"; }
fl_needs_build_mark() {
  [[ "${FL_DRY_RUN:-0}" == "1" || ! -d "$1" ]] && return 0
  mkdir -p "${1}/logs/.benchbar" 2>/dev/null && date -u +%Y-%m-%dT%H:%M:%SZ >"$(fl_needs_build_marker "$1")" 2>/dev/null || true
}

# fl_pin_app_commit BENCH APP SHA BRANCH: APP's clone onto the pinned commit.
# A commit the clone does not reach stops the run here, before the build
# that follows a pin (the callers get-app with --skip-assets for it).
fl_pin_app_commit() {
  local bench_dir="$1" app="$2" sha="$3" branch="${4:-}" dir full head
  dir="${bench_dir}/apps/${app}"
  [[ -d "${dir}/.git" ]] || return 0
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: git -C ${dir} fetch --all --tags, then git checkout ${sha}"
    return 0
  fi
  # already there: nothing to do, and no rebuild
  full="$(git -C "$dir" rev-parse -q --verify "${sha}^{commit}" 2>/dev/null || true)"
  head="$(git -C "$dir" rev-parse -q HEAD 2>/dev/null || true)"
  if [[ -n "$full" && "$full" == "$head" ]]; then
    fl_ok "${app} is at the pinned commit ${sha}"
    return 0
  fi
  fl_warn "Pinning ${app} to commit ${sha}"
  fl_commit_reach "$dir" "$sha" || fl_die "The pinned commit ${sha} of ${app} is not in its clone${branch:+ (branch ${branch})} and its remote did not hand it out; nothing was built." \
    "Check the commit (it must be on a branch or tag of that repo)$([[ "${#sha}" -ge 40 ]] || printf '; a remote cannot hand out an abbreviated hash, so use the full 40 character hash'), or drop the pin: the next install builds what is there. The clone is ${dir}."
  fl_run git -C "$dir" checkout --quiet "$sha" \
    || fl_die "commit checkout failed for ${app}." "Manual command: git -C ${dir} checkout ${sha}"
  FL_PINS_APPLIED=1
  fl_needs_build_mark "$bench_dir"
}
FL_PINS_APPLIED=0

fl_get_app_if_needed() {
  local bench_dir="$1" app="$2" branch="$3" repo="${4:-}" commit="${5:-}" pin="${6:-0}" skip_flag=() was_there=0
  [[ -d "$bench_dir/apps/$app" ]] && was_there=1
  fl_info "Checking app ${app}"
  # a pinned app is built once, after its checkout (see fl_pin_app_commit)
  [[ "$pin" == "1" && -n "$commit" ]] && skip_flag+=(--skip-assets)
  if [[ -d "$bench_dir/apps/$app" ]]; then
    fl_ok "apps/${app} already cloned"
  else
    fl_info "Getting ${app} at ${branch}"
    if [[ -n "$repo" ]]; then
      fl_bench_run_long "bench get-app ${app} (${branch})" "$bench_dir" bench get-app --branch "$branch" ${skip_flag[@]+"${skip_flag[@]}"} "$repo" \
        || fl_die "bench get-app failed for ${app}." "Manual command: cd ${bench_dir} && bench get-app --branch ${branch}${skip_flag[*]:+ ${skip_flag[*]}} ${repo}"
    else
      fl_bench_run_long "bench get-app ${app} (${branch})" "$bench_dir" bench get-app --branch "$branch" ${skip_flag[@]+"${skip_flag[@]}"} "$app" \
        || fl_die "bench get-app failed for ${app}." "Manual command: cd ${bench_dir} && bench get-app --branch ${branch}${skip_flag[*]:+ ${skip_flag[*]}} ${app}"
    fi
    fl_changed app "$app" "cloned at ${branch}"
  fi
  [[ "${#skip_flag[@]}" -eq 0 || "$was_there" == "1" ]] || fl_needs_build_mark "$bench_dir"
  if [[ "$pin" == "1" && -n "$commit" ]]; then
    fl_pin_app_commit "$bench_dir" "$app" "$commit" "$branch"
  fi
  fl_state_set "APP_${app}_CLONED" yes
}

# fl_bench_env_setuptools DIR: 'setuptools<70' into DIR's env, so Frappe v15
# and honcho find pkg_resources (setuptools 70 dropped it, and a fresh env
# with Python 3.12+ has none). uv when it is there, else the env's pip.
fl_bench_env_setuptools() {
  local py="$1/env/bin/python"
  if command -v uv >/dev/null 2>&1; then
    fl_run_long "install setuptools<70 into env (uv)" uv pip install --python "$py" 'setuptools<70'
  else
    fl_run_long "install setuptools<70 into env (pip)" "$py" -m pip install 'setuptools<70'
  fi
}

# fl_bench_write_ports DIR WEB SOCKETIO QUEUE CACHE: the port block into
# the bench's common_site_config.json with bench itself, and its
# config/redis_*.conf regenerated. Output goes to the run log.
fl_bench_write_ports() {
  local dir="$1" web="$2" sio="$3" queue="$4" cache="$5"
  (
    cd "$dir" || exit 1
    bench set-config -g -p webserver_port "$web" &&
    bench set-config -g -p socketio_port "$sio" &&
    bench set-config -g redis_queue "redis://127.0.0.1:${queue}" &&
    bench set-config -g redis_cache "redis://127.0.0.1:${cache}" &&
    bench set-config -g redis_socketio "redis://127.0.0.1:${cache}" &&
    bench setup redis
  ) >>"${FL_LOG_FILE:-/dev/null}" 2>&1
}

# ---------------------------------------------------------------- setup redis
#
# frappe v16 connects to the bench's Redis during new-site and install-app
# (a fresh v16 bench failed "install-app erpnext" with "Connection refused"
# on its redis_queue port). Before the service exists nothing runs them, so
# setup starts the bench's own Redis servers from config/redis_*.conf, and
# afterwards stops only the ones it started.

FL_SETUP_REDIS_PORTS=""

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
    if (cd "$bench_dir" && redis-server "config/$(basename "$conf")" --daemonize yes) >>"${FL_LOG_FILE:-/dev/null}" 2>&1 3>&-; then
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

# frappe's own command line (what "bench new-site" runs), started inside
# the bench's Python with the secrets read from stdin, one per line, and put
# in place of @secret0@, @secret1@ ... only inside that process. So no
# password is ever on a command line (ps), in the run log or in an error
# message. The same approach as benchbar pull's restore.
FL_PY_FRAPPE_SECRETS='import sys
secrets = [line.rstrip("\n") for line in sys.stdin]
def fill(arg):
    if arg.startswith("@secret") and arg.endswith("@"):
        return secrets[int(arg[7:-1])]
    return arg
sys.argv = ["bench_helper"] + [fill(a) for a in sys.argv[2:]]
from frappe.utils.bench_helper import main
main()'

# fl__frappe_with_secrets BENCH_DIR VAR... -- ARGS...: frappe ARGS in the bench,
# with the values of the named variables on stdin (names, never values, are
# arguments here, since fl_run_long logs its arguments).
fl__frappe_with_secrets() {
  local bench_dir="$1" var
  shift
  local names=()
  while [[ "$#" -gt 0 && "$1" != "--" ]]; do names+=("$1"); shift; done
  shift
  for var in "${names[@]}"; do printf '%s\n' "${!var}"; done |
    fl__in_dir "${bench_dir}/sites" "${bench_dir}/env/bin/python" -c "$FL_PY_FRAPPE_SECRETS" benchbar-secrets frappe "$@"
}

# fl_site_creating_marker BENCH SITE: the file that says "bench new-site
# SITE is running (or was cut short)". It lives in the bench's own
# logs/.benchbar folder, never inside sites/.
fl_site_creating_marker() { printf '%s/logs/.benchbar/creating-%s' "$1" "$2"; }

# fl_new_site_db_name: a database name in frappe's own shape (an underscore and
# 16 hex digits), chosen by benchbar so that it is known before new-site starts
fl_new_site_db_name() { printf '_%s' "$(head -c 4096 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-16)"; }

# fl_site_marker_db BENCH SITE: the database name the marker records, when it
# is a name benchbar made (see fl_new_site_create); nothing for an older marker
fl_site_marker_db() {
  local name
  name="$(sed -n 's/^db_name=//p' "$(fl_site_creating_marker "$1" "$2")" 2>/dev/null | awk 'NR==1')"
  [[ "$name" =~ ^_[0-9a-f]{16}$ ]] && printf '%s' "$name"
  return 0
}

# The record of a new-site that benchbar started: the database name it chose,
# written in benchbar's own state folder (outside the bench, so a marker that
# is copied or edited cannot forge it) before the marker and before new-site
# runs, keyed by the bench's path and the site. Removed when the site is done
# or the cut short one is cleaned up.
fl_site_record_file() {
  local h
  fl_path_hash_v h "$(fl_bench_canonical "$1")|$2"
  printf '%s/new-site/%s.rec' "$FL_STATE_DIR" "$h"
}

# fl_site_record_write BENCH SITE DB
fl_site_record_write() {
  local f tmp
  f="$(fl_site_record_file "$1" "$2")"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  tmp="${f}.tmp.$$"
  printf 'bench=%s\nsite=%s\ndb_name=%s\n' "$(fl_bench_canonical "$1")" "$2" "$3" >"$tmp" 2>/dev/null && mv "$tmp" "$f" 2>/dev/null
}

# fl_site_record_has BENCH SITE DB: the record names this bench, this site and this database
fl_site_record_has() {
  local f
  f="$(fl_site_record_file "$1" "$2")"
  [[ -f "$f" ]] || return 1
  grep -qxF -- "bench=$(fl_bench_canonical "$1")" "$f" && grep -qxF -- "site=$2" "$f" && grep -qxF -- "db_name=$3" "$f"
}

fl_site_record_remove() { local f; f="$(fl_site_record_file "$1" "$2")"; [[ ! -f "$f" ]] || rm -f "$f"; return 0; }

# fl_db_named_by_other_site BENCH SITE_DIR DB: prints the first sites/*/site_config.json,
# in this bench or in any bench benchbar knows (known and registered ones),
# that names DB, other than the config inside SITE_DIR itself. A config that
# cannot be read counts as naming it. 0 found, 1 none.
fl_db_named_by_other_site() {
  local bench_dir="$1" site_dir="$2" db="$3" b c own cfg line seen=$'\n' benches=()
  own="$(fl_bench_canonical "$bench_dir")/sites/${site_dir##*/}/site_config.json"
  benches=("$bench_dir")
  # Fails closed: a list that cannot be read, a known or registered bench
  # that is gone (an unmounted volume) or whose sites/ cannot be read counts
  # as naming DB, so nothing is dropped. A bench benchbar has never seen is
  # not looked at (docs/DECISIONS.md).
  if declare -F fl_known_bench_candidates >/dev/null; then
    # every folder benchbar was told of, the unfiltered list: one that is gone
    # (an unmounted volume) fails closed below; one that is there but is no
    # bench (auto-detection found a folder that is not one) is skipped
    local known
    known="$(fl_known_bench_candidates 2>/dev/null)" || { printf '%s' "the list of known benches (it could not be read)"; return 0; }
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      if [[ ! -e "$line" ]]; then printf '%s' "the known bench ${line} (gone, perhaps on a volume that is not mounted)"; return 0; fi
      fl_is_bench_dir "$line" && benches+=("$line")
    done <<<"$known"
  fi
  if [[ -e "${FL_STATE_DIR}/registered-benches.txt" ]]; then
    [[ -r "${FL_STATE_DIR}/registered-benches.txt" ]] || { printf '%s' "${FL_STATE_DIR}/registered-benches.txt"; return 0; }
    while IFS= read -r line || [[ -n "$line" ]]; do [[ -z "$line" ]] || benches+=("$line"); done <"${FL_STATE_DIR}/registered-benches.txt"
  fi
  for b in "${benches[@]}"; do
    c="$(fl_bench_canonical "$b")"
    case "$seen" in *$'\n'"$c"$'\n'*) continue ;; esac
    seen="${seen}${c}"$'\n'
    if [[ ! -d "$c/sites" || ! -r "$c/sites" || ! -x "$c/sites" ]]; then
      printf '%s' "$c/sites (it cannot be read)"; return 0
    fi
    for cfg in "$c"/sites/*/site_config.json; do
      [[ -e "$cfg" && "$cfg" != "$own" ]] || continue
      if [[ ! -r "$cfg" ]] || grep -Eq "\"db_name\"[[:space:]]*:[[:space:]]*\"${db}\"" "$cfg" 2>/dev/null; then
        printf '%s' "$cfg"; return 0
      fi
    done
  done
  return 1
}

# fl__db_by_hand DB: the command a person runs to drop a half made database (and its user) themselves
fl__db_by_hand() {
  # shellcheck disable=SC2016
  printf 'mariadb -u root -p -e "DROP DATABASE IF EXISTS \\`%s\\`; DROP USER IF EXISTS '"'%s'@'%%', '%s'@'localhost'"'"' "$1" "$1" "$1"
}

# fl_site_incomplete BENCH SITE [WHY]: true, with the recovery printed, when a
# bench new-site for SITE was cut short (Ctrl+C, a crash): the folder is
# there, the database may be half made, site_config.json may be missing.
# The install cleans a provable one up itself (fl_site_recover); this is
# the stop for the rest, and WHY says why benchbar did not. What
# fl_site_recover left in FL_SITE_RECOVER_DB and _FOREIGN is read here once
# and cleared, so the next call (a site add, a restore) never sees it.
FL_SITE_RECOVER_WHY=""
FL_SITE_RECOVER_FOREIGN=0
FL_SITE_RECOVER_DB=""
fl_site_incomplete() {
  local bench_dir="$1" site_name="$2" marker foreign="$FL_SITE_RECOVER_FOREIGN" db="$FL_SITE_RECOVER_DB"
  FL_SITE_RECOVER_FOREIGN=0; FL_SITE_RECOVER_DB=""
  marker="$(fl_site_creating_marker "$bench_dir" "$site_name")"
  [[ -d "$bench_dir/sites/$site_name" && -f "$marker" ]] || return 1
  fl_fail "a previous bench new-site ${site_name} did not finish (started $(sed -n 1p "$marker" 2>/dev/null || printf '?')); the site folder is incomplete"
  [[ -z "${3:-}" ]] || fl_info "benchbar did not clean it up itself: ${3}"
  if [[ "$foreign" == "1" ]]; then
    fl_fix "mv $(printf '%q' "${bench_dir}/sites/${site_name}") ~/$(printf '%q' "${site_name}.incomplete"), then run this again; leave the database ${db:-it names} alone until you know whose it is"
  elif [[ -n "$db" ]]; then
    fl_fix "mv $(printf '%q' "${bench_dir}/sites/${site_name}") ~/$(printf '%q' "${site_name}.incomplete"), then run this again. The database ${db} may be left behind: first check that no site uses it (grep -l '\"${db}\"' $(printf '%q' "$bench_dir")/sites/*/site_config.json), then drop it yourself: $(fl__db_by_hand "$db")   If the site works already (bench --site ${site_name} doctor), only remove ${marker}"
  else
    fl_fix "mv $(printf '%q' "${bench_dir}/sites/${site_name}") ~/$(printf '%q' "${site_name}.incomplete")   (then, if its database exists: cd $(printf '%q' "$bench_dir") && bench drop-site ${site_name} --force), then run this again; if the site works already (bench --site ${site_name} doctor), only remove ${marker}"
  fi
  return 0
}

# fl_site_orphan_stop BENCH SITE: the marker is there, the site folder is
# gone and the database could not be cleaned up: a stop that names it (starting
# new-site again would overwrite the marker and lose track of it).
fl_site_orphan_stop() {
  local bench_dir="$1" site_name="$2" db="$FL_SITE_RECOVER_DB" marker
  marker="$(fl_site_creating_marker "$bench_dir" "$site_name")"
  fl_fail "a previous bench new-site ${site_name} did not finish and sites/${site_name} is gone; its database ${db} may be left behind"
  [[ -z "$FL_SITE_RECOVER_WHY" ]] || fl_info "benchbar did not clean it up itself: ${FL_SITE_RECOVER_WHY}"
  fl_fix "check that no site uses ${db} (grep -l '\"${db}\"' $(printf '%q' "$bench_dir")/sites/*/site_config.json); if none does, drop it yourself: $(fl__db_by_hand "$db")   Then remove ${marker} and run this again"
  FL_SITE_RECOVER_FOREIGN=0; FL_SITE_RECOVER_DB=""
}

# fl_site_recover BENCH SITE ROOT_PASSWORD: cleans up a new-site that was cut
# short, so a rerun starts over without any work by hand. 0 cleaned up (or,
# in a dry run, would), 1 not touched, with FL_SITE_RECOVER_WHY saying why
# (and FL_SITE_RECOVER_DB naming the database the marker records).
# It drops a database only when ALL of this holds:
#  a) benchbar's own record in its state folder (outside the bench, written
#     before the marker and before new-site ran) names this database for this
#     bench and site; the marker alone is not enough,
#  b) no sites/*/site_config.json of this bench or of any bench benchbar knows
#     names it, other than a config inside the half made site folder itself,
#  c) it is still just created: no tabUser rows but Administrator and Guest, or
#     no tables at all,
#  d) the root password logs in and a person confirms (a terminal, default No),
#     or --yes was given. Without either, nothing is dropped.
# The site folder is moved to archived/sites, as bench drop-site does, never deleted.
fl_site_recover() {
  local bench_dir="$1" site_name="$2" pw="$3" marker db cfg_db site_dir dest bin hit answer rc=0 fresh=0
  FL_SITE_RECOVER_WHY=""; FL_SITE_RECOVER_FOREIGN=0; FL_SITE_RECOVER_DB=""
  marker="$(fl_site_creating_marker "$bench_dir" "$site_name")"
  [[ -f "$marker" ]] || return 1
  site_dir="${bench_dir}/sites/${site_name}"
  db="$(fl_site_marker_db "$bench_dir" "$site_name")"
  if [[ -z "$db" ]]; then
    FL_SITE_RECOVER_WHY="the marker does not name a database that benchbar made (an older benchbar wrote it), so no database is dropped"
    return 1
  fi
  FL_SITE_RECOVER_DB="$db"
  if ! fl_site_record_has "$bench_dir" "$site_name" "$db"; then
    FL_SITE_RECOVER_WHY="benchbar has no record in its state folder that it chose ${db} for ${site_name} (the marker alone is not proof: it can be copied, edited or left by an older benchbar), so no database is dropped"
    return 1
  fi
  if [[ -f "$site_dir/site_config.json" ]]; then
    cfg_db="$(sed -n 's/.*"db_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$site_dir/site_config.json" | awk 'NR==1')"
    if [[ -n "$cfg_db" && "$cfg_db" != "$db" ]]; then
      FL_SITE_RECOVER_WHY="sites/${site_name}/site_config.json names the database ${cfg_db}, not the one benchbar made (${db}); it may be a site made by hand, so nothing is dropped or moved"
      FL_SITE_RECOVER_FOREIGN=1
      return 1
    fi
  fi
  if hit="$(fl_db_named_by_other_site "$bench_dir" "$site_dir" "$db")"; then
    FL_SITE_RECOVER_WHY="${hit} names the database ${db}: another site uses it, so nothing is dropped or moved"
    FL_SITE_RECOVER_FOREIGN=1
    return 1
  fi
  dest="${bench_dir}/archived/sites/${site_name}.incomplete.$(date +%Y%m%d%H%M%S)"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_warn "A new-site for ${site_name} was cut short (started $(sed -n 1p "$marker" 2>/dev/null || printf '?'))"
    [[ ! -d "$site_dir" ]] || fl_info "dry-run: would move ${site_dir} to ${dest}"
    fl_info "dry-run: would drop the database ${db} and its user, which the cut short new-site made (benchbar's record and ${marker} name it), only if it is still just created (no users but Administrator and Guest) and you confirm or pass --yes; then remove the marker"
    return 0
  fi
  if [[ -z "$pw" ]] || ! fl_mariadb_root_verify "$pw"; then
    FL_SITE_RECOVER_WHY="the MariaDB root password does not work, so the half made database ${db} cannot be checked or dropped"
    return 1
  fi
  fl_mariadb_db_exists "$pw" "$db" || rc=$?
  if [[ "$rc" == "2" ]]; then
    FL_SITE_RECOVER_WHY="MariaDB could not be asked whether ${db} exists"
    return 1
  fi
  if [[ "$rc" == "0" ]]; then
    fl_mariadb_db_fresh "$pw" "$db" || fresh=$?
    if [[ "$fresh" == "1" ]]; then
      FL_SITE_RECOVER_WHY="the database ${db} holds data (users besides Administrator and Guest), so it is no half made one; it may be a finished site, and nothing is dropped or moved"
      FL_SITE_RECOVER_FOREIGN=1
      return 1
    elif [[ "$fresh" != "0" ]]; then
      FL_SITE_RECOVER_WHY="MariaDB could not tell whether ${db} is still just created"
      return 1
    fi
    if [[ "${FL_ASSUME_YES:-0}" != "1" ]]; then
      if fl_noninteractive || [[ ! -t 0 ]]; then
        FL_SITE_RECOVER_WHY="dropping ${db} needs your OK and nothing can ask: run this again with --yes, or drop it yourself"
        return 1
      fi
      fl_spinner_pause
      read -r -p "  Drop the half made database ${db} and its user? [y/N] " answer || answer=""
      if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        FL_SITE_RECOVER_WHY="you did not confirm dropping ${db}"
        return 1
      fi
    fi
  fi
  fl_warn "A new-site for ${site_name} was cut short (started $(sed -n 1p "$marker" 2>/dev/null || printf '?')); cleaning it up and starting over"
  if [[ "$rc" == "0" ]]; then
    # the prompt can wait for a person for a long time: ask again, right before
    # the drop, that no site took the database meanwhile and it is still fresh
    if hit="$(fl_db_named_by_other_site "$bench_dir" "$site_dir" "$db")"; then
      FL_SITE_RECOVER_WHY="${hit} names the database ${db} now: another site uses it, so nothing is dropped or moved"
      FL_SITE_RECOVER_FOREIGN=1
      return 1
    fi
    fresh=0
    fl_mariadb_db_fresh "$pw" "$db" || fresh=$?
    if [[ "$fresh" != "0" ]]; then
      FL_SITE_RECOVER_WHY="the database ${db} is no longer just created, or MariaDB could not tell, so nothing is dropped or moved"
      FL_SITE_RECOVER_FOREIGN=1
      return 1
    fi
    bin="$(fl_mariadb_client)"
    # db is _ and 16 hex digits (fl_site_marker_db): safe in SQL; the backticks are SQL's
    # shellcheck disable=SC2016
    if ! printf 'DROP DATABASE IF EXISTS `%s`;\nDROP USER IF EXISTS '"'%s'@'%%'"';\nDROP USER IF EXISTS '"'%s'@'localhost'"';\nFLUSH PRIVILEGES;\n' "$db" "$db" "$db" \
        | MYSQL_PWD="$pw" "$bin" -u root --connect-timeout=5 >>"${FL_LOG_FILE:-/dev/null}" 2>&1; then
      FL_SITE_RECOVER_WHY="dropping the database ${db} failed (log: ${FL_LOG_FILE:-none})"
      return 1
    fi
    fl_ok "dropped the database ${db} that the cut short new-site made"
  fi
  if [[ -d "$site_dir" ]]; then
    mkdir -p "${bench_dir}/archived/sites"
    mv "$site_dir" "$dest" || { FL_SITE_RECOVER_WHY="could not move ${site_dir} to ${dest}"; return 1; }
    fl_ok "moved ${site_dir} to ${dest}"
  fi
  rm -f "$marker"
  fl_site_record_remove "$bench_dir" "$site_name"
  FL_SITE_RECOVER_DB=""
  fl_changed site "$site_name" "a cut short new-site was cleaned up (folder moved to ${dest}, database ${db} dropped)"
}

# The site's database user may log in from any host (bench connects over TCP
# to 127.0.0.1): v16 names this --mariadb-user-host-login-scope and calls
# --no-mariadb-socket deprecated; v15 knows only the old flag.
fl_new_site_scope() {
  if [[ "$(fl_profile_major)" -ge 16 ]]; then printf '%s' "--mariadb-user-host-login-scope=%"; else printf '%s' "--no-mariadb-socket"; fi
}

# fl_new_site_create BENCH SITE DB_PASSWORD ADMIN_PASSWORD: bench new-site
# inside the "creating" marker (see fl_site_creating_marker). 0 done, 1 the
# marker could not be written (nothing was started), 2 new-site failed (the
# marker stays: a rerun must not take the half made site for done).
fl_new_site_create() {
  local bench_dir="$1" site_name="$2" db_password="$3" admin_password="$4" marker scope code=0 db_name="" candidate try rc db_args=()
  marker="$(fl_site_creating_marker "$bench_dir" "$site_name")"
  scope="$(fl_new_site_scope)"
  # the passwords travel on stdin (see FL_PY_FRAPPE_SECRETS), never as
  # arguments; plain shell variables (not exported), cleared right after
  if [[ "${FL_DRY_RUN:-0}" != "1" ]]; then
    # a database name benchbar chooses (frappe takes it with --db-name), checked
    # free and written to the marker before new-site starts: a run that is cut
    # short can then be cleaned up by that name, and by no other. When MariaDB
    # cannot be asked, frappe names it, and the marker has no name.
    for try in 1 2 3; do
      candidate="$(fl_new_site_db_name)"
      rc=0; fl_mariadb_db_exists "$db_password" "$candidate" || rc=$?
      [[ "$rc" == "2" ]] && break
      [[ "$rc" == "1" ]] && { db_name="$candidate"; break; }
    done
    [[ -z "$db_name" ]] || db_args=(--db-name "$db_name")
    # benchbar's own record of the name first (see fl_site_record_file): the marker
    # in the bench is not proof by itself, and nothing starts without the record
    if [[ -n "$db_name" ]] && ! fl_site_record_write "$bench_dir" "$site_name" "$db_name"; then
      fl_fail "could not write benchbar's record of the database ${db_name} in ${FL_STATE_DIR}; not starting new-site without it"
      return 1
    fi
    mkdir -p "$(dirname "$marker")" 2>/dev/null
    { date -u +%Y-%m-%dT%H:%M:%SZ; [[ -z "$db_name" ]] || printf 'db_name=%s\n' "$db_name"; } >"$marker" 2>/dev/null || { fl_fail "could not write ${marker}; not starting new-site without it"; return 1; }
  fi
  FL__DB_PW="$db_password"; FL__ADMIN_PW="$admin_password"
  fl_run_long "bench new-site ${site_name}" fl__frappe_with_secrets "$bench_dir" FL__DB_PW FL__ADMIN_PW -- \
    new-site "$site_name" --mariadb-root-password @secret0@ --admin-password @secret1@ "$scope" ${db_args[@]+"${db_args[@]}"} || code=$?
  FL__DB_PW=""; FL__ADMIN_PW=""
  [[ "$code" == "0" ]] || return 2
  rm -f "$marker"
  fl_site_record_remove "$bench_dir" "$site_name"
}

fl_new_site_if_needed() {
  local bench_dir="$1" site_name="$2" db_password="$3" admin_password="$4" code=0
  fl_section "CREATE SITE"
  fl_info "Checking site ${site_name}"
  if [[ -f "$(fl_site_creating_marker "$bench_dir" "$site_name")" ]]; then
    # a new-site that was cut short: cleaned up here when it is provably ours,
    # else a stop with the recovery when its folder is there, or one that names
    # the database when only that is left (a marker that names no database, an
    # older benchbar's, goes on as before and new-site starts again)
    if ! fl_site_recover "$bench_dir" "$site_name" "$db_password"; then
      if [[ -d "$bench_dir/sites/$site_name" ]]; then
        fl_site_incomplete "$bench_dir" "$site_name" "$FL_SITE_RECOVER_WHY" && return 1
      elif [[ -n "$FL_SITE_RECOVER_DB" ]]; then
        fl_site_orphan_stop "$bench_dir" "$site_name"
        return 1
      fi
    fi
  elif [[ -d "$bench_dir/sites/$site_name" ]]; then
    fl_ok "Site ${site_name} already exists"
    fl_state_set SITE_CREATED yes
    return 0
  fi
  fl_new_site_create "$bench_dir" "$site_name" "$db_password" "$admin_password" || code=$?
  case "$code" in
    0) ;;
    1) return 1 ;;
    *) fl_die "bench new-site failed." "Manual command: cd ${bench_dir} && bench new-site ${site_name} $(fl_new_site_scope)   (it asks for both passwords). If sites/${site_name} was left behind, move it aside first." ;;
  esac
  fl_state_set SITE_CREATED yes
  fl_changed site "$site_name" "created"
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
  installed="$(printf '%s\n' "$installed" | awk '{print $1}')"
  if fl_has_line "$installed" "$app"; then
    fl_ok "${app} already installed on ${site_name}"
  else
    fl_bench_run_long "bench install-app ${app} on ${site_name}" "$bench_dir" bench --site "$site_name" install-app "$app" \
      || fl_die "bench install-app failed for ${app}." "Manual command: cd ${bench_dir} && bench --site ${site_name} install-app ${app}"
    fl_changed app "$app" "installed on ${site_name}"
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
  if [[ "$({ tr -d '[:space:]' <"$bench_dir/sites/currentsite.txt"; } 2>/dev/null)" != "$site_name" ]]; then
    fl_bench_run "$bench_dir" bench use "$site_name"
  fi
}
