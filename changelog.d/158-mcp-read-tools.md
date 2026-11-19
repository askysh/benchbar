### Agents and MCP

- Nine new MCP read tools, so an agent no longer needs a terminal to look: `benchbar_site_backups` (the backup sets of a site and the `stamp` that `benchbar_site_restore_plan` takes), `benchbar_ports_check`, `benchbar_ports_plan` (a preview with no apply tool), `benchbar_lock_check`, `benchbar_doctor_prerequisites`, `benchbar_labs_list`, `benchbar_where`, `benchbar_self_update_check` and `benchbar_app_focus_list`. Each runs one read only command with `--json`, and its result is labeled as data from the bench like every other.
- The restore tools no longer point at `benchbar_site_list` for backup stamps (it never carried them): `benchbar_site_backups` lists them.
- Turning a lab on, applying ports, sharing, the LAN guard, `self-update`, `site default` and `app focus NAME` stay a person's decisions and have no MCP tool. The tool list, the agents guide, the MCP reference and `AGENTS.md` say so.
- The docs check runs in both directions: every tool of the server is named in the agents guide and the MCP reference, and those pages, the features page and `AGENTS.md` name no tool the server lacks.
