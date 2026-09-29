---
title: "Apps"
description: "Add Frappe apps from the registry or any git repository, install them on sites, and update them with a changelog first, without bench update."
---

`benchbar app` adds, installs and updates the apps of a bench. It uses
bench itself (`get-app`, `install-app`, `migrate`, `build`) and git only
to read an app and to fast forward it.

```bash
benchbar app list                                   # branch, commit, local changes, sites
benchbar app add crm --site macdev                  # from config/apps.tsv
benchbar app add git@github.com:acme/acme.git --branch main --all-sites
benchbar app install crm --site v16two              # an app the bench already has
benchbar app update erpnext --dry-run               # the changelog and the plan
benchbar app update erpnext                         # backup, fast forward, migrate, build
```

## Adding an app

`app add` takes a name from the registry in `config/apps.tsv` (erpnext,
hrms, payments, crm, helpdesk, lms, wiki, insights, drive, builder, raven)
or any git URL: GitHub, SSH, or a host alias from `~/.ssh/config`. The
registry names the branch for each [profile](../reference/configuration.md#profiles).
`--branch` picks another branch, `--name` another folder name, and
`--site S` or `--all-sites` installs the app right away.

`app add` checks that git can read the repo before it changes anything,
so a private repo without a key or token fails at once with the fix.
Private repositories work with your SSH key or your `gh` login. It never
replaces an existing app. A clone that does not finish is moved to the
backups, not left half done.

`app add URL --dry-run --json` prints the whole plan first, required
apps from `hooks.py` included, with a token; `--apply TOKEN --yes` runs
exactly that plan without a question. Coding agents add apps this way
(see [Coding agents and MCP](agents.md#adding-an-app)).

## Installing on a site

`app install NAME --site S` installs an app the bench already has on one
of its sites.

## Updating an app

`app update NAME` fast forwards one app. It shows the changelog first,
backs up the sites that have the app (`--skip-backup` skips that), then
runs requirements, migrate and build. `--dry-run` shows the changelog and
the plan and changes nothing.

`app update` never runs `bench update`, never rebases and never resets: a
dirty or diverged app is refused.

## Focus apps and their dependencies

You pull the app you work on yourself, so a warning about it is noise.
What goes stale quietly are the apps it needs. benchbar calls the apps
you work on focus apps, and doctor warns only about the apps they need:

```
[WARN] Dependencies of focus apps: exponent_custom_v1 (needed by exponent_ecr) is 30 commits / 12 days behind upstream/develop
  fix: benchbar app update exponent_custom_v1 --bench-dir ~/frappe-bench
```

An app is a focus app when it has local changes, is on a branch other
than the one the profile names (or the remote's default branch), or has
a commit by your `git config user.email` in the last 14 days. What it
needs comes from `required_apps` in each app's `hooks.py`, followed
through other apps, so an app two steps away counts too. Every other app
gets one summary line (`apps_behind`).

```bash
benchbar app focus                   # every app: focus or not, why, needed by, behind
benchbar app focus exponent_ecr      # pin it as a focus app
benchbar app unfocus erpnext         # pin it as not one (a branch you only tried)
benchbar app focus erpnext --auto    # infer again
```

Doctor is read only and never touches the network on its own, so it
stays fast and works offline: the numbers are those of the last fetch,
yours or benchbar's, and an app never fetched is unknown, never a
failure. `benchbar doctor --fetch` or `benchbar app focus --fetch`
fetches the dependencies first; `OFFLINE=1` never fetches.

## In the app

The BenchBar window's Apps page does the same: add an app from the
registry or any GitHub URL, install it on a site, and update it after
reading the changelog. Each app shows whether it is a focus app, and a
menu sets it to Auto, Focus or Ignore; Check Remotes fetches the
dependencies (`app focus --fetch`). See [The menu bar app](../app.md#the-benchbar-window).

## Keeping a team on the same apps

A team profile names the apps a new bench gets, and the `benchbar.toml`
lockfile pins their commits. See [Teams](teams.md).
