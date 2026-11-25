---
title: "Glossary"
description: "The words BenchBar docs use: bench, site, bench agent, coding agent, port block, plan and token, state folder, room, seat, LAN guard, Lab, profile and more, each in one or two sentences."
---

One name is used for one thing across these docs. Terms are in
alphabetical order.

## bench agent

The background job that keeps one bench running. On macOS it
is a launchd agent. On Linux and in WSL it is a `systemd --user` unit.
See [Benches and sites](guides/benches-and-sites.md).

## app

Two meanings. A Frappe app, such as ERPNext, is code installed
in a bench (see [Apps](guides/apps.md)). BenchBar.app is the menu bar
app for the Mac. In these docs "the app" means BenchBar.app on the Mac,
and "the tray" means the BenchBar tray on Windows.

## bench

The folder that holds one Frappe installation: the Frappe
apps in `apps/`, a Python environment in `env/` and the sites in
`sites/`. `bench` is also the name of Frappe's own tool. `benchbar` is
the command line tool of this project.

## coding agent

An AI tool such as Claude Code or Cursor that works on your machine. It
can read and drive a bench through `benchbar mcp` or the CLI. See
[Coding agents and MCP](guides/agents.md).

## doctor

`benchbar doctor` checks a bench and a machine and changes
nothing. Every failed check names the exact fix. See
[Doctor checks](guides/doctor-and-repair.md).

## frappe-mac

The old name of `benchbar`, up to version 0.2. It
appears only where these docs explain the move to the new name. See
[Troubleshooting](troubleshooting.md#migrating-from-frappe-mac-02-or-older-setups).

## Lab

An experiment that is off until you turn it on. See
[Labs](guides/labs.md).

## LAN guard

The firewall rule that lets a guest reach one shared
site and nothing else on your machine. It is a pf anchor on macOS and an
nftables table on Linux. See
[How sharing keeps your bench safe](concepts/sharing-safety.md).

## launchd

The way macOS runs a program in the background. A launchd
agent is one such program for one user.

## MCP

The Model Context Protocol. `benchbar mcp` lets a coding agent
call BenchBar tools instead of parsing text. See
[Coding agents and MCP](guides/agents.md).

## pf anchor

A named set of rules for pf, the macOS firewall. The LAN
guard uses one.

## plan and token

A command that changes more than one thing can show
its plan first. The plan has a token. You give the token back to apply
exactly that plan, and a stale token is refused.

## port block

The set of ports one bench uses: web, socketio and two
Redis ports. Each bench has its own block. See
[Port blocks](concepts/port-blocks.md).

## profile

A recipe for a new bench: the Frappe version and the apps.
A team profile is shared by the team. See
[Teams](guides/teams.md).

## room

A shared session in which you let a colleague on your network
use one of your sites. See
[Share a site on your network](guides/share-on-your-network.md).

## room code

The code a guest types to join a room. It lets a person
into the room and no further.

## runner

The small animation the Mac app draws in the menu bar for a
bench. See [Runners](runners.md).

## seat

One Frappe user of the shared site that a guest may use. You
give a guest a seat.

## site

One Frappe instance in a bench, with its own database and its
own address, such as `http://macdev:8000`.

## state folder

Where `benchbar` keeps its logs, backups and the list
of remembered benches. For Homebrew and the one line installer on a Mac it
is `~/.local/state/benchbar`. On Linux it is `$XDG_STATE_HOME/benchbar` when that variable is set, else the same `~/.local/state/benchbar`. In a
git checkout it is the `.benchbar/` folder of the checkout.

## systemd

The way most Linux systems run programs in the background.
`systemd --user` runs them for one user.

## WSL

The Windows Subsystem for Linux. BenchBar for Windows runs your
benches in an Ubuntu distro under WSL. See [Windows](windows.md).
