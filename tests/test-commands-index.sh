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
#   5. without the index file the lookups still answer, by the scan.
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
  ask() { # WHAT...: the answer of one lookup, by the index and by the scan
    local a b
    FL_CMD_INDEXED=1; a="$("$@" 2>&1; printf "|%s|%s" "$?" "${FL_BAD_FLAGS:-}")" || true
    FL_CMD_INDEXED=0; b="$("$@" 2>&1; printf "|%s|%s" "$?" "${FL_BAD_FLAGS:-}")" || true
    FL_CMD_INDEXED=1
    n=$((n + 1))
    [[ "$a" == "$b" ]] || printf "%s: index [%s] scan [%s]\n" "$*" "$a" "$b"
  }
  attr() { local v; fl_cmd_attr_v v "$1" "$2"; printf "%s" "$v"; }
  key3() { ARGS=("${2:-}" "${3:-}"); fl_cmd_key_for "$1" "${2:-}"; }
  fl_cmd_attr_v _ status json   # the index is read here, in this shell
  while IFS="~" read -r kind key name val _; do
    case "$kind" in
      cmd)
        for f in tty sudo network mutating json nosuchfield; do ask attr "$key" "$f"; done
        set -f; set -- $key; set +f
        ask key3 "$1"; ask key3 "$1" "${2:-}"; ask key3 "$1" "${2:-}" "${3:-}"
        ask key3 "$1" nosuchword; ask key3 "$1" "${2:-nosuchword}" nosuchword; ask key3 "$1" --json x
        ask fl_cmd_flag_check "$key" --no-such-flag; ask fl_cmd_flag_check "$key" -Z; ask fl_cmd_flag_check "$key" plain words ;;
      flag)
        ask fl_cmd_flag_check "$key" "$name"
        ask fl_cmd_flag_check "$key" "$name" --no-such-flag
        ask fl_cmd_flag_check "$key" "${name}=x" --no-such-flag
        ask fl_cmd_flag_check "$key" "${name}20" -Z
        ask fl_cmd_flag_check "$key" -- "$name" --no-such-flag ;;
    esac
  done <<<"$FL_CMD_TABLE"
  ask key3 nosuchcommand; ask key3 "" ""; ask attr nosuchcommand json; ask attr "" json
  ask fl_cmd_flag_check nosuchcommand --json
  printf "asked %s\n" "$n"
')"
case "$DIFF" in
  "asked "*) n="${DIFF#asked }"; [[ "$n" -gt 2000 ]] || fail "only $n lookups were compared" ;;
  *) fail "the index and the scan of the table differ:"$'\n'"$(printf '%s\n' "$DIFF" | head -20)" ;;
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
HOSTILE=('x[$(touch '"$PWNED"')]' 'status;touch '"$PWNED" 'a b' 'A' 'st*tus' 'site list x y' '-' 'x y z w' $'status\nx' 'é' '${HOME}' 'x__y' 'site_list')
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
cp "$ROOT/lib/frappe-local/ui.sh" "$ROOT/lib/frappe-local/commands.sh" "$ROOT/lib/frappe-local/help.sh" "$ROOT/lib/frappe-local/help-layout.txt" "$TMP_DIR/noindex/lib/frappe-local/"
assert_eq "0|document|site list|0" "$(LIB_ROOT="$TMP_DIR/noindex" lib '
  fl_cmd_attr_v j status json; ARGS=(list); fl_cmd_key_for_v k site list
  fl_cmd_flag_check logs --no-follow; printf "%s|%s|%s|%s" "$FL_CMD_INDEXED" "$j" "$k" "$?"')" "(no index file)"

printf 'test-commands-index: ok\n'
