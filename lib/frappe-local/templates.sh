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
#   #@default KEY text     stripped on render; the text stands for __KEY__ when no
#                          KEY=value is passed (a \n in it is a line break). A
#                          template can grow a per platform variable and still
#                          render byte for byte as before where none is given.
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

# FL_TEMPLATE_DIR is a test seam: a production run ignores it (FL_TESTING)
if [[ "${FL_TESTING:-}" == "1" ]]; then FL_TEMPLATE_DIR="${FL_TEMPLATE_DIR:-${SCRIPT_DIR}/templates}"; else FL_TEMPLATE_DIR="${SCRIPT_DIR}/templates"; fi
FL_BACKUP_ROOT="${FL_BACKUP_ROOT:-${FL_STATE_DIR}/backups}"
FL_BACKUP_STAMP=""
FL_LAST_BACKUP=""

fl_content_hash() {
  local sum
  if [[ "$OSTYPE" == linux* ]] && command -v sha256sum >/dev/null 2>&1; then
    # the same 12 hex digits as shasum -a 256, from the C program: on Linux shasum is a Perl script
    # (a start is 20 ms there, sha256sum's is 1 ms), and a render of the service files hashes six
    sum="$(sha256sum)"; printf '%s\n' "${sum:0:12}"
  elif command -v shasum >/dev/null 2>&1; then
    # the first 12 hex digits, cut in bash (one program, not two)
    sum="$(shasum -a 256)"; printf '%s\n' "${sum:0:12}"
  elif command -v sha256sum >/dev/null 2>&1; then
    # the same 12 hex digits as shasum -a 256 (no shasum on a minimal Linux)
    sha256sum | cut -c1-12
  else
    cksum | awk '{print $1}'
  fi
}

fl_template_version() {
  local line re='^#@version[[:space:]]*([0-9][0-9]*)'
  [[ -r "$1" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $re ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; return 0; fi
  done <"$1"
  return 0
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
# The lines go into an array and are joined once at the end: appending each
# line to one growing string made bash copy the whole body per line, and the
# header went in by a substitution over that body, which bash 3.2 does
# character by character in a UTF-8 locale (94 ms for the 288 lines of
# bench-run.sh, 17 of which hold a token). The header now goes into its own
# lines, and the version is read in the same pass, not by a second read in a
# subshell.
fl_template_render() {
  local name="$1" file body hbody line hline pair key value hash version="" only_token unhashed="" quoted="" fmt=bash i n=0 e
  local keys=() vals=() evals=() dkeys=() dvals=() nd=0 given dk dv nl=$'\n' bsn='\n'
  local lines=() hidx=() hval=() tidx=() nb=0 nh=0 nt=0 vre='^#@version[[:space:]]*([0-9][0-9]*)' IFS
  shift
  file="${FL_TEMPLATE_DIR}/${name}.tmpl"
  [[ -f "$file" ]] || { fl_fail "template not found: ${file}"; return 1; }
  case "$name" in *.plist) fmt=xml ;; esac
  # the values once, with their escaped form for where the template says
  # they sit inside double quotes (or everywhere, in XML)
  for pair in "$@"; do
    keys[n]="${pair%%=*}"; vals[n]="${pair#*=}"
    if [[ "$fmt" == xml ]]; then fl_xml_escape_v e "${vals[$n]}"; else fl_bash_dq_escape_v e "${vals[$n]}"; fi
    evals[n]="$e"
    n=$((n + 1))
  done
  while IFS= read -r line || [[ -n "$line" ]]; do
    # a line with no __ in it holds no token, no default and no header, and one that does not
    # start with #@ is no directive: it goes in as it is (almost every line)
    if [[ "$line" != *__* && "$line" != '#@'* ]]; then lines[nb]="$line"; nb=$((nb + 1)); continue; fi
    case "$line" in
      '#@version'*)
        # the first line that names a number is the version (what fl_template_version reads)
        if [[ -z "$version" && "$line" =~ $vre ]]; then version="${BASH_REMATCH[1]}"; fi
        continue ;;
      '#@unhashed'*) unhashed="${unhashed} ${line#'#@unhashed'} "; continue ;;
      '#@quoted'*) quoted="${line#'#@quoted'}"; quoted=" ${quoted%%#*} "; continue ;;
      '#@default '*)
        dk="${line#'#@default '}"; dv="${dk#* }"; dk="${dk%% *}"
        given=0
        for ((i = 0; i < n; i++)); do [[ "${keys[$i]}" == "$dk" ]] && given=1; done
        if [[ "$given" == "0" ]]; then dkeys[nd]="$dk"; dvals[nd]="${dv//"$bsn"/$nl}"; nd=$((nd + 1)); fi
        continue ;;
    esac
    if [[ "$line" != *__* ]]; then lines[nb]="$line"; nb=$((nb + 1)); continue; fi
    only_token=0
    [[ "$line" =~ ^__[A-Z_]+__$ ]] && only_token=1
    # a default stands in first, so the tokens inside it are filled below
    for ((i = 0; i < nd; i++)); do
      dv="${dvals[$i]}"
      line="${line//__${dkeys[$i]}__/$dv}"
    done
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
    [[ "$only_token" == "1" && -z "$line" ]] && continue
    # the hashed copy differs from the body only in the lines noted here
    if [[ -n "$unhashed" && "$hline" != "$line" ]]; then hidx[nh]="$nb"; hval[nh]="$hline"; nh=$((nh + 1)); fi
    # the header goes in once the hash is known, into the lines that hold its token
    if [[ "$line" == *__HEADER__* ]]; then tidx[nt]="$nb"; nt=$((nt + 1)); fi
    lines[nb]="$line"; nb=$((nb + 1))
  done <"$file"
  [[ "$nb" -gt 0 ]] || return 0
  IFS="$nl"
  if [[ "$nh" -gt 0 ]]; then
    for ((i = 0; i < nh; i++)); do e="${lines[${hidx[$i]}]}"; lines[${hidx[$i]}]="${hval[$i]}"; hval[i]="$e"; done
    hbody="${lines[*]}${nl}"
    for ((i = 0; i < nh; i++)); do lines[${hidx[$i]}]="${hval[$i]}"; done
  else
    hbody="${lines[*]}${nl}"
  fi
  hash="$(printf '%s' "$hbody" | fl_content_hash)"
  value="${FL_TEMPLATE_TOKEN}: ${name} v${version:-1} ${hash}"
  for ((i = 0; i < nt; i++)); do line="${lines[${tidx[$i]}]}"; lines[${tidx[$i]}]="${line//__HEADER__/$value}"; done
  printf '%s\n' "${lines[*]}"
}

# fl_template_header_line_v VAR LINE: "<name> vN <hash>" when LINE holds a
# template header (what grep -o with FL_TEMPLATE_HEADER_RE found, minus the
# "benchbar-template: " words), else VAR is left empty
fl_template_header_line_v() {
  local __re='(benchbar|frappe-mac)-template: ([A-Za-z0-9._-]* v[0-9]* [0-9a-f]*)'
  printf -v "$1" '%s' ""
  [[ "$2" == *-template:* && "$2" =~ $__re ]] && printf -v "$1" '%s' "${BASH_REMATCH[2]}"
  return 0
}

# Prints "<name> vN <hash>" from the first header on stdin, or nothing. Read in
# bash: doctor asks this for every service file, and a grep, an awk and a sed
# for each of them was most of its programs.
fl_template_header_key() {
  local line key=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    fl_template_header_line_v key "$line"
    [[ -z "$key" ]] || { printf '%s\n' "$key"; return 0; }
  done
  return 0
}

# Prints the header key found in an existing file, or nothing.
fl_template_installed_header() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  fl_template_header_key <"$path" 2>/dev/null || true
}

fl_template_header_of() {
  fl_template_header_key <<<"$1"
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
