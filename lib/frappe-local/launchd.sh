#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# launchd.sh: the one launchd agent per bench, honcho resolution, and
# migration of legacy per-process agents.

FL_HONCHO=""
FL_LEGACY_DIR="${FL_LEGACY_DIR:-$HOME/Library/LaunchAgents-disabled}"

# ------------------------------------------------------------- honcho

fl_pipx_home() {
  local h
  h="$(pipx environment --value PIPX_HOME 2>/dev/null || true)"
  [[ -n "$h" ]] && { printf '%s' "$h"; return 0; }
  if [[ -d "$HOME/Library/Application Support/pipx" ]]; then
    printf '%s' "$HOME/Library/Application Support/pipx"
  else
    printf '%s' "$HOME/.local/pipx"
  fi
}

# uv installs tools here; "uv tool dir" says the same, but costs a process
fl_uv_tool_dir() { printf '%s' "${UV_TOOL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/uv/tools}"; }

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

# Resolves honcho in this order: PATH, pipx venv of frappe-bench, bench env.
# Sets FL_HONCHO (absolute path) or leaves it empty.
fl_honcho_resolve() {
  local cand stored
  FL_HONCHO=""
  stored="$(fl_bstate_get HONCHO_BIN 2>/dev/null || true)"
  for cand in \
    "$(command -v honcho 2>/dev/null || true)" \
    "$(fl_pipx_home)/venvs/frappe-bench/bin/honcho" \
    "$(fl_uv_tool_dir)/frappe-bench/bin/honcho" \
    "$HOME/.local/pipx/venvs/frappe-bench/bin/honcho" \
    "${FL_BENCH_DIR}/env/bin/honcho" \
    "$stored"; do
    [[ -n "$cand" && -x "$cand" ]] || continue
    FL_HONCHO="$cand"
    return 0
  done
  return 1
}

fl_honcho_install() {
  local py="${FL_BENCH_DIR}/env/bin/python"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would install honcho into ${FL_BENCH_DIR}/env with uv pip (or pip)"
    FL_HONCHO="${FL_BENCH_DIR}/env/bin/honcho"
    return 0
  fi
  [[ -x "$py" ]] || { fl_fail "cannot install honcho: ${py} is missing"; return 1; }
  if command -v uv >/dev/null 2>&1; then
    fl_run_long "install honcho into the bench env (uv)" uv pip install --python "$py" honcho || return 1
  else
    fl_run_long "install honcho into the bench env (pip)" "$py" -m pip install honcho || return 1
  fi
  fl_honcho_resolve
}

# ------------------------------------------------------------- agent

fl_launchd_path_value() {
  local brew="${FL_BREW_PREFIX:-/opt/homebrew}" p=""
  [[ -n "${FL_PYTHON_FORMULA:-}" ]] && p="${brew}/opt/${FL_PYTHON_FORMULA}/bin:"
  [[ -n "${FL_NODE_FORMULA:-}" ]] && p="${p}${brew}/opt/${FL_NODE_FORMULA}/bin:"
  [[ -n "${FL_MARIADB_FORMULA:-}" ]] && p="${p}${brew}/opt/${FL_MARIADB_FORMULA}/bin:"
  p="${p}${HOME}/.local/bin:${brew}/bin:${brew}/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  printf '%s' "$p"
}

fl_agent_target() {
  printf '%s/%s' "$(fl_launchd_domain)" "$(fl_agent_label)"
}

fl_agent_loaded() {
  launchctl print "$(fl_agent_target)" >/dev/null 2>&1
}

# fl_agent_field FIELD [TARGET]: reads "state", "pid" or "last exit code".
fl_agent_field() {
  local field="$1" target="${2:-$(fl_agent_target)}"
  launchctl print "$target" 2>/dev/null | awk -F' = ' -v f="$field" '
    $1 ~ "^[[:space:]]*" f "$" { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit }' || true
}

# Loads a plist and confirms launchd lists the job. Neither exit code can be
# trusted on its own: "load -w" exits 0 even when it loaded nothing, so the
# result is checked with "launchctl print". A few tries, a second apart.
fl_agent_bootstrap() {
  local plist="$1" target try
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: launchctl bootstrap $(fl_launchd_domain) ${plist}"
    return 0
  fi
  target="$(fl_launchd_domain)/$(basename "$plist" .plist)"
  for try in 1 2 3; do
    fl_log "launchctl bootstrap $(fl_launchd_domain) ${plist} (try ${try})"
    launchctl bootstrap "$(fl_launchd_domain)" "$plist" 2>/dev/null || launchctl load -w "$plist" 2>/dev/null || true
    launchctl print "$target" >/dev/null 2>&1 && return 0
    sleep 1
  done
  fl_log "launchd does not list ${target} after 3 tries"
  return 1
}

# launchctl bootout returns before a running job has stopped (the runner
# forwards SIGTERM and waits for honcho). Until launchd forgets the job, a
# bootstrap of the same label fails, so wait for that, up to
# FL_BOOTOUT_WAIT_SECS (launchd itself sends SIGKILL after 20 seconds).
FL_BOOTOUT_WAIT_SECS="${FL_BOOTOUT_WAIT_SECS:-30}"

fl_agent_wait_gone() {
  local target="$1" i=0 limit=$((FL_BOOTOUT_WAIT_SECS * 4))
  while launchctl print "$target" >/dev/null 2>&1; do
    if [[ "$i" -ge "$limit" ]]; then
      fl_warn "launchd still lists ${target} after ${FL_BOOTOUT_WAIT_SECS} s"
      return 1
    fi
    sleep 0.25
    i=$((i + 1))
  done
  [[ "$i" == "0" ]] || fl_log "${target} gone after $((i / 4)) s"
  return 0
}

fl_agent_bootout() {
  local target="${1:-$(fl_agent_target)}"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: launchctl bootout ${target}"
    return 0
  fi
  fl_log "launchctl bootout ${target}"
  launchctl bootout "$target" 2>/dev/null || launchctl remove "${target##*/}" 2>/dev/null || true
  # non zero when the job is still there: a bootstrap now would fail, or
  # find the old job and look like it worked
  fl_agent_wait_gone "$target"
}

fl_agent_kickstart() {
  local kill_flag="${1:-}"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: launchctl kickstart ${kill_flag} $(fl_agent_target)"
    return 0
  fi
  fl_log "launchctl kickstart ${kill_flag} $(fl_agent_target)"
  if [[ -n "$kill_flag" ]]; then
    launchctl kickstart "$kill_flag" "$(fl_agent_target)"
  else
    launchctl kickstart "$(fl_agent_target)"
  fi
}

fl_agent_signal() {
  local sig="${1:-SIGTERM}"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: launchctl kill ${sig} $(fl_agent_target)"
    return 0
  fi
  fl_log "launchctl kill ${sig} $(fl_agent_target)"
  launchctl kill "$sig" "$(fl_agent_target)" 2>/dev/null || true
}

# ------------------------------------------------------------- legacy agents

fl_plist_label() {
  local file="$1"
  awk '/<key>Label<\/key>/ { getline l; if (l ~ /<string>/) { sub(/.*<string>/, "", l); sub(/<\/string>.*/, "", l); print l; exit } }
       /<key>Label<\/key><string>/ { l = $0; sub(/.*<key>Label<\/key><string>/, "", l); sub(/<\/string>.*/, "", l); print l; exit }' "$file" 2>/dev/null
}

fl_plist_working_dir() {
  awk '/<key>WorkingDirectory<\/key>/ { l = $0; if (l !~ /<string>/) getline l; sub(/.*<string>/, "", l); sub(/<\/string>.*/, "", l); print l; exit }' "$1" 2>/dev/null
}

# Lists LaunchAgents to migrate for this bench. Prints "path|label|state|last-exit" lines.
#   com.frappe-mac.*   the frappe-mac 0.2.0 agent, only when its WorkingDirectory is this bench
#   anything else      older per-process Frappe setups or a hand-made agent
# com.benchbar.* agents (this bench and others) are never listed.
fl_legacy_agents_list() {
  local f label state code dir="$HOME/Library/LaunchAgents"
  [[ -d "$dir" ]] || return 0
  for f in "$dir"/*.plist; do
    [[ -f "$f" ]] || continue
    case "$(basename "$f")" in
      com.benchbar.*|sh.brew.*|homebrew.mxcl.*|com.apple.*) continue ;;
      com.frappe-mac.*)
        [[ "$(fl_plist_working_dir "$f")" == "$FL_BENCH_DIR" ]] || continue ;;
      *)
        grep -q -F "$FL_BENCH_DIR" "$f" 2>/dev/null || grep -q -i -E 'frappe|honcho|socketio\.js|bench_helper|bench-run' "$f" 2>/dev/null || continue ;;
    esac
    label="$(fl_plist_label "$f")"
    [[ -n "$label" ]] || label="$(basename "$f" .plist)"
    state="$(fl_agent_field state "$(fl_launchd_domain)/${label}")"
    code="$(fl_agent_field 'last exit code' "$(fl_launchd_domain)/${label}")"
    printf '%s|%s|%s|%s\n' "$f" "$label" "${state:-not loaded}" "${code:-none}"
  done
}

# Migrates one legacy agent: bootout, then move the plist (never delete) to
# ~/Library/LaunchAgents-disabled/<timestamp>/. Safe to re-run: a plist that
# is already gone is skipped.
fl_legacy_agent_migrate() {
  local file="$1" label="$2" dest
  dest="${FL_LEGACY_DIR}/$(fl_backup_stamp)"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would bootout ${label} and move ${file} to ${dest}/"
    return 0
  fi
  [[ -f "$file" ]] || return 0
  launchctl bootout "$(fl_launchd_domain)/${label}" 2>/dev/null || launchctl unload "$file" 2>/dev/null || true
  mkdir -p "$dest"
  mv "$file" "$dest/"
  fl_log "migrated legacy agent ${label}: ${file} -> ${dest}/"
  fl_ok "moved ${label} to ${dest}/"
}
