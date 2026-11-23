#!/usr/bin/env bash
# benchbar site move: a site to another registered bench. The plan and its errors (the default site, an app
# the target lacks, an existing name, the same bench, an unknown bench, a lease), the stale token, the order of
# the steps, a failed check that leaves the source alone, the backups that stay. Linux in test-site-move-2.
# shellcheck source=tests/lib/site-move-suite.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/site-move-suite.sh"

suite mac

printf 'test-site-move: ok\n'
