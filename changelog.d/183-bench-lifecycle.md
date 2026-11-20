### Command line

- `benchbar bench forget PATH` takes a bench out of benchbar (its service files go aside, backed up first; the folder, sites and databases stay) and `benchbar bench remove PATH` also backs up each site, drops its database and moves the folder to `.benchbar-trash` next to it. Both show a plan and a token first (`--dry-run --json`, then `--apply TOKEN --yes`); `remove` is for a person at a terminal (#183).
- `benchbar install --scratch [--ttl DAYS]` and `benchbar bench scratch PATH` mark a bench scratch with an expiry, and `benchbar bench gc` lists the scratch benches that expired and removes them with the same plan and token (never the default bench) (#183).
- `benchbar site hosts --prune` removes the `/etc/hosts` lines of sites no bench has (one backup, one `sudo`), and `benchbar db orphans` lists databases that no site refers to. It never drops one (#183).
- `benchbar uninstall-service` keeps the shell helper block while another bench still has a service; the last one removes it (#183).

### Agents and MCP

- The bench lifecycle commands decide what an agent may do: `bench forget` with its plan and token, and the plans of `bench remove` and `bench gc` read only; applying those two deletes data and refuses `--for-agent`, `mcp` and a run without a terminal. They are not MCP tools yet (#183).

### Docs

- A reference page for `bench` and a section on retiring a bench in the benches and sites guide (#183).
