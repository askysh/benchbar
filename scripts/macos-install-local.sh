#!/usr/bin/env bash
#
# macos-install-local.sh: copy macos/build/BenchBar.app to ~/Applications
# and start it. A running copy is asked to quit first (then stopped if it
# does not). Run scripts/macos-build.sh before this.
#
# Options:
#   --no-open   install without starting the app

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/macos/build/BenchBar.app"
DEST_DIR="${BENCHBAR_INSTALL_DIR:-$HOME/Applications}"
DEST="${DEST_DIR}/BenchBar.app"
OPEN=1

for arg in "$@"; do
  case "$arg" in
    --no-open) OPEN=0 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$arg" >&2; exit 1 ;;
  esac
done

[[ -d "$SRC" ]] || { printf '[FAIL] %s is missing\n  fix: %s/scripts/macos-build.sh\n' "$SRC" "$ROOT" >&2; exit 1; }

if pgrep -xq BenchBar; then
  printf '==> quitting the running BenchBar\n'
  osascript -e 'tell application id "com.akashmishra.benchbar" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -xq BenchBar || break
    sleep 0.5
  done
  if pgrep -xq BenchBar; then
    pkill -x BenchBar || true
    sleep 1
  fi
fi

printf '==> installing to %s\n' "$DEST"
mkdir -p "$DEST_DIR"
rm -rf "$DEST"
ditto "$SRC" "$DEST"
touch "$DEST"  # ditto keeps the build's mtime; a fresh one makes Finder reread the icon

if [[ "$OPEN" == "1" ]]; then
  open "$DEST"
  printf '[OK] BenchBar is running: look for the runner in the menu bar\n'
else
  printf '[OK] installed; start it with: open %s\n' "$DEST"
fi
