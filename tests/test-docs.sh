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
cp -R "$ROOT/benchbar" "$ROOT/lib" "$ROOT/scripts" "$ROOT/docs" "$COPY/"
# shellcheck disable=SC2016
sed -i.bak 's/^| `benchbar site list\([^|]*\)| [a-z]* |/| `benchbar site list\1| maybe |/' "$COPY/docs/reference/cli/site.md"
if OUT="$(python3 -I "$COPY/scripts/docs-reference.py" --check 2>&1)"; then fail "a changed generated table passed the docs reference check"; fi
assert_contains "$OUT" "site.md: a generated table differs from the code"
cp "$ROOT/docs/reference/cli/site.md" "$COPY/docs/reference/cli/site.md"
sed -i.bak 's/^flag~site backup~--with-files~~Include the uploads.$/&\nflag~site backup~--no-such-flag~~A flag the page does not list./' "$COPY/lib/frappe-local/commands.sh"
if OUT="$(python3 -I "$COPY/scripts/docs-reference.py" --check 2>&1)"; then fail "a new flag in the code passed the docs reference check"; fi
assert_contains "$OUT" "site.md: a generated table differs from the code"

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

printf 'test-docs: ok\n'
