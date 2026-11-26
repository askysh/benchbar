#!/usr/bin/env bash
#
# cmd-where.sh: --version (fl_print_version) and the commands where, mcp and status. They read
# the install kind (install-kind.sh decides it, this file only prints it) and hand off to the
# MCP server or to fl_cmd_status. Moved out of the entry point as they were (CORE-18, issue 151).
# Every start loads this file, a lean one too: --version, where and status are lean commands, and
# --version needs fl_print_version before the command line is read.

# benchbar --version: the first line stays "benchbar X.Y.Z" (the app and
# scripts read it); the installed app's version follows on its own line, and
# after a hand off the copy that was started and its version: the version
# above is then the app's CLI's, not the one of the benchbar the person ran.
fl_print_version() {
  local app tab=$'\t' via=""
  printf 'benchbar %s\n' "$FL_VERSION"
  app="$(fl_app_bundle_info)"
  [[ -z "$app" ]] || printf 'BenchBar app %s (%s)\n' "${app%%"$tab"*}" "${app#*"$tab"}"
  [[ -n "$FL_HANDOFF_FROM" ]] || return 0
  fl_handoff_via_v via
  printf 'via %s%s, which hands off to the CLI inside BenchBar.app\n' "$FL_HANDOFF_FROM" "${via:+ (${via})}"
  fl_handoff_newer_hint "$via"
}

# benchbar where [--json]: how this CLI was installed and where its things
# are. Read only: no bench, no lock, no log.
cmd_where() {
  local info app_version="" app_path="" tab=$'\t' how via_version="" state_real
  [[ "${#ARGS[@]}" == "0" ]] || fl_die "Unexpected argument for where: ${ARGS[0]}" "Usage: benchbar where [--json]"
  if [[ "$FL_INSTALL_KIND" == app ]]; then
    # the app this CLI is part of, not the first one found
    app_path="${SCRIPT_DIR%/Contents/Resources/cli}"; app_version="$(fl_app_bundle_version_at "$app_path")"
  else
    info="$(fl_app_bundle_info)"
    if [[ -n "$info" ]]; then app_version="${info%%"$tab"*}"; app_path="${info#*"$tab"}"; fi
  fi
  # the version of the copy that handed off: an older app's CLI runs in its place
  fl_handoff_via_v via_version
  # the folder behind the state path: the same, unless ~/.local/state/benchbar
  # is a link to the installer checkout's folder on another volume (state.sh)
  state_real="$FL_STATE_DIR"
  if [[ -d "$FL_STATE_DIR" ]]; then state_real="$(cd "$FL_STATE_DIR" 2>/dev/null && pwd -P)" || state_real="$FL_STATE_DIR"; fi
  if [[ "$OPT_JSON" == "1" ]]; then
    printf '{"schema_version":%d,"cli_version":%s,"install":%s,"self":%s,"state_dir":%s,"state_dir_real":%s,"app_version":%s,"app_path":%s,"handoff_from":%s,"handoff_from_version":%s}\n' \
      "$FL_SCHEMA_VERSION" "$(fl_json_str "$FL_VERSION")" "$(fl_json_str "$FL_INSTALL_KIND")" "$(fl_json_str "$FL_SELF")" \
      "$(fl_json_str "$FL_STATE_DIR")" "$(fl_json_str "$state_real")" "$(fl_su_json_or_null "$app_version")" "$(fl_su_json_or_null "$app_path")" \
      "$(fl_su_json_or_null "$FL_HANDOFF_FROM")" "$(fl_su_json_or_null "$via_version")"
    return 0
  fi
  case "$FL_INSTALL_KIND" in
    homebrew) how="with Homebrew (brew upgrade askysh/tap/benchbar)" ;;
    managed) how="with the one line installer (benchbar self-update)" ;;
    app) how="inside BenchBar.app (it updates with the app: Sparkle or brew upgrade)" ;;
    checkout) how="as a git checkout (git pull)" ;;
    *) how="some other way" ;;
  esac
  printf 'benchbar %s, installed %s\n' "$FL_VERSION" "$how"
  printf '  install  %s\n' "$FL_INSTALL_KIND"
  printf '  self     %s\n' "$FL_SELF"
  [[ -z "$FL_HANDOFF_FROM" ]] || printf '  via      %s%s, which hands off to this CLI\n' "$FL_HANDOFF_FROM" "${via_version:+ (${via_version})}"
  [[ -z "$(fl_handoff_newer_hint "$via_version")" ]] || printf '           %s\n' "$(fl_handoff_newer_hint "$via_version")"
  if [[ "$state_real" != "$FL_STATE_DIR" ]]; then printf '  state    %s -> %s\n' "$FL_STATE_DIR" "$state_real"; else printf '  state    %s\n' "$FL_STATE_DIR"; fi
  if [[ -n "$app_path" ]]; then printf '  app      %s (%s)\n' "$app_path" "$app_version"; else printf '  app      not installed\n'; fi
}

# cmd_mcp: the MCP server, on a Python 3.9+ that imports only the standard
# library. A python3 from PATH of 3.10 or newer comes first (3.9, the Command
# Line Tools' version, is past its end of life), then Apple's /usr/bin/python3
# when the Command Line Tools are installed (xcode-select -p; without them it
# is a stub that only offers to install them), then any python3 from PATH of
# 3.9. A GUI client (Claude Desktop) may start us with a PATH that leads to a
# pyenv shim or a project venv: each candidate is run and checked, and -I
# (isolated mode) ignores PYTHON* variables, the user site and the script
# folder, so the server sees the same Python everywhere.
# BENCHBAR_MCP_CLI: tests only, a fake CLI stands in (a timeout, a hang).
cmd_mcp() {
  local py candidates=() found="" ver minor
  if command -v python3 >/dev/null 2>&1; then candidates+=("$(command -v python3)"); fi
  if ! fl_is_linux && xcode-select -p >/dev/null 2>&1 && [[ -x /usr/bin/python3 ]]; then candidates+=(/usr/bin/python3); fi
  for minor in 10 9; do
    for py in ${candidates[@]+"${candidates[@]}"}; do
      if "$py" -I -c "import sys; sys.exit(0 if sys.version_info >= (3, ${minor}) else 1)" >/dev/null 2>&1; then
        BENCHBAR="${BENCHBAR_MCP_CLI:-$FL_SELF}" BENCHBAR_VERSION="$FL_VERSION" exec "$py" -I "${SCRIPT_DIR}/lib/frappe-local/mcp.py" ${ARGS[@]+"${ARGS[@]}"}
      fi
    done
  done
  for py in ${candidates[@]+"${candidates[@]}"}; do
    ver="$("$py" -I -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null || true)"
    found="${found:+${found}, }${py} (${ver:-not runnable})"
  done
  fl_die "python3 3.9 or newer is needed for benchbar mcp; found: ${found:-no python3}." "$(fl_is_linux && printf 'Install it: sudo apt-get install python3' || printf 'Install the Xcode Command Line Tools: xcode-select --install')"
}

cmd_status() {
  FL_CONTEXT_LIGHT=1
  fl_context_init "$OPT_BENCH_DIR" "$OPT_SITE" "$OPT_PROFILE"
  fl_cmd_status "$OPT_JSON"
}
