#!/usr/bin/env bash
#
# templates.sh: render files from templates/ with a version and content hash
# header, detect whether an installed copy is current, and back up before
# every rewrite.
#
# A template may contain:
#   #@version N            stripped on render, becomes the vN in the header
#   #@unhashed KEY...      stripped on render; these keys' values are left
#                          out of the hash (put it before their first use)
#   #@quoted KEY... [# note]  stripped on render; these keys' values sit inside
#                          bash double quotes, so " \ $ and ` in them are
#                          escaped (put it before their first use; text
#                          after a # on that line is a note). In a
#                          .plist template every value is XML escaped
#                          (& < > ") instead. Neither changes a value that
#                          has none of those characters, so an ordinary
#                          path renders byte for byte as before.
#   __HEADER__             replaced by "benchbar-template: <name> vN <hash>"
#   __KEY__                replaced by the value passed as KEY=value; a line
#                          that is only __KEY__ and renders to nothing is
#                          dropped (an optional line, like the scheduler)
# The hash covers the rendered content with __HEADER__ still in place, so it
# only changes when the template or its inputs change. An unhashed key is
# hashed as its __KEY__ token: the runner's CLI_VERSION, so that an upgrade
# alone does not make every runner outdated. The value still lands in the
# file, and stays there until another change rewrites it.
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

# The replacement of every ${var//pat/rep} here is a plain variable, never a
# quoted literal: bash 3.2 to 4.2 keep the quotes of a quoted replacement
# (BENCH=""..."" under /bin/bash). bash 5.2 would read an & or \ in the
# replacement, an expanded variable included, as the match or an escape:
# ui.sh turns patsub_replacement off for the whole program.

# fl_xml_escape_v VAR TEXT: TEXT as XML element text (& < > " escaped)
fl_xml_escape_v() {
  local __s="$2" __amp='&amp;' __lt='&lt;' __gt='&gt;' __quot='&quot;'
  __s="${__s//&/$__amp}"
  __s="${__s//</$__lt}"
  __s="${__s//>/$__gt}"
  __s="${__s//\"/$__quot}"
  printf -v "$1" '%s' "$__s"
}

# fl_bash_dq_escape_v VAR TEXT: TEXT as it must be written between bash
# double quotes to mean itself (\ " $ ` escaped)
fl_bash_dq_escape_v() {
  local __s="$2" __bs="\\" __bt='`' __dq='"' __dl='$'
  __s="${__s//"$__bs"/$__bs$__bs}"
  __s="${__s//"$__dq"/$__bs$__dq}"
  __s="${__s//"$__dl"/$__bs$__dl}"
  __s="${__s//"$__bt"/$__bs$__bt}"
  printf -v "$1" '%s' "$__s"
}

# fl_template_render NAME KEY=VALUE...  (NAME is the file under templates/, without .tmpl)
# Prints the rendered content including the resolved header line.
fl_template_render() {
  local name="$1" file body hbody line hline pair key value hash version only_token unhashed="" quoted="" fmt=bash i n=0 e
  local keys=() vals=() evals=()
  shift
  file="${FL_TEMPLATE_DIR}/${name}.tmpl"
  [[ -f "$file" ]] || { fl_fail "template not found: ${file}"; return 1; }
  version="$(fl_template_version "$file")"
  case "$name" in *.plist) fmt=xml ;; esac
  # the values once, with their escaped form for where the template says
  # they sit inside double quotes (or everywhere, in XML)
  for pair in "$@"; do
    keys[n]="${pair%%=*}"; vals[n]="${pair#*=}"
    if [[ "$fmt" == xml ]]; then fl_xml_escape_v e "${vals[$n]}"; else fl_bash_dq_escape_v e "${vals[$n]}"; fi
    evals[n]="$e"
    n=$((n + 1))
  done
  body=""; hbody=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      '#@version'*) continue ;;
      '#@unhashed'*) unhashed="${unhashed} ${line#'#@unhashed'} "; continue ;;
      '#@quoted'*) quoted="${line#'#@quoted'}"; quoted=" ${quoted%%#*} "; continue ;;
    esac
    only_token=0
    [[ "$line" =~ ^__[A-Z_]+__$ ]] && only_token=1
    hline="$line"
    for ((i = 0; i < n; i++)); do
      key="${keys[$i]}"
      value="${vals[$i]}"
      if [[ "$fmt" == xml ]]; then value="${evals[$i]}"
      elif [[ -n "$quoted" ]]; then case "$quoted" in *" ${key} "*) value="${evals[$i]}" ;; esac
      fi
      line="${line//__${key}__/$value}"
      # the hashed copy keeps an unhashed key's token
      if [[ -n "$unhashed" ]]; then
        case "$unhashed" in *" ${key} "*) ;; *) hline="${hline//__${key}__/$value}" ;; esac
      fi
    done
    [[ -n "$unhashed" ]] || hline="$line"
    [[ "$only_token" == "1" && -z "$line" ]] && continue
    body="${body}${line}"$'\n'
    hbody="${hbody}${hline}"$'\n'
  done <"$file"
  hash="$(printf '%s' "$hbody" | fl_content_hash)"
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

# the backup folder of this run: the log's stamp when there is a log (set
# by fl_log_init), else date, time and pid, unique per run either way
fl_backup_stamp() {
  [[ -n "$FL_BACKUP_STAMP" ]] || FL_BACKUP_STAMP="$(date +%Y%m%d-%H%M%S)-$$"
  printf '%s' "$FL_BACKUP_STAMP"
}

# fl_backup_dest PATH: where PATH goes in this run's backup folder
fl_backup_dest() {
  local flat
  flat="$(printf '%s' "$1" | sed -e "s#^${HOME}#HOME#" -e 's#^/##' -e 's#/#__#g')"
  printf '%s/%s/%s' "$FL_BACKUP_ROOT" "$(fl_backup_stamp)" "$flat"
}

# fl_backup_file PATH: copies PATH into the backup folder for this run.
# Sets FL_LAST_BACKUP to the copy. Never deletes anything.
fl_backup_file() {
  local path="$1" dest
  FL_LAST_BACKUP=""
  [[ -e "$path" ]] || return 0
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would back up ${path}"
    return 0
  fi
  dest="$(fl_backup_dest "$path")"
  # a backup that did not happen must stop the change it was meant to cover
  mkdir -p "$(dirname "$dest")" 2>/dev/null || { fl_fail "could not create the backup folder $(dirname "$dest")"; return 1; }
  cp -p "$path" "$dest" 2>/dev/null || { fl_fail "could not back up ${path} to ${dest}"; return 1; }
  FL_LAST_BACKUP="$dest"
  fl_log "backup: ${path} -> ${dest}"
}

# fl_backup_link LINK: keeps the symlink itself, not the file it leads to,
# in the backup folder for this run: a link with the same target, which
# may be gone already. Sets FL_LAST_BACKUP to it.
fl_backup_link() {
  local link="$1" dest
  FL_LAST_BACKUP=""
  [[ -L "$link" ]] || return 0
  if [[ "${FL_DRY_RUN:-0}" == "1" ]]; then
    fl_info "dry-run: would back up the link ${link}"
    return 0
  fi
  dest="$(fl_backup_dest "$link")"
  mkdir -p "$(dirname "$dest")" 2>/dev/null || { fl_fail "could not create the backup folder $(dirname "$dest")"; return 1; }
  ln -sfn "$(readlink "$link")" "$dest" 2>/dev/null || { fl_fail "could not back up the link ${link}"; return 1; }
  FL_LAST_BACKUP="$dest"
  fl_log "backup: ${link} -> ${dest} (a link to $(readlink "$link"))"
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
  mv "$path" "$dest" 2>/dev/null || { fl_fail "could not move ${path} aside to ${dest}"; return 1; }
  fl_log "moved aside: ${path} -> ${dest}"
  fl_info "moved aside: ${dest}"
}

# fl_template_apply PATH RENDERED [MODE]: backs up PATH when it exists, then
# writes RENDERED atomically. Prints nothing when the file is already current.
# Returns 0 and sets FL_TEMPLATE_CHANGED=1 when a write happened; returns 1,
# with the old file untouched, when any stage of the write fails (a read
# only folder, a full disk, a backup that could not be made): the callers
# run inside "if act_...; then", where a failure not returned would be
# reported as done.
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
  fl_backup_file "$path" || return 1
  mkdir -p "$(dirname "$path")" 2>/dev/null || { fl_fail "could not create $(dirname "$path")"; return 1; }
  tmp="$(mktemp "${path}.tmp.XXXXXX" 2>/dev/null)" || { fl_fail "could not write into $(dirname "$path") (read only?)"; return 1; }
  printf '%s' "$rendered" >"$tmp" 2>/dev/null || { rm -f "$tmp"; fl_fail "could not write ${tmp} (disk full?)"; return 1; }
  if [[ -n "$mode" ]]; then chmod "$mode" "$tmp" 2>/dev/null || { rm -f "$tmp"; fl_fail "could not set mode ${mode} on ${tmp}"; return 1; }; fi
  mv -f "$tmp" "$path" 2>/dev/null || { rm -f "$tmp"; fl_fail "could not replace ${path}"; return 1; }
  fl_log "wrote ${path} (${status})"
  FL_TEMPLATE_CHANGED=1
}
