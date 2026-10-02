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
# Nothing comes from the environment on purpose: a variable the formula's
# wrapper set would reach every child, a nested benchbar of another kind
# included.

FL_MANAGED_HOME="${HOME%/}/.local/share/benchbar"
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
  *)
    if [[ -e "${SCRIPT_DIR}/.git" ]]; then FL_INSTALL_KIND=checkout; fi ;;
esac
FL_SELF_PREFIX=""
if [[ "$FL_INSTALL_KIND" == homebrew ]]; then FL_SELF_PREFIX="${FL_SELF%/opt/benchbar/bin/benchbar}"; fi
