#!/usr/bin/env bash
# The docs site's promises to the CLI and the app: every doctor check id
# has a "### <id>" heading in docs/guides/doctor-and-repair.md (doctor FAIL
# lines link to /guides/doctor-and-repair/#<id>), every flag in a table of
# docs/reference/cli/ appears in benchbar --help, and every markdown file
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

# ---- every flag in the reference tables exists in --help
run_fm --help
assert_eq "0" "$CODE" "$OUT"
help="$OUT"
for page in "$ROOT"/docs/reference/cli/*.md; do
  while IFS= read -r flag; do
    [[ -n "$flag" ]] || continue
    case "$help" in
      *"$flag"*) ;;
      *) fail "$(basename "$page") documents ${flag}, which benchbar --help does not mention" ;;
    esac
  done < <(grep '^| `-' "$page" | grep -oE '`-[-a-zA-Z]+' | tr -d '`' | sort -u)
done

# ---- frontmatter on every page
while IFS= read -r f; do
  [[ "$(basename "$f")" == "README.md" ]] && continue
  [[ "$(head -n1 "$f")" == "---" ]] || fail "${f#"$ROOT"/} has no frontmatter"
  head -n5 "$f" | grep -q '^title: ' || fail "${f#"$ROOT"/} has no title"
  head -n5 "$f" | grep -q '^description: ' || fail "${f#"$ROOT"/} has no description"
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
done < <(sed -n 's/^lab~\([^~]*\)~.*/\1/p' "$ROOT/lib/frappe-local/labs.sh")

printf 'test-docs: ok\n'
