#!/usr/bin/env bash
# The index of the commands table (lib/frappe-local/commands-index.sh, issue 137): a lookup of a
# command key, of one of its fields or of its flags reads one variable of the index, not the
# 500 lines of the table. This test holds what makes that safe:
#   1. the index is what scripts/commands-index.sh makes from the table now (a record that
#      changed without the index fails here, with the command that makes it again);
#   2. every lookup through the index gives what the scan of the table gives, for every key,
#      every field and every flag of the table;
#   3. a lookup with the index reads no table (it answers with the table emptied);
#   4. a word a person typed never becomes part of a variable name unless it is a plain key;
#   5. without the index file the lookups still answer, by the scan;
#   6. the table that is cut out by the length in the index is the table.
# shellcheck disable=SC2016  # the snippets in single quotes run in a child bash, which expands them
set -euo pipefail
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# lib SCRIPT ARGS...: SCRIPT in a bash that has ui.sh and commands.sh of LIB_ROOT (default: this checkout)
lib() {
  local script="$1"; shift
  bash -c 'set -euo pipefail; . "$1/lib/frappe-local/ui.sh"; . "$1/lib/frappe-local/commands.sh"; ARGS=(); shift; '"$script" _ "${LIB_ROOT:-$ROOT}" "$@"
}

# ---- 1. the index is in step with the table
OUT="$(bash "$ROOT/scripts/commands-index.sh" --check 2>&1)" || fail "the index is not what the table gives: $OUT"
# and a record that changes is seen: a copy of the lib with one field changed
mkdir -p "$TMP_DIR/stale/lib/frappe-local" "$TMP_DIR/stale/scripts"
cp "$ROOT/lib/frappe-local/commands.sh" "$ROOT/lib/frappe-local/commands-index.sh" "$TMP_DIR/stale/lib/frappe-local/"
cp "$ROOT/scripts/commands-index.sh" "$TMP_DIR/stale/scripts/"
sed 's/^cmd~notices~\(.*\)~no~document$/cmd~notices~\1~yes~document/' "$ROOT/lib/frappe-local/commands.sh" >"$TMP_DIR/stale/lib/frappe-local/commands.sh"
cmp -s "$ROOT/lib/frappe-local/commands.sh" "$TMP_DIR/stale/lib/frappe-local/commands.sh" && fail "(the test did not change the notices record)"
set +e; OUT="$(bash "$TMP_DIR/stale/scripts/commands-index.sh" --check 2>&1)"; CODE="$?"; set -e
assert_eq 1 "$CODE" "(a changed record with the old index) $OUT"
assert_contains "$OUT" "bash scripts/commands-index.sh --write"

# ---- 2. the index and the scan agree, for every key, field and flag of the table
DIFF="$(lib '
  n=0
  # each lookup is made twice in this shell, by the index and by the scan (no subshell: about 4000 of them)
  both() { # WHAT INDEX_ANSWER SCAN_ANSWER
    n=$((n + 1))
    [[ "$2" == "$3" ]] || printf "%s: index [%s] scan [%s]\n" "$1" "$2" "$3"
  }
  attr() { local a b; FL_CMD_INDEXED=1; fl_cmd_attr_v a "$1" "$2"; FL_CMD_INDEXED=0; fl_cmd_attr_v b "$1" "$2"; FL_CMD_INDEXED=1; both "attr $1 $2" "$a" "$b"; }
  key3() { # COMMAND [ARG [THIRD]]
    local a b ra=0 rb=0
    ARGS=("${2:-}" "${3:-}")
    FL_CMD_INDEXED=1; fl_cmd_key_for_v a "$1" "${2:-}" || ra=1
    FL_CMD_INDEXED=0; fl_cmd_key_for_v b "$1" "${2:-}" || rb=1
    FL_CMD_INDEXED=1; both "key $*" "${ra}|${a}" "${rb}|${b}"
  }
  flags() { # KEY ARG...
    local a b
    FL_CMD_INDEXED=1; if fl_cmd_flag_check "$@"; then a="0|${FL_BAD_FLAGS}"; else a="1|${FL_BAD_FLAGS}"; fi
    FL_CMD_INDEXED=0; if fl_cmd_flag_check "$@"; then b="0|${FL_BAD_FLAGS}"; else b="1|${FL_BAD_FLAGS}"; fi
    FL_CMD_INDEXED=1; both "flags $*" "$a" "$b"
  }
  fl_cmd_attr_v _ status json   # the index is read here
  [[ "$FL_CMD_INDEXED" == 1 ]] || { printf "the index was not read\n"; exit 0; }
  while IFS="~" read -r kind key name val _; do
    case "$kind" in
      cmd)
        for f in tty sudo network mutating json nosuchfield; do attr "$key" "$f"; done
        set -f; set -- $key; set +f
        key3 "$1"; key3 "$1" "${2:-}"; key3 "$1" "${2:-}" "${3:-}"
        key3 "$1" nosuchword; key3 "$1" "${2:-nosuchword}" nosuchword; key3 "$1" --json x
        flags "$key" --no-such-flag; flags "$key" -Z; flags "$key" plain words ;;
      flag)
        flags "$key" "$name"
        flags "$key" "$name" --no-such-flag
        flags "$key" "${name}=x" --no-such-flag
        flags "$key" "${name}20" -Z ;;
    esac
  done <<<"$FL_CMD_TABLE"
  key3 nosuchcommand; key3 "" ""; attr nosuchcommand json; attr "" json
  flags nosuchcommand --json
  printf "asked %s\n" "$n"
')"
case "$DIFF" in
  "asked "*) n="${DIFF#asked }"; [[ "$n" -gt 2000 ]] || fail "only $n lookups were compared" ;;
  *) fail "the index and the scan of the table differ:"$'\n'"$(printf '%s\n' "$DIFF" | sed -n '1,20p')" ;;
esac

# ---- 3. with the index a lookup reads no table: it answers with the table emptied
assert_eq "document|no|site snapshot drop|site list|status|0|1 --nope" "$(lib '
  FL_CMD_TABLE=""
  fl_cmd_attr_v j status json; fl_cmd_attr_v m status mutating
  ARGS=(snapshot drop); fl_cmd_key_for_v k3 site snapshot
  ARGS=(list --json); fl_cmd_key_for_v k2 site list
  ARGS=(--json); fl_cmd_key_for_v k1 status --json
  fl_cmd_flag_check logs --no-follow -n 20; a="$?"
  set +e; fl_cmd_flag_check logs --nope; b="$? ${FL_BAD_FLAGS}"; set -e
  printf "%s|%s|%s|%s|%s|%s|%s" "$j" "$m" "$k3" "$k2" "$k1" "$a" "$b"')" "(lookups with the table emptied)"
# the printing form gives the same key, and fails for a command the table does not have
assert_eq "site list" "$(lib 'ARGS=(list); fl_cmd_key_for site list')"
assert_eq "no" "$(lib 'if fl_cmd_key_for nosuchcommand >/dev/null; then echo yes; else echo no; fi')"

# ---- 4. a typed word is never part of a variable name unless it is a plain key
PWNED="$TMP_DIR/pwned"
HOSTILE=('x[$(touch '"$PWNED"')]' 'status;touch '"$PWNED" 'a b' 'A' 'st*tus' 'site list x y' '-' 'x y z w' $'status\nx' 'é' '${HOME}' 'x__y' 'site_list' 'site--list')
for word in "${HOSTILE[@]}"; do
  OUT="$(lib '
    ARGS=("$1" "$1"); r=0
    fl_cmd_key_for_v k "$1" "$1" || r=1
    fl_cmd_key_for_v k2 site "$1" || true
    fl_cmd_attr_v a "$1" json
    set +e; fl_cmd_flag_check "$1" --json; f="$?"; set -e
    printf "%s|%s|%s|%s|%s" "$r" "$k" "$k2" "$a" "$f"' "$word" 2>&1)"
  assert_eq "1||site||1" "$OUT" "(the word ${word})"
done
assert_no_file "$PWNED"

# ---- 5. without the index file the lookups answer by the scan
mkdir -p "$TMP_DIR/noindex/lib/frappe-local"
for f in "$ROOT"/lib/frappe-local/*; do
  [[ -d "$f" || "${f##*/}" == commands-index.sh ]] || cp "$f" "$TMP_DIR/noindex/lib/frappe-local/"
done
assert_no_file "$TMP_DIR/noindex/lib/frappe-local/commands-index.sh"
assert_eq "0|document|site list|0" "$(LIB_ROOT="$TMP_DIR/noindex" lib '
  fl_cmd_attr_v j status json; ARGS=(list); fl_cmd_key_for_v k site list
  fl_cmd_flag_check logs --no-follow; printf "%s|%s|%s|%s" "$FL_CMD_INDEXED" "$j" "$k" "$?"')" "(no index file)"

# ---- 6. the table is cut out by the length the index gives, and it is the table the search for its end gives
assert_eq "by length|same|same" "$(lib '
  LC_ALL=C; a="$FL_CMD_TABLE"; r="by search"
  [[ "${#a}" != "$FL_CMD_TABLE_BYTES" ]] || r="by length"
  FL_CMD_TABLE_BYTES=""; fl_cmd_load; [[ "$a" != "$FL_CMD_TABLE" ]] || r="${r}|same"
  FL_CMD_TABLE_BYTES=10; fl_cmd_load; [[ "$a" != "$FL_CMD_TABLE" ]] || r="${r}|same"
  printf "%s" "$r"')" "(the table with the length, without it, and with a wrong one)"

printf 'test-commands-index: ok\n'
