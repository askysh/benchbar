#!/usr/bin/env bash
# A first install on a Mac, and the reruns after it stopped (issue 112): phase 00 brings
# uv, phase 01 refuses to start bench init without it, a skeleton a failed bench init
# left is moved aside by the next run, the note about "an existing MariaDB" is for a
# server that is not benchbar's own, a new-site that was cut short is cleaned up by the
# rerun (and only when its database is provably the half made one), and benchbar is
# linked into ~/.local/bin before the bench and site step.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

add_proc 900 "mariadbd --datadir=/x"
add_proc 901 "redis-server *:6379"
printf 'mariadb@10.11 started akash file\nredis started akash file\n' >"$MOCK_BREW_SERVICES"
touch "$MOCK_STATE/wkhtml_installed"
mkdir -p "$MOCK_STATE/keychain" "$MOCK_STATE/ps"
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
printf 'rootpw' >"$MOCK_STATE/keychain/benchbar-mariadb--root"
run00() { set +e; OUT="$("$ROOT/00-mac-system-deps.sh" "$@" 2>&1)"; CODE=$?; set -e; }
run01() { set +e; OUT="$("$ROOT/01-install-bench-and-site.sh" "$@" 2>&1)"; CODE=$?; set -e; }
BENCH="$HOME/frappe-bench"
export MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw

# ---- INST-1: phase 00 installs uv with Homebrew when there is none
use_mocks_without uv
run00 --profile v15-lts --dry-run
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "dry-run: brew install uv"
assert_calls_not_contain '^brew install uv$' "(a dry run installs nothing)"
reset_calls
run00 --yes --profile v15-lts
assert_eq "0" "$CODE" "$OUT"
assert_calls_contain '^brew install uv$'
assert_contains "$OUT" "uv installed at "
# the Homebrew copy is found by its prefix, though that folder is not on PATH: not installed twice
reset_calls
run00 --yes --profile v15-lts
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain '^brew install uv$'
# a uv that is on PATH already (the owner's own) is left alone
use_all_mocks
reset_calls
run00 --yes --profile v15-lts
assert_eq "0" "$CODE" "$OUT"
assert_calls_not_contain '^brew install uv$'

# ---- SVC-5: no uv at phase 01 (bench came from pipx): stops before bench init, with the fix
use_mocks_without uv
rm -f "$MOCK_BREW_PREFIX/bin/uv"
reset_calls
run01 --yes --offline
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "uv is not installed"
assert_contains "$OUT" "00-mac-system-deps.sh"
assert_contains "$OUT" "brew install uv"
assert_calls_not_contain '^bench init' "(bench init needs uv: it is not started without it)"
[[ ! -e "$BENCH" ]] || fail "nothing may be made before the check for uv"
# a dry run names the step that installs it, and fails nothing
run01 --yes --offline --dry-run
assert_eq "0" "$CODE" "$OUT"
# the bench mock fails the way frappe-bench 5.31 does and leaves the skeleton of the issue
set +e; bench init "$BENCH" >/dev/null 2>&1; set -e
for d in apps sites config logs; do [[ -d "$BENCH/$d" ]] || fail "the failed init leaves ${d}/"; done
[[ ! -e "$BENCH/env" ]] || fail "the failed init leaves no env"

# ---- INST-2: the next run, with uv, moves the empty skeleton aside by itself and starts over
use_all_mocks
reset_calls
run01 --yes --offline
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "An earlier bench init stopped before it cloned frappe"
assert_contains "$OUT" "moving it to ${BENCH}.incomplete."
assert_calls_contain "^bench init ${BENCH} "
[[ -f "$BENCH/sites/apps.txt" && -d "$BENCH/env" ]] || fail "a complete bench after the rerun"
set -- "$HOME"/frappe-bench.incomplete.*
assert_eq "1" "$#" "(the skeleton is moved, one folder)"
[[ -d "$1/apps" && -d "$1/logs" ]] || fail "the moved skeleton keeps its folders: nothing is deleted"
# an empty log file in it is no data either, a log with lines is not looked at
mkdir -p "$HOME/skel/logs" "$HOME/skel/apps" "$HOME/skel/sites" "$HOME/skel/config" "$HOME/skel/env"
printf 'bench init started\n' >"$HOME/skel/logs/bench.log"
BENCH_DIR="$HOME/skel" run01 --yes --offline
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "moving it to ${HOME}/skel.incomplete."
# a folder with something of the user's in it is not a skeleton: the stop, and the repair-bench way out
mkdir -p "$HOME/mine/apps" "$HOME/mine/sites"
printf 'my notes\n' >"$HOME/mine/notes.txt"
BENCH_DIR="$HOME/mine" run01 --yes --offline
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "Bench directory exists but is incomplete: ${HOME}/mine"
assert_file "$HOME/mine/notes.txt"
# a folder with an app in it neither
mkdir -p "$HOME/withapp/apps/myapp" "$HOME/withapp/sites"
BENCH_DIR="$HOME/withapp" run01 --yes --offline
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "Bench directory exists but is incomplete: ${HOME}/withapp"
assert_file "$HOME/withapp/apps/myapp"

# ---- INST-2: --repair-bench with --dry-run shows the move and changes nothing
BENCH_DIR="$HOME/mine" run01 --yes --offline --repair-bench --dry-run
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "dry-run: mv ${HOME}/mine ${HOME}/mine.incomplete."
assert_file "$HOME/mine/notes.txt"
set -- "$HOME"/mine.incomplete.*
[[ ! -e "$1" ]] || fail "a dry run moves nothing"
# the same flag on benchbar install reaches the phase, and moves the folder in a real run
run_fm install --repair-bench --dry-run --yes --bench-dir "$HOME/mine" --site minesite
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "dry-run: mv ${HOME}/mine ${HOME}/mine.incomplete."
BENCH_DIR="$HOME/mine" run01 --yes --offline --repair-bench
assert_eq "0" "$CODE" "$OUT"
assert_file "$HOME/mine.incomplete."*"/notes.txt"

# ---- INST-3: the note about an existing MariaDB is for a server that is not benchbar's own
rm -rf "$BENCH" "$HOME"/frappe-bench.incomplete.*
make_fake_bench "$BENCH"
note="Existing MariaDB/MySQL may already be using port 3306"
printf '%s\n' "${MOCK_BREW_PREFIX}/opt/mariadb@10.11/bin/mariadbd --datadir=${MOCK_BREW_PREFIX}/var/mysql" >"$MOCK_STATE/ps/111"
run01 --yes --offline
assert_eq "0" "$CODE" "$OUT"
assert_not_contains "$OUT" "$note" "(the server is the profile's own Homebrew MariaDB, the Keychain password works)"
run00 --yes --profile v15-lts
assert_eq "0" "$CODE" "$OUT"
assert_not_contains "$OUT" "$note" "(the same in phase 00)"
# the password in the Keychain does not work: asked, as before
printf 'otherpw' >"$MOCK_STATE/keychain/benchbar-mariadb--root"
run01 --yes --offline
assert_contains "$OUT" "$note"
printf 'rootpw' >"$MOCK_STATE/keychain/benchbar-mariadb--root"
# a server that is not the formula's (someone else's MySQL): asked, as before
printf '%s\n' "/usr/local/mysql/bin/mysqld --datadir=/usr/local/mysql/data" >"$MOCK_STATE/ps/111"
run01 --yes --offline
assert_contains "$OUT" "$note"
run00 --yes --profile v15-lts
assert_contains "$OUT" "$note"
# the right server, but the brew service is not the one that runs it
printf '%s\n' "${MOCK_BREW_PREFIX}/opt/mariadb@10.11/bin/mariadbd --datadir=x" >"$MOCK_STATE/ps/111"
printf 'redis started akash file\n' >"$MOCK_BREW_SERVICES"
run01 --yes --offline
assert_contains "$OUT" "$note"
printf 'mariadb@10.11 started akash file\nredis started akash file\n' >"$MOCK_BREW_SERVICES"
rm -f "$MOCK_STATE/ps/111"
rm -rf "$BENCH"

# ---- INST-10: a new-site that was cut short is cleaned up by the rerun
make_fake_bench "$BENCH" othersite
SITE="cutsite"
SQLLOG="$MOCK_STATE/mariadb_sql.log"
: >"$MOCK_STATE/mariadb_dbs"
MOCK_NEW_SITE_CUT=1 SITE_NAME="$SITE" run01 --yes --offline
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "bench new-site failed"
MARKER="$BENCH/logs/.benchbar/creating-${SITE}"
assert_file "$MARKER" "(the marker stays after a cut short new-site)"
HALF_DB="$(sed -n 's/^db_name=//p' "$MARKER")"
[[ "$HALF_DB" =~ ^_[0-9a-f]{16}$ ]] || fail "the marker records the database benchbar chose, got [$HALF_DB]"
assert_calls_contain "^bench new-site ${SITE} .*--db-name ${HALF_DB}\$"
grep -qx -- "$HALF_DB" "$MOCK_STATE/mariadb_dbs" || fail "the cut short new-site left its database"
assert_file "$BENCH/sites/$SITE/site_config.json"
reset_calls
SITE_NAME="$SITE" run01 --yes --offline
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "A new-site for ${SITE} was cut short"
assert_contains "$OUT" "dropped the database ${HALF_DB}"
! grep -qx -- "$HALF_DB" "$MOCK_STATE/mariadb_dbs" || fail "the half made database is dropped"
grep -q "DROP DATABASE IF EXISTS \`${HALF_DB}\`" "$SQLLOG" || fail "the drop is in the SQL log"
grep -q "DROP USER IF EXISTS '${HALF_DB}'@'%'" "$SQLLOG" || fail "its database user is dropped too"
set -- "$BENCH"/archived/sites/"${SITE}".incomplete.*
assert_eq "1" "$#" "(the half made folder is moved, not deleted)"
assert_file "$1/site_config.json"
assert_no_file "$MARKER"
assert_file "$BENCH/sites/$SITE/site_config.json"
NEW_DB="$(sed -n 's/.*"db_name": "\(.*\)".*/\1/p' "$BENCH/sites/$SITE/site_config.json")"
[[ "$NEW_DB" != "$HALF_DB" && "$NEW_DB" =~ ^_[0-9a-f]{16}$ ]] || fail "the rerun made a new database, got [$NEW_DB]"
assert_calls_contain "^bench new-site ${SITE} .*--db-name ${NEW_DB}\$"
# a rerun of a finished site touches nothing
reset_calls
SITE_NAME="$SITE" run01 --yes --offline
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "already exists: no passwords needed"
assert_calls_not_contain '^bench new-site'

# in doubt: a marker without the database name (an older benchbar), a folder whose config names another
# database, a name that is not one benchbar makes: nothing is dropped or moved, and the exact commands are said
doubt() {
  local label="$1" site="$2" marker_body="$3" config_db="$4" before after
  mkdir -p "$BENCH/sites/$site" "$BENCH/logs/.benchbar"
  printf '%s' "$marker_body" >"$BENCH/logs/.benchbar/creating-${site}"
  [[ -z "$config_db" ]] || printf '{"db_name": "%s"}\n' "$config_db" >"$BENCH/sites/$site/site_config.json"
  : >"$SQLLOG"
  SITE_NAME="$site" run01 --yes --offline
  assert_eq "1" "$CODE" "$label: $OUT"
  assert_contains "$OUT" "a previous bench new-site ${site} did not finish" "$label"
  assert_contains "$OUT" "mv ${BENCH}/sites/${site} ~/${site}.incomplete" "$label"
  if [[ "${5:-}" == "foreign" ]]; then
    assert_not_contains "$OUT" "bench drop-site" "$label (another site's database is not offered for dropping)"
  else
    assert_contains "$OUT" "bench drop-site ${site} --force" "$label"
  fi
  ! grep -q "DROP DATABASE" "$SQLLOG" || fail "$label: no database may be dropped"
  assert_file "$BENCH/sites/$site" "$label"
  assert_file "$BENCH/logs/.benchbar/creating-${site}" "$label"
}
: >"$MOCK_STATE/mariadb_dbs"; printf '%s\n' _aaaaaaaaaaaaaaaa >>"$MOCK_STATE/mariadb_dbs"
doubt "old marker" oldmark $'2026-10-03T10:00:00Z\n' ""
doubt "other database" otherdb $'2026-10-03T10:00:00Z\ndb_name=_bbbbbbbbbbbbbbbb\n' "_aaaaaaaaaaaaaaaa" foreign
assert_contains "$OUT" "names the database _aaaaaaaaaaaaaaaa, not the one benchbar made (_bbbbbbbbbbbbbbbb)"
grep -qx -- _aaaaaaaaaaaaaaaa "$MOCK_STATE/mariadb_dbs" || fail "another site's database stays"
doubt "odd name" oddname $'2026-10-03T10:00:00Z\ndb_name=mysql\n' ""
# the root password does not work: nothing is dropped
printf '%s\n' _cccccccccccccccc >>"$MOCK_STATE/mariadb_dbs"
mkdir -p "$BENCH/sites/nopw"
printf '2026-10-03T10:00:00Z\ndb_name=_cccccccccccccccc\n' >"$BENCH/logs/.benchbar/creating-nopw"
printf '{"db_name": "_cccccccccccccccc"}\n' >"$BENCH/sites/nopw/site_config.json"
printf 'wrongpw' >"$MOCK_STATE/keychain/benchbar-mariadb--root"
MARIADB_ROOT_PASSWORD=wrongpw SITE_NAME=nopw run01 --yes --offline
printf 'rootpw' >"$MOCK_STATE/keychain/benchbar-mariadb--root"
assert_eq "2" "$CODE" "$OUT"
grep -qx -- _cccccccccccccccc "$MOCK_STATE/mariadb_dbs" || fail "no database is dropped without a working root password"
assert_file "$BENCH/sites/nopw"

# a dry run says what it would do and does it not
printf '2026-10-03T10:00:00Z\ndb_name=_dddddddddddddddd\n' >"$BENCH/logs/.benchbar/creating-dryhalf"
mkdir -p "$BENCH/sites/dryhalf"; printf '_dddddddddddddddd\n' >>"$MOCK_STATE/mariadb_dbs"
: >"$SQLLOG"
SITE_NAME=dryhalf run01 --yes --offline --dry-run
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "dry-run: would move ${BENCH}/sites/dryhalf"
assert_contains "$OUT" "drop the database _dddddddddddddddd"
assert_file "$BENCH/sites/dryhalf"
grep -qx -- _dddddddddddddddd "$MOCK_STATE/mariadb_dbs" || fail "a dry run drops nothing"
rm -rf "$BENCH"

# ---- minor point of #112: benchbar is on PATH before the bench and site step
rm -rf "$HOME/.local/bin/benchbar" "$HOME/.local/bin/frappe-mac" "$HOME"/mine* "$HOME"/skel*
mkdir -p "$HOME/failbench/apps"
printf 'my notes\n' >"$HOME/failbench/notes.txt"
unset MARIADB_ROOT_PASSWORD ADMIN_PASSWORD
reset_calls
MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw run_fm install --yes --bench-dir "$HOME/failbench" --site failsite
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "Bench directory exists but is incomplete"
[[ -L "$HOME/.local/bin/benchbar" ]] || fail "benchbar is linked into ~/.local/bin after phase 00, before phase 01 can fail"
assert_contains "$OUT" "${HOME}/.local/bin/benchbar install"
# a dry run links nothing
rm -f "$HOME/.local/bin/benchbar" "$HOME/.local/bin/frappe-mac"
MARIADB_ROOT_PASSWORD=rootpw ADMIN_PASSWORD=adminpw run_fm install --yes --dry-run --bench-dir "$HOME/failbench" --site failsite
[[ ! -e "$HOME/.local/bin/benchbar" ]] || fail "a dry run must not link anything"

printf 'ok\n'
