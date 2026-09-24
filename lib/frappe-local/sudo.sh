#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# sudo.sh: one sudo prompt for a whole run.
#
# fl_sudo_begin REASON... says why sudo is needed, runs "sudo -v" once and
# keeps the credential fresh in the background until fl_sudo_end (or the
# process exits). The session is exported as FL_SUDO_SESSION=1 so the phase
# scripts started by "benchbar install" do not ask again: sudo's timestamp
# is shared by the processes of one terminal.
#
# Only two things ever need sudo: the wkhtmltopdf package (installer -pkg)
# and the /etc/hosts line. Nothing else in benchbar runs as root.

FL_SUDO_KEEPALIVE_PID=""
FL_SUDO_SESSION="${FL_SUDO_SESSION:-0}"

fl_sudo_available() {
  # true when a sudo credential is cached or can be obtained without a prompt
  sudo -n true 2>/dev/null
}

# fl_sudo_begin REASON...: returns 0 with a live sudo session, 1 when sudo
# could not be obtained (no terminal, wrong password, sudo missing).
fl_sudo_begin() {
  local reason
  [[ "${FL_DRY_RUN:-0}" == "1" ]] && { fl_info "dry-run: would ask for your password once (sudo) to: $*"; return 0; }
  [[ "$FL_SUDO_SESSION" == "1" ]] && return 0
  command -v sudo >/dev/null 2>&1 || { fl_warn "sudo is not available"; return 1; }
  fl_spinner_pause
  printf '\n  %ssudo%s is needed once for this run, to:\n' "$FL_BOLD" "$FL_RESET"
  for reason in "$@"; do printf '     %s %s\n' "$FL_G_PEND" "$reason"; done
  printf '     nothing else runs as root; the password is not stored\n'
  if ! sudo -v; then
    fl_warn "sudo was refused; the steps above are skipped and listed at the end"
    return 1
  fi
  FL_SUDO_SESSION=1
  export FL_SUDO_SESSION
  # Keep the timestamp fresh while this process lives. The loop owns no
  # stdio (a caller capturing our output must not wait for it), sleeps in
  # short slices so it notices the parent leaving, and dies on TERM.
  ( trap 'exit 0' TERM
    parent="$$"
    while kill -0 "$parent" 2>/dev/null; do
      sudo -n true 2>/dev/null || exit 0
      slice=0
      while [[ "$slice" -lt 10 ]]; do sleep 5; kill -0 "$parent" 2>/dev/null || exit 0; slice=$((slice + 1)); done
    done ) </dev/null >/dev/null 2>&1 &
  FL_SUDO_KEEPALIVE_PID="$!"
  fl_log "sudo session started (keepalive pid ${FL_SUDO_KEEPALIVE_PID})"
  return 0
}

fl_sudo_end() {
  [[ -n "$FL_SUDO_KEEPALIVE_PID" ]] || return 0
  kill "$FL_SUDO_KEEPALIVE_PID" 2>/dev/null || true
  wait "$FL_SUDO_KEEPALIVE_PID" 2>/dev/null || true
  FL_SUDO_KEEPALIVE_PID=""
  fl_log "sudo session ended"
}
