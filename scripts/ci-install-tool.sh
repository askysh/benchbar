#!/usr/bin/env bash
#
# ci-install-tool.sh: install one build tool of the CI and release jobs at a
# pinned version, after its download matches a pinned sha256. Nothing here
# follows "latest": a new version is a change to this file, in a pull request.
#
#   scripts/ci-install-tool.sh TOOL      shellcheck, xcodegen, actionlint or zizmor
#   scripts/ci-install-tool.sh --list    one line per tool: name, version
#
# The tool goes to $RUNNER_TEMP/tools/NAME-VERSION (or /tmp when RUNNER_TEMP
# is unset) and its folder is added to $GITHUB_PATH, or printed when that is
# unset. The sha256 of each archive was taken from the vendor's checksum file
# where one exists (actionlint) and otherwise from the digest GitHub shows on
# the release asset, and was checked again against the downloaded file.
# maintainers/DECISIONS.md, "Supply chain", says why these four are here and what
# stays outside (setup-go, setup-dotnet, setup-bun, apk, brew and apt).

set -euo pipefail

SHELLCHECK_VERSION=0.11.0
XCODEGEN_VERSION=2.47.0
ACTIONLINT_VERSION=1.7.12
ZIZMOR_VERSION=1.32.0

die() { printf 'ci-install-tool: %s\n' "$1" >&2; exit 1; }

case "${1:-}" in
  --list)
    printf 'shellcheck %s\nxcodegen %s\nactionlint %s\nzizmor %s\n' \
      "$SHELLCHECK_VERSION" "$XCODEGEN_VERSION" "$ACTIONLINT_VERSION" "$ZIZMOR_VERSION"
    exit 0 ;;
  shellcheck | xcodegen | actionlint | zizmor) tool="$1" ;;
  *) die "usage: ci-install-tool.sh shellcheck|xcodegen|actionlint|zizmor|--list" ;;
esac

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) plat=linux-x86_64 ;;
  Linux-aarch64 | Linux-arm64) plat=linux-aarch64 ;;
  Darwin-arm64) plat=darwin-aarch64 ;;
  Darwin-x86_64) plat=darwin-x86_64 ;;
  *) die "no pinned $tool for $(uname -s) $(uname -m)" ;;
esac

# pin_for: sets VERSION, URL, SUM, EXT and BIN (the executable inside the
# archive) for $tool on $plat. One line per archive, so a change to a pin is
# one line in a diff.
pin_for() {
  local base
  case "$tool" in
    shellcheck)
      VERSION="$SHELLCHECK_VERSION"; EXT=tar.xz; BIN="shellcheck-v${VERSION}/shellcheck"
      base="https://github.com/koalaman/shellcheck/releases/download/v${VERSION}/shellcheck-v${VERSION}"
      case "$plat" in
        linux-x86_64) URL="${base}.linux.x86_64.tar.xz"; SUM=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 ;;
        linux-aarch64) URL="${base}.linux.aarch64.tar.xz"; SUM=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588 ;;
        darwin-aarch64) URL="${base}.darwin.aarch64.tar.xz"; SUM=56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79 ;;
        darwin-x86_64) URL="${base}.darwin.x86_64.tar.xz"; SUM=3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6 ;;
      esac ;;
    xcodegen)
      # one universal build; the folder keeps bin/ and share/ together because
      # the executable finds its setting presets relative to itself
      VERSION="$XCODEGEN_VERSION"; EXT=zip; BIN="xcodegen/bin/xcodegen"
      URL="https://github.com/yonaskolb/XcodeGen/releases/download/${VERSION}/xcodegen.zip"
      SUM=6ef12a3ef5327c2c713397f46d9160550f8b1cdc5c925cd884d65c77c9f696cd
      case "$plat" in darwin-*) ;; *) die "xcodegen is pinned for macOS only" ;; esac ;;
    actionlint)
      VERSION="$ACTIONLINT_VERSION"; EXT=tar.gz; BIN="actionlint"
      base="https://github.com/rhysd/actionlint/releases/download/v${VERSION}/actionlint_${VERSION}"
      case "$plat" in
        linux-x86_64) URL="${base}_linux_amd64.tar.gz"; SUM=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8 ;;
        linux-aarch64) URL="${base}_linux_arm64.tar.gz"; SUM=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6 ;;
        darwin-aarch64) URL="${base}_darwin_arm64.tar.gz"; SUM=aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f ;;
        darwin-x86_64) URL="${base}_darwin_amd64.tar.gz"; SUM=5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644 ;;
      esac ;;
    zizmor)
      VERSION="$ZIZMOR_VERSION"; EXT=tar.gz; BIN="zizmor"
      base="https://github.com/zizmorcore/zizmor/releases/download/v${VERSION}/zizmor"
      case "$plat" in
        linux-x86_64) URL="${base}-x86_64-unknown-linux-gnu.tar.gz"; SUM=bb110cc765eca9cd7efb2e284a956be5974c60027b0970f16397d86208a9957b ;;
        linux-aarch64) URL="${base}-aarch64-unknown-linux-gnu.tar.gz"; SUM=cb152b207f815116d7fa1c1ee4614f61578803351395052908095e79adfd9fd0 ;;
        darwin-aarch64) URL="${base}-aarch64-apple-darwin.tar.gz"; SUM=6efed18c4539a663fd3c851a2be9533fd8456c4e646d9416206da059154a0d3c ;;
        darwin-x86_64) URL="${base}-x86_64-apple-darwin.tar.gz"; SUM=6983143c719ada6845a69cc4dd2bacc215f971662fecd8bbd2678388e5ce5969 ;;
      esac ;;
  esac
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}

pin_for
dest="${RUNNER_TEMP:-/tmp}/tools/${tool}-${VERSION}"
work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/ci-tool.XXXXXX")"
trap 'rm -rf "$work"' EXIT

archive="${work}/${tool}.${EXT}"
curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$archive" "$URL" || die "download failed: $URL"
got="$(sha256_of "$archive")"
[ "$got" = "$SUM" ] || die "sha256 of $URL is $got, expected $SUM; nothing installed"

mkdir -p "$dest"
case "$EXT" in
  tar.xz) tar -xJf "$archive" -C "$dest" ;;
  tar.gz) tar -xzf "$archive" -C "$dest" ;;
  zip) unzip -q -o "$archive" -d "$dest" ;;
esac
[ -x "${dest}/${BIN}" ] || die "${dest}/${BIN} is missing after extracting $URL"

bindir="$(dirname "${dest}/${BIN}")"
if [ -n "${GITHUB_PATH:-}" ]; then
  printf '%s\n' "$bindir" >>"$GITHUB_PATH"
else
  printf '%s\n' "$bindir"
fi
printf '%s %s installed in %s (sha256 checked)\n' "$tool" "$VERSION" "$bindir" >&2
