#!/usr/bin/env bash
#
# selfupdate.sh: "benchbar self-update", BenchBar updating itself with the
# one line installer (install.sh), the same command the app's Update Now runs.
#
#   benchbar self-update            the plan, then asks, then runs the installer
#   benchbar self-update --check    this CLI and the app against the latest release
#   benchbar self-update --json     the same as JSON, never runs anything
#   benchbar self-update --dry-run  the plan and the command, runs nothing
#
# It updates BenchBar only: never a bench, never "bench update". A CLI that
# is a developer checkout (not ~/.local/share/benchbar) is left to git: only
# the app is updated (--app-only) and the git pull to run is printed.

FL_SELFUPDATE_API="${BENCHBAR_API:-https://api.github.com/repos/askysh/benchbar}"
FL_SELFUPDATE_INSTALLER="${BENCHBAR_INSTALLER_URL:-https://raw.githubusercontent.com/askysh/benchbar/main/install.sh}"
FL_SELFUPDATE_HOME="${BENCHBAR_HOME:-$HOME/.local/share/benchbar}"
FL_SELFUPDATE_TIMEOUT="${FL_SELFUPDATE_TIMEOUT:-10}"

# fl_version_lt A B: true when version A is older than B ("v0.5.8" < "0.6.0",
# 0.10 after 0.9, a prerelease before its release)
fl_version_lt() {
  local a="${1#v}" b="${2#v}" pa="" pb="" x y i
  [[ "$a" == *-* ]] && { pa="${a#*-}"; a="${a%%-*}"; }
  [[ "$b" == *-* ]] && { pb="${b#*-}"; b="${b%%-*}"; }
  local -a na nb
  IFS=. read -r -a na <<<"$a"
  IFS=. read -r -a nb <<<"$b"
  for ((i = 0; i < ${#na[@]} || i < ${#nb[@]}; i++)); do
    x="${na[i]:-0}"; y="${nb[i]:-0}"
    [[ "$x" =~ ^[0-9]+$ && "$y" =~ ^[0-9]+$ ]] || return 1
    ((10#$x < 10#$y)) && return 0
    ((10#$x > 10#$y)) && return 1
  done
  [[ -n "$pa" && -z "$pb" ]] && return 0
  [[ -n "$pa" && -n "$pb" && "$pa" < "$pb" ]] && return 0
  return 1
}

# fl_selfupdate_latest: "TAG<TAB>PAGE" of the latest GitHub release, or return 1
fl_selfupdate_latest() {
  local json tag page
  json="$(curl -fsSL --max-time "$FL_SELFUPDATE_TIMEOUT" -A "benchbar/${FL_VERSION:-0}" \
    -H 'Accept: application/vnd.github+json' "${FL_SELFUPDATE_API}/releases/latest" 2>/dev/null)" || return 1
  tag="$(printf '%s' "$json" | tr ',' '\n' | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  page="$(printf '%s' "$json" | tr ',' '\n' | sed -n 's/.*"html_url"[[:space:]]*:[[:space:]]*"\([^"]*\/releases\/tag\/[^"]*\)".*/\1/p' | head -n 1)"
  [[ -n "$tag" ]] || return 1
  printf '%s\t%s' "${tag#v}" "${page:-https://github.com/askysh/benchbar/releases/tag/${tag}}"
}

# fl_selfupdate_plan: sets SU_KIND (managed|checkout|other), SU_CLI_DIR,
# SU_APP_VERSION, SU_APP_PATH, SU_APP_DIR (BENCHBAR_APP_DIR for the
# installer, empty for its default ~/Applications), SU_APP_ONLY, SU_NOTES
# (one per line) and SU_COMMAND. The same decisions as the app's UpdatePlan.
fl_selfupdate_plan() {
  local here home info tab=$'\t' parent
  here="$(cd "$SCRIPT_DIR" && pwd -P)"
  home="$(cd "$FL_SELFUPDATE_HOME" 2>/dev/null && pwd -P || printf '%s' "$FL_SELFUPDATE_HOME")"
  SU_CLI_DIR="$here"; SU_APP_ONLY=0; SU_NOTES=""; SU_APP_DIR=""
  if [[ "$here" == "$home" ]]; then
    SU_KIND=managed
  elif [[ -e "${here}/.git" ]]; then
    SU_KIND=checkout; SU_APP_ONLY=1
    SU_NOTES="the CLI at ${here} is a git checkout: update it yourself with git -C ${here} pull"
  else
    SU_KIND=other; SU_APP_ONLY=1
    SU_NOTES="the CLI at ${here} was not installed by install.sh: update it the way you installed it"
  fi
  info="$(fl_app_bundle_info)"
  SU_APP_VERSION=""; SU_APP_PATH=""
  if [[ -n "$info" ]]; then
    SU_APP_VERSION="${info%%"$tab"*}"; SU_APP_PATH="${info#*"$tab"}"
    parent="$(dirname "$SU_APP_PATH")"
    if [[ "$parent" != "$HOME/Applications" ]]; then
      if [[ -w "$parent" ]]; then
        SU_APP_DIR="$parent"
      else
        SU_NOTES="${SU_NOTES:+${SU_NOTES}$'\n'}${parent} is not writable: the new app goes to ~/Applications, move the old one at ${SU_APP_PATH} to the Trash"
      fi
    fi
  fi
  fl_selfupdate_pin ""
  return 0
}

# fl_selfupdate_pin VERSION: SU_INSTALLER, SU_ARGS and SU_COMMAND for that
# release: its tag's install.sh with --version, so a release published
# after the prompt cannot change what is installed. Empty or odd: main.
fl_selfupdate_pin() {
  SU_INSTALLER="$FL_SELFUPDATE_INSTALLER"; SU_ARGS=(--yes)
  [[ "$SU_APP_ONLY" == "1" ]] && SU_ARGS+=(--app-only)
  if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
    [[ -z "${BENCHBAR_INSTALLER_URL:-}" ]] && SU_INSTALLER="https://raw.githubusercontent.com/askysh/benchbar/v${1}/install.sh"
    SU_ARGS+=(--version "v${1}")
  fi
  SU_COMMAND="curl -fsSL ${SU_INSTALLER} | "
  [[ -n "$SU_APP_DIR" ]] && SU_COMMAND+="BENCHBAR_APP_DIR=$(printf '%q' "$SU_APP_DIR") "
  SU_COMMAND+="bash -s -- ${SU_ARGS[*]}"
}

fl_selfupdate_json() {
  local latest="$1" page="$2" available="$3" error="$4" notes="[" line first=1
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$first" == "1" ]] || notes+=","
    notes+="$(fl_json_str "$line")"; first=0
  done <<<"$SU_NOTES"
  notes+="]"
  printf '{"schema_version":%d,"cli_version":"%s","current":"%s","app_version":%s,"app_path":%s,"latest":%s,"release_url":%s,"update_available":%s,"install":"%s","cli_dir":%s,"app_only":%s,"app_dir":%s,"command":%s,"notes":%s,"error":%s}\n' \
    "$FL_SCHEMA_VERSION" "${FL_VERSION:-0}" "${FL_VERSION:-0}" \
    "$(fl_su_json_or_null "$SU_APP_VERSION")" "$(fl_su_json_or_null "$SU_APP_PATH")" \
    "$(fl_su_json_or_null "$latest")" "$(fl_su_json_or_null "$page")" "$available" "$SU_KIND" \
    "$(fl_json_str "$SU_CLI_DIR")" "$([[ "$SU_APP_ONLY" == "1" ]] && printf true || printf false)" \
    "$(fl_su_json_or_null "$SU_APP_DIR")" "$(fl_json_str "$SU_COMMAND")" "$notes" "$(fl_su_json_or_null "$error")"
}

fl_su_json_or_null() { if [[ -n "$1" ]]; then fl_json_str "$1"; else printf 'null'; fi; }

fl_selfupdate_usage() {
  cat <<USAGE
Usage: benchbar self-update [--check] [--dry-run] [--json] [--yes]

Updates the benchbar CLI and the BenchBar app with the one line installer:
  curl -fsSL ${FL_SELFUPDATE_INSTALLER} | bash -s -- --yes
It shows the plan and asks first. It never touches a bench and never runs
bench update. A CLI that is a git checkout of your own gets --app-only and
the git pull to run.

  --check     this CLI and the app against the latest release, nothing else
  --json      the same as JSON (never runs the installer)
  --dry-run   the plan and the command, nothing runs
  --yes       do not ask
USAGE
}

# fl_cmd_self_update [--check]
fl_cmd_self_update() {
  local arg check=0 latest="" page="" got available=false error="" line tab=$'\t'
  for arg in "$@"; do
    case "$arg" in
      --check) check=1 ;;
      -h|--help|help) fl_selfupdate_usage; return 0 ;;
      *) fl_die "Unknown self-update option: ${arg}" "Usage: benchbar self-update [--check] [--dry-run] [--json] [--yes]" ;;
    esac
  done
  fl_selfupdate_plan
  if got="$(fl_selfupdate_latest)"; then
    latest="${got%%"$tab"*}"; page="${got#*"$tab"}"
    if fl_version_lt "${FL_VERSION:-0}" "$latest" || { [[ -n "$SU_APP_VERSION" ]] && fl_version_lt "$SU_APP_VERSION" "$latest"; }; then
      available=true
      fl_selfupdate_pin "$latest"
    fi
  else
    available=null
    error="could not ask GitHub for the latest release (offline, or rate limited)"
  fi

  if [[ "$OPT_JSON" == "1" ]]; then
    fl_selfupdate_json "$latest" "$page" "$available" "$error"
    if [[ -n "$error" ]]; then return 1; fi
    return 0
  fi

  printf '\n%sbenchbar self-update%s%s\n' "$FL_BOLD" "$FL_RESET" "$([[ "${FL_DRY_RUN:-0}" == "1" ]] && printf ' (dry-run)')"
  local how="installed some other way"
  [[ "$SU_KIND" == managed ]] && how="installed by install.sh"
  [[ "$SU_KIND" == checkout ]] && how="a git checkout"
  fl_info "CLI ${FL_VERSION:-0} at ${SU_CLI_DIR} (${how})"
  if [[ -n "$SU_APP_VERSION" ]]; then fl_info "BenchBar app ${SU_APP_VERSION} at ${SU_APP_PATH}"; else fl_info "BenchBar app not installed"; fi
  if [[ -n "$error" ]]; then
    fl_fail "$error"
    fl_fix "try again later, or run it yourself: ${SU_COMMAND}"
    return 1
  fi
  fl_info "latest release ${latest}: ${page}"
  if [[ "$available" != "true" ]]; then
    fl_ok "BenchBar is up to date (${latest})"
    return 0
  fi
  fl_warn "BenchBar ${latest} is available"
  while IFS= read -r line; do [[ -z "$line" ]] || fl_note "$line"; done <<<"$SU_NOTES"
  if [[ "$check" == "1" ]]; then
    fl_fix "benchbar self-update   (runs: ${SU_COMMAND})"
    return 0
  fi
  fl_info "runs: ${SU_COMMAND}"
  if [[ "$SU_APP_ONLY" == "1" ]]; then
    fl_info "it updates the app in ${SU_APP_DIR:-$HOME/Applications} (a running BenchBar is quit first); no bench is touched"
  else
    fl_info "it pulls the CLI in ${FL_SELFUPDATE_HOME} and updates the app in ${SU_APP_DIR:-$HOME/Applications}; no bench is touched"
  fi
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: nothing was run"
    return 0
  fi
  fl_confirm "Update BenchBar to ${latest} now?" || { fl_info "Cancelled. Nothing was changed. Later: benchbar self-update"; return 1; }
  [[ -n "$SU_APP_DIR" ]] && export BENCHBAR_APP_DIR="$SU_APP_DIR"
  # exec: the installer may replace this very script with git pull
  # shellcheck disable=SC2016  # $1 and $@ belong to the inner bash
  exec bash -c 'set -o pipefail; url="$1"; shift; curl -fsSL "$url" | bash -s -- "$@"' _ "$SU_INSTALLER" "${SU_ARGS[@]}"
}
