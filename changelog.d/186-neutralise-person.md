### Command line

- `benchbar site restore --neutralise` switches the restored site's outbound integrations off and clears its stored secrets after the restore and before migrate: the list `benchbar pull` runs, with the Administrator login kept. The plan shows it as a step and its token covers it. Without the flag, the plan of a set that is not one of this bench's own backups carries a warning. A restore from one of the bench's own backups is unchanged.

### Agents and MCP

- `benchbar pull --keep-secrets` is a person's decision now, like `benchbar listen all`: under `--for-agent`, `benchbar mcp` and `BENCHBAR_NONINTERACTIVE=1` it is refused with one line, whatever `--yes` says. In a terminal, in the Mac app and in the Windows tray it works as before.
- `benchbar site restore` and the MCP tools `benchbar_site_restore_plan` and `benchbar_site_restore` refuse a backup set from a path outside the bench's own backup folders when no person runs them, unless `--neutralise` (`neutralise: true`) is given: such a set may be a production site's, with its integrations and stored passwords live.
