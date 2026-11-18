#!/usr/bin/env bash
# LAN sharing gateway: the pure Node modules (path policy, CPace room-password join,
# rate limits, device store, activity log, error pages) and the gateway server
# itself (mTLS, join, seats, sign-in, proxy, control socket, deadline) via node:test.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -euo pipefail

if ! command -v node >/dev/null 2>&1; then
  printf 'SKIP: node not found\n'
  printf 'test-share-gateway: ok (SKIPPED: node not found)\n'
  exit 0
fi

cd "$ROOT"
# A test that hangs ends after 120 s with its own name, not at the runner's 600 s limit with
# nothing but "Promise resolution is still pending". The slowest test takes about 2 s. Node
# before 20.11 has no --test-timeout, so ask it first.
timeout_flag=()
if node --help 2>/dev/null | grep -q -- '--test-timeout'; then timeout_flag=(--test-timeout=120000); fi
node --test ${timeout_flag[@]+"${timeout_flag[@]}"} tests/share/*.test.js
printf 'test-share-gateway: ok\n'
