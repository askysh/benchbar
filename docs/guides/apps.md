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

## In the app

The BenchBar window's Apps page does the same: add an app from the
registry or any GitHub URL, install it on a site, and update it after
reading the changelog. See [The menu bar app](../app.md#the-benchbar-window).

## Keeping a team on the same apps

A team profile names the apps a new bench gets, and the `benchbar.toml`
lockfile pins their commits. See [Teams](teams.md).
