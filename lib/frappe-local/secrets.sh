#!/usr/bin/env bash
# shellcheck disable=SC2034  # FL_SUDO_PW is read by sudo.sh; the passwords by the commands
#
# secrets.sh: the secret channel for a caller that is not a person at a
# terminal (the Windows tray, an agent): install --secrets-stdin and its
# siblings read the passwords from standard input, so they are never in the
# environment of benchbar or of a child, where /proc/PID/environ (Linux) and
# ReadProcessMemory (Windows) show them for the whole run.
#
# Format: KEY=VALUE lines, LF only, ended by an empty line, which is required
# (nothing after it is read, so a caller may keep stdin open; a timeout and a
# closed input are told apart by no bash, so both are refused). The
# value is everything after the first "=", so it may hold "=" and spaces.
# Only the keys of FL_SECRETS_KEYS are known; an unknown or repeated key, a
# line without "=", a CR, a list with no empty line at its end (a timeout, a closed input), an empty list or a
# line over 4096 characters is refused with the line number
# (never the line: it may be the password). The values go into plain shell
# variables, never exported, never in an argument, a log, a record or JSON.
#
# The phase scripts get the same lines on an inherited pipe (FL_SECRETS_FD,
# fd 7, like the sudo password on fd 8) and read them first thing, so their
# environment has no password either.
# xtrace is switched off around every read.

# the keys a caller may send
FL_SECRETS_KEYS="ADMIN_PASSWORD MARIADB_ROOT_PASSWORD BENCHBAR_SUDO_PASSWORD"
# seconds the first line may take to arrive
FL_SECRETS_WAIT="${FL_SECRETS_WAIT:-30}"

# fl__secrets_set KEY VALUE: into the shell variable the command reads.
fl__secrets_set() {
  case "$1" in
    ADMIN_PASSWORD) ADMIN_PASSWORD="$2" ;;
    MARIADB_ROOT_PASSWORD) MARIADB_ROOT_PASSWORD="$2" ;;
    BENCHBAR_SUDO_PASSWORD) FL_SUDO_PW="$2" ;;
  esac
}

# fl__secrets_read FD: reads the lines from FD and sets the variables; prints
# nothing, returns 0, or 1 with FL_SECRETS_ERR naming the problem. Only
# builtins run while a value is held: no process sees it. Refused, the same on
# bash 3.2 and 5 (they differ in what a timed out read keeps, so none is
# kept): a list not ended by an empty line (a timeout or a closed input), a last line with no LF, a line over 4096
# characters, more than 8 lines, an empty list, a key that is not exactly one
# of FL_SECRETS_KEYS (no space joined keys), a repeated key, a CR.
fl__secrets_read() {
  local fd="$1" line key val n=0 seen=" " xt=0 wait="$FL_SECRETS_WAIT" rc
  FL_SECRETS_ERR=""
  case "$-" in *x*) xt=1; { set +x; } 2>/dev/null ;; esac
  [[ "$wait" =~ ^[0-9]+$ && "$wait" -ge 1 ]] || wait=30
  while :; do
    line=""; rc=0
    # -n 4097: a longer line stops the read before its LF, and is refused below
    IFS= read -r -n 4097 -t "$wait" -u "$fd" line || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      # a timeout and the end of the input look the same on bash 3.2 (status 1; bash 5 says 142 for a
      # timeout), so both are one refusal: the list must end with an empty line
      if [[ -n "$line" ]]; then FL_SECRETS_ERR="the last line has no LF at its end"
      else FL_SECRETS_ERR="the list was not ended by an empty line (the input closed, or no line came in ${wait} seconds)"; fi
      break
    fi
    [[ -n "$line" ]] || break
    n=$((n + 1))
    if [[ "$n" -gt 8 ]]; then FL_SECRETS_ERR="more than 8 lines"; break; fi
    if [[ "${#line}" -gt 4096 ]]; then FL_SECRETS_ERR="line ${n} is longer than 4096 characters"; break; fi
    case "$line" in
      *$'\r') FL_SECRETS_ERR="line ${n} ends in a carriage return (LF only)"; break ;;
      *=*) ;;
      *) FL_SECRETS_ERR="line ${n} is not KEY=VALUE"; break ;;
    esac
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in
      ADMIN_PASSWORD|MARIADB_ROOT_PASSWORD) ;;
      BENCHBAR_SUDO_PASSWORD)
        # as in the environment: it counts with BENCHBAR_SUDO=env on Linux; a caller that sends it
        # otherwise is told, not ignored
        if ! { declare -F fl_sudo_env >/dev/null 2>&1 && fl_sudo_env; }; then
          FL_SECRETS_ERR="line ${n}: BENCHBAR_SUDO_PASSWORD needs BENCHBAR_SUDO=env on Linux (it is not set here, or this is not Linux)"; break
        fi ;;
      *) FL_SECRETS_ERR="line ${n} has a key that is not accepted"; break ;;
    esac
    case "$seen" in *" ${key} "*) FL_SECRETS_ERR="line ${n} repeats a key"; break ;; esac
    seen="${seen}${key} "
    fl__secrets_set "$key" "$val"
  done
  line=""; val=""
  if [[ -z "$FL_SECRETS_ERR" && "$n" -eq 0 ]]; then FL_SECRETS_ERR="no secret was sent (the input was empty)"; fi
  if [[ "$xt" == "1" ]]; then set -x; fi
  [[ -z "$FL_SECRETS_ERR" ]]
}

# fl_secrets_stdin_take: --secrets-stdin. Takes the flag out of ARGS (the
# commands never see it) and, unless this is a help request, reads the
# secrets from stdin. Before anything else reads stdin and before the
# preflight asks which inputs are missing.
OPT_SECRETS_STDIN=0
fl_secrets_stdin_take() {
  local a i=0 n="${FL_ARGS_FLAGS_N:--1}" rest=() found=0
  [[ "${#ARGS[@]}" -gt 0 ]] || return 0
  for a in "${ARGS[@]}"; do
    if [[ "$a" == "--secrets-stdin" && ( "$n" -lt 0 || "$i" -lt "$n" ) ]]; then found=1
    else rest+=("$a"); fi
    i=$((i + 1))
  done
  [[ "$found" == "1" ]] || return 0
  ARGS=(${rest[@]+"${rest[@]}"})
  [[ "$n" -lt 0 ]] || FL_ARGS_FLAGS_N=$((n - 1))
  OPT_SECRETS_STDIN=1
  [[ "${FL_WANT_HELP:-0}" != "1" ]] || return 0
  if [[ -t 0 ]]; then
    fl_usage_refuse secrets_stdin_terminal "--secrets-stdin reads the secrets from standard input, and this one is a terminal." \
      "It is for a program that has no terminal. At a terminal, leave it out: benchbar asks, or reads the Keychain. Format: KEY=VALUE lines, one per secret, ended by an empty line."
  fi
  if ! fl__secrets_read 0; then
    fl_usage_refuse secrets_stdin_invalid "The secrets on standard input were refused: ${FL_SECRETS_ERR}. Nothing was changed." \
      "Send KEY=VALUE lines (LF only, no value on a second line) with the keys ${FL_SECRETS_KEYS// /, }, ended by an empty line (required)."
  fi
  fl__secrets_notrace
}

# fl__secrets_notrace: a run that holds secrets from the channel does not trace
# the rest of itself: bash prints every command line after expansion, so a
# "bash -x" trace would show each password at each place that passes it on
# (a function call, a test, an assignment). The trace stops here, silently.
fl__secrets_notrace() { { set +x; } 2>/dev/null; return 0; }

# fl__secrets_emit: the passwords the phase scripts need, as the lines
# fl__secrets_read takes. Builtins only (printf), so no process has them.
fl__secrets_emit() {
  local xt=0
  case "$-" in *x*) xt=1; { set +x; } 2>/dev/null ;; esac
  [[ -z "${ADMIN_PASSWORD:+x}" ]] || printf 'ADMIN_PASSWORD=%s\n' "$ADMIN_PASSWORD"
  [[ -z "${MARIADB_ROOT_PASSWORD:+x}" ]] || printf 'MARIADB_ROOT_PASSWORD=%s\n' "$MARIADB_ROOT_PASSWORD"
  # the empty line that ends the list
  printf '\n'
  if [[ "$xt" == "1" ]]; then set -x; fi
  return 0
}

# fl__secrets_present: a password for the phase scripts is held
# (:+x, so an xtrace line shows "x" and not the value)
fl__secrets_present() { [[ -n "${ADMIN_PASSWORD:+x}${MARIADB_ROOT_PASSWORD:+x}" ]]; }

# fl_secrets_fd_take: a phase script reads what its parent put on FL_SECRETS_FD
# (fd 4 to 9), once, and closes it. Without the variable it does nothing: a
# phase script started by hand still reads its environment.
fl_secrets_fd_take() {
  local fd="${FL_SECRETS_FD:-}"
  [[ -n "$fd" ]] || return 0
  unset FL_SECRETS_FD
  [[ "$fd" =~ ^[4-9]$ ]] || return 0
  fl__secrets_read "$fd" || { eval "exec ${fd}<&- 62<&- 63<&-" 2>/dev/null || true; fl_die "The secrets from benchbar were refused: ${FL_SECRETS_ERR}." "This is a bug in benchbar; run: benchbar report"; }
  eval "exec ${fd}<&-" 2>/dev/null || true
  # the process substitutions behind fd 7 and fd 8 hold their pipes on fd 62 and 63: closed, so the
  # phase script's children (bench init, get-app, brew) do not inherit them
  eval "exec 62<&- 63<&-" 2>/dev/null || true
  fl__secrets_notrace
}
