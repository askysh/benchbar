#!/usr/bin/env bash
#
# templates.sh: render files from templates/ with a version and content hash
# header, detect whether an installed copy is current, and back up before
# every rewrite.
#
# A template may contain:
#   #@version N            stripped on render, becomes the vN in the header
#   __HEADER__             replaced by "benchbar-template: <name> vN <hash>"
#   __KEY__                replaced by the value passed as KEY=value; a line
#                          that is only __KEY__ and renders to nothing is
#                          dropped (an optional line, like the scheduler)
# The hash covers the rendered content with __HEADER__ still in place, so it
# only changes when the template or its inputs change.
#
# Files written before 0.3.0 say "frappe-mac-template:". Both words count as
# ours, and only "<name> vN <hash>" is compared, so the rename alone never
# rewrites a file (a MariaDB drop-in rewrite would restart MariaDB).

FL_TEMPLATE_TOKEN="benchbar-template"
FL_TEMPLATE_HEADER_RE='\(benchbar\|frappe-mac\)-template: [A-Za-z0-9._-]* v[0-9]* [0-9a-f]*'

FL_TEMPLATE_DIR="${FL_TEMPLATE_DIR:-${SCRIPT_DIR}/templates}"
FL_BACKUP_ROOT="${FL_BACKUP_ROOT:-${FL_STATE_DIR}/backups}"
FL_BACKUP_STAMP=""
FL_LAST_BACKUP=""

fl_content_hash() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -c1-12
  else
    cksum | awk '{print $1}'
  fi
}

fl_template_version() {
  local file="$1"
  sed -n 's/^#@version[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$file" | head -n1
}

# fl_template_render NAME KEY=VALUE...  (NAME is the file under templates/, without .tmpl)
# Prints the rendered content including the resolved header line.
fl_template_render() {
  local name="$1" file body line pair key value hash version only_token
  shift
  file="${FL_TEMPLATE_DIR}/${name}.tmpl"
  [[ -f "$file" ]] || { fl_fail "template not found: ${file}"; return 1; }
  version="$(fl_template_version "$file")"
  body=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      '#@version'*) continue ;;
    esac
    only_token=0
    [[ "$line" =~ ^__[A-Z_]+__$ ]] && only_token=1
    for pair in "$@"; do
      key="${pair%%=*}"
      value="${pair#*=}"
      line="${line//__${key}__/$value}"
    done
    [[ "$only_token" == "1" && -z "$line" ]] && continue
    body="${body}${line}"$'\n'
  done <"$file"
  hash="$(printf '%s' "$body" | fl_content_hash)"
  printf '%s' "${body//__HEADER__/${FL_TEMPLATE_TOKEN}: ${name} v${version:-1} ${hash}}"
}

# Prints "<name> vN <hash>" from the first header on stdin, or nothing.
fl_template_header_key() {
  grep -o "$FL_TEMPLATE_HEADER_RE" | head -n1 | sed 's/^[a-z-]*-template: //' || true
}

# Prints the header key found in an existing file, or nothing.
fl_template_installed_header() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  fl_template_header_key <"$path" 2>/dev/null || true
}

fl_template_header_of() {
  printf '%s' "$1" | fl_template_header_key
}

# fl_template_status PATH RENDERED -> missing | current | outdated | foreign
#   foreign: the file exists but was not written by benchbar
fl_template_status() {
  local path="$1" rendered="$2" have want
  [[ -e "$path" ]] || { printf 'missing'; return 0; }
  have="$(fl_template_installed_header "$path")"
  want="$(fl_template_header_of "$rendered")"
  if [[ -z "$have" ]]; then printf 'foreign'; return 0; fi
  if [[ "$have" == "$want" ]]; then printf 'current'; else printf 'outdated'; fi
}

fl_backup_stamp() {
  [[ -n "$FL_BACKUP_STAMP" ]] || FL_BACKUP_STAMP="$(date +%Y%m%d-%H%M%S)"
  printf '%s' "$FL_BACKUP_STAMP"
}

# fl_backup_file PATH: copies PATH into the backup folder for this run.
# Sets FL_LAST_BACKUP to the copy. Never deletes anything.
fl_backup_file() {
  local path="$1" dest flat
  FL_LAST_BACKUP=""
  [[ -e "$path" ]] || return 0
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would back up ${path}"
    return 0
  fi
  flat="$(printf '%s' "$path" | sed -e "s#^${HOME}#HOME#" -e 's#^/##' -e 's#/#__#g')"
  dest="${FL_BACKUP_ROOT}/$(fl_backup_stamp)/${flat}"
  mkdir -p "$(dirname "$dest")"
  cp -p "$path" "$dest"
  FL_LAST_BACKUP="$dest"
  fl_log "backup: ${path} -> ${dest}"
}

# fl_move_aside PATH: renames PATH to PATH.<suffix>.<stamp> next to itself.
# Used for large trees (env, node_modules) that must not be deleted.
fl_move_aside() {
  local path="$1" suffix="${2:-broken}" dest
  [[ -e "$path" ]] || return 0
  dest="${path}.${suffix}.$(fl_backup_stamp)"
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would move ${path} to ${dest}"
    return 0
  fi
  mv "$path" "$dest"
  fl_log "moved aside: ${path} -> ${dest}"
  fl_info "moved aside: ${dest}"
}

# fl_template_apply PATH RENDERED [MODE]: backs up PATH when it exists, then
# writes RENDERED atomically. Prints nothing when the file is already current.
# Returns 0 and sets FL_TEMPLATE_CHANGED=1 when a write happened.
fl_template_apply() {
  local path="$1" rendered="$2" mode="${3:-}" status tmp
  FL_TEMPLATE_CHANGED=0
  status="$(fl_template_status "$path" "$rendered")"
  [[ "$status" == "current" ]] && return 0
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would write ${path} (${status})"
    FL_TEMPLATE_CHANGED=1
    return 0
  fi
  [[ "$status" == "foreign" ]] && fl_warn "${path} was not written by benchbar; backing it up before replacing"
  fl_backup_file "$path"
  mkdir -p "$(dirname "$path")"
  tmp="$(mktemp "${path}.tmp.XXXXXX")"
  printf '%s' "$rendered" >"$tmp"
  [[ -n "$mode" ]] && chmod "$mode" "$tmp"
  mv "$tmp" "$path"
  fl_log "wrote ${path} (${status})"
  FL_TEMPLATE_CHANGED=1
}
