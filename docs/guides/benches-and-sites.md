---
title: "Benches and sites"
description: "Run a Frappe bench in the background every day: the shell helpers, the lean Procfile, the scheduler, sites, several benches side by side and their port blocks."
---

A bench runs under its own launchd agent, `com.benchbar.<folder>`. It
keeps running when you close Terminal, comes back after a reboot if it
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
| `benchfg` | `benchbar fg` | Stop the service and run honcho in the foreground |
| `benchwatch` | `benchbar watch` | `bench watch` for JS and CSS rebuilds |
| `benchdoctor` | `benchbar doctor` | Read only health report |
| `benchcd` | `cd "$(benchbar path)"` | Jump into the bench folder |

Every flag is in the [CLI reference](../reference/cli/running.md).

## The lean Procfile and the scheduler

The lean Procfile runs Redis, the web server, socketio and one worker. It
has no watcher: run `benchwatch` while you edit assets. The scheduler is
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

## Finding the bench

Point the tool at any bench once with `--bench-dir`; the path is
remembered. Without it, benchbar looks for a remembered bench, then
`~/frappe-bench`, `~/dev/frappe-bench`, and any folder under `~` or
`~/dev` that holds `sites/common_site_config.json`.

`benchbar list` prints every bench benchbar knows about.

## Several benches

Several benches work side by side, each under its own agent
`com.benchbar.<folder>`, with its own profile, site and autostart setting.
Installing or adopting a second bench keeps the first one as the default
(the one `benchup` starts) unless you pass `--make-default`; the PATH
lines in your shell block follow the default bench's profile. Stopping
one bench never touches another.

To act on a bench that is not the default, add `--bench-dir`:

```bash
benchbar up --bench-dir ~/dev/v16-bench
benchbar status --bench-dir ~/dev/v16-bench
```

`benchup` warns when another running bench already uses the same web or
socketio port, and asks before it starts.

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

## Autostart

A bench that was running comes back after you log in. To keep one bench
from starting at login:

```bash
benchbar autostart off
```

`benchbar autostart on` turns it back on, and `benchbar autostart` alone
says which it is.
