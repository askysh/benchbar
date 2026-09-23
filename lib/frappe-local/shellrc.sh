#!/usr/bin/env bash
#
# shellrc.sh: manage one marker block in the user's shell rc file.
#
#   # >>> frappe-mac >>>
#   ...managed content...
#   # <<< frappe-mac <<<
#
# The block is replaced in place only when both markers exist exactly once
# and in order. Otherwise the block is appended and a warning is printed.
# The rc file is backed up before every write.

FL_RC_START="# >>> frappe-mac >>>"
FL_RC_END="# <<< frappe-mac <<<"

fl_rc_file() {
  if [[ -n "${FL_RC_FILE:-}" ]]; then printf '%s' "$FL_RC_FILE"; return 0; fi
  case "$(basename "${SHELL:-zsh}")" in
    bash)
      if [[ -f "$HOME/.bashrc" ]]; then printf '%s' "$HOME/.bashrc"; else printf '%s' "$HOME/.bash_profile"; fi ;;
    *) printf '%s' "$HOME/.zshrc" ;;
  esac
}

fl_rc_marker_count() {
  local file="$1" marker="$2"
  [[ -f "$file" ]] || { printf '0'; return 0; }
  grep -c -x -F "$marker" "$file" 2>/dev/null || true
}

# fl_rc_block_state FILE -> missing | present | broken
fl_rc_block_state() {
  local file="$1" starts ends start_line end_line
  starts="$(fl_rc_marker_count "$file" "$FL_RC_START")"
  ends="$(fl_rc_marker_count "$file" "$FL_RC_END")"
  [[ "${starts:-0}" == "0" && "${ends:-0}" == "0" ]] && { printf 'missing'; return 0; }
  [[ "$starts" == "1" && "$ends" == "1" ]] || { printf 'broken'; return 0; }
  start_line="$(grep -n -x -F "$FL_RC_START" "$file" | cut -d: -f1)"
  end_line="$(grep -n -x -F "$FL_RC_END" "$file" | cut -d: -f1)"
  [[ "$start_line" -lt "$end_line" ]] && printf 'present' || printf 'broken'
}

# Prints the managed content between the markers (markers excluded).
fl_rc_block_extract() {
  local file="$1"
  [[ "$(fl_rc_block_state "$file")" == "present" ]] || return 0
  awk -v s="$FL_RC_START" -v e="$FL_RC_END" '$0 == e {inb = 0} inb {print} $0 == s {inb = 1}' "$file"
}

# fl_rc_block_status FILE CONTENT -> missing | current | outdated | broken
fl_rc_block_status() {
  local file="$1" content="$2" state have want
  state="$(fl_rc_block_state "$file")"
  case "$state" in
    missing|broken) printf '%s' "$state"; return 0 ;;
  esac
  have="$(fl_rc_block_extract "$file" | fl_template_header_of_stdin)"
  want="$(printf '%s' "$content" | fl_template_header_of_stdin)"
  if [[ -n "$have" && "$have" == "$want" ]]; then printf 'current'; else printf 'outdated'; fi
}

fl_template_header_of_stdin() {
  grep -o 'frappe-mac-template: [A-Za-z0-9._-]* v[0-9]* [0-9a-f]*' | head -n1 || true
}

# fl_rc_block_write FILE CONTENT: replace in place or append. Backs up first.
fl_rc_block_write() {
  local file="$1" content="$2" state tmp body
  state="$(fl_rc_block_state "$file")"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    case "$state" in
      present) fl_info "dry-run: would replace the frappe-mac block in ${file}" ;;
      broken) fl_info "dry-run: would append a new frappe-mac block to ${file} (existing markers are malformed)" ;;
      *) fl_info "dry-run: would append the frappe-mac block to ${file}" ;;
    esac
    return 0
  fi
  fl_backup_file "$file"
  body="$(mktemp "${TMPDIR:-/tmp}/frappe-mac-rc.XXXXXX")"
  printf '%s\n' "$content" >"$body"
  tmp="$(mktemp "${TMPDIR:-/tmp}/frappe-mac-rc.XXXXXX")"
  case "$state" in
    present)
      awk -v s="$FL_RC_START" -v e="$FL_RC_END" -v body="$body" '
        $0 == s { print; while ((getline l < body) > 0) print l; close(body); skip = 1; next }
        $0 == e { skip = 0; print; next }
        !skip { print }' "$file" >"$tmp"
      fl_log "replaced frappe-mac block in ${file}"
      ;;
    *)
      if [[ "$state" == "broken" ]]; then
        fl_warn "${file} has malformed frappe-mac markers; appending a fresh block. Remove the old one by hand."
      fi
      { [[ -f "$file" ]] && cat "$file"; printf '\n%s\n' "$FL_RC_START"; cat "$body"; printf '%s\n' "$FL_RC_END"; } >"$tmp"
      fl_log "appended frappe-mac block to ${file}"
      ;;
  esac
  mv "$tmp" "$file"
  rm -f "$body"
}

# fl_rc_block_remove FILE: removes the block (and the blank line before it).
fl_rc_block_remove() {
  local file="$1" tmp
  [[ "$(fl_rc_block_state "$file")" == "present" ]] || return 0
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would remove the frappe-mac block from ${file}"
    return 0
  fi
  fl_backup_file "$file"
  tmp="$(mktemp "${TMPDIR:-/tmp}/frappe-mac-rc.XXXXXX")"
  awk -v s="$FL_RC_START" -v e="$FL_RC_END" '
    $0 == s { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip { print }' "$file" >"$tmp"
  mv "$tmp" "$file"
  fl_log "removed frappe-mac block from ${file}"
}

# Prints marker names of other managed blocks (for example old
# "frappe-bench helpers" blocks) so doctor can warn about them.
fl_rc_legacy_blocks() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  grep -o '^# >>> [A-Za-z0-9 ._-]* >>>' "$file" 2>/dev/null | sed -e 's/^# >>> //' -e 's/ >>>$//' | grep -v -x 'frappe-mac' | sort -u || true
}
