#!/usr/bin/env bash
# LAN sharing gateway: the pure Node modules (path policy, CPace room-password join,
# rate limits, device store, activity log, error pages) and the gateway server
# itself (mTLS, join, seats, sign-in, proxy, control socket, deadline) via node:test.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -euo pipefail

if ! command -v node >/dev/null 2>&1; then
  printf 'SKIP: node not found\n'
  exit 0
fi

cd "$ROOT"
node --test tests/share/*.test.js
printf 'test-share-gateway: ok\n'
