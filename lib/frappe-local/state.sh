#!/usr/bin/env bash
#
# state.sh: small key=value store in .frappe-local/state.env.

FL_STATE_DIR="${FL_STATE_DIR:-${SCRIPT_DIR}/.frappe-local}"
FL_STATE_FILE="${FL_STATE_FILE:-${FL_STATE_DIR}/state.env}"

fl_state_init() {
  [[ "${FL_DRY_RUN:-0}" == "1" ]] && return 0
  mkdir -p "$FL_STATE_DIR"
  touch "$FL_STATE_FILE"
}

fl_state_set() {
  local key="$1" value="$2"
  [[ "${FL_DRY_RUN:-0}" == "1" ]] && return 0
  mkdir -p "$FL_STATE_DIR" 2>/dev/null || true
  [[ -f "$FL_STATE_FILE" ]] || : >"$FL_STATE_FILE"
  if [[ "$(fl_state_get "$key")" == "$value" ]]; then
    return 0
  fi
  grep -v "^${key}=" "$FL_STATE_FILE" >"${FL_STATE_FILE}.tmp" 2>/dev/null || true
  printf '%s=%q\n' "$key" "$value" >>"${FL_STATE_FILE}.tmp"
  mv "${FL_STATE_FILE}.tmp" "$FL_STATE_FILE"
}

fl_state_get() {
  local key="$1" raw
  [[ -f "$FL_STATE_FILE" ]] || return 0
  raw="$(sed -n "s/^${key}=//p" "$FL_STATE_FILE" | tail -n1)"
  [[ -n "$raw" ]] || return 0
  # values are stored with %q; unquote the common forms
  eval "printf '%s\n' $raw"
}
