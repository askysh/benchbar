#!/usr/bin/env bash
#
# record-tray-fixtures.sh: keeps windows/tray/fixtures in step with the CLI.
#
#   bash tests/record-tray-fixtures.sh           rewrite the generated fixtures
#   bash tests/record-tray-fixtures.sh --check   change nothing; exit 1 when a
#                                                generated fixture differs from
#                                                what the CLI prints now, or a
#                                                hand shaped one holds a field
#                                                the CLI no longer prints
#
# It runs the CLI of this checkout under the test mocks (the same harness as
# the mocked suite, as the Linux CLI inside WSL that the tray talks to) and
# writes what it prints. Two kinds of fixture:
#
#   generated   the file is the CLI's own output for a fixed fake bench, with
#               this machine's folders replaced by /home/akash. Nothing in it is
#               typed by hand. The list is GENERATED below.
#   hand shaped a scenario the mocks cannot make: an older CLI, a refusal, a
#               check level this build does not know, three apps with focus
#               reasons. They are listed in SHAPES below, each with the command
#               it stands for. The check compares field names: every field of
#               the fixture must still be printed by that command (a rename or a
#               removal fails; a field the CLI added is only listed, since the
#               tray reads fields it knows and ignores the rest).
#
# After a CLI change that touches a document the tray reads, or a version bump
# (every generated file holds cli_version), run it without --check and commit
# the files it changes. A fixture that is in neither list is not checked.

set -euo pipefail

CHECK=0
case "${1:-}" in
  "") ;;
  --check) CHECK=1 ;;
  *) printf 'usage: tests/record-tray-fixtures.sh [--check]\n' >&2; exit 2 ;;
esac

# the Linux CLI of WSL, like the tray sees it
BENCHBAR_TEST_PLATFORM=linux
export BENCHBAR_TEST_PLATFORM
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

FIXTURES="$ROOT/windows/tray/fixtures"
BENCH="$HOME/frappe-bench"
make_fake_bench "$BENCH" linuxdev.localhost
mkdir -p "$HOME/empty"
run_fm service --yes --bench-dir "$BENCH"
assert_eq "0" "$CODE" "$OUT"

# cli_out ARGS...: the JSON document of one command, with this run's folders
# replaced by the paths the fixtures have always used. Fails when the command does.
cli_out() {
  run_fm "$@" </dev/null
  # a command that is expected to refuse (ALLOW_EXIT=1) still prints what the tray reads
  [[ "$CODE" == 0 || "${ALLOW_EXIT:-0}" == 1 ]] || fail "benchbar $* exited $CODE: $OUT"
  printf '%s\n' "$OUT" | TMP="$TMP_DIR" CHECKOUT="$ROOT" python3 -c '
import os, sys
tmp = os.environ["TMP"]
text = sys.stdin.read()
# a fix command runs the checkout the recorder runs from: the fixture names plain benchbar
text = text.replace(os.environ["CHECKOUT"] + "/benchbar ", "benchbar ")
for old, new in ((tmp + "/home/frappe-bench", "/home/akash/frappe-bench"), (tmp + "/home/empty", "/home/akash/empty"),
                 (tmp + "/home", "/home/akash"), (tmp + "/config", "/opt/benchbar/config"), (tmp, "/tmp/benchbar")):
    text = text.replace(old, new)
sys.stdout.write(text)'
}

# GENERATED: fixture file, then the command. One line each.
generated() {
  printf '%s\n' \
    "recorded/list.json|list --json" \
    "recorded/status.json|status --json --bench-dir $BENCH" \
    "cli/ports-check-clean.json|ports check --json --bench-dir $BENCH" \
    "cli/scan-empty.json|scan --json $HOME/empty"     "cli/envelope-read-failure.json|!status --for-agent --bench-dir $HOME/no-such-bench"     "cli/envelope-usage-error.jsonl|!install --bogus --jsonl"     "cli/envelope-run-refused.jsonl|!run --jsonl --bench-dir $BENCH -- bogus"
}

# GENERATED_TEXT: fixture file, then the command; commands that print no JSON (autostart) or are
# refused (lock write on a bench whose apps are not git checkouts, exit 1). A leading "!" allows a
# non zero exit. autostart is read twice, off first, then on again (a run leaves it on).
generated_text() {
  printf '%s\n' \
    "cli/autostart-off.txt|autostart --bench-dir $BENCH" \
    "cli/lock-write-refused.txt|!lock write --dry-run --bench-dir $BENCH"
}

# SHAPES: fixture file, then the command it stands for (a CLI of today prints
# every field of it, or says so below).
shapes() {
  printf '%s\n' \
    "cli/apps-list.json|app list --json --bench-dir $BENCH" \
    "cli/commands.json|commands --json" \
    "cli/doctor-ack.json|doctor --ack mariadb_utf8 --json --bench-dir $BENCH" \
    "cli/health-doctor.json|doctor --json --bench-dir $BENCH" \
    "cli/labs-list.json|labs list --json" \
    "cli/logs-first.json|logs --json -n5 --bench-dir $BENCH" \
    "cli/prerequisites.json|!doctor --prerequisites --json --bench-dir $BENCH" \
    "cli/prerequisites-fail.json|!doctor --prerequisites --json --bench-dir $BENCH" \
    "cli/up-services-only.jsonl|!up --services-only --json --bench-dir $BENCH" \
    "cli/ports-check-conflict.json|ports check --json --bench-dir $BENCH" \
    "cli/ports-check-running.json|ports check --json --bench-dir $BENCH" \
    "cli/profile-list.json|profile list --json" \
    "cli/profile-list-linux.json|profile list --json" \
    "cli/scan-list.json|list --json" \
    "cli/status-notices.json|status --json --bench-dir $BENCH" \
    "cli/status-not-ready.json|status --json --bench-dir $BENCH" \
    "cli/status-ready.json|status --json --bench-dir $BENCH" \
    "cli/status-ready-stale.json|status --json --bench-dir $BENCH" \
    "cli/status-pending-update.json|status --json --bench-dir $BENCH" \
    "cli/status-pending-add.json|status --json --bench-dir $BENCH" \
    "cli/snapshots-list.json|site snapshots linuxdev.localhost --json --bench-dir $BENCH" \
    "cli/lease-list.json|lease list --json" \
    "cli/history.json|history --json" \
    "cli/stats.json|stats --json --bench-dir $BENCH" \
    "cli/stats-stopped.json|stats --json --bench-dir $BENCH" \
    "cli/op-list.json|op list --json" \
    "cli/run-plan.json|run --site linuxdev.localhost --dry-run --json --bench-dir $BENCH -- migrate --skip-failing" \
    "cli/bench-gc-plan.json|bench gc --dry-run --json" \
    "cli/bench-remove-plan.json|bench remove $BENCH --dry-run --json" \
    "cli/bench-forget-plan.json|bench forget $BENCH --dry-run --json"
}

# paths FILE: one line per field path of a JSON document, arrays folded into
# "[]", and a mark (+) on a path whose value is null or an empty container (the
# mocks do not fill it, so a field below it cannot be judged)
paths() {
  python3 -I -c '
import json, sys
text = open(sys.argv[1]).read()
try:
    docs = [json.loads(text)]
except ValueError:
    # a JSON Lines stream (a fixture of a command that streams): every line that is an object
    docs = [json.loads(l) for l in text.splitlines() if l.strip().startswith("{")]
out = {}
def walk(v, p):
    if isinstance(v, dict):
        if not v and p: out[p] = True
        for k, x in v.items(): walk(x, p + "." + k if p else k)
    elif isinstance(v, list):
        if not v: out[p] = True
        for x in v: walk(x, p + "[]")
    else:
        if p: out[p] = v is None
for doc in docs:
    walk(doc, "")
for p, empty in sorted(out.items()):
    print(p + ("+" if empty else ""))
' "$1"
}

TMP_OUT="$TMP_DIR/recorded"
mkdir -p "$TMP_OUT"
status=0

# ---- generated files
while IFS='|' read -r file cmd; do
  # a leading "!" allows a non zero exit: a refusal prints its envelope all the same
  allow=0; [[ "$cmd" == "!"* ]] && { allow=1; cmd="${cmd#!}"; }
  # shellcheck disable=SC2086  # the command is one word per argument, none has a space
  ALLOW_EXIT="$allow" cli_out $cmd >"$TMP_OUT/new.json"
  python3 -I -c '
import json, sys
text = open(sys.argv[1]).read()
try:
    json.loads(text)
except ValueError:
    [json.loads(l) for l in text.splitlines() if l.strip()]' "$TMP_OUT/new.json" || fail "$file: the CLI did not print JSON"
  if [[ "$CHECK" == 1 ]]; then
    if ! cmp -s "$TMP_OUT/new.json" "$FIXTURES/$file"; then
      printf 'windows/tray/fixtures/%s differs from what the CLI prints now:\n' "$file" >&2
      diff -u "$FIXTURES/$file" "$TMP_OUT/new.json" >&2 || true
      status=1
    fi
  else
    cp "$TMP_OUT/new.json" "$FIXTURES/$file"
    printf 'wrote windows/tray/fixtures/%s\n' "$file"
  fi
done < <(generated)

# ---- generated text files: what the CLI prints, word for word, when it has no JSON
# no_header_box: the text without the run's header box (the lines from the first "+-" line to
# the next one)
no_header_box() {
  awk 'box == 0 && /^\+-.*-\+$/ { box = 1; next } box == 1 { if (/^\+-+\+$/) box = 2; next } { print }'
}

text_fixture() {
  local file="$1" new="$2"
  if [[ "$CHECK" == 1 ]]; then
    # the header box is as wide as its longest line, the bench path, which is not the same on every
    # runner (a macOS TMPDIR is long): the box is left out of the comparison, the tray does not read it
    if ! cmp -s <(no_header_box <"$new") <(no_header_box <"$FIXTURES/$file"); then
      printf 'windows/tray/fixtures/%s differs from what the CLI prints now:\n' "$file" >&2
      diff -u "$FIXTURES/$file" "$new" >&2 || true
      status=1
    fi
  else
    cp "$new" "$FIXTURES/$file"
    printf 'wrote windows/tray/fixtures/%s\n' "$file"
  fi
}
while IFS='|' read -r file cmd; do
  allow=0; [[ "$cmd" == "!"* ]] && { allow=1; cmd="${cmd#!}"; }
  run_fm autostart off --bench-dir "$BENCH"
  # shellcheck disable=SC2086
  ALLOW_EXIT="$allow" cli_out $cmd >"$TMP_OUT/new.txt"
  text_fixture "$file" "$TMP_OUT/new.txt"
done < <(generated_text)
run_fm autostart on --bench-dir "$BENCH"
cli_out autostart --bench-dir "$BENCH" >"$TMP_OUT/new.txt"
text_fixture cli/autostart-on.txt "$TMP_OUT/new.txt"

# ---- hand shaped files: every field of the fixture is still printed
while IFS='|' read -r file cmd; do
  [[ -f "$FIXTURES/$file" ]] || { printf 'windows/tray/fixtures/%s: no such file (fix SHAPES in tests/record-tray-fixtures.sh)\n' "$file" >&2; status=1; continue; }
  allow=0; [[ "$cmd" == "!"* ]] && { allow=1; cmd="${cmd#!}"; }
  # shellcheck disable=SC2086
  ALLOW_EXIT="$allow" cli_out $cmd >"$TMP_OUT/now.json"
  paths "$TMP_OUT/now.json" >"$TMP_OUT/now.paths"
  paths "$FIXTURES/$file" >"$TMP_OUT/fix.paths"
  missing="$(python3 -I -c '
import sys
now = {l.strip() for l in open(sys.argv[1]) if l.strip()}
fix = [l.strip() for l in open(sys.argv[2]) if l.strip()]
plain = {p.rstrip("+") for p in now}
unjudged = {p.rstrip("+") for p in now if p.endswith("+")}
for p in fix:
    empty = p.endswith("+")
    p = p.rstrip("+")
    if p in plain: continue
    # an empty array in the fixture (a bench that is ready waits on nothing) stands for the array the CLI fills when it has something to say
    if empty and p + "[]" in plain: continue
    # below a value the mocks leave empty: cannot be judged
    if any(p.startswith(u + ".") or p.startswith(u + "[]") for u in unjudged): continue
    print(p)
' "$TMP_OUT/now.paths" "$TMP_OUT/fix.paths")"
  if [[ -n "$missing" ]]; then
    printf 'windows/tray/fixtures/%s holds fields that "benchbar %s" no longer prints (renamed or removed?):\n' "$file" "${cmd%% --*}" >&2
    printf '%s\n' "$missing" | sed 's/^/  /' >&2
    status=1
  fi
done < <(shapes)

if [[ "$CHECK" == 1 ]]; then
  [[ "$status" == 0 ]] || { printf 'Run: bash tests/record-tray-fixtures.sh   (then review and commit windows/tray/fixtures)\n' >&2; exit 1; }
  printf 'tray fixtures match the CLI\n'
fi
exit "$status"
