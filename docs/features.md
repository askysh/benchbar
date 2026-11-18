---
title: "Features"
description: "Every BenchBar feature by surface: the command line tool on macOS and Linux, the Mac app, BenchBar for Windows and the MCP server. Each has a platform, the version it came in and a link."
---

This page lists every feature once, grouped by where you use it. Each row
gives the version that added it and a link. The same feature can show up
on more than one surface, for example a site backup in the CLI and in the
Mac app.

**Labs** are experiments. A Lab is off until you turn it on, and it can
change or go away. They are marked **Lab** below. Turn one on with
`benchbar labs on NAME` or in **Settings > Labs** in the Mac app. See
[labs](reference/cli/labs.md).

Terms: a *bench* is one Frappe installation folder. A *site* is one
database and domain on a bench. *Platform* names the systems where the
feature works.

## Command line tool

The `benchbar` command runs on macOS, and on Ubuntu 24.04 (Linux and
WSL). A row says "macOS" when it does not work on Linux.

| Feature | What it does | Since | Platform | Guide |
| --- | --- | --- | --- | --- |
| Install | Installs the dependencies, a bench and a site. A second run changes nothing. | 0.1 | macOS, Linux | [Install](install.md) |
| Background service | Runs each bench under launchd or `systemd --user`: it survives a closed Terminal, restarts after a crash and comes back after a reboot. | 0.1 | macOS, Linux | [Benches and sites](guides/benches-and-sites.md) |
| Doctor and repair | `doctor` reads the state and names the fix. `repair` applies only the flagged fixes, with a backup first. | 0.1 | macOS, Linux | [Doctor and repair](guides/doctor-and-repair.md) |
| Adopt a bench | Registers a bench you already have, without touching its apps, sites or databases. | 0.2 | macOS, Linux | [Quick start](quick-start.md) |
| Several benches | A bench per Frappe version, each with its own ports, sites and scheduler. | 0.4 | macOS, Linux | [Benches and sites](guides/benches-and-sites.md) |
| Port blocks and `ports setup` | Gives each bench its own four ports, and moves a bench that clashes after asking. | 0.6 | macOS, Linux | [Port blocks](concepts/port-blocks.md) |
| Apps | Adds, installs and updates apps from the app registry or any git URL, with a changelog before each update. | 0.5 | macOS, Linux | [Apps](guides/apps.md) |
| Sites: backup, restore, drop | Backs up a site, restores it into the same site or into a copy for QA, and drops a site after a backup. | 0.5 | macOS, Linux | [Benches and sites](guides/benches-and-sites.md#backing-up-and-dropping-a-site) |
| Team profiles and lockfile | A profile sets up a bench with your team's apps and branches. `benchbar.toml` keeps every bench the same. | 0.5 | macOS, Linux | [Teams](guides/teams.md) |
| `pull` | Copies a production site over SSH into a new local site, with email muted and the scheduler paused. | 0.5 | macOS, Linux | [Teams](guides/teams.md) |
| Open as a user | `open --as USER` signs in to a development site as another user, with no password. Off until you turn it on for a site. | 0.8.1 | macOS, Linux | [open](reference/cli/other.md#open), [site open-as](reference/cli/site.md#site-open-as) |
| Rooms on your Wi-Fi (`share`, `lan-guard`) | Lets colleagues on the same Wi-Fi use a hardened copy of a site behind a room code. **Lab** `lan-rooms`. | 0.8.2 | macOS | [share and lan-guard](reference/cli/share.md), [How sharing keeps your bench safe](concepts/sharing-safety.md) |
| Labs | `benchbar labs` lists, turns on and turns off experiments. | 0.8.2 | macOS, Linux | [labs](reference/cli/labs.md) |
| Self update | `self-update` updates the CLI and the app. | 0.6 | macOS, Linux | [Install](install.md#updating) |
| Report a bug | `benchbar report` writes a diagnostics zip with secrets removed. | 0.5 | macOS, Linux | [report](reference/cli/other.md#report) |
| Agent mode | `--for-agent` prints JSON lines, never asks, and ends every change with one `done` line. | 0.8 | macOS, Linux | [Coding agents and MCP](guides/agents.md) |
| Shell helpers | `benchup`, `benchdown`, `benchrestart`, `benchwatch`, `benchlogs` and `benchstatus`. | 0.1 | macOS, Linux | [Benches and sites](guides/benches-and-sites.md#daily-use) |

On Linux, only the v15-lts bench is supported, and the site is
`linuxdev.localhost`. See [Install](install.md#linux).

## Mac app

The BenchBar app lives in the menu bar. It runs the CLI and reads its
JSON. See [The menu bar app](app.md).

| Feature | What it does | Since | Platform | Guide |
| --- | --- | --- | --- | --- |
| Runner, popover and window | A small runner shows the state of your benches. The popover starts and stops a bench. The window has a page per bench for sites, apps and health. | 0.2 | macOS | [The menu bar app](app.md) |
| Custom runners | Draw your own menu bar runner. | 0.2 | macOS | [Runners](runners.md) |
| First run wizard | Creates or adopts a bench on a Mac that has none. | 0.8 | macOS | [Quick start](quick-start.md) |
| Team Profiles and Find Benches | Imports profiles and finds benches in a folder. | 0.6 | macOS | [The menu bar app](app.md#the-benchbar-window) |
| Open as and Find User | Opens a site as a pinned user from the popover or the window. | 0.8.1 | macOS | [Open as a user](app.md#open-as-a-user) |
| Quick Switch | A panel on ⌃⌥U that opens a site as any pinned user from any app. **Lab** `quick-switch`. | 0.8.2 | macOS | [Quick Switch](app.md#quick-switch) |
| Sharing tab | Sets up, starts and stops a room, shows the room code and the people in it. **Lab** `lan-rooms`. | 0.8.2 | macOS | [Share on your network](app.md#share-on-your-network) |
| On your network | Finds the rooms of colleagues on your Wi-Fi and joins them. **Lab** `lan-rooms`. | 0.8.2 | macOS | [Join a room](app.md#join-a-room-on-your-network) |
| Settings > Labs | Lists the experiments, with a switch, a warning and the version of each. | 0.8.2 | macOS | [The menu bar app](app.md#the-benchbar-window) |
| Updates | Checks once a day, with Update Now. | 0.6 | macOS | [The menu bar app](app.md#updates) |
| URL scheme | `benchbar://` links for Raycast, Shortcuts and your own scripts. | 0.5 | macOS | [URL scheme](reference/url-scheme.md) |

## BenchBar for Windows

BenchBar for Windows is a beta. The benches run in WSL 2. See
[Windows](windows.md).

| Feature | What it does | Since | Platform | Guide |
| --- | --- | --- | --- | --- |
| `benchbar.exe` | Runs the CLI inside WSL from PowerShell, with the same input, output and exit code. | 0.8 | Windows | [Windows](windows.md) |
| Installer | Sets up WSL, an Ubuntu 24.04 distro and the CLI from one script. | 0.8 | Windows | [Windows](windows.md#install) |
| Tray app | Shows the benches in the notification area, with a window for sites, logs and health. | 0.8 | Windows | [The tray](windows.md#the-tray) |
| Report a bug | The tray writes the diagnostics zip. | 0.8 | Windows | [Report a bug](windows.md#report-a-bug) |
| Self update | `benchbar.exe self-update` and Update Now in the tray. | 0.8.3 | Windows | [Update](windows.md#update) |

Rooms and Quick Switch are not available on Windows yet. A Lab lists its
platforms, and `labs on` refuses on another one.

## MCP server

`benchbar mcp` lets a coding agent read and drive your benches over the
Model Context Protocol, on every platform that has the CLI.

| Feature | What it does | Since | Platform | Guide |
| --- | --- | --- | --- | --- |
| Read tools | List benches, status, doctor, logs, sites, apps and profiles. | 0.5 | macOS, Linux, Windows | [Coding agents and MCP](guides/agents.md) |
| Change tools | Plan and apply for apps, sites, restores and the service. A person approves each plan before the agent applies it. | 0.6 | macOS, Linux, Windows | [mcp](reference/cli/mcp.md) |

Rooms, Labs and the repairs of `repair` are not MCP tools. A change
that needs a person stays with the person.

## Guides still to write

These features have a reference or an app page, and no task guide yet:

- Rooms on your Wi-Fi: a guide to share a site for 30 minutes.
- Labs: what a Lab is and how to turn one on.
- Quick Switch.
- On your network: join a room as a guest.
