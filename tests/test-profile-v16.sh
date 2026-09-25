#!/usr/bin/env bash
# The v16-lts profile under mocks: profile resolution, the formulae and
# build formulae, the pdf_engine branch (wkhtmltopdf plus Chromium), and
# how bench itself gets installed (uv preferred, pipx kept).
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# a machine set up for v16: python@3.14, node@24, mariadb@11.8
mkdir -p "$MOCK_BREW_PREFIX/opt/python@3.14/bin" "$MOCK_BREW_PREFIX/opt/node@24/bin" "$MOCK_BREW_PREFIX/opt/mariadb@11.8/bin"
printf '#!/usr/bin/env bash\ncase "$*" in --version) printf "Python 3.14.7\\n" ;; *) exit 0 ;; esac\n' >"$MOCK_BREW_PREFIX/opt/python@3.14/bin/python3.14"
printf '#!/usr/bin/env bash\nprintf "v24.9.0\\n"\n' >"$MOCK_BREW_PREFIX/opt/node@24/bin/node"
cp "$ROOT/tests/mocks/mariadb" "$MOCK_BREW_PREFIX/opt/mariadb@11.8/bin/mariadb"
chmod +x "$MOCK_BREW_PREFIX"/opt/*/bin/*
printf 'python@3.14\nnode@24\nmariadb@11.8\n' >>"$MOCK_STATE/installed"
printf 'python@3.14\n' >>"$MOCK_BREW_LEAVES"

BENCH="$HOME/v16-bench"
make_fake_bench "$BENCH" v16dev
cat >"$BENCH/env/bin/python" <<'PY'
#!/bin/bash
case "$*" in *version_info*) echo "3.14" ;; --version) echo "Python 3.14.7" ;; *) exit 0 ;; esac
PY
printf '127.0.0.1 v16dev\n' >>"$FL_HOSTS_FILE"
run_fm service --yes --bench-dir "$BENCH" --profile v16-lts
assert_eq "0" "$CODE" "$OUT"

# profile resolution: remembered after service, the v16 toolchain is expected
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "profile  v16-lts"
assert_contains "$OUT" "[OK] Homebrew formulae: python@3.14, node@24, mariadb@11.8, redis, pkgconf, mariadb-connector-c installed"
assert_contains "$OUT" "[OK] Bench env: env/bin/python runs (Python 3.14)"
# the MariaDB 10.11 server a v15 machine already runs is inside v16's range
assert_contains "$OUT" "[OK] MariaDB server: MariaDB 10.11"
assert_contains "$OUT" "profile v16-lts accepts 10.6 to 11.8"
grep -q 'opt/mariadb-connector-c/lib/pkgconfig' "$HOME/.zshrc" || fail "PKG_CONFIG_PATH must include mariadb-connector-c"

# pdf_engine on v16: wkhtmltopdf patched, Chromium not downloaded yet: a warning with the frappe command
assert_contains "$OUT" "[WARN] PDF engine: wkhtmltopdf: patched Qt build at"
assert_contains "$OUT" "Chromium for chrome Print Formats is not downloaded yet"
assert_contains "$OUT" "fix: cd ${BENCH} && bench setup-chrome"
assert_eq "0" "$CODE" "(a missing Chromium is a warning, not a failure)"

# Chromium where bench setup-chrome puts it
mkdir -p "$BENCH/chromium/chrome-mac"
printf '#!/bin/sh\n' >"$BENCH/chromium/chrome-mac/headless_shell"; chmod +x "$BENCH/chromium/chrome-mac/headless_shell"
run_fm doctor --bench-dir "$BENCH" --json
assert_eq "ok" "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"]=="pdf_engine"][0]["level"]')"
assert_contains "$OUT" "Chromium at ${BENCH}/chromium/chrome-mac/headless_shell"
rm -rf "$BENCH/chromium"

# chromium_path in common_site_config.json wins
mkdir -p "$TMP_DIR/chrome"; printf '#!/bin/sh\n' >"$TMP_DIR/chrome/headless_shell"; chmod +x "$TMP_DIR/chrome/headless_shell"
sed_inplace "s#\"default_site\"#\"chromium_path\": \"$TMP_DIR/chrome/headless_shell\",\n \"default_site\"#" "$BENCH/sites/common_site_config.json"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "[OK] PDF engine: wkhtmltopdf: patched Qt build at"
assert_contains "$OUT" "Chromium at ${TMP_DIR}/chrome/headless_shell"

# wkhtmltopdf missing on v16: still the repair action (it is v16's default engine)
touch "$MOCK_STATE/wkhtml_missing"
run_fm doctor --bench-dir "$BENCH" --json
assert_eq "wkhtmltopdf_install" "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"]=="pdf_engine"][0]["action"]')"
rm -f "$MOCK_STATE/wkhtml_missing"

# missing build formulae: a warning with the brew command, doctor still exits 0
grep -v -x -E 'pkgconf|mariadb-connector-c' "$MOCK_STATE/installed" >"$MOCK_STATE/installed.tmp"; mv "$MOCK_STATE/installed.tmp" "$MOCK_STATE/installed"
run_fm doctor --bench-dir "$BENCH"
assert_contains "$OUT" "missing build formulae: pkgconf mariadb-connector-c"
assert_contains "$OUT" "fix: brew install pkgconf mariadb-connector-c"
printf 'pkgconf\nmariadb-connector-c\n' >>"$MOCK_STATE/installed"

# v15 knows nothing about Chromium
BENCH15="$HOME/frappe-bench"
make_fake_bench "$BENCH15"
run_fm doctor --bench-dir "$BENCH15" --profile v15-lts
assert_contains "$OUT" "[OK] PDF engine: wkhtmltopdf: patched Qt build at"
assert_not_contains "$OUT" "Chromium"

# 00 dry-run for v16 plans the v16 formulae and the build formulae
set +e; OUT="$("$ROOT/00-mac-system-deps.sh" --dry-run --profile v16-lts 2>&1)"; CODE=$?; set -e
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "brew install python@3.14"
assert_contains "$OUT" "brew install node@24"
assert_contains "$OUT" "brew install pkgconf"
assert_contains "$OUT" "brew install mariadb-connector-c"

# bench itself: uv when it is there, pipx otherwise; doctor names the owner
NOBENCH="$TMP_DIR/nobench"; mkdir -p "$NOBENCH"
for m in "$ROOT"/tests/mocks/bin/*; do [[ "$(basename "$m")" == bench ]] || ln -s "$m" "$NOBENCH/"; done
install_bench() {
  # install_bench PATH: runs fl_install_pipx_if_needed and fl_install_bench_if_needed with that PATH
  set +e
  OUT="$(PATH="$1:/usr/bin:/bin" SCRIPT_DIR="$ROOT" bash -c '
    set -euo pipefail
    . "$SCRIPT_DIR/lib/frappe-local/ui.sh"; . "$SCRIPT_DIR/lib/frappe-local/run.sh"
    . "$SCRIPT_DIR/lib/frappe-local/state.sh"; . "$SCRIPT_DIR/lib/frappe-local/launchd.sh"
    . "$SCRIPT_DIR/lib/frappe-local/bench.sh"
    FL_DRY_RUN=0
    fl_install_pipx_if_needed; fl_install_bench_if_needed
    printf "owner=%s\n" "$(fl_bench_owner)"' 2>&1)"
  CODE=$?
  set -e
}
reset_calls
MOCK_PIPX_NO_BENCH=1 install_bench "$NOBENCH:$HOME/.local/bin"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^uv tool install frappe-bench$'
assert_calls_not_contain '^pipx install'
assert_contains "$OUT" "owner=uv"
rm -f "$HOME/.local/bin/bench"; rm "$NOBENCH/uv"
reset_calls
MOCK_PIPX_NO_BENCH=1 install_bench "$NOBENCH:$HOME/.local/bin"
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^pipx install frappe-bench$'
assert_contains "$OUT" "owner=pipx"
# uv's executable folder moved with UV_TOOL_BIN_DIR: bench is still found there
rm -f "$HOME/.local/bin/bench"; ln -s "$ROOT/tests/mocks/bin/uv" "$NOBENCH/uv"; reset_calls
export UV_TOOL_BIN_DIR="$TMP_DIR/uvbin"
MOCK_PIPX_NO_BENCH=1 install_bench "$NOBENCH"
unset UV_TOOL_BIN_DIR
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^uv tool install frappe-bench$'
assert_contains "$OUT" "owner=uv"
rm -f "$TMP_DIR/uvbin/bench"; rm "$NOBENCH/uv"
MOCK_PIPX_NO_BENCH=1 install_bench "$NOBENCH:$HOME/.local/bin" >/dev/null
# an existing pipx bench is reported, never migrated to uv
ln -s "$ROOT/tests/mocks/bin/uv" "$NOBENCH/uv"; reset_calls
install_bench "$NOBENCH:$HOME/.local/bin"
assert_calls_not_contain '^(uv tool install|pipx install)'
assert_contains "$OUT" "owner=pipx"

printf 'test-profile-v16: ok\n'
