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
  local stored
  if [[ -n "${FL_RC_FILE:-}" ]]; then printf '%s' "$FL_RC_FILE"; return 0; fi
  # Linux: bash unless the user's shell is zsh
  if [[ "${FL_PLATFORM:-}" == "linux" && "${SHELL:-}" != *zsh ]]; then printf '%s/.bashrc' "$HOME"; return 0; fi
  case "$(basename "${SHELL:-zsh}")" in
    bash)
      if [[ -f "$HOME/.bashrc" ]]; then printf '%s' "$HOME/.bashrc"; else printf '%s' "$HOME/.bash_profile"; fi ;;
    *)
      # zsh reads $ZDOTDIR/.zshrc when ZDOTDIR is set (dotfile managers do
      # that). The app and launchd start the CLI without the terminal's
      # variables, so the file a block was written to is remembered
      # (RC_FILE in the state) and found again without ZDOTDIR.
      if [[ -n "${ZDOTDIR:-}" ]]; then printf '%s/.zshrc' "$ZDOTDIR"; return 0; fi
      stored="$(fl_state_get RC_FILE 2>/dev/null || true)"
      if [[ -n "$stored" && -e "$stored" ]]; then printf '%s' "$stored"; return 0; fi
      printf '%s/.zshrc' "$HOME" ;;
  esac
}

# fl_rc_markers_state FILE START END -> missing | present | broken. One read
# of the file in bash: how often each marker stands alone on a line, and where.
fl_rc_markers_state() {
  local file="$1" start="$2" end="$3" line n=0 starts=0 ends=0 start_line=0 end_line=0
  [[ -f "$file" && -r "$file" ]] || { printf 'missing'; return 0; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    if [[ "$line" == "$start" ]]; then starts=$((starts + 1)); start_line="$n"; fi
    if [[ "$line" == "$end" ]]; then ends=$((ends + 1)); end_line="$n"; fi
  done <"$file"
  [[ "$starts" == "0" && "$ends" == "0" ]] && { printf 'missing'; return 0; }
  [[ "$starts" == "1" && "$ends" == "1" ]] || { printf 'broken'; return 0; }
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
  local file="$1" line inb=0
  [[ "$(fl_rc_block_state "$file")" == "present" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$FL_RC_END" ]]; then inb=0; fi
    if [[ "$inb" == "1" ]]; then printf '%s\n' "$line"; fi
    if [[ "$line" == "$FL_RC_START" ]]; then inb=1; fi
  done <"$file"
  return 0
}

# fl_rc_recorded_cli_v VAR FILE: the benchbar the helper block names
# (BENCHBAR="..."), or nothing
fl_rc_recorded_cli_v() {
  local __line __block
  printf -v "$1" '%s' ""
  __block="$(fl_rc_block_extract "$2" 2>/dev/null)"
  while IFS= read -r __line; do
    if [[ "$__line" =~ ^BENCHBAR=\"(.*)\"$ ]]; then printf -v "$1" '%s' "${BASH_REMATCH[1]}"; return 0; fi
  done <<<"$__block"
  return 0
}

# fl_rc_block_status FILE CONTENT -> missing | current | outdated | broken
fl_rc_block_status() {
  local file="$1" content="$2" state have want
  state="$(fl_rc_block_state "$file")"
  case "$state" in
    missing|broken) printf '%s' "$state"; return 0 ;;
    legacy) printf 'outdated'; return 0 ;;
  esac
  have="$(fl_template_header_of "$(fl_rc_block_extract "$file")")"
  want="$(fl_template_header_of "$content")"
  if [[ -n "$have" && "$have" == "$want" ]]; then printf 'current'; else printf 'outdated'; fi
}

fl_template_header_of_stdin() {
  fl_template_header_key
}

# fl_rc_target FILE: the file a symlinked rc file points at, resolved link by
# link, so the write lands in the real file (a dotfiles repo) and the link
# stays a link; FILE itself when it is no link.
fl_rc_target() {
  local target="$1" dir link
  while [[ -L "$target" ]]; do
    dir="$(cd "$(dirname "$target")" 2>/dev/null && pwd)" || break
    link="$(readlink "$target")" || break
    case "$link" in /*) target="$link" ;; *) target="${dir}/${link}" ;; esac
  done
  printf '%s' "$target"
}

# fl_rc_replace_file FILE TMP: puts TMP's content into FILE. The new file
# is written next to the resolved target with the target's mode and renamed
# onto it: the rename is one step (a write cut short leaves the old file),
# and a symlink above the target stays a symlink. FILE is created when it
# does not exist. TMP is removed. Fails without touching FILE when TMP is
# not a complete file.
fl_rc_replace_file() {
  local file="$1" tmp="$2" target new mode
  target="$(fl_rc_target "$file")"
  [[ -s "$tmp" ]] || { rm -f "$tmp"; fl_fail "the new content for ${file} is empty; not writing it"; return 1; }
  new="$(mktemp "${target}.XXXXXX" 2>/dev/null)" || { rm -f "$tmp"; fl_fail "could not write next to ${target}"; return 1; }
  if ! cat "$tmp" >"$new" 2>/dev/null; then
    rm -f "$tmp" "$new"
    fl_fail "could not write ${target}"
    return 1
  fi
  if [[ -e "$target" ]]; then
    # GNU stat first: BSD stat has no -c and fails quietly, GNU's -f prints filesystem data
    mode="$(stat -c '%a' "$target" 2>/dev/null || stat -f '%Lp' "$target" 2>/dev/null)"
  else
    mode=644
  fi
  [[ -z "$mode" ]] || chmod "$mode" "$new" 2>/dev/null
  if ! mv -f "$new" "$target" 2>/dev/null; then
    rm -f "$tmp" "$new"
    fl_fail "could not write ${target}; it is as it was"
    return 1
  fi
  rm -f "$tmp"
}

# fl_rc_block_write FILE CONTENT: replace in place or append. Backs up first.
# Every stage is checked: a backup, a read or an awk that fails leaves the
# file as it was (an unchecked temp copy wiped a ~/.zshrc before).
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
  fl_backup_file "$file" || return 1
  body="$(mktemp "${TMPDIR:-/tmp}/benchbar-rc.XXXXXX")" || return 1
  printf '%s\n' "$content" >"$body" || { rm -f "$body"; return 1; }
  tmp="$(mktemp "${TMPDIR:-/tmp}/benchbar-rc.XXXXXX")" || { rm -f "$body"; return 1; }
  case "$state" in
    present|legacy)
      local from_start="$FL_RC_START" from_end="$FL_RC_END"
      if [[ "$state" == "legacy" ]]; then from_start="$FL_RC_LEGACY_START"; from_end="$FL_RC_LEGACY_END"; fi
      # the new markers go where the old block was, so its place in the file is kept
      if ! awk -v s="$from_start" -v e="$from_end" -v ns="$FL_RC_START" -v ne="$FL_RC_END" -v body="$body" '
        $0 == s { print ns; while ((getline l < body) > 0) print l; close(body); skip = 1; next }
        $0 == e { skip = 0; print ne; next }
        !skip { print }' "$file" >"$tmp"; then
        rm -f "$tmp" "$body"; fl_fail "could not rewrite the block in ${file}; the file is unchanged"; return 1
      fi
      fl_log "replaced the ${state} block in ${file}"
      ;;
    *)
      if [[ "$state" == "broken" ]]; then
        fl_warn "${file} has malformed benchbar markers; appending a fresh block. Remove the old one by hand."
      fi
      if ! { if [[ -f "$file" ]]; then cat "$file"; fi; printf '\n%s\n' "$FL_RC_START"; cat "$body"; printf '%s\n' "$FL_RC_END"; } >"$tmp"; then
        rm -f "$tmp" "$body"; fl_fail "could not read ${file}; the file is unchanged"; return 1
      fi
      fl_log "appended benchbar block to ${file}"
      ;;
  esac
  rm -f "$body"
  fl_rc_replace_file "$file" "$tmp" || return 1
  # the file this block lives in, for a run without the terminal's ZDOTDIR
  fl_state_set RC_FILE "$file"
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
  fl_backup_file "$file" || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/benchbar-rc.XXXXXX")" || return 1
  if ! awk -v s="$start" -v e="$end" '
    $0 == s { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip { print }' "$file" >"$tmp"; then
    rm -f "$tmp"; fl_fail "could not rewrite ${file}; the file is unchanged"; return 1
  fi
  # a file that held only the block is empty afterwards: that is a valid result
  if [[ ! -s "$tmp" ]]; then : >"$(fl_rc_target "$file")" || { rm -f "$tmp"; return 1; }; rm -f "$tmp"
  else fl_rc_replace_file "$file" "$tmp" || return 1; fi
  fl_log "removed benchbar block from ${file}"
}

# Prints marker names of other managed blocks (for example old
# "frappe-bench helpers" blocks) so doctor can warn about them. The
# installer's own PATH block (benchbar-path) is not one of them.
fl_rc_legacy_blocks() {
  local file="$1" ours="frappe-mac" line name names="" n=0
  local re='^# >>> ([A-Za-z0-9 ._-]*) >>>'
  [[ -f "$file" ]] || return 0
  # a frappe-mac block is ours to migrate, unless a benchbar block already exists
  [[ "$(fl_rc_markers_state "$file" "$FL_RC_START" "$FL_RC_END")" == "present" ]] && ours="benchbar"
  [[ -r "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ $re ]] || continue
    name="${BASH_REMATCH[1]}"
    case "$name" in benchbar|benchbar-path|"$ours") continue ;; esac
    [[ $'\n'"$names" == *$'\n'"$name"$'\n'* ]] && continue
    names="${names}${name}"$'\n'; n=$((n + 1))
  done <"$file"
  # one name needs no sort; several come out as sort -u gives them
  if [[ "$n" -eq 1 ]]; then printf '%s' "$names"; elif [[ "$n" -gt 1 ]]; then printf '%s' "$names" | sort -u; fi
  return 0
}
