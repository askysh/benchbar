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
`benchbar labs on NAME`, in **Settings > Labs** in the Mac app or on the
**Labs** page of the BenchBar window on Windows. See
[labs](reference/cli/labs.md).

Terms: a *bench* is one Frappe installation folder. A *site* is one
database and domain on a bench. *Platform* names the systems where the
feature works.

## Command line tool

The `benchbar` command runs on macOS, and on Ubuntu 24.04 (Linux and
WSL; other apt based systems work with a doctor warning). Linux and WSL first shipped in 0.8.0. A row that came in before
that says "Linux 0.8.0": it was macOS only until then, and *Since* is the
macOS version. A row that says "macOS" does not work on Linux.

| Feature | What it does | Since | Platform | Guide |
| --- | --- | --- | --- | --- |
| Install | Installs the dependencies, a bench and a site. A second run changes nothing. | 0.1.0 | macOS; Linux 0.8.0 | [Install](install.md) |
| Pick a profile at install | `install --profile` takes `v15-lts`, `v16-lts` or a team profile. On Linux, Python and Node come from uv and fnm, and MariaDB from apt (10.11). | 0.1.0 | macOS; Linux 0.9.0 (v15-lts only before) | [Install](install.md#profiles-on-linux) |
| Background service | Runs each bench under launchd or `systemd --user`: it survives a closed Terminal, restarts after a crash and comes back after a reboot. | 0.2.0 | macOS; Linux 0.8.0 | [Benches and sites](guides/benches-and-sites.md) |
| Doctor and repair | `doctor` reads the state and names the fix. `repair` applies only the flagged fixes, with a backup first. | 0.2.0 | macOS; Linux 0.8.0 | [Doctor and repair](guides/doctor-and-repair.md) |
| Shell helpers | `benchup`, `benchdown`, `benchrestart`, `benchwatch`, `benchlogs` and `benchstatus`. | 0.2.0 | macOS; Linux 0.8.0 | [Benches and sites](guides/benches-and-sites.md#daily-use) |
| `up`, `down`, `restart`, `status` | Start, stop, restart and read the state of a bench. | 0.2.0 | macOS; Linux 0.8.0 | [running](reference/cli/running.md) |
| `list` | Every bench benchbar knows, without pinging a site. | 0.3.0 | macOS; Linux 0.8.0 | [list](reference/cli/other.md#list) |
| `logs`, `fg`, `watch` | Tail the bench log, run the bench in the foreground, rebuild assets. | 0.2.0 | macOS; Linux 0.8.0 | [running](reference/cli/running.md#logs) |
| `autostart`, `uninstall-service` | Let a bench come back after login or not, and remove its service. | 0.2.0 | macOS; Linux 0.8.0 | [autostart](reference/cli/other.md#autostart), [uninstall-service](reference/cli/other.md#uninstall-service) |
| Adopt a bench | Registers a bench you already have, without touching its apps, sites or databases. | 0.3.0 | macOS; Linux 0.8.0 | [Quick start](quick-start.md) |
| Report a bug | `benchbar report` writes a diagnostics zip with secrets removed. | 0.3.0 | macOS; Linux 0.8.0 | [report](reference/cli/other.md#report) |
| Several benches | A bench per Frappe version, each with its own sites and scheduler. | 0.4.0 | macOS; Linux 0.8.0 | [Benches and sites](guides/benches-and-sites.md#several-benches) |
| Port blocks | A new bench that clashes with another gets its own four ports. | 0.4.0 | macOS; Linux 0.8.0 | [Port blocks](concepts/port-blocks.md) |
| Sites: add, list, default, hosts | Adds a site, lists them, sets the default and writes the hosts lines. | 0.4.0 | macOS; Linux 0.8.0 | [site](reference/cli/site.md) |
| Apps | Adds, installs and updates apps from the app registry or any git URL, with a changelog before each update. | 0.5.0 | macOS; Linux 0.8.0 | [Apps](guides/apps.md) |
| Team profiles and lockfile | A profile sets up a bench with your team's apps and branches. `benchbar.toml` keeps every bench the same. | 0.5.0 | macOS; Linux 0.8.0 | [Teams](guides/teams.md) |
| `pull` | Copies a production site over SSH into a new local site, with email muted and the scheduler paused. | 0.5.0 | macOS; Linux 0.8.0 | [Teams](guides/teams.md) |
| `scan` and `register` | `scan` finds benches in a folder without changing anything. `register` remembers the ones you pick. | 0.5.7 | macOS; Linux 0.8.0 | [scan](reference/cli/scan.md) |
| `console` and `db` | A Python console and the site's database shell. | 0.5.8 | macOS; Linux 0.8.0 | [console](reference/cli/other.md#console), [db](reference/cli/other.md#db) |
| `ports setup` | Previews the ports of several benches, asks once, then applies. `ports check` and `ports mode` read and pin them. | 0.5.8 | macOS; Linux 0.8.0 | [ports](reference/cli/ports.md) |
| Site backup and drop | Backs up a site, and drops one after a backup. | 0.5.8 | macOS; Linux 0.8.0 | [Benches and sites](guides/benches-and-sites.md#backing-up-and-dropping-a-site) |
| Self update | `self-update` updates the CLI and the app. | 0.6.0 | macOS; Linux 0.8.0 | [Install](install.md#updating) |
| Run bench commands | `benchbar run -- migrate`, `clear-cache`, `build`, `run-tests` and more from an allow list, with a plan and token for a change. | 0.9.0 | macOS, Linux | [run](reference/cli/run.md) |
| Site restore | Restores a backup into the same site or into a copy for QA. | 0.8.0 | macOS, Linux | [site restore](reference/cli/site.md#site-restore) |
| Agent mode | `--for-agent` prints JSON lines, never asks, and ends every change with one `done` line. | 0.8.0 | macOS, Linux | [Coding agents and MCP](guides/agents.md) |
| Open as a user | `open --as USER` signs in to a development site as another user, with no password. Off until you turn it on for a site. | 0.8.1 | macOS, Linux | [open](reference/cli/other.md#open), [site open-as](reference/cli/site.md#site-open-as) |
| Rooms on your Wi-Fi (`share`, `lan-guard`) | Lets colleagues on the same Wi-Fi use a hardened copy of a site behind a room code. **Lab** `lan-rooms`. | 0.8.2 | macOS | [share and lan-guard](reference/cli/share.md), [How sharing keeps your bench safe](concepts/sharing-safety.md) |
| Labs | `benchbar labs` lists, turns on and turns off experiments. | 0.8.2 | macOS, Linux | [labs](reference/cli/labs.md) |

On Linux, only the v15-lts bench is supported, and the site is
`linuxdev.localhost`. See [Install](install.md#linux).

## Mac app

The BenchBar app lives in the menu bar. It runs the CLI and reads its
JSON. See [The menu bar app](app.md).

| Feature | What it does | Since | Platform | Guide |
| --- | --- | --- | --- | --- |
| Runner and popover | A small runner shows the state of your benches. The popover starts and stops a bench. | 0.3.0 | macOS | [The menu bar app](app.md#the-runner) |
| Speed | The runner runs faster the busier the bench is. | 0.3.0 | macOS | [Energy](app.md#energy) |
| Crash notification | A notice when a bench crashes or the crash guard pauses it. On Linux the runner calls `notify-send`; in WSL the tray shows the toast; a headless server has the record in `status`. | 0.3.0 | macOS; Linux 0.9.0 | [The menu bar app](app.md), [Linux](install.md#crash-notifications-on-linux) |
| Custom runners | Draw your own menu bar runner. | 0.3.0 | macOS | [Runners](runners.md) |
| BenchBar window | A page per bench for its overview, sites, apps and health. | 0.5.0 | macOS | [The BenchBar window](app.md#the-benchbar-window) |
| Doctor and repair | The Health page runs doctor and repairs with the plan first. | 0.5.0 | macOS | [The BenchBar window](app.md#the-benchbar-window) |
| Log window | Follows the bench log, with search and a filter per process. | 0.5.0 | macOS | [The BenchBar window](app.md#the-benchbar-window) |
| Find Benches | Finds benches in a folder you choose and adds them. | 0.5.7 | macOS | [Find existing benches](app.md#find-existing-benches-in-a-folder) |
| Ports | Port Settings and Setup: a preview, Automatic or Fixed mode, and Resolve & Start. | 0.5.8 | macOS | [The BenchBar window](app.md#the-benchbar-window) |
| Backups | Backs up a site, with or without files, and drops one after a backup. | 0.5.8 | macOS | [The BenchBar window](app.md#the-benchbar-window) |
| CPU and memory charts | The last ten minutes of a running bench. | 0.5.8 | macOS | [Energy](app.md#energy) |
| URL scheme | `benchbar://` links for Raycast, Shortcuts and your own scripts. | 0.5.8 | macOS | [URL scheme](reference/url-scheme.md) |
| Team Profiles | Imports and subscribes to profiles. | 0.6.0 | macOS | [The BenchBar window](app.md#the-benchbar-window) |
| Updates | Checks once a day, with Update Now. | 0.6.0 | macOS | [Updates](app.md#updates) |
| First run wizard | Creates or adopts a bench on a Mac that has none. | 0.8.0 | macOS | [A new bench from the app](app.md#a-new-bench-from-the-app) |
| Open as and Find User | Opens a site as a pinned user from the popover or the window. | 0.8.1 | macOS | [Open as a user](app.md#open-as-a-user) |
| Quick Switch | A panel on ⌃⌥U that opens a site as any pinned user from any app. **Lab** `quick-switch`. | 0.8.2 | macOS | [Quick Switch](app.md#quick-switch) |
| Sharing tab | Sets up, starts and stops a room, shows the room code and the people in it. **Lab** `lan-rooms`. | 0.8.2 | macOS | [Share on your network](app.md#share-on-your-network) |
| On your network | Finds the rooms of colleagues on your Wi-Fi and joins them. **Lab** `lan-rooms`. | 0.8.2 | macOS | [Join a room](app.md#join-a-room-on-your-network) |
| Settings > Labs | Lists the experiments, with a switch, a warning and the version of each. | 0.8.2 | macOS | [The menu bar app](app.md#the-benchbar-window) |
| Restore a backup | Restores one of a site's backups into the site or into a copy, from the plan the CLI shows, by its token. | 0.9.0 | macOS | [The BenchBar window](app.md#the-benchbar-window) |
| Pull a site | Copies a production site over SSH, or a downloaded backup, into a new site. The copy is neutralised unless you choose to keep the secrets. | 0.9.0 | macOS | [The BenchBar window](app.md#the-benchbar-window) |
| Unfinished changes | Lists an app update or add that stopped part way, with Resume and Drop the Record. | 0.9.0 | macOS | [The BenchBar window](app.md#the-benchbar-window) |

## BenchBar for Windows

BenchBar for Windows is a beta. The benches run in WSL 2. See
[Windows](windows.md).

| Feature | What it does | Since | Platform | Guide |
| --- | --- | --- | --- | --- |
| `benchbar.exe` | Runs the CLI inside WSL from PowerShell, with the same input, output and exit code. | 0.8.0 | Windows | [Windows](windows.md) |
| Installer | Sets up WSL, an Ubuntu 24.04 distro and the CLI from one script. | 0.8.0 | Windows | [Windows](windows.md#install) |
| Tray app | Shows the benches in the notification area. | 0.8.0 | Windows | [The tray](windows.md#the-tray) |
| Agent mode | `--for-agent` and `mcp` pass through to the CLI. `benchbar.exe doctor --for-agent` prints the Windows checks as text before the JSON, so its output is not one JSON document yet. | 0.8.0 | Windows (partial) | [Coding agents and MCP](guides/agents.md) |
| Window: Sites, Apps, Health | A page per bench: Overview, Sites (backups, restore, drop), Apps and Health with Repair. | 0.8.1 | Windows | [The BenchBar window](windows.md#the-benchbar-window) |
| Window: Ports | Port Settings and Setup in a bench's Overview. | 0.8.1 | Windows | [The BenchBar window](windows.md#the-benchbar-window) |
| Window: Profiles, Find Benches | Team Profiles and Find Benches in the sidebar. | 0.8.1 | Windows | [The BenchBar window](windows.md#the-benchbar-window) |
| Window: Open as | **Allow Open as...** per site, then **Open as...** and Find User open the site in your browser signed in as any enabled user. | 0.9.0 | Windows | [The BenchBar window](windows.md#the-benchbar-window) |
| Quick Switch | The tray menu opens a panel that opens a site as Administrator or a pinned user, by digit, arrows or typing. | 0.9.0 | Windows | [The BenchBar window](windows.md#the-benchbar-window) |
| Window: services only, autostart | **Start Services Only** (the bench's Redis, for a restore or a migrate) and **Stop Services**, and **Start again after Ubuntu restarts** (`autostart`), in the Overview. Offered when the CLI lists them. | 0.9.0 | Windows | [The BenchBar window](windows.md#the-benchbar-window) |
| Window: service, lockfile | **Install Service...** and the scheduler box use the plan of `service`; **Write Lockfile...** and **Apply Lockfile...** show the dry run first. **Watch Assets** and **Run in Foreground** open a terminal. | 0.9.0 | Windows | [The BenchBar window](windows.md#the-benchbar-window) |
| Window: acknowledge, prerequisites | **Acknowledge** on a Health warning (`doctor --ack`), and the prerequisites of `doctor --prerequisites` on the New Bench page. | 0.9.0 | Windows | [The BenchBar window](windows.md#the-benchbar-window) |
| Window: Labs | Lists the experiments with a switch, a warning, the version and, for one that is not on Windows yet, why. | 0.9.0 | Windows | [The BenchBar window](windows.md#the-benchbar-window) |
| URL scheme | `benchbar://` links start, stop and open a bench from a launcher or a script. **Settings > Ask before a link acts** is off by default. | 0.9.0 | Windows | [benchbar:// links](windows.md#benchbar-links), [URL scheme](reference/url-scheme.md) |
| Report a bug | The tray writes the diagnostics zip. | 0.8.1 | Windows | [Report a bug](windows.md#report-a-bug) |
| Self update | `benchbar.exe self-update` and Update Now in the tray. | 0.8.3 | Windows | [Update](windows.md#update) |

Rooms and Quick Switch are not available on Windows yet. A Lab lists its
platforms, and `labs on` refuses on another one. The Labs page shows why.

## MCP server

`benchbar mcp` lets a coding agent read and drive your benches over the
Model Context Protocol. It first shipped on macOS, and runs on Linux and
Windows (`benchbar.exe mcp`) since 0.8.0. The tools below are the ones in
`lib/frappe-local/mcp.py`.

| Feature | What it does | Since | Platform | Guide |
| --- | --- | --- | --- | --- |
| Read tools | `benchbar_list`, `benchbar_status`, `benchbar_doctor`, `benchbar_logs_tail` and `benchbar_site_list`. | 0.5.0 | macOS; Linux, Windows 0.8.0 | [Coding agents and MCP](guides/agents.md) |
| Actions | `benchbar_up`, `benchbar_down` and `benchbar_restart`. | 0.5.0 | macOS; Linux, Windows 0.8.0 | [mcp](reference/cli/mcp.md) |
| Profile tools | `benchbar_profile_list` and `benchbar_profile_check`. | 0.6.0 | macOS; Linux, Windows 0.8.0 | [Coding agents and MCP](guides/agents.md) |
| App plan and apply | `benchbar_app_add_plan`, then `benchbar_app_add` with the plan's token. | 0.6.0 | macOS; Linux, Windows 0.8.0 | [Coding agents and MCP](guides/agents.md) |
| `benchbar_app_list` | Every app of a bench, with branch, commit and sites. | 0.7.3 | macOS; Linux, Windows 0.8.0 | [Coding agents and MCP](guides/agents.md) |
| Run tools | `benchbar_run_plan` and `benchbar_run`, and `benchbar_run_read` for `doctor`, `list-apps` and `version`. | 0.9.0 | macOS, Linux, Windows | [Coding agents and MCP](guides/agents.md) |
| Site plan and apply | `benchbar_site_add_plan` and `benchbar_site_add`, `benchbar_site_restore_plan` and `benchbar_site_restore`. | 0.8.0 | macOS, Linux, Windows | [mcp](reference/cli/mcp.md) |
| `benchbar_site_backup` | Backs up one site. | 0.8.0 | macOS, Linux, Windows | [mcp](reference/cli/mcp.md) |
| Service plan and apply | `benchbar_service_install_plan` and `benchbar_service_install`, for a bench that has no service. | 0.8.0 | macOS, Linux, Windows | [mcp](reference/cli/mcp.md) |
| More read tools | `benchbar_site_backups`, `benchbar_ports_check`, `benchbar_ports_plan`, `benchbar_lock_check`, `benchbar_labs_list`, `benchbar_where`, `benchbar_doctor_prerequisites`, `benchbar_self_update_check` and `benchbar_app_focus_list`. | 0.9.0 | macOS, Linux, Windows | [Coding agents and MCP](guides/agents.md) |

A person approves each plan before the agent applies it. Rooms, Labs,
sharing, the LAN guard, `self-update` and the repairs of `repair` are not MCP tools. A change that needs a person
stays with the person.

## Guides still to write

These features have a reference or an app page, and no task guide yet:

- Rooms on your Wi-Fi: a guide to share a site for 30 minutes.
- Labs: what a Lab is and how to turn one on.
- Quick Switch.
- On your network: join a room as a guest.
