---
title: "How sharing keeps your bench safe"
description: "What a room on your Wi-Fi shares, what it never shares, and the checks that end a share when a protection fails."
---

A room is an experiment (a [Lab](../reference/cli/labs.md)). This page
explains the safety model behind it. For the steps, see the
[share and lan-guard reference](../reference/cli/share.md) and
[Share on your network](../app.md#share-on-your-network) in the app.

## The safety model in plain words

- **Only the copy is shared, never the site.** `share setup` restores a
  backup of the site into `share.localhost` and hardens it. Your site,
  its database and its files are not reachable from the network.
- **The bench's ports stay on this computer.** The LAN guard (a pf anchor on macOS, an nftables table on Linux, see
  [lan-guard](../reference/cli/share.md#lan-guard-install)) refuses web 8000-8099, socket.io 9000-9099, Redis 11000-11099
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
- **Ten wrong codes lock the room** until you draw a new code. The count is
  for the room, not per guest, so anyone on the network who can reach the
  gateway can lock everyone out by guessing wrong ten times. The lock holds
  until `share code --new`; nobody gets in or back in meanwhile. The code
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
