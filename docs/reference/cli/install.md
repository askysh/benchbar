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
| `--json` | Versioned JSON: one document for a command that reads, JSON lines for one that changes things ([JSON schema](../../json-schema.md)) |
| `--jsonl` | JSON lines (`plan`, `step`, `progress`, `done`) for any command that changes things |
| `--for-agent` | `--jsonl` for a command that changes things, `--json` for one that reads, plus `BENCHBAR_NONINTERACTIVE=1`, `NO_COLOR=1` and `--plain` |
| `--plain` | No colors or spinners (also: `NO_COLOR=1`, or a non TTY) |
| `-h`, `--help` | The help. `benchbar COMMAND --help` prints that command's flags, what it needs (a terminal, `sudo`, the network) and whether it changes things |
| `--version` | Print the version, and the BenchBar app's when it is installed |

The environment variable `BENCHBAR_NONINTERACTIVE=1` makes a command
refuse to ask. One that needs an input it does not have names all of
them in one error, before it takes the lock or touches a bench. See
[Coding agents and MCP](../../guides/agents.md#the-cli-as-an-agent-contract).

`benchbar commands --json` lists every command with its flags, its
environment variables and what each needs, as one document.

## install

```
benchbar install [--profile NAME] [--bundle NAME] [--make-default] [--port-offset N] [--frappe-commit SHA] [--erpnext-commit SHA] [--offline] [--dry-run] [--yes] [--json]
```

Runs phase 00 (system dependencies), phase 01 (bench and site) and the
background service, with a live step list. Safe to re-run: it only
changes what changed.

It asks for two passwords, the MariaDB root password (generated unless
you set `MARIADB_ROOT_PASSWORD`, kept in your Keychain) and the site's
Administrator password (or `ADMIN_PASSWORD`). It asks for `sudo` once, up
front, only when a step ahead needs it: the wkhtmltopdf package and the
`/etc/hosts` line. Those two steps run first, and the `sudo` credential
is dropped (`sudo -k`) before Homebrew, pip, npm, yarn or `bench get-app`
run anything, so no package's install script finds a cached `sudo`. The
package is copied into a folder only root can write, hashed there and
installed from there. The two passwords stay inside `benchbar` and the
phase scripts: no other program started by the install sees them.

| Flag | What it does |
|---|---|
| `--profile NAME` | Release profile (default `v15-lts`), or a team profile ([Configuration](../configuration.md#profiles)) |
| `--bundle NAME` | App bundle: `minimal`, `common` or `extended` |
| `--make-default` | Make this the default bench even when another one is already the default |
| `--port-offset N` | Use port block N (web 8000+N, socketio 9000+N, redis 11000+N and 13000+N). Default: keep the ports, or the next free block when another bench already uses them |
| `--with-schedule`, `--without-schedule` | Add the scheduler to `Procfile.lean`, or leave it out (the default) |
| `--dry-run` | Print the plan of every phase, change nothing |
| `--frappe-commit SHA`, `--erpnext-commit SHA` | Pin frappe or erpnext to a commit (7 to 40 hex characters; a team profile can say `frappe_commit` and `erpnext_commit`). The flag wins over the profile. A pinned clone is fetched without its first build, the commit is checked out, and one build follows. A commit the clone does not reach stops the install before anything is built or created |
| `--offline` | Skip the remote branch checks of both phase scripts (also `OFFLINE=1` or `BENCHBAR_OFFLINE=1`) |
| `--allow-windows-fs` | WSL only: accept a bench on the Windows file system (`/mnt/c`, drvfs, 9p). Refused by default: it is very slow, file watching does not work and permissions break |
| `-y`, `--yes` | Accept every default and confirmation, including the `sudo` line for `/etc/hosts`; the passwords must be in the environment |
| `--json` | JSON lines for the BenchBar app and agents: `plan`, `step`, `progress` and a closing `done` ([schema](../../json-schema.md#benchbar-install---json)). Needs `--yes` or `--dry-run`, takes every value from a flag or the environment and never asks |

`BENCH_INIT_TIMEOUT_SECONDS` sets how long `bench init` may run before it is
stopped (default 2700, `0` for no limit). A half built bench left by a stopped
init, with frappe as its only app and no site, is moved aside (never deleted)
by the next `install`, which starts `bench init` again. A bench with another
app or a site is never moved: `install` stops and names `benchbar repair`.

With `--yes` the confirmation is skipped but the `sudo` password prompt
is not. When the BenchBar app runs it, `BENCHBAR_SUDO=gui` is set, and each of
the two steps that need root asks in macOS's own password dialog, at
most two per run ([the privileged steps](../../json-schema.md#the-privileged-steps-and-benchbar_sudogui)).

Exit codes: 0 success; 1 a step failed; 2 phase 00 or 01 stopped for a
manual step, most often a MariaDB root password that neither the
environment nor the Keychain knows (pass `MARIADB_ROOT_PASSWORD`).
System dependencies may be set up; no bench or site was created.

```bash
MARIADB_ROOT_PASSWORD='...' ADMIN_PASSWORD='...' benchbar install --profile v16-lts --bundle common --yes
```

## adopt

```
benchbar adopt PATH [--make-default] [--port-offset N] [--site NAME] [--dry-run] [--yes] [--json]
```

Registers an existing bench: `Procfile.lean`, the runner, the agent, the
shell helpers and the hosts line. It shows the plan and asks; it never
runs `migrate`, `build` or `update`, and never touches `apps/`, `env/`,
the sites or the databases.

When the bench uses the same ports as an established bench, adopt moves
it to the next free port block, after asking: `bench set-config -g`
writes the port keys into `sites/common_site_config.json` (backed up
first) and `bench setup redis` rewrites `config/redis_*.conf`. That is
the only change under `sites/`.
The default bench never moves on its own. When honcho is missing, adopt
warns and does not install it into the bench env.

| Flag | What it does |
|---|---|
| `--make-default` | Make this the default bench even when another one is the default |
| `--port-offset N` | Use port block N instead of the automatic choice |
| `--site NAME` | The site `benchup` waits for, when the bench has several |
| `--allow-windows-fs` | WSL only: accept a bench on the Windows file system (`/mnt/c`, drvfs, 9p), which is refused by default |
| `--dry-run` | Print the plan, change nothing |
| `-y`, `--yes` | Apply without asking |
| `--json` | JSON lines, as for `install` ([schema](../../json-schema.md#benchbar-install---json)); needs `--yes` or `--dry-run` |

A bench path with a double quote, backslash, `$`, backtick, `<`, `>`,
`&` or a control character in it is refused before anything is written:
the runner script and the launchd agent cannot carry it as plain text.
Move the bench to a plainer folder (spaces and apostrophes are fine).

Exit codes: 0 adopted (or unchanged); 1 the path is not a bench, the path
has a character the service files cannot carry, the plan was cancelled,
or a step failed.

```bash
benchbar adopt ~/frappe-bench
```

## service

```
benchbar service [--with-schedule | --without-schedule] [--port-offset N] [--make-default] [--json] [--bench-dir DIR]
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
| `--json` | JSON lines ending in a `done` ([the done fields](../../json-schema.md#the-done-fields-08)) |

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

## Flags, needs and environment

These tables come from the code (`benchbar commands --json`); the sections above explain them.

<!-- generated:cli-commands install adopt service -->
<!-- Generated by scripts/docs-reference.py from the code. Edit the code, then run: python3 -I scripts/docs-reference.py --write -->

| Command | Terminal | `sudo` | Network | Changes things | JSON |
|---|---|---|---|---|---|
| `benchbar install [--profile NAME] [--bundle NAME] [--dry-run] [--yes] [--json]` | yes | yes | yes | yes | stream |
| `benchbar adopt PATH [--dry-run] [--yes] [--json]` | yes | yes | no | yes | stream |
| `benchbar service [--with-schedule\|--without-schedule] [--port-offset N] [--dry-run\|--apply TOKEN --yes] [--json]` | yes | no | no | yes | stream |

Terminal: may ask a question on a terminal. `sudo`: may run `sudo`. Network: may reach the network.
JSON: `document` is one JSON line, `stream` is JSON lines ending in a `done` line.

| Command | Flag | Value | What it does |
|---|---|---|---|
| `install` | `--profile` | `NAME` | Release profile (default v15-lts) or a team profile. |
| `install` | `--bundle` | `NAME` | App bundle: minimal, common or extended. |
| `install` | `--port-offset` | `N` | Use port block N (web 8000+N). |
| `install` | `--make-default` |  | Make this the default bench even when another one is. |
| `install` | `--allow-windows-fs` |  | WSL only: accept a bench on the Windows file system (/mnt/c, drvfs, 9p). It is refused by default: slow, no file watching, broken permissions. |
| `install` | `--offline` |  | Skip the remote branch checks. |
| `install` | `--frappe-commit` | `SHA` | Pin the frappe clone to this commit (or FRAPPE_COMMIT, or the team profile). |
| `install` | `--erpnext-commit` | `SHA` | Pin the erpnext clone to this commit. |
| `install` | `--dry-run` |  | Print the plan, change nothing. |
| `install` | `--yes` |  | Do not ask; secrets come from the environment. |
| `adopt` | `--port-offset` | `N` | Move the bench to port block N. |
| `adopt` | `--make-default` |  | Make this the default bench. |
| `adopt` | `--allow-windows-fs` |  | WSL only: accept a bench on the Windows file system (/mnt/c, drvfs, 9p), which is refused by default. |
| `adopt` | `--dry-run` |  | Print the plan, change nothing. |
| `adopt` | `--yes` |  | Do not ask. |
| `service` | `--with-schedule` |  | Add the scheduler to Procfile.lean. |
| `service` | `--without-schedule` |  | Remove it again. |
| `service` | `--port-offset` | `N` | Use port block N. |
| `service` | `--dry-run` |  | Print the plan and its token, change nothing. |
| `service` | `--apply` | `TOKEN` | Run exactly that plan (with --yes). |

| Command | Environment variable | What it does |
|---|---|---|
| `install` | `ADMIN_PASSWORD` | The new site's Administrator password. |
| `install` | `MARIADB_ROOT_PASSWORD` | Only when MariaDB has a password benchbar does not know. |
| `install` | `BENCH_INIT_TIMEOUT_SECONDS` | Seconds bench init may take before it is stopped (default 2700, 0 for no limit). A half built bench left by a stopped init is moved aside by the next install, which starts it again. |
| `install` | `BENCHBAR_SUDO` | Linux only: env makes the sudo steps use BENCHBAR_SUDO_PASSWORD, no terminal needed (a wrong one fails at once with error_id sudo_password_wrong, before any change). |
| `install` | `BENCHBAR_SUDO_PASSWORD` | The sudo password, with BENCHBAR_SUDO=env. Read once at startup and removed from the environment; never in argv, the log or a child. |
| `adopt` | `BENCHBAR_SUDO` | Linux only: env makes the sudo steps use BENCHBAR_SUDO_PASSWORD, no terminal needed (a wrong one fails at once with error_id sudo_password_wrong, before any change). |
| `adopt` | `BENCHBAR_SUDO_PASSWORD` | The sudo password, with BENCHBAR_SUDO=env. Read once at startup and removed from the environment; never in argv, the log or a child. |
| `service` | `BENCHBAR_SUDO` | Linux only: env makes the sudo steps use BENCHBAR_SUDO_PASSWORD, no terminal needed (a wrong one fails at once with error_id sudo_password_wrong, before any change). |
| `service` | `BENCHBAR_SUDO_PASSWORD` | The sudo password, with BENCHBAR_SUDO=env. Read once at startup and removed from the environment; never in argv, the log or a child. |
<!-- /generated:cli-commands -->
