#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SCRIPTS=("$ROOT"/benchbar "$ROOT"/00-mac-system-deps.sh "$ROOT"/01-install-bench-and-site.sh "$ROOT"/02-background-service.sh "$ROOT"/lib/frappe-local/*.sh)

bash -n "${SCRIPTS[@]}"

for t in test-ui test-templates test-shellrc test-platform test-run test-version-policy test-bench-flow test-runner test-process test-service test-migrate test-doctor test-repair test-cli test-phases; do
  [[ -f "$ROOT/tests/$t.sh" ]] || continue
  bash "$ROOT/tests/$t.sh"
done

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "${SCRIPTS[@]}" "$ROOT"/tests/*.sh "$ROOT"/tests/lib/*.sh "$ROOT"/tests/mocks/bin/*
  printf 'shellcheck: ok\n'
else
  printf 'shellcheck not installed; skipped lint (brew install shellcheck)\n'
fi
