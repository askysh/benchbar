#!/usr/bin/env bash
#
# shellrc.sh: manage one marker block in the user's shell rc file.
#
#   # >>> benchbar >>>
#   ...managed content...
#   # <<< benchbar <<<
#
# The block is replaced in place only when both markers exist exactly once
# and in order. Otherwise the block is appended and a warning is printed.
# The rc file is backed up before every write.
#
# Before 0.3.0 the markers said frappe-mac. Such a block is "legacy": it is
# ours, it counts as outdated, and the next write replaces it in place
# with the new markers.

FL_RC_START="# >>> benchbar >>>"
FL_RC_END="# <<< benchbar <<<"
FL_RC_LEGACY_START="# >>> frappe-mac >>>"
FL_RC_LEGACY_END="# <<< frappe-mac <<<"

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

# fl_rc_markers_state FILE START END -> missing | present | broken
fl_rc_markers_state() {
  local file="$1" start="$2" end="$3" starts ends start_line end_line
  starts="$(fl_rc_marker_count "$file" "$start")"
  ends="$(fl_rc_marker_count "$file" "$end")"
  [[ "${starts:-0}" == "0" && "${ends:-0}" == "0" ]] && { printf 'missing'; return 0; }
  [[ "$starts" == "1" && "$ends" == "1" ]] || { printf 'broken'; return 0; }
  start_line="$(grep -n -x -F "$start" "$file" | cut -d: -f1)"
  end_line="$(grep -n -x -F "$end" "$file" | cut -d: -f1)"
  [[ "$start_line" -lt "$end_line" ]] && printf 'present' || printf 'broken'
}

# fl_rc_block_state FILE -> missing | present | legacy | broken
#   legacy: no benchbar block, but a well formed frappe-mac one
fl_rc_block_state() {
  local file="$1" state
  state="$(fl_rc_markers_state "$file" "$FL_RC_START" "$FL_RC_END")"
  if [[ "$state" == "missing" && "$(fl_rc_markers_state "$file" "$FL_RC_LEGACY_START" "$FL_RC_LEGACY_END")" == "present" ]]; then
    state="legacy"
  fi
  printf '%s' "$state"
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
    legacy) printf 'outdated'; return 0 ;;
  esac
  have="$(fl_rc_block_extract "$file" | fl_template_header_of_stdin)"
  want="$(printf '%s' "$content" | fl_template_header_of_stdin)"
  if [[ -n "$have" && "$have" == "$want" ]]; then printf 'current'; else printf 'outdated'; fi
}

fl_template_header_of_stdin() {
  fl_template_header_key
}

# fl_rc_block_write FILE CONTENT: replace in place or append. Backs up first.
fl_rc_block_write() {
  local file="$1" content="$2" state tmp body
  state="$(fl_rc_block_state "$file")"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    case "$state" in
      present) fl_info "dry-run: would replace the benchbar block in ${file}" ;;
      legacy) fl_info "dry-run: would replace the frappe-mac block in ${file} with a benchbar block" ;;
      broken) fl_info "dry-run: would append a new benchbar block to ${file} (existing markers are malformed)" ;;
      *) fl_info "dry-run: would append the benchbar block to ${file}" ;;
    esac
    return 0
  fi
  fl_backup_file "$file"
  body="$(mktemp "${TMPDIR:-/tmp}/benchbar-rc.XXXXXX")"
  printf '%s\n' "$content" >"$body"
  tmp="$(mktemp "${TMPDIR:-/tmp}/benchbar-rc.XXXXXX")"
  case "$state" in
    present|legacy)
      local from_start="$FL_RC_START" from_end="$FL_RC_END"
      if [[ "$state" == "legacy" ]]; then from_start="$FL_RC_LEGACY_START"; from_end="$FL_RC_LEGACY_END"; fi
      # the new markers go where the old block was, so its place in the file is kept
      awk -v s="$from_start" -v e="$from_end" -v ns="$FL_RC_START" -v ne="$FL_RC_END" -v body="$body" '
        $0 == s { print ns; while ((getline l < body) > 0) print l; close(body); skip = 1; next }
        $0 == e { skip = 0; print ne; next }
        !skip { print }' "$file" >"$tmp"
      fl_log "replaced the ${state} block in ${file}"
      ;;
    *)
      if [[ "$state" == "broken" ]]; then
        fl_warn "${file} has malformed benchbar markers; appending a fresh block. Remove the old one by hand."
      fi
      { [[ -f "$file" ]] && cat "$file"; printf '\n%s\n' "$FL_RC_START"; cat "$body"; printf '%s\n' "$FL_RC_END"; } >"$tmp"
      fl_log "appended benchbar block to ${file}"
      ;;
  esac
  mv "$tmp" "$file"
  rm -f "$body"
}

# fl_rc_block_remove FILE: removes the block, benchbar or legacy frappe-mac.
fl_rc_block_remove() {
  local file="$1" tmp state start="$FL_RC_START" end="$FL_RC_END"
  state="$(fl_rc_block_state "$file")"
  case "$state" in
    present) ;;
    legacy) start="$FL_RC_LEGACY_START"; end="$FL_RC_LEGACY_END" ;;
    *) return 0 ;;
  esac
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would remove the benchbar block from ${file}"
    return 0
  fi
  fl_backup_file "$file"
  tmp="$(mktemp "${TMPDIR:-/tmp}/benchbar-rc.XXXXXX")"
  awk -v s="$start" -v e="$end" '
    $0 == s { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip { print }' "$file" >"$tmp"
  mv "$tmp" "$file"
  fl_log "removed benchbar block from ${file}"
}

# Prints marker names of other managed blocks (for example old
# "frappe-bench helpers" blocks) so doctor can warn about them. The
# installer's own PATH block (benchbar-path) is not one of them.
fl_rc_legacy_blocks() {
  local file="$1" ours="frappe-mac"
  [[ -f "$file" ]] || return 0
  # a frappe-mac block is ours to migrate, unless a benchbar block already exists
  [[ "$(fl_rc_markers_state "$file" "$FL_RC_START" "$FL_RC_END")" == "present" ]] && ours="benchbar"
  grep -o '^# >>> [A-Za-z0-9 ._-]* >>>' "$file" 2>/dev/null | sed -e 's/^# >>> //' -e 's/ >>>$//' | grep -v -x -e 'benchbar' -e 'benchbar-path' -e "$ours" | sort -u || true
}
