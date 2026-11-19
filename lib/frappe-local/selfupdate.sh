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
# the app is updated (--app-only) and the git pull to run is printed. A CLI
# installed with Homebrew is upgraded by brew (FL_SELFUPDATE_BREW_CMD), and
# the installer never runs: the app updates itself, or comes from the cask.
# The CLI inside BenchBar.app (what Homebrew's and the installer's copy hand
# off to once the app is installed) updates with the app: Sparkle, or brew
# upgrade when the cask installed the app. Only that brew command is run
# from here; Sparkle is the app's to start.

# The addresses are fixed. BENCHBAR_API and BENCHBAR_INSTALLER_URL (the test
# seams: a mocked release, a stub installer) are read only under FL_TESTING=1,
# so an environment that a person or a script leaves set cannot point the
# update at another server.
FL_SELFUPDATE_API="https://api.github.com/repos/askysh/benchbar"
FL_SELFUPDATE_RAW="https://raw.githubusercontent.com/askysh/benchbar"
FL_SELFUPDATE_DOWNLOADS="https://github.com/askysh/benchbar/releases/download"
FL_SELFUPDATE_INSTALLER_OVERRIDE=""
if [[ "${FL_TESTING:-}" == "1" ]]; then
  FL_SELFUPDATE_API="${BENCHBAR_API:-$FL_SELFUPDATE_API}"
  FL_SELFUPDATE_INSTALLER_OVERRIDE="${BENCHBAR_INSTALLER_URL:-}"
fi
FL_SELFUPDATE_HOME="${BENCHBAR_HOME:-$HOME/.local/share/benchbar}"
FL_SELFUPDATE_TIMEOUT="${FL_SELFUPDATE_TIMEOUT:-10}"
FL_SELFUPDATE_BREW_CMD="brew upgrade askysh/tap/benchbar"
FL_SELFUPDATE_CASK_CMD="brew upgrade askysh/tap/benchbar-app"
# where a cask may have installed the app, after this Mac's own prefix (tests set it)
FL_SELFUPDATE_CASK_PREFIXES="${FL_SELFUPDATE_CASK_PREFIXES:-/opt/homebrew /usr/local}"

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
  tag="$(printf '%s' "$json" | tr ',' '\n' | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | awk 'NR==1')"
  page="$(printf '%s' "$json" | tr ',' '\n' | sed -n 's/.*"html_url"[[:space:]]*:[[:space:]]*"\([^"]*\/releases\/tag\/[^"]*\)".*/\1/p' | awk 'NR==1')"
  [[ -n "$tag" ]] || return 1
  printf '%s\t%s' "${tag#v}" "${page:-https://github.com/askysh/benchbar/releases/tag/${tag}}"
}

# fl_selfupdate_cask_prefix: the Homebrew prefix whose cask installed the
# app at SU_APP_PATH, else nothing. The cask's app is in /Applications; one
# in ~/Applications came from install.sh.
fl_selfupdate_cask_prefix() {
  local p
  [[ -n "$SU_APP_PATH" && "$SU_APP_PATH" != "$HOME/Applications/BenchBar.app" ]] || return 0
  # shellcheck disable=SC2086 # a space separated list
  for p in "${FL_SELF_PREFIX:-}" "${FL_BREW_PREFIX:-}" $FL_SELFUPDATE_CASK_PREFIXES; do
    [[ -n "$p" && -d "${p}/Caskroom/benchbar-app" ]] && { printf '%s' "$p"; return 0; }
  done
  return 0
}

# fl_selfupdate_plan: sets SU_KIND (managed|checkout|other|homebrew|app),
# SU_CLI_DIR, SU_APP_VERSION, SU_APP_PATH, SU_APP_DIR (BENCHBAR_APP_DIR for
# the installer, empty for its default ~/Applications), SU_APP_ONLY,
# SU_NOTES (one per line) and SU_COMMAND. The same decisions as the app's
# UpdatePlan.
fl_selfupdate_plan() {
  local here home info tab=$'\t' parent
  SU_APP_ONLY=0; SU_NOTES=""; SU_APP_DIR=""; SU_CASK=""
  info="$(fl_app_bundle_info)"
  SU_APP_VERSION=""; SU_APP_PATH=""
  if [[ -n "$info" ]]; then SU_APP_VERSION="${info%%"$tab"*}"; SU_APP_PATH="${info#*"$tab"}"; fi
  # the app's CLI is the app's to update: brew for the cask's app, else Sparkle
  if [[ "${FL_INSTALL_KIND:-}" == app ]]; then
    # the app this CLI is part of, not the first one found
    SU_KIND=app; SU_CLI_DIR="$SCRIPT_DIR"; SU_APP_PATH="${SCRIPT_DIR%/Contents/Resources/cli}"
    SU_APP_VERSION="$(fl_app_bundle_version_at "$SU_APP_PATH")"; SU_CASK="$(fl_selfupdate_cask_prefix)"
    if [[ -n "$SU_CASK" ]]; then
      SU_NOTES="this CLI is part of BenchBar.app, which Homebrew's cask installed: brew upgrades both (or Check for Updates in BenchBar)"
    else
      SU_NOTES="this CLI is part of BenchBar.app, which updates itself: open BenchBar and choose Check for Updates"
    fi
    fl_selfupdate_pin ""
    return 0
  fi
  # Homebrew's CLI: install-kind.sh knows it by its path (a pwd -P here
  # would be the Cellar folder, which is "other")
  if [[ "${FL_INSTALL_KIND:-}" == homebrew ]]; then
    SU_KIND=homebrew; SU_CLI_DIR="$FL_SELF_DIR"
    # the cask's app is in /Applications; one in ~/Applications came from install.sh
    if [[ -n "$SU_APP_PATH" && -d "${FL_SELF_PREFIX}/Caskroom/benchbar-app" && "$SU_APP_PATH" != "$HOME/Applications/BenchBar.app" ]]; then
      SU_NOTES="the app comes from Homebrew's cask benchbar-app and updates itself; with brew: brew upgrade askysh/tap/benchbar-app"
    elif [[ -n "$SU_APP_PATH" ]]; then
      SU_NOTES="this updates the CLI only: the app at ${SU_APP_PATH} updates itself (Check for Updates in BenchBar)"
    fi
    fl_selfupdate_pin ""
    return 0
  fi
  here="$(cd "$SCRIPT_DIR" && pwd -P)"
  home="$(cd "$FL_SELFUPDATE_HOME" 2>/dev/null && pwd -P || printf '%s' "$FL_SELFUPDATE_HOME")"
  SU_CLI_DIR="$here"
  if [[ "$here" == "$home" ]]; then
    SU_KIND=managed
  elif [[ -e "${here}/.git" ]]; then
    SU_KIND=checkout; SU_APP_ONLY=1
    SU_NOTES="the CLI at ${here} is a git checkout: update it yourself with git -C ${here} pull"
  else
    SU_KIND=other; SU_APP_ONLY=1
    SU_NOTES="the CLI at ${here} was not installed by install.sh: update it the way you installed it"
  fi
  if [[ -n "$SU_APP_PATH" ]]; then
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

# fl_selfupdate_pin VERSION: SU_INSTALLER, SU_SUMS, SU_PIN, SU_ARGS and
# SU_COMMAND for that release: its tag's install.sh with --version, checked
# against that release's SHA256SUMS before it runs, so a release published
# after the prompt cannot change what is installed and a file served from
# main (or from anywhere else) is never run. Without a version there is no
# command to run: the plan only says what self-update does. Homebrew has no
# pin: brew installs the version its tap has.
fl_selfupdate_pin() {
  SU_PIN=""; SU_INSTALLER=""; SU_SUMS=""
  if [[ "$SU_KIND" == app ]]; then
    SU_ARGS=(); SU_COMMAND=""
    [[ -z "$SU_CASK" ]] || SU_COMMAND="$FL_SELFUPDATE_CASK_CMD"
    return 0
  fi
  if [[ "$SU_KIND" == homebrew ]]; then
    SU_ARGS=(); SU_COMMAND="$FL_SELFUPDATE_BREW_CMD"
    return 0
  fi
  SU_ARGS=(--yes)
  [[ "$SU_APP_ONLY" == "1" ]] && SU_ARGS+=(--app-only)
  SU_COMMAND=""
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || return 0
  SU_PIN="$1"
  SU_INSTALLER="${FL_SELFUPDATE_RAW}/v${1}/install.sh"
  SU_SUMS="${FL_SELFUPDATE_DOWNLOADS}/v${1}/SHA256SUMS"
  [[ -z "$FL_SELFUPDATE_INSTALLER_OVERRIDE" ]] || SU_INSTALLER="$FL_SELFUPDATE_INSTALLER_OVERRIDE"
  SU_ARGS+=(--version "v${1}")
  # the same steps self-update takes, as one line to copy
  SU_COMMAND="cd \"\$(mktemp -d)\" && curl --proto '=https' --tlsv1.2 -fsSL -o install.sh ${SU_INSTALLER} && curl --proto '=https' --tlsv1.2 -fsSL ${SU_SUMS} | grep ' install.sh\$' | shasum -a 256 -c - && "
  [[ -n "$SU_APP_DIR" ]] && SU_COMMAND+="BENCHBAR_APP_DIR=$(printf '%q' "$SU_APP_DIR") "
  SU_COMMAND+="bash install.sh ${SU_ARGS[*]}"
}

# fl_selfupdate_fetch: install.sh of the pinned release in SU_TMP, after its
# sha256 matched the line for install.sh in the release's SHA256SUMS. Dies,
# with SU_TMP removed, when a download fails, the release lists no install.sh
# (a release from before the installers were listed) or the hashes differ.
fl_selfupdate_fetch() {
  local want have name
  [[ -n "$SU_PIN" && -n "$SU_INSTALLER" && -n "$SU_SUMS" ]] || fl_die "There is no release to update to." "Run: benchbar self-update --check"
  SU_TMP="$(mktemp -d "${TMPDIR:-/tmp}/benchbar-selfupdate.XXXXXX")" || fl_die "Could not create a temporary folder."
  curl --proto '=https' --tlsv1.2 -fsSL --max-time 60 -o "${SU_TMP}/install.sh" "$SU_INSTALLER" 2>/dev/null \
    || { rm -rf "$SU_TMP"; fl_die "Could not download ${SU_INSTALLER}." "Try again later."; }
  curl --proto '=https' --tlsv1.2 -fsSL --max-time 60 -o "${SU_TMP}/SHA256SUMS" "$SU_SUMS" 2>/dev/null \
    || { rm -rf "$SU_TMP"; fl_die "Could not download ${SU_SUMS}." "Try again later."; }
  want=""
  while read -r have name _; do
    case "$name" in install.sh|\*install.sh|./install.sh) want="$have"; break ;; esac
  done <"${SU_TMP}/SHA256SUMS"
  if [[ -z "$want" ]]; then
    rm -rf "$SU_TMP"
    fl_die "The SHA256SUMS of v${SU_PIN} has no line for install.sh, so the installer cannot be checked and was not run." "Update by hand: see https://github.com/askysh/benchbar/blob/main/docs/install.md#updating"
  fi
  have="$(shasum -a 256 "${SU_TMP}/install.sh" | awk '{print $1}')"
  if [[ "$have" != "$want" ]]; then
    rm -rf "$SU_TMP"
    fl_die "install.sh of v${SU_PIN} does not match the release's SHA256SUMS (file ${have}, SHA256SUMS ${want}); it was not run." "Try again later. If it repeats, report it at https://github.com/askysh/benchbar/issues"
  fi
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

Updates the benchbar CLI and the BenchBar app with the one line installer of
the release it installs: it downloads install.sh of that release's tag,
compares its sha256 with the release's SHA256SUMS, and only then runs it
(with --yes and --version). The CLI is checked out at the release's tag.
It shows the plan and asks first. It never touches a bench and never runs
bench update. A CLI that is a git checkout of your own gets --app-only and
the git pull to run. A CLI installed with Homebrew is upgraded by brew
(${FL_SELFUPDATE_BREW_CMD}), never by the installer.

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
    # under Homebrew only the CLI is this command's: the app updates itself
    if fl_version_lt "${FL_VERSION:-0}" "$latest" \
      || { [[ "$SU_KIND" != homebrew && "$SU_KIND" != app && -n "$SU_APP_VERSION" ]] && fl_version_lt "$SU_APP_VERSION" "$latest"; }; then
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
  [[ "$SU_KIND" == homebrew ]] && how="installed with Homebrew"
  [[ "$SU_KIND" == app ]] && how="part of BenchBar.app"
  fl_info "CLI ${FL_VERSION:-0} at ${SU_CLI_DIR} (${how})"
  if [[ -n "$SU_APP_VERSION" ]]; then fl_info "BenchBar app ${SU_APP_VERSION} at ${SU_APP_PATH}"; else fl_info "BenchBar app not installed"; fi
  if [[ -n "$error" ]]; then
    fl_fail "$error"
    fl_fix "try again later${SU_COMMAND:+, or run it yourself: ${SU_COMMAND}}"
    return 1
  fi
  fl_info "latest release ${latest}: ${page}"
  if [[ "$available" != "true" && "$SU_KIND" == homebrew ]]; then
    fl_ok "the benchbar CLI is up to date (${latest})"
    if [[ -n "$SU_APP_VERSION" ]] && fl_version_lt "$SU_APP_VERSION" "$latest"; then
      fl_warn "BenchBar app ${SU_APP_VERSION} is older than ${latest}"
      while IFS= read -r line; do [[ -z "$line" ]] || fl_note "$line"; done <<<"$SU_NOTES"
    fi
    return 0
  elif [[ "$available" != "true" ]]; then
    fl_ok "BenchBar is up to date (${latest})"
    return 0
  fi
  fl_warn "BenchBar ${latest} is available"
  while IFS= read -r line; do [[ -z "$line" ]] || fl_note "$line"; done <<<"$SU_NOTES"
  if [[ "$SU_KIND" == app && -z "$SU_COMMAND" ]]; then
    fl_fix "open BenchBar and choose Check for Updates (BenchBar updates itself, and this CLI with it)"
    return 0
  fi
  if [[ "$check" == "1" ]]; then
    fl_fix "benchbar self-update   (runs: ${SU_COMMAND})"
    return 0
  fi
  fl_info "runs: ${SU_COMMAND}"
  if [[ "$SU_KIND" == app ]]; then
    fl_info "Homebrew upgrades BenchBar.app and the CLI inside it (a running BenchBar is quit first); no bench is touched"
  elif [[ "$SU_KIND" == homebrew ]]; then
    fl_info "Homebrew upgrades the benchbar formula; the app and every bench stay as they are"
    fl_note "when brew says benchbar is already installed, its tap has not caught up with ${latest} yet: try again in a few minutes"
  elif [[ "$SU_APP_ONLY" == "1" ]]; then
    fl_info "it updates the app in ${SU_APP_DIR:-$HOME/Applications} (a running BenchBar is quit first); no bench is touched"
  else
    fl_info "it pulls the CLI in ${FL_SELFUPDATE_HOME} and updates the app in ${SU_APP_DIR:-$HOME/Applications}; no bench is touched"
  fi
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: nothing was run"
    return 0
  fi
  if [[ "$SU_KIND" == app ]]; then
    fl_confirm "Upgrade BenchBar to ${latest} with Homebrew now?" || { fl_info "Cancelled. Nothing was changed. Later: benchbar self-update"; return 1; }
    # exec: the upgrade replaces the app this script runs from
    local cask_brew=brew
    [[ -x "${SU_CASK}/bin/brew" ]] && cask_brew="${SU_CASK}/bin/brew"
    # exec skips the EXIT trap: the lock goes now, or brew would leave it behind
    fl_lock_release
    exec "$cask_brew" upgrade askysh/tap/benchbar-app
  fi
  if [[ "$SU_KIND" == homebrew ]]; then
    fl_confirm "Upgrade benchbar to ${latest} with Homebrew now?" || { fl_info "Cancelled. Nothing was changed. Later: benchbar self-update"; return 1; }
    # the brew of the prefix this CLI is in, else the one on PATH; exec:
    # the upgrade replaces the keg this script runs from
    local brew=brew
    [[ -x "${FL_SELF_PREFIX}/bin/brew" ]] && brew="${FL_SELF_PREFIX}/bin/brew"
    fl_lock_release
    exec "$brew" upgrade askysh/tap/benchbar
  fi
  fl_confirm "Update BenchBar to ${latest} now?" || { fl_info "Cancelled. Nothing was changed. Later: benchbar self-update"; return 1; }
  [[ -n "$SU_APP_DIR" ]] && export BENCHBAR_APP_DIR="$SU_APP_DIR"
  fl_selfupdate_fetch
  fl_ok "install.sh of v${SU_PIN} matches the release's SHA256SUMS"
  # a CLI that install.sh manages is left at the release's tag: install.sh
  # pins only the app on a Mac (and a release candidate's CLI)
  local pin_home=""
  [[ "$SU_APP_ONLY" == "1" ]] || pin_home="$FL_SELFUPDATE_HOME"
  # exec: the installer may replace this very script with git pull; the lock
  # goes first, since exec skips the EXIT trap. The inner shell runs the
  # checked file, removes it, then checks the CLI out at the tag.
  fl_lock_release
  # shellcheck disable=SC2016  # $1 and $@ belong to the inner bash
  exec bash -c 'dir="$1"; home="$2"; tag="$3"; shift 3
    bash "$dir/install.sh" "$@"; rc=$?
    rm -rf "$dir"
    [ "$rc" -eq 0 ] || exit "$rc"
    if [ -n "$home" ] && [ -e "$home/.git" ]; then
      git -C "$home" fetch --quiet --tags && git -C "$home" checkout --quiet "$tag" \
        || { echo "benchbar self-update: could not check the CLI out at $tag in $home (local changes?). The app is updated; the CLI stays as it was. fix: git -C $home checkout $tag" >&2; exit 1; }
      echo "CLI at $home is at $tag"
    fi' _ "$SU_TMP" "$pin_home" "v${SU_PIN}" "${SU_ARGS[@]}"
}

# The path helpers of `where` (lean start): they live here, not in checks.sh,
# which a lean start does not load.
# Homebrew's benchbar by a path brew upgrade keeps: the opt path, or its
# link in <prefix>/bin. Never a Cellar path, which brew cleanup deletes.
fl_cli_path_is_brew() {
  local p
  case "$1" in
    */opt/benchbar/bin/benchbar|*/opt/benchbar/bin/frappe-mac|*/opt/benchbar/libexec/benchbar|*/opt/benchbar/libexec/frappe-mac) return 0 ;;
  esac
  for p in "${FL_SELF_PREFIX:-}" "${FL_BREW_PREFIX:-}"; do
    [[ -n "$p" ]] || continue
    [[ "$1" == "${p}/bin/benchbar" || "$1" == "${p}/bin/frappe-mac" ]] && return 0
  done
  return 1
}

# fl_cli_standalone_script PATH: the benchbar script behind Homebrew's or the
# installer's CLI at PATH (as a link or the helper block names it), else
# nothing. No process.
fl_cli_standalone_script() {
  case "$1" in
    */opt/benchbar/bin/benchbar|*/opt/benchbar/bin/frappe-mac) printf '%s' "${1%/bin/*}/libexec/benchbar" ;;
    */opt/benchbar/libexec/benchbar|*/opt/benchbar/libexec/frappe-mac) printf '%s' "${1%/*}/benchbar" ;;
    "${FL_MANAGED_HOME}/benchbar"|"${FL_MANAGED_HOME}/frappe-mac") printf '%s' "${FL_MANAGED_HOME}/benchbar" ;;
    *) if fl_cli_path_is_brew "$1"; then printf '%s' "${1%/bin/*}/opt/benchbar/libexec/benchbar"; fi ;;
  esac
}

# fl_cli_version_at FILE: the version a benchbar script declares, or nothing
fl_cli_version_at() {
  local line
  [[ -r "$1" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^FL_VERSION=\"(.*)\"$ ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; return 0; fi
  done <"$1"
  return 0
}
