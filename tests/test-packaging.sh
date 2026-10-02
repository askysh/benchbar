#!/usr/bin/env bash
# The Homebrew packaging: scripts/cli-tarball.sh makes the same bytes twice,
# holds only what the CLI runs and refuses a version FL_VERSION does not
# say; the tarball unpacked the way the formula installs it (libexec, and
# bin/benchbar as write_exec_script writes it) runs as a homebrew install;
# scripts/homebrew-render.sh fills in the url and the sha256 of the files,
# and writes the cask only with a DMG.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# the real git and gzip, not the mocks
REAL_PATH="${PATH#"$ROOT/tests/mocks/bin:"}"
TARBALL_SH="$ROOT/scripts/cli-tarball.sh"
RENDER_SH="$ROOT/scripts/homebrew-render.sh"
sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

if PATH="$REAL_PATH" git -C "$ROOT" rev-parse --verify -q HEAD >/dev/null 2>&1; then
  # ---- the tarball: the same bytes from the same commit, only the CLI's files
  PATH="$REAL_PATH" bash "$TARBALL_SH" "$VER" "$TMP_DIR/a" >/dev/null
  PATH="$REAL_PATH" bash "$TARBALL_SH" "$VER" "$TMP_DIR/b" >/dev/null
  TARBALL="$TMP_DIR/a/benchbar-cli-${VER}.tar.gz"
  assert_file "$TARBALL"
  assert_eq "$(sha_of "$TARBALL")" "$(sha_of "$TMP_DIR/b/benchbar-cli-${VER}.tar.gz")" "(two runs, one sha256)"
  LIST="$(tar tzf "$TARBALL")"
  for f in benchbar frappe-mac 00-mac-system-deps.sh 01-install-bench-and-site.sh 02-background-service.sh \
    lib/frappe-local/install-kind.sh lib/frappe-local/mcp.py templates/shell-helpers.tmpl config/apps.tsv LICENSE README.md; do
    assert_contains "$LIST" "benchbar-${VER}/${f}"
  done
  for f in tests/ macos/ docs/ site/ install.sh scripts/ packaging/; do
    assert_not_contains "$LIST" "benchbar-${VER}/${f}"
  done

  set +e; OUT="$(PATH="$REAL_PATH" bash "$TARBALL_SH" 9.9.9 "$TMP_DIR/c" 2>&1)"; CODE=$?; set -e
  assert_eq 1 "$CODE" "(a version FL_VERSION does not say)"
  assert_contains "$OUT" "FL_VERSION=\"${VER}\", not 9.9.9"
  assert_contains "$OUT" "fix: set FL_VERSION=\"9.9.9\" in benchbar"
  assert_no_file "$TMP_DIR/c/benchbar-cli-9.9.9.tar.gz"

  # ---- the tarball installed as the formula does it, in a fake prefix
  PREFIX="$TMP_DIR/hb"
  KEG="$PREFIX/Cellar/benchbar/$VER"
  mkdir -p "$KEG/libexec" "$KEG/bin" "$PREFIX/opt" "$PREFIX/bin"
  tar xzf "$TARBALL" -C "$KEG/libexec" --strip-components 1
  ln -s "../Cellar/benchbar/$VER" "$PREFIX/opt/benchbar"
  printf '#!/bin/bash\nexec "%s" "$@"\n' "$PREFIX/opt/benchbar/libexec/benchbar" >"$KEG/bin/benchbar"
  chmod +x "$KEG/bin/benchbar"
  ln -s "../Cellar/benchbar/$VER/bin/benchbar" "$PREFIX/bin/benchbar"
  assert_contains "$("$PREFIX/bin/benchbar" --version)" "benchbar ${VER}"
  WHERE="$("$PREFIX/bin/benchbar" where --json)"
  assert_contains "$WHERE" '"install":"homebrew"'
  assert_contains "$WHERE" "\"self\":\"$PREFIX/opt/benchbar/bin/benchbar\""
  assert_not_contains "$WHERE" "/Cellar/"
else
  printf 'test-packaging: not a git checkout, tarball checks skipped\n'
  TARBALL="$TMP_DIR/a/benchbar-cli-${VER}.tar.gz"
  mkdir -p "$TMP_DIR/a"; printf 'stand in\n' >"$TARBALL"
fi

# ---- the formula alone, with the release url
bash "$RENDER_SH" --version "$VER" --cli "$TARBALL" "$TMP_DIR/tap1" >/dev/null
FORMULA="$(cat "$TMP_DIR/tap1/Formula/benchbar.rb")"
assert_contains "$FORMULA" "url \"https://github.com/askysh/benchbar/releases/download/v${VER}/benchbar-cli-${VER}.tar.gz\""
assert_contains "$FORMULA" "sha256 \"$(sha_of "$TARBALL")\""
assert_contains "$FORMULA" 'bin.write_exec_script opt_libexec/"benchbar"'
assert_not_contains "$FORMULA" "{{"
assert_no_file "$TMP_DIR/tap1/Casks" "(no DMG, no cask)"

# ---- with a DMG and a local url
printf 'a disk image\n' >"$TMP_DIR/BenchBar.dmg"
bash "$RENDER_SH" --version "$VER" --cli "$TARBALL" --dmg "$TMP_DIR/BenchBar.dmg" \
  --url "file://$TARBALL" "$TMP_DIR/tap2" >/dev/null
assert_contains "$(cat "$TMP_DIR/tap2/Formula/benchbar.rb")" "url \"file://$TARBALL\""
CASK="$(cat "$TMP_DIR/tap2/Casks/benchbar-app.rb")"
assert_contains "$CASK" 'cask "benchbar-app" do'
assert_contains "$CASK" "version \"${VER}\""
assert_contains "$CASK" "sha256 \"$(sha_of "$TMP_DIR/BenchBar.dmg")\""
assert_contains "$CASK" 'depends_on formula: "askysh/tap/benchbar"'
assert_contains "$CASK" 'uninstall quit: "com.akashmishra.benchbar"'
assert_not_contains "$CASK" "git clone"
assert_not_contains "$CASK" "{{"

# ---- what it refuses
set +e; OUT="$(bash "$RENDER_SH" --version "$VER" --cli "$TARBALL" --url 'https://x/"a' "$TMP_DIR/tap3" 2>&1)"; CODE=$?; set -e
assert_eq 1 "$CODE" "(a quote in the url)"
assert_no_file "$TMP_DIR/tap3"
set +e; OUT="$(bash "$RENDER_SH" --version "$VER" --cli "$TMP_DIR/missing.tar.gz" "$TMP_DIR/tap4" 2>&1)"; CODE=$?; set -e
assert_eq 1 "$CODE" "(no tarball)"
assert_contains "$OUT" "scripts/cli-tarball.sh ${VER}"
set +e; OUT="$(bash "$RENDER_SH" --version 1.0 --cli "$TARBALL" "$TMP_DIR/tap5" 2>&1)"; CODE=$?; set -e
assert_eq 1 "$CODE" "(not X.Y.Z)"

printf 'test-packaging: ok\n'
