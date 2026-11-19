---
title: "lease"
description: "benchbar lease take, renew, release and list: hold a bench or a site for a while, so another agent or the app does not restart, migrate, drop or restore it meanwhile."
---

The run lock holds for one command. A lease holds for many: an agent that
runs tests on a site for twenty minutes, or a person who watches a
migration, takes a lease first. While it runs, the commands that change
what it covers refuse and say who holds it and until when. Reading is never
refused.

A lease is benchbar's own state. It does not stop a process, lock a file or
change a bench. It is a promise that every benchbar command, the BenchBar app
and `benchbar mcp` keep.

## lease

```
benchbar lease take (--bench PATH | --site NAME) [--for MINUTES] [--note TEXT] [--json]
benchbar lease renew ID [--for MINUTES] [--json]
benchbar lease release ID [--json]
benchbar lease list [--bench PATH] [--json]
```

`lease take` leases a whole bench (`--bench PATH`, every site of it) or one
site (`--site NAME`, of the bench `--bench-dir` names, or of the default
bench). It returns the lease id. `--for` is the length in minutes: 1 to 480,
30 by default. `--note` says why, for whoever meets the lease: printable ASCII,
at most 120 characters, anything else is a `?`. `lease renew` moves the end to
`--for` minutes from now (by default the first length); an expired lease
cannot be renewed, take a new one. `lease release` lets go; a lease that is
already gone is "unchanged", not an error. `lease list` shows the active
leases of every bench, or of the one `--bench` names.

One holder at a time: a lease on a bench conflicts with a lease on any of its
sites, and two leases on one site conflict. The second `lease take` stops and
names the first holder. A lease that has expired is ignored everywhere and
dropped the next time the file is written.

```
$ benchbar lease take --site qa1.localhost --for 20 --note "running the QA suite"
[OK] lease l-3f9a1c07be52 taken on site qa1.localhost of /Users/you/frappe-bench for 20 minutes (until 2026-11-19T15:20:00Z), held by claude-qa
$ benchbar restart
[FAIL] The site qa1.localhost of /Users/you/frappe-bench is leased by claude-qa until 2026-11-19T15:20:00Z (running the QA suite). Nothing was changed.
$ benchbar restart --lease l-3f9a1c07be52
```

### Who holds it

The holder is `BENCHBAR_CALLER`: a name the agent or script chose, 1 to 40
letters, digits or `. _ @ : + -`. `benchbar mcp` sets it for every command it
runs, to `mcp:CLIENT:PID` (your own `BENCHBAR_CALLER` wins). Without it, a run
under `BENCHBAR_NONINTERACTIVE` or `--for-agent` is `agent`, and a run in a
terminal is the login name. Set `BENCHBAR_CALLER` when two agents share a
machine, so they are two holders.

### What a lease stops

| Class | Commands | Stopped by |
|---|---|---|
| The whole bench | `restart`, `down`, `fg`, `repair`, `service`, `install`, `adopt`, `uninstall-service`, `app add`, `app update`, `lock apply`, `ports apply`, `ports setup` | a lease on the bench, or on any site of it |
| One site | `site drop`, `site restore`, `pull` (the site it creates or replaces), `app install --site` | a lease on the bench, or on that site |
| The bench itself | `site add`, `site default` | a lease on the bench |

These stop before the run lock is taken and before anything changes, with exit
code 1 and the error id `lease_held` in `--json`. `--dry-run` and every read
(`status`, `doctor`, `logs`, `site list`, `site backups`, `app list`, `open`,
`report`) pass. So do `up` (it starts what is stopped and never interrupts),
`site backup`, `console`, `db`, `watch`, `autostart` and `listen`: benchbar
cannot tell what a console is for, and a backup is what a lease holder needs
most.

### Passing a lease

`--lease ID` is for the holder: the command goes ahead for the lease with that
id (repeat it for several). Over MCP the tools that change a bench take it as
`lease`. A lease id that has expired is refused with the rest of the message.

`--break-lease` is for a person: it goes ahead although the lease stands, and
prints a warning that names the holder. It is refused (exit code 2, error id
`lease_break_refused`) under `BENCHBAR_NONINTERACTIVE`, `--for-agent`,
`benchbar mcp` and in a run without a terminal, unless the Mac app or the
Windows tray passes `BENCHBAR_NONINTERACTIVE=0` after its own alert, like
[`labs on`](labs.md). An agent that meets a lease waits or asks the person.

An id is what lets a run change a leased bench, so `lease list` shows it only
to the lease's holder and to a person at a terminal; for anyone else `id` is
`null`, and `status --json` never shows it. Like the other person checks this
stops mistakes between cooperating tools. It is not a boundary against a
process that means harm: whoever can read the state folder can read the file.

### status

`status --json` has a `leases` array: the active leases of that bench (the
bench's own and those of its sites), each with `scope`, `site`, `holder`,
`note`, `since` and `expires_at`. It is one small file read; without leases it
reads nothing. The JSON is in [the JSON reference](../../json-schema.md#benchbar-lease---json).
The BenchBar app and the Windows tray do not show leases yet.

## Flags, needs and environment

These tables come from the code (`benchbar commands --json`); the sections above explain them.

<!-- generated:cli-commands lease -->
<!-- Generated by scripts/docs-reference.py from the code. Edit the code, then run: python3 -I scripts/docs-reference.py --write -->

| Command | Terminal | `sudo` | Network | Changes things | JSON |
|---|---|---|---|---|---|
| `benchbar lease take\|release\|renew\|list ...` | no | no | no | no | none |
| `benchbar lease take (--bench PATH \| --site NAME) [--for MINUTES] [--note TEXT] [--json]` | no | no | no | yes | stream |
| `benchbar lease release ID [--json]` | no | no | no | yes | stream |
| `benchbar lease renew ID [--for MINUTES] [--json]` | no | no | no | yes | stream |
| `benchbar lease list [--bench PATH] [--json]` | no | no | no | no | document |

Terminal: may ask a question on a terminal. `sudo`: may run `sudo`. Network: may reach the network.
JSON: `document` is one JSON line, `stream` is JSON lines ending in a `done` line.

| Command | Flag | Value | What it does |
|---|---|---|---|
| `lease take` | `--bench` | `PATH` | Lease the whole bench (every site of it). |
| `lease take` | `--site` | `NAME` | Lease one site (global option; the bench is --bench-dir or the default one). |
| `lease take` | `--for` | `MINUTES` | How long, from 1 to 480. Default: 30. |
| `lease take` | `--note` | `TEXT` | Why, for whoever meets the lease: printable ASCII, at most 120 characters. |
| `lease take` | `--json` |  | JSON lines, ending in a done line with the lease and its id. |
| `lease release` | `--json` |  | JSON lines, ending in a done line. |
| `lease renew` | `--for` | `MINUTES` | How long from now, from 1 to 480. |
| `lease renew` | `--json` |  | JSON lines, ending in a done line with the lease. |
| `lease list` | `--bench` | `PATH` | Only the leases of this bench. |
| `lease list` | `--json` |  | One JSON document. |

| Command | Environment variable | What it does |
|---|---|---|
| `lease take` | `BENCHBAR_CALLER` | The holder's name (1 to 40 letters, digits or . _ @ : + -). benchbar mcp sets it per client; without it an agent run is "agent" and a terminal run is the login name. |
<!-- /generated:cli-commands -->
