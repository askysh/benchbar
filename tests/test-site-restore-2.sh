#!/usr/bin/env bash
# benchbar site restore, the Linux half of test-site-restore: the same suite
# with the password file in place of the Keychain and no hosts line.
# shellcheck source=tests/lib/site-restore-suite.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/site-restore-suite.sh"

use_linux
suite linux fresh.localhost

printf 'test-site-restore-2: ok\n'
