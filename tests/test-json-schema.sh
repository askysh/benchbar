#!/usr/bin/env bash
# schema/benchbar.schema.json is the one description of the CLI's JSON, and what reads
# it agrees with it (scripts/json-schema-check.py, docs/json-schema.md):
#   fixtures  every fixture of the Mac app and the Windows tray fits its definition
#   live      what the CLI of this checkout prints under the mocks fits too, and prints
#             every field the schema lists (a field marked x-conditional may be absent)
#   models    the Swift and C# models and mcp.py read only fields the schema has, and
#             need only fields it requires (schema/models.map)
#   docs      the prose and the schema name the same fields
# A field a pull request adds to the CLI's JSON is added to the schema in the same
# pull request: this test fails until it is.
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

CHK=(python3 -I "$ROOT/scripts/json-schema-check.py")

# check SUBCOMMAND ARGS...: runs the checker, shows what it says, fails when it does
check() {
  local out
  if ! out="$("${CHK[@]}" "$@" 2>&1)"; then
    printf '%s\n' "$out" >&2
    fail "json-schema-check $1 $2"
  fi
  [[ -z "$out" ]] || printf '%s\n' "$out"
}

# the second pass (below) is the same live checks as the Linux CLI of WSL, in a shell of its own,
# because the platform is chosen when the harness is sourced
if [[ "${1:-}" != "--live-only" ]]; then
  check fixtures
  check models
  check docs

fi

# ---- live: one fake bench, every command that prints a document
BENCH="$HOME/dev/frappe-bench"
make_fake_bench "$BENCH"
LIVE="$TMP_DIR/live"
mkdir -p "$LIVE"

# live DEFINITION NAME ARGS...: runs the CLI, keeps stdout in $LIVE/NAME, checks it against DEFINITION
live() {
  local def="$1" name="$2"
  shift 2
  set +e
  "$FM" "$@" >"$LIVE/$name" 2>"$LIVE/$name.err" </dev/null
  CODE=$?
  set -e
  # doctor exits 1 for a failing check and still prints its document
  [[ "$CODE" == 0 || ( "$def" == doctor* && "$CODE" == 1 ) ]] || fail "benchbar $* exited $CODE: $(cat "$LIVE/$name.err")"
  check live "$def" "$LIVE/$name"
}

# the stream of a command that changes things: plan, steps, done with its envelope
live streamLine service.jsonl service --yes --json --bench-dir "$BENCH"

if [[ "${BENCHBAR_TEST_PLATFORM:-}" == "linux" ]]; then
  # the Linux CLI prints fields the Mac's does not (a distro's prerequisites, the profiles it can install)
  live status status.json status --json --bench-dir "$BENCH"
  live doctor doctor.json doctor --json --bench-dir "$BENCH"
  live doctorPrerequisites prerequisites.json doctor --prerequisites --json
  live profileList profile-list.json profile list --json
  live labsList labs-list.json labs list --json
  live list list.json list --json
  live where where.json where --json
  printf 'test-json-schema (linux): ok\n'
  exit 0
fi
live streamLine service-dry.jsonl service --dry-run --json --bench-dir "$BENCH"
live streamLine up-dry.jsonl up --dry-run --json --bench-dir "$BENCH"
live streamLine repair-dry.jsonl repair --dry-run --json --bench-dir "$BENCH"
assert_contains "$(cat "$LIVE/service.jsonl")" '"event":"step"'
assert_contains "$(cat "$LIVE/service.jsonl")" '"event":"done"'

live status status.json status --json --bench-dir "$BENCH"
live list list.json list --json
live doctor doctor.json doctor --json --bench-dir "$BENCH"
live doctorPrerequisites prerequisites.json doctor --prerequisites --json
live logs logs.json logs --json -n5 --bench-dir "$BENCH"
live appList app-list.json app list --json --bench-dir "$BENCH"
live appFocus app-focus.json app focus --json --bench-dir "$BENCH"
live siteList site-list.json site list --json --bench-dir "$BENCH"
live profileList profile-list.json profile list --json
live labsList labs-list.json labs list --json
live portsCheck ports-check.json ports check --json --bench-dir "$BENCH"
live where where.json where --json
live report report.json report --json
live document site-add-plan.json site add qa.localhost --dry-run --json --bench-dir "$BENCH"
live document ports-plan.json ports plan --json --bench-dir "$BENCH" -- "$BENCH"
live document commands.json commands --json

# a backup of a site, then the list of them
mkdir -p "$BENCH/sites/bbtest.localhost"; printf '{}\n' >"$BENCH/sites/bbtest.localhost/site_config.json"
printf '# >>> benchbar >>>\n127.0.0.1 bbtest.localhost\n# <<< benchbar <<<\n' >>"$FL_HOSTS_FILE"
printf 'rootpw' >"$MOCK_STATE/mariadb_root_pw"
export MARIADB_ROOT_PASSWORD=rootpw
live siteBackup site-backup.json site backup bbtest.localhost --with-files --json --bench-dir "$BENCH"
live siteBackups site-backups.json site backups bbtest.localhost --json --bench-dir "$BENCH"

BENCHBAR_TEST_PLATFORM=linux bash "${BASH_SOURCE[0]}" --live-only

printf 'test-json-schema: ok\n'
