#!/usr/bin/env bash
#
# 02-background-service.sh
#
# Phase 2 for local Frappe/ERPNext development on macOS: run the bench in
# the background under one launchd agent. Thin wrapper around
# "frappe-mac service" so the phase scripts keep their numbering.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/frappe-mac" service "$@"
