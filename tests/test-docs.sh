#!/usr/bin/env bash
# The docs site's promises to the CLI and the app: every doctor check id
# has a "### <id>" heading in docs/guides/doctor-and-repair.md (doctor FAIL
# lines link to /guides/doctor-and-repair/#<id>), the generated tables of
# docs/reference/cli/ and the MCP tools are what the code says, and every markdown file
# in docs/ has a title and a description in its frontmatter, every page
# is in the sidebar (DOC-3), and every Lab, every top level command and every
# MCP tool has a row on the Features page (#170).
# shellcheck source=tests/lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

GUIDE="$ROOT/docs/guides/doctor-and-repair.md"
assert_file "$GUIDE"

# ---- one heading per check id, port_block included (it shows in plans)
ids="$(sed -n 's/^FL_CHECK_ORDER="\(.*\)"$/\1/p' "$ROOT/lib/frappe-local/checks.sh") port_block"
n=0
for id in $ids; do
  n=$((n + 1))
  grep -qx "### ${id}" "$GUIDE" || fail "docs/guides/doctor-and-repair.md has no '### ${id}' heading"
done
[[ "$n" -gt 30 ]] || fail "read only ${n} check ids from checks.sh"

# ---- the CLI reference tables are generated from `benchbar commands --json` and
# the MCP tool table from mcp.py (scripts/docs-reference.py). The check fails when
# a committed table differs from what the script makes, when a command is on no
# page, when a page documents a flag the CLI does not have, or when a guide leaves
# an MCP tool out. Fix: python3 -I scripts/docs-reference.py --write
OUT="$(python3 -I "$ROOT/scripts/docs-reference.py" --check 2>&1)" || fail "docs reference check: ${OUT}"
assert_contains "$OUT" "docs-reference: ok"

# the check really fails: a copy with one table row changed, and one with a flag added to the code
COPY="$TMP_DIR/ref-copy"
mkdir -p "$COPY"
cp -R "$ROOT/benchbar" "$ROOT/lib" "$ROOT/scripts" "$ROOT/docs" "$ROOT/AGENTS.md" "$COPY/"
# shellcheck disable=SC2016
sed -i.bak 's/^| `benchbar site list\([^|]*\)| [a-z]* |/| `benchbar site list\1| maybe |/' "$COPY/docs/reference/cli/site.md"
if OUT="$(python3 -I "$COPY/scripts/docs-reference.py" --check 2>&1)"; then fail "a changed generated table passed the docs reference check"; fi
assert_contains "$OUT" "site.md: a generated table differs from the code"
cp "$ROOT/docs/reference/cli/site.md" "$COPY/docs/reference/cli/site.md"
sed -i.bak 's/^flag~site backup~--with-files~~Include the uploads.$/&\nflag~site backup~--no-such-flag~~A flag the page does not list./' "$COPY/lib/frappe-local/commands.sh"
if OUT="$(python3 -I "$COPY/scripts/docs-reference.py" --check 2>&1)"; then fail "a new flag in the code passed the docs reference check"; fi
assert_contains "$OUT" "site.md: a generated table differs from the code"
cp "$ROOT/lib/frappe-local/commands.sh" "$COPY/lib/frappe-local/commands.sh"
# a page that names a tool the server does not have (MCP-6): in the other direction, a tool the pages do not name, is checked above
# shellcheck disable=SC2016 # the backticks are Markdown
printf '
The tool `benchbar_no_such_tool` does nothing.
' >>"$COPY/docs/guides/agents.md"
if OUT="$(python3 -I "$COPY/scripts/docs-reference.py" --check 2>&1)"; then fail "a page naming a tool the server lacks passed the docs reference check"; fi
assert_contains "$OUT" "agents.md names benchbar_no_such_tool, which is not an MCP tool of the server"
cp "$ROOT/docs/guides/agents.md" "$COPY/docs/guides/agents.md"
# every page counts, not four fixed ones (json-schema.md, a CLI page, a guide), and a heading anchor is no tool name
# shellcheck disable=SC2016 # the backticks are Markdown
printf '
The tool `benchbar_made_up_read` and the anchor (x.md#the-privileged-steps-and-benchbar_sudogui).
' >>"$COPY/docs/json-schema.md"
if OUT="$(python3 -I "$COPY/scripts/docs-reference.py" --check 2>&1)"; then fail "json-schema.md naming a tool the server lacks passed the docs reference check"; fi
assert_contains "$OUT" "docs/json-schema.md names benchbar_made_up_read, which is not an MCP tool of the server"
assert_not_contains "$OUT" "benchbar_sudogui"
cp "$ROOT/docs/json-schema.md" "$COPY/docs/json-schema.md"
# shellcheck disable=SC2016 # the backticks are Markdown
sed -i.bak 's/`benchbar_where`/benchbar_where/g' "$COPY/docs/reference/cli/mcp.md"
if OUT="$(python3 -I "$COPY/scripts/docs-reference.py" --check 2>&1)"; then fail "a tool the pages do not name passed the docs reference check"; fi
assert_contains "$OUT" "mcp.md does not name the MCP tool benchbar_where"

# ---- every docs address in the code and the apps names a page and a heading that exist (#169): the
# CLI, the notices, the Mac app, the tray, the installers and the README link to the site, some with an
# anchor, and a split or renamed page must not break one. Fix the link, or keep the old anchor working
# in site/public/moved/ (the old page loads it).
OUT="$(python3 -I "$ROOT/scripts/docs-links.py" --check 2>&1)" || fail "docs links check: ${OUT}"
assert_contains "$OUT" "docs-links: ok"
# the check really fails: a heading that an address points at is gone, and an anchor that never existed
LINKS="$TMP_DIR/links-copy"
mkdir -p "$LINKS/site" "$LINKS/macos/BenchBar/System"
cp -R "$ROOT/docs" "$ROOT/lib" "$ROOT/scripts" "$LINKS/"
cp -R "$ROOT/site/public" "$ROOT/site/astro.config.mjs" "$LINKS/site/"
cp "$ROOT/macos/BenchBar/System/Links.swift" "$LINKS/macos/BenchBar/System/"
cp "$ROOT/README.md" "$ROOT/ROADMAP.md" "$ROOT/CONTRIBUTING.md" "$LINKS/" 2>/dev/null || true
OUT="$(python3 -I "$LINKS/scripts/docs-links.py" --check "$LINKS" 2>&1)" || fail "docs links check on a copy: ${OUT}"
grep -rl '^### env_python$' "$LINKS/docs" | while IFS= read -r page; do sed_inplace 's/^### env_python$/### env_python_renamed/' "$page"; done
if OUT="$(python3 -I "$LINKS/scripts/docs-links.py" --check "$LINKS" 2>&1)"; then fail "a doctor check without its heading passed the docs links check"; fi
assert_contains "$OUT" "the doctor check env_python"
printf '
See https://benchbar.akashmishra.com/json-schema/#no-such-heading and https://benchbar.akashmishra.com/no-such-page/.
' >>"$LINKS/README.md"
if OUT="$(python3 -I "$LINKS/scripts/docs-links.py" --check "$LINKS" 2>&1)"; then fail "addresses of a missing heading and a missing page passed the docs links check"; fi
assert_contains "$OUT" "README.md:"
assert_contains "$OUT" "has no heading #no-such-heading"
assert_contains "$OUT" "the page /no-such-page/ does not exist"

# ---- frontmatter on every page
while IFS= read -r f; do
  [[ "$(basename "$f")" == "README.md" ]] && continue
  [[ "$(head -n1 "$f")" == "---" ]] || fail "${f#"$ROOT"/} has no frontmatter"
  grep -q '^title: ' <<<"$(head -n5 "$f")" || fail "${f#"$ROOT"/} has no title"
  grep -q '^description: ' <<<"$(head -n5 "$f")" || fail "${f#"$ROOT"/} has no description"
done < <(find "$ROOT/docs" -name '*.md')

# ---- every page is in the sidebar (a page nobody can find is not documented)
CONFIG="$ROOT/site/astro.config.mjs"
while IFS= read -r f; do
  rel="${f#"$ROOT"/docs/}"
  [[ "$rel" == "README.md" ]] && continue
  slug="$(printf '%s' "${rel%.md}" | tr '[:upper:]' '[:lower:]')"
  grep -q "slug: '${slug}'" "$CONFIG" || fail "docs/${rel} is not in the sidebar: add slug '${slug}' to site/astro.config.mjs"
done < <(find "$ROOT/docs" -name '*.md')

# ---- every Lab has a row on the Features page
while IFS= read -r lab; do
  [[ -n "$lab" ]] || continue
  grep -q "\`${lab}\`" "$ROOT/docs/features.md" || fail "docs/features.md does not mention the Lab ${lab}"
  # and the Since of its rows is the version the lab table says (DOC-10)
  since="$(awk -F'~' -v l="$lab" '$1 == "lab" && $2 == l { print $6 }' "$ROOT/lib/frappe-local/labs.sh")"
  while IFS= read -r row; do
    case "$row" in
      *"| ${since} |"*) ;;
      *) fail "docs/features.md: the row of the Lab ${lab} does not say since ${since}: ${row}" ;;
    esac
  done < <(grep "\*\*Lab\*\* \`${lab}\`" "$ROOT/docs/features.md")
done < <(sed -n 's/^lab~\([^~]*\)~.*/\1/p' "$ROOT/lib/frappe-local/labs.sh")

# ---- every top level command and every MCP tool has a row on the Features page, and no table has
# the same feature twice (#170). The docs reference check above reads the real page (the words that
# need no row are FEATURES_SKIP in scripts/docs-reference.py, each with its reason). Here it really
# fails: on a copy that lost a row, that names a tool only outside a table, and that has a row twice.
FEAT="$COPY/docs/features.md"
feat_check() { python3 -I "$COPY/scripts/docs-reference.py" --check 2>&1; }
# shellcheck disable=SC2016 # the backticks are Markdown
grep -q '^| `stats` ' "$ROOT/docs/features.md" || fail "docs/features.md has no row that starts with the command stats (the checks below use it)"
# shellcheck disable=SC2016
grep -v '^| `stats` ' "$ROOT/docs/features.md" >"$FEAT"
if OUT="$(feat_check)"; then fail "a Features page without a row for the command stats passed the docs reference check"; fi
assert_contains "$OUT" "docs/features.md has no row for the command stats. Add one line"
# a tool named in the prose only is not in a row
# shellcheck disable=SC2016
sed 's/`benchbar_history`/the history tool/' "$ROOT/docs/features.md" >"$FEAT"
# shellcheck disable=SC2016
printf '\nAn agent reads the history with `benchbar_history`.\n' >>"$FEAT"
if OUT="$(feat_check)"; then fail "a Features page without a row for the MCP tool benchbar_history passed the docs reference check"; fi
assert_contains "$OUT" "docs/features.md has no row for the MCP tool benchbar_history. Add it"
assert_not_contains "$OUT" "for the command"
# the same feature twice in one table (what a merge of two pull requests left behind). The same
# name in two tables, such as Doctor and repair for the CLI and for the Mac app, is fine: the real page passes
# shellcheck disable=SC2016
awk '{ print } /^\| `stats` / { print }' "$ROOT/docs/features.md" >"$FEAT"
if OUT="$(feat_check)"; then fail "a Features page with the same row twice passed the docs reference check"; fi
# shellcheck disable=SC2016
assert_contains "$OUT" 'docs/features.md: the table of "Command line tool" has the row "`stats`" twice: keep one'
cp "$ROOT/docs/features.md" "$FEAT"
# a word in the skip list that is no command any more is named, so the list cannot rot
sed_inplace 's/^FEATURES_SKIP = {$/&\n    "no-such-command": "a reason",/' "$COPY/scripts/docs-reference.py"
if OUT="$(feat_check)"; then fail "a skip list entry that is not a command passed the docs reference check"; fi
assert_contains "$OUT" "FEATURES_SKIP in scripts/docs-reference.py names no-such-command, which is not a command"
cp "$ROOT/scripts/docs-reference.py" "$COPY/scripts/docs-reference.py"

# ---- every image is in the manifest, and every manifest row is a file (DOC-11)
MANIFEST="$ROOT/docs/images/manifest.tsv"
assert_file "$MANIFEST"
for f in "$ROOT"/docs/images/*.png; do
  grep -q "^$(basename "$f")	" "$MANIFEST" || fail "docs/images/$(basename "$f") has no row in docs/images/manifest.tsv"
done
while IFS=$'\t' read -r img _; do
  [[ "$img" == "#"* || "$img" == "image" ]] && continue
  [[ -f "$ROOT/docs/images/$img" ]] || fail "docs/images/manifest.tsv lists $img, which is not in docs/images"
done < "$MANIFEST"

# ---- What's new has a section for the version of the code and for every version of CHANGELOG.md
# from 0.8.0 on (DOC-4), and "(coming)" stands only on a version that is not released yet (#170).
# The version comes from FL_VERSION. A final one (0.9.0) is the last release: its section has a
# date, and only a later version may say "(coming)". A candidate (0.9.0-rc.1) has not shipped
# 0.9.0, so the last release is the newest dated section of CHANGELOG.md.
NEW="$ROOT/docs/whats-new.md"
assert_file "$NEW"
# ver_later A B: A is a later version than B
ver_later() {
  local a b i
  IFS=. read -r -a a <<<"$1"
  IFS=. read -r -a b <<<"$2"
  for i in 0 1 2; do
    if (( ${a[i]:-0} > ${b[i]:-0} )); then return 0; fi
    if (( ${a[i]:-0} < ${b[i]:-0} )); then return 1; fi
  done
  return 1
}
# whats_new_problems PAGE CODE_VERSION CHANGELOG: one line per problem, nothing when the page is right
whats_new_problems() {
  local page="$1" code="$2" base="${2%%-*}" released ver
  if [[ "$code" == "$base" ]]; then released="$base"
  else
    # every dated version, then the first line: no pipe into head, which would close on the writer
    released="$(sed -n 's/^## \([0-9][0-9.]*\) - .*/\1/p' "$3")"
    released="${released%%$'\n'*}"
  fi
  grep -q "^## ${base//./\\.} " "$page" || printf 'no section for %s, the version of the code (FL_VERSION)\n' "$base"
  while IFS= read -r ver; do
    ver_later "$ver" "$released" || printf '"## %s (coming)" but %s is released: write its date, as maintainers/releasing.md says\n' "$ver" "$released"
  done < <(sed -n 's/^## \([0-9][0-9.]*\) (coming).*/\1/p' "$page")
  return 0
}
CODE_VERSION="$(sed -n 's/^FL_VERSION="\(.*\)"$/\1/p' "$ROOT/benchbar")"
[[ "$CODE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]] || fail "read no version from FL_VERSION in benchbar: [${CODE_VERSION}]"
OUT="$(whats_new_problems "$NEW" "$CODE_VERSION" "$ROOT/CHANGELOG.md")"
[[ -z "$OUT" ]] || fail "docs/whats-new.md: ${OUT}"
# the check really fails: the release is cut and the page still says "(coming)", or has no section for it
WN="$TMP_DIR/whats-new.md" CL="$TMP_DIR/changelog.md"
printf '## Unreleased\n\n## 0.8.3 - 2026-11-17\n' >"$CL"
printf '## 0.9.0 (coming)\n\n## 0.8.3 (2026-11-17)\n' >"$WN"
assert_eq "" "$(whats_new_problems "$WN" 0.8.3 "$CL")" "(the next release may say coming)"
assert_eq "" "$(whats_new_problems "$WN" 0.9.0-rc.1 "$CL")" "(a candidate has not shipped its release)"
assert_contains "$(whats_new_problems "$WN" 0.9.0 "$CL")" '"## 0.9.0 (coming)" but 0.9.0 is released'
assert_contains "$(whats_new_problems "$WN" 0.10.0 "$CL")" '"## 0.9.0 (coming)" but 0.10.0 is released'
assert_contains "$(whats_new_problems "$WN" 0.10.0 "$CL")" "no section for 0.10.0, the version of the code"
printf '## 0.9.1 (coming)\n\n## 0.9.0 (2026-12-01)\n\n## 0.8.3 (2026-11-17)\n' >"$WN"
assert_eq "" "$(whats_new_problems "$WN" 0.9.0 "$CL")" "(a dated section and a later coming one)"
printf '## 0.8.3 (coming)\n' >"$WN"
assert_contains "$(whats_new_problems "$WN" 0.9.0-rc.1 "$CL")" '"## 0.8.3 (coming)" but 0.8.3 is released'
while IFS= read -r ver; do
  grep -q "^## ${ver} " "$NEW" || fail "docs/whats-new.md has no section for ${ver}"
done < <(awk '/^## [0-9]+\.[0-9]+\.[0-9]+ /{ split($2, v, "."); if (v[1] > 0 || v[2] >= 8) print $2 }' "$ROOT/CHANGELOG.md")
grep -q 'whats-new' "$ROOT/maintainers/releasing.md" || fail "maintainers/releasing.md has no step that writes the What's new section"
grep -q 'data-exclude-search' "$ROOT/site/astro.config.mjs" || fail "the Umami script lacks data-exclude-search (docs/privacy.md says no query string is sent)"


# ---- claims that were fixed stay fixed (DOC-7, DOC-8)
for f in README.md SECURITY.md docs/index.md docs/reference/configuration.md; do
  if grep -q 'twice per install\|used for two things' "$ROOT/$f"; then fail "$f gives an old sudo count"; fi
done
for f in README.md docs/index.md site/astro.config.mjs; do
  if grep -q 'benches on your Mac, in the background\|benches on macOS, in the background\|benches on macOS"' "$ROOT/$f"; then fail "$f describes BenchBar as macOS only"; fi
done

# ---- every link in the features table is a page that exists (DOC-1: each feature has a guide)
while IFS= read -r link; do
  target="${link%%#*}"
  [[ -n "$target" ]] || continue
  [[ -f "$ROOT/docs/$target" ]] || fail "docs/features.md links to ${target}, which is not a page in docs/"
done < <(grep -o '\]([^)]*)' "$ROOT/docs/features.md" | sed 's/^](//; s/)$//' | grep -v '^http' | grep -v '^\.\./' )

printf 'test-docs: ok\n'
