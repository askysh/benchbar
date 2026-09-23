#!/usr/bin/env bash
#
# lock.sh: one frappe-mac run at a time. The lock is a directory (mkdir is
# atomic) holding the owner pid; stale locks from dead processes are reclaimed.

FL_LOCK_DIR=""

fl_lock_acquire() {
  local dir="${1:-${FL_STATE_DIR}/lock}" owner
  [[ "${FL_DRY_RUN:-0}" == "1" ]] && return 0
  mkdir -p "$(dirname "$dir")" 2>/dev/null || true
  if mkdir "$dir" 2>/dev/null; then
    printf '%s\n' "$$" >"$dir/pid"
    FL_LOCK_DIR="$dir"
    return 0
  fi
  owner="$(cat "$dir/pid" 2>/dev/null || true)"
  if [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null; then
    fl_die "Another frappe-mac run is active (pid ${owner})." "Wait for it to finish, or remove ${dir} if you are sure it is dead."
  fi
  fl_warn "Reclaiming stale lock left by pid ${owner:-unknown}"
  rm -rf "$dir"
  mkdir "$dir" 2>/dev/null || fl_die "Could not create lock ${dir}."
  printf '%s\n' "$$" >"$dir/pid"
  FL_LOCK_DIR="$dir"
}

fl_lock_release() {
  [[ -n "$FL_LOCK_DIR" ]] || return 0
  if [[ "$(cat "$FL_LOCK_DIR/pid" 2>/dev/null)" == "$$" ]]; then
    rm -rf "$FL_LOCK_DIR"
  fi
  FL_LOCK_DIR=""
}
