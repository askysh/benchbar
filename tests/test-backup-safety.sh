#!/usr/bin/env bash
# Backups and state folders: bench's backup never deletes the site's older
# backups (SVC-3), a backup set is read before the old data is replaced
# (SVC-12), benchbar's own run logs, state backups and temp files keep to a
# limit (SVC-14, CORE-12), and the evidence of a crash survives more than one
# start (SVC-15).
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

BENCH="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH" macdev
printf 'port 11000\n' >"$BENCH/config/redis_queue.conf"; printf 'port 13000\n' >"$BENCH/config/redis_cache.conf"
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
export MARIADB_ROOT_PASSWORD=rootpw
for s in bbtest.localhost other; do
  mkdir -p "$BENCH/sites/$s"; printf '{"db_name":"_x"}\n' >"$BENCH/sites/$s/site_config.json"
done
printf '127.0.0.1 macdev\n\n# >>> benchbar >>>\n127.0.0.1 bbtest.localhost\n127.0.0.1 other\n# <<< benchbar <<<\n' >>"$FL_HOSTS_FILE"
BK="$BENCH/sites/bbtest.localhost/private/backups"
run_json() {
  set +e
  OUT="$("$FM" "$@" 2>"$MOCK_STATE/stderr")"
  CODE="$?"
  ERR="$(cat "$MOCK_STATE/stderr")"
  set -e
}
# make_old_set DIR SLUG STAMP [files]: an old backup set, its files a week old
make_old_set() {
  local base="$1/$3-$2"
  mkdir -p "$1"
  # the line a restore reads the installed apps from (verify wants frappe)
  mkgz "${base}-database.sql.gz" "-- dump of $3
INSERT INTO \`tabDefaultValue\` VALUES ('a','__default','installed_apps','[\\\"frappe\\\"]');"
  printf '{}\n' >"${base}-site_config_backup.json"
  if [[ "${4:-}" == "files" ]]; then mktar "${base}-files.tar"; mktar "${base}-private-files.tar"; fi
  touch -t 202609010900 "${base}"-*
}
# no leftover of the keep copy in the state backups
assert_no_kept_copy() {
  [[ -z "$(find "$FL_BACKUP_ROOT" -name 'kept-sets*' 2>/dev/null)" ]] || fail "a kept copy is left behind: $(find "$FL_BACKUP_ROOT" -name 'kept-sets*')"
}

# ---- SVC-3: site backup keeps the older sets that bench's backup would delete
make_old_set "$BK" bbtest_localhost 20260901_090000 files
make_old_set "$BK" bbtest_localhost 20260902_090000
MOCK_BENCH_BACKUP_PRUNE=1 run_json site backup bbtest.localhost --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT$ERR"
for f in 20260901_090000-bbtest_localhost-database.sql.gz 20260901_090000-bbtest_localhost-files.tar 20260901_090000-bbtest_localhost-private-files.tar \
  20260901_090000-bbtest_localhost-site_config_backup.json 20260902_090000-bbtest_localhost-database.sql.gz; do
  assert_file "$BK/$f" "(site backup must not delete older backups)"
done
assert_eq "-- dump of 20260901_090000" "$(gzip -dc "$BK/20260901_090000-bbtest_localhost-database.sql.gz" | head -n1)"
assert_eq "202609010900" "$(date -r "$BK/20260901_090000-bbtest_localhost-database.sql.gz" +%Y%m%d%H%M 2>/dev/null || date -d "@$(mtime_of "$BK/20260901_090000-bbtest_localhost-database.sql.gz")" +%Y%m%d%H%M)" "(the kept file keeps its time)"
assert_no_kept_copy
run_json site backups bbtest.localhost --json --bench-dir "$BENCH"
assert_eq "3" "$(printf '%s' "$OUT" | jget - 'len(d["backups"])')" "$OUT"
# nothing about the pruning is hidden: the text output says what was kept
MOCK_BENCH_BACKUP_PRUNE=1 run_fm site backup bbtest.localhost --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
assert_contains "$OUT" "older backups are kept"
assert_file "$BK/20260901_090000-bbtest_localhost-database.sql.gz"

# bench drop-site runs through the env's python: env-python answers it, frappe-python answers a restore
use_python() { cp "$ROOT/tests/mocks/$1" "$BENCH/env/bin/python"; chmod +x "$BENCH/env/bin/python"; }

# ---- SVC-3: site drop keeps them too, in the archived folder
OB="$BENCH/sites/other/private/backups"
make_old_set "$OB" other 20260901_090000 files
MOCK_BENCH_BACKUP_PRUNE=1 run_json site drop other --confirm-site other --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT$ERR"
assert_file "$BENCH/archived/sites/other/private/backups/20260901_090000-other-database.sql.gz" "(site drop must not delete older backups)"
assert_file "$BENCH/archived/sites/other/private/backups/20260901_090000-other-files.tar"
assert_no_kept_copy

# ---- SVC-3: the backup a restore takes first keeps them
use_python frappe-python
mkdir -p "$BENCH/sites/bbtest.localhost"
make_old_set "$BK" bbtest_localhost 20260903_090000 files
MOCK_BENCH_BACKUP_PRUNE=1 run_json site restore bbtest.localhost --from 20260903_090000 --with-files --dry-run --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT$ERR"
token="$(printf '%s' "$OUT" | jget - 'd["token"]')"
MOCK_BENCH_BACKUP_PRUNE=1 run_json site restore bbtest.localhost --from 20260903_090000 --with-files --apply "$token" --yes --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT$ERR"
assert_file "$BK/20260901_090000-bbtest_localhost-database.sql.gz" "(the backup before a restore must not delete older backups)"
assert_file "$BK/20260902_090000-bbtest_localhost-database.sql.gz"
assert_no_kept_copy

# plan_refused TEXT: the plan was made (exit 0) and cannot be applied, TEXT is among its errors
plan_refused() {
  assert_eq "0" "$CODE" "$OUT$ERR"
  assert_eq "False" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')" "$OUT"
  assert_contains "$OUT" "$1"
}

# ---- SVC-12: a set is read before the old data is replaced
GOOD="$BK/20260903_090000-bbtest_localhost-database.sql.gz"
cp "$GOOD" "$TMP_DIR/good.gz"
# a truncated gzip
head -c 12 "$TMP_DIR/good.gz" >"$GOOD"
reset_calls
run_json site restore bbtest.localhost --from 20260903_090000 --dry-run --json --bench-dir "$BENCH"
plan_refused "20260903_090000-bbtest_localhost-database.sql.gz is not a complete gzip file"
assert_calls_not_contain '^bench --site .* backup|benchbar-frappe .* restore'
# a zero byte dump
: >"$GOOD"
run_json site restore bbtest.localhost --from 20260903_090000 --dry-run --json --bench-dir "$BENCH"
plan_refused "is empty"
cp "$TMP_DIR/good.gz" "$GOOD"
# a files archive that tar cannot read, only a problem when files are restored
FILES="$BK/20260903_090000-bbtest_localhost-files.tar"
printf 'not a tar\n' >"$FILES"
run_json site restore bbtest.localhost --from 20260903_090000 --with-files --dry-run --json --bench-dir "$BENCH"
plan_refused "20260903_090000-bbtest_localhost-files.tar is not a readable tar archive"
run_json site restore bbtest.localhost --from 20260903_090000 --dry-run --json --bench-dir "$BENCH"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'd["can_apply"]')" "$OUT"
mktar "$FILES"
# the apply of a plan made before the file broke stops before anything is backed up
run_json site restore bbtest.localhost --from 20260903_090000 --dry-run --json --bench-dir "$BENCH"
token="$(printf '%s' "$OUT" | jget - 'd["token"]')"
reset_calls
head -c 12 "$TMP_DIR/good.gz" >"$GOOD"
run_json site restore bbtest.localhost --from 20260903_090000 --apply "$token" --yes --json --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT$ERR"
assert_calls_not_contain '^bench --site .* backup|benchbar-frappe .* restore'
cp "$TMP_DIR/good.gz" "$GOOD"

# the listing marks a set that is empty
: >"$BK/20260904_090000-bbtest_localhost-database.sql.gz"
run_json site backups bbtest.localhost --json --bench-dir "$BENCH"
assert_eq "False" "$(printf '%s' "$OUT" | jget - '[b for b in d["backups"] if b["stamp"] == "20260904_090000"][0]["complete"]')"
assert_eq "True" "$(printf '%s' "$OUT" | jget - '[b for b in d["backups"] if b["stamp"] == "20260903_090000"][0]["complete"]')"
run_fm site backups bbtest.localhost --bench-dir "$BENCH"
assert_contains "$OUT" "incomplete"
rm -f "$BK/20260904_090000-bbtest_localhost-database.sql.gz"

# pull --from-dir reads the set before anything is replaced
DL="$TMP_DIR/dl"
mkdir -p "$DL"
mkgz "$DL/20260905_090000-erp_example_com-database.sql.gz" "dump"
head -c 10 "$DL/20260905_090000-erp_example_com-database.sql.gz" >"$DL/trunc.gz"
mv "$DL/trunc.gz" "$DL/20260905_090000-erp_example_com-database.sql.gz"
reset_calls
run_fm pull --from-dir "$DL" --as bbtest.localhost --replace --yes --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT"
assert_contains "$OUT" "is not a complete gzip file"
assert_calls_not_contain '^bench --site .* backup|benchbar-frappe .* restore'

# ---- SVC-14 and CORE-12: benchbar's own files keep to a limit
LOGS="$FL_STATE_DIR/logs"
mkdir -p "$LOGS" "$FL_BACKUP_ROOT"
# the runs above made logs and backup folders of their own, all newer than the fixtures
find "$LOGS" -type f -delete
find "$FL_BACKUP_ROOT" -mindepth 1 -delete
for i in 1 2 3 4 5 6 7 8; do printf 'log %s\n' "$i" >"$LOGS/2026010${i}-000000-100${i}.log"; done
printf 'keep: not a run log\n' >"$LOGS/notes.txt"
for i in 1 2 3 4 5 6; do mkdir -p "$FL_BACKUP_ROOT/2026010${i}-000000-100${i}"; printf 'x\n' >"$FL_BACKUP_ROOT/2026010${i}-000000-100${i}/file"; done
mkdir -p "$FL_BACKUP_ROOT/20260101-000000-1001/restore-set"; printf 'set\n' >"$FL_BACKUP_ROOT/20260101-000000-1001/restore-set/x"
mkdir -p "$FL_BACKUP_ROOT/not-a-stamp"; printf 'y\n' >"$FL_BACKUP_ROOT/not-a-stamp/file"
for d in 01 02 03 04; do printf 'check\n' >"$FL_STATE_DIR/update-check.202601${d}.txt"; done
printf 'tmp\n' >"$FL_STATE_DIR/state.env.AbC123"; touch -t 202601010000 "$FL_STATE_DIR/state.env.AbC123"
printf 'tmp\n' >"$FL_STATE_DIR/state.env.Zz9876"
export FL_KEEP_RUN_LOGS=4 FL_KEEP_STATE_BACKUPS=3 FL_KEEP_UPDATE_CHECKS=2
run_json site backup bbtest.localhost --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT$ERR"
# the four newest logs: this run's and 2026010{8,7,6}; the older ones are gone, other files stay
assert_eq "4" "$(find "$LOGS" -name '*.log' | wc -l | tr -d ' ')" "$(ls "$LOGS")"
assert_file "$LOGS/20260108-000000-1008.log"; assert_file "$LOGS/20260106-000000-1006.log"
assert_no_file "$LOGS/20260105-000000-1005.log"; assert_no_file "$LOGS/20260101-000000-1001.log"
assert_file "$LOGS/notes.txt"
# the newest three stamps of the state backups (this run's may not have one), the one with a restore-set, and what is no stamp
assert_no_file "$FL_BACKUP_ROOT/20260102-000000-1002"
assert_no_file "$FL_BACKUP_ROOT/20260103-000000-1003"
assert_file "$FL_BACKUP_ROOT/20260104-000000-1004"; assert_file "$FL_BACKUP_ROOT/20260106-000000-1006"
assert_file "$FL_BACKUP_ROOT/20260101-000000-1001/restore-set/x" "(a folder that holds a restore-set stays)"
assert_file "$FL_BACKUP_ROOT/not-a-stamp/file"
assert_no_file "$FL_STATE_DIR/update-check.20260101.txt"; assert_no_file "$FL_STATE_DIR/update-check.20260102.txt"
assert_file "$FL_STATE_DIR/update-check.20260104.txt"
assert_no_file "$FL_STATE_DIR/state.env.AbC123" "(an old temp file of a killed writer)"
assert_file "$FL_STATE_DIR/state.env.Zz9876" "(a young one may be a live writer's)"
# the done line says it
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'any(c["kind"] == "pruned" for c in d["changed"])')" "$OUT"
# the next run adds a log and the limit holds: it removes that one log, nothing else, and says so
run_json site backup bbtest.localhost --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT$ERR"
assert_eq "4" "$(find "$LOGS" -name '*.log' | wc -l | tr -d ' ')"
assert_contains "$OUT" "1 run logs (keeps 4), 0 backup folders (keeps 3), 0 update checks (keeps 2), 0 old temp files"
unset FL_KEEP_RUN_LOGS FL_KEEP_STATE_BACKUPS FL_KEEP_UPDATE_CHECKS

# ---- SVC-15: the evidence of a crash survives a second start
export MOCK_KICKSTART_PING=200
printf 'crash trace\n' >"$BENCH/logs/bench.log"
run_fm up --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"
grep -q 'crash trace' "$BENCH/logs/bench.previous.log" || fail "the first start keeps the crash in bench.previous.log"
printf 'second short run\n' >"$BENCH/logs/bench.log"
run_fm restart --bench-dir "$BENCH"
grep -q 'second short run' "$BENCH/logs/bench.previous.log" || fail "bench.previous.log is the run before the last start"
grep -q 'crash trace' "$BENCH/logs/bench.previous.1.log" || fail "the crash of the first run is gone after the second start: $(ls "$BENCH/logs")"
printf 'third short run\n' >"$BENCH/logs/bench.log"
run_fm restart --bench-dir "$BENCH"
grep -q 'crash trace' "$BENCH/logs/bench.previous.2.log" || fail "the crash is kept through a third start: $(ls "$BENCH/logs")"
printf 'fourth\n' >"$BENCH/logs/bench.log"; run_fm restart --bench-dir "$BENCH"
printf 'fifth\n' >"$BENCH/logs/bench.log"; run_fm restart --bench-dir "$BENCH"
assert_no_file "$BENCH/logs/bench.previous.4.log" "(three older copies at most)"

printf 'test-backup-safety: ok\n'
