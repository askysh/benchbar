#!/usr/bin/env bash
#
# state.sh: small key=value store in .benchbar/state.env.
#
# The folder was .frappe-local before 0.3.0. The first run after the
# upgrade renames it (one atomic mv in the checkout), unless a run holds
# its lock right now; until then the old folder is used as is.

fl_state_dir_default() {
  local new="${SCRIPT_DIR}/.benchbar" old="${SCRIPT_DIR}/.frappe-local"
  if [[ -d "$old" && ! -e "$new" && ! -d "${old}/lock" ]]; then
    mv "$old" "$new" 2>/dev/null || true
  fi
  if [[ -d "$new" || ! -d "$old" ]]; then printf '%s' "$new"; else printf '%s' "$old"; fi
}

FL_STATE_DIR="${FL_STATE_DIR:-$(fl_state_dir_default)}"
FL_STATE_FILE="${FL_STATE_FILE:-${FL_STATE_DIR}/state.env}"

fl_state_init() {
  [[ "${FL_DRY_RUN:-0}" == "1" ]] && return 0
  mkdir -p "$FL_STATE_DIR"
  touch "$FL_STATE_FILE"
}

# fl_kv_set FILE KEY VALUE and fl_kv_get FILE KEY: the store behind both
# the checkout's state.env and the per bench files. Nothing is written in a
# dry run, and an unchanged value is not written again.
fl_kv_set() {
  local file="$1" key="$2" value="$3"
  [[ "${FL_DRY_RUN:-0}" == "1" ]] && return 0
  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  [[ -f "$file" ]] || : >"$file"
  if [[ "$(fl_kv_get "$file" "$key")" == "$value" ]]; then
    return 0
  fi
  grep -v "^${key}=" "$file" >"${file}.tmp" 2>/dev/null || true
  printf '%s=%q\n' "$key" "$value" >>"${file}.tmp"
  mv "${file}.tmp" "$file"
}

fl_kv_get() {
  local file="$1" key="$2" raw
  [[ -f "$file" ]] || return 0
  raw="$(sed -n "s/^${key}=//p" "$file" | tail -n1)"
  [[ -n "$raw" ]] || return 0
  # values are stored with %q; unquote the common forms
  eval "printf '%s\n' $raw"
}

fl_kv_del() {
  local file="$1" key="$2"
  [[ "${FL_DRY_RUN:-0}" == "1" ]] && return 0
  grep -q "^${key}=" "$file" 2>/dev/null || return 0
  grep -v "^${key}=" "$file" >"${file}.tmp" 2>/dev/null || true
  mv "${file}.tmp" "$file"
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

# The name a bench goes by in agent labels and state files: its folder name.
fl_bench_name_of() {
  basename "$1" | tr -c 'A-Za-z0-9._\n-' '-'
}

# <name>-<8 hex of the full path>.env: ~/frappe-bench and ~/dev/frappe-bench
# share a folder name, never a file
# The path is canonical first (symlinks, "." and ".." resolved), so every
# spelling of one bench finds the same file. A file under the plain
# <name>.env, written by the first 0.4 builds, is read until the hashed one
# exists and is renamed by the next write.
fl_bench_canonical() {
  local parent real
  # printf, not pwd's own output: the hash must not depend on a newline
  if [[ -d "$1" ]] && real="$(cd "$1" 2>/dev/null && pwd -P)"; then printf '%s' "$real"; return 0; fi
  # not created yet (phase 01 records it before bench init): resolve the parent
  parent="$(dirname "$1")"
  if [[ -d "$parent" ]]; then printf '%s/%s' "$(cd "$parent" && pwd -P)" "$(basename "$1")"; else printf '%s' "$1"; fi
}

fl_bench_state_file_for() {
  local h real
  real="$(fl_bench_canonical "$1")"
  h="$(printf '%s' "$real" | cksum | awk '{printf "%08x", $1}')"
  printf '%s/benches/%s-%s.env' "$FL_STATE_DIR" "$(fl_bench_name_of "$real")" "$h"
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
  local dir="$1" key="$2" v file
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
  file="$(fl_bench_state_file_for "$1")"; old="$(fl_bench_state_file_old "$1")"
  if [[ ! -f "$file" && -f "$old" && "${FL_DRY_RUN:-0}" != "1" ]] && fl_bench_owns_old_file "$1"; then mv "$old" "$file"; fi
  fl_kv_set "$file" "$2" "$3"
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
