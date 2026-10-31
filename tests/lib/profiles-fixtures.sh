#!/usr/bin/env bash
#
# profiles-fixtures.sh: the setup shared by test-profiles, -2 and -3: the harness,
# two app remotes, and the helpers the sharing tests use.

# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
# shellcheck source=tests/lib/apps-fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/apps-fixtures.sh"

USER_DIR="$HOME/.config/benchbar/profiles"
TEAM_REPO="$TMP_DIR/team-config"
mkdir -p "$USER_DIR" "$TEAM_REPO"
make_app_remote acme_crm
make_app_remote acme_tools
PIN="$(git -C "$REMOTES/acme_tools.git" rev-parse main)"

# stdout only in OUT (the JSON), stderr in ERR
run_js() { set +e; OUT="$("$FM" "$@" 2>"$TMP_DIR/stderr")"; CODE="$?"; ERR="$(cat "$TMP_DIR/stderr")"; set -e; }
ex() { printf '%s' "$OUT" | jget - "$1"; }

# write_acme_profile: the team profile "acme" in the user folder
write_acme_profile() {
cat >"$USER_DIR/acme.toml" <<TOML
# acme's bench
schema = 1
base = "v15-lts"
description = "Acme ERP"
site = "acme.localhost"
scheduler = true

[[apps]]
name = "acme_crm"
repo = "file://${REMOTES}/acme_crm.git"
branch = "main"

[[apps]]
name = "acme_tools"
repo = "file://${REMOTES}/acme_tools.git"
branch = "version-15"
commit = "${PIN}"
TOML
}

# mock_services_up: MariaDB, Redis and wkhtmltopdf running and installed, the root password known
mock_services_up() {
  add_proc 900 "mariadbd --datadir=/x"
  add_proc 901 "redis-server *:6379"
  printf 'mariadb@10.11 started akash file\nredis started akash file\n' >"$MOCK_BREW_SERVICES"
  touch "$MOCK_STATE/wkhtml_installed"
  printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
}

# install_acme: install --profile acme (the bench that doctor and the sharing tests use)
install_acme() {
  mock_services_up
  BENCH="$HOME/acme-bench"
  reset_calls
  MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw run_fm install --yes --profile acme --bench-dir "$BENCH"
  state="$(ls "$FL_STATE_DIR"/benches/acme-bench-*.env)"
}
