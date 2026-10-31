#!/usr/bin/env bash
# benchbar site restore: a backup set into an existing site (backed up
# first) or a new one, the plan and its token, --no-migrate, the
# --before-migrate hook, the encryption key, the default site, and the
# refusals. Run on the macOS platform here and as Linux in test-site-restore-2.
# shellcheck source=tests/lib/site-restore-suite.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/site-restore-suite.sh"

suite mac fresh.localhost

printf 'test-site-restore: ok\n'
