---
title: "BenchBar documentation"
description: "How the BenchBar documentation is organised and how to run the docs site locally."
---

These markdown files are the source of <https://benchbar.akashmishra.com>.
Edit them here; GitHub renders them as they are, and the site in `site/`
(Astro Starlight) builds from this folder. This README is not a page on
the site.

## Run the site locally

```bash
cd site && bun install && bun run dev
```

`bun run build` builds the static site into `site/dist`, and `bun run
linkcheck` checks every internal link and anchor in it.

## Writing a page

- Every file starts with frontmatter: `title` and `description`. The
  title is the page heading, so do not repeat it as a `# ` heading.
- Link to other pages with relative paths to their `.md` files, for
  example `[Apps](guides/apps.md)`. The site turns them into its own URLs,
  and links to other files in the repo into GitHub links.
- A new page goes into the sidebar in `site/astro.config.mjs`.
- `ROADMAP.md` and `CONTRIBUTING.md` stay at the repo root; the build
  copies them in as `/roadmap/` and `/contributing/`.
- A new doctor check needs a `### <check_id>` heading in
  `guides/doctor-and-repair.md`: the app links doctor lines there, and
  `tests/test-docs.sh` checks it.
