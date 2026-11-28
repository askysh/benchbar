#!/usr/bin/env bash
#
# commands-index.sh: writes or checks lib/frappe-local/commands-index.sh, the index of the
# commands table (the records of lib/frappe-local/commands.sh).
#
#   bash scripts/commands-index.sh --write   make the index again, after a change of a cmd or flag record
#   bash scripts/commands-index.sh --check   exit 1 when the index is not what the table gives
#   bash scripts/commands-index.sh --print   the index on stdout
#
# The index holds, for each command key, one variable with its tty, sudo, network, mutating and
# json fields and one with its flags, and the length of the table in bytes. A lookup at run time
# reads one variable; without the index it reads the 500 lines of the table one by one (3 to
# 8 ms, on every start), and the load of the table looks for its end (10 ms on bash 3.2). The name of a
# variable is the key with a space as __ and a dash as _: this file refuses a key or a flag that
# such a name, or a line of the index, cannot carry.
# Runs under bash 3.2: no associative arrays, the flags of a key are gathered in a variable per key.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TABLE_FILE="${ROOT}/lib/frappe-local/commands.sh"
INDEX_FILE="${ROOT}/lib/frappe-local/commands-index.sh"

die() { printf 'commands-index: %s\n' "$1" >&2; exit 1; }

# name_v VAR KEY: the part of a variable name that stands for KEY
name_v() {
  local __n="${2// /__}"
  printf -v "$1" '%s' "${__n//-/_}"
}

index_text() {
  local line in_table=0 kind key usage summary tty sudo network mutating json name val rest n
  local flag_keys=() seen=" " fseen=" " k cur bytes=0 LC_ALL=C
  printf '%s\n' '#!/usr/bin/env bash' '#' \
    '# commands-index.sh: the index of the commands table. Generated from the records of commands.sh' \
    '# by scripts/commands-index.sh --write: do not edit it, edit the records and run that.' \
    '# tests/test-commands-index.sh fails when the two differ. FL_CMDX_<key> holds the tty, sudo,' \
    '# network, mutating and json fields of a command, FL_CMDF_<key> its flags (NAME, or NAME= for' \
    '# one that takes a value); <key> is the table key with a space as __ and a dash as _.' \
    '# FL_CMD_TABLE_BYTES is the length of the records, by which fl_cmd_load cuts them out.' \
    '# shellcheck disable=SC2034  # read by name in commands.sh (fl__cmd_idx_v)'
  while IFS= read -r line; do
    if [[ "$in_table" == 0 ]]; then
      [[ "$line" != ": <<'TABLE'" ]] || in_table=1
      continue
    fi
    [[ "$line" != "TABLE" ]] || break
    bytes=$((bytes + ${#line} + 1))
    kind="${line%%~*}"
    case "$kind" in
      cmd)
        IFS='~' read -r _ key usage summary tty sudo network mutating json rest <<<"$line"
        case "$key" in ""|*[!abcdefghijklmnopqrstuvwxyz0123456789\ -]*|" "*|*" "|*"  "*) die "the key of a cmd record has a character the index cannot carry: ${key}" ;; esac
        for val in "$tty" "$sudo" "$network" "$mutating" "$json"; do
          case "$val" in ""|*[!abcdefghijklmnopqrstuvwxyz]*) die "a field of the cmd record ${key} is not a plain word: ${val}" ;; esac
        done
        name_v n "$key"
        case "$seen" in *" ${n} "*) die "two cmd records give the same index name: ${key}" ;; esac
        seen="${seen}${n} "
        printf "FL_CMDX_%s='%s~%s~%s~%s~%s'\n" "$n" "$tty" "$sudo" "$network" "$mutating" "$json" ;;
      flag)
        IFS='~' read -r _ key name val rest <<<"$line"
        case "$key" in ""|*[!abcdefghijklmnopqrstuvwxyz0123456789\ -]*) die "the key of a flag record has a character the index cannot carry: ${key}" ;; esac
        case "$name" in -[!-]*|--[!-]*) ;; *) die "a flag of ${key} does not start with one or two dashes: ${name}" ;; esac
        case "$name" in *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-]*) die "a flag of ${key} has a character the index cannot carry: ${name}" ;; esac
        name_v n "$key"
        case "$fseen" in *" ${n} "*) ;; *) fseen="${fseen}${n} "; flag_keys+=("$n"); printf -v "IDX_F_${n}" '%s' "" ;; esac
        cur="IDX_F_${n}"
        printf -v "IDX_F_${n}" '%s %s%s' "${!cur}" "$name" "${val:+=}" ;;
    esac
  done <"$TABLE_FILE"
  [[ "$in_table" == 1 ]] || die "no table in ${TABLE_FILE}"
  for k in ${flag_keys[@]+"${flag_keys[@]}"}; do
    cur="IDX_F_${k}"
    printf "FL_CMDF_%s='%s'\n" "$k" "${!cur}"
  done
  # the bytes of the records, without the line end before the end marker (fl_cmd_load cuts by it)
  printf 'FL_CMD_TABLE_BYTES=%s\n' "$((bytes - 1))"
  printf '%s\n' 'FL_CMD_INDEXED=1'
}

case "${1:-}" in
  --print) index_text ;;
  --write)
    index_text >"${INDEX_FILE}.tmp"
    mv "${INDEX_FILE}.tmp" "$INDEX_FILE"
    printf 'commands-index: wrote %s\n' "${INDEX_FILE#"${ROOT}/"}" ;;
  --check)
    want="$(index_text)"
    have="$(cat "$INDEX_FILE" 2>/dev/null || true)"
    if [[ "$want" != "$have" ]]; then
      printf 'commands-index: lib/frappe-local/commands-index.sh is not what the commands table gives.\n' >&2
      printf 'A cmd or flag record of commands.sh changed. Make the index again: bash scripts/commands-index.sh --write\n' >&2
      diff <(printf '%s\n' "$have") <(printf '%s\n' "$want") | sed -n '1,20p' >&2 || true
      exit 1
    fi
    printf 'commands-index: ok\n' ;;
  *) die "use --write, --check or --print" ;;
esac
