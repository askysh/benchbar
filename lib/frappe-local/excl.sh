#!/usr/bin/env bash
#
# excl.sh: a folder as a lock that one run of several wins, for lock.sh, lease.sh and the guards of
# state.sh. Its own file because state.sh and lock.sh are each loaded alone (tests, the runner): each
# loads it when the functions are not there yet.

# fl_mkdir_excl DIR: makes the folder DIR as a lock; of several runs that make it at once, one wins.
# The exit code of mkdir does not say which. uutils coreutils (the coreutils of Ubuntu 25.10 and
# later) looks for the folder first and, when another process makes it between that look and its
# own mkdir, reports success all the same: two runs held one lock and a lease was lost although
# its take said ok (issue 138). The winner is the run whose claim file goes in first: bash's
# noclobber opens it with O_EXCL, which no coreutils is between. A run that lost the claim does not
# hold the folder and leaves it alone. Returns 0 held, 1 held by another run (or gone again), 2 the
# claim cannot be written (no space, no inodes, no permission): a folder that is there with no claim
# in it after a second try is not a race, and the caller says so instead of waiting for nobody.
fl_mkdir_excl() {
  mkdir "$1" 2>/dev/null || return 1
  ( set -o noclobber; : >"${1}/claim" ) 2>/dev/null && return 0
  [[ -d "$1" && ! -e "${1}/claim" ]] || return 1
  # a folder another run made a moment ago, before its own claim: the claim is still free
  ( set -o noclobber; : >"${1}/claim" ) 2>/dev/null && return 0
  [[ -d "$1" && ! -e "${1}/claim" ]] || return 1
  return 2
}

# fl_rmdir_excl DIR: lets go of a folder fl_mkdir_excl made: its claim, then the folder
fl_rmdir_excl() {
  rm -f "${1}/claim" 2>/dev/null
  rmdir "$1" 2>/dev/null
}
