---
title: "app"
description: "benchbar app list, add, install and update: the apps of a bench, new apps from the registry or any git URL, and fast forward updates with a changelog."
---

The apps of a bench. The guide is [Apps](../../guides/apps.md). Every
command takes the [options for every command](install.md#options-for-every-command).
None of them runs `bench update`, drops a site or deletes a folder.

## app list

```
benchbar app list [--json] [--no-sites]
```

Every app: branch, commit, local changes, and the sites that have it.
`benchbar app` alone does the same.

| Flag | What it does |
|---|---|
| `--json` | The list as JSON ([schema](../../json-schema.md#benchbar-app-list---json)) |
| `--no-sites` | Read the last site lists instead of asking bench (faster) |

Exit codes: 0; 1 when no bench is found.

```bash
benchbar app list --json
```

## app add

```
benchbar app add NAME|URL [--branch B] [--name N] [--site S | --all-sites]
```

`bench get-app` from `config/apps.tsv` or any git URL (GitHub, SSH, a
host alias), after checking that git can read it. Never replaces an app.

| Flag | What it does |
|---|---|
| `--branch B` | Clone this branch instead of the registry's |
| `--name N` | The app's folder name, when it differs from the URL |
| `--site S` | Install the app on this site afterwards |
| `--all-sites` | Install it on every site |

Exit codes: 0 added (or already there); 1 the repo is not readable, the
app exists, or a step failed.

```bash
benchbar app add git@github.com:acme/acme.git --branch main --all-sites
```

## app install

```
benchbar app install NAME --site S
```

Installs an app of the bench on one site.

| Flag | What it does |
|---|---|
| `--site S` | The site to install on |

Exit codes: 0; 1 on failure.

```bash
benchbar app install crm --site v16two
```

## app update

```
benchbar app update NAME [--skip-backup] [--dry-run] [--json]
```

Fast forwards one app with a changelog first, backs up the sites that
have it, then runs requirements, migrate and build. A dirty or diverged
app is refused; it never rebases or resets.

| Flag | What it does |
|---|---|
| `--skip-backup` | Do not back up the sites first |
| `--dry-run` | Show the changelog and the plan, change nothing |
| `--json` | With `--dry-run`: the plan as JSON ([schema](../../json-schema.md#benchbar-app-update-name---dry-run---json)) |

Exit codes: 0 updated or already current; 1 refused or a step failed.

```bash
benchbar app update erpnext --dry-run
```
