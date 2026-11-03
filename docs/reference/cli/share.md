---
title: "share and lan-guard"
description: "benchbar share setup, start, code, lock, people, remove, assign, log, open-as, stop and teardown, and benchbar lan-guard: a room on your Wi-Fi where people sign in to a hardened copy of a dev site."
---

Sharing opens a **room** on this Mac's network. People on the same Wi-Fi
join it with a 6 digit **room code**, take a **seat** (one of the Frappe
users you chose) and use a hardened **copy** of one of your dev sites in
their own browser. macOS only. Every command takes the
[options for every command](install.md#options-for-every-command).
The documents are in the [JSON schema](../../json-schema.md#sharing).

## The safety model in plain words

- **Only the copy is shared, never the site.** `share setup` restores a
  backup of the site into `share.localhost` and hardens it. Your site,
  its database and its files are not reachable from the network.
- **The bench's ports stay on this Mac.** The LAN guard (a pf anchor,
  below) refuses web 8000-8099, socket.io 9000-9099, Redis 11000-11099
  and 13000-13099 and MariaDB 3306 to anything but this Mac. Guests reach
  only the gateway on port 8443 (TLS, both sides with a certificate).
- **Sharing fails closed.** Before the gateway starts, and every few
  seconds while it runs, the checks (`share preflight --critical`) probe
  the block from this Mac's own LAN address with a throwaway listener and
  a control port. A failed check, or a gateway that exits, ends the share.
- **The room code proves membership, not the host's identity.** Anyone who
  has the code can join, with no action from you; you see every join and
  can remove people. On a first join a guest cannot tell your room from a
  rogue one that also knows the code: the guest's pin of your certificate
  protects only rejoins.
- **Ten wrong codes lock the room** until you draw a new code. The code
  never reaches a file, a log, `share status` or any `--json` but
  `share code --json`.
- **The copy holds real data** (people, customers, contacts, addresses).
  `share setup` stops until you pass `--acknowledge-data`.
- **No live updates for guests.** `/socket.io` answers 404 through the
  gateway, so pages do not refresh by themselves; guests reload.
- Sharing ends at its deadline (4 hours by default, at most 12 hours from
  the start) and when you stop it. Every session of the copy ends with it.

## What guests can see

The pages of the copy that their seat's user can open, and the room's
roster (`In this room`: each person's name, Mac model, seat and whether
they are online). Not your site, not other benches, not the code. Before
they join, a guest sees only the room's label, your Mac's name, the site's
name and the people and seat counts.

## What the copy holds, and what is taken out

The copy is your site's database and files at the backup you choose. In the
copy only:

- the seat users lose every role that can run code or change settings
  (`share users` lists them per user); Website Users are never seats;
- every other user is disabled, and Administrator's password is replaced
  by a random one nobody is told;
- developer mode, server scripts, sign-up and API keys are off; outgoing
  mail is muted; Portal Settings' default role is cleared;
- the copy and its backups are excluded from Time Machine.

## The sudo steps

macOS asks for your password (or shows its own dialog when the BenchBar app
runs the command) only for `lan-guard install`, `lan-guard remove` and
`lan-guard allow-node`. Nothing else in sharing runs as root.

## share setup

```
benchbar share setup [--site S] [--from STAMP|latest] [--backup-now] [--users A,B] [--name LABEL]
                     [--refresh] [--regenerate-identity] [--acknowledge-data] [--dry-run] [--yes] [--json]
```

Makes the copy, hardens it and creates the host identity (key and
certificate). `--users` picks the seats (enabled System Users).
`--refresh` replaces an existing copy (backed up first); it is needed to
change the seats. Refused under `BENCHBAR_NONINTERACTIVE`, `--for-agent`
and `mcp`, and without a terminal unless the app passes `BENCHBAR_SUDO=gui`.

Exit codes: 0; 1 on a refusal or a failed step.

```bash
benchbar share setup --site mysite.localhost --users priya@example.com,mgr@example.com --acknowledge-data
```

## share users

```
benchbar share users [--site S] [--json]
```

The users who can take a seat, and the roles each would lose in the copy.
Reads only.

```bash
benchbar share users --site mysite.localhost
```

## share preflight

```
benchbar share preflight [--static|--critical] [--quiet] [--json]
```

The checks, each with a status, a message and a `fix_action`. `--static`:
what is checked before anything starts (the copy, its seats, node, the
firewall). `--critical`: what a running share repeats (the pf block probed
from the LAN address, the share web process, the bench's Redis).

Exit codes: 0 when every check passes; 1 when one fails.

```bash
benchbar share preflight --critical
```

## share start

```
benchbar share start [--for DUR] [--name LABEL] [--dry-run] [--json]
```

Starts the room until the deadline (`--for 30m`, `4h`; 5 minutes to 12
hours; 4 hours by default). The bench must be running. Refused like
`share setup`. A second start says "unchanged".

```bash
benchbar share start --for 2h
```

## share code

```
benchbar share code [--new] [--json]
```

Prints the room code on the terminal, for you to read out. `--new` draws a
new one: the failure budget resets, people already in the room stay, and a
code already handed out stops working. `--json` is the app's read: the one
document that carries the code. Never logged and never stored.

Refused under `BENCHBAR_NONINTERACTIVE`, `--for-agent` and `mcp`, and
without a terminal unless the app passes `BENCHBAR_SUDO=gui`, so a script,
a cron job or an agent's shell never reads the code.

```bash
benchbar share code --new
```

## share lock and share unlock

```
benchbar share lock [--json]
benchbar share unlock [--json]
```

Lock: nobody new can join. The room also locks itself while every seat is
taken. Unlock lifts your lock; a lock after 10 wrong codes stays until
`share code --new`.

```bash
benchbar share lock
```

## share people

```
benchbar share people [--json]
```

The people in the room: id (`d_` and 8 hex digits), name, Mac model,
address, seat, online, joined, last seen. `share devices` is another name
for it.

```bash
benchbar share people
```

## share remove

```
benchbar share remove ID [--new-code] [--yes] [--json]
```

Removes a person: their Mac is blocked for the rest of this room and their
seat's sessions end. Asks first. `--new-code` also draws a new code, for
when you do not know who it was: a fresh Mac could join again with the old
one. `share revoke` is another name for it.

```bash
benchbar share remove d_0123abcd --new-code
```

## share assign

```
benchbar share assign ID SEAT_ID [--json]
```

Moves a person to another free seat; the old seat's sessions end first.

```bash
benchbar share assign d_0123abcd s_0a1b2c3d
```

## share log

```
benchbar share log [--device ID] [--since TIME] [--limit N] [--json]
```

What people in the room opened in the last 14 days: time, Mac, seat,
method, the first two path segments (never a document name) and the
status. 200 entries by default, at most 5000.

```bash
benchbar share log --device d_0123abcd --since 09:00:00
```

## share open-as

```
benchbar share open-as USER [--print-url] [--json]
```

Opens the copy in this Mac's browser signed in as a seat, the way
`open --as` does (the copy is opted in to Open as by `share setup`).
`--print-url` prints the sign-in link instead: it carries the session id,
so treat it like a password. `--json` never includes the link or the
session.

```bash
benchbar share open-as priya@example.com
```

## share status

```
benchbar share status [--preflight] [--json]
```

`on`, `off`, `expired` or `error`, the time left, the copy, the room's
counts (`seats`, `people`, `locked`, `budget_left`, `join_trouble`) and the
LAN guard's state. Never the code. `--preflight` adds the critical checks.

`wipe_failed` counts a sign-out that is owed or failed. While sharing is
off it reads 1 or more from the marker `share stop` leaves when it could
not end every session of the copy (the next room command retries it while
the bench's Redis answers). It also reads 1 for a moment after every
`share remove`, until the gateway has ended that seat's sessions.

```bash
benchbar share status --json
```

## share extend

```
benchbar share extend --by DUR [--json]
```

Moves the deadline, up to 12 hours from the start.

```bash
benchbar share extend --by 1h
```

## share stop

```
benchbar share stop [--json]
```

Ends the room: the gateway and the job stop, the room empties and every
session of the copy ends. Never refused, no dry run.

```bash
benchbar share stop
```

## share teardown

```
benchbar share teardown [--yes] [--json]
```

Stops sharing, drops the copy (backed up first) and deletes the share
folder with the host identity and the room. Asks first. The archived copy
keeps its Time Machine exclusion.

```bash
benchbar share teardown --yes
```

## lan-guard install

```
benchbar lan-guard install [--dry-run] [--yes] [--json]
```

Writes the pf anchor `/etc/pf.anchors/com.benchbar.lan` (loaded as
`com.apple/250.benchbar`) and the launch daemon
`/Library/LaunchDaemons/com.benchbar.pf.plist` that loads it at every boot,
with sudo once, then probes the block from the LAN address. Says
"unchanged: the guard is installed and matches", with no sudo, when the
anchor's rules already match. Refused under `BENCHBAR_NONINTERACTIVE`,
`--for-agent` and `mcp`, and without a terminal unless `BENCHBAR_SUDO=gui`.
On a refusal, run the same command yourself in a terminal.

Exit codes: 0; 1 on a refusal, a cancelled password or a failed root step.

```bash
benchbar lan-guard install --dry-run
```

## lan-guard status

```
benchbar lan-guard status [--json]
```

`installed`, `missing` or `outdated`, and `active`: whether the bench ports
are refused on this Mac's LAN address (null with no LAN address). Reads
only; never refused.

```bash
benchbar lan-guard status --json
```

## lan-guard remove

```
benchbar lan-guard remove [--yes] [--json]
```

Unloads and deletes the anchor and its daemon, with sudo once. Asks first.
Without them the bench ports answer the LAN and `share start` refuses to
run.

```bash
benchbar lan-guard remove
```

## lan-guard allow-node

```
benchbar lan-guard allow-node [--yes] [--json]
```

Adds the realpath of the node the gateway runs on to the macOS firewall's
allowed apps, with sudo once. "Unchanged" when the firewall is off or
already allows it. A Homebrew upgrade of node changes the realpath, so the
`firewall_node` check asks for it again.

```bash
benchbar lan-guard allow-node
```
