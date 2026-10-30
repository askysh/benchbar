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
# (installer -pkg, with Rosetta 2 installed by the same root script when the
# package needs it and it is missing) and the /etc/hosts line. On Linux: apt (the packages and
# the wkhtmltopdf .deb), the MariaDB admin step, its drop-in and restart, and
# starting a stopped mariadb or redis-server (platform-linux.sh). Nothing
# else in benchbar runs as root, and fl_sudo_drop ("sudo -k") ends the
# credential as soon as those steps are done, before brew, pip, npm, yarn,
# uv, fnm or bench run any third party code on the same terminal: a
# package's install script must not find a cached sudo. "benchbar install"
# does those steps first and drops; a phase script that needs sudo on its
# own asks itself and drops after.

# BENCHBAR_SUDO=gui (the BenchBar app sets it): the two root steps run
# through osascript's administrator dialog instead of sudo, see fl_root_run.
# BENCHBAR_SUDO=env (Linux, the Windows tray sets it) with the password in
# BENCHBAR_SUDO_PASSWORD: see "BENCHBAR_SUDO=env" at the end of this file.
# Any other value is the terminal path. FL_OSASCRIPT is for the tests.
FL_OSASCRIPT="${FL_OSASCRIPT:-/usr/bin/osascript}"
# macOS only: Linux has no osascript, and BENCHBAR_SUDO is ignored there
fl_sudo_gui() { [[ "${BENCHBAR_SUDO:-}" == "gui" && "${FL_PLATFORM:-}" != "linux" ]]; }

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
  # no terminal, the password in the environment (Linux)
  if fl_sudo_env_has_password; then fl_sudo_env_begin "$@"; return $?; fi
  [[ "$FL_SUDO_SESSION" == "1" ]] && return 0
  # install --json and adopt --json without the dialogs, and any run under
  # BENCHBAR_NONINTERACTIVE=1 (sudo -v would read the terminal and wait):
  # nothing can type a password, so a cached credential or a NOPASSWD rule is
  # used and anything else skips the steps (with their manual command), as a
  # cancelled dialog does
  if [[ "${FL_JSONL:-0}" == "1" ]] || fl_noninteractive; then
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      FL_SUDO_SESSION=1
      export FL_SUDO_SESSION
      # the later plain sudo calls (apt on Linux runs for minutes) must not
      # outlive the cached timestamp and prompt on the terminal
      fl__sudo_keepalive
      return 0
    fi
    FL_SUDO_REFUSED=1
    export FL_SUDO_REFUSED
    if fl_sudo_env; then
      fl_warn "sudo needs a password, BENCHBAR_SUDO=env has none (set BENCHBAR_SUDO_PASSWORD) and this run cannot ask for one; the steps that need it are skipped: $*"
    else
      fl_warn "sudo needs a password and this run cannot ask for one; the steps that need it are skipped: $*"
    fi
    return 1
  fi
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
  fl__sudo_keepalive
  return 0
}

# Keep the timestamp fresh while this process lives. The loop owns no
# stdio and not fd 3, the JSON stream (a reader must not wait for it), sleeps in
# short slices so it notices the parent leaving, and dies on TERM.
fl__sudo_keepalive() {
  ( trap 'exit 0' TERM
    parent="$$"
    while kill -0 "$parent" 2>/dev/null; do
      sudo -n true 2>/dev/null || exit 0
      slice=0
      while [[ "$slice" -lt 10 ]]; do sleep 5; kill -0 "$parent" 2>/dev/null || exit 0; slice=$((slice + 1)); done
    done ) </dev/null >/dev/null 2>&1 3>&- &
  FL_SUDO_KEEPALIVE_PID="$!"
  fl_log "sudo session started (keepalive pid ${FL_SUDO_KEEPALIVE_PID})"
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
FL_ROOT_FAILED=""
FL_ROOT_OUTPUT=""
# FL_ROOT_KIND names the kind of step a dialog is for (hosts: all the lines,
# whoever asks); without it the dialog's title is the kind. A cancelled or
# failed kind is not asked for again in the same run.
FL_ROOT_KIND=""
fl_root_was_cancelled() { case " $FL_ROOT_CANCELLED " in *" ${1// /_} "*) return 0 ;; esac; return 1; }
fl_root_was_failed() { case " $FL_ROOT_FAILED " in *" ${1// /_} "*) return 0 ;; esac; return 1; }
fl_root_run() {
  local reason="$1" script="$2" key cmdline arg out err code=0
  shift 2
  key="${FL_ROOT_KIND:-$reason}"
  if fl_root_was_cancelled "$key"; then FL_ROOT_OUTPUT="the password dialog was cancelled earlier in this run"; return 2; fi
  # a step that failed behind its dialog is not tried again by a later pass (the service step)
  if fl_root_was_failed "$key"; then FL_ROOT_OUTPUT="this step failed earlier in this run"; return 1; fi
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
    *"(-128)"*) FL_ROOT_CANCELLED="${FL_ROOT_CANCELLED} ${key// /_}"; return 2 ;;
  esac
  FL_ROOT_FAILED="${FL_ROOT_FAILED} ${key// /_}"
  return 1
}

# ---------------------------------------------------------------- BENCHBAR_SUDO=env
#
# For a program that cannot type into a terminal (the Windows tray starting
# benchbar through wsl.exe). The caller sets BENCHBAR_SUDO=env and passes the
# user's password in BENCHBAR_SUDO_PASSWORD. sudo-env.sh took it out of the
# environment at startup; it lives only in FL_SUDO_PW, a shell variable that
# is never exported, so no child process and no xtrace line ever has it.
#
# "sudo" becomes a shell function for this process (and its subshells, not
# for programs it starts). Before each call it tries "sudo -n true"; when
# that fails it validates the password with "sudo -S -p '' -v", the password
# on stdin through a process substitution running the printf builtin (never
# argv, never a file),
# and then runs the real sudo from the same shell, so a ticket that sudo ties
# to the parent process (no terminal) is found. The command keeps its own
# stdin. The run log gets "run:" lines of commands and none carries the
# password.
#
# Linux only: on a Mac BENCHBAR_SUDO=env is ignored.
fl_sudo_env() { [[ "${BENCHBAR_SUDO:-}" == "env" && "${FL_PLATFORM:-}" == "linux" ]]; }
# (the length test, not -n "$FL_SUDO_PW": an xtrace line would print the value)
fl_sudo_env_has_password() { fl_sudo_env && [[ -n "${FL_SUDO_PW:+x}" ]]; }

# fl__sudo_env_feed: validate the password with the real sudo. xtrace is off
# while the value is expanded.
fl__sudo_env_feed() {
  local xt=0 code=0
  case "$-" in *x*) xt=1; { set +x; } 2>/dev/null ;; esac
  # not "printf | sudo": every pipeline element is a forked subshell, and bash
  # 3.2 runs the command in a child of it, so the parent of sudo would be that
  # subshell and not this shell, and the ticket (tied to the parent pid without
  # a terminal) would be lost for the call that follows
  "$FL_SUDO_BIN" -S -p '' -v 0< <(printf '%s\n' "$FL_SUDO_PW") >/dev/null 2>&1 || code=$?
  if [[ "$xt" == "1" ]]; then set -x; fi
  return "$code"
}

# fl__sudo_env_call ARGS...: what the sudo function runs
fl__sudo_env_call() {
  case "${1:-}" in
    -k|-K|-V|--version|-h|--help) "$FL_SUDO_BIN" "$@"; return $? ;;
  esac
  if ! "$FL_SUDO_BIN" -n true 2>/dev/null; then
    fl__sudo_env_feed || { printf 'sudo: the password from BENCHBAR_SUDO_PASSWORD was not accepted\n' >&2; return 1; }
  fi
  # never the last command: bash may exec a last command in place of a
  # $(...) subshell, and sudo's parent would then not be the shell that
  # holds the ticket
  local code=0
  "$FL_SUDO_BIN" "$@" || code=$?
  return "$code"
}

# fl__sudo_env_wrap: define the sudo function. The real sudo is called by its
# path (found before the function exists), not as "command sudo": bash 3.2 with
# "set -e" ends the shell when "command CMD" fails, even in "if", "!" or "||".
fl__sudo_env_wrap() {
  FL_SUDO_BIN="$(type -P sudo 2>/dev/null || true)"
  FL_SUDO_BIN="${FL_SUDO_BIN:-/usr/bin/sudo}"
  # shellcheck disable=SC2329  # the callers run it as "sudo"
  sudo() { fl__sudo_env_call "$@"; }
}

# fl_sudo_env_forget: the privileged steps are done. The password and the
# function go, so nothing later in this process can use sudo either.
fl_sudo_env_forget() {
  FL_SUDO_PW=""
  unset -f sudo 2>/dev/null || true
}

# fl_sudo_env_wrong: the password was refused. The id is stable (the done line).
fl_sudo_env_wrong() {
  FL_ERROR_ID="sudo_password_wrong"
  fl_die "sudo did not accept the password in BENCHBAR_SUDO_PASSWORD. Nothing was changed." \
    "Run the command again with the sudo password of $(id -un 2>/dev/null || printf 'this user')."
}

# fl_sudo_env_check: 0 when sudo accepts the password, 2 when there is no
# sudo. "sudo -k" first, so a credential cached earlier cannot make a wrong
# password pass.
fl_sudo_env_check() {
  command -v sudo >/dev/null 2>&1 || return 2
  "$FL_SUDO_BIN" -k 2>/dev/null || true
  fl__sudo_env_feed
}

# fl_sudo_env_begin REASON...: fl_sudo_begin with a password in env mode
fl_sudo_env_begin() {
  local code=0
  fl__sudo_env_wrap
  [[ "$FL_SUDO_SESSION" == "1" ]] && return 0
  fl_sudo_env_check || code=$?
  case "$code" in
    0) ;;
    2) fl_warn "sudo is not available"; return 1 ;;
    *) fl_sudo_env_wrong ;;
  esac
  FL_SUDO_SESSION=1
  export FL_SUDO_SESSION
  fl_log "sudo session started (password from BENCHBAR_SUDO_PASSWORD)"
  return 0
}

# fl_sudo_env_preflight: a command that may run sudo checks the password once
# before anything changes, so a wrong one fails up front with its id
fl_sudo_env_preflight() {
  local code=0
  fl_sudo_env_has_password || return 0
  [[ "${FL_DRY_RUN:-0}" != "1" ]] || return 0
  fl__sudo_env_wrap
  fl_sudo_env_check || code=$?
  case "$code" in
    0|2) return 0 ;;
    *) fl_sudo_env_wrong ;;
  esac
}

# fl__sudo_env_emit: the password, one line, for a phase script's pipe
fl__sudo_env_emit() {
  { set +x; } 2>/dev/null
  printf '%s\n' "$FL_SUDO_PW"
}
