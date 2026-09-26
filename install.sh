#!/bin/bash
#
# install.sh: the one line installer for BenchBar.
#
#   curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash
#
# What it does, in this order, and says so before each step:
#   1. checks macOS, Apple Silicon (warns on Intel), the Xcode Command Line
#      Tools (offers xcode-select --install and waits) and Homebrew (offers
#      the official installer)
#   2. clones the CLI into ~/.local/share/benchbar (or pulls), links
#      benchbar and frappe-mac into ~/.local/bin, and adds that folder to
#      PATH in ~/.zshrc inside a marker block
#   3. installs or updates the BenchBar app from the latest GitHub release
#      (zip checked against the release's SHA256SUMS, unpacked with ditto
#      into ~/Applications); skipped when no release exists yet
#   4. offers "benchbar adopt" for a bench it finds, or "benchbar install"
#
# Flags:
#   --yes             accept every default, no questions (no TTY needed)
#   --dry-run         print the plan and every command, change nothing
#   --no-app          CLI only
#   --app-only        app only
#   --version vX.Y.Z  install that release of the app instead of the latest
#   --uninstall       remove the app, the links and the PATH block; offer to
#                     stop and remove the launchd agents and the checkout
#                     (with --yes: yes to both). Benches, sites and databases
#                     are never touched.
#
# It never runs sudo itself. The only step that may ask for your password
# is Homebrew's own installer, and it says so first. Works on macOS
# /bin/bash 3.2. Prompts read from /dev/tty, so it works when piped.

set -euo pipefail

BENCHBAR_REPO="${BENCHBAR_REPO:-https://github.com/askysh/benchbar.git}"
BENCHBAR_API="${BENCHBAR_API:-https://api.github.com/repos/askysh/benchbar}"
BENCHBAR_HOME="${BENCHBAR_HOME:-$HOME/.local/share/benchbar}"
BIN_DIR="${BENCHBAR_BIN_DIR:-$HOME/.local/bin}"
APP_DIR="${BENCHBAR_APP_DIR:-$HOME/Applications}"
APP="${APP_DIR}/BenchBar.app"
RC_FILE="${BENCHBAR_RC_FILE:-$HOME/.zshrc}"
RC_START="# >>> benchbar-path >>>"
RC_END="# <<< benchbar-path <<<"

YES=0; DRY=0; DO_CLI=1; DO_APP=1; UNINSTALL=0; PIN=""
CHANGED=0

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -y|--yes) YES=1 ;;
    --dry-run) DRY=1 ;;
    --no-app) DO_APP=0 ;;
    --app-only) DO_CLI=0 ;;
    --version) PIN="${2:-}"; shift ;;
    --version=*) PIN="${1#*=}" ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'Unknown option: %s (try --help)\n' "$1" >&2; exit 1 ;;
  esac
  shift
done
[[ -z "$PIN" || "$PIN" == v* ]] || PIN="v${PIN}"

# ---------------------------------------------------------------- output

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  B="$(tput bold 2>/dev/null || true)"; D="$(tput dim 2>/dev/null || true)"; R="$(tput sgr0 2>/dev/null || true)"
  GREEN="$(tput setaf 2 2>/dev/null || true)"; YELLOW="$(tput setaf 3 2>/dev/null || true)"; RED="$(tput setaf 1 2>/dev/null || true)"
else
  B=""; D=""; R=""; GREEN=""; YELLOW=""; RED=""
fi
ok()   { printf '  %s[OK]%s %s\n' "$GREEN" "$R" "$1"; }
same() { printf '  %s[OK]%s %s (unchanged)\n' "$GREEN" "$R" "$1"; }
warn() { printf '  %s[WARN]%s %s\n' "$YELLOW" "$R" "$1"; }
fail() { printf '  %s[FAIL]%s %s\n' "$RED" "$R" "$1" >&2; }
info() { printf '  %s..%s %s\n' "$D" "$R" "$1"; }
step() { printf '\n%s==> %s%s\n' "$B" "$1" "$R"; }
die()  { fail "$1"; [[ -n "${2:-}" ]] && printf '  fix: %s\n' "$2" >&2; exit 1; }

# run CMD...: prints the command in dry-run, runs it otherwise
run() {
  if [[ "$DRY" == "1" ]]; then info "dry-run: $*"; return 0; fi
  "$@"
}

has_tty() { [[ -r /dev/tty ]] && { true </dev/tty; } 2>/dev/null; }

# confirm QUESTION DEFAULT(y|n): --yes takes the default; no TTY takes the default
confirm() {
  local q="$1" def="${2:-n}" ans=""
  if [[ "$YES" == "1" ]]; then info "auto: ${q} -> ${def}"; [[ "$def" == "y" ]]; return; fi
  if ! has_tty; then info "no terminal: ${q} -> ${def}"; [[ "$def" == "y" ]]; return; fi
  if [[ "$def" == "y" ]]; then
    printf '  %s [Y/n] ' "$q" >/dev/tty; read -r ans </dev/tty || ans=""
    [[ -z "$ans" || "$ans" =~ ^[Yy] ]]
  else
    printf '  %s [y/N] ' "$q" >/dev/tty; read -r ans </dev/tty || ans=""
    [[ "$ans" =~ ^[Yy] ]]
  fi
}

# ---------------------------------------------------------------- helpers

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

app_version() {
  # the version of the installed app, or nothing
  local plist="${APP}/Contents/Info.plist"
  [[ -f "$plist" ]] || return 0
  awk '/<key>CFBundleShortVersionString<\/key>/ { l = $0; if (l !~ /<string>/) getline l; sub(/.*<string>/, "", l); sub(/<\/string>.*/, "", l); print l; exit }' "$plist"
}

quit_app() {
  pgrep -xq BenchBar 2>/dev/null || return 0
  if [[ "$DRY" == "1" ]]; then info "dry-run: would quit the running BenchBar"; return 0; fi
  info "quitting the running BenchBar"
  osascript -e 'tell application id "com.akashmishra.benchbar" to quit' >/dev/null 2>&1 || true
  local i=0
  while pgrep -xq BenchBar 2>/dev/null && [[ "$i" -lt 20 ]]; do sleep 0.5; i=$((i + 1)); done
  pgrep -xq BenchBar 2>/dev/null && { pkill -x BenchBar 2>/dev/null || true; sleep 1; }
  return 0
}

rc_block_state() {
  # missing | present
  [[ -f "$RC_FILE" ]] || { printf 'missing'; return 0; }
  if grep -q -x -F "$RC_START" "$RC_FILE" && grep -q -x -F "$RC_END" "$RC_FILE"; then printf 'present'; else printf 'missing'; fi
}

# the bin folder as written into the rc file: under the home folder it is
# spelled with $HOME so the block survives a renamed user
rc_bin_dir() {
  # shellcheck disable=SC2016  # a literal $HOME is the point
  case "$BIN_DIR" in
    "$HOME"/*) printf '$HOME/%s' "${BIN_DIR#"$HOME"/}" ;;
    *) printf '%s' "$BIN_DIR" ;;
  esac
}

rc_block_content() {
  local dir
  dir="$(rc_bin_dir)"
  printf '%s\n' "$RC_START" \
    "# Added by the BenchBar installer so that benchbar and frappe-mac are on PATH." \
    "case \":\$PATH:\" in *\":${dir}:\"*) ;; *) export PATH=\"${dir}:\$PATH\" ;; esac" \
    "$RC_END"
}

rc_block_write() {
  local want have tmp
  want="$(rc_block_content)"
  if [[ "$(rc_block_state)" == "present" ]]; then
    have="$(awk -v s="$RC_START" -v e="$RC_END" '$0 == s {p = 1} p {print} $0 == e {p = 0}' "$RC_FILE")"
    if [[ "$have" == "$want" ]]; then same "PATH block in ${RC_FILE}"; return 0; fi
    if [[ "$DRY" == "1" ]]; then info "dry-run: would refresh the PATH block in ${RC_FILE}"; return 0; fi
    tmp="$(mktemp "${TMPDIR:-/tmp}/benchbar-rc.XXXXXX")"
    awk -v s="$RC_START" -v e="$RC_END" '$0 == s {skip = 1} !skip {print} $0 == e {skip = 0}' "$RC_FILE" >"$tmp"
    { cat "$tmp"; printf '\n%s\n' "$want"; } >"$RC_FILE"
    rm -f "$tmp"
    ok "PATH block refreshed in ${RC_FILE}"
  else
    if [[ "$DRY" == "1" ]]; then info "dry-run: would append the PATH block to ${RC_FILE}"; return 0; fi
    { [[ -f "$RC_FILE" ]] && cat "$RC_FILE"; printf '\n%s\n' "$want"; } >"${RC_FILE}.benchbar.tmp"
    mv "${RC_FILE}.benchbar.tmp" "$RC_FILE"
    ok "added ${BIN_DIR} to PATH in ${RC_FILE}"
  fi
  CHANGED=1
}

rc_block_remove() {
  [[ "$(rc_block_state)" == "present" ]] || { same "no PATH block in ${RC_FILE}"; return 0; }
  if [[ "$DRY" == "1" ]]; then info "dry-run: would remove the PATH block from ${RC_FILE}"; return 0; fi
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/benchbar-rc.XXXXXX")"
  awk -v s="$RC_START" -v e="$RC_END" '$0 == s {skip = 1} !skip {print} $0 == e {skip = 0}' "$RC_FILE" >"$tmp"
  mv "$tmp" "$RC_FILE"
  ok "removed the PATH block from ${RC_FILE}"
  CHANGED=1
}

# json_field NAME: the first string value of "NAME": "..." on stdin
json_field() { sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1; }

# ---------------------------------------------------------------- checks

check_system() {
  step "System"
  [[ "$(uname -s)" == "Darwin" ]] || die "This installer is for macOS." "For Windows and WSL see github.com/askysh/frappe_wsl_dev_server"
  ok "macOS $(sw_vers -productVersion 2>/dev/null || printf '?')"
  if [[ "$(uname -m)" == "arm64" ]]; then
    ok "Apple Silicon"
  else
    warn "Intel Mac ($(uname -m)): the CLI works, the BenchBar app is built for Apple Silicon only and is skipped"
    DO_APP=0
  fi
  # the prebuilt app needs only curl, shasum and ditto: developer tools are for the CLI
  if [[ "$DO_CLI" != "1" ]]; then
    info "app only: skipping the Command Line Tools and Homebrew checks"
    return 0
  fi
  if xcode-select -p >/dev/null 2>&1; then
    ok "Xcode Command Line Tools at $(xcode-select -p)"
  elif [[ "$DRY" == "1" ]]; then
    info "dry-run: would run xcode-select --install and wait for it"
  else
    warn "Xcode Command Line Tools are missing; starting the installer (a dialog opens)"
    xcode-select --install >/dev/null 2>&1 || true
    info "waiting until the Command Line Tools are installed (finish the dialog, this continues on its own)"
    local i=0
    while ! xcode-select -p >/dev/null 2>&1; do
      sleep 5; i=$((i + 1))
      [[ "$i" -lt 360 ]] || die "gave up waiting after 30 minutes" "finish the Command Line Tools installer, then run this again"
    done
    ok "Xcode Command Line Tools installed"
  fi
  if command -v brew >/dev/null 2>&1; then
    ok "Homebrew $(brew --version 2>/dev/null | head -n 1 | awk '{print $2}') at $(brew --prefix)"
    return 0
  fi
  warn "Homebrew is not installed; benchbar needs it for Python, Node, MariaDB and Redis"
  if [[ "$DRY" == "1" ]]; then
    info "dry-run: would offer the official Homebrew installer (it asks for your password itself)"
    return 0
  fi
  if confirm "Run the official Homebrew installer now? (from brew.sh, it asks for your password)" y; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/tty
    for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
      [[ -x "$p" ]] && eval "$("$p" shellenv)"
    done
    command -v brew >/dev/null 2>&1 || die "Homebrew did not install" "see https://brew.sh, then run this again"
    ok "Homebrew installed"
  else
    warn "continuing without Homebrew; install it from https://brew.sh before benchbar install"
  fi
}

# ---------------------------------------------------------------- CLI

install_cli() {
  step "Command line tool"
  command -v git >/dev/null 2>&1 || die "git not found" "install the Xcode Command Line Tools: xcode-select --install"
  if [[ -d "${BENCHBAR_HOME}/.git" ]]; then
    local before after out
    before="$(git -C "$BENCHBAR_HOME" rev-parse --short HEAD 2>/dev/null || true)"
    if [[ "$DRY" == "1" ]]; then
      info "dry-run: git -C ${BENCHBAR_HOME} pull --ff-only"
    else
      out="$(git -C "$BENCHBAR_HOME" pull --ff-only 2>&1)" || { printf '%s\n' "$out"; die "git pull failed in ${BENCHBAR_HOME}" "fix the checkout (uncommitted changes?) or move it aside"; }
      after="$(git -C "$BENCHBAR_HOME" rev-parse --short HEAD 2>/dev/null || true)"
      if [[ "$before" == "$after" ]]; then same "CLI at ${BENCHBAR_HOME} (${after})"; else ok "CLI updated ${before} to ${after} in ${BENCHBAR_HOME}"; CHANGED=1; fi
    fi
  elif [[ -e "$BENCHBAR_HOME" ]]; then
    die "${BENCHBAR_HOME} exists but is not a git checkout" "move it aside and run this again"
  else
    run mkdir -p "$(dirname "$BENCHBAR_HOME")"
    run git clone --quiet "$BENCHBAR_REPO" "$BENCHBAR_HOME"
    [[ "$DRY" == "1" ]] || ok "CLI cloned into ${BENCHBAR_HOME}"
    CHANGED=1
  fi

  local name link target="${BENCHBAR_HOME}/benchbar"
  for name in benchbar frappe-mac; do
    link="${BIN_DIR}/${name}"
    if [[ -L "$link" && "$(readlink "$link")" == "$target" ]]; then
      same "${link}"
    elif [[ -e "$link" && ! -L "$link" ]]; then
      warn "${link} is a regular file, not touching it; move it aside to get the link"
    else
      run mkdir -p "$BIN_DIR"
      run ln -sfn "$target" "$link"
      [[ "$DRY" == "1" ]] || ok "linked ${link}"
      CHANGED=1
    fi
  done
  rc_block_write
}

# ---------------------------------------------------------------- app

# release_lookup: sets REL_TAG, REL_ZIP_URL, REL_SUMS_URL from the GitHub API.
# Returns 1 when there is no (matching) release.
release_lookup() {
  local url json
  REL_TAG=""; REL_ZIP_URL=""; REL_SUMS_URL=""
  if [[ -n "$PIN" ]]; then url="${BENCHBAR_API}/releases/tags/${PIN}"; else url="${BENCHBAR_API}/releases/latest"; fi
  json="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$url" 2>/dev/null)" || return 1
  REL_TAG="$(printf '%s' "$json" | json_field tag_name)"
  REL_ZIP_URL="$(printf '%s' "$json" | tr ',' '\n' | json_field browser_download_url | grep -E 'BenchBar-.*\.zip$' || true)"
  [[ -n "$REL_ZIP_URL" ]] || REL_ZIP_URL="$(printf '%s' "$json" | tr ',' '\n' | sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*BenchBar-[^"]*\.zip\)".*/\1/p' | head -n 1)"
  REL_SUMS_URL="$(printf '%s' "$json" | tr ',' '\n' | sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*SHA256SUMS\)".*/\1/p' | head -n 1)"
  [[ -n "$REL_TAG" && -n "$REL_ZIP_URL" ]]
}

install_app() {
  step "BenchBar app"
  local have want tmp zipname expected actual
  have="$(app_version)"
  if ! release_lookup; then
    if [[ -n "$PIN" ]]; then
      warn "no release ${PIN} on GitHub; the app is skipped"
    else
      warn "no BenchBar release on GitHub yet; the app is skipped (the CLI works without it)"
      info "build it yourself with scripts/macos-build.sh in ${BENCHBAR_HOME}, or wait for the first release"
    fi
    return 0
  fi
  want="${REL_TAG#v}"
  if [[ -n "$have" && "$have" == "$want" ]]; then
    same "BenchBar ${have} in ${APP_DIR}"
    return 0
  fi
  if [[ -n "$have" ]]; then info "BenchBar ${have} installed, release ${want} available"; else info "release ${want} available, app not installed yet"; fi
  if [[ "$DRY" == "1" ]]; then
    info "dry-run: would download ${REL_ZIP_URL}"
    info "dry-run: would check it against ${REL_SUMS_URL:-<no SHA256SUMS in the release>}"
    info "dry-run: would quit a running BenchBar and unpack the zip into ${APP_DIR} with ditto"
    return 0
  fi
  [[ -n "$REL_SUMS_URL" ]] || die "release ${REL_TAG} has no SHA256SUMS; refusing to install an unchecked app" "download the dmg by hand from github.com/askysh/benchbar/releases"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/benchbar-app.XXXXXX")"
  zipname="$(basename "$REL_ZIP_URL")"
  info "downloading ${zipname}"
  curl -fsSL --retry 3 -o "${tmp}/${zipname}" "$REL_ZIP_URL" || { rm -rf "$tmp"; die "download failed: ${REL_ZIP_URL}"; }
  curl -fsSL --retry 3 -o "${tmp}/SHA256SUMS" "$REL_SUMS_URL" || { rm -rf "$tmp"; die "download failed: ${REL_SUMS_URL}"; }
  expected="$(awk -v f="$zipname" '$2 == f || $2 == "*" f || $2 == "./" f {print $1; exit}' "${tmp}/SHA256SUMS")"
  actual="$(sha256_of "${tmp}/${zipname}")"
  if [[ -z "$expected" || "$expected" != "$actual" ]]; then
    rm -rf "$tmp"
    die "checksum mismatch for ${zipname} (SHA256SUMS: ${expected:-not listed}, file: ${actual}); nothing installed" "try again later, or download the dmg by hand and check it yourself"
  fi
  ok "sha256 verified against SHA256SUMS"
  quit_app
  mkdir -p "$APP_DIR"
  rm -rf "${tmp}/unpacked"; mkdir -p "${tmp}/unpacked"
  ditto -x -k "${tmp}/${zipname}" "${tmp}/unpacked" || { rm -rf "$tmp"; die "could not unpack ${zipname}"; }
  [[ -d "${tmp}/unpacked/BenchBar.app" ]] || { rm -rf "$tmp"; die "${zipname} does not contain BenchBar.app"; }
  rm -rf "$APP"
  ditto "${tmp}/unpacked/BenchBar.app" "$APP"
  touch "$APP"  # ditto keeps the build's mtime; a fresh one makes Finder reread the icon
  rm -rf "$tmp"
  CHANGED=1
  ok "BenchBar ${want} installed in ${APP_DIR} (downloaded with curl: no Gatekeeper prompt on first open)"
  info "start it with: open ${APP}"
}

# ---------------------------------------------------------------- bench

offer_bench() {
  step "Your bench"
  local cli="${BENCHBAR_HOME}/benchbar" found=""
  [[ -x "$cli" ]] || { info "the CLI is not installed; skipping"; return 0; }
  found="$("$cli" list --json 2>/dev/null | tr ',' '\n' | sed -n 's/.*"path":"\([^"]*\)".*/\1/p' | head -n 1 || true)"
  if [[ -n "$found" ]]; then
    ok "found a bench at ${found}"
    info "benchbar adopt registers it: Procfile.lean, runner, launchd agent and the bench* helpers, nothing inside sites/ or apps/"
    if [[ "$DRY" == "1" ]]; then info "dry-run: would offer: benchbar adopt ${found}"; return 0; fi
    if confirm "Run 'benchbar adopt ${found}' now? (it shows its plan and asks again before writing)" y; then
      # adopt keeps its own plan and question; only --yes here answers it
      if has_tty; then "$cli" adopt "$found" </dev/tty || true
      elif [[ "$YES" == "1" ]]; then "$cli" adopt "$found" --yes || true
      else "$cli" adopt "$found" || true; info "no terminal to answer adopt's question; later: benchbar adopt ${found} --yes"; fi
    else
      info "later: benchbar adopt ${found}"
    fi
    return 0
  fi
  ok "no bench found under ~ or ~/dev"
  info "benchbar install sets up Homebrew packages, MariaDB, a bench and a site; it asks for two passwords"
  if [[ "$DRY" == "1" || "$YES" == "1" ]] || ! has_tty; then
    info "next: open a new terminal and run: benchbar install"
    return 0
  fi
  if confirm "Run 'benchbar install' now? (takes 15 to 30 minutes)" n; then
    "$cli" install </dev/tty || true
  else
    info "later: benchbar install"
  fi
}

# ---------------------------------------------------------------- uninstall

uninstall() {
  step "Uninstall BenchBar"
  info "removes: the app, the benchbar and frappe-mac links, the PATH block"
  info "keeps: every bench, site, database and Homebrew package"
  if [[ -d "$APP" ]]; then
    quit_app
    run rm -rf "$APP"
    [[ "$DRY" == "1" ]] || ok "removed ${APP}"
    CHANGED=1
  else
    same "no app in ${APP_DIR}"
  fi
  local name link
  for name in benchbar frappe-mac; do
    link="${BIN_DIR}/${name}"
    if [[ -L "$link" ]] && [[ "$(readlink "$link")" == "${BENCHBAR_HOME}/"* ]]; then
      run rm -f "$link"
      [[ "$DRY" == "1" ]] || ok "removed ${link}"
      CHANGED=1
    elif [[ -e "$link" ]]; then
      warn "${link} was not created by this installer; left alone"
    else
      same "no ${link}"
    fi
  done
  rc_block_remove

  step "Background agents"
  local plist wd cli="${BENCHBAR_HOME}/benchbar" any=0
  for plist in "$HOME"/Library/LaunchAgents/com.benchbar.*.plist; do
    [[ -f "$plist" ]] || continue
    any=1
    wd="$(awk '/<key>WorkingDirectory<\/key>/ { l = $0; if (l !~ /<string>/) getline l; sub(/.*<string>/, "", l); sub(/<\/string>.*/, "", l); print l; exit }' "$plist")"
    info "agent $(basename "$plist" .plist) runs the bench at ${wd:-?}"
    # --yes on --uninstall means "everything that is ours", so the answer is yes there
    if [[ "$YES" != "1" ]] && ! confirm "Stop it and remove the agent, runner and Procfile.lean? (the bench itself stays)" n; then
      info "kept; later: benchbar uninstall-service --bench-dir ${wd}"
      continue
    fi
    if [[ -x "$cli" && -n "$wd" && -d "$wd" ]]; then
      if [[ "$DRY" == "1" ]]; then info "dry-run: ${cli} uninstall-service --bench-dir ${wd} --yes"; else "$cli" uninstall-service --bench-dir "$wd" --yes || warn "uninstall-service reported a problem; see above"; fi
    else
      run launchctl bootout "gui/$(id -u)/$(basename "$plist" .plist)" 2>/dev/null || true
      run mkdir -p "$HOME/Library/LaunchAgents-disabled"
      run mv "$plist" "$HOME/Library/LaunchAgents-disabled/"
      [[ "$DRY" == "1" ]] || ok "moved $(basename "$plist") to ~/Library/LaunchAgents-disabled/"
    fi
    CHANGED=1
  done
  [[ "$any" == "1" ]] || same "no benchbar agents"

  step "Checkout"
  if [[ -d "$BENCHBAR_HOME" ]]; then
    info "${BENCHBAR_HOME} holds the CLI and its logs and backups (.benchbar/)"
    if [[ "$YES" == "1" ]] || confirm "Remove ${BENCHBAR_HOME}?" n; then
      run rm -rf "$BENCHBAR_HOME"
      [[ "$DRY" == "1" ]] || ok "removed ${BENCHBAR_HOME}"
      CHANGED=1
    else
      info "kept ${BENCHBAR_HOME}"
    fi
  else
    same "no checkout at ${BENCHBAR_HOME}"
  fi
  printf '\n'
  if [[ "$DRY" == "1" ]]; then ok "dry-run finished; nothing was removed"
  elif [[ "$CHANGED" == "1" ]]; then ok "BenchBar removed. Open a new terminal to drop the old PATH."
  else ok "nothing to remove (unchanged)"; fi
}

# ---------------------------------------------------------------- main

printf '\n%sBenchBar installer%s%s\n' "$B" "$R" "$([[ "$DRY" == "1" ]] && printf ' (dry-run: nothing is changed)')"
if [[ "$UNINSTALL" == "1" ]]; then
  uninstall
  exit 0
fi
printf '  Plan:\n'
[[ "$DO_CLI" == "1" ]] && printf '   1. check macOS, the Command Line Tools and Homebrew\n   2. clone or update the CLI in %s, link it into %s, add that folder to PATH in %s\n' "$BENCHBAR_HOME" "$BIN_DIR" "$RC_FILE"
[[ "$DO_APP" == "1" ]] && printf '   3. install or update the BenchBar app in %s from the %s GitHub release (sha256 checked)\n' "$APP_DIR" "${PIN:-latest}"
[[ "$DO_CLI" == "1" ]] && printf '   4. offer benchbar adopt for an existing bench, or benchbar install\n'
if [[ "$DO_CLI" == "1" ]]; then
  printf '  This script never runs sudo. Homebrew'"'"'s installer, if you accept it, asks for your password itself.\n'
else
  printf '  This script never runs sudo.\n'
fi

check_system
[[ "$DO_CLI" == "1" ]] && install_cli
[[ "$DO_APP" == "1" ]] && install_app
[[ "$DO_CLI" == "1" ]] && offer_bench

step "Done"
if [[ "$DRY" == "1" ]]; then
  ok "dry-run finished; nothing was changed"
elif [[ "$CHANGED" == "1" ]]; then
  ok "BenchBar is installed. Open a new terminal (or run: source ${RC_FILE}), then: benchbar --help"
else
  ok "everything was already in place (unchanged)"
fi
[[ -d "$APP" ]] && info "app: open ${APP}"
info "testing guide: ${BENCHBAR_HOME}/docs/testing.md"
