#!/usr/bin/env bash
# benchbar site move, the Linux half of test-site-move: the same suite with no hosts line.
# shellcheck source=tests/lib/site-move-suite.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/site-move-suite.sh"

use_linux
suite linux

printf 'test-site-move-2: ok\n'
