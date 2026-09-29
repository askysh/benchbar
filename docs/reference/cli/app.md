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
It shows the plan and asks first. Then it clones, builds, installs the
app on the sites you name (`bench install-app`, which writes its tables
into each site's database) and restarts the bench when it is running.
The app's own code runs on your Mac, so add only repos you trust.

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

### The plan and its token

```
benchbar app add NAME|URL [same flags] --dry-run --json
benchbar app add NAME|URL [same flags] --apply TOKEN --yes [--json]
```

`--dry-run --json` prints the plan and changes nothing: the resolved app,
repo and branch, whether git can read the repo (without a prompt, with a
timeout), the sites, the required apps from `hooks.py` (read from a
shallow clone in a temp folder, then removed) and whether each resolves
through `config/apps.tsv` or the team profile, the steps, and a `token`.
See the [JSON schema](../../json-schema.md#benchbar-app-add-url---dry-run---json).

`--apply TOKEN --yes`, with the same arguments, recomputes the plan
under the CLI lock and runs exactly that plan, including the planned
required apps, without asking anything. `benchbar_app_add` in
[benchbar mcp](mcp.md) uses it.

| Flag | What it does |
|---|---|
| `--apply TOKEN` | Run the plan with this token; needs `--yes`, not with `--dry-run` |
| `--json` | With `--dry-run` the plan, with `--apply` the result; text goes to stderr |

Exit codes: 0 planned, or applied (also when there was nothing to do); 1
the token no longer matches (`sites/apps.txt`, `apps/` or the sites
changed: plan again), the plan cannot be applied (`can_apply` false), or
a step failed. `--json` without `--dry-run` or `--apply` is refused.

```bash
benchbar app add https://github.com/acme/acme_crm --site macdev --dry-run --json
benchbar app add https://github.com/acme/acme_crm --site macdev --apply 3f9c...e1 --yes
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

## app focus

```
benchbar app focus [--list] [--json] [--fetch]
benchbar app focus NAME [--auto] [--json]
benchbar app unfocus NAME [--json]
```

Focus apps are the ones you work on. Doctor warns when an app they need
falls behind its remote (`dependency_behind`), never about a focus app
itself. See [focus apps](../../guides/apps.md#focus-apps-and-their-dependencies).

Without NAME: every app, whether it is a focus app and why, which focus
apps need it, and how far behind it is. With NAME: `focus` pins it as a
focus app, `unfocus` pins it as not one (`ignore`), and `--auto` removes
the pin so it is inferred again. The pin is kept in the bench's state.

| Flag | What it does |
|---|---|
| `--list` | List the apps (the same as no NAME) |
| `--json` | As JSON ([schema](../../json-schema.md#benchbar-app-focus---json)) |
| `--fetch` | Fetch the focus apps' dependencies first (20 seconds each, no prompt; not with `OFFLINE=1` or `--dry-run`) |
| `--auto` | With NAME: remove the pin, infer again |

Exit codes: 0; 1 when the app or the bench is not found.

```bash
benchbar app focus
benchbar app focus exponent_ecr
benchbar app unfocus erpnext
```
