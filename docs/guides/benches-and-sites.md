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
it somewhere else when you need it to outlive the bench. Frappe's own
`bench backup` (and so `site backup`) first deletes the files in that
folder that are older than the site's `keep_backups_for_hours` (23 hours
when it is not set), so an old set there is not kept for you.

What is kept, and for how long:

- **Backups of a site: for ever.** bench's own `bench backup` deletes
  every file in that folder that is older than `keep_backups_for_hours`
  (23 hours by default). Every command of benchbar that takes a backup
  (`site backup`, the backup first of `site restore`, `site drop`,
  `pull --replace` and `app update`) keeps the older files: it holds a
  second name for each one under benchbar's state folder while bench
  runs, and puts back what bench deleted. benchbar never prunes a site's
  backups and never changes the site's config for this; remove old ones
  yourself when the disk fills. A backup that frappe's own scheduler
  takes is still pruned by frappe (set `keep_backups_for_hours` in the
  site config to keep more of those).

  How it works: before bench runs, each file of the site's backup folder
  gets a second name in the state folder
  (`backups/<run>/kept-sets/<site>/`). On the same volume that is a hard
  link and costs no space. When the state folder is on another volume
  (the bench on an external disk, say) a link is impossible, so benchbar
  copies the whole folder each run: it needs that much free space, checks
  it first, and stops before bench starts when it is not there. Afterwards
  the files bench deleted are put back and the second names go. A hard
  link shares the file's inode, so making the second name changes its status
  change time (`ctime`), which frappe reads to decide a backup is old:
  an old set looks recent to frappe for another `keep_backups_for_hours`.

  If a run is cut short (Ctrl-C, a closed terminal) benchbar puts the
  files back as it exits. If it is killed outright, or a file could not
  be put back, the kept copy may be the only copy, so benchbar never
  prunes it. The next backup of any site puts it back first and says so in
  `changed[]`, and until then `benchbar doctor` warns (`kept_backups`);
  `benchbar repair` puts the files back.
- **Read before use.** `site restore` and `pull` read the set before they
  change anything: the dump has to be a complete gzip file and, with
  `--with-files`, the file archives have to be readable tar archives. A
  set that is empty, cut short or unreadable stops the command with the
  file named, and `site backups` marks it `(incomplete)` when a part has
  no bytes.
- **benchbar's own files, newest kept.** In the state folder
  (`benchbar where` shows it): the newest 100 run logs
  (`logs/<date>-<time>-<pid>.log`), the newest 50 folders of
  `backups/<date>-<time>-<pid>/` (one that still holds a `restore-set`
  copy stays until that copy goes; the three newest per bench are kept),
  the newest 14 `update-check.<date>.txt` files, the newest 100 records
  of operations (`ops/<op_id>.json`, with the output of a `--background`
  run; never one that still runs: see [op](../reference/cli/other.md#op)),
  and no `state.env.*` temp file older than a day. The pruning runs at
  the start of a run that makes a log, and the run's `changed[]` says what
  it removed. The limits are `FL_KEEP_RUN_LOGS`, `FL_KEEP_STATE_BACKUPS`,
  `FL_KEEP_UPDATE_CHECKS` and `FL_KEEP_OPS`.
- **The bench's own log.** `benchup` keeps the tail of the log it
  replaces in `logs/bench.previous.log` and the three copies before it
  in `logs/bench.previous.1.log` to `.3.log`, so a crash is still there
  after two quick restarts.

`site restore` puts a backup back, into the site it came from or into a
new site (`--new`), with the encryption key of the set. A site that is
there is backed up with its files first, and the default site never
moves. Look at the plan first; it ends in a token that `--apply` takes:

```bash
benchbar site restore v16two --from 20260902_090000 --with-files --dry-run --json
benchbar site restore v16two --from 20260902_090000 --with-files --apply TOKEN --yes
benchbar site restore copy --from 20260902_090000 --from-site v16two --new --yes
```

`--no-migrate` stops after the restore, `--before-migrate SCRIPT` runs a
script of yours between the two. The restore starts the bench's Redis
itself when the bench is stopped and stops it again; for your own
`bench restore` or `bench migrate` on a stopped bench,
`benchbar up --services-only` starts that Redis and nothing else, and
`benchbar down` stops it. See
[site restore](../reference/cli/site.md#site-restore).

## Snapshots: save a site, put it back

A snapshot is for "save this site before I try something, and put it back
in one step". `site snapshot` takes a backup with files (the database,
the public and private files, `site_config.json`) and moves it out of
`sites/NAME/private/backups`, which frappe prunes, into
`sites/NAME/snapshots/<time>-<label>/`, next to a `manifest.json` with the
time, the label, the size and the apps of the bench with their commits.
Nothing in the site changes, and nothing removes a snapshot by itself.

```bash
benchbar site snapshot v16two --label "before the erpnext update"
benchbar site snapshots v16two              # newest first: label, size, and whether the bench's apps still match
benchbar site rollback v16two --to latest --dry-run --json
benchbar site rollback v16two --to latest --apply TOKEN --yes
```

`site rollback` is `site restore` with a snapshot as its source: the same
plan, token and run. It first takes a snapshot of the current state
labelled `before rollback`, so a rollback can itself be undone
(`site rollback NAME --to latest` right after it goes back), then restores
the snapshot's database and files into the same site, runs `bench migrate`
only when the snapshot's app commits differ from the bench's (the plan says
so; `--no-migrate` stops before it), and ends with the same check as a
restore. A rollback across an app change is allowed and warned: the
snapshot's data goes into the bench's current code. `--to` takes the name
from `site snapshots`, its time stamp, or `latest`. A snapshot that lacks
a part (the manifest, the database, the public or private files,
`site_config.json`) is refused, however it is named. A rollback puts back
the database, the files and the site's `encryption_key`; the other keys of
`site_config.json` stay as they are now.

The `before rollback` snapshot of a rollback that finished is its undo
point, and the earlier one is released. A rollback that failed halfway
leaves its own snapshot protected too (retention and `--prune` never take
it), and a retry does not move the undo point until it finishes.

The default site is a person's to roll back: an agent (`--for-agent`,
`benchbar mcp`, `BENCHBAR_NONINTERACTIVE=1`) or a run with no terminal, even
with `--yes`, gets a plan that cannot be applied, and in a terminal the
question names it as the default site.
Another site is never touched.

Retention keeps the newest 10 snapshots (`SNAPSHOT_KEEP` in the bench's
state file, or `--keep N`), but only reports it: `site snapshots` lists the
ones beyond the limit, and a person removes them with
`benchbar site snapshot drop SITE --prune` or one by name with
`benchbar site snapshot drop SITE SNAPSHOT`. Both ask first and are refused
for an agent. `--prune` never removes the `before rollback` snapshot of the
last rollback, and dropping it by name is refused too, because it is the way
back from that rollback; a person who is sure adds `--force-undo-point`.

A snapshot holds the whole database and the files, so it is as big as a
backup with files, and `bench backup` writes that set before anything is
moved (a rollback writes one more before it replaces anything). So both
commands first check the free space of the volume against the site's files
plus its largest database dump, and stop with a message when it does not fit;
`site snapshots` shows what the snapshots hold and what is free. The snapshots
live in the site's folder: `site drop` and `bench remove` move them into
`archived/sites/` with it, and their plans say how many and how big. See
[site snapshot](../reference/cli/site.md#site-snapshot).

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

## Retiring a bench

`benchbar bench forget PATH` takes a bench out of benchbar: its service files
are backed up and moved aside, its settings and its place in the list go, and
the folder, its sites and its databases stay. `benchbar bench remove PATH`
goes further: it backs up each site, drops its database and moves the folder
to `.benchbar-trash` next to it. Both show a plan first (`--dry-run`) and run
with `--apply TOKEN --yes`; `remove` is for a person at a terminal and asks you
to repeat the folder's name.

A bench for a try-out can say so: `benchbar install --scratch --ttl 3` sets it
up as before and marks it to expire in 3 days. `benchbar bench gc --dry-run`
lists the ones that expired (never the default bench), and a person at a
terminal applies the plan. Afterwards `benchbar site hosts --prune` removes the
hosts lines of sites that are gone, and `benchbar db orphans` lists databases
no site refers to. See [bench](../reference/cli/bench.md).

## Port blocks

Each bench has its own port block. How blocks work and how to sort out
the ports of several benches is in [Port blocks](../concepts/port-blocks.md).

## Limits of the background service

The agent (launchd on a Mac, a systemd user unit on Linux) raises the open
file limit of the bench: 10240 on a Mac, where launchd's own default of 256
is too low for Frappe's file watchers, and 65536 on Linux (the hard limit
stays at systemd's 524288, so the unit sets `LimitNOFILE=65536:524288`). Nothing else
changes by default: priority is normal and memory is not capped.

Three optional settings go in the bench's own state file (`benchbar where
--json` shows `state_dir`; the file is `benches/<name>-<hash>.env` in it),
one `KEY=value` per line, then `benchbar repair` writes the agent again:

| Key | Values | Effect |
|---|---|---|
| `SERVICE_NICE` | `0` to `19` | `Nice` (launchd) and `Nice=` (systemd): the bench yields to other programs |
| `SERVICE_BACKGROUND` | `on` | launchd `ProcessType` Background: low CPU and disk priority (Mac only) |
| `SNAPSHOT_KEEP` | `1` to `9999` | how many snapshots of a site `site snapshots` and `site snapshot drop --prune` keep (default 10); no service change |
| `SERVICE_MEMORY_HIGH` | `4G`, `512M`, `50%` | systemd `MemoryHigh=`: the unit is slowed and its memory reclaimed above it, never killed (Linux only). `0` and `0%` are refused: use `infinity` for no limit |

A value that is not valid is ignored and the default stays. A runaway
worker is still yours to stop with `benchbar down`; these settings only
make a bench a better neighbour on a laptop.

## Autostart

A bench that was running comes back after you log in. To keep one bench
from starting at login:

```bash
benchbar autostart off
```

`benchbar autostart on` turns it back on, and `benchbar autostart` alone
says which it is.
