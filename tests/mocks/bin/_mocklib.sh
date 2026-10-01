#!/usr/bin/env bash
# shared by the mocks: append a call record
mock_log() { printf '%s %s\n' "$(basename "$0")" "$*" >>"${MOCK_LOG:-/dev/null}"; }
# programs a mock starts are the mock's, not benchbar's (test-status-cost counts benchbar's)
export BENCHBAR_TEST_MOCK=1
