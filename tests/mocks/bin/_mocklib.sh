#!/usr/bin/env bash
# shared by the mocks: append a call record
mock_log() {
  local name
  name="$(basename "$0")"
  printf '%s %s\n' "$name" "$*" >>"${MOCK_LOG:-/dev/null}"
  # MOCK_ENV_DUMP=1: record which password variables this mock saw in its
  # environment (names only), so a test can assert a child never got them
  if [[ -n "${MOCK_ENV_DUMP:-}" && -d "${MOCK_STATE:-/nonexistent}" ]]; then
    mkdir -p "${MOCK_STATE}/env"
    { printf 'call: %s\n' "$*"; env | grep -o -E '^(MARIADB_ROOT_PASSWORD|ADMIN_PASSWORD)=' || true; } >>"${MOCK_STATE}/env/${name}"
  fi
  # MOCK_SUDO_PROBE=1: third party code trying "sudo -n true" (ok or denied),
  # so a test can assert that no cached credential was usable when it ran
  if [[ -n "${MOCK_SUDO_PROBE:-}" && -d "${MOCK_STATE:-/nonexistent}" && "$name" != "sudo" ]]; then
    mkdir -p "${MOCK_STATE}/sudo_probe"
    if MOCK_NO_LOG=1 sudo -n true 2>/dev/null; then printf 'ok\n'; else printf 'denied\n'; fi >>"${MOCK_STATE}/sudo_probe/${name}"
  fi
}
# programs a mock starts are the mock's, not benchbar's (test-status-cost counts benchbar's)
export BENCHBAR_TEST_MOCK=1
