---
title: "JSON: sites, backups and snapshots"
description: "The JSON of benchbar site add, users, service, site backups, snapshots and restore, and the MCP results of the site and service tools."
---

The documents of the commands that work on a site. The [rules for readers](../../json-schema.md#rules-for-readers) and the [done fields](../../json-schema.md#the-done-fields-08) apply to all of them.

## Sites

`list --json` (per bench), `status --json` and `benchbar site list --json`
carry the bench's sites, read from `sites/*/site_config.json`:

```json
"sites": [
  { "name": "v16dev", "default": true, "hosts_entry": true, "ping_code": 200, "developer_mode": true, "open_as_enabled": true, "open_as": true },
  { "name": "v16two", "default": false, "hosts_entry": false, "ping_code": null, "developer_mode": false, "open_as_enabled": false, "open_as": false }
]
```

| Field | Type | Notes |
|---|---|---|
| `name` | string | the site folder |
| `default` | bool | the site `benchup` waits for, the runner pings and the app opens; `benchbar site default NAME` changes it (and runs `bench use`) |
| `hosts_entry` | bool | `/etc/hosts` maps it to 127.0.0.1; `benchbar site hosts` adds the missing lines |
| `ping_code` | number or null | HTTP code of `/api/method/ping` with this site as `Host`; `null` when nothing listens on the web port or nothing answered. Since 0.6.1 `list --json` and `status --json` leave it `null` (they are polled; `web_ping_code` is the default site's ping) unless `status --json --ping` asks every site once; `site list --json` always asks |
| `developer_mode` | bool | added after 0.8.0: `developer_mode` as frappe sees it, the site's `site_config.json` over `common_site_config.json`; `1` or `true` is on. `benchbar open --as` signs in as another user only when it is on |
| `open_as_enabled` | bool | added after 0.8.0: the person turned Open as on for this site (`benchbar site open-as on NAME`). Benchbar's own state for the bench; off for every site until then, also for a site added or pulled later |
| `open_as` | bool | added after 0.8.0: `benchbar open --as` can sign in on this site: `open_as_enabled` and `developer_mode` are on and it is the site the web process answers as (`bench serve` without `--site` answers as the `default_site` of `common_site_config.json` for every name) |
| `served` | bool or null | `status --json` only, added in 0.8: does the running web process serve this site (its `Host` is not answered with a 404). `null` while the bench is stopped (a stopped bench is never pinged) or when nothing answered. The default site's ping, and with `--ping` every site's, is reused; any other site is asked once, in bash. `false` is a site folder in `sites/` that the running bench does not serve: doctor's `site_not_served` warns about it |

`benchbar site list --json` prints `{"schema_version":1,"cli_version":..,"bench":..,"sites":[..]}`,
and since 0.7.3 each of its sites also carries the database:

| Field | Type | Notes |
|---|---|---|
| `db_name` | string or null | `db_name` from the site's `site_config.json`; `null` when the file has none |
| `db_port` | number | the site's `db_port`, else the bench's (`common_site_config.json`), else 3306 |

The password is never printed. `list --json` and `status --json` leave
these two out: they are polled.

Since 0.8 every site result carries `default_site`, the bench's default
site after the run: `site list` at the top level, and `site add`, `site
default` and `site drop` in their result. `site add` never moves it (it
puts it back if `bench new-site` did); only `site default` does.
`site add`, `site default` and `site drop` end with the [done fields](../../json-schema.md#the-done-fields-08),
`site add` and `site default` with `site`, `default_site` and `created`.

## `benchbar users --json`

`benchbar users [--site S] [--search TEXT] [--limit N] --json`: the enabled
users of a site, for `open --as` (needs `site open-as on` and a running
bench). One document:

```json
{"schema_version":1,"cli_version":"…","site":"mysite.localhost","users":[
  {"name":"priya@example.com","full_name":"Priya","user_type":"System User",
   "roles":["Sales User"],"role_count":1,"last_login":"2026-11-02 09:30:00.123456"}],"truncated":false}
```

`roles` holds the user's five rarest roles, `role_count` all of them
(without `All`, `Guest` and `Desk User`). `last_login` is Frappe's text, or
null. `truncated` is true when more users match than `--limit` (1 to 500, default 50).

## `benchbar site add NAME --dry-run --json`

The plan of a site add, read only, with the token that `--apply TOKEN --yes`
(and `benchbar_site_add` over MCP) needs. One document; the text goes to
stderr.

```json
{"schema_version":1,"cli_version":"0.8.0","bench":"/Users/you/frappe-bench","site":"qa1.localhost","exists":false,
 "apps":["erpnext"],"default_site":"macdev","default_moves":false,"backup":null,"hosts_entry":false,
 "steps":[{"kind":"new_site","name":"Create qa1.localhost","command":"bench new-site qa1.localhost ..."},
  {"kind":"install","name":"Install erpnext","command":"bench --site qa1.localhost install-app erpnext"}],
 "touches":["database","site_folder"],"changes":true,"token":"3f9c0e...64 hex characters"}
```

| Field | Type | Notes |
|---|---|---|
| `exists` | bool | the site folder is already there (then no `new_site` step) |
| `default_site` | string | the default site now (`sites/currentsite.txt`); `default_moves` is always `false` |
| `steps[]` | array | `kind` is `new_site`, `install` or `hosts` (macOS, when the line is missing) |
| `touches` | array of strings | `database`, `site_folder`, `hosts` |
| `token` | string | SHA-256 of the plan and of the bench's site list, `apps.txt` and default site |

`--apply TOKEN --yes` recomputes the plan and refuses a token that no longer
matches before anything changes; then it is a normal `site add` and its
stream ends in the usual `done` line.

## `benchbar service --dry-run --json`

The plan line of the service stream (as for `adopt --json`) carries a `token`:
a SHA-256 of the planned actions, the bench, the port block, the scheduler
choice and the site. `benchbar service --apply TOKEN --yes [--json]` runs that
plan and refuses, before any action, a token that no longer matches. Since 0.9 the
apply takes `--with-schedule` or `--without-schedule` too (the one the dry run was
made with): the choice is stored only after the run succeeded, and a refused token
stores nothing.

## MCP results of the site and service tools

`benchbar_site_add_plan`, `benchbar_site_restore_plan` and
`benchbar_service_install_plan` return the CLI's plan (for the service, the
plan line of its stream) as `structuredContent`. The apply tools and
`benchbar_site_backup` return `exit_code`, `output` (stderr text), `result`
(the `done` line, or the one document with the done fields) and the state
after: `sites` (`site list --json`) for `benchbar_site_add` and
`benchbar_site_restore`, `status` for the others. `benchbar_site_add` adds
`admin_password_generated: true`, `admin_password_file` (a 0600 file in
benchbar's state folder, `site-admin/SITE`, where the person reads the
password) and `admin_password_note` when it generated the new site's
Administrator password; the password itself is never in a result. If the file
could not be written, `admin_password_file` is absent and the note says so. `benchbar_up` on a bench whose `state` is
`not_adopted` returns `service: "missing"`, `started: false`, `next_tool:
"benchbar_service_install_plan"` and the `status` instead of starting it.
Any line of CLI text that would name where the MariaDB root password is kept
is replaced by a note in every result and error.

## Site backups

Since 0.8 the results of `site backup` and `site drop` (not their plans) also carry the [done fields](../../json-schema.md#the-done-fields-08), and `site drop`'s plan and result `default_site`. `--jsonl` turns either into a stream whose `done` carries the document's fields.

`site backup`, `site backups` and `site drop` (0.5.8) describe a backup
the same way. A backup is the files in the site's backup folder that
share one timestamp:

```json
{
  "stamp": "20260929_101500",
  "time": "2026-09-29T04:45:00Z",
  "path": "/Users/you/frappe-bench/sites/macdev/private/backups/20260929_101500-macdev-database.sql.gz",
  "database": "/Users/you/frappe-bench/sites/macdev/private/backups/20260929_101500-macdev-database.sql.gz",
  "files": "/Users/you/frappe-bench/sites/macdev/private/backups/20260929_101500-macdev-files.tar",
  "private_files": "/Users/you/frappe-bench/sites/macdev/private/backups/20260929_101500-macdev-private-files.tar",
  "config": "/Users/you/frappe-bench/sites/macdev/private/backups/20260929_101500-macdev-site_config_backup.json",
  "size_bytes": 5242880,
  "with_files": true,
  "encrypted": false,
  "partial": false,
  "complete": true
}
```

| Field | Meaning |
|---|---|
| `stamp` | the timestamp at the start of the file names, in the site's time zone |
| `complete` | `false` for a partial set, a set without a database file, or one with an empty part (a cheap check: `site restore` also reads the files to their end) |
| `time` | when the database file was written, UTC |
| `path` | the database file, the one a restore needs (else the first file of the set) |
| `database`, `files`, `private_files`, `config` | each part, `null` when the set has none |
| `size_bytes` | all parts together |
| `with_files` | the set has the public or private files |
| `encrypted`, `partial` | bench's encrypted and partial backups (`-enc`, `-partial`) |

`benchbar site backups NAME --json`: `{"schema_version", "cli_version",
"bench", "site", "folder", "backups": [backup, ...]}`, newest first.

`benchbar site backup NAME --json`: `{"schema_version", "cli_version",
"bench", "site", "dry_run", "backup": backup}`; `backup` is `null` in a
dry run.

`benchbar site drop NAME --confirm-site NAME --dry-run --json`, the plan:

```json
{
  "schema_version": 1, "cli_version": "0.5.8",
  "bench": "/Users/you/frappe-bench", "site": "bbtest.localhost",
  "dry_run": true, "is_default": false, "new_default": null,
  "database": "_bbtest",
  "token": "9f2c...64 hex characters",
  "steps": [
    {"title": "Back up bbtest.localhost with files, drop its database and user, move the folder to archived/sites", "command": "bench drop-site bbtest.localhost", "needs_password": false},
    {"title": "Remove '127.0.0.1 bbtest.localhost' from /etc/hosts", "command": "sudo, backup first", "needs_password": true}
  ]
}
```

Since 0.9 the plan has a `token`, a SHA-256 of the plan and of the site list,
the default site, the hosts line and the database name (`database`, from the site's own
`site_config.json`: it is the database that gets dropped). `benchbar site drop NAME --confirm-site
NAME --apply TOKEN --yes [--json]` runs that plan and refuses, before anything
changes, a token that no longer matches (exit 1). The MCP tools
`benchbar_site_drop_plan` and `benchbar_site_drop` pass it on as it is.

And the result, without `--dry-run`:

| Field | Meaning |
|---|---|
| `dropped` | `true`; a failed drop exits 1 with no JSON |
| `archived_path` | the site folder in `archived/sites/`, `null` if bench put it elsewhere |
| `backup` | the backup bench took before dropping (inside the archived folder), or `null` |
| `new_default` | the site that became the default, or `null` |
| `hosts_removed` | the `/etc/hosts` line was removed |
| `manual_step` | the command that removes the hosts line by hand when benchbar could not (no terminal for `sudo`, a line outside benchbar's block), else `null` |

### Site snapshots

Added in 0.9.0. A snapshot is a backup with files kept in
`sites/NAME/snapshots/<id>/` with a `manifest.json`. One snapshot, as
`site snapshot` and `site snapshots` print it:

| Field | Meaning |
|---|---|
| `id` | the folder name: the time stamp of the backup, then the label as a slug (`20261120_160102-before-upgrade`) |
| `site`, `label`, `time` | the site, the label given (empty when none), the time of the backup (UTC) |
| `stamp`, `path` | the backup's time stamp, the folder |
| `size_bytes`, `db_size_bytes` | all parts together, the database dump alone |
| `with_files`, `complete` | the public or private files are in it; every part is there and not empty |
| `rollback_of` | for a `before rollback` snapshot: the snapshot that rollback went to, else empty |
| `before_rollback` | `true` for the `before rollback` snapshot of the last rollback of this site |
| `apps` | `[{"name", "commit", "branch"}]` of the bench's git apps when it was taken |
| `apps_match` | `true` when the bench's apps are the same now, `false` when one was added, removed or moved to another commit, `null` when the manifest lists none |
| `changed_apps` | the app names that differ now |

`benchbar site snapshot NAME --json`: `{"schema_version", "cli_version",
"bench", "site", "dry_run", "snapshot": snapshot, "keep", "over_limit":
[id, ...]}`; `snapshot` is `null` in a dry run.

`benchbar site snapshots NAME --json`: `{"schema_version", "cli_version",
"bench", "site", "folder", "keep", "snapshots": [snapshot, ...],
"over_limit": [id, ...], "held_back": [id, ...], "held_back_bytes",
"leftovers": [{"id", "path", "size_bytes", "move_back"}],
"last_rollback_snapshot", "total_bytes", "free_bytes"}`, newest first.
`held_back` is what is beyond the limit but protected as an undo point, and
`leftovers` the `.incomplete-ID` folders a killed snapshot left, each with the
command in `move_back` that puts its backup files back. `total_bytes` is what the snapshots hold,
`free_bytes` the free space of the volume (`null` when `df` does not say).
`over_limit` is what retention would remove, never the undo point of the
last rollback that finished nor the snapshot of one that did not. Nothing is removed by either command.

`benchbar site rollback NAME --to SNAPSHOT --dry-run --json` is the plan of
[site restore](#benchbar-site-restore---json) (the same fields and token), with
the first step `snapshot` in place of `local_backup`, `migrate` only when the
apps differ, and one more key:

| Field | Meaning |
|---|---|
| `rollback` | `{"snapshot", "label", "time", "snapshot_first": "before rollback", "apps_match", "changed_apps", "default_site"}`. `can_apply` is `false` with an error when the site is the bench's default site and the caller is an agent |

The result of `--apply TOKEN --yes --json` is the restore result with
`rollback: {"snapshot", "before_rollback", "undo"}`: `before_rollback` is the
snapshot of the state before the rollback and `undo` the command that goes
back to the state before the first attempt (after a retry of a rollback that
did not finish, the oldest unfinished snapshot, not `before_rollback`).
`benchbar site snapshot drop` also lists `held_back` and `held_back_bytes` in
its prune plan, and prints `{"dropped": [id, ...],
"freed_bytes"}` (a plan with `would_drop`); it is for a person at a terminal.

`site drop`'s plan and result and the `sites[]` of `bench remove`'s plan carry
`snapshots: {"count", "size_bytes"}` when the site has snapshots: they move
into `archived/sites/` with the site folder. The key is absent otherwise.

### `benchbar site restore --json`

Added in 0.8. The plan of a restore from a backup set, read only, with a
token. `--apply TOKEN --yes` runs exactly that plan:

```json
{
  "schema_version": 1, "cli_version": "0.8.0",
  "bench": "/Users/you/frappe-bench", "site": "acme.localhost",
  "new": false, "exists": true,
  "source": {
    "site": "acme.localhost",
    "set": { "stamp": "20260902_090000", "...": "a backup, as above" },
    "restores_files": true, "encryption_key": true
  },
  "backup_first": { "will_run": true, "with_files": true, "folder": "/Users/you/frappe-bench/sites/acme.localhost/private/backups" },
  "migrate": true, "before_migrate": null, "before_migrate_sha256": null,
  "touches": ["backup", "database", "files", "site_config"],
  "steps": [
    { "id": "local_backup", "name": "Back up acme.localhost with its files", "touches": ["backup"] },
    { "id": "restore", "name": "Restore 20260902_090000 into acme.localhost with its files", "touches": ["database", "files"] },
    { "id": "encryption_key", "name": "Carry the encryption key of the set over", "touches": ["site_config"] },
    { "id": "migrate", "name": "bench migrate", "touches": ["database"] },
    { "id": "clear_cache", "name": "Clear caches", "touches": ["cache"] },
    { "id": "verify", "name": "Verify acme.localhost", "touches": [] }
  ],
  "warnings": [], "needs": [], "errors": [], "can_apply": true,
  "token": "8f1c...64 hex characters"
}
```

| Field | Meaning |
|---|---|
| `site`, `new`, `exists` | the target; `new` is `--new` (the site is created first, with `bench new-site`), `exists` that a site of that name is there |
| `source.site` | the site whose backups the stamp names (`--from-site`, else the target); `null` for a path |
| `source.set` | the backup set, as in [Site backups](#site-backups) |
| `source.restores_files` | `--with-files` was given: the public and private files are restored too |
| `source.encryption_key` | the set's `site_config_backup.json` has an `encryption_key`, which is carried into the target (never printed) |
| `backup_first` | an existing target is backed up with its files before anything changes (`will_run`); `folder` is where the set lands |
| `migrate`, `before_migrate`, `before_migrate_sha256` | `migrate` is `false` with `--no-migrate`; `before_migrate` is the path of the `--before-migrate` script and `before_migrate_sha256` its hash (a changed script makes the token stale) |
| `touches` | what the run changes: `backup` (an existing target is backed up first), `database`, `files`, `site_config`, `hosts` for a new site whose `/etc/hosts` line is missing, and `common_site_config` when the scheduler of a running bench is paused for the restore |
| `needs` | inputs a run in a terminal would ask for, for example `["MARIADB_ROOT_PASSWORD"]` when none is stored. In a terminal (no `--json`, no `--yes`) the plan stays applicable; for `--json` it is an error as well, because nothing can answer |
| `steps` | in the order they run, each with the `touches` of that step. Ids: `local_backup`, `quiesce`, `new_site`, `restore`, `encryption_key`, `resume`, `before_migrate`, `migrate`, `clear_cache`, `hosts`, `verify` |
| `errors`, `can_apply` | what stops the plan (no such site, a set that is not there, an encrypted or file-less set, MariaDB down, the root password unknown to benchbar, apps the bench lacks, a hook that is not an executable file); `can_apply` is `false` when there is one. The command still exits 0 with `--json` |
| `token` | a keyed hash of the plan and of what it was made against: the sites, the default site, the hook and the set's files. The key is per install (`plan-key` in the state folder, 0600) and the token carries a ten minute window: `--apply` recomputes it and refuses a different one (`The site restore plan changed since it was shown`) or one older than 60 to 70 minutes (`The plan token expired`), nothing changed. The script of `--before-migrate` is hashed again right before it runs and not run when it changed since the plan |

The result of `--apply TOKEN --yes --json`:

| Field | Meaning |
|---|---|
| `applied`, `ok` | `ok` is `false` when a step failed (exit 1); the steps after it stay `pending` or `skipped` |
| `site`, `new`, `token` | as in the plan |
| `backup` | the backup taken before an existing target was touched (a [backup](#site-backups)), `null` for a new site or when it did not get that far. It must be a new set with its database and both file archives, or the run stops before anything is overwritten. Put it back with `site restore TARGET --from STAMP --with-files --yes` |
| `set_copy` | for an existing target: the folder under the state backups that holds a copy (hard links, else copies) of the set that was restored. Bench's own backup deletes old backups in the target's folder, so the restore reads the copy, which stays after the run. `null` for a new site |
| `steps` | `[{"id","name","status"}]`, `status` is `done`, `unchanged`, `skipped`, `failed` or `pending` |
| `verify` | what the end check found: `apps` (what `bench --site TARGET list-apps` answers), `default_site` (the default site after the run, which is never changed: if a step moved it, it is put back with `bench use` and a warning says so) and `answers` (the web ping of the target while the bench runs, else `null`) |
| `warnings` | for example `migrate was skipped (--no-migrate)` |

Exit 0 only after the end check passed: the target answers `list-apps`
with frappe in it, and the default site is where it was. Exit 2 is
the MariaDB root password unknown to benchbar. The hook (`--before-migrate`)
runs in the bench folder with `BENCHBAR_SITE`, `BENCHBAR_BENCH` and
`BENCHBAR_DB_NAME`; variables named like a secret (`*PASSWORD*`, `*SECRET*`,
`*TOKEN*`, `*PASSPHRASE*`, `*_KEY`) are removed from its environment, and a
failing hook ends the run before migrate.
