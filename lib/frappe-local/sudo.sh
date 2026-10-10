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
# Only two things ever need sudo: the wkhtmltopdf package (installer -pkg)
# and the /etc/hosts line. Nothing else in benchbar runs as root, and
# fl_sudo_drop ("sudo -k") ends the credential as soon as those two are
# done, before brew, pip, npm, yarn or bench run any third party code on
# the same terminal: a package's install script must not find a cached
# sudo. "benchbar install" does the two steps first and drops; a phase
# script that needs sudo on its own asks itself and drops after.

# BENCHBAR_SUDO=gui (the BenchBar app sets it): the two root steps run
# through osascript's administrator dialog instead of sudo, see fl_root_run.
# Any other value is the terminal path. FL_OSASCRIPT is for the tests.
FL_OSASCRIPT="${FL_OSASCRIPT:-/usr/bin/osascript}"
fl_sudo_gui() { [[ "${BENCHBAR_SUDO:-}" == "gui" ]]; }

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
  # a macOS dialog asks, once per step, when the step runs (fl_root_run)
  fl_sudo_gui && return 0
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
  if ! sudo -v; then
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
  fl_sudo_gui && return 0
  fl_sudo_end
  if [[ "$FL_SUDO_SESSION" == "1" ]]; then
    sudo -k 2>/dev/null || true
    fl_log "sudo credential dropped (sudo -k)"
  fi
  FL_SUDO_SESSION=0
  export FL_SUDO_SESSION
}

# fl_root_run REASON SCRIPT ARG...: SCRIPT (bash source) runs as root with
# ARG... as its $1..., behind one macOS password dialog titled REASON.
# Returns 0 when the script succeeded, 2 when the person cancelled the
# dialog (the same reason is not asked again in this run), 1 otherwise;
# FL_ROOT_OUTPUT holds what the script or osascript said.
#
# The command line is /bin/bash -c 'SCRIPT' benchbar-root 'ARG'..., every
# word in single quotes (fl_sq) and handed to AppleScript as an argument,
# never inside an AppleScript string, so only shell quoting matters. The
# script names every tool by its absolute path. benchbar never sees the
# password and there is no cached credential afterwards.
FL_ROOT_CANCELLED=""
FL_ROOT_OUTPUT=""
fl_root_was_cancelled() { case " $FL_ROOT_CANCELLED " in *" ${1// /_} "*) return 0 ;; esac; return 1; }
fl_root_run() {
  local reason="$1" script="$2" cmdline arg out err code=0
  shift 2
  if fl_root_was_cancelled "$reason"; then FL_ROOT_OUTPUT="the password dialog was cancelled earlier in this run"; return 2; fi
  cmdline="/bin/bash -c $(fl_sq "$script") benchbar-root"
  for arg in "$@"; do cmdline="${cmdline} $(fl_sq "$arg")"; done
  out="$(mktemp "${TMPDIR:-/tmp}/benchbar-root.XXXXXX")"
  err="$(mktemp "${TMPDIR:-/tmp}/benchbar-root.XXXXXX")"
  fl_log "run: osascript, administrator dialog: ${reason}"
  "$FL_OSASCRIPT" -e 'on run argv' -e 'do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges' -e 'end run' -- "$cmdline" "$reason" </dev/null >"$out" 2>"$err" 3>&- || code=$?
  FL_ROOT_OUTPUT="$(cat "$out" "$err" 2>/dev/null)"
  fl_log_file_append "$out"
  fl_log_file_append "$err"
  rm -f "$out" "$err"
  [[ "$code" -ne 0 ]] || return 0
  case "$FL_ROOT_OUTPUT" in
    *"(-128)"*) FL_ROOT_CANCELLED="${FL_ROOT_CANCELLED} ${reason// /_}"; return 2 ;;
  esac
  return 1
}
