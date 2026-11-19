### Command line

- `benchbar lease take (--bench PATH | --site NAME) [--for MINUTES] [--note TEXT]` holds a bench or a site for a while (30 minutes by default, at most 480) and returns a lease id. While it stands, `restart`, `down`, `repair`, `service`, `app add`, `app update`, `site add`, `site drop`, `site restore`, `pull` and the other commands that change what it covers refuse and say who holds it and until when. Pass the id (`--lease ID`) to go ahead. `lease renew`, `lease release` and `lease list` finish the set. A person at a terminal can pass `--break-lease`; an agent never can. Reads, `--dry-run` and `up` are never refused. `benchbar status --json` has a `leases` array (#184).

### Agents and MCP

- `benchbar_lease_take`, `benchbar_lease_renew`, `benchbar_lease_release` and `benchbar_lease_list` let an agent take a lease before long work, so another agent or the app does not restart, drop or restore the bench or site meanwhile. `benchbar_restart`, `benchbar_down` and the four apply tools take the id as `lease`. The server sets `BENCHBAR_CALLER` to the client's name and pid, so each session is its own holder, and only a lease's holder is shown its id (#184).

### Docs

- A new `lease` reference page, a Leases section in the agents guide and in `AGENTS.md`, and the `leases` field of `status --json` in the JSON reference. The Mac app and the Windows tray do not show leases yet (#184).
