#!/usr/bin/env bash
# The Windows tray's recorded CLI output (windows/tray/fixtures) still matches the
# CLI of this checkout: the generated files are what the CLI prints now, and the
# hand shaped ones hold no field it dropped. Fix a failure with
# `bash tests/record-tray-fixtures.sh` (see its header).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$ROOT/tests/record-tray-fixtures.sh" --check
