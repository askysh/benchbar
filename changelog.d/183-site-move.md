### Command line

- `benchbar site move NAME --to-bench PATH` moves a site to another registered bench on the same machine, under the same name: a backup with files, the restore there, migrate (not with `--no-migrate`), a check that it lists the same apps there, then the drop here (a second backup first; the backups stay in `archived/sites`). The bench the site is in must be stopped first (`benchbar down`), or writes made after the backup would be lost. It shows a plan and a token first (`--dry-run --json`, then `--apply TOKEN --yes`) and cannot be applied for the default site of either bench, a name that exists in the other bench, an app the other bench lacks, the same bench, a bench benchbar does not know or a lease someone else holds. A failed step before the drop leaves the site where it was and says what to clean up (#183).

### Agents and MCP

- `benchbar_site_move_plan` and `benchbar_site_move` run the same plan and token, with the lease argument like the other site tools (#183).
