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
set -- "$FL_STATE_DIR"/new-site/*.rec
assert_eq "1" "$#" "(benchbar's own record of the database, written before the marker)"
grep -qx -- "db_name=${HALF_DB}" "$1" || fail "the record names the database"
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
set -- "$FL_STATE_DIR"/new-site/*.rec
[[ ! -e "$1" ]] || fail "the record is gone once the cut short new-site is cleaned up and the new one is done"
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

# benchbar's own record of the name it chose (lib/frappe-local/bench.sh, fl_site_record_write): a file
# in its state folder, keyed by the bench's path and the site
CANON="$(cd "$BENCH" && pwd -P)"
record_path() { printf '%s/new-site/%s.rec' "$FL_STATE_DIR" "$(printf '%s' "${CANON}|$1" | cksum | awk '{printf "%08x", $1}')"; }
write_record() { # SITE DB
  mkdir -p "$FL_STATE_DIR/new-site"
  printf 'bench=%s\nsite=%s\ndb_name=%s\n' "$CANON" "$1" "$2" >"$(record_path "$1")"
}

# in doubt: a marker without the database name (an older benchbar), a folder whose config names another
# database, a name that is not one benchbar makes: nothing is dropped or moved, and the exact commands are said
doubt() {
  local label="$1" site="$2" marker_body="$3" config_db="$4" before after mdb
  mkdir -p "$BENCH/sites/$site" "$BENCH/logs/.benchbar"
  printf '%s' "$marker_body" >"$BENCH/logs/.benchbar/creating-${site}"
  mdb="$(printf '%s' "$marker_body" | sed -n 's/^db_name=//p')"
  [[ -z "$mdb" ]] || write_record "$site" "$mdb"
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
write_record nopw _cccccccccccccccc
printf '{"db_name": "_cccccccccccccccc"}\n' >"$BENCH/sites/nopw/site_config.json"
printf 'wrongpw' >"$MOCK_STATE/keychain/benchbar-mariadb--root"
MARIADB_ROOT_PASSWORD=wrongpw SITE_NAME=nopw run01 --yes --offline
printf 'rootpw' >"$MOCK_STATE/keychain/benchbar-mariadb--root"
assert_eq "2" "$CODE" "$OUT"
grep -qx -- _cccccccccccccccc "$MOCK_STATE/mariadb_dbs" || fail "no database is dropped without a working root password"
assert_file "$BENCH/sites/nopw"

# ---- the database is dropped only when ALL of these hold: benchbar's own record names it, no site of any
# bench benchbar knows names it, it is still just created, a person said yes. Any other case: nothing is
# dropped or moved, and the stop names the database and the commands.
# cut_site SITE: a genuinely cut short new-site (folder, database, marker, and benchbar's record)
cut_site() {
  MOCK_NEW_SITE_CUT=1 SITE_NAME="$1" run01 --yes --offline
  assert_eq "1" "$CODE" "$OUT"
  MARKER="$BENCH/logs/.benchbar/creating-$1"
  HALF_DB="$(sed -n 's/^db_name=//p' "$MARKER")"
  [[ "$HALF_DB" =~ ^_[0-9a-f]{16}$ ]] || fail "$1: no database name in the marker"
  : >"$SQLLOG"
  reset_calls
}
# refused SITE LABEL [EXPECTED TEXT]: a rerun stops, drops and moves nothing, names the database
refused() {
  local site="$1" label="$2"
  SITE_NAME="$site" run01 --yes --offline
  assert_eq "1" "$CODE" "$label: $OUT"
  assert_contains "$OUT" "$HALF_DB" "$label (names the database)"
  [[ -z "${3:-}" ]] || assert_contains "$OUT" "$3" "$label"
  ! grep -q "DROP DATABASE" "$SQLLOG" || fail "$label: the database must not be dropped"
  grep -qx -- "$HALF_DB" "$MOCK_STATE/mariadb_dbs" || fail "$label: the database must stay"
  assert_file "$MARKER" "$label"
  assert_calls_not_contain '^bench new-site' "$label (no new site is started over it)"
  set +f; set -- "$BENCH"/archived/sites/"${site}".incomplete.*
  [[ ! -e "$1" ]] || fail "$label: nothing may be moved"
}

# a marker alone is not enough: no record in benchbar's state folder, no drop
cut_site norec
assert_file "$(record_path norec)" "(the cut short new-site left benchbar's record)"
rm -f "$(record_path norec)"
refused norec "marker without a record" "benchbar has no record"
assert_contains "$OUT" 'DROP DATABASE IF EXISTS' "(the commands for the person)"
assert_file "$BENCH/sites/norec"

# a database that another site of this bench names (here: a site made by hand over it)
cut_site shared1
mkdir -p "$BENCH/sites/handmade"
printf '{"db_name": "%s"}\n' "$HALF_DB" >"$BENCH/sites/handmade/site_config.json"
refused shared1 "database shared with a site of this bench" "sites/handmade/site_config.json names the database ${HALF_DB}"
assert_file "$BENCH/sites/shared1"

# a database that a site of another registered bench names
cut_site shared2
OTHER_BENCH="$TMP_DIR/otherbench"
mkdir -p "$OTHER_BENCH/sites/theirs"
printf '{}\n' >"$OTHER_BENCH/sites/common_site_config.json"
printf '{"db_name": "%s"}\n' "$HALF_DB" >"$OTHER_BENCH/sites/theirs/site_config.json"
printf '%s\n' "$OTHER_BENCH" >"$FL_STATE_DIR/registered-benches.txt"
refused shared2 "database shared with another registered bench" "otherbench/sites/theirs/site_config.json names the database ${HALF_DB}"
assert_file "$BENCH/sites/shared2"
# the same database unregistered elsewhere is not seen (benchbar knows only the benches it knows): it is dropped
cut_site shared3
printf '' >"$FL_STATE_DIR/registered-benches.txt"
SITE_NAME=shared3 run01 --yes --offline
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "dropped the database ${HALF_DB}"

# a finished site with a stale marker: the database has users, so it is no half made one
cut_site stale
printf 'Administrator\nGuest\nalice@example.com\n' >"$MOCK_STATE/mariadb_users.${HALF_DB}"
refused stale "complete site with a stale marker" "holds data"
assert_file "$BENCH/sites/stale/site_config.json"

# the folder is gone and the database cannot be cleaned up: a stop that names it, not a silent new-site
cut_site orphan
mv "$BENCH/sites/orphan" "$TMP_DIR/orphan.moved"
rm -f "$(record_path orphan)"
SITE_NAME=orphan run01 --yes --offline
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "sites/orphan is gone; its database ${HALF_DB} may be left behind"
assert_contains "$OUT" 'DROP DATABASE IF EXISTS' "(the commands)"
assert_calls_not_contain '^bench new-site' "(no new-site over an orphan database)"
grep -qx -- "$HALF_DB" "$MOCK_STATE/mariadb_dbs" || fail "the orphan database stays"
assert_file "$MARKER"

# a dry run says what it would do and does it not
cut_site dryrun
SITE_NAME=dryrun run01 --yes --offline --dry-run
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "dry-run: would move ${BENCH}/sites/dryrun"
assert_contains "$OUT" "drop the database ${HALF_DB}"
assert_contains "$OUT" "only if it is still just created"
assert_file "$BENCH/sites/dryrun"
grep -qx -- "$HALF_DB" "$MOCK_STATE/mariadb_dbs" || fail "a dry run drops nothing"
! grep -q "DROP DATABASE" "$SQLLOG" || fail "a dry run drops nothing"
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
