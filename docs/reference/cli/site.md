---
title: "site"
description: "benchbar site list, add, default, hosts, backup, backups and drop: the sites of a bench, their backups, and dropping one safely."
---

The sites of a bench. The guide is
[Benches and sites](../../guides/benches-and-sites.md#sites). Every
command takes the [options for every command](install.md#options-for-every-command).

## site list

```
benchbar site list [--json] [--bench-dir DIR]
```

Every site of the bench; the default one, the site `benchup` waits for,
is marked. `benchbar site` alone does the same. With `--json`: each
site's name, whether it is the default, whether `/etc/hosts` has it, and
its ping code ([schema](../../json-schema.md#sites)).

Exit codes: 0; 1 when no bench is found.

```bash
benchbar site list --json
```

## site add

```
benchbar site add NAME [--bundle NAME | --apps "a b"] [--dry-run] [--yes]
```

`bench new-site` on the bench's MariaDB with the root password from the
Keychain, the site's `/etc/hosts` line, and optionally apps that are
already in `apps/`. The default site stays as it is. It asks for the new
site's Administrator password, or reads `ADMIN_PASSWORD`.

| Flag | What it does |
|---|---|
| `--bundle NAME` | Install the apps of a bundle (`minimal`, `common`, `extended`) |
| `--apps "a b"` | Install these apps, which must be in `apps/` already |
| `--dry-run` | Print the plan, change nothing |
| `-y`, `--yes` | Do not ask; `ADMIN_PASSWORD` must be set |

Exit codes: 0 the site exists; 1 a step failed or an app is not in
`apps/`; 2 the MariaDB root password is unknown (pass
`MARIADB_ROOT_PASSWORD`).

```bash
ADMIN_PASSWORD='...' benchbar site add v16two --bundle minimal --yes
```

## site default

```
benchbar site default NAME
```

Makes NAME the default site: `bench use`, the runner's ping, `benchup` and
the app all follow it. The processes keep running.

Exit codes: 0; 1 when the site does not exist or `bench use` fails.

```bash
benchbar site default v16two
```

## site hosts

```
benchbar site hosts
```

Adds a `127.0.0.1` line to `/etc/hosts` for every site that has none,
inside benchbar's markers, with one `sudo` prompt.

Exit codes: 0; 1 when the hosts file could not be written.

```bash
benchbar site hosts
```

## site backup

```
benchbar site backup NAME [--with-files] [--json] [--dry-run]
```

Runs bench's own `bench --site NAME backup` and reports the new backup:
the database dump, the site config and, with `--with-files`, the public
and private files. The backup lands where bench always puts it,
`sites/NAME/private/backups/`, inside the bench: copy it elsewhere when
it has to outlive the bench. When the bench is stopped, its Redis is
started for the backup and stopped again.

| Flag | What it does |
|---|---|
| `--with-files` | Also back up the uploaded files (public and private) |
| `--json` | Print the new backup as JSON ([schema](../../json-schema.md#site-backups)); the progress goes to stderr |
| `--dry-run` | Print the command, change nothing |

Exit codes: 0 the backup exists; 1 the site does not exist or the backup
failed.

```bash
benchbar site backup macdev --with-files
```

## site backups

```
benchbar site backups NAME [--json]
```

Every backup of the site, newest first: when it was taken, its size,
whether it has the files, and the database file. Read only. The files
that share a timestamp are one backup.

Exit codes: 0; 1 when the site does not exist.

```bash
benchbar site backups macdev --json
```

## site drop

```
benchbar site drop NAME --confirm-site NAME [--new-default OTHER] [--dry-run] [--json]
```

Removes a site for good. Its database and database user are dropped,
and only the backup taken first can bring the data back; the site's
address stops working. Check that it is the site you mean and run with
`--dry-run` first.

It runs `bench drop-site`, which takes a backup with files first, drops
the database and user, and moves the site folder, with that backup, to
`archived/sites/` in the bench (nothing is deleted there). The
MariaDB root password comes from the Keychain and reaches bench on
stdin, never on the command line. Afterwards the site's `127.0.0.1` line
is removed from `/etc/hosts`, with one `sudo` prompt, when it is inside
benchbar's block and no other bench has a site with that name.

benchbar refuses:

- without `--confirm-site` repeating the site name exactly;
- the default site, unless `--new-default OTHER` names the site that
  takes its place (it is made the default first, like `site default`);
- the only site of the bench;
- when the backup fails: bench stops before it drops anything, and the
  site stays.

A hosts line outside benchbar's block is left alone, and so is the line
when there is no terminal to ask for the `sudo` password (the app): the
output says which command removes it by hand.

| Flag | What it does |
|---|---|
| `--confirm-site NAME` | The site name again; nothing is dropped without it |
| `--new-default OTHER` | For the default site: the site that becomes the default |
| `--dry-run` | Print the plan, change nothing (with `--json`: the steps) |
| `--json` | The result as JSON: the backup, the archived folder, the hosts line ([schema](../../json-schema.md#site-backups)) |

Exit codes: 0 the site is dropped; 1 a refusal or a failed step; 2 the
MariaDB root password is unknown (pass `MARIADB_ROOT_PASSWORD`).

```bash
benchbar site drop bbtest.localhost --confirm-site bbtest.localhost --dry-run
benchbar site drop bbtest.localhost --confirm-site bbtest.localhost
```

To bring a dropped site back, restore its backup from
`archived/sites/NAME/private/backups/` into a new site with
`bench --site NAME restore PATH --with-public-files ... --with-private-files ...`.
The restore does not bring back the site's `encryption_key`: copy it
from `archived/sites/NAME/site_config.json` into the new site's
`site_config.json`, or its stored passwords do not decrypt (see
[Troubleshooting](../../troubleshooting.md#common-stumbles)).
