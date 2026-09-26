---
title: "install and adopt"
description: "benchbar install, adopt and service: set up a new bench, register an existing one, or refresh only its background service. Flags, exit codes and examples."
---

These commands set a bench up. `install` builds a new one from nothing,
`adopt` registers one you already have, and `service` refreshes only the
background service. All three are safe to run again: a second run says
`unchanged`.

## Options for every command

These come from `benchbar --help` and work with every command below.

| Flag | What it does |
|---|---|
| `--bench-dir DIR` | Bench to act on (default: remembered, or auto detected) |
| `--site NAME` | Site name (default: remembered, or from the bench) |
| `--dry-run` | Print the full plan, change nothing |
| `-y`, `--yes` | Do not ask; secrets must come from the environment |
| `--json` | Versioned JSON where a command supports it ([JSON schema](../../json-schema.md)) |
| `--plain` | No colors or spinners (also: `NO_COLOR=1`, or a non TTY) |
| `-h`, `--help` | The help |
| `--version` | Print the version |

## install

```
benchbar install [--profile NAME] [--bundle NAME] [--make-default] [--port-offset N] [--dry-run] [--yes]
```

Runs phase 00 (system dependencies), phase 01 (bench and site) and the
background service, with a live step list. Safe to re-run: it only
changes what changed.

It asks for two passwords, the MariaDB root password (generated unless
you set `MARIADB_ROOT_PASSWORD`, kept in your Keychain) and the site's
Administrator password (or `ADMIN_PASSWORD`). It asks for `sudo` once, up
front, only when a step ahead needs it: the wkhtmltopdf package and the
`/etc/hosts` line.

| Flag | What it does |
|---|---|
| `--profile NAME` | Release profile (default `v15-lts`), or a team profile ([Configuration](../configuration.md#profiles)) |
| `--bundle NAME` | App bundle: `minimal`, `common` or `extended` |
| `--make-default` | Make this the default bench even when another one is already the default |
| `--port-offset N` | Use port block N (web 8000+N, socketio 9000+N, redis 11000+N and 13000+N). Default: keep the ports, or the next free block when another bench already uses them |
| `--with-schedule`, `--without-schedule` | Add the scheduler to `Procfile.lean`, or leave it out (the default) |
| `--dry-run` | Print the plan of every phase, change nothing |
| `-y`, `--yes` | Accept every default and confirmation, including the `sudo` line for `/etc/hosts`; the passwords must be in the environment |

With `--yes` the confirmation is skipped but the `sudo` password prompt
is not.

Exit codes: 0 success; 1 a step failed; 2 phase 00 or 01 stopped for a
manual step, most often a MariaDB root password that neither the
environment nor the Keychain knows (pass `MARIADB_ROOT_PASSWORD`).
Nothing else changed in that case.

```bash
MARIADB_ROOT_PASSWORD='...' ADMIN_PASSWORD='...' benchbar install --profile v16-lts --bundle common --yes
```

## adopt

```
benchbar adopt PATH [--make-default] [--port-offset N] [--site NAME] [--dry-run] [--yes]
```

Registers an existing bench: `Procfile.lean`, the runner, the agent, the
shell helpers and the hosts line. It shows the plan and asks; it never
runs `migrate`, `build` or `update`, and never touches `apps/`, `env/`,
the sites or the databases.

When the bench uses the same ports as an established bench, adopt moves
it to the next free port block with `bench set-config -g`, after asking.
The default bench never moves on its own. When honcho is missing, adopt
warns and does not install it into the bench env.

| Flag | What it does |
|---|---|
| `--make-default` | Make this the default bench even when another one is the default |
| `--port-offset N` | Use port block N instead of the automatic choice |
| `--site NAME` | The site `benchup` waits for, when the bench has several |
| `--dry-run` | Print the plan, change nothing |
| `-y`, `--yes` | Apply without asking |

Exit codes: 0 adopted (or unchanged); 1 the path is not a bench, the plan
was cancelled, or a step failed.

```bash
benchbar adopt ~/frappe-bench
```

## service

```
benchbar service [--with-schedule | --without-schedule] [--port-offset N] [--make-default] [--bench-dir DIR]
```

Installs or refreshes only the background service (phase 02): the lean
Procfile, the runner, the launchd agent and the shell helpers.

| Flag | What it does |
|---|---|
| `--with-schedule` | Add the scheduler to `Procfile.lean` (per bench, kept by repair) |
| `--without-schedule` | Remove it again (the default) |
| `--port-offset N` | Move the bench to port block N |
| `--make-default` | Make this the default bench |
| `--dry-run` | Print the plan, change nothing |

After a scheduler change on a running bench, run `benchbar restart`.

Exit codes: 0 success; 1 failure.

```bash
benchbar service --port-offset 1 --bench-dir ~/dev/v16-bench
```

## The phase scripts

The three phases also run on their own from the checkout:
`00-mac-system-deps.sh`, `01-install-bench-and-site.sh` and
`02-background-service.sh`. See
[Troubleshooting](../../troubleshooting.md#what-benchbar-writes) for their
flags.
