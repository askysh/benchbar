---
title: "Configuration"
description: "Release profiles, app bundles, team profile files, passwords, environment variables, bench discovery and port blocks for benchbar."
---

benchbar has no settings file of its own to edit. A bench is configured
by the flags you pass once (they are remembered per bench), the profile
and bundle it was installed with, and a few environment variables.

## Profiles

**Profiles** pick the Frappe branch and the matching toolchain:

| Profile | Frappe | ERPNext | Python | Node | MariaDB |
|---|---|---|---|---|---|
| `v15-lts` (default) | `version-15` | `version-15` | `python@3.11` | `node@20` | `mariadb@10.11` |
| `v16-lts` | `version-16` | `version-16` | `python@3.14` | `node@24` | `mariadb@11.8` |

Every profile also installs `pkgconf` (pkg-config) and
`mariadb-connector-c`, which `mysqlclient` needs to build on v16. When
`uv` is on PATH, `bench` itself is installed with `uv tool install
frappe-bench`, as the Frappe docs now recommend; an existing pipx install
is kept, and doctor says which one owns `bench`.

Each profile accepts a range of MariaDB servers: 10.6 to 10.11 for
`v15-lts`, 10.6 to 11.8 for `v16-lts`. A v16 bench shares the
`mariadb@10.11` server a v15 bench runs, so one MariaDB serves every
bench. The profiles are defined in `config/release-profiles.tsv`.

`--profile NAME` picks one for `install`; a bench remembers its profile.
A name that is not built in is looked up as a
[team profile](#team-profile-files).

## App bundles

**App bundles** pick what `install` adds beyond Frappe: `minimal`
(`erpnext`), `common` (`erpnext hrms payments`), `extended` (`erpnext hrms
payments crm helpdesk insights`). Definitions live in `config/`:
`config/app-bundles.tsv` for the bundles, `config/apps.tsv` for the app
registry that `benchbar app add NAME` reads, with the branch each app
follows per profile.

```bash
benchbar install --profile v16-lts --bundle common
MARIADB_ROOT_PASSWORD='...' ADMIN_PASSWORD='...' benchbar install --yes   # non interactive
benchbar autostart off                                                  # never start at login
```

`--yes` accepts every default and confirmation, including the `sudo` line
for `/etc/hosts`, and expects the passwords in the environment.

## Team profile files

A team profile is `NAME.toml` in `~/.config/benchbar/profiles/`, then in
each folder of `BENCHBAR_PROFILE_PATH`. A built in profile of the same
name wins. The format is a strict subset of TOML: strings, booleans,
integers and one line lists; no escapes, no inline tables.

| Key | Required | What it sets |
|---|---|---|
| `base` | yes | The built in profile for Python, Node and MariaDB, for example `"v15-lts"` |
| `description` | no | One line shown by `profile list` |
| `frappe_branch` | no | Another Frappe branch than the base's |
| `bundle` | no | An app bundle, instead of or besides `[[apps]]` |
| `site` | no | The default site name for `install` |
| `scheduler` | no | `true` to run the scheduler |
| `[[apps]]` `name` | yes, per app | The app's folder name |
| `[[apps]]` `repo` | yes, per app | Its git URL. A URL with a user name or token is refused |
| `[[apps]]` `branch` | yes, per app | The branch to clone |
| `[[apps]]` `commit` | no | A commit to pin |

An example is in [Teams](../guides/teams.md#team-profiles). `benchbar
profile create` writes one from a bench you have.

## Passwords

| What | Where it lives | When you need it |
|---|---|---|
| MariaDB root | your Keychain, item `benchbar-mariadb`; `benchbar mariadb-password` prints it after a confirmation | rarely: another `bench new-site`, or `mariadb -u root -p` |
| Administrator | you choose it in phase 2, or `ADMIN_PASSWORD` | every login at `http://macdev:8000` |

## Environment variables

| Variable | Used by | What it does |
|---|---|---|
| `MARIADB_ROOT_PASSWORD` | `install`, `site add`, `pull` | The MariaDB root password. A fresh MariaDB gets a generated one when unset; an existing one is read from the Keychain |
| `ADMIN_PASSWORD` | `install`, `site add`, `pull` | The Administrator password of a new site; for `pull`, a new Administrator password for the copy |
| `BENCHBAR_PROFILE_PATH` | `--profile`, `profile` | Colon separated folders with team profiles, for example a clone of your team's config repo |
| `BENCHBAR_LOCK` | `lock`, doctor | The lockfile path, when `--lock` is not given |
| `BENCHBAR_REPORT_DIR` | `report` | Where the zip goes instead of `~/Desktop` |
| `NO_COLOR` | every command | `NO_COLOR=1` turns off colors and spinners, like `--plain` |

The one line installer reads `BENCHBAR_HOME` (the checkout, default
`~/.local/share/benchbar`), `BENCHBAR_BIN_DIR` (default `~/.local/bin`),
`BENCHBAR_APP_DIR` (default `~/Applications`) and `BENCHBAR_RC_FILE`
(default `~/.zshrc`).

## Bench discovery

Point the tool at any bench once with `--bench-dir`; the path is
remembered. Without it, benchbar looks for a remembered bench, then
`~/frappe-bench`, `~/dev/frappe-bench`, and any folder under `~` or
`~/dev` that holds `sites/common_site_config.json`.

The first bench you install or adopt becomes the default; a second one
keeps the first as the default unless you pass `--make-default`. See
[Several benches](../guides/benches-and-sites.md#several-benches).

## Port blocks

Each bench uses a block of four ports: web `8000 + n`, socketio
`9000 + n`, Redis `11000 + n` and `13000 + n`. `--port-offset N` picks
block N for `install`, `adopt` or `service`. How a clashing bench is
moved is in [Port blocks](../guides/benches-and-sites.md#port-blocks).

## Where state lives

- Per bench settings (profile, site, scheduler, autostart, lockfile
  path) live in `.benchbar/benches/` in the checkout, one file per bench.
- The logs and backups of every mutating run are in the same folder:
  `.benchbar/logs/<timestamp>.log` and `.benchbar/backups/<timestamp>/`.
- The runner writes `<bench>/logs/.benchbar/state.json` on every state
  change ([schema](../json-schema.md#logsbenchbarstatejson)).
- Everything else benchbar writes is listed in
  [Troubleshooting](../troubleshooting.md#what-benchbar-writes).
