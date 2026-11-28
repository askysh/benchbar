#!/usr/bin/env bash
# The guards of state.sh hold under a mkdir that answers as uutils coreutils does (issue 340): a run
# that loses the race to make a folder is told it made it. The state move guard and the reclaim guard
# of the key=value store take the folder with fl_mkdir_excl, so a held guard stays held.
# shellcheck disable=SC2016  # the snippets in single quotes run in a child bash, which expands them
set -euo pipefail
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

UU_DIR="$TMP_DIR/uu"
mkdir -p "$UU_DIR/bin"
# mkdir as uutils coreutils answers the run that lost the race to make a folder: made
printf '#!/bin/bash\n"%s" "$@" 2>/dev/null || [[ -d "${!#}" ]]\n' "$(command -v mkdir)" >"$UU_DIR/bin/mkdir"
chmod +x "$UU_DIR/bin/mkdir"

# uu SCRIPT ARGS...: SCRIPT runs with state.sh loaded (its own state folder) and the uutils mkdir first on PATH
uu() {
  local script="$1"; shift
  FL_STATE_DIR="$TMP_DIR/state" PATH="$UU_DIR/bin:$PATH" bash -c '. "$1/lib/frappe-local/state.sh"; shift; '"$script" _ "$ROOT" "$@"
}

# ---- the state move guard: a live run holds it, a second take waits and is refused
G="$TMP_DIR/guard-held"
mkdir "$G"; : >"$G/claim"; printf '%s\n' "$$" >"$G/pid"
assert_eq "held" "$(uu 'if fl_state_guard_take "$1"; then echo taken; else echo held; fi' "$G")" "(a guard a live run holds is not taken under the uutils mkdir)"
assert_eq "$$" "$(cat "$G/pid")" "(the holder's pid is still in the guard)"

# a free guard is taken, holds a claim, and its drop leaves nothing
F="$TMP_DIR/guard-free"
assert_eq "taken" "$(uu 'if fl_state_guard_take "$1"; then echo taken; else echo held; fi' "$F")" "(a free guard is taken)"
assert_eq "yes" "$([[ -e "$F/claim" && -s "$F/pid" ]] && echo yes || echo no)" "(the taken guard has its claim and a pid)"
uu 'fl_state_guard_drop "$1"' "$F"
assert_eq "gone" "$([[ -e "$F" ]] && echo there || echo gone)" "(the drop removes the guard with its claim)"

# ---- the reclaim guard of the store: a live reclaimer holds it, a second one moves nothing
LCK="$TMP_DIR/kv.env.lck"
mkdir "$LCK"; : >"$LCK/999999.1"
touch -t 202001010000 "$LCK"
mkdir "$LCK.reclaim"; : >"$LCK.reclaim/claim"
uu 'fl__kv_reclaim "$1" "$2"' "$LCK" "999999.1"
assert_eq "there" "$([[ -d "$LCK" ]] && echo there || echo gone)" "(a reclaim under a held guard leaves the lock alone)"
assert_eq "there" "$([[ -d "$LCK.reclaim" ]] && echo there || echo gone)" "(the held guard stays)"

# with the guard free, the stale lock goes and the guard is let go
rm -f "$LCK.reclaim/claim"; rmdir "$LCK.reclaim"
uu 'fl__kv_reclaim "$1" "$2"' "$LCK" "999999.1"
assert_eq "gone gone" "$([[ -e "$LCK" ]] && echo there || echo gone) $([[ -e "$LCK.reclaim" ]] && echo there || echo gone)" "(a free guard: the stale lock is reclaimed and the guard let go)"

printf 'test-state-guards: ok\n'
