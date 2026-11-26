### Docs

- The JSON schema page is split into one page per command family under `reference/json/`, so a page is short enough to read. `/json-schema/` stays as the overview with the rules for readers, the done fields and the result envelope, and a link to an old heading of it, such as `/json-schema/#benchbar-doctor---json`, still opens the new page at the same anchor (#169).
- `tests/test-docs.sh` now checks every docs address that the CLI, the Mac app, the tray, the installers and the README use: the page and the heading must exist (#169).
