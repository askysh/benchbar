#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# wkhtmltopdf.sh: the patched Qt wkhtmltopdf that Frappe needs for PDFs.
#
# Homebrew's wkhtmltopdf crashes on real Frappe templates, so the official
# package from github.com/wkhtmltopdf/packaging is used. Its version, URL
# and sha256 are pinned in config/wkhtmltopdf.tsv. The package holds an
# Intel only binary (checked: the Mach-O is x86_64), so on Apple Silicon
# it needs Rosetta 2. Installing the package itself needs sudo once.
#
# fl_wkhtmltopdf_ensure returns 0 when the patched build is present or was
# installed, 1 when it is not there and the user skipped it (PDFs will not
# work; the bench itself is fine).

FL_WKHTML_DOWNLOAD_DIR="${FL_WKHTML_DOWNLOAD_DIR:-${FL_STATE_DIR}/downloads}"
# where the official package puts its binary
FL_WKHTML_PKG_BIN="${FL_WKHTML_PKG_BIN:-/usr/local/bin/wkhtmltopdf}"
# 1 when Rosetta 2 still has to be installed together with the package
FL_WKHTML_NEED_ROSETTA=0
# FL_SKIP_COMMAND (ui.sh) is set when the step is skipped on purpose: what to
# run by hand, for the JSON stream's "command"

fl__wkhtmltopdf_is_patched() {
  [[ -n "$1" && -x "$1" ]] || return 1
  "$1" --version 2>&1 | grep -qi 'with patched qt'
}

# The binary that counts: the package's own when it is the patched build,
# otherwise whatever PATH resolves (an unpatched Homebrew build, or nothing).
fl_wkhtmltopdf_bin() {
  if fl__wkhtmltopdf_is_patched "$FL_WKHTML_PKG_BIN"; then printf '%s' "$FL_WKHTML_PKG_BIN"; return 0; fi
  command -v wkhtmltopdf 2>/dev/null || true
}

# Prints the path of an unpatched wkhtmltopdf that PATH resolves before the
# patched package binary (Frappe would run the crashing one), or nothing.
fl_wkhtmltopdf_shadow() {
  local on_path
  fl__wkhtmltopdf_is_patched "$FL_WKHTML_PKG_BIN" || return 0
  on_path="$(command -v wkhtmltopdf 2>/dev/null || true)"
  [[ -n "$on_path" && "$on_path" != "$FL_WKHTML_PKG_BIN" ]] || return 0
  fl__wkhtmltopdf_is_patched "$on_path" && return 0
  printf '%s' "$on_path"
}

fl_wkhtmltopdf_pin() {
  # sets FL_WKHTML_VERSION, FL_WKHTML_FILE, FL_WKHTML_URL, FL_WKHTML_SHA256
  local file
  file="$(fl_config_file wkhtmltopdf.tsv)"
  [[ -f "$file" ]] || { fl_fail "missing ${file}"; return 1; }
  IFS=$'\t' read -r FL_WKHTML_VERSION FL_WKHTML_FILE FL_WKHTML_URL FL_WKHTML_SHA256 _arch _note < <(awk -F '\t' 'NR == 2' "$file")
  [[ -n "$FL_WKHTML_SHA256" ]] || { fl_fail "no sha256 pinned in ${file}"; return 1; }
}

# prints "patched", "unpatched" or "missing"
fl_wkhtmltopdf_state() {
  local bin raw
  bin="$(fl_wkhtmltopdf_bin)"
  [[ -n "$bin" ]] || { printf 'missing'; return 0; }
  raw="$("$bin" --version 2>&1 || true)"
  if printf '%s' "$raw" | grep -qi 'with patched qt'; then printf 'patched'; elif [[ -n "$raw" ]]; then printf 'unpatched'; else printf 'missing'; fi
}

fl_rosetta_installed() {
  [[ "${FL_ARCH:-$(uname -m)}" == "arm64" ]] || return 0
  arch -x86_64 /usr/bin/true >/dev/null 2>&1
}

# Offers to install Rosetta 2. Returns 0 when it is (now) present.
fl_rosetta_ensure() {
  fl_rosetta_installed && { fl_ok "Rosetta 2 is installed (needed by the Intel only wkhtmltopdf)"; return 0; }
  fl_warn "Rosetta 2 is not installed; the official wkhtmltopdf is an Intel binary and needs it"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: softwareupdate --install-rosetta --agree-to-license"
    return 0
  fi
  if ! fl_confirm "Install Rosetta 2 now? (Apple's translation layer, about 300 MB, no restart)"; then
    return 1
  fi
  # BENCHBAR_SUDO=gui: root installs it in the same script as the package,
  # behind the one password dialog (fl_wkhtmltopdf_install_gui)
  if fl_sudo_gui; then
    FL_WKHTML_NEED_ROSETTA=1
    fl_info "Rosetta 2 is installed in the same step as the package, behind one password dialog"
    return 0
  fi
  fl_run_long "softwareupdate --install-rosetta" softwareupdate --install-rosetta --agree-to-license || return 1
  fl_rosetta_installed || { fl_warn "Rosetta 2 still not detected"; return 1; }
  fl_ok "Rosetta 2 installed"
}

fl_sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

# Downloads the pinned package into the state folder and checks its sha256.
# A cached file with the right checksum is reused.
fl_wkhtmltopdf_download() {
  local dest sum
  dest="${FL_WKHTML_DOWNLOAD_DIR}/${FL_WKHTML_FILE}"
  FL_WKHTML_PKG="$dest"
  if [[ -f "$dest" ]] && [[ "$(fl_sha256_of "$dest")" == "$FL_WKHTML_SHA256" ]]; then
    fl_ok "wkhtmltopdf ${FL_WKHTML_VERSION} package already downloaded and verified"
    return 0
  fi
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: curl -fL -o ${dest} ${FL_WKHTML_URL}"
    fl_info "dry-run: verify sha256 ${FL_WKHTML_SHA256}"
    return 0
  fi
  mkdir -p "$FL_WKHTML_DOWNLOAD_DIR"
  rm -f "$dest"
  # the stream's progress lines read the size of the file being written
  FL_PROGRESS_FILE="${dest}.part" fl_run_long "download wkhtmltopdf ${FL_WKHTML_VERSION} (about 50 MB)" curl -fL --retry 3 -o "${dest}.part" "$FL_WKHTML_URL" || return 1
  sum="$(fl_sha256_of "${dest}.part")"
  if [[ "$sum" != "$FL_WKHTML_SHA256" ]]; then
    rm -f "${dest}.part"
    fl_fail "checksum mismatch for ${FL_WKHTML_FILE}: got ${sum}, pinned ${FL_WKHTML_SHA256}"
    fl_note "the download is discarded; if the upstream file changed on purpose, update config/wkhtmltopdf.tsv"
    return 1
  fi
  mv "${dest}.part" "$dest"
  fl_ok "downloaded and verified ${FL_WKHTML_FILE} (sha256 ok)"
}

# fl_wkhtmltopdf_install: sudo installer -pkg. Needs a sudo session.
#
# The download sits in a folder the user can write, so the file that was
# verified is not necessarily the file root would install (another process
# could swap it in between). Root therefore copies it into a fresh folder
# only root can write, in /tmp (sticky: nobody else can rename or replace
# that folder), hashes the copy itself, compares with the pin, installs that
# copy, and removes the folder again. "sudo rm -rf" only ever gets this
# fresh folder.
FL_WKHTML_ROOT_TMP_TEMPLATE="/tmp/benchbar-wkhtmltopdf.XXXXXX"

fl_wkhtmltopdf_install() {
  local root_dir="" root_pkg sum code=0
  if fl_sudo_gui && [[ "${FL_DRY_RUN:-0}" != "1" ]]; then fl_wkhtmltopdf_install_gui; return $?; fi
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: sudo mktemp -d ${FL_WKHTML_ROOT_TMP_TEMPLATE}"
    fl_info "dry-run: sudo install -m 0644 -o root ${FL_WKHTML_PKG} <that folder>/${FL_WKHTML_FILE}"
    fl_info "dry-run: sudo shasum -a 256 <that folder>/${FL_WKHTML_FILE}   (must be ${FL_WKHTML_SHA256})"
    fl_info "dry-run: sudo installer -pkg <that folder>/${FL_WKHTML_FILE} -target /"
    fl_info "dry-run: sudo rm -rf <that folder>"
    return 0
  fi
  root_dir="$(sudo mktemp -d "$FL_WKHTML_ROOT_TMP_TEMPLATE" 2>/dev/null || true)"
  case "$root_dir" in
    /tmp/benchbar-wkhtmltopdf.*) ;;
    *) fl_fail "could not create a root owned folder for the package (sudo mktemp -d ${FL_WKHTML_ROOT_TMP_TEMPLATE})"; return 1 ;;
  esac
  root_pkg="${root_dir}/${FL_WKHTML_FILE}"
  fl_log "run: sudo install -m 0644 -o root ${FL_WKHTML_PKG} ${root_pkg}"
  if ! sudo install -m 0644 -o root "$FL_WKHTML_PKG" "$root_pkg"; then
    fl_fail "could not copy ${FL_WKHTML_FILE} into ${root_dir}"
    code=1
  else
    # the hash of the copy root will install, taken by root
    sum="$(sudo shasum -a 256 "$root_pkg" 2>/dev/null | awk '{print $1}')"
    if [[ "$sum" != "$FL_WKHTML_SHA256" ]]; then
      fl_fail "checksum mismatch on the root owned copy of ${FL_WKHTML_FILE}: got ${sum:-nothing}, pinned ${FL_WKHTML_SHA256}"
      fl_note "nothing was installed; the download in ${FL_WKHTML_DOWNLOAD_DIR} is discarded"
      rm -f "$FL_WKHTML_PKG"
      code=1
    else
      fl_ok "root owned copy verified (sha256 ok)"
      fl_run_long "installer -pkg ${FL_WKHTML_FILE}" sudo installer -pkg "$root_pkg" -target / || code=1
    fi
  fi
  fl_log "run: sudo rm -rf ${root_dir}"
  sudo rm -rf "$root_dir" 2>/dev/null || fl_warn "could not remove ${root_dir}; run: sudo rm -rf ${root_dir}"
  [[ "$code" == "0" ]] || return 1
  hash -r 2>/dev/null || true
  case "$(fl_wkhtmltopdf_state)" in
    patched) fl_ok "$("$(fl_wkhtmltopdf_bin)" --version 2>&1 | head -n1) at $(fl_wkhtmltopdf_bin)"; fl_wkhtmltopdf_shadow_warn ;;
    *) fl_fail "the package installed but 'wkhtmltopdf --version' does not say 'with patched qt'"; return 1 ;;
  esac
}

# BENCHBAR_SUDO=gui: the same steps as fl_wkhtmltopdf_install, as one root
# script behind one password dialog (fl_root_run). Root makes a fresh folder
# in /tmp that only it can write, copies the package in, hashes the copy
# against the pin, installs the copy and removes the folder; Rosetta 2, when
# it is missing, is installed first in the same script. Returns 0, 1 failed,
# 2 the dialog was cancelled (skipped).
FL_WKHTML_GUI_REASON="Install the patched wkhtmltopdf package"
fl_wkhtmltopdf_root_script() {
  cat <<'ROOT'
set -eu
pkg="$1" file="$2" sha="$3" rosetta="$4"
if [ "$rosetta" = 1 ]; then
  /usr/sbin/softwareupdate --install-rosetta --agree-to-license || { echo "softwareupdate --install-rosetta failed" >&2; exit 20; }
fi
dir="$(/usr/bin/mktemp -d /tmp/benchbar-wkhtmltopdf.XXXXXX)" || exit 21
case "$dir" in /tmp/benchbar-wkhtmltopdf.*) ;; *) echo "could not create a root owned folder for the package" >&2; exit 21 ;; esac
trap '/bin/rm -rf "$dir"' EXIT
/usr/bin/install -m 0644 "$pkg" "$dir/$file" || { echo "could not copy $file into $dir" >&2; exit 22; }
sum="$(/usr/bin/shasum -a 256 "$dir/$file" | /usr/bin/awk '{print $1}')"
if [ "$sum" != "$sha" ]; then
  echo "checksum mismatch on the root owned copy of $file: got ${sum:-nothing}, pinned $sha" >&2
  exit 23
fi
/usr/sbin/installer -pkg "$dir/$file" -target / || { echo "installer -pkg $file failed" >&2; exit 24; }
ROOT
}

# the commands a person runs by hand when the dialog was cancelled
fl_wkhtmltopdf_manual_command() {
  local cmd="sudo installer -pkg $(fl_sq "$FL_WKHTML_PKG") -target /"
  [[ "$FL_WKHTML_NEED_ROSETTA" != "1" ]] || cmd="softwareupdate --install-rosetta --agree-to-license && ${cmd}"
  printf '%s' "$cmd"
}

fl_wkhtmltopdf_install_gui() {
  local code=0 last
  if fl_root_was_cancelled "$FL_WKHTML_GUI_REASON"; then code=2; else
    fl_root_run "$FL_WKHTML_GUI_REASON" "$(fl_wkhtmltopdf_root_script)" "$FL_WKHTML_PKG" "$FL_WKHTML_FILE" "$FL_WKHTML_SHA256" "$FL_WKHTML_NEED_ROSETTA" || code=$?
  fi
  case "$code" in
    0) ;;
    2)
      FL_SKIP_COMMAND="$(fl_wkhtmltopdf_manual_command)"
      fl_warn "the password dialog was cancelled; wkhtmltopdf was not installed. PDFs will not work until it is; everything else does."
      fl_fix "$FL_SKIP_COMMAND"
      return 2 ;;
    *)
      last="$(printf '%s\n' "$FL_ROOT_OUTPUT" | grep -v '^[[:space:]]*$' | tail -n 1)"
      fl_fail "could not install the wkhtmltopdf package${last:+: ${last}}"
      case "$FL_ROOT_OUTPUT" in
        *"checksum mismatch"*) fl_note "nothing was installed; the download in ${FL_WKHTML_DOWNLOAD_DIR} is discarded"; rm -f "$FL_WKHTML_PKG" ;;
      esac
      return 1 ;;
  esac
  [[ "$FL_WKHTML_NEED_ROSETTA" != "1" ]] || { fl_rosetta_installed && fl_ok "Rosetta 2 installed" || fl_warn "Rosetta 2 still not detected"; }
  FL_WKHTML_NEED_ROSETTA=0
  hash -r 2>/dev/null || true
  case "$(fl_wkhtmltopdf_state)" in
    patched) fl_ok "$("$(fl_wkhtmltopdf_bin)" --version 2>&1 | head -n1) at $(fl_wkhtmltopdf_bin)"; fl_wkhtmltopdf_shadow_warn ;;
    *) fl_fail "the package installed but 'wkhtmltopdf --version' does not say 'with patched qt'"; return 1 ;;
  esac
}

# Says so when an unpatched build earlier on PATH would be the one Frappe runs.
fl_wkhtmltopdf_shadow_warn() {
  local shadow
  shadow="$(fl_wkhtmltopdf_shadow)"
  [[ -n "$shadow" ]] || return 0
  fl_warn "${shadow} comes before ${FL_WKHTML_PKG_BIN} on PATH and is not the patched build: Frappe would run it"
  fl_fix "brew uninstall wkhtmltopdf   (the official package at ${FL_WKHTML_PKG_BIN} stays)"
}

# The whole flow: detect, Rosetta, download, verify, install.
#   0  patched build present (already, or installed now)
#   1  a step failed (message printed)
#   2  skipped on purpose: Rosetta or the package declined, or no sudo
# fl_wkhtmltopdf_will_install: true when fl_wkhtmltopdf_ensure would reach
# the sudo step in this run: the patched build is missing, Rosetta is there
# (or can be offered: --yes or a terminal), and the download can be agreed
# to (--yes or a terminal). Without a terminal and without --yes every
# question is "no", so nothing is installed and no sudo is needed for it.
fl_wkhtmltopdf_will_install() {
  [[ "$(fl_wkhtmltopdf_state)" != "patched" ]] || return 1
  # the download, and Rosetta before it when missing, are questions: with
  # --yes or a terminal they can be agreed to, otherwise both are "no"
  [[ "${FL_ASSUME_YES:-0}" == "1" || -t 0 ]]
}

fl_wkhtmltopdf_ensure() {
  local state
  state="$(fl_wkhtmltopdf_state)"
  if [[ "$state" == "patched" ]]; then
    fl_ok "wkhtmltopdf patched Qt build at $(fl_wkhtmltopdf_bin)"
    fl_wkhtmltopdf_shadow_warn
    return 0
  fi
  if [[ "$state" == "unpatched" ]]; then
    fl_warn "wkhtmltopdf at $(fl_wkhtmltopdf_bin) is not the patched Qt build (Homebrew's crashes on Frappe templates)"
  else
    fl_warn "wkhtmltopdf is not installed (Frappe needs it for PDF printing)"
  fi
  fl_wkhtmltopdf_pin || return 1
  if [[ "${FL_ARCH:-$(uname -m)}" == "arm64" ]] && ! fl_rosetta_ensure; then
    fl_warn "skipping wkhtmltopdf: without Rosetta 2 the Intel binary cannot run. PDFs will not work; everything else does."
    fl_fix "softwareupdate --install-rosetta --agree-to-license, then run this again"
    FL_SKIP_COMMAND="softwareupdate --install-rosetta --agree-to-license"
    return 2
  fi
  if [[ "${FL_DRY_RUN:-0}" != "1" ]] && ! fl_confirm "Download wkhtmltopdf ${FL_WKHTML_VERSION} (official patched Qt package, sha256 verified) and install it with sudo?"; then
    fl_warn "skipping wkhtmltopdf: PDFs will not work until it is installed; everything else does."
    fl_fix "${FL_SELF_DIR}/00-mac-system-deps.sh   (asks again)"
    return 2
  fi
  fl_wkhtmltopdf_download || return 1
  if [[ "${FL_DRY_RUN:-0}" != "1" ]] && ! fl_sudo_begin "install the wkhtmltopdf package (installer -pkg ${FL_WKHTML_FILE} -target /)"; then
    fl_warn "skipping wkhtmltopdf: sudo was not available"
    fl_fix "sudo installer -pkg ${FL_WKHTML_PKG} -target /"
    FL_SKIP_COMMAND="sudo installer -pkg $(fl_sq "$FL_WKHTML_PKG") -target /"
    return 2
  fi
  fl_wkhtmltopdf_install
}
