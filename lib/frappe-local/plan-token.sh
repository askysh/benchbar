#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are shared with the other lib files
#
# plan-token.sh: the approval token of a plan (site add, site restore,
# app add, ports apply, service --apply).
#
# A token is 64 hex characters: a hash of the plan and of the state it was
# made against, keyed with a per install secret and tied to a time window.
#   - The key is plan-key in the state folder (0600), made on first use. A
#     person or an agent that can only run the plan command and read its
#     output cannot compute a token for a plan it has changed; the key never
#     leaves the Mac and is never printed.
#   - The hash is H(key, window, H(key, plan)): the key goes in at both ends
#     so the token cannot be extended (a plain H(key + plan) can).
#   - The window is FL_PLAN_WINDOW_SECS (10 minutes). Apply accepts the
#     current window and the FL_PLAN_VALID_WINDOWS before it, so a token is
#     good for 60 to 70 minutes, then refused as expired. Nothing is stored:
#     apply makes the plan again and recomputes the token for each window.
# It proves that the bench is as the plan saw it, recently. It does not prove
# that a person looked at the plan (the MCP and AGENTS.md rules say who asks).

# fixed in production; the tests may change them only under FL_TESTING=1 (DECISIONS: test seams)
FL_PLAN_WINDOW_SECS=600
FL_PLAN_VALID_WINDOWS=6
# how far back an expired token is still recognised as one of ours (windows):
# older ones are only "not this plan"
FL_PLAN_RECOGNISE_WINDOWS="${FL_PLAN_RECOGNISE_WINDOWS:-36}"

# FL_PLAN_NOW: the tests' clock, read only under FL_TESTING=1
fl_plan_now() {
  if [[ "${FL_TESTING:-0}" == "1" && -n "${FL_PLAN_NOW:-}" ]]; then printf '%s' "$FL_PLAN_NOW"; else date +%s; fi
}

# fl__plan_key_usable FILE: a regular file with a key in it that only its
# owner can read or write. An empty file, or one that group or others can
# read, is not a key to trust.
fl__plan_key_usable() {
  local mode
  [[ -f "$1" && ! -L "$1" && -s "$1" ]] || return 1
  mode="$(stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || true)"
  [[ "$mode" =~ ^[0-7]*[0-7]00$ ]]
}

# fl_plan_key_v VAR: the install's secret, made when it is not there yet. A
# key file that is empty or readable by others is replaced with a new key
# (tokens made with the old one are then refused as a changed plan).
fl_plan_key_v() {
  local __file="${FL_STATE_DIR}/plan-key" __k="" __tmp __replace=0
  if fl__plan_key_usable "$__file"; then
    __k="$(cat "$__file" 2>/dev/null || true)"
  else
    [[ -e "$__file" || -L "$__file" ]] && __replace=1
    __k="$(head -c 32 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    if [[ ${#__k} -ge 32 ]] && mkdir -p "$FL_STATE_DIR" 2>/dev/null; then
      __tmp="${__file}.$$"
      if (umask 077; printf '%s\n' "$__k" >"$__tmp") 2>/dev/null; then
        chmod 600 "$__tmp" 2>/dev/null || true
        if [[ "$__replace" -eq 1 ]]; then
          # the old file was empty or readable by others: it is replaced
          if mv -f "$__tmp" "$__file" 2>/dev/null; then
            fl_log "plan token: ${__file} was empty or readable by others; made a new key"
          else
            fl_log "plan token: could not replace ${__file}"
          fi
        else
          # a second run that made one first wins: link fails when the file exists
          ln "$__tmp" "$__file" 2>/dev/null || true
        fi
        [[ -e "$__tmp" ]] && rm -f "$__tmp"
        __k=""
        fl__plan_key_usable "$__file" && __k="$(cat "$__file" 2>/dev/null || true)"
      else
        __k=""
      fi
    else
      __k=""
    fi
  fi
  # a state folder that cannot be written: the token still carries the time
  # window but loses its key; say so in the log, never stop a plan for it
  [[ -n "$__k" ]] || { fl_log "plan token: no key in ${FL_STATE_DIR}; the token is not keyed"; __k="unkeyed"; }
  printf -v "$1" '%s' "$__k"
}

# fl__plan_hash TEXT: sha256 of TEXT, on stdin so nothing is on a command line
fl__plan_hash() { printf '%s' "$1" | shasum -a 256 | awk '{print $1}'; }

# fl__plan_token_at_v VAR KEY INNER WINDOW
fl__plan_token_at_v() {
  local __h
  __h="$(fl__plan_hash "${2}"$'\n'"${4}"$'\n'"${3}")"
  printf -v "$1" '%s' "$__h"
}

# fl_plan_token_v VAR PLAN: the token of PLAN (its body and the state it was
# made against, as one text) for the window of now
fl_plan_token_v() {
  local __key __inner __t
  fl_plan_key_v __key
  __inner="$(fl__plan_hash "${__key}"$'\n'"${2}")"
  fl__plan_token_at_v __t "$__key" "$__inner" "$(( $(fl_plan_now) / FL_PLAN_WINDOW_SECS ))"
  printf -v "$1" '%s' "$__t"
}

# fl_plan_token_check PLAN TOKEN: PLAN is the plan made again now.
#   0  TOKEN is this plan's token and still valid
#   1  TOKEN is not this plan's (the bench changed, or it was never issued)
#   2  TOKEN is this plan's, but older than the validity
fl_plan_token_check() {
  local key inner w cur oldest last t
  fl_plan_key_v key
  inner="$(fl__plan_hash "${key}"$'\n'"${1}")"
  cur=$(( $(fl_plan_now) / FL_PLAN_WINDOW_SECS ))
  oldest=$(( cur - FL_PLAN_VALID_WINDOWS ))
  last=$(( cur - FL_PLAN_RECOGNISE_WINDOWS ))
  w="$cur"
  while [[ "$w" -ge "$last" ]]; do
    fl__plan_token_at_v t "$key" "$inner" "$w"
    if [[ "$t" == "$2" ]]; then
      [[ "$w" -ge "$oldest" ]] && return 0
      return 2
    fi
    w=$((w - 1))
  done
  return 1
}

# fl_plan_token_expired_text: the sentence of a refusal for an expired token
fl_plan_token_expired_text() {
  printf 'The plan token expired: a token is good for about an hour after its plan was made, and this one is older. Nothing was changed.'
}
