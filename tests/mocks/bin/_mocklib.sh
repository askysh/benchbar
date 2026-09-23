#!/usr/bin/env bash
# shared by the mocks: append a call record
mock_log() { printf '%s %s\n' "$(basename "$0")" "$*" >>"${MOCK_LOG:-/dev/null}"; }
