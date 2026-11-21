### Command line

- `benchbar site snapshot NAME [--label TEXT]` saves the state of a site before a risky change: the database, the public and private files and `site_config.json`, with the apps of the bench and their commits, in `sites/NAME/snapshots/`, where frappe's backup pruning never reaches. It changes nothing in the site (#182).
- `benchbar site snapshots NAME` lists the snapshots, newest first, with their size and whether the bench's apps still match, and says which are beyond the newest 10 (`SNAPSHOT_KEEP` in the bench's state file, or `--keep N`). Nothing is removed on its own (#182).
- `benchbar site rollback NAME --to SNAPSHOT` puts a snapshot back with the plan, token and checks of `site restore`. It first takes a snapshot of the current state (`before rollback`), so a rollback can be undone with `--to latest`, and runs migrate only when the apps differ from the snapshot's. The default site is refused for an agent and for a run with no terminal, a snapshot that lacks a part is refused, and the undo point moves only when a rollback finished (#182).
- `benchbar site snapshot drop NAME SNAPSHOT` and `site snapshot drop NAME --prune` remove snapshots. They ask first, are refused for an agent, and `--prune` keeps the `before rollback` snapshot of the last rollback, and dropping it by name needs `--force-undo-point` (#182).
- A snapshot and a rollback check the free space first and stop with a message when the set would not fit; `site snapshots` shows what the snapshots hold and what is free. The plans of `site drop` and `bench remove` say how many snapshots move into the archive with the site (#182).
- `--background` also works on `site snapshot` and `site rollback` (#182).

### Agents and MCP

- Four MCP tools: `benchbar_site_snapshot` (no plan: it only adds a snapshot), `benchbar_site_snapshots`, and `benchbar_site_rollback_plan` with `benchbar_site_rollback`. They refuse the default site, and there is no tool to remove a snapshot (#182).

### Docs

- The sites guide has a section on snapshots and rollback, and the agents guide on saving a site before a risky change (#182).
