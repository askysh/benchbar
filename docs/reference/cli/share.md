---
title: "share and lan-guard"
description: "benchbar share setup, start, code, invite, lock, people, remove, assign, log, open-as, stop and teardown, and benchbar lan-guard: a room on your Wi-Fi where people sign in to a hardened copy of a dev site."
---

**share is an experiment: run `benchbar labs on lan-rooms` first.** While the lab is off, `share` and `lan-guard` are hidden from `--help` and `commands --json` (listed under `gated`) and exit 2 with that hint. The commands that stop, remove or report what the lab started still run while it is off: `share stop`, `share status`, `share teardown`, `lan-guard status` and `lan-guard remove`. `benchbar labs off lan-rooms` stops a running share and, if lan-guard is installed or `lan-guard allow-node` put node on the macOS firewall's list, warns with `run: benchbar lan-guard remove` (it never uses sudo itself).

Sharing opens a **room** on this computer's network. People on the same Wi-Fi
join it with a 6 digit **room code**, take a **seat** (one of the Frappe
users you chose) and use a hardened **copy** of one of your dev sites in
their own browser. It runs on macOS and, since 0.9.0, on Linux (see [Sharing on Linux](#sharing-on-linux));
the Mac app is macOS only. Every command takes the
[options for every command](install.md#options-for-every-command).
The documents are in the [JSON schema](../../json-schema.md#sharing).

## Sharing on Linux

The same commands, with the macOS parts swapped:

| What | macOS | Linux |
| --- | --- | --- |
| The LAN guard | a pf anchor and a launch daemon | an nftables table and a systemd unit ([lan-guard install on Linux](#lan-guard-install-on-linux)) |
| The sharing job | a launchd job | a `systemd --user` unit, `benchbar-share-gateway.service`, written into `$XDG_RUNTIME_DIR/systemd/user` and deleted when the share ends; it is never enabled, so a logout or a reboot ends it, and it is not in `~/.config/systemd/user` where the bench's unit is |
| Listing on the network | Bonjour (`dns-sd`) | `avahi-publish` when it is installed (`sudo apt install avahi-utils`); without it the room is not listed, `share start` says so, and people join with the address and the code |
| Keeping the computer awake | `caffeinate` | nothing yet: a laptop that suspends ends the room's reachability until it wakes |
| Naming the owner of the web port | `lsof` | `ss` |
| The firewall for node | `lan-guard allow-node` | none; with ufw on, `sudo ufw allow 8443/tcp` for the room's port |
| The room's label | the Mac's ComputerName | the host name |

`share start` needs a user session with a systemd user manager (the folder `$XDG_RUNTIME_DIR` exists):
over SSH without a login session, or in a WSL distro without systemd, it stops and says so. In WSL the
default NAT network is not the office Wi-Fi: its address belongs to the Windows PC, so nobody on the Wi-Fi
can reach a room there. A room is not available on WSL NAT: `share preflight`, `share start` and
`share invite` read `wslinfo --networking-mode` (a WSL without `wslinfo` counts as NAT) and refuse, naming
the fix. With mirrored networking (`networkingMode=mirrored` under `[wsl2]` in `%UserProfile%\.wslconfig`,
then `wsl.exe --shutdown` in Windows) the room has the PC's own Wi-Fi address, and `share preflight` and
`share start` warn that Windows still blocks inbound connections to WSL until the Hyper-V firewall allows
the room's port. Run this once in a PowerShell opened as administrator:

```powershell
New-NetFirewallHyperVRule -Name BenchBarRoom -DisplayName "BenchBar room" -Direction Inbound -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Protocol TCP -LocalPorts 8443
```

See [Windows](../../windows.md#rooms-on-windows) and Microsoft's
[mirrored mode networking](https://learn.microsoft.com/windows/wsl/networking#mirrored-mode-networking).

## The safety model

The safety model, what guests can see, what the copy holds and the sudo
steps are in [How sharing keeps your bench safe](../../concepts/sharing-safety.md).

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

The hardening of the copy runs the same neutralisation as
[`benchbar pull`](pull.md#what-the-copy-loses): every stored password,
token and queued mail is gone, and webhooks, email accounts, notifications,
social logins, backup uploads, LDAP, SMS, payment keys and jobs that call
out are off, so a room never reaches the real services (a single list in one
file, so the two cannot differ). Since 0.9 that list also covers LDAP, SMS,
Google, Dropbox, S3 and payment settings, which the older hardening left on.

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
firewall; on WSL, the networking mode: `wsl_networking` fails on NAT and warns on mirrored). `--critical`: what a running share repeats (the pf block probed
from the LAN address, the share web process, the bench's Redis).

Exit codes: 0 when every check passes; 1 when one fails.

```bash
benchbar share preflight --critical
```

## share start

```
benchbar share start [--for DUR] [--name LABEL] [--open-seats] [--dry-run] [--json]
```

Starts the room until the deadline (`--for 30m`, `4h`; 5 minutes to 12
hours; 4 hours by default). The bench must be running. Refused like
`share setup`. A second start says "unchanged".

**Who gives a person their seat.** You do. The room code lets a person
into the room and no further: a person who joins has no seat and sees
nothing of the copy until you run [`share assign`](#share-assign) for
them. They cannot take a seat or change to another one themselves.
[`share people`](#share-people) lists who waits and which seats are free,
and the start says that guests wait for you. A person keeps their place
for 10 minutes while they wait. When the room is full, the next person who
joins takes the place of whoever has waited longest, if that is more than
2 minutes; [`share remove`](#share-remove) puts out somebody you do not
know.

`--open-seats` starts the room of 0.8: the code also lets a person take
any free seat, the most privileged one included, with no action from you
(and a person without a seat keeps their place for 2 minutes). Use it only
when everybody who has the code may use every seat. `--assign-seats` names
the default and is not needed; the two do not go together. On WSL with NAT networking it
is refused before anything is written, even with `--dry-run`; with mirrored
networking it warns what the Hyper-V firewall needs (see
[Sharing on Linux](#sharing-on-linux)).

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
the room's name, this computer's key fingerprint, the code's salt, the code
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
for it. When someone in the room has no seat, the free seats follow with
their ids (`s_` and 8 hex digits), ready for `share assign`. `--json` always
carries `seats`, every seat of the room with its roles and who holds it,
and `seat_mode` (`host` or `open`).

```bash
benchbar share people
```

## share remove

```
benchbar share remove ID [--new-code] [--yes] [--json]
```

Removes a person: their seat's sessions end and their Mac cannot join
again with the code it used. Drawing a new code (`share code --new`, the
app's **Copy new invite**) lifts every removal, so to let someone back in,
send them the new invite; the people still in the room stay. Asks first.
`--new-code` also draws a new code, for when you do not know who it was: a
fresh Mac could join again with the old one. `share revoke` is another name
for it.

```bash
benchbar share remove d_0123abcd --new-code
```

## share assign

```
benchbar share assign ID SEAT_ID [--json]
```

Gives a person a free seat, or moves them to another one; the old seat's
sessions end first. This is the only way a person gets or changes a seat,
unless the room was started with `--open-seats`. `share people` shows the ids of
the people and of the free seats.

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

The log is a file per day in the share folder. It names a seat by its id,
never by the e-mail address of the seat's user; `share log` shows the
seat's name. A day's file stops at 16 MB (its last line is
`/_benchbar/log-full`). Files older than 14 days are deleted when a share
starts, when it ends and when `share log` reads them; `share teardown`
deletes all of them.

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

Moves the deadline, up to 12 hours from the start. People in the room stay
signed in: the browser's cookie has no end date of its own, and every
session of the copy ends when the share does.

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

**Where the gateway listens.** The gateway listens on this Mac's address on
the network the room is on (the default route's interface, the one `share
preflight` reports as `lan_ip`), not on every interface. A VPN, a phone
hotspot or an Ethernet port with its own address does not see port 8443. The
room works as long as that address stays: when the Mac joins another network or
gets a new address, the watchdog ends the room with "this Mac's network
address changed" and you start it again. The bench's own web server and the
share's web process listen on 127.0.0.1, which is where the gateway reaches
them.

**What lan-guard blocks.** The rule is global and always on, with or without
a room open: TCP to ports 8000-8099 (web), 9000-9099 (socket.io),
11000-11099 and 13000-13099 (Redis) and 3306 (MariaDB) is refused unless it
comes from this Mac's loopback address. Anything that reaches those ports
through this Mac's LAN address is refused too, which includes a Docker
container or a VM that dials the LAN IP instead of the loopback one. Use
127.0.0.1 where the tool allows it, or run `benchbar lan-guard remove` for as
long as you need the LAN path (`share start` refuses to run without the
guard, so install it again before you share). `lan-guard allow-node` is not
a way around the block: it only lets the gateway's node through the macOS
application firewall and opens no bench port.

Exit codes: 0; 1 on a refusal, a cancelled password, a failed root step or
a block that still lets a bench port through.

```bash
benchbar lan-guard install --dry-run
```

### lan-guard install on Linux

The same command, with nftables in place of pf and systemd in place of
launchd. It writes the rules file `/etc/benchbar/lan-guard.nft` (one table,
`inet benchbar`, with one input chain at priority -10 and a policy of
accept) and the unit `/etc/systemd/system/benchbar-lan-guard.service`, then
enables the unit and starts it again. The unit loads the table at every boot
and deletes it when it stops. Only the bench ports are touched, from the
same list and for the same reason as on macOS: TCP to them is refused with a
reset unless it comes from loopback, and this machine's own LAN address
counts as not loopback, which is how `status` proves the rule works.

It needs `nft` (`sudo apt install nftables`) and systemd as the init (in WSL,
`systemd=true` in `/etc/wsl.conf`); without them it stops before it asks for
sudo and changes nothing. The root step names the system tools by absolute
path and carries both files as literals, as on macOS. `BENCHBAR_SUDO=gui` is
the Mac's dialog and does nothing on Linux. From the Windows tray the
password comes in `BENCHBAR_SUDO=env`.

**ufw and firewalld.** The guard does not change them. A host that runs ufw
refuses incoming ports it was not told to allow, and the guard adds to that:
both can refuse, neither accepts for the other. A room's port (8443) then
needs a rule of your own, `sudo ufw allow 8443/tcp`; `install` and `status`
say so when ufw is active. A service that flushes the whole ruleset
(`nftables.service` reloading `/etc/nftables.conf`, which starts with `flush
ruleset`) takes the table away: `status` then shows `active: false` and
`install` loads it again. A published Docker port is forwarded, not
delivered to this machine, and is outside what the input chain sees.

`lan-guard allow-node` is macOS only: it changes the macOS application
firewall, and Linux has no such list. On Linux it says so and changes
nothing.

## lan-guard status

```
benchbar lan-guard status [--json]
```

`installed`, `missing` or `outdated`, and `active`: whether the bench ports
are refused on this machine's LAN address (null with no LAN address, or when
the probe could not run: it needs the bench's Node). `anchor` is the pf
anchor on macOS and `inet benchbar` on Linux. Reads only; never refused.

```bash
benchbar lan-guard status --json
```

## lan-guard remove

```
benchbar lan-guard remove [--yes] [--json]
```

Unloads and deletes the anchor and its daemon, with sudo once. Asks first.
Without them the bench ports answer the LAN and `share start` refuses to
run. On Linux it stops and disables the unit, deletes the table `inet
benchbar` (no other table, chain or rule), and removes the unit, the rules
file and their folder.

It also gives back the pf token that install recorded (`pfctl -X TOKEN`), so
pf is turned off again when the guard was the only thing that turned it on.
When pf was already enabled before the first install, remove leaves pf on.
If an install failed after it turned pf on and its two files are gone
since, the guard reads "not installed" but the reference is still held:
remove asks for your password and gives it back.
A token from before a reboot is stale, and releasing it is harmless. The
boot daemon takes a reference of its own at every boot; it ends at the next
reboot, because remove deletes the daemon.

On macOS it also takes out of the firewall's allowed apps every node that
`lan-guard allow-node` added (`socketfilterfw --remove PATH`), in the same
root step, so one password covers both. It does so too when the guard itself
is not installed. An entry that you made yourself in System Settings, or
that a BenchBar before 0.9.0 added (it kept no record), is left alone: when
the firewall is on and still allows the gateway's node, remove prints the
command that takes the entry out.

`lan-guard remove` runs while the `lan-rooms` Lab is off, so the Lab can
always be undone.

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
`firewall_node` check asks for it again; that run also takes the entry of
the older node out.

The firewall keeps its list by program. The entry lets every script that
this node runs accept incoming connections, on every network, not only the
gateway of a room: a dev server on another port is then reachable without
the firewall's own question. The command says so before it asks.
BenchBar records the path it added (`lan-guard/firewall.allowed` in its
state folder), and `benchbar lan-guard remove` takes the entry out again.

```bash
benchbar lan-guard allow-node
```

## Flags, needs and environment

These tables come from the code (`benchbar commands --json`); the sections above explain them.

<!-- generated:cli-commands share lan-guard -->
<!-- Generated by scripts/docs-reference.py from the code. Edit the code, then run: python3 -I scripts/docs-reference.py --write -->

| Command | Terminal | `sudo` | Network | Changes things | JSON |
|---|---|---|---|---|---|
| `benchbar share setup\|users\|preflight\|start\|stop\|extend\|status\|code\|invite\|lock\|unlock\|people\|remove\|assign\|log\|open-as\|teardown ...` (Lab `lan-rooms`) | no | no | no | no | none |
| `benchbar share setup [--site S] [--from STAMP\|latest] [--backup-now] [--users A,B] [--name LABEL] [--refresh] [--regenerate-identity] [--acknowledge-data] [--dry-run] [--yes] [--json]` (Lab `lan-rooms`) | yes | no | no | yes | stream |
| `benchbar share users [--site S] [--json]` (Lab `lan-rooms`) | no | no | no | no | document |
| `benchbar share preflight [--static\|--critical] [--quiet] [--json]` (Lab `lan-rooms`) | no | no | no | no | document |
| `benchbar share start [--for DUR] [--name LABEL] [--open-seats] [--dry-run] [--json]` (Lab `lan-rooms`) | yes | no | no | yes | stream |
| `benchbar share stop [--json]` (Lab `lan-rooms`) | no | no | no | yes | stream |
| `benchbar share extend --by DUR [--json]` (Lab `lan-rooms`) | no | no | no | yes | stream |
| `benchbar share status [--preflight] [--json]` (Lab `lan-rooms`) | no | no | no | no | document |
| `benchbar share code [--new] [--json]` (Lab `lan-rooms`) | no | no | no | no | document |
| `benchbar share invite [--install-url URL] [--json]` (Lab `lan-rooms`) | no | no | no | no | document |
| `benchbar share lock [--json]` (Lab `lan-rooms`) | no | no | no | yes | stream |
| `benchbar share unlock [--json]` (Lab `lan-rooms`) | no | no | no | yes | stream |
| `benchbar share people [--json]` (Lab `lan-rooms`) | no | no | no | no | document |
| `benchbar share devices [--json]` (Lab `lan-rooms`) | no | no | no | no | document |
| `benchbar share remove ID [--new-code] [--yes] [--json]` (Lab `lan-rooms`) | yes | no | no | yes | stream |
| `benchbar share revoke ID [--new-code] [--yes] [--json]` (Lab `lan-rooms`) | yes | no | no | yes | stream |
| `benchbar share assign ID SEAT_ID [--json]` (Lab `lan-rooms`) | no | no | no | yes | stream |
| `benchbar share log [--device ID] [--since TIME] [--limit N] [--json]` (Lab `lan-rooms`) | no | no | no | no | document |
| `benchbar share open-as USER [--print-url] [--json]` (Lab `lan-rooms`) | yes | no | no | yes | document |
| `benchbar share teardown [--yes] [--json]` (Lab `lan-rooms`) | yes | no | no | yes | stream |
| `benchbar lan-guard install\|status\|remove\|allow-node ...` (Lab `lan-rooms`) | yes | yes | no | yes | stream |
| `benchbar lan-guard install [--dry-run] [--yes] [--json]` (Lab `lan-rooms`) | yes | yes | no | yes | stream |
| `benchbar lan-guard status [--json]` (Lab `lan-rooms`) | no | no | no | no | document |
| `benchbar lan-guard remove [--yes] [--json]` (Lab `lan-rooms`) | yes | yes | no | yes | stream |
| `benchbar lan-guard allow-node [--yes] [--json]` (Lab `lan-rooms`) | yes | yes | no | yes | stream |

Terminal: may ask a question on a terminal. `sudo`: may run `sudo`. Network: may reach the network.
JSON: `document` is one JSON line, `stream` is JSON lines ending in a `done` line.

| Command | Flag | Value | What it does |
|---|---|---|---|
| `share setup` | `--users` | `A,B` | The Frappe users who may sign in to the copy, one seat each. They must be enabled System Users; each loses the roles that can run code or change settings, in the copy only. Default: the last setup's. |
| `share setup` | `--from` | `STAMP\|latest` | The backup set of the site to copy (benchbar site backups S lists them). Default: the newest complete one. |
| `share setup` | `--backup-now` |  | Take a backup of the site first (benchbar site backup S) and copy that. |
| `share setup` | `--name` | `LABEL` | The room's label, at most 40 printable characters. Default: "&lt;your name&gt;'s room". |
| `share setup` | `--refresh` |  | Replace the existing copy (it is backed up first). Anything guests changed in it is lost; needed to change --users. |
| `share setup` | `--regenerate-identity` |  | Replace the host's key and certificate and empty the paired Macs: every pairing becomes invalid. Asks first (--yes). |
| `share setup` | `--acknowledge-data` |  | Agree that the copy holds the site's real data (people, customers, contacts, addresses). Without it setup stops before any change, naming what the copy holds. |
| `share setup` | `--dry-run` |  | Print the plan (size, time, the data the copy holds) and change nothing. |
| `share setup` | `--yes` |  | Do not ask before replacing the copy or the identity. |
| `share setup` | `--json` |  | JSON lines: plan, steps, done. |
| `share preflight` | `--static` |  | Only the checks that run before anything starts: the copy, its seats, node, the firewall. |
| `share preflight` | `--critical` |  | Only the fast checks a running share repeats: the pf block (probed from this Mac's LAN address with its own listener and a control), the share web process, the bench's Redis. |
| `share preflight` | `--quiet` |  | List only the checks that are not ok. |
| `share preflight` | `--json` |  | One document: protocol, ok, lan_ip and the checks, each with a status, a message and a fix_action. |
| `share start` | `--for` | `DUR` | How long the share runs: 30m, 4h; from 5 minutes to 12 hours. Default: 4h. |
| `share start` | `--name` | `LABEL` | The room's label for this share, at most 40 printable characters. Default: the one share setup recorded. |
| `share start` | `--open-seats` |  | Guests take a free seat themselves, as before 0.9.0: anyone with the room code takes any free seat, the most privileged one included. Without it you give out the seats: a person who joins waits (up to 10 minutes) until you run benchbar share assign for them, and cannot take or change a seat themselves. |
| `share start` | `--assign-seats` |  | The default, said out loud: you give out the seats. Not with --open-seats. |
| `share start` | `--dry-run` |  | Print the plan and start nothing. |
| `share start` | `--json` |  | JSON lines: plan, steps, done (with the deadline). |
| `share stop` | `--json` |  | JSON lines: steps, done. |
| `share extend` | `--by` | `DUR` | How much later: 30m, 1h; from 5 minutes to 12 hours. |
| `share extend` | `--json` |  | JSON lines: done, with the new deadline. |
| `share status` | `--preflight` |  | Run the critical checks too and add them, each with its fix_action. |
| `share status` | `--json` |  | One document (never the room code). |
| `share code` | `--new` |  | Draw a new code first: the failure budget resets, the people in the room stay, a code already handed out stops working. |
| `share code` | `--json` |  | One document with the code: never logged, never stored. |
| `share invite` | `--install-url` | `URL` | Where people download BenchBar, added to the invite text; one http:// or https:// address. |
| `share invite` | `--json` |  | One document with the invite text and its link: the code is in it, never logged, never stored. |
| `share lock` | `--json` |  | JSON lines: done, with locked and lock_reason. |
| `share unlock` | `--json` |  | JSON lines: done, with locked and lock_reason. |
| `share people` | `--json` |  | One document: state; people, each with id, name, model, ip, seat_id, seat_full_name, online, joined, last_seen; seats, every seat of the room with seat_id, full_name, roles, held_by and held_by_name (null for a free seat); seat_mode (host or open). |
| `share devices` | `--json` |  | As share people --json. |
| `share remove` | `--new-code` |  | Also draw a new room code, for when the person is not known: a fresh Mac could join again with the old one. The new code also lets the removed Mac back, if they get it. |
| `share remove` | `--yes` |  | Do not ask first. |
| `share remove` | `--json` |  | JSON lines: done, with removed, new_code and the wipe. |
| `share revoke` | `--new-code` |  | As share remove --new-code. |
| `share revoke` | `--yes` |  | Do not ask first. |
| `share revoke` | `--json` |  | As share remove --json. |
| `share assign` | `--json` |  | JSON lines: done, with the device and its new seat. |
| `share log` | `--device` | `ID` | Only this Mac (an id of share people). |
| `share log` | `--since` | `TIME` | Only entries at or after it: ISO 8601, YYYY-MM-DD HH:MM:SS, a date, or HH:MM:SS today. |
| `share log` | `--limit` | `N` | The newest N entries, 1 to 5000. Default: 200. |
| `share log` | `--json` |  | One document: entries (ts, device, user, method, path, status) and truncated. user is the seat's name (the seat's id when the room no longer has the seat), never an e-mail address but in a line written by 0.8.3. |
| `share open-as` | `--print-url` |  | Print the sign-in link instead of opening it; it holds the session. |
| `share open-as` | `--json` |  | One document without the link (never the session). |
| `share teardown` | `--yes` |  | Do not ask first. |
| `share teardown` | `--json` |  | JSON lines: steps, done with copy_dropped, archived_path and state_removed. |
| `lan-guard install` | `--dry-run` |  | Print what would be written and run, with no sudo. |
| `lan-guard install` | `--yes` |  | Do not ask first (sudo still asks for the password). |
| `lan-guard install` | `--json` |  | JSON lines: done, with state, active, ports, anchor and lan_ip. |
| `lan-guard status` | `--json` |  | One document: state, active (null with no LAN address), ports, anchor, lan_ip. |
| `lan-guard remove` | `--yes` |  | Do not ask first. |
| `lan-guard remove` | `--json` |  | JSON lines: done, with the guard's state. |
| `lan-guard allow-node` | `--yes` |  | Do not ask first. |
| `lan-guard allow-node` | `--json` |  | JSON lines: done, with node (the realpath). |

| Command | Environment variable | What it does |
|---|---|---|
| `share setup` | `MARIADB_ROOT_PASSWORD` | Making the copy restores it as MariaDB's root user: the password from the Keychain, this variable, or typed at a terminal. With none of them, setup and its dry run exit 2 before any change. |
<!-- /generated:cli-commands -->
