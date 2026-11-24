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
  can remove people. The code does not grant a seat: you give out the
  seats (`share assign`, **Give a Seat** in the apps), and a guest cannot
  take or change one. Only a room started with `--open-seats` works as in
  0.8, where whoever has the code can take any free seat, the most
  privileged one included. On a first join a guest cannot tell your room from a
  rogue one that also knows the code: the guest's pin of your certificate
  protects only rejoins. A guest who joins from an invite link can check:
  their join sheet shows 16 digits of the host's key, and yours are on the
  Sharing tab and in `share status` ("Host key") for you to read out.
- **A device on the network can slow joins down, not hold them off in
  silence.** The gateway keeps 16 connections for devices that are not in
  the room yet, 4 per address. Such a connection must send a request
  within 10 seconds and is closed 60 seconds after it opened at the
  latest, so a device that only holds connections open loses them. A
  device that keeps opening new ones can still crowd new guests out, as
  it could by flooding the Wi-Fi itself: `share status` then shows
  `join_trouble`. People already in the room are not affected.
- **Uploaded files cannot act as pages of the copy.** A file under
  `/files` or `/private/files` whose type a browser could run (HTML, SVG,
  XML, anything unknown) reaches a guest as a download, with a sandbox
  policy on it. Images, PDFs, text, audio and video show as before.
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
they join, a guest sees only the room's label, your Mac's name and the
people and seat counts. Every device on the network can read those, so the
name of the site you copied is not among them: a person learns it once
they are in the room.

## What the host sees of a guest

The name the guest's Mac gives, its model, its address, and the key their
BenchBar made for rooms. That key is the same for every room a Mac is in,
so a host can tell that the same Mac joined before, also under another
name. The key is deleted when the guest forgets their last room
(**Forget** in **Your rooms**); the next join makes a new one. The join
itself derives the room code's key material in arithmetic that is not
constant time. That matters only to a program already running on the
guest's own Mac, which can read the code on the screen anyway.

An invite link names the host's address only as a hint. BenchBar dials it
only when it is an address of a local network (10.x, 172.16 to 172.31,
192.168.x, 169.254.x or 100.64 to 100.127); a link that names any other
address finds its room by Bonjour or not at all.

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
