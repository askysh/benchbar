#!/usr/bin/env bash
#
# ci-timings.sh: print fresh TEST_SECS tables for tests/run-tests.sh from a CI run.
#
#   scripts/ci-timings.sh RUN_ID      the logs of that run (needs gh, signed in)
#   scripts/ci-timings.sh FILE        a saved `gh run view RUN_ID --log`
#   scripts/ci-timings.sh -           the same from stdin
#
# run-tests.sh prints "--- ok: NAME (Ns)" for every test. Pick a green run of the
# full suite (a push to next-release or the nightly), run this, and paste the two
# blocks over TEST_SECS_MAC and TEST_SECS_LINUX in tests/run-tests.sh. The Linux
# table averages the bash 5 and the bash 3.2 container legs; a test no leg ran
# is left out (it counts as 10).

set -euo pipefail

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

table() {
  printf '%s\n' "$rows" | awk -v leg="$1" -v var="$2" '
    $1 == leg { sum[$2] += $3; n[$2]++ }
    END {
      for (t in sum) printf "%d %s\n", sum[t] / n[t] + 0.5, t
    }' | sort -k1,1nr -k2,2 | awk -v var="$2" '
    { cell[NR] = $2 "=" $1 }
    END {
      printf "%s=\"", var
      for (i = 1; i <= NR; i++) {
        if (i > 1) printf (i % 6 == 1) ? "\n" : " "
        printf "%s", cell[i]
      }
      printf "\"\n"
    }'
}

table mac TEST_SECS_MAC
printf '\n'
table linux TEST_SECS_LINUX
