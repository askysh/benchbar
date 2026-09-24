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
  bin="$(command -v wkhtmltopdf 2>/dev/null || true)"
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
  fl_run_long "download wkhtmltopdf ${FL_WKHTML_VERSION} (about 50 MB)" curl -fL --retry 3 -o "${dest}.part" "$FL_WKHTML_URL" || return 1
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
fl_wkhtmltopdf_install() {
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: sudo installer -pkg ${FL_WKHTML_PKG} -target /"
    return 0
  fi
  fl_run_long "installer -pkg ${FL_WKHTML_FILE}" sudo installer -pkg "$FL_WKHTML_PKG" -target / || return 1
  hash -r 2>/dev/null || true
  case "$(fl_wkhtmltopdf_state)" in
    patched) fl_ok "$(wkhtmltopdf --version 2>&1 | head -n1) at $(command -v wkhtmltopdf)" ;;
    *) fl_fail "the package installed but 'wkhtmltopdf --version' does not say 'with patched qt'"; return 1 ;;
  esac
}

# The whole flow: detect, Rosetta, download, verify, install.
#   0  patched build present (already, or installed now)
#   1  not installed: skipped by the user, or a step failed (message printed)
fl_wkhtmltopdf_ensure() {
  local state
  state="$(fl_wkhtmltopdf_state)"
  if [[ "$state" == "patched" ]]; then
    fl_ok "wkhtmltopdf patched Qt build at $(command -v wkhtmltopdf)"
    return 0
  fi
  if [[ "$state" == "unpatched" ]]; then
    fl_warn "wkhtmltopdf at $(command -v wkhtmltopdf) is not the patched Qt build (Homebrew's crashes on Frappe templates)"
  else
    fl_warn "wkhtmltopdf is not installed (Frappe needs it for PDF printing)"
  fi
  fl_wkhtmltopdf_pin || return 1
  if [[ "${FL_ARCH:-$(uname -m)}" == "arm64" ]] && ! fl_rosetta_ensure; then
    fl_warn "skipping wkhtmltopdf: without Rosetta 2 the Intel binary cannot run. PDFs will not work; everything else does."
    fl_fix "softwareupdate --install-rosetta --agree-to-license, then run this again"
    return 1
  fi
  if [[ "${FL_DRY_RUN:-0}" != "1" ]] && ! fl_confirm "Download wkhtmltopdf ${FL_WKHTML_VERSION} (official patched Qt package, sha256 verified) and install it with sudo?"; then
    fl_warn "skipping wkhtmltopdf: PDFs will not work until it is installed; everything else does."
    fl_fix "${SCRIPT_DIR}/00-mac-system-deps.sh   (asks again)"
    return 1
  fi
  fl_wkhtmltopdf_download || return 1
  if [[ "${FL_DRY_RUN:-0}" != "1" ]] && ! fl_sudo_begin "install the wkhtmltopdf package (installer -pkg ${FL_WKHTML_FILE} -target /)"; then
    fl_warn "skipping wkhtmltopdf: sudo was not available"
    fl_fix "sudo installer -pkg ${FL_WKHTML_PKG} -target /"
    return 1
  fi
  fl_wkhtmltopdf_install
}
