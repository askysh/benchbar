#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# sudo.sh: one sudo prompt for a whole run.
#
# fl_sudo_begin REASON... says why sudo is needed, runs "sudo -v" once and
# keeps the credential fresh in the background until fl_sudo_end (or the
# process exits). The session is exported as FL_SUDO_SESSION=1 so a function
# that needs sudo later in the same run does not ask again.
#
# On macOS only two things ever need sudo: the wkhtmltopdf package
# (installer -pkg) and the /etc/hosts line. On Linux: apt (the packages and
# the wkhtmltopdf .deb), the MariaDB admin step, its drop-in and restart, and
# starting a stopped mariadb or redis-server (platform-linux.sh). Nothing
# else in benchbar runs as root, and fl_sudo_drop ("sudo -k") ends the
# credential as soon as those steps are done, before brew, pip, npm, yarn,
# uv, fnm or bench run any third party code on the same terminal: a
# package's install script must not find a cached sudo. "benchbar install"
# does those steps first and drops; a phase script that needs sudo on its
# own asks itself and drops after.

FL_SUDO_KEEPALIVE_PID=""
FL_SUDO_SESSION="${FL_SUDO_SESSION:-0}"
# 1 once sudo was refused in this run: later steps skip instead of asking again
FL_SUDO_REFUSED="${FL_SUDO_REFUSED:-0}"

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
  if [[ "$FL_SUDO_REFUSED" == "1" ]]; then
    fl_warn "sudo was refused earlier in this run; not asking again for: $*"
    return 1
  fi
  command -v sudo >/dev/null 2>&1 || { fl_warn "sudo is not available"; return 1; }
  fl_spinner_pause
  printf '\n  %ssudo%s is needed once for this run, to:\n' "$FL_BOLD" "$FL_RESET"
  for reason in "$@"; do printf '     %s %s\n' "$FL_G_PEND" "$reason"; done
  printf '     nothing else runs as root; the password is not stored\n'
  # A NOPASSWD rule needs no prompt, but "sudo -v" still asks for a password
  # when another rule for the same user wants one (sudo's verifypw=all, the
  # default with Ubuntu's %sudo line). "-k" with a command ignores a cached
  # credential, so this succeeds only when no password is needed at all.
  if sudo -n -k true 2>/dev/null; then
    fl_log "sudo: no password needed (NOPASSWD)"
  elif ! sudo -v; then
    FL_SUDO_REFUSED=1
    export FL_SUDO_REFUSED
    fl_warn "sudo was refused; the steps above are skipped, and this run will not ask again"
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

# fl_sudo_drop: the privileged steps are done. Stops the keepalive and
# invalidates the cached credential (sudo -k), so nothing that runs after
# this, in this process or a child, can use sudo without a password. A run
# that never obtained sudo leaves sudo alone.
fl_sudo_drop() {
  fl_sudo_end
  if [[ "$FL_SUDO_SESSION" == "1" ]]; then
    sudo -k 2>/dev/null || true
    fl_log "sudo credential dropped (sudo -k)"
  fi
  FL_SUDO_SESSION=0
  export FL_SUDO_SESSION
}
