# Changelog fragments

A pull request does not edit `CHANGELOG.md`. It adds one file here, named
`<issue number>-<short-slug>.md`, for example `132-changelog-fragments.md`
(lowercase letters, digits and dashes; use the pull request number when
there is no issue). Two pull requests then never edit the same lines, so
they do not conflict.

## The format

A fragment has one or more `### <Section>` headings. Under each heading
are bullet lines. A bullet that runs over several lines continues on lines
that start with a space.

```markdown
### Command line

- `benchbar site backups` lists the stamps of a site's backups (#123).

### Docs

- The sites guide shows how to restore a backup into a copy.
  It uses `--new` so the original site is not touched.
```

Write each bullet as it should read in the release notes: what a person
sees, in plain English. Keep it to one bullet per change.

The rules, which `scripts/changelog-fold.sh --check` enforces (and
`tests/test-changelog.sh` runs on every pull request that touches this
folder):

- The name is `<number>-<slug>.md`.
- Every heading is `###` and one of the sections below.
- Every section has at least one bullet. No other text, no `##` or `####`
  heading.
- No em dash and no en dash. Use a colon, a comma or a new sentence.
- Plain line ends (no carriage returns).

## The sections

In the order they appear in `CHANGELOG.md`:

1. Command line
2. Install
3. Mac app
4. Windows
5. Windows installer
6. Windows tray
7. benchbar.exe
8. Linux and WSL
9. Agents and MCP
10. Sharing
11. New defaults
12. Docs
13. For contributors

Two fragments may use the same section: their bullets are merged under one
heading, in file name order. A section that is already in `## Unreleased`
and is not in this list stays, after the listed ones.

To add a section, add its name to `SECTIONS` in
`scripts/changelog-fold.sh` and to this list.

## At release time

`scripts/changelog-fold.sh` writes every fragment into `## Unreleased` of
`CHANGELOG.md` and removes the fragment files. `--print` shows the section
without writing, and `--check` only validates. A second run with no
fragments changes nothing. See [maintainers/releasing.md](../maintainers/releasing.md).
