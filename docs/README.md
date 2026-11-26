---
title: "BenchBar documentation"
description: "How the BenchBar documentation is organised and how to run the docs site locally."
---

These markdown files are the source of <https://benchbar.akashmishra.com>.
Edit them here; GitHub renders them as they are, and the site in `site/`
(Astro Starlight) builds from this folder. This README is not a page on
the site.

Pages for maintainers are not in this folder, because everything here is
published. Decisions and Releasing are in `maintainers/`, and the site
redirects their old addresses to GitHub.

## Run the site locally

```bash
cd site && bun install && bun run dev
```

`bun run build` builds the static site into `site/dist`, and `bun run
linkcheck` checks every internal link and anchor in it. The external
links are checked once a week by the Docs workflow (`bun run
linkcheck:external` runs the same check by hand).

## What the site shows

The site is built and deployed from `main` only, so it describes the last
release and never a feature that has not shipped. You write docs on
`next-release`, in the pull request of the feature, and they go live with
the release. Every pull request to `next-release` runs the docs test, the
build and the link check. A page's "Edit page" link opens the file on
`next-release`.

## Generated tables

The tables of flags, needs and environment variables in
`reference/cli/` and the MCP tool table in `guides/agents.md` and
`reference/cli/mcp.md` come from the code (`benchbar commands --json`
and `lib/frappe-local/mcp.py`). They sit between
`<!-- generated:... -->` comments; the prose and the examples around them
are yours. After you change a command, a flag or an MCP tool, run

```bash
python3 -I scripts/docs-reference.py --write
```

and commit the result. `tests/test-docs.sh` fails when a table differs
from the code, when a command is on no page, and when a page documents a
flag no command has.

## Writing a page

- Every file starts with frontmatter: `title` and `description`. The
  title is the page heading, so do not repeat it as a `# ` heading.
- Link to other pages with relative paths to their `.md` files, for
  example `[Apps](guides/apps.md)`. The site turns them into its own URLs,
  and links to other files in the repo into GitHub links.
- A new page goes into the sidebar in `site/astro.config.mjs`;
  `tests/test-docs.sh` fails for a page that is in no group. A new user
  feature also gets a row in `features.md` (platform and version). A new
  Lab, a new top level command and a new MCP tool must be named in a row
  there, or `tests/test-docs.sh` fails.
- The CLI, the apps and the README link to pages and anchors of the site.
  When you split or rename a page, keep its old anchors working with a
  data file in `site/public/moved/` (see `moved/json-schema.js`) that the
  old page loads. `scripts/docs-links.py` checks every such address, and
  `tests/test-docs.sh` runs it.
- `ROADMAP.md` and `CONTRIBUTING.md` stay at the repo root; the build
  copies them in as `/roadmap/` and `/contributing/`.
- A new doctor check needs a `### <check_id>` heading in
  `guides/doctor-and-repair.md`: the app links doctor lines there, and
  `tests/test-docs.sh` checks it.

## Images

`docs/images/manifest.tsv` lists every image, the page that uses it, what
makes it and its status. A new image needs a row, and `tests/test-docs.sh`
fails without one. The Mac screens come from `DocsSnapshotTests` in
`macos/BenchBarTests`. These tests open real windows, so they run on a Mac
you are not using, with the `on-screen` marker in the snapshot folder, and
never in CI. After a release that changed a screen, run them, copy the
new images in, and update the dates in the manifest. `og-image.png` and
`social-preview.png` come from `swift scripts/social-preview.swift`.
