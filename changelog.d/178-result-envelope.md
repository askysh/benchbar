### Agents and MCP

- Every command with a JSON mode now ends with the same envelope under `--for-agent` and `--jsonl`: `exit` (the process exit code), `error` when it failed, and for a command that changes things `changed[]`, `warnings[]`, `next_actions[]` and `state_after`. A read prints its one document with `exit`; a read that fails, a command that does not exist and a refused run print the envelope instead of nothing. `docs/json-schema.md` has the table, and `tests/test-envelope.sh` runs every command of `benchbar commands --json` against it.
- Twelve commands that changed things without JSON (`register`, `autostart`, `listen`, `uninstall-service`, `app install`, `app unfocus`, `lock write`, `lock apply`, `profile create`, `ports setup`, `ports mode`, `site hosts`) now stream a `done` line under `--for-agent` and `--json`.
- The MCP server returns `exit` in the `structuredContent` of every tool, `error` when it is not 0, and `changed`, `warnings` and `next_actions` at the top of an action's result. `exit_code` stays.
- The `labs`, `ports plan` and `ports check` documents carry `cli_version`, the `repair` done line carries `schema_version` and `cli_version`, and a failed `pull` or `share` document says why in `error`.

### Mac app

- The app reads the result envelope in one place (`ResultEnvelope`): `exit`, `error`, `changed`, `warnings` and `next_actions` with their real types. The old reader of the `labs on` and `labs off` result expected strings where the CLI sends objects, and so read nothing.
