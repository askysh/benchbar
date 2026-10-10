#!/usr/bin/env bash
# Doctor, repair and report on Linux (Ubuntu under WSL): the checks that only
# make sense on a Mac are not emitted, the apt, uv, fnm, MariaDB and name
# resolution checks give the right level, fix and action, repair plans the
# Linux actions with sudo only where it is needed, and the report collects the
# Linux items and redacts the hostname and the passwords.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
use_linux

BENCH="$HOME/frappe-bench"
SITE="linuxdev.localhost"
make_fake_bench "$BENCH" "$SITE"
# the bench's PATH has the mocks' pkg-config; the machine's own mariadbd,
# MariaDB drop-in folder and my.cnf are fakes
export FL_LAUNCHD_PATH_SYSTEM="$ROOT/tests/mocks/bin:/usr/bin:/bin"
CONF="$TMP_DIR/mysql/mariadb.conf.d"
mkdir -p "$CONF"
export FL_MARIADB_CONF_DIR="$CONF" FL_MYSQL_CNF="$TMP_DIR/mysql/my.cnf"
printf '[client-server]\n!includedir %s/\n' "$CONF" >"$FL_MYSQL_CNF"
SCRIPT_DIR="$ROOT" bash -c '. "$1/lib/frappe-local/ui.sh"; . "$1/lib/frappe-local/templates.sh"; fl_template_render mariadb-frappe.cnf' _ "$ROOT" >"$CONF/99-frappe.cnf"
cat >"$TMP_DIR/mariadbd" <<'SH'
#!/usr/bin/env bash
echo "mariadbd  Ver 10.11.8-MariaDB-0ubuntu0.24.04.1 for debian-linux-gnu on x86_64 (Ubuntu 24.04)"
SH
chmod +x "$TMP_DIR/mariadbd"
export FL_MARIADBD_BIN="$TMP_DIR/mariadbd"

SKIPPED="formula_dates python_leaves legacy_agents cleanmymac mole app_copies full_disk_access fork_safety redis_6379"
HAVE_SYSTEMD=0
[[ -f "$ROOT/lib/frappe-local/systemd.sh" ]] && HAVE_SYSTEMD=1
if [[ "$HAVE_SYSTEMD" == "1" ]]; then
  run_fm service --yes --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
else
  echo "note: lib/frappe-local/systemd.sh is not there yet; the unit, runner and Procfile checks are left out of the healthy assertions"
fi

# scan [ARGS]: one doctor --json run, kept in CUR (its exit code in SCAN_CODE);
# row, msg and field read from it, so a scenario costs one doctor run
CUR="$TMP_DIR/cur.json"
scan() { set +e; "$FM" doctor --json "$@" --bench-dir "$BENCH" >"$CUR" 2>/dev/null; SCAN_CODE=$?; set -e; }
# row ID: "level | fix_command | action" of one check
row() { jget "$CUR" "' | '.join(str(c[k] or '-') for c in d['checks'] if c['id'] == '$1' for k in ('level','fix_command','action'))"; }
msg() { jget "$CUR" "[c['message'] for c in d['checks'] if c['id'] == '$1'][0]"; }
field() { jget "$CUR" "[c['$2'] for c in d['checks'] if c['id'] == '$1'][0]"; }
count() { jget "$CUR" "len([c for c in d['checks'] if c['id'] == '$1'])"; }
events() { set +e; EV="$("$FM" repair --json "$@" --bench-dir "$BENCH" 2>/dev/null)"; CODE=$?; set -e; }
ev() { printf '%s\n' "$EV" | python3 -c "import json,sys; e=[json.loads(l) for l in sys.stdin if l.strip()]; print($1)"; }

# ---- a healthy Linux machine
scan
assert_eq "0" "$SCAN_CODE" "(doctor exits 0 on a healthy Linux machine)"
for id in $SKIPPED; do
  assert_eq "0" "$(count "$id")" "(check $id is not emitted on Linux)"
done
assert_eq "0" "$(jget "$CUR" "d['summary']['fail']")"
for id in brew hosts mariadb_bind mariadb_utf8 mariadb_version toolchain_node toolchain_yarn toolchain_pkgconfig; do
  assert_eq "ok | - | -" "$(row "$id")" "($id)"
done
assert_contains "$(msg brew)" "Python 3.11 (uv) and Node 22 (fnm)"
assert_contains "$(msg mariadb_version)" "MariaDB 10.11.8"
assert_eq "System packages" "$(field brew label)"
assert_eq "systemd unit" "$(field agent label)"
assert_eq "Site name resolves" "$(field hosts label)"
if [[ "$HAVE_SYSTEMD" == "1" ]]; then
  assert_eq "0" "$(jget "$CUR" "d['summary']['warn']")" "(a healthy Linux machine has no warning)"
  run_fm repair --dry-run --bench-dir "$BENCH"
  assert_eq "0" "$CODE" "$OUT"
  assert_contains "$OUT" "unchanged: all"
fi
# doctor is read only and never reads the password file
mkdir -p "$FL_STATE_DIR/secrets"; printf 'DoNotReadMe\n' >"$FL_STATE_DIR/secrets/mariadb-root"; chmod 600 "$FL_STATE_DIR/secrets/mariadb-root"
snap_before="$(snapshot "$HOME" "$BENCH" "$CONF")"
reset_calls
run_fm doctor --bench-dir "$BENCH"
assert_eq "$snap_before" "$(snapshot "$HOME" "$BENCH" "$CONF")" "(doctor must not write)"
assert_not_contains "$OUT" "DoNotReadMe"
assert_calls_not_contain '^(sudo|apt-get|systemctl (start|restart|stop|enable)|mariadb )'

# ---- a missing apt package: FAIL, the exact apt command, no repair action
cp "$MOCK_STATE/apt_installed" "$MOCK_STATE/apt_installed.good"
grep -vx redis-server "$MOCK_STATE/apt_installed.good" >"$MOCK_STATE/apt_installed"
scan
assert_eq "1" "$SCAN_CODE"
assert_eq "fail | sudo apt-get install -y redis-server | -" "$(row brew)"
assert_contains "$(msg brew)" "missing apt packages: redis-server"
# a build package is a warning
grep -vx libmariadb-dev "$MOCK_STATE/apt_installed.good" >"$MOCK_STATE/apt_installed"
scan
assert_eq "0" "$SCAN_CODE"
assert_eq "warn | sudo apt-get install -y libmariadb-dev | -" "$(row brew)"
cp "$MOCK_STATE/apt_installed.good" "$MOCK_STATE/apt_installed"

# ---- the profile's Node missing from fnm: FAIL with the fnm command and node_install
NODE_DIR="$HOME/.local/share/fnm/node-versions"
mv "$NODE_DIR/v22.11.0" "$TMP_DIR/v22.gone"
scan
assert_eq "fail | fnm install 22 | node_install" "$(row brew)"
assert_eq "warn | fnm install 22 | node_install" "$(row toolchain_node)"
assert_contains "$(msg brew)" "Node 22 (fnm) not found"
# repair --dry-run plans fnm install, without sudo, and runs nothing
events --dry-run
assert_eq "0" "$CODE" "$EV"
assert_eq "plan" "$(ev 'e[0]["event"]')"
assert_contains "$(ev '[a["id"] for a in e[0]["actions"]]')" "node_install"
assert_eq "False" "$(ev '[a["sudo"] for a in e[0]["actions"] if a["id"]=="node_install"][0]')"
assert_eq "fnm install 22 (the Node of profile v15-lts; an older Node is not removed)" "$(ev '[a["label"] for a in e[0]["actions"] if a["id"]=="node_install"][0]')"
# none of the Mac only actions, and sudo only where it is needed
for a in python_leaves legacy_migrate hosts_entry redis_stop; do
  assert_eq "False" "$(ev "'$a' in [x['id'] for x in e[0]['actions']]")"
done
assert_eq "[]" "$(ev '[a["id"] for a in e[0]["actions"] if a["sudo"]]')" "(no sudo here)"
reset_calls
run_fm repair --dry-run --bench-dir "$BENCH"
assert_contains "$OUT" "dry-run: fnm install 22"
assert_calls_not_contain '^(fnm install|sudo|apt-get)'
# repair --yes installs it through fnm
# (without the systemd backend the unit cannot be written here: leave that action out)
if [[ "$HAVE_SYSTEMD" == "1" ]]; then run_fm repair --yes --bench-dir "$BENCH"; else FL_ENGINE_SKIP_ACTIONS="write_plist" run_fm repair --yes --bench-dir "$BENCH"; fi
assert_calls_contain '^fnm install 22'
assert_not_contains "$OUT" ": failed"
scan
assert_eq "ok | - | -" "$(row brew)"
assert_eq "ok | - | -" "$(row toolchain_node)"
# the Python missing from uv: FAIL with the uv command (no repair action)
PY_DIR="$HOME/.local/share/uv/python"
mv "$PY_DIR/cpython-3.11.9-linux-x86_64-gnu" "$TMP_DIR/py311.gone"
scan
assert_eq "fail | uv python install 3.11 | -" "$(row brew)"
mv "$TMP_DIR/py311.gone" "$PY_DIR/cpython-3.11.9-linux-x86_64-gnu"

# ---- yarn missing: the fnm Node's npm installs it
rm -f "$NODE_DIR"/v22.*/installation/bin/yarn
scan
assert_eq "warn" "$(field toolchain_yarn level)"
assert_eq "yarn_install" "$(field toolchain_yarn action)"
assert_contains "$(field toolchain_yarn fix_command)" "/installation/bin/npm install -g yarn"

# ---- the site does not resolve (the getent mock knows *.localhost and the listed names)
scan --site mysite.test
assert_eq "1" "$SCAN_CODE"
assert_eq "fail" "$(field hosts level)"
assert_contains "$(field hosts fix_command)" "*.localhost"
assert_contains "$(field hosts fix_command)" "echo '127.0.0.1 mysite.test'"
assert_eq "None" "$(field hosts action)" "(no repair action: nothing in /etc/hosts is edited on Linux)"
printf 'mysite.test\n' >"$MOCK_STATE/hosts_resolve"
scan --site mysite.test
assert_eq "ok | - | -" "$(row hosts)"
assert_calls_not_contain '^sudo'

# ---- a *.localhost site on a glibc without nss-myhostname: the fix is the package
touch "$MOCK_STATE/no_myhostname"
scan
assert_eq "fail" "$(field hosts level)"
assert_contains "$(field hosts fix_command)" "libnss-myhostname"
assert_not_contains "$(field hosts fix_command)" "/etc/hosts"
rm -f "$MOCK_STATE/no_myhostname"

# ---- MariaDB drop-in missing: WARN with the repair fix and the action, sudo in the plan
mv "$CONF/99-frappe.cnf" "$TMP_DIR/99-frappe.cnf.gone"
scan
assert_eq "warn" "$(field mariadb_utf8 level)"
assert_eq "mariadb_utf8" "$(field mariadb_utf8 action)"
assert_contains "$(field mariadb_utf8 fix_command)" "with sudo"
events --dry-run
assert_eq "True" "$(ev '[a["sudo"] for a in e[0]["actions"] if a["id"]=="mariadb_utf8"][0]')"
assert_contains "$(ev '[a["label"] for a in e[0]["actions"] if a["id"]=="mariadb_utf8"][0]')" "(sudo)"
# the drop-in is there, but my.cnf does not pull the folder in
mv "$TMP_DIR/99-frappe.cnf.gone" "$CONF/99-frappe.cnf"
printf '[client-server]\n' >"$FL_MYSQL_CNF"
scan
assert_contains "$(msg mariadb_utf8)" "!includedir"
printf '[client-server]\n!includedir %s/\n' "$CONF" >"$FL_MYSQL_CNF"

# ---- MariaDB listening on every address: WARN mariadb_bind, sudo in the plan
: >"$MOCK_LISTEN"; add_listener 3306 111 mariadbd '*'
scan
assert_eq "warn" "$(field mariadb_bind level)"
assert_eq "mariadb_bind" "$(field mariadb_bind action)"
assert_contains "$(field mariadb_bind fix_command)" "${CONF}/99-benchbar-local-only.cnf"
events --dry-run
assert_eq "True" "$(ev '[a["sudo"] for a in e[0]["actions"] if a["id"]=="mariadb_bind"][0]')"
# not running: a warning, and the server's own bind-address line counts
: >"$MOCK_LISTEN"
scan
assert_eq "warn" "$(field mariadb_bind level)"
assert_eq "warn | sudo systemctl start mariadb | -" "$(row mariadb_version)"
printf '[mysqld]\nbind-address            = 127.0.0.1\n' >"$CONF/50-server.cnf"
scan
assert_eq "ok | - | -" "$(row mariadb_bind)"
rm -f "$CONF/50-server.cnf"
printf '3306 111 mariadbd 127.0.0.1\n' >"$MOCK_LISTEN"
# a redis on 6379 is expected on Linux, not a stray
add_listener 6379 222 redis-server 127.0.0.1
scan
assert_eq "0" "$(count redis_6379)"

# ---- the action table: order and sudo, and the apt MariaDB as the profile's formula
LIBS="$(cd "$ROOT/lib/frappe-local" && printf '%s ' ui.sh run.sh platform.sh version-policy.sh state.sh templates.sh shellrc.sh benchinfo.sh process.sh mariadb.sh checks.sh repair.sh report.sh)"
# shellcheck disable=SC2016  # the code runs in the child shell
libcall() { # libcall CODE: runs CODE with the libraries loaded and the Linux layer on top
  FL_PLATFORM=linux SCRIPT_DIR="$ROOT" LIBS="$LIBS" bash -c '
    for f in $LIBS; do . "$SCRIPT_DIR/lib/frappe-local/$f"; done
    fl_platform_load
    eval "$1"' _ "$1"
}
# shellcheck disable=SC2016
assert_eq "node_install yarn_install env_rebuild env_setuptools honcho_install honcho_setuptools node_requirements build clear_cache mariadb_bind mariadb_utf8 wkhtmltopdf_install port_block write_procfile write_runner write_plist write_helpers write_cli_link rotate_logs" "$(libcall 'printf %s "$FL_ACTION_ORDER"')"
# shellcheck disable=SC2016
assert_eq "mariadb_bind mariadb_utf8 wkhtmltopdf_install" "$(libcall 'for a in $FL_ACTION_ORDER; do fl_action_needs_sudo "$a" && printf "%s " "$a"; done' | sed 's/ $//')"
assert_eq "mariadb@10.11 10.11.8" "$(libcall 'fl_mariadb_running_formula')"

# ---- report on Linux
EXTRA="$TMP_DIR/extra-bin"
mkdir -p "$EXTRA"
printf '#!/usr/bin/env bash\necho ubuntu-box-77\n' >"$EXTRA/hostname"
printf '#!/usr/bin/env bash\necho "unit status for $*"\n' >"$EXTRA/systemctl"
printf '#!/usr/bin/env bash\necho "journal for $*"\necho "db_password=Hunter2Secret on ubuntu-box-77"\n' >"$EXTRA/journalctl"
chmod +x "$EXTRA"/*
printf 'processor\t: 0\nmodel name\t: Test CPU 9000 @ 3.00GHz\n' >"$MOCK_STATE/cpuinfo"
export FL_CPUINFO="$MOCK_STATE/cpuinfo"
printf 'start on ubuntu-box-77 as %s\ndb_password=Hunter2Secret\n' "$USER" >>"$BENCH/logs/bench.log"
OUT="$(PATH="$EXTRA:$PATH" "$FM" report --print --bench-dir "$BENCH" 2>&1)"
assert_contains "$OUT" "Ubuntu"
assert_contains "$OUT" "6.6.0-microsoft-standard-WSL2"
assert_contains "$OUT" "Test CPU 9000"
assert_contains "$OUT" "systemctl --user status"
assert_contains "$OUT" "journalctl --user -u"
assert_contains "$OUT" "-n 200 --no-pager"
assert_not_contains "$OUT" "sw_vers"
assert_not_contains "$OUT" "launchctl"
assert_not_contains "$OUT" "sysctl"
assert_not_contains "$OUT" "brew --version"
assert_not_contains "$OUT" "BenchBar app:"
assert_not_contains "$OUT" "ubuntu-box-77"
assert_contains "$OUT" "<host>"
assert_not_contains "$OUT" "Hunter2Secret"
assert_contains "$OUT" "db_password=***"
assert_not_contains "$OUT" "$HOME/"

# the zip lands in the state folder's reports/ by default (the leg needs zip)
if command -v zip >/dev/null 2>&1; then
  PATH="$EXTRA:$PATH" "$FM" report --bench-dir "$BENCH" >/dev/null 2>&1
  assert_eq "1" "$(find "$FL_STATE_DIR/reports" -name 'benchbar-report-*.zip' | grep -c .)" "(default zip location on Linux)"
  assert_no_file "$HOME/Desktop"
else
  echo "note: zip is not installed here; the zip leg of the report test is skipped"
fi

echo "test-doctor-linux: ok"
