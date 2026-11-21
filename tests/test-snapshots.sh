#!/usr/bin/env bash
# benchbar site snapshot, snapshots and rollback: the snapshot kept out of frappe's pruning, the
# list with its app comparison, the rollback plan and its token, the snapshot of the current state
# first, migrate only across an app change, the default site, drop and retention. Run on the macOS
# platform here and as Linux in test-snapshots-2.
# shellcheck source=tests/lib/snapshots-suite.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/snapshots-suite.sh"

suite mac

printf 'test-snapshots: ok\n'
