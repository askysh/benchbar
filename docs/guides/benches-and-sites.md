---
title: "Benches and sites"
description: "Run a Frappe bench in the background every day: the shell helpers, the lean Procfile, the scheduler, sites, several benches side by side and their port blocks."
---

A bench is the folder that holds a Frappe installation: its apps in
`apps/`, its Python environment in `env/` and its sites in `sites/`. A
site is one Frappe instance in that bench, with its own database and
address. benchbar runs each bench under its own launchd agent,
`com.benchbar.<folder>`: launchd is the part of macOS that starts
programs in the background and keeps them running. The bench keeps
running when you close Terminal, comes back after a reboot if it
was running, and restarts after a crash. After three crashes in ten
minutes it pauses and BenchBar shows a notification.

## Daily use

`install` and `repair` write a few shell helpers into your `~/.zshrc`.
Each one is a short name for a `benchbar` command.

| Helper | Same as | What it does |
|---|---|---|
| `benchup` | `benchbar up` | Start the bench in the background and wait for the site |
| `benchdown` | `benchbar down` | Stop it and keep it stopped, also across reboots |
| `benchrestart` | `benchbar restart` | Restart every process. Needed after Python changes |
| `benchstatus` | `benchbar status` | Agent state, pid, last exit code, stop flag, site ping |
| `benchlogs` | `benchbar logs` | Follow `logs/bench.log`. Flags: `--worker`, `--previous`, `--no-follow` |
| `benchfg` | `benchbar fg` | Stop the service and run the bench in this Terminal, to watch its output |
| `benchwatch` | `benchbar watch` | `bench watch` for JS and CSS rebuilds |
| `benchdoctor` | `benchbar doctor` | Read only health report |
| `benchcd` | `cd "$(benchbar path)"` | Jump into the bench folder |

Every flag is in the [CLI reference](../reference/cli/running.md).

## The lean Procfile and the scheduler

A Procfile lists the processes a bench runs, one per line; honcho, a
small process manager, starts them all and stops them together. The
lean Procfile, `Procfile.lean`, runs Redis, the web server, socketio and
one worker. It has no watcher: run `benchwatch` while you edit assets. The scheduler is
opt in per bench: `benchbar service --with-schedule` adds it (and
`--without-schedule` takes it out again), then `benchbar restart`.

`Procfile.lean` sits next to the bench's own `Procfile`. `bench update`
and `bench setup procfile` rewrite `Procfile` and leave `Procfile.lean`
alone. The BenchBar window has a scheduler switch on each bench's
Overview page.

## Sites

```bash
benchbar site list                          # every site; the default is marked
benchbar site add v16two --bundle minimal   # a new site with apps already in the bench
benchbar site default v16two                # benchup waits for it, the app opens it
benchbar site hosts                         # a 127.0.0.1 line for every site
```

- `site list` shows the bench's sites.
- `site add NAME` creates a new site on the same MariaDB, with its
  `/etc/hosts` line; `--bundle` or `--apps` installs apps already in the
  bench. The default site does not change.
- `site default NAME` makes NAME the site `benchup` waits for and the app
  opens.
- `site hosts` adds every missing hosts line.

`site add` uses the MariaDB root password from the Keychain and asks for
the new site's Administrator password (or reads `ADMIN_PASSWORD`). To
copy a production site into a new local one, see
[benchbar pull](teams.md#a-copy-of-production).

### Backing up and dropping a site

```bash
benchbar site backup v16two --with-files    # database, site config and uploaded files
benchbar site backups v16two                # every backup, newest first
```

A backup lands inside the bench, in `sites/NAME/private/backups/`. Copy
it somewhere else when you need it to outlive the bench.

`site drop` removes a site for good: its database and database user are
dropped, and only the backup it takes first can bring them back. Before
you drop one, check that it is the site you mean (`benchbar site list`)
and that nothing you need exists only there. Then look at the plan
first, and run it with the site name typed twice:

```bash
benchbar site drop v16two --confirm-site v16two --dry-run
benchbar site drop v16two --confirm-site v16two
```

It takes a backup with files first and stops if that fails, then drops
the database, moves the site folder with the backup to
`archived/sites/` in the bench, and removes the site's `/etc/hosts` line
(one `sudo` prompt). The default site also needs `--new-default OTHER`,
and the only site of a bench is never dropped. See
[site drop](../reference/cli/site.md#site-drop) for how to restore one.

## Finding the bench

Point the tool at any bench once with `--bench-dir`; the path is
remembered. Without it, benchbar looks for a remembered bench, then
`~/frappe-bench`, `~/dev/frappe-bench`, and any folder directly under
`~` or `~/dev` that holds `sites/common_site_config.json`.

`benchbar list` prints every bench benchbar knows about. For benches
deeper in a folder, `benchbar scan ~/Developer` lists them (read only)
and `benchbar register PATH ...` remembers the ones you pick, without
touching their services; see [scan and register](../reference/cli/scan.md).

## Several benches

Several benches work side by side, each under its own agent
`com.benchbar.<folder>`, with its own profile, site and autostart setting.
Installing or adopting a second bench keeps the first one as the default
(the one `benchup` starts) unless you pass `--make-default`; the PATH
lines in your shell block follow the default bench's profile. Stopping
one bench never touches another.

To act on a bench that is not the default, add `--bench-dir` with its
folder (`~/dev/v16-bench` here is an example):

```bash
benchbar up --bench-dir ~/dev/v16-bench
benchbar status --bench-dir ~/dev/v16-bench
```

`benchup` refuses to start a bench whose ports a running bench, or any
other program, is listening on; it never takes their ports. When only a
stopped bench shares the ports, it warns and asks, so the two can run one
at a time. Either way it prints the fix, `benchbar ports setup`, which
gives each bench its own block.

## Port blocks

Each bench has its own port block: web `8000 + n`, socketio `9000 + n`,
Redis `11000 + n` and `13000 + n`. `bench init` already counts up for
benches in the same folder; `install` and `adopt` also check every bench
benchbar knows and the ports in use, and move a new bench that clashes
with an established one to the next free block, with `bench set-config -g`
and `bench setup redis`. `--port-offset N` picks a block, for example
`benchbar service --port-offset 1 --bench-dir ~/dev/v16-bench`.

The default bench never moves on its own. Doctor's
[`port_clash`](doctor-and-repair.md#port_clash) check warns when two
benches share ports.

To sort out the ports of several benches at once, preview first, then
apply:

```bash
benchbar ports plan -- ~/frappe-bench ~/dev/v16-bench    # read only
benchbar ports setup -- ~/frappe-bench ~/dev/v16-bench   # the same plan, asks once, then applies
```

Stop the benches first (`benchbar down --bench-dir PATH`): the plan
marks a running bench as blocked, and setup applies nothing while any
bench in it is blocked. The plan lists every bench's ports and the
service files it would rewrite, and setup never starts a bench; run
`benchup` afterwards. `benchbar ports check --bench-dir PATH` shows the
conflicts of one bench. Every command and flag is in the
[ports reference](../reference/cli/ports.md).

## Autostart

A bench that was running comes back after you log in. To keep one bench
from starting at login:

```bash
benchbar autostart off
```

`benchbar autostart on` turns it back on, and `benchbar autostart` alone
says which it is.
