## What and why

<!-- What changes, and the problem it solves. Link the issue: Fixes #123. -->

## Tested on

<!-- macOS version, profile (v15-lts, v16-lts or a team profile), and whether it ran on a real Mac with a real bench or only under the mocks. -->

- macOS:
- Profile:
- Real Mac: yes / no

## Checklist

Tick each box, or write "n/a" and why (a CI only change has no guide page).

- [ ] Tests: the tests for the change pass (`bash tests/affected.sh`; `scripts/macos-build.sh --test` for app changes), and a bug fix has a test that failed before
- [ ] A second run changes nothing and says `unchanged`
- [ ] User docs: the guide or the app page that tells a user about the change is updated, not only the reference page
- [ ] Features page: a new feature, Lab or platform has a row in `docs/features.md` (platform and version)
- [ ] CHANGELOG: a line under `## Unreleased` in CHANGELOG.md, in the section that fits
- [ ] DECISIONS: a line per non obvious choice (docs/DECISIONS.md or macos/DECISIONS.md), or none needed
- [ ] No em dashes or en dashes in the code, the docs or this description
- [ ] If a command, flag or MCP tool changed: `python3 -I scripts/docs-reference.py --write` was run and its tables are committed

## AI disclosure

<!-- One line: the tool and how much it did, or "None". See CONTRIBUTING.md. -->

AI use:
