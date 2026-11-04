---
title: "share and lan-guard"
description: "benchbar share setup, start, code, invite, lock, people, remove, assign, log, open-as, stop and teardown, and benchbar lan-guard: a room on your Wi-Fi where people sign in to a hardened copy of a dev site."
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
  only the gateway on port 8443 (TLS, both sides with a certificate). A
  request that names any other `Host` (DNS rebinding) is refused with
  400 `bad_host` and its connection closed.
- **Sharing fails closed.** Before the gateway starts, and about once a
  minute while it runs, the checks (`share preflight --critical`, a few
  seconds per run) probe the block from this Mac's own LAN address with a
  throwaway listener and a control port. Two failed runs in a row, or a
  gateway that exits, end the share. A share web process that ends is
  started again and checked, with guests seeing a "restarting" page
  meanwhile; the 4th end in a row (a web that stays up 5 minutes starts
  the count again) ends the share.
- **The room code proves membership, not the host's identity.** Anyone who
  has the code can join, with no action from you; you see every join and
  can remove people. On a first join a guest cannot tell your room from a
  rogue one that also knows the code: the guest's pin of your certificate
  protects only rejoins.
- **Ten wrong codes lock the room** until you draw a new code. The code
  never reaches a file, a log, `share status` or any `--json` but
  `share code --json` and `share invite --json`.
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

Making the copy (the first setup, or `--refresh`) restores it as MariaDB's
root user, so it needs the root password: from the Keychain, from
`MARIADB_ROOT_PASSWORD`, or typed at a terminal (setup asks for it before
anything changes, and keeps it in the Keychain). Without a terminal, with
`--yes` or `--json`, and with no password known, setup and its dry run stop
before any change with exit 2, naming `MARIADB_ROOT_PASSWORD`. A MariaDB
root that logs in only over the unix socket, with no password, cannot make
the copy.

A setup that stops halfway (a failed step, or the app quit while it ran)
never leaves the bench's scheduler paused: the pause it set for the restore
is removed on the way out, and the half-made copy keeps a `pause_scheduler`
and `mute_emails` of its own. A pause that was there before setup started
stays. Such a setup leaves no `share.json`: until `share setup --refresh`
finishes it, `share status`, `share start` and a plain `share setup` say
"Sharing setup was interrupted. Run: benchbar share setup --refresh".

Exit codes: 0; 1 on a refusal or a failed step; 2 when the MariaDB root
password is needed and unknown.

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

A start takes about 15 seconds on a 29-app copy: the checks run before
and after the gateway starts (about 2 seconds each), and the copy's web
process is started and warmed with one request before them (1 to 10
seconds, longer for a cold large copy; up to 30 seconds are allowed). A
restart of the web process while sharing takes about 10 seconds, during
which guests see the "restarting" page.

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

## share invite

```
benchbar share invite [--install-url URL] [--json]
```

Prints a ready-to-paste invite for your team channel. Its link carries
the room's name, this Mac's key fingerprint, the code's salt, the code
itself, this Mac's LAN address and gateway port, and the deadline, so
a guest's BenchBar opens the join sheet with everything filled in. The
guest still clicks **Join**. Before the code is sent, the guest's app checks
that the host's key matches the fingerprint in the link and that the salt
is still current.

```
Join my BenchBar room "Lab" (office Wi-Fi, until 17:30)
benchbar://share/join?v=1&r=Lab&h=<64 hex>&s=<32 hex>&c=<6 digits>&a=192.168.1.20%3A8443&x=<unix seconds>
No BenchBar yet? Install: <URL>
Or: open BenchBar → On your network → Paste invite
```

The install line is there only with `--install-url`, which must be one
`http://` or `https://` address with no spaces. `--json` gives
`url`, `text`, `expires_at` (ISO 8601, UTC) and `room`. Every link
value is percent-encoded (a space is `%20`).

**The invite holds the room code.** Anyone who gets the text can join
until sharing ends. Post it only where the people you mean to invite read
it. **New code** (`share code --new`, or `share remove --new-code`) or
**Stop** makes every posted invite stop working: a guest with an old invite is told to ask for a new one, and
does not use up one of the room's ten tries. The app's **Copy invite** puts
the text on the clipboard only when you click it.

It has the same guards as `share code`: refused for agents and scripts,
never logged and never stored. It needs sharing on with the site up, and
says "start sharing first" if it is not. It also needs an IPv4 address on
this Mac's default network.

```bash
benchbar share invite --install-url https://example.com/benchbar
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
so treat it like a password. The link goes to the copy's own web port on
this Mac (`http://share.localhost:PORT/login?...`), not through the
gateway. `--json` never includes the link or the session.

Refused under `BENCHBAR_NONINTERACTIVE`, `--for-agent` and `mcp`, and
without a terminal unless the app passes `BENCHBAR_SUDO=gui`.

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

`setup_interrupted` is true when a setup stopped halfway: there is no
`share.json`, and the one setup set aside or the copy `share.localhost` is
there. Only `share setup --refresh` clears it.

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
anchor and the daemon already match and no bench port answers on the LAN.
When they match but a bench port answers (pf disabled, the anchor flushed),
it loads the anchor and the daemon again with sudo, and fails if a port
still answers. Refused under `BENCHBAR_NONINTERACTIVE`,
`--for-agent` and `mcp`, and without a terminal unless `BENCHBAR_SUDO=gui`.
On a refusal, run the same command yourself in a terminal.

Turning pf on (`pfctl -E`) hands out a token. Install records it in the
state folder (`lan-guard/pf.state`, never the bench), together with whether
pf was already on before the first install, so that `lan-guard remove` can
give it back.

Exit codes: 0; 1 on a refusal, a cancelled password, a failed root step or
a block that still lets a bench port through.

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

It also gives back the pf token that install recorded (`pfctl -X TOKEN`), so
pf is turned off again when the guard was the only thing that turned it on.
When pf was already enabled before the first install, remove leaves pf on.
A token from before a reboot is stale, and releasing it is harmless. The
boot daemon takes a reference of its own at every boot; it ends at the next
reboot, because remove deletes the daemon.

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
