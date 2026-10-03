#!/usr/bin/env bash
#
# state.sh: the folder benchbar keeps its own state in (the remembered
# benches, per bench settings, logs, backups, the lock), and the small
# key=value store in its state.env.
#
# A packaged CLI (homebrew, managed or app, see install-kind.sh) keeps it in
# ~/.local/state/benchbar, outside the install folder: brew upgrade
# installs every version into a new folder, and brew cleanup deletes the
# old one. The path is fixed, not ${XDG_STATE_HOME}: BenchBar.app, an MCP
# client and launchd start the CLI without the variables of ~/.zshrc, and
# every caller must find the same state and the same lock. Any other CLI, a
# checkout, keeps .benchbar next to itself. FL_STATE_DIR from the
# environment wins over both.
#
# The one line installer's checkout kept it in
# ~/.local/share/benchbar/.benchbar until 0.7.0. The first run of a packaged
# CLI moves that folder there with one mv (a rename) and leaves a symlink at
# the old path, so an older CLI still on the Mac reads the same state and
# takes the same lock; a later run makes that link again when it is gone. A
# run that holds the old folder's lock defers the move: until it ends, the
# old folder is used as is. On another volume mv would copy, and a copy cut
# short would pass for the state, so the folder stays where it is and the
# new path is a link to it. Nothing is copied or deleted.
#
# BenchBar.app makes ~/.local/state/benchbar/bin/benchbar at launch, often
# before the first CLI run: a new folder that holds nothing but that bin/
# (and a .DS_Store) is no state, and the checkout's folder still moves in.
# One first run at a time: a guard folder (mkdir, with a pid file, like the
# lock) is taken before the checks; a run that finds it held waits for it,
# and one left by a dead run is reclaimed.
#
# The folder was .frappe-local before 0.3.0. The first run after the
# upgrade renames it (one atomic mv in the checkout), unless a run holds
# its lock right now; until then the old folder is used as is.

# fl_state_dir_in_v VAR DIR: DIR/.benchbar, or DIR/.frappe-local while a
# run holds that one's lock
fl_state_dir_in_v() {
  local __new="${2}/.benchbar" __old="${2}/.frappe-local"
  if [[ -d "$__old" && ! -e "$__new" && ! -d "${__old}/lock" ]]; then
    mv "$__old" "$__new" 2>/dev/null || true
  fi
  if [[ -d "$__new" || ! -d "$__old" ]]; then printf -v "$1" '%s' "$__new"; else printf -v "$1" '%s' "$__old"; fi
}

# fl_state_dir_shell_only DIR: true when DIR holds no state, only bin/ (the
# link BenchBar.app makes to its CLI at launch, before the first CLI run)
# and perhaps a .DS_Store. Globs, no process.
fl_state_dir_shell_only() {
  local __e
  for __e in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [[ -e "$__e" || -L "$__e" ]] || continue
    case "${__e##*/}" in bin|.DS_Store) ;; *) return 1 ;; esac
  done
  return 0
}

# fl_state_guard_stale GUARD: true when the run that made GUARD is gone (the
# pid inside is dead) or GUARD is older than 60 s (a pid number reused by
# another process would otherwise hold it for good). One cat, one stat and
# one date, and only when a guard exists.
fl_state_guard_stale() {
  local __pid __m="" __now=""
  __pid="$(cat "${1}/pid" 2>/dev/null || true)"
  if [[ -n "$__pid" ]] && ! kill -0 "$__pid" 2>/dev/null; then return 0; fi
  __m="$( (stat -c %Y "$1" || stat -f %m "$1") 2>/dev/null)"
  __now="$(date +%s 2>/dev/null || true)"
  [[ -n "$__m" && -n "$__now" && $((__now - __m)) -gt 60 ]]
}

# fl_state_guard_drop GUARD: removes what a run leaves in its guard: the pid
# file, the app's link in bin/ (a symlink only) and empty folders. Anything
# else stays, and the folder with it, never deleted.
fl_state_guard_drop() {
  local __d
  rm -f "${1}/pid" 2>/dev/null || true
  if [[ -L "${1}/bin/benchbar" ]]; then rm -f "${1}/bin/benchbar" 2>/dev/null || true; fi
  for __d in bin shell; do
    if [[ -d "${1}/${__d}" ]]; then rmdir "${1}/${__d}" 2>/dev/null || true; fi
  done
  rmdir "$1" 2>/dev/null || true
}

# fl_state_guard_reclaim GUARD: a stale guard goes, claimed by a rename
# first (mv is atomic: of two runs that both saw the dead pid, one gets
# it). Returns 1 when another run claimed it.
fl_state_guard_reclaim() {
  mv "$1" "${1}.stale.$$" 2>/dev/null || return 1
  fl_state_guard_drop "${1}.stale.$$"
  return 0
}

# fl_state_guard_take GUARD: one first run at a time. The guard is a folder
# (mkdir is atomic) holding the owner's pid, made before any check of the
# move. A run that finds it held waits up to 5 s for the owner to finish; a
# stale one (fl_state_guard_stale, or no pid written by the end of the
# wait) is reclaimed. Returns 1 while a live run still holds it: the caller
# then uses the state where it is.
fl_state_guard_take() {
  local __g="$1" __i __round
  if mkdir "$__g" 2>/dev/null; then printf '%s\n' "$$" >"${__g}/pid" 2>/dev/null || true; return 0; fi
  for __round in 1 2; do
    for ((__i = 0; __i < 50; __i++)); do
      [[ -d "$__g" ]] || break
      ! fl_state_guard_stale "$__g" || break
      sleep 0.1
    done
    [[ -d "$__g" ]] || break
    if [[ -s "${__g}/pid" ]] && ! fl_state_guard_stale "$__g"; then return 1; fi
    fl_state_guard_reclaim "$__g" && break
    # another waiter reclaimed it first and holds it now: one more wait
  done
  mkdir "$__g" 2>/dev/null || return 1
  printf '%s\n' "$$" >"${__g}/pid" 2>/dev/null || true
  return 0
}

# fl_state_dir_user_v VAR: the state folder of a packaged CLI, after the
# one time move of the installer checkout's folder. A few tests on every
# run but the first, and no process: status runs this on every poll.
#
# BenchBar.app makes ~/.local/state/benchbar/bin/benchbar at launch, before
# the first CLI run, so the new folder may exist with nothing but that
# link in it. That is no state: the checkout's folder still moves. bin/
# goes into that folder first (one mv), the emptied folder is removed
# (rmdir, atomic), and the rename that puts the state in place brings
# bin/benchbar back with it. A run cut short after any step leaves a
# layout the next run finishes from: a bin/ already in the checkout's
# folder is part of the state folder now, not a state of its own.
fl_state_dir_user_v() {
  local __base="${HOME%/}/.local/state" __new legacy __mh="${FL_MANAGED_HOME:-${HOME%/}/.local/share/benchbar}" __d1="" __d2="" __guard __shell=0 __bin_to=""
  __new="${__base}/benchbar"
  __guard="${__base}/.benchbar-migrating"
  printf -v "$1" '%s' "$__new"
  if [[ -e "$__new" || -L "$__new" ]]; then
    if [[ -d "$__new" && ! -L "$__new" ]] \
      && { [[ -d "${__mh}/.benchbar" && ! -L "${__mh}/.benchbar" ]] || [[ -d "${__mh}/.frappe-local" && ! -L "${__mh}/.frappe-local" ]]; } \
      && fl_state_dir_shell_only "$__new"; then
      : # the app's bin/ came first: the state is still in the checkout, and moves below
    else
      # moved before, but the link is gone (a run stopped between the mv and
      # the ln): an older CLI there would start empty, so it is made again
      if [[ -d "$__mh" && -d "$__new" && ! -L "$__new" && ! -e "${__mh}/.benchbar" && ! -L "${__mh}/.benchbar" && ! -e "${__mh}/.frappe-local" ]]; then
        ln -sn "$__new" "${__mh}/.benchbar" 2>/dev/null || true
      fi
      # a guard a run killed after the move left: swept, so no later run
      # waits on it (one -d test here; the rest only when there is one)
      if [[ -d "$__guard" ]] && fl_state_guard_stale "$__guard"; then fl_state_guard_reclaim "$__guard" || true; fi
      return 0
    fi
  fi
  fl_state_dir_in_v legacy "$__mh"
  # nothing to move; a symlink there is a move made before
  [[ -d "$legacy" && ! -L "$legacy" ]] || return 0
  if [[ -d "${legacy}/lock" ]]; then printf -v "$1" '%s' "$legacy"; return 0; fi
  mkdir -p "$__base" 2>/dev/null || true
  if ! fl_state_guard_take "$__guard"; then
    # another first run still holds the guard after the wait: the state as
    # it is now, the old folder unless the new one holds state already
    if [[ -d "$legacy" && ! -L "$legacy" ]] && { [[ ! -d "$__new" ]] || fl_state_dir_shell_only "$__new"; }; then printf -v "$1" '%s' "$legacy"; fi
    return 0
  fi
  # checked again, holding the guard: another first run may have moved it
  # while this one waited for the guard or made the base folder
  if [[ ! -d "$legacy" || -L "$legacy" ]]; then
    [[ -d "$__new" ]] || printf -v "$1" '%s' "$legacy"
    fl_state_guard_drop "$__guard"
    return 0
  fi
  # another volume? One stat of both, before anything moves.
  { read -r __d1; read -r __d2; } < <( (stat -c %d "$__base" "$__mh" || stat -f %d "$__base" "$__mh") 2>/dev/null)
  if [[ -e "$__new" || -L "$__new" ]]; then
    if [[ -d "$__new" && ! -L "$__new" ]] && fl_state_dir_shell_only "$__new"; then
      # the app's bin/ goes into the checkout's folder first, so the rename
      # that puts that folder in place brings bin/benchbar back with it (a
      # run cut short after this step leaves a layout the next run finishes
      # from). When a run cut short left one there already, this one waits
      # in the guard instead.
      if [[ -d "${__new}/bin" ]]; then
        if [[ ! -e "${legacy}/bin" && ! -L "${legacy}/bin" ]]; then __bin_to="${legacy}/bin"; else __bin_to="${__guard}/bin"; fi
        if ! mv "${__new}/bin" "$__bin_to" 2>/dev/null; then fl_state_guard_drop "$__guard"; return 0; fi
      fi
      # the emptied folder goes (an empty folder and a Finder file, never
      # state), so the rename is one step. When something appeared in it in
      # between, bin/ goes back and the next run tries again.
      rm -f "${__new}/.DS_Store" 2>/dev/null || true
      if ! rmdir "$__new" 2>/dev/null; then
        [[ -z "$__bin_to" ]] || mv "$__bin_to" "${__new}/bin" 2>/dev/null || true
        fl_state_guard_drop "$__guard"
        return 0
      fi
      __shell=1
    else
      # a state folder of its own: never merged into, the old one stays
      fl_state_guard_drop "$__guard"
      return 0
    fi
  fi
  # another volume: mv would copy, and a copy cut short would pass for the
  # state. The folder stays, and the new path leads to it.
  if [[ -z "$__d1" || "$__d1" != "$__d2" ]]; then
    ln -s "$legacy" "$__new" 2>/dev/null || true
    [[ -L "$__new" ]] || printf -v "$1" '%s' "$legacy"
  elif mv "$legacy" "$__new" 2>/dev/null; then
    if [[ -L "${__new}/${legacy##*/}" ]]; then
      # a second first run (an older CLI, which knows no guard) moved and
      # linked in between, so this mv put its link inside the new folder: it
      # goes back
      mv "${__new}/${legacy##*/}" "$legacy" 2>/dev/null || rm -f "${__new:?}/${legacy##*/}"
    elif [[ -d "${__new}/${legacy##*/}" ]]; then
      # the new folder came back in between (the app made bin/ again), so
      # this mv put the state inside it: back where it was
      mv "${__new}/${legacy##*/}" "$legacy" 2>/dev/null && printf -v "$1" '%s' "$legacy"
    else
      # -n: never through a link already at the old path (a waiting run's
      # fast path made it in between), which would put a link to the state
      # folder inside itself; one an older CLI put there goes
      ln -sn "$__new" "$legacy" 2>/dev/null || true
      if [[ -L "${__new}/${__new##*/}" ]]; then rm -f "${__new:?}/${__new##*/}"; fi
      if [[ ! -L "$legacy" ]]; then
        if [[ -d "$legacy" ]]; then
          # an older CLI made the folder again in between, and ln put the link
          # inside it: that link goes, the folder stays (doctor's Second CLI
          # names it), and this run uses the moved state
          if [[ -L "${legacy}/${__new##*/}" ]]; then rm -f "${legacy:?}/${__new##*/}"; fi
        elif mv "$__new" "$legacy" 2>/dev/null; then
          # without the link an older CLI would start empty: the move is undone
          printf -v "$1" '%s' "$legacy"
        fi
      fi
    fi
  elif [[ ! -d "$__new" ]]; then
    # not moved (when another run just moved it, the new folder is there)
    printf -v "$1" '%s' "$legacy"
  fi
  if [[ "$__shell" == "1" && ! -e "$__new" && ! -L "$__new" ]]; then
    # nothing took its place (the move was undone): the app's folder comes
    # back, bin/ in it, so the app's link works
    if mkdir "$__new" 2>/dev/null; then
      if [[ -d "${__guard}/bin" ]]; then mv "${__guard}/bin" "${__new}/bin" 2>/dev/null || true
      elif [[ -d "$legacy" && ! -L "$legacy" && -d "${legacy}/bin" ]]; then mv "${legacy}/bin" "${__new}/bin" 2>/dev/null || true; fi
    fi
  fi
  fl_state_guard_drop "$__guard"
  return 0
}

if [[ -z "${FL_STATE_DIR:-}" ]]; then
  case "${FL_INSTALL_KIND:-}" in
    homebrew|managed|app) fl_state_dir_user_v FL_STATE_DIR ;;
    *) fl_state_dir_in_v FL_STATE_DIR "$SCRIPT_DIR" ;;
  esac
fi
FL_STATE_FILE="${FL_STATE_FILE:-${FL_STATE_DIR}/state.env}"

fl_state_init() {
  [[ "${FL_DRY_RUN:-0}" == "1" ]] && return 0
  mkdir -p "$FL_STATE_DIR"
  touch "$FL_STATE_FILE"
}

# Writers of one key-value file serialize on FILE.lck (mkdir is atomic): a
# status poll of the app and a repair writing the same bench file at once
# must not lose each other's keys. A short wait, then the write goes ahead
# anyway (a lock left by a killed writer must not block forever).
fl__kv_lock() {
  local lck="$1.lck" i=0
  while ! mkdir "$lck" 2>/dev/null; do
    i=$((i + 1))
    [[ "$i" -lt 40 ]] || { rm -rf "$lck"; continue; }
    sleep 0.05
  done
}
fl__kv_unlock() { rmdir "$1.lck" 2>/dev/null || true; }

# fl_kv_set FILE KEY VALUE and fl_kv_get FILE KEY: the store behind both
# the checkout's state.env and the per bench files. Nothing is written in a
# dry run, and an unchanged value is not written again. The new content is
# built in a temp file of its own (mktemp), never a fixed name two writers
# would share, and renamed into place under the file's lock.
fl_kv_set() {
  local file="$1" key="$2" value="$3" tmp
  [[ "${FL_DRY_RUN:-0}" == "1" ]] && return 0
  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  [[ -f "$file" ]] || : >"$file"
  if [[ "$(fl_kv_get "$file" "$key")" == "$value" ]]; then
    return 0
  fi
  fl__kv_lock "$file"
  if tmp="$(mktemp "${file}.XXXXXX" 2>/dev/null)"; then
    if { grep -v "^${key}=" "$file" 2>/dev/null || true; printf '%s=%q\n' "$key" "$value"; } >"$tmp"; then
      mv -f "$tmp" "$file" || rm -f "$tmp"
    else
      rm -f "$tmp"
    fi
  fi
  fl__kv_unlock "$file"
}

# fl_kv_decode_v VAR RAW: the value fl_kv_set wrote as RAW (printf %q),
# decoded without eval, so a hand edited state file can run no command and
# expand no glob or variable. The %q forms: plain text as it is; $'...'
# (a control character somewhere) with \n \t \\ \' and \NNN octal escapes;
# backslash before each space or metacharacter otherwise. A '...' form is
# its inner text. Anything else is the literal text.
fl_kv_decode_v() {
  local __raw="$2" __out="" __rest __c __oct
  case "$__raw" in
    "") printf -v "$1" '%s' '' ;;
    \$\'*\')
      __rest="${__raw#\$\'}"; __rest="${__rest%\'}"
      while [[ "$__rest" == *\\* ]]; do
        __out="${__out}${__rest%%\\*}"
        __rest="${__rest#*\\}"
        __c="${__rest:0:1}"
        case "$__c" in
          n) __out="${__out}"$'\n'; __rest="${__rest:1}" ;;
          t) __out="${__out}"$'\t'; __rest="${__rest:1}" ;;
          r) __out="${__out}"$'\r'; __rest="${__rest:1}" ;;
          a) __out="${__out}"$'\a'; __rest="${__rest:1}" ;;
          b) __out="${__out}"$'\b'; __rest="${__rest:1}" ;;
          f) __out="${__out}"$'\f'; __rest="${__rest:1}" ;;
          v) __out="${__out}"$'\v'; __rest="${__rest:1}" ;;
          e|E) __out="${__out}"$'\033'; __rest="${__rest:1}" ;;
          [0-7])
            __oct="$__c"; __rest="${__rest:1}"
            while [[ "${#__oct}" -lt 3 && "${__rest:0:1}" == [0-7] ]]; do __oct="${__oct}${__rest:0:1}"; __rest="${__rest:1}"; done
            printf -v __c '%b' "\\0${__oct}"
            __out="${__out}${__c}" ;;
          "") ;;
          *) __out="${__out}${__c}"; __rest="${__rest:1}" ;;
        esac
      done
      printf -v "$1" '%s' "${__out}${__rest}" ;;
    \'*\') __rest="${__raw#\'}"; printf -v "$1" '%s' "${__rest%\'}" ;;
    *\\*)
      __rest="$__raw"
      while [[ "$__rest" == *\\* ]]; do
        __out="${__out}${__rest%%\\*}"
        __rest="${__rest#*\\}"
        __out="${__out}${__rest:0:1}"
        __rest="${__rest:1}"
      done
      printf -v "$1" '%s' "${__out}${__rest}" ;;
    *) printf -v "$1" '%s' "$__raw" ;;
  esac
}

fl_kv_get() {
  local file="$1" key="$2" raw="" line v
  [[ -f "$file" && -r "$file" ]] || return 0
  # the last line for KEY wins (fl_kv_set appends); read in bash, as status
  # and list do this a dozen times per call
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "${key}="* ]] && raw="${line#"${key}="}"
  done <"$file"
  [[ -n "$raw" ]] || return 0
  fl_kv_decode_v v "$raw"
  printf '%s\n' "$v"
}

fl_kv_del() {
  local file="$1" key="$2" tmp
  [[ "${FL_DRY_RUN:-0}" == "1" ]] && return 0
  grep -q "^${key}=" "$file" 2>/dev/null || return 0
  fl__kv_lock "$file"
  if tmp="$(mktemp "${file}.XXXXXX" 2>/dev/null)"; then
    if { grep -v "^${key}=" "$file" 2>/dev/null || true; } >"$tmp"; then
      mv -f "$tmp" "$file" || rm -f "$tmp"
    else
      rm -f "$tmp"
    fi
  fi
  fl__kv_unlock "$file"
}

fl_state_set() { fl_kv_set "$FL_STATE_FILE" "$1" "$2"; }
fl_state_get() { fl_kv_get "$FL_STATE_FILE" "$1"; }

# ---------------------------------------------------------------- per bench
#
# Settings that belong to one bench (profile, site, autostart, honcho,
# bundle) live in .benchbar/benches/<name>-<path hash>.env, so a second bench never
# changes the first. state.env keeps what is global: BENCH_DIR, the default
# bench, and the tool paths.
#
# Before 0.4 these keys lived in state.env. They still count there for the
# default bench until its own file has the key, so an upgrade needs no
# migration and doctor stays read only.

FL_BENCH_KEYS="PROFILE SITE_NAME AUTOSTART HONCHO_BIN APP_BUNDLE APPS"
# MARIADB_FORMULA, PORT_OFFSET and SCHEDULER are per bench too, but never
# lived in state.env, so they need no fallback

# The name a bench goes by in agent labels and state files: its folder name,
# every character outside A-Za-z0-9._- turned into "-" (what
# `basename | tr -c 'A-Za-z0-9._\n-' '-'` gave before 0.6.1). The characters
# are listed one by one: in bash 3.2 a range follows the locale's collation
# and would keep an "é" that tr replaces, which would rename state files.
FL_NAME_CHARS="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
fl_bench_name_v() {
  local __n="$2"
  while [[ "$__n" == */ && "$__n" != / ]]; do __n="${__n%/}"; done
  [[ "$__n" == / ]] || __n="${__n##*/}"
  printf -v "$1" '%s' "${__n//[!${FL_NAME_CHARS}]/-}"
}
fl_bench_name_of() {
  local name
  fl_bench_name_v name "$1"
  printf '%s\n' "$name"
}

# fl_path_hash_v VAR PATH: the 8 hex digits of `cksum` of PATH, which name
# state files and agent labels. One process; FL_BENCH_HASH keeps the current
# bench's for the rest of the run.
fl_path_hash_v() {
  local __crc __rest
  read -r __crc __rest < <(printf '%s' "$2" | cksum)
  printf -v "$1" '%08x' "$__crc"
}
FL_BENCH_HASH=""
FL_BENCH_HASH_DIR=""
fl_bench_hash_prime() {
  [[ "$FL_BENCH_HASH_DIR" == "$FL_BENCH_DIR" && -n "$FL_BENCH_HASH" ]] && return 0
  fl_path_hash_v FL_BENCH_HASH "$FL_BENCH_DIR"
  FL_BENCH_HASH_DIR="$FL_BENCH_DIR"
}

# <name>-<8 hex of the full path>.env: ~/frappe-bench and ~/dev/frappe-bench
# share a folder name, never a file
# The path is canonical first (symlinks, "." and ".." resolved), so every
# spelling of one bench finds the same file. A file under the plain
# <name>.env, written by the first 0.4 builds, is read until the hashed one
# exists and is renamed by the next write.
fl_bench_canonical() {
  local parent real
  # the current bench, found by fl_bench_detect, is canonical already
  if [[ -n "$1" && "$1" == "${FL_BENCH_DIR_CANON:-}" ]]; then printf '%s' "$1"; return 0; fi
  # printf, not pwd's own output: the hash must not depend on a newline
  if [[ -d "$1" ]] && real="$(cd "$1" 2>/dev/null && pwd -P)"; then printf '%s' "$real"; return 0; fi
  # not created yet (phase 01 records it before bench init): resolve the parent
  parent="$(dirname "$1")"
  if [[ -d "$parent" ]]; then printf '%s/%s' "$(cd "$parent" && pwd -P)" "$(basename "$1")"; else printf '%s' "$1"; fi
}

fl_bench_state_file_for() {
  local h real name
  real="$(fl_bench_canonical "$1")"
  if [[ "$real" == "$FL_BENCH_HASH_DIR" && -n "$FL_BENCH_HASH" ]]; then h="$FL_BENCH_HASH"; else fl_path_hash_v h "$real"; fi
  fl_bench_name_v name "$real"
  printf '%s/benches/%s-%s.env' "$FL_STATE_DIR" "$name" "$h"
}

# fl_same_path A B: one bench, however either path is spelled (a stored
# BENCH_DIR may predate canonical paths).
fl_same_path() {
  [[ -n "$1" && -n "$2" && "$(fl_bench_canonical "$1")" == "$(fl_bench_canonical "$2")" ]]
}

# True when DIR may claim the plain <name>.env of the first 0.4 builds: it is
# the default bench, or no other known bench shares its folder name.
fl_bench_owns_old_file() {
  local dir="$1" name d
  fl_same_path "$(fl_state_get BENCH_DIR)" "$dir" && return 0
  declare -F fl_known_benches >/dev/null || return 1
  name="$(fl_bench_name_of "$(fl_bench_canonical "$dir")")"
  while IFS= read -r d; do
    [[ -n "$d" && "$(fl_bench_name_of "$d")" == "$name" ]] || continue
    fl_same_path "$d" "$dir" || return 1
  done < <(fl_known_benches 2>/dev/null)
  return 0
}

fl_bench_state_file_old() { printf '%s/benches/%s.env' "$FL_STATE_DIR" "$(fl_bench_name_of "$1")"; }

# fl_bstate_get_for DIR KEY: the bench's own value, else the pre 0.4 global
# one when DIR is the default bench.
fl_bstate_get_for() {
  local dir="$1" key="$2" v file i
  if [[ -n "$dir" && "$dir" == "$FL_BS_DIR" ]]; then
    v=""
    for ((i = 0; i < ${#FL_BS_KEYS[@]}; i++)); do
      [[ "${FL_BS_KEYS[$i]}" == "$key" ]] && v="${FL_BS_VALS[$i]}"
    done
    # values are stored with %q, decoded as in fl_kv_get
    [[ -n "$v" ]] && fl_kv_decode_v v "$v"
    if [[ -z "$v" && "$FL_BS_DEFAULT" == "1" ]]; then
      case " $FL_BENCH_KEYS " in *" $key "*) v="$(fl_state_get "$key")" ;; esac
    fi
    printf '%s' "$v"
    [[ -n "$v" ]] && printf '\n'
    return 0
  fi
  file="$(fl_bench_state_file_for "$dir")"
  # the plain <name>.env of the first 0.4 builds: claimed only when no other
  # bench could own it (the default bench, or the only one with that name)
  if [[ ! -f "$file" ]] && fl_bench_owns_old_file "$dir"; then file="$(fl_bench_state_file_old "$dir")"; fi
  v="$(fl_kv_get "$file" "$key")"
  if [[ -z "$v" ]] && fl_same_path "$(fl_state_get BENCH_DIR)" "$dir"; then
    case " $FL_BENCH_KEYS " in *" $key "*) v="$(fl_state_get "$key")" ;; esac
  fi
  printf '%s' "$v"
  [[ -n "$v" ]] && printf '\n'
  return 0
}

fl_bstate_set_for() {
  local file old
  # a primed read cache of this bench is stale from here on
  [[ "$1" == "$FL_BS_DIR" ]] && FL_BS_DIR=""
  file="$(fl_bench_state_file_for "$1")"; old="$(fl_bench_state_file_old "$1")"
  if [[ ! -f "$file" && -f "$old" && "${FL_DRY_RUN:-0}" != "1" ]] && fl_bench_owns_old_file "$1"; then mv "$old" "$file"; fi
  fl_kv_set "$file" "$2" "$3"
}

# fl_bstate_prime: the current bench's state file read once, for the read
# only commands (status, list, ports check; FL_CONTEXT_LIGHT=1). Every
# fl_bstate_get of that bench then answers from FL_BS_*, with the same
# fallbacks as a read of the file. Commands that write never prime: a cache
# could miss a write made in a subshell.
FL_BS_DIR=""
FL_BS_DEFAULT=0
FL_BS_KEYS=()
FL_BS_VALS=()
fl_bstate_prime() {
  local file line
  FL_BS_DIR=""; FL_BS_DEFAULT=0; FL_BS_KEYS=(); FL_BS_VALS=()
  [[ "${FL_CONTEXT_LIGHT:-0}" == "1" && -n "$FL_BENCH_DIR" ]] || return 0
  file="$(fl_bench_state_file_for "$FL_BENCH_DIR")"
  if [[ ! -f "$file" ]] && fl_bench_owns_old_file "$FL_BENCH_DIR"; then file="$(fl_bench_state_file_old "$FL_BENCH_DIR")"; fi
  if [[ -f "$file" && -r "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" == *=* ]] || continue
      FL_BS_KEYS+=("${line%%=*}"); FL_BS_VALS+=("${line#*=}")
    done <"$file"
  fi
  fl_same_path "$(fl_state_get BENCH_DIR)" "$FL_BENCH_DIR" && FL_BS_DEFAULT=1
  FL_BS_DIR="$FL_BENCH_DIR"
}

# The current bench (FL_BENCH_DIR).
fl_bstate_get() { fl_bstate_get_for "$FL_BENCH_DIR" "$1"; }
fl_bstate_set() { fl_bstate_set_for "$FL_BENCH_DIR" "$1" "$2"; }

# fl_bench_state_migrate DIR: moves the pre 0.4 per bench keys from
# state.env into DIR's own file (only when DIR is the default bench they
# belonged to). Writing commands call it; readers never need it.
fl_bench_state_migrate() {
  local dir="$1" key v file
  fl_same_path "$(fl_state_get BENCH_DIR)" "$dir" || return 0
  file="$(fl_bench_state_file_for "$dir")"
  for key in $FL_BENCH_KEYS; do
    v="$(fl_state_get "$key")"
    [[ -n "$v" ]] || continue
    [[ -n "$(fl_kv_get "$file" "$key")" ]] || fl_kv_set "$file" "$key" "$v"
    fl_kv_del "$FL_STATE_FILE" "$key"
  done
}

# fl_remember_default DIR: DIR becomes the default bench (the one commands
# use without --bench-dir) only when there is none yet, the old one is gone,
# it already is, or FL_MAKE_DEFAULT=1 (--make-default). A second bench never
# takes over "benchup" by being installed.
fl_remember_default() {
  local dir="$1" cur
  cur="$(fl_state_get BENCH_DIR)"
  if [[ -z "$cur" || ! -d "$cur" || "${FL_MAKE_DEFAULT:-0}" == "1" ]] || fl_same_path "$cur" "$dir"; then
    # the old default keeps its settings: move them into its own file first
    if [[ -n "$cur" ]] && ! fl_same_path "$cur" "$dir"; then fl_bench_state_migrate "$cur"; fi
    fl_state_set BENCH_DIR "$dir"
    return 0
  fi
  return 1
}
