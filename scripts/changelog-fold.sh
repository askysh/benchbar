#!/bin/bash
#
# changelog-fold.sh: fold the changelog fragments into CHANGELOG.md.
#
#   scripts/changelog-fold.sh            fold changelog.d/*.md into "## Unreleased", remove the fragments
#   scripts/changelog-fold.sh --check    only check the fragments (and that CHANGELOG.md has "## Unreleased")
#   scripts/changelog-fold.sh --print    print the Unreleased section as it would be, write nothing
#
# A pull request adds changelog.d/<issue>-<slug>.md instead of editing
# CHANGELOG.md (see changelog.d/README.md). The release step runs this
# before the version heading is written. Sections with the same name are
# merged, sections come in the fixed order of SECTIONS below, and a
# section that is already in Unreleased and is not in SECTIONS stays,
# after the known ones, in its old order. With no fragments nothing is
# changed, so a second run is a no-op.
#
# CHANGELOG and CHANGELOG_DIR override the two paths (the tests use them).
# Exit: 0 done or nothing to do, 1 a fragment or CHANGELOG.md is invalid,
# 2 wrong usage.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHANGELOG="${CHANGELOG:-$ROOT/CHANGELOG.md}"
FRAGDIR="${CHANGELOG_DIR:-$ROOT/changelog.d}"

# The section names a fragment may use, in the order they are written.
SECTIONS="Command line|Install|Mac app|Windows|Windows installer|Windows tray|benchbar.exe|Linux and WSL|Agents and MCP|Sharing|New defaults|Docs|For contributors"

mode="fold"
case "${1:-}" in
  "") ;;
  --check) mode=check ;;
  --print) mode=print ;;
  -h|--help) sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) printf 'changelog-fold: unknown argument %s (see --help)\n' "$1" >&2; exit 2 ;;
esac
[[ "$#" -le 1 ]] || { printf 'changelog-fold: one option at most\n' >&2; exit 2; }

LC_ALL=C
export LC_ALL
EM=$'\xe2\x80\x94'
EN=$'\xe2\x80\x93'

# the fragments, in name order (README.md is the format description)
fragments() {
  local f
  [[ -d "$FRAGDIR" ]] || return 0
  for f in "$FRAGDIR"/*.md; do
    [[ -f "$f" ]] || continue
    [[ "${f##*/}" == README.md ]] && continue
    printf '%s\n' "$f"
  done
}

errors=0
bad() { printf '%s\n' "$1" >&2; errors=$((errors + 1)); }

check_fragment() {
  local f="$1" name out
  name="${f##*/}"
  [[ "$name" =~ ^[0-9]+-[a-z0-9]+(-[a-z0-9]+)*\.md$ ]] \
    || bad "changelog.d/$name: the name must be <issue number>-<short-slug>.md (lowercase letters, digits, dashes)"
  if grep -q -e "$EM" -e "$EN" "$f"; then
    bad "changelog.d/$name: has an em dash or en dash; use a colon, a comma or a new sentence"
  fi
  out="$(awk -v names="$SECTIONS" -v f="changelog.d/$name" '
    function err(n, m) { printf "%s:%d: %s\n", f, n, m; bad = 1 }
    function close_section() {
      if (head != "" && !bullets) err(headline, "the section \"" head "\" has no bullet line")
    }
    BEGIN { n = split(names, k, "|"); for (i = 1; i <= n; i++) known[k[i]] = 1 }
    /\r$/ { err(NR, "has a carriage return; use plain line ends"); next }
    /^### / {
      close_section()
      head = substr($0, 5); sub(/[ \t]+$/, "", head); headline = NR; bullets = 0; seen = 1
      if (!(head in known)) err(NR, "unknown section \"" head "\" (see changelog.d/README.md)")
      next
    }
    /^#/ { err(NR, "only ### section headings are allowed"); next }
    /^[ \t]*$/ { next }
    /^- / { if (!seen) err(NR, "a bullet before the first ### heading"); bullets = 1; next }
    /^[ \t]+[^ \t]/ { if (!bullets) err(NR, "an indented line must continue a bullet"); next }
    { err(NR, "a line must be a bullet (- text) or an indented continuation of one") }
    END {
      close_section()
      if (!seen) err(1, "no ### section heading")
      exit bad
    }
  ' "$f")" || { printf '%s\n' "$out" >&2; errors=$((errors + 1)); }
}

check_all() {
  local f
  grep -q '^## Unreleased[[:space:]]*$' "$CHANGELOG" 2>/dev/null \
    || bad "CHANGELOG.md has no \"## Unreleased\" heading"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    check_fragment "$f"
  done < <(fragments)
  return 0
}

# build_block: the new Unreleased section on stdout (no blank line after it)
build_block() {
  local cur frags f
  cur="$(mktemp "${TMPDIR:-/tmp}/changelog-cur.XXXXXX")"
  awk '/^## Unreleased[ \t]*$/ { p = 1; next } /^## / { p = 0 } p' "$CHANGELOG" >"$cur"
  frags=()
  while IFS= read -r f; do [[ -n "$f" ]] && frags+=("$f"); done < <(fragments)
  awk -v names="$SECTIONS" -v first="$cur" '
    BEGIN { n = split(names, k, "|"); for (i = 1; i <= n; i++) rank[k[i]] = i }
    FILENAME != last { last = FILENAME; pend = 0; cur = 0; part = 0 }
    /^### / {
      name = substr($0, 5); sub(/[ \t]+$/, "", name)
      if (!(name in idx)) { idx[name] = ++nsec; names_of[nsec] = name; cnt[nsec] = 0 }
      cur = idx[name]; pend = 0; part = 0; next
    }
    /^[ \t]*$/ { if (part > 0) pend = 1; next }
    {
      part++
      if (cur == 0) {
        if (FILENAME != first) next
        if (pend) pre[++npre] = ""; pend = 0
        pre[++npre] = $0; next
      }
      if (pend) line[cur, ++cnt[cur]] = ""; pend = 0
      line[cur, ++cnt[cur]] = $0
    }
    END {
      for (i = 1; i <= nsec; i++) { order[i] = i; key[i] = (names_of[i] in rank) ? rank[names_of[i]] : 1000 + i }
      for (i = 2; i <= nsec; i++) {
        v = order[i]; j = i - 1
        while (j >= 1 && key[order[j]] > key[v]) { order[j + 1] = order[j]; j-- }
        order[j + 1] = v
      }
      print "## Unreleased"
      if (npre > 0) { print ""; for (i = 1; i <= npre; i++) print pre[i] }
      for (i = 1; i <= nsec; i++) {
        s = order[i]
        print ""; print "### " names_of[s]; print ""
        for (j = 1; j <= cnt[s]; j++) print line[s, j]
      }
    }
  ' "$cur" ${frags[@]+"${frags[@]}"}
  rm -f -- "$cur"
}

[[ -f "$CHANGELOG" ]] || { printf 'changelog-fold: no %s\n' "$CHANGELOG" >&2; exit 1; }

check_all
if [[ "$errors" -gt 0 ]]; then
  printf 'changelog-fold: %d problem(s); nothing was changed\n' "$errors" >&2
  exit 1
fi
[[ "$mode" != check ]] || { printf 'changelog fragments: ok (%d)\n' "$(fragments | grep -c .)"; exit 0; }

if [[ "$mode" == print ]]; then
  build_block
  exit 0
fi

if [[ -z "$(fragments)" ]]; then
  printf 'unchanged: no fragments in %s\n' "${FRAGDIR#"$ROOT"/}"
  exit 0
fi

new="$(mktemp "${TMPDIR:-/tmp}/changelog-new.XXXXXX")"
trap 'rm -f -- "$new"' EXIT
{
  awk '/^## Unreleased[ \t]*$/ { exit } { print }' "$CHANGELOG"
  build_block
  rest="$(awk '/^## Unreleased[ \t]*$/ { p = 1; next } p && /^## / { q = 1 } q' "$CHANGELOG")"
  [[ -z "$rest" ]] || printf '\n%s\n' "$rest"
} >"$new"
cat "$new" >"$CHANGELOG"
count=0
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  rm -f -- "$f"
  count=$((count + 1))
done < <(fragments)
printf 'folded %d fragment(s) into the Unreleased section of CHANGELOG.md\n' "$count"
