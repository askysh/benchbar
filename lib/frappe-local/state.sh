#!/usr/bin/env bash
#
# state.sh: small key=value store in .benchbar/state.env.
#
# The folder was .frappe-local before 0.3.0. The first run after the
# upgrade renames it (one atomic mv in the checkout), unless a run holds
# its lock right now; until then the old folder is used as is.

fl_state_dir_default() {
  local new="${SCRIPT_DIR}/.benchbar" old="${SCRIPT_DIR}/.frappe-local"
  if [[ -d "$old" && ! -e "$new" && ! -d "${old}/lock" ]]; then
    mv "$old" "$new" 2>/dev/null || true
  fi
  if [[ -d "$new" || ! -d "$old" ]]; then printf '%s' "$new"; else printf '%s' "$old"; fi
}

FL_STATE_DIR="${FL_STATE_DIR:-$(fl_state_dir_default)}"
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
