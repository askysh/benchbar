#!/usr/bin/env bash
# shellcheck disable=SC2034  # FL_SUDO_PW is read by sudo.sh
#
# sudo-env.sh: takes BENCHBAR_SUDO_PASSWORD out of the environment. Sourced
# before anything else by benchbar and by the phase scripts that run sudo.
#
# BENCHBAR_SUDO=env is how a program without a terminal (the Windows tray)
# gives a Linux run the sudo password. The password moves into a plain shell
# variable (FL_SUDO_PW, never exported) and the environment variable is
# unset at once, so no child (bench, git, npm, a mock, a package script)
# inherits it. A phase script has no password in its environment either:
# the parent hands it over one line on an inherited pipe, FL_SUDO_PW_FD
# names the descriptor, and the child reads it once and closes it.
#
# xtrace is switched off around the reads, so "bash -x benchbar" does not
# print the value. sudo.sh holds the rest (the sudo function, the checks).

FL_SUDO_PW=""
FL__SUDO_XT=0
case "$-" in *x*) FL__SUDO_XT=1; { set +x; } 2>/dev/null ;; esac
if [[ -n "${BENCHBAR_SUDO_PASSWORD+x}" || -n "${FL_SUDO_PW_FD+x}" ]]; then
  if [[ "${BENCHBAR_SUDO:-}" == "env" ]]; then
    if [[ -n "${BENCHBAR_SUDO_PASSWORD:-}" ]]; then
      FL_SUDO_PW="$BENCHBAR_SUDO_PASSWORD"
    elif [[ "${FL_SUDO_PW_FD:-}" =~ ^([4-9]|[1-9][0-9])$ ]]; then
      IFS= read -r -u "$FL_SUDO_PW_FD" FL_SUDO_PW 2>/dev/null || true
    fi
  fi
  # the pipe is spent either way: closed here, so nothing started later inherits it
  if [[ "${FL_SUDO_PW_FD:-}" =~ ^([4-9]|[1-9][0-9])$ ]]; then eval "exec ${FL_SUDO_PW_FD}<&-" 2>/dev/null || true; fi
  unset BENCHBAR_SUDO_PASSWORD FL_SUDO_PW_FD
fi
if [[ "$FL__SUDO_XT" == "1" ]]; then set -x; fi
unset FL__SUDO_XT
