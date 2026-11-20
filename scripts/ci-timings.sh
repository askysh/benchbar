#!/usr/bin/env bash
#
# ci-timings.sh: refresh tests/timings.tsv (the seconds per test) from a CI run.
#
#   scripts/ci-timings.sh RUN_ID            print the new table (needs gh, signed in)
#   scripts/ci-timings.sh --write RUN_ID    write it to tests/timings.tsv
#   scripts/ci-timings.sh FILE              from a saved `gh run view RUN_ID --log`
#   scripts/ci-timings.sh -                 the same from stdin
#
# run-tests.sh prints "--- ok: NAME (Ns)" for every test. Pick a green run of the
# full suite (a push to next-release or the nightly). The Linux column averages
# the bash 5 and the bash 3.2 container legs. A test the run did not time keeps
# the seconds it had; the header lines of the file stay as they are.
# TIMINGS_FILE names another table (the tests use it).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TABLE="${TIMINGS_FILE:-$ROOT/tests/timings.tsv}"
write=0
if [[ "${1:-}" == "--write" ]]; then write=1; shift; fi
[[ "$#" -eq 1 ]] || { sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1; }
src="$1"
if [[ "$src" == "-" ]]; then
  log="$(cat)"
elif [[ -f "$src" ]]; then
  log="$(cat "$src")"
elif [[ "$src" =~ ^[0-9]+$ ]]; then
  log="$(gh run view "$src" --log)"
else
  printf 'ci-timings: %s is neither a file nor a run id\n' "$src" >&2; exit 1
fi

# one line per test: leg ("mac" or "linux"), name, seconds. The job name starts each log line.
rows="$(printf '%s\n' "$log" | awk -F'\t' '
  $1 ~ /^CLI tests \(macOS/ { leg = "mac" }
  $1 ~ /^CLI tests \((Linux|bash 3\.2)/ { leg = "linux" }
  $1 ~ /^CLI tests \(/ && match($3, /--- ok: [^ ]+ \([0-9]+s\)/) {
    s = substr($3, RSTART + 8, RLENGTH - 8)
    name = s; sub(/ .*/, "", name)
    secs = s; sub(/^[^(]*\(/, "", secs); sub(/s\)$/, "", secs)
    print leg, name, secs
  }')"
[[ -n "$rows" ]] || { printf 'ci-timings: no "--- ok: NAME (Ns)" lines in that log\n' >&2; exit 1; }

# the new table: the header lines of the old one, then one row per test, by name. A column
# the run timed is the average of its legs; one it did not time keeps the old value.
old=""
[[ -f "$TABLE" ]] && old="$(cat "$TABLE")"
new="$(
  printf '%s\n' "$old" | grep '^#' || true
  {
    printf '%s\n' "$old" | awk -F'\t' '$1 != "" && $1 !~ /^#/ { print "old", $1, $2, $3 }'
    printf '%s\n' "$rows" | awk '{ print "new", $1, $2, $3 }'
  } | awk '
    $1 == "old" { seen[$2] = 1; if (!($2 in mac)) mac[$2] = $3; if (!($2 in linux)) linux[$2] = $4 }
    $1 == "new" { seen[$3] = 1; sum[$2, $3] += $4; n[$2, $3]++ }
    END {
      for (t in seen) {
        m = (("mac", t) in n) ? sprintf("%d", sum["mac", t] / n["mac", t] + 0.5) : mac[t]
        l = (("linux", t) in n) ? sprintf("%d", sum["linux", t] / n["linux", t] + 0.5) : linux[t]
        if (m == "") m = "-"
        if (l == "") l = "-"
        printf "%s\t%s\t%s\n", t, m, l
      }
    }' | LC_ALL=C sort
)"
if [[ "$write" == 1 ]]; then
  printf '%s\n' "$new" >"$TABLE.new" && mv "$TABLE.new" "$TABLE"
  printf 'ci-timings: wrote %s\n' "$TABLE" >&2
else
  printf '%s\n' "$new"
fi
