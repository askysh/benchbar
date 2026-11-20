### Command line

- `benchbar status --json` has `autostart`, whether the bench may come back after a login (the read side of `benchbar autostart on|off`) (#186).
- `benchbar service --apply TOKEN --yes` takes `--with-schedule` or `--without-schedule`, the choice the plan was made with. A plan made with one could not be applied before. A refused token stores nothing (#186).
- `benchbar site drop` has a plan token: `--dry-run --json` prints it and `--apply TOKEN --yes` runs exactly that plan, refused when the sites, the default site, the hosts line or the site's database name changed since. The plan names the `database` (#186).

### Agents and MCP

- Eight new MCP tools close gaps with the command line: `benchbar_doctor_ack` (`check`, and `unack: true` to show a warning again), `benchbar_autostart`, `benchbar_ports_mode`, `benchbar_ports_apply` (after `benchbar_ports_plan`, only for benches benchbar knows), `benchbar_site_drop_plan` and `benchbar_site_drop`, `benchbar_scan` and `benchbar_report` (the redacted diagnostics as text, no zip) (#186).
- `benchbar_service_install_plan` and `benchbar_service_install` take `schedule` to turn the scheduler on or off (#186).
- `benchbar_site_drop_plan` and `benchbar_site_drop` refuse the default site and cannot move the default; they give the person the command (#186).
- Registering a bench, the hosts line, `console` and `db` stay a person's decisions and have no tool. The agents guide lists every command, its tool, or the reason it has none (#186).

### Docs

- The agents guide has a parity table: each command, the MCP tool that covers it, or the safety reason it has none (#186).
