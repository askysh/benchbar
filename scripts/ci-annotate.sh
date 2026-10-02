#!/usr/bin/env bash
#
# ci-annotate.sh: turn the compiler errors and failed Swift tests in an
# xcodebuild log into GitHub annotations, so a failure shows on the pull
# request and through the checks API without opening the log.
#
#   scripts/ci-annotate.sh macos/build/build.log macos/build/test.log
#
# Prints at most 40 annotations. Exits 0; the caller decides the outcome.

set -uo pipefail

[[ $# -gt 0 ]] || { echo "usage: ci-annotate.sh LOG..." >&2; exit 0; }
logs=()
for f in "$@"; do [[ -f "$f" ]] && logs+=("$f"); done
[[ ${#logs[@]} -gt 0 ]] || exit 0
root="${GITHUB_WORKSPACE:-$(pwd)}"

# "/path/File.swift:12:5: error: message"
grep -h -E '^/.+\.swift:[0-9]+:[0-9]+: error: ' "${logs[@]}" | sort -u | head -n 30 |
  while IFS= read -r line; do
    file="${line%%:*}"
    rest="${line#*:}"
    row="${rest%%:*}"; rest="${rest#*:}"
    col="${rest%%:*}"; rest="${rest#*: error: }"
    printf '::error file=%s,line=%s,col=%s::%s\n' "${file#"$root"/}" "$row" "$col" "$rest"
  done

# Swift Testing: "✘ Test name() recorded an issue at File.swift:12:3: Expectation failed: ..."
grep -h -E '^✘ Test .* recorded an issue' "${logs[@]}" | sort -u | head -n 10 |
  while IFS= read -r line; do
    printf '::error title=Swift test failed::%s\n' "${line#✘ }"
  done
exit 0
