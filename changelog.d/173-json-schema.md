### Command line

- `labs list --json`, `labs status --json`, `ports check --json` and `ports plan --json` now print `cli_version`, like every other document (#173).

### Mac app

- The Mac app reads the `changed` and `next_actions` of the done line of `labs on` and `labs off` as the lists of objects the CLI prints, not as lists of text (#173).

### For contributors

- `schema/benchbar.schema.json` is the one JSON Schema of the CLI's JSON. `tests/test-json-schema.sh` checks that every recorded fixture of the Mac app and the Windows tray fits it, that what the CLI prints fits it, and that the Swift models, the tray's C# models and the MCP server read only fields it has. A pull request that adds a field adds it to the schema too (#173).

### Docs

- `docs/json-schema.md` says the schema file is the source of truth and lists its definitions (#173).
