#!/usr/bin/env bash
# The docs site's promises to the CLI and the app: every doctor check id
# has a "### <id>" heading in docs/guides/doctor-and-repair.md (doctor FAIL
# lines link to /guides/doctor-and-repair/#<id>), the generated tables of
# docs/reference/cli/ and the MCP tools are what the code says, and every markdown file
# in docs/ has a title and a description in its frontmatter, every page
# is in the sidebar (DOC-3) and every Lab is on the Features page.
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

# ---- What's new has a section for the next release and every version of CHANGELOG.md from 0.8.0 on (DOC-4)
NEW="$ROOT/docs/whats-new.md"
assert_file "$NEW"
grep -q '^## 0\.9\.0' "$NEW" || fail "docs/whats-new.md has no section for the next release (0.9.0)"
while IFS= read -r ver; do
  grep -q "^## ${ver} " "$NEW" || fail "docs/whats-new.md has no section for ${ver}"
done < <(awk '/^## [0-9]+\.[0-9]+\.[0-9]+ /{ split($2, v, "."); if (v[1] > 0 || v[2] >= 8) print $2 }' "$ROOT/CHANGELOG.md")
grep -q 'whats-new' "$ROOT/docs/releasing.md" || fail "docs/releasing.md has no step that writes the What's new section"
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
