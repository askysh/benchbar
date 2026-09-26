---
title: "site"
description: "benchbar site list, add, default and hosts: the sites of a bench, a new site on the same MariaDB, the default site and the /etc/hosts lines."
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
