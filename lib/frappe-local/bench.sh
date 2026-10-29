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

fl_install_pipx_if_needed() {
  # uv is preferred for bench itself; pipx is only needed without it
  command -v uv >/dev/null 2>&1 && return 0
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

# fl_bench_init_if_needed DIR FRAPPE_REF PYTHON [REPAIR] [SKIP_ASSETS]: SKIP_ASSETS=1
# (a frappe commit pin) leaves the first build to the caller, which builds
# once the pinned commit is checked out, so a commit the clone does not
# reach is found before anything is built.
fl_bench_init_if_needed() {
  local bench_dir="$1" frappe_ref="$2" python_bin="$3" repair="${4:-0}" skip_assets="${5:-0}" timestamp backup init_extra=()
  [[ "$skip_assets" == "1" ]] && init_extra+=(--skip-assets)
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
      fl_die "Bench ${bench_dir} has apps or sites but its env is missing or incomplete." "This is a repair, not a reinstall. Run: ${FL_SELF} repair --bench-dir ${bench_dir}"
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
  fl_run_with_timeout "$timeout_seconds" "bench init" bench init "$bench_dir" --frappe-branch "$frappe_ref" --python "$python_bin" --no-backups --verbose ${init_extra[@]+"${init_extra[@]}"} \
    || fl_die "bench init failed." "Manual command: bench init ${bench_dir} --frappe-branch ${frappe_ref} --python ${python_bin} --no-backups --verbose${init_extra[*]:+ ${init_extra[*]}}"
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
  env GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' git -C "$dir" fetch --all --tags --quiet >>"${FL_LOG_FILE:-/dev/null}" 2>&1 || true
  fl_commit_present "$dir" "$sha" && return 0
  if [[ "$(git -C "$dir" rev-parse --is-shallow-repository 2>/dev/null || true)" == "true" ]]; then
    env GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' git -C "$dir" fetch --all --tags --unshallow --quiet >>"${FL_LOG_FILE:-/dev/null}" 2>&1 || true
  fi
  fl_commit_present "$dir" "$sha" && return 0
  # a single branch clone has not seen a commit that is on another branch: the
  # remote may hand out a commit it has by its hash (GitHub does)
  for remote in $(git -C "$dir" remote 2>/dev/null || true); do
    env GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes' git -C "$dir" fetch --quiet "$remote" "$sha" >>"${FL_LOG_FILE:-/dev/null}" 2>&1 || true
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

# fl_site_incomplete BENCH SITE: true, with the recovery printed, when a
# bench new-site for SITE was cut short (Ctrl+C, a crash): the folder is
# there, the database may be half made, site_config.json may be missing. A
# folder in sites/ is never moved by benchbar; the person does it.
fl_site_incomplete() {
  local bench_dir="$1" site_name="$2" marker
  marker="$(fl_site_creating_marker "$bench_dir" "$site_name")"
  [[ -d "$bench_dir/sites/$site_name" && -f "$marker" ]] || return 1
  fl_fail "a previous bench new-site ${site_name} did not finish (started $(cat "$marker" 2>/dev/null || printf '?')); the site folder is incomplete"
  fl_fix "mv ${bench_dir}/sites/${site_name} ~/${site_name}.incomplete   (then, if its database exists: cd ${bench_dir} && bench drop-site ${site_name} --force), then run this again; if the site works already (bench --site ${site_name} doctor), only remove ${marker}"
  return 0
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
  local bench_dir="$1" site_name="$2" db_password="$3" admin_password="$4" marker scope code=0
  marker="$(fl_site_creating_marker "$bench_dir" "$site_name")"
  scope="$(fl_new_site_scope)"
  # the passwords travel on stdin (see FL_PY_FRAPPE_SECRETS), never as
  # arguments; plain shell variables (not exported), cleared right after
  if [[ "${FL_DRY_RUN:-0}" != "1" ]]; then
    mkdir -p "$(dirname "$marker")" 2>/dev/null
    date -u +%Y-%m-%dT%H:%M:%SZ >"$marker" 2>/dev/null || { fl_fail "could not write ${marker}; not starting new-site without it"; return 1; }
  fi
  FL__DB_PW="$db_password"; FL__ADMIN_PW="$admin_password"
  fl_run_long "bench new-site ${site_name}" fl__frappe_with_secrets "$bench_dir" FL__DB_PW FL__ADMIN_PW -- \
    new-site "$site_name" --mariadb-root-password @secret0@ --admin-password @secret1@ "$scope" || code=$?
  FL__DB_PW=""; FL__ADMIN_PW=""
  [[ "$code" == "0" ]] || return 2
  rm -f "$marker"
}

fl_new_site_if_needed() {
  local bench_dir="$1" site_name="$2" db_password="$3" admin_password="$4" code=0
  fl_section "CREATE SITE"
  fl_info "Checking site ${site_name}"
  if [[ -d "$bench_dir/sites/$site_name" ]]; then
    fl_site_incomplete "$bench_dir" "$site_name" && return 1
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
  if printf '%s\n' "$installed" | awk '{print $1}' | grep -qx "$app"; then
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
