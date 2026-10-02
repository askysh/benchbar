#!/usr/bin/env bash
#
# install-kind.sh: how this CLI was installed, and the path it records for
# itself. Decided from SCRIPT_DIR as a string, with no process: status runs
# this on every poll of the app.
#
#   homebrew  SCRIPT_DIR is <prefix>/opt/benchbar/libexec (the formula's
#             bin/benchbar wrapper runs that path) or
#             <prefix>/Cellar/benchbar/<version>/libexec (a symlink followed
#             into the keg)
#   managed   ~/.local/share/benchbar, the checkout of the one line installer
#   app       BenchBar.app/Contents/Resources/cli, the copy the app ships
#   checkout  another git checkout, such as ./benchbar in a clone
#   other     anything else
#
# FL_SELF is the benchbar that generated files and printed commands name.
# Under Homebrew it is <prefix>/opt/benchbar/bin/benchbar, which brew
# upgrade keeps: the Cellar path changes with every version and brew
# cleanup deletes it. FL_SELF_DIR is the folder of its files by the same
# stable path, and FL_SELF_PREFIX the Homebrew prefix (empty for the other
# kinds). For every other kind FL_SELF and FL_SELF_DIR stay what they were
# before 0.7.0, SCRIPT_DIR's, so an upgrade rewrites no helper block.
# SCRIPT_DIR remains the folder this run reads its lib/, templates/ and
# config/ from.
#
# The app's copy records ~/.local/state/benchbar/bin/benchbar, the link
# BenchBar.app keeps to it (FL_APP_CLI), when that link leads here, and
# its own path otherwise (a build that runs from Xcode's folder). Sparkle
# and brew replace the app in place, so the link outlives every update.
#
# Hand off: when BenchBar.app is installed, it owns the CLI. Homebrew's and
# the installer's copy then run the app's (exec through FL_APP_CLI), so
# every caller gets the CLI of the app's version, whichever channel updated
# what. A checkout never hands off (a developer runs their own branch), nor
# does anything when BENCHBAR_NO_HANDOFF is set. A missing or dangling link
# (no app, or the app in the Trash) means this copy runs itself.
#
# Nothing else comes from the environment on purpose: a variable the
# formula's wrapper set would reach every child, a nested benchbar of
# another kind included. BENCHBAR_HANDOFF_FROM, set only for the exec
# below, is read and unset right here, so it stops one hand off from
# leading to another and reaches no child.

FL_MANAGED_HOME="${HOME%/}/.local/share/benchbar"
FL_APP_CLI="${HOME%/}/.local/state/benchbar/bin/benchbar"
FL_INSTALL_KIND=other
FL_SELF="${SCRIPT_DIR}/benchbar"
FL_SELF_DIR="$SCRIPT_DIR"
case "$SCRIPT_DIR" in
  */opt/benchbar/libexec)
    FL_INSTALL_KIND=homebrew
    FL_SELF="${SCRIPT_DIR%/libexec}/bin/benchbar" ;;
  */Cellar/benchbar/*/libexec)
    FL_INSTALL_KIND=homebrew
    FL_SELF_DIR="${SCRIPT_DIR%/Cellar/benchbar/*}/opt/benchbar/libexec"
    FL_SELF="${FL_SELF_DIR%/libexec}/bin/benchbar" ;;
  "$FL_MANAGED_HOME") FL_INSTALL_KIND=managed ;;
  */BenchBar.app/Contents/Resources/cli)
    FL_INSTALL_KIND=app
    # -ef compares the files the paths lead to, with no process: status runs this on every poll
    if [[ "$FL_APP_CLI" -ef "${SCRIPT_DIR}/benchbar" ]]; then FL_SELF="$FL_APP_CLI"; fi ;;
  *)
    if [[ -e "${SCRIPT_DIR}/.git" ]]; then FL_INSTALL_KIND=checkout; fi ;;
esac
FL_SELF_PREFIX=""
if [[ "$FL_INSTALL_KIND" == homebrew ]]; then FL_SELF_PREFIX="${FL_SELF%/opt/benchbar/bin/benchbar}"; fi

FL_HANDOFF_FROM="${BENCHBAR_HANDOFF_FROM:-}"
if [[ -z "$FL_HANDOFF_FROM" && -z "${BENCHBAR_NO_HANDOFF:-}" && -x "$FL_APP_CLI" ]] \
  && [[ "$FL_INSTALL_KIND" == homebrew || "$FL_INSTALL_KIND" == managed ]]; then
  # "$@" is the arguments of the benchbar that sources this file
  BENCHBAR_HANDOFF_FROM="$FL_SELF" exec "$FL_APP_CLI" "$@"
fi
unset BENCHBAR_HANDOFF_FROM
