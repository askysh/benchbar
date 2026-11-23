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
WSL; `install` stops on another system unless you pass
`--allow-unsupported-distro`). Linux and WSL first shipped in 0.8.0. A row that came in before
that says "Linux 0.8.0": it was macOS only until then, and *Since* is the
macOS version. A row that says "macOS" does not work on Linux.

| Feature | What it does | Since | Platform | Guide |
| --- | --- | --- | --- | --- |
| Install | Installs the dependencies, a bench and a site. A second run changes nothing. | 0.1.0 | macOS; Linux 0.8.0 | [Install](install.md) |
| Pick a profile at install | `install --profile` takes `v15-lts`, `v16-lts` or a team profile. On Linux, Python and Node come from uv and fnm, and MariaDB from apt (10.11). | 0.1.0 | macOS; Linux 0.9.0 (v15-lts only before) | [Install](install.md#profiles-on-linux) |
| Background service | Runs each bench under launchd or `systemd --user`: it survives a closed Terminal, restarts after a crash and comes back after a reboot. | 0.2.0 | macOS; Linux 0.8.0 | [Benches and sites](guides/benches-and-sites.md) |
| Doctor and repair | `doctor` reads the state and names the fix. `repair` applies only the flagged fixes, with a backup first. | 0.2.0 | macOS; Linux 0.8.0 | [Doctor and repair](guides/doctor-and-repair.md) |
| Shell helpers | `benchup`, `benchdown`, `benchrestart`, `benchwatch`, `benchlogs` and `benchstatus`, and `benchcd`, which goes to the folder `benchbar path` prints. | 0.2.0 | macOS; Linux 0.8.0 | [Benches and sites](guides/benches-and-sites.md#daily-use) |
| `up`, `down`, `restart`, `status` | Start, stop, restart and read the state of a bench. | 0.2.0 | macOS; Linux 0.8.0 | [running](reference/cli/running.md) |
| `wait` and `ready` | `status --json` has a `ready` object: agent, processes, site ping, socketio, Redis, a worker, and whether Python code changed since the bench started. `benchbar wait` and the MCP tool `benchbar_wait` block until it is ready and say what is missing. | 0.9.0 | macOS, Linux | [Readiness](json-schema.md#readiness), [running](reference/cli/running.md) |
| `stats` | CPU, memory and process count of the running bench's own processes, and the speed figure the runner of the app uses. | 0.9.0 | macOS, Linux | [running](reference/cli/running.md) |
| `list` | Every bench benchbar knows, without pinging a site. | 0.3.0 | macOS; Linux 0.8.0 | [list](reference/cli/other.md#list) |
| `logs`, `fg`, `watch` | Tail the bench log, run the bench in the foreground, rebuild assets. | 0.2.0 | macOS; Linux 0.8.0 | [running](reference/cli/running.md#logs) |
| `autostart`, `uninstall-service` | Let a bench come back after login or not, and remove its service. | 0.2.0 | macOS; Linux 0.8.0 | [autostart](reference/cli/other.md#autostart), [uninstall-service](reference/cli/other.md#uninstall-service) |
| Adopt a bench | `adopt` registers a bench you already have, without touching its apps, sites or databases. | 0.3.0 | macOS; Linux 0.8.0 | [Quick start](quick-start.md), [adopt](reference/cli/install.md) |
| Report a bug | `benchbar report` writes a diagnostics zip with secrets removed. | 0.3.0 | macOS; Linux 0.8.0 | [report](reference/cli/other.md#report) |
| `mariadb-password` | Prints the MariaDB root password to a person at a terminal, after a question. An agent is refused. | 0.3.0 | macOS; Linux 0.8.0 | [mariadb-password](reference/cli/other.md#mariadb-password) |
| Retire a bench | `bench forget` and `bench remove` with a plan and a token, scratch benches that expire (`install --scratch`, `bench gc`), `site hosts --prune`, `db orphans`. | 0.9.0 | macOS; Linux 0.9.0 | [bench](reference/cli/bench.md) |
| Several benches | A bench per Frappe version, each with its own sites and scheduler. | 0.4.0 | macOS; Linux 0.8.0 | [Benches and sites](guides/benches-and-sites.md#several-benches) |
| Port blocks | A new bench that clashes with another gets its own four ports. | 0.4.0 | macOS; Linux 0.8.0 | [Port blocks](concepts/port-blocks.md) |
| Sites: add, list, default, hosts | Adds a site, lists them, sets the default and writes the hosts lines. | 0.4.0 | macOS; Linux 0.8.0 | [site](reference/cli/site.md) |
| Apps | `app add`, `app install` and `app update` add, install and update apps from the app registry or any git URL, with a changelog before each update. | 0.5.0 | macOS; Linux 0.8.0 | [Apps](guides/apps.md) |
| Team profiles and lockfile | A profile (`profile import`, `profile subscribe`) sets up a bench with your team's apps and branches. `lock write` and `lock apply` keep every bench the same through `benchbar.toml`. | 0.5.0 | macOS; Linux 0.8.0 | [Teams](guides/teams.md) |
| `pull` | Copies a production site over SSH into a new local site, with email muted and the scheduler paused. | 0.5.0 | macOS; Linux 0.8.0 | [Teams](guides/teams.md) |
| `scan` and `register` | `scan` finds benches in a folder without changing anything. `register` remembers the ones you pick. | 0.5.7 | macOS; Linux 0.8.0 | [scan](reference/cli/scan.md) |
| `console` and `db` | A Python console and the site's database shell. | 0.5.8 | macOS; Linux 0.8.0 | [console](reference/cli/other.md#console), [db](reference/cli/other.md#db) |
| `ports setup` | Previews the ports of several benches, asks once, then applies. `ports check` and `ports mode` read and pin them. | 0.5.8 | macOS; Linux 0.8.0 | [ports](reference/cli/ports.md) |
| Site backup and drop | Backs up a site, and drops one after a backup. | 0.5.8 | macOS; Linux 0.8.0 | [Benches and sites](guides/benches-and-sites.md#backing-up-and-dropping-a-site) |
| Self update | `self-update` updates the CLI and the app. | 0.6.0 | macOS; Linux 0.8.0 | [Install](install.md#updating) |
| `docs` | Opens the documentation, or the page of one topic. | 0.5.5 | macOS; Linux 0.8.0 | [docs](reference/cli/other.md#docs) |
| `where` | Says how this CLI was installed, where its state folder is and which app it belongs to. | 0.7.0 | macOS; Linux 0.8.0 | [where](reference/cli/other.md#where) |
| Run bench commands | `benchbar run -- migrate`, `clear-cache`, `build`, `run-tests` and more from an allow list, with a plan and token for a change. | 0.9.0 | macOS, Linux | [run](reference/cli/run.md) |
| Site restore | Restores a backup into the same site or into a copy for QA. | 0.8.0 | macOS, Linux | [site restore](reference/cli/site.md#site-restore) |
| Site snapshots and rollback | `site snapshot` saves a site (database, files, apps and commits) before a risky change; `site rollback` puts it back in one step, after a snapshot of the current state. The CLI and MCP tools; the Mac app and the tray window have them too. | 0.9.0 | macOS, Linux | [Snapshots](guides/benches-and-sites.md#snapshots-save-a-site-put-it-back), [site snapshot](reference/cli/site.md#site-snapshot) |
| Move a site | `benchbar site move NAME --to-bench PATH` moves a site to another registered bench on this machine: a backup, the restore there, migrate, a check, then the drop here, with a plan and a token. The backups stay; a failed check leaves the site where it was. The Mac app and the tray window do not have it yet. | 0.9.0 | macOS, Linux | [site move](reference/cli/site.md#site-move) |
| Agent mode | `--for-agent` prints JSON lines, never asks, and ends every change with one `done` line. `commands --json` lists every command and flag. | 0.8.0 | macOS, Linux | [Coding agents and MCP](guides/agents.md) |
| Open as a user | `open --as USER` signs in to a development site as another user, with no password. `users` lists the users of the site. Off until you turn it on for a site. | 0.8.1 | macOS, Linux | [open](reference/cli/other.md#open), [users](reference/cli/other.md#users), [site open-as](reference/cli/site.md#site-open-as) |
| Rooms on your Wi-Fi (`share`, `lan-guard`) | Lets colleagues on the same Wi-Fi use a hardened copy of a site behind a room code. `lan-guard` keeps the bench ports off the network. **Lab** `lan-rooms`. | 0.8.2 | macOS; Linux 0.9.0 (WSL needs mirrored networking) | [Share a site on your network](guides/share-on-your-network.md), [share and lan-guard](reference/cli/share.md), [How sharing keeps your bench safe](concepts/sharing-safety.md) |
| Labs | `benchbar labs` lists, turns on and turns off experiments. | 0.8.2 | macOS, Linux | [Labs](guides/labs.md), [labs](reference/cli/labs.md) |
| Leases | `benchbar lease take` holds a bench or a site for a while, so another agent or the app does not restart, migrate, drop or restore it meanwhile. `--lease ID` passes it, `status --json` lists it. | 0.9.0 | macOS, Linux | [lease](reference/cli/lease.md) |
| `op` and `--background` | Every run that changes things has an `op_id`. `op status`, `op list` and `op wait` follow it, and `--background` starts a long run detached and prints the id at once. | 0.9.0 | macOS, Linux | [op](reference/cli/other.md#op) |
| `history` | Lists every run that changed things on this computer, newest first, with who started it: a terminal, the app, the tray, MCP or an agent. | 0.9.0 | macOS, Linux | [history](reference/cli/other.md#history) |
| `listen` and the 127.0.0.1 default | The web server and socketio of a bench listen on this computer only. `listen all` opens a bench to the network and `listen local` goes back. | 0.9.0 | macOS, Linux | [listen](reference/cli/other.md#listen), [What's new](whats-new.md#the-bench-listens-on-this-computer-only) |
| Verified downloads | Every release file has build provenance. `install.sh` and `self-update` check the checksum of what they download, and the provenance when `gh` is signed in. | 0.9.0 | macOS, Linux | [Verify a download by hand](install.md#verify-a-download-by-hand) |
| Notices after an update | Every default an update changes shows a notice once, with its switch back. `benchbar notices` lists and dismisses them, and the Mac app shows a banner. | 0.9.0 | macOS, Linux | [notices](reference/cli/other.md#notices), [What's new](whats-new.md) |

On Linux the default site is `linuxdev.localhost`. See
[Install](install.md#linux).

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
| Quick Switch | A panel on ⌃⌥U that opens a site as any pinned user from any app. **Lab** `quick-switch`. | 0.8.2 | macOS | [Quick Switch](guides/quick-switch.md), [in the app](app.md#quick-switch) |
| Sharing tab | Sets up, starts and stops a room, shows the room code and the people in it. **Lab** `lan-rooms`. | 0.8.2 | macOS | [Share a site on your network](guides/share-on-your-network.md#open-a-room-in-the-mac-app), [in the app](app.md#share-on-your-network) |
| On your network | Finds the rooms of colleagues on your Wi-Fi and joins them. **Lab** `lan-rooms`. | 0.8.2 | macOS | [Join a room](guides/share-on-your-network.md#join-a-room-in-the-mac-app), [in the app](app.md#join-a-room-on-your-network) |
| Settings > Labs | Lists the experiments, with a switch, a warning and the version of each. | 0.8.2 | macOS | [The menu bar app](app.md#the-benchbar-window) |
| Restore a backup | Restores one of a site's backups into the site or into a copy, from the plan the CLI shows, by its token. | 0.9.0 | macOS | [The BenchBar window](app.md#the-benchbar-window) |
| Pull a site | Copies a production site over SSH, or a downloaded backup, into a new site. The copy is neutralised unless you choose to keep the secrets. | 0.9.0 | macOS | [The BenchBar window](app.md#the-benchbar-window) |
| Unfinished changes | Lists an app update or add that stopped part way, with Resume and Drop the Record. | 0.9.0 | macOS | [The BenchBar window](app.md#the-benchbar-window) |
| Several apps in one add | **Add App…** takes up to eight apps in one plan with one token, each with its own branch, commit pin and site. | 0.9.0 | macOS | [The BenchBar window](app.md#the-benchbar-window) |
| Acknowledge a warning | **Acknowledge** and **Undo** on a Health warning (`doctor --ack`, `--unack`); not for a failure. | 0.9.0 | macOS | [The BenchBar window](app.md#the-benchbar-window) |
| Services only, autostart | **Start Services Only** and **Stop Services** for a stopped bench, and **Start after login** (`autostart`) in the Overview. Offered when the CLI lists them. | 0.9.0 | macOS | [The BenchBar window](app.md#the-benchbar-window) |
| Lockfile: write and apply | **Write Lock File…** and **Apply…** in the Overview show the CLI's plan of `lock write` and `lock apply` and run it when you confirm. | 0.9.0 | macOS | [The BenchBar window](app.md#the-benchbar-window) |
| Site snapshots and rollback | **Snapshots…** on a site takes a snapshot (optional label), lists them, rolls the site back by the plan and token of `site rollback`, and removes one after asking. | 0.9.0 | macOS | [The BenchBar window](app.md#the-benchbar-window) |
| History | A **History** pane lists what ran on this Mac that changed something, who started it and how it ended (`history`). | 0.9.0 | macOS | [The BenchBar window](app.md#the-benchbar-window) |
| Leases | The Overview shows who holds a lease and until when; a refused change shows the holder, and **Break Lease…** is a person's explicit choice. | 0.9.0 | macOS | [The BenchBar window](app.md#the-benchbar-window) |
| Run Bench Command | **Run Bench Command…** in the ⋯ menu of the Overview runs one command of the allow list of `benchbar run`: a read shows its output at once, a change shows the plan of `run --dry-run --json` and runs it by its own token. Offered when the CLI lists `run`. | 0.9.0 | macOS | [The BenchBar window](app.md#the-benchbar-window) |
| Running operations | A **Running now** section on the Overview lists the bench's background operations (`op list --running`, `op status`) while the window can be seen. | 0.9.0 | macOS | [The BenchBar window](app.md#the-benchbar-window) |
| Watch Assets in Terminal | The ⋯ menu of the Overview opens `benchbar watch` for the bench in Terminal. | 0.9.0 | macOS | [The BenchBar window](app.md#the-benchbar-window) |
| Logs since the last start | The log window has **Since last start** and reads the worker log through `logs --json`, with only the new lines each time. | 0.9.0 | macOS | [The menu bar app](app.md) |
| Install or refresh the service | **Install Service…** or **Refresh Service…** shows the plan of `service` and runs it by its token. | 0.9.0 | macOS | [The BenchBar window](app.md#the-benchbar-window) |

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
| Quick Switch | **Quick Switch...** in the tray menu opens a panel that opens a site as Administrator or a pinned user, by digit, arrows or typing. It has no global keyboard shortcut yet. | 0.9.0 | Windows | [The BenchBar window](windows.md#the-benchbar-window) |
| Window: services only, autostart | **Start Services Only** (the bench's Redis, for a restore or a migrate) and **Stop Services**, and **Start again after Ubuntu restarts** (`autostart`), in the Overview. Offered when the CLI lists them. | 0.9.0 | Windows | [The BenchBar window](windows.md#the-benchbar-window) |
| Window: service, lockfile | **Install Service...** and the scheduler box use the plan of `service`; **Write Lockfile...** and **Apply Lockfile...** show the dry run first. **Watch Assets** and **Run in Foreground** open a terminal. | 0.9.0 | Windows | [The BenchBar window](windows.md#the-benchbar-window) |
| Window: acknowledge, prerequisites | **Acknowledge** on a Health warning (`doctor --ack`), and the prerequisites of `doctor --prerequisites` on the New Bench page. | 0.9.0 | Windows | [The BenchBar window](windows.md#the-benchbar-window) |
| Window: notices, readiness | A banner for each default an update changed (`notices[]`, **Dismiss** runs `notices --dismiss`), and **Ready**, **Needs restart (code changed)** or **Running, not ready** with what the bench waits on, from `status --json` `ready`. | 0.9.0 | Windows | [The BenchBar window](windows.md#the-benchbar-window) |
| Window: Pull | **Pull...** on the Sites tab copies a production site over SSH, or a backup folder, into a new site: the plan of `pull --dry-run` first, then `--apply TOKEN`. The copy is neutralised unless you keep production's secrets. | 0.9.0 | Windows | [The BenchBar window](windows.md#the-benchbar-window) |
| Window: snapshots and rollback | **Snapshots...** in the menu of a site takes a snapshot (optional label), lists them, rolls the site back (you type the site name, then the plan of `site rollback --dry-run`, then `--apply TOKEN`) and removes one after asking. | 0.9.0 | Windows | [The BenchBar window](windows.md#the-benchbar-window) |
| Window: leases | The Overview lists who holds a lease on the bench or a site and until when (`lease list`). A start, stop or restart a lease refuses shows the holder, and **Break Lease...** is your own choice: it asks, then runs the same command with `--break-lease`. | 0.9.0 | Windows | [The BenchBar window](windows.md#the-benchbar-window) |
| Window: History | **History** below the benches lists what ran on this computer and changed something (`history`): who started it, how it ended and what it changed. | 0.9.0 | Windows | [The BenchBar window](windows.md#the-benchbar-window) |
| Window: resource charts and running operations | While the Overview is on screen it charts the CPU and memory of the running bench, with its process count and the runner speed (from benchbar stats), and lists the background operations of the bench (`op list`). | 0.9.0 | Windows | [The BenchBar window](windows.md#the-benchbar-window) |
| Window: Run Bench Command | **Run Bench Command...** in the More menu of the Overview runs one command of the allow list of `benchbar run`: a read at once, a change after its plan, by the token of that plan. | 0.9.0 | Windows | [The BenchBar window](windows.md#the-benchbar-window) |
| Window: Tidy Up, Forget, Remove | **Tidy Up...** in the More menu of the Overview marks the bench scratch for 1 to 90 days or not, lists the scratch benches that expired (`bench gc --dry-run`) and the databases no site refers to (`db orphans`), and **Remove Expired...** runs the plan of `bench gc` by its token. **Forget Bench...**, **Remove Bench...** (you type the folder name) and **Remove Service...** (`uninstall-service` for that bench) show their plan first. `site hosts --prune` has no entry: it is macOS only. | 0.9.0 | Windows | [The BenchBar window](windows.md#the-benchbar-window) |
| Window: Labs | Lists the experiments with a switch, a warning, the version and, for one that is not on Windows yet, why. | 0.9.0 | Windows | [The BenchBar window](windows.md#the-benchbar-window) |
| Window: Sharing | The **Sharing** tab hosts a room: set up the copy, start, stop, extend and lock the room, the room code and the people in it. Shown while the `lan-rooms` Lab is on. The tray cannot join a room. | 0.9.0 | Windows | [The BenchBar window](windows.md#the-benchbar-window), [Rooms on Windows](windows.md#rooms-on-windows) |
| URL scheme | `benchbar://` links start, stop and open a bench from a launcher or a script. **Settings > Ask before a link acts** is off by default. | 0.9.0 | Windows | [benchbar:// links](windows.md#benchbar-links), [URL scheme](reference/url-scheme.md) |
| Report a bug | The tray writes the diagnostics zip. | 0.8.1 | Windows | [Report a bug](windows.md#report-a-bug) |
| Self update | `benchbar.exe self-update` and Update Now in the tray. | 0.8.3 | Windows | [Update](windows.md#update) |
| Verified downloads | `benchbar.exe self-update` runs `install.ps1` of the release it installs, after it checks its checksum. `install.ps1` checks the provenance of the zip when `gh` is signed in. | 0.9.0 | Windows | [Update](windows.md#update) |

The tray hosts a room and cannot join one yet. A Lab lists its platforms,
and `labs on` refuses on another one. The Labs page shows why.

## MCP server

`benchbar mcp` lets a coding agent read and drive your benches over the
Model Context Protocol. It first shipped on macOS, and runs on Linux and
Windows (`benchbar.exe mcp`) since 0.8.0. The tools below are the ones in
`lib/frappe-local/mcp.py`.

| Feature | What it does | Since | Platform | Guide |
| --- | --- | --- | --- | --- |
| `benchbar mcp` | Starts the server for a coding agent. `mcp --calls` prints the log of every call, and `mcp --print-agents-md` a snippet for the AGENTS.md of a project. | 0.5.0 | macOS; Linux, Windows 0.8.0 | [mcp](reference/cli/mcp.md) |
| Read tools | `benchbar_list`, `benchbar_status`, `benchbar_doctor`, `benchbar_logs_tail` and `benchbar_site_list`. | 0.5.0 | macOS; Linux, Windows 0.8.0 | [Coding agents and MCP](guides/agents.md) |
| Actions | `benchbar_up`, `benchbar_down` and `benchbar_restart`. | 0.5.0 | macOS; Linux, Windows 0.8.0 | [mcp](reference/cli/mcp.md) |
| App plan and apply | `benchbar_app_add_plan`, then `benchbar_app_add` with the plan's token. | 0.6.0 | macOS; Linux, Windows 0.8.0 | [Coding agents and MCP](guides/agents.md) |
| `benchbar_app_list` | Every app of a bench, with branch, commit and sites. | 0.7.3 | macOS; Linux, Windows 0.8.0 | [Coding agents and MCP](guides/agents.md) |
| Run tools | `benchbar_run_plan` and `benchbar_run`, and `benchbar_run_read` for `doctor`, `list-apps` and `version`. | 0.9.0 | macOS, Linux, Windows | [Coding agents and MCP](guides/agents.md) |
| Site plan and apply | `benchbar_site_add_plan` and `benchbar_site_add`, `benchbar_site_restore_plan` and `benchbar_site_restore`. | 0.8.0 | macOS, Linux, Windows | [mcp](reference/cli/mcp.md) |
| Snapshot tools | `benchbar_site_snapshot` saves a site, `benchbar_site_snapshots` lists them, and `benchbar_site_rollback_plan` then `benchbar_site_rollback` put one back with the plan's token. No tool removes a snapshot, and the default site is never rolled back by an agent. | 0.9.0 | macOS, Linux, Windows | [Coding agents and MCP](guides/agents.md) |
| Site move tools | `benchbar_site_move_plan` then `benchbar_site_move` move a site to another bench of this machine with the plan's token. The default site of either bench is never moved. | 0.9.0 | macOS, Linux, Windows | [Coding agents and MCP](guides/agents.md) |
| `benchbar_site_backup` | Backs up one site. | 0.8.0 | macOS, Linux, Windows | [mcp](reference/cli/mcp.md) |
| Service plan and apply | `benchbar_service_install_plan` and `benchbar_service_install`, for a bench that has no service. | 0.8.0 | macOS, Linux, Windows | [mcp](reference/cli/mcp.md) |
| App install and update | `benchbar_app_install_plan` then `benchbar_app_install`, and `benchbar_app_update_plan` then `benchbar_app_update`, each with the CLI's own plan token. | 0.9.0 | macOS, Linux, Windows | [Coding agents and MCP](guides/agents.md) |
| Lock tools | `benchbar_lock_write` writes `benchbar.toml` from the bench, and `benchbar_lock_apply_plan` then `benchbar_lock_apply` clone and fast forward to it with the plan's token; `benchbar_lock_check` reads. | 0.9.0 | macOS, Linux, Windows | [Coding agents and MCP](guides/agents.md#parity-with-the-command-line) |
| Pull tools | `benchbar_pull_plan` then `benchbar_pull` copy a production site into a new, neutralised local site with the plan's token. Never the default site, never `--keep-secrets`. | 0.9.0 | macOS, Linux, Windows | [Coding agents and MCP](guides/agents.md#parity-with-the-command-line) |
| Profile tools | `benchbar_profile_list` and `benchbar_profile_check` read, `benchbar_profile_create` writes a team profile from a bench, and `benchbar_profile_remove_plan` then `benchbar_profile_remove` move an import or subscription aside. `profile import`, `subscribe`, `update` and `export` stay a person's. | 0.9.0 | macOS, Linux, Windows | [Coding agents and MCP](guides/agents.md#parity-with-the-command-line) |
| Lease tools | `benchbar_lease_take`, `benchbar_lease_renew`, `benchbar_lease_release` and `benchbar_lease_list`: hold a bench or a site while an agent works. | 0.9.0 | macOS, Linux, Windows | [Coding agents and MCP](guides/agents.md#leases) |
| Long runs, history and readiness | `benchbar_op_status` reads a long run by its `op_id`, `benchbar_history` what ran before the agent and who started it, and `benchbar_wait` blocks until a bench is ready. | 0.9.0 | macOS, Linux, Windows | [Coding agents and MCP](guides/agents.md#long-runs-and-op_id) |
| Site drop | `benchbar_site_drop_plan`, then `benchbar_site_drop` with the token of the plan. The default site is refused. | 0.9.0 | macOS, Linux, Windows | [Coding agents and MCP](guides/agents.md#parity-with-the-command-line) |
| Ports, autostart, scan, report | `benchbar_ports_mode`, `benchbar_ports_apply` with the token of `benchbar_ports_plan`, `benchbar_autostart`, `benchbar_doctor_ack` for a warning the person has seen, `benchbar_scan` and `benchbar_report`. | 0.9.0 | macOS, Linux, Windows | [Coding agents and MCP](guides/agents.md#parity-with-the-command-line) |
| More read tools | `benchbar_site_backups`, `benchbar_ports_check`, `benchbar_ports_plan`, `benchbar_lock_check`, `benchbar_labs_list`, `benchbar_where`, `benchbar_doctor_prerequisites`, `benchbar_self_update_check`, `benchbar_app_focus_list` and `benchbar_stats` (CPU and memory of the running bench). | 0.9.0 | macOS, Linux, Windows | [Coding agents and MCP](guides/agents.md) |

A person approves each plan before the agent applies it. Turning a Lab
on, rooms, the LAN guard, `self-update`, `register`, `console`, `db` and
the repairs of `repair` are not MCP tools. A change that needs a person
stays with the person.
