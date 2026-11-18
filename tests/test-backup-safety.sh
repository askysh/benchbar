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

# ---- SVC-3, later: a kept set is never the only copy that gets pruned or lost
# kcall CODE: CODE in a fresh shell with the libraries loaded (a killed run is made by hand)
kcall() {
  FL_STATE_DIR="$FL_STATE_DIR" FL_BACKUP_ROOT="$FL_BACKUP_ROOT" FL_BENCH_DIR="$BENCH" LIBROOT="$ROOT/lib/frappe-local" bash -c '
    for f in ui.sh run.sh templates.sh site-backups.sh; do . "$LIBROOT/$f"; done
    eval "$1"' _ "$1"
}
# shellcheck disable=SC2016  # expanded in the shell kcall starts
PRUNE='fl_state_prune "$FL_STATE_DIR/logs"'
# newer_stamps N: N state backup folders, all newer than the fixtures
newer_stamps() {
  local i
  for i in $(seq 1 "$1"); do mkdir -p "$FL_BACKUP_ROOT/20261001-$(printf '%06d' "$i")-$i"; printf 'x\n' >"$FL_BACKUP_ROOT/20261001-$(printf '%06d' "$i")-$i/file"; done
}
# leave_kept_set SITE STAMP FILES...: what a killed run leaves: the files are in kept-sets
# and bench's backup already deleted them from the site's folder
leave_kept_set() {
  local site="$1" stamp="$2" dir ks f
  shift 2
  dir="$BENCH/sites/$site/private/backups"
  ks="$FL_BACKUP_ROOT/$stamp/kept-sets/$site"
  mkdir -p "$ks"
  printf '%s\n' "$dir" >"$ks/.from"
  for f in "$@"; do mv "$dir/$f" "$ks/$f"; done
}
find "$FL_BACKUP_ROOT" -mindepth 1 -delete
KSET="20260801_090000-bbtest_localhost"
make_old_set "$BK" bbtest_localhost 20260801_090000 files
leave_kept_set bbtest.localhost 20260801-000000-1 "${KSET}-database.sql.gz" "${KSET}-files.tar" "${KSET}-private-files.tar" "${KSET}-site_config_backup.json"
assert_no_file "$BK/${KSET}-database.sql.gz"
# 51 newer stamps (limit 50), and an old folder that holds nothing of value
newer_stamps 51
mkdir -p "$FL_BACKUP_ROOT/20260701-000000-2"; printf 'x\n' >"$FL_BACKUP_ROOT/20260701-000000-2/file"
kcall "$PRUNE"
assert_no_file "$FL_BACKUP_ROOT/20260701-000000-2" "(the prune ran and removed an old folder)"
assert_file "$FL_BACKUP_ROOT/20260801-000000-1/kept-sets/bbtest.localhost/${KSET}-database.sql.gz" "(a stamp folder that holds a kept set is never pruned)"
assert_file "$FL_BACKUP_ROOT/20260801-000000-1/kept-sets/bbtest.localhost/${KSET}-files.tar"
# doctor warns, with the fix
run_json doctor --json --bench-dir "$BENCH"
assert_eq "warn" "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"] == "kept_backups"][0]["level"]')" "$OUT"
assert_eq "kept_backups" "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"] == "kept_backups"][0]["action"]')"
assert_contains "$OUT" "4 file(s) of bbtest.localhost"
# the next backup of the site puts the files back first, says so, and the folder goes
MOCK_BENCH_BACKUP_PRUNE=1 run_json site backup bbtest.localhost --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT$ERR"
for f in database.sql.gz files.tar private-files.tar site_config_backup.json; do assert_file "$BK/${KSET}-${f}" "(put back by the next backup)"; done
assert_eq "-- dump of 20260801_090000" "$(gzip -dc "$BK/${KSET}-database.sql.gz" | head -n1)"
assert_contains "$OUT" "put back 4 older backup file(s)"
assert_eq "True" "$(printf '%s' "$OUT" | jget - 'any(c["kind"] == "backups" for c in d["changed"])')" "$OUT"
assert_no_file "$FL_BACKUP_ROOT/20260801-000000-1/kept-sets" "(nothing left to keep)"
assert_no_kept_copy
run_json doctor --json --bench-dir "$BENCH"
assert_eq "ok" "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"] == "kept_backups"][0]["level"]')" "$OUT"

# a site folder that is gone and has no archive (a site drop that found none): the files stay, are not pruned,
# and go to the archived folder when there is one
make_old_set "$BENCH/sites/ghost.localhost/private/backups" ghost_localhost 20260802_090000
GK="20260802_090000-ghost_localhost"
leave_kept_set ghost.localhost 20260802-000000-3 "${GK}-database.sql.gz" "${GK}-site_config_backup.json"
find "$BENCH/sites/ghost.localhost" -mindepth 1 -delete; rmdir "$BENCH/sites/ghost.localhost"
newer_stamps 51
kcall "$PRUNE"
assert_file "$FL_BACKUP_ROOT/20260802-000000-3/kept-sets/ghost.localhost/${GK}-database.sql.gz" "(no folder to go back to: still kept after the prune)"
run_json site backup bbtest.localhost --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT$ERR"
assert_contains "$OUT" "only in"
assert_file "$FL_BACKUP_ROOT/20260802-000000-3/kept-sets/ghost.localhost/${GK}-database.sql.gz" "(a backup of another site does not lose it)"
mkdir -p "$BENCH/archived/sites/ghost.localhost/private/backups"
run_json site backup bbtest.localhost --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT$ERR"
assert_file "$BENCH/archived/sites/ghost.localhost/private/backups/${GK}-database.sql.gz" "(put back into the archived folder)"
assert_no_file "$FL_BACKUP_ROOT/20260802-000000-3/kept-sets"

# a put back that fails (the folder cannot be written) leaves the files, then a later one puts them back
if [[ "$(id -u)" != "0" ]]; then
  make_old_set "$BK" bbtest_localhost 20260803_090000
  PB="20260803_090000-bbtest_localhost"
  leave_kept_set bbtest.localhost 20260803-000000-4 "${PB}-database.sql.gz" "${PB}-site_config_backup.json"
  chmod 555 "$BK"
  kcall 'fl_backups_recover'
  chmod 755 "$BK"
  assert_file "$FL_BACKUP_ROOT/20260803-000000-4/kept-sets/bbtest.localhost/${PB}-database.sql.gz" "(a failed put back keeps the file)"
  assert_no_file "$BK/${PB}-database.sql.gz"
  newer_stamps 51
  kcall "$PRUNE"
  assert_file "$FL_BACKUP_ROOT/20260803-000000-4/kept-sets/bbtest.localhost/${PB}-database.sql.gz" "(and the prune leaves it)"
  run_json doctor --json --bench-dir "$BENCH"
  assert_eq "warn" "$(printf '%s' "$OUT" | jget - '[c for c in d["checks"] if c["id"] == "kept_backups"][0]["level"]')" "$OUT"
  # repair is the fix doctor names
  run_json repair --yes --json --bench-dir "$BENCH"
  assert_file "$BK/${PB}-database.sql.gz" "(repair puts it back)"
  assert_no_file "$FL_BACKUP_ROOT/20260803-000000-4/kept-sets"
fi
find "$FL_BACKUP_ROOT" -mindepth 1 -delete

# a run that is cut short between begin and end puts the files back in its exit trap
make_old_set "$BK" bbtest_localhost 20260804_090000
TK="20260804_090000-bbtest_localhost"
MOCK_BENCH_BACKUP_PRUNE=1 MOCK_BENCH_BACKUP_SIGNAL=TERM run_json site backup bbtest.localhost --json --bench-dir "$BENCH"
assert_eq "143" "$CODE" "$OUT$ERR"
assert_file "$BK/${TK}-database.sql.gz" "(TERM between begin and end: the files are back)"
assert_file "$BK/${TK}-site_config_backup.json"
assert_no_kept_copy
find "$BK" -name "${TK}-*" -delete

# the copy fallback (a backup folder on another volume) reads the free space once and compares it with the
# whole folder. The df here counts what the copies already use, as a real one does: adding the copied bytes to
# the need again (a second time) fails a folder that fits
make_old_set "$BK" bbtest_localhost 20260805_090000
make_old_set "$BK" bbtest_localhost 20260806_090000
head -c 3000000 /dev/zero >"$BK/20260805_090000-bbtest_localhost-big.bin"
head -c 3000000 /dev/zero >"$BK/20260806_090000-bbtest_localhost-big.bin"
mkdir -p "$TMP_DIR/mockbin"
cat >"$TMP_DIR/mockbin/ln" <<'LN'
#!/bin/bash
# no hard links here: another volume
exit 1
LN
cat >"$TMP_DIR/mockbin/df" <<'DF'
#!/bin/bash
# DF_LIMIT_KB of room in all; what is in the kept folders is used
used="$(find "$DF_ROOT" -path '*/kept-sets/*' -type f -print0 2>/dev/null | xargs -0 cat 2>/dev/null | wc -c | tr -d ' ')"
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/x 999999999 1 %s 1%% /\n' "$(( DF_LIMIT_KB - used / 1024 ))"
DF
chmod +x "$TMP_DIR/mockbin/ln" "$TMP_DIR/mockbin/df"
total_kb=$(( ( $(find "$BK" -type f -print0 | xargs -0 cat | wc -c) + 1023 ) / 1024 ))
# half the room: the folder does not fit, bench's backup does not run
reset_calls
DF_ROOT="$FL_BACKUP_ROOT" DF_LIMIT_KB="$((total_kb / 2))" PATH="$TMP_DIR/mockbin:$PATH" run_json site backup bbtest.localhost --json --bench-dir "$BENCH"
assert_eq "1" "$CODE" "$OUT$ERR"
assert_contains "$OUT$ERR" "not enough free space to keep the older backups"
assert_calls_not_contain '^bench --site .* backup' "(bench's backup does not run when the files cannot be kept)"
assert_file "$BK/20260805_090000-bbtest_localhost-big.bin"
assert_no_kept_copy
# room for the whole folder and a little more: the copy is made, bench's backup runs, the files are still there
DF_ROOT="$FL_BACKUP_ROOT" DF_LIMIT_KB="$((total_kb + 64))" MOCK_BENCH_BACKUP_PRUNE=1 PATH="$TMP_DIR/mockbin:$PATH" run_json site backup bbtest.localhost --json --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT$ERR"
assert_file "$BK/20260805_090000-bbtest_localhost-big.bin" "(kept by a copy, put back)"
assert_file "$BK/20260806_090000-bbtest_localhost-database.sql.gz"
assert_no_kept_copy

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
