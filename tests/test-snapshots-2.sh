#!/usr/bin/env bash
# benchbar site snapshot, snapshots and rollback, the Linux half of test-snapshots: the same suite
# with the password file in place of the Keychain and no hosts line.
# shellcheck source=tests/lib/snapshots-suite.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/snapshots-suite.sh"

use_linux
suite linux

printf 'test-snapshots-2: ok\n'
