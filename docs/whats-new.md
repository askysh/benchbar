---
title: "What's new"
description: "What changed for you in each BenchBar release from 0.8.0, and what to do when you update to 0.9.0: new defaults, upgrade notes and links to the guides."
---

This page lists what changed for people who use BenchBar, one section per
release, newest first. Each item names its platform. The full log of every
change, written for contributors, is the
[CHANGELOG](https://github.com/askysh/benchbar/blob/main/CHANGELOG.md).
The [Features](features.md) page lists every feature with the version it
came in.

## 0.9.0 (coming)

0.9.0 is a hardening release. It changes three defaults, so read the
upgrade notes first. It also makes installs and commands faster, fixes
the first run bugs of Linux and macOS, and gives agents safer tools. New
commands follow a long run, wait for a bench and run bench commands. Rooms
come to Linux and to the Windows tray.

### Upgrade notes

BenchBar 0.9.0 changes three defaults to the safer choice. Each one has a way
back, an upgrade note here and a notice that shows once after the update: the
first command you type in a terminal prints it, the Mac app shows it as a
banner, and `benchbar notices` lists it again. `benchbar notices --dismiss ID`
or `--all` hides them. A fresh install shows none of them. See
[notices](reference/cli/other.md#notices).

### After the update

Run `benchbar repair` once per bench. It rewrites the service files (the
`Procfile.lean`, the runner and the agent) from the new templates, and it may
restart a running bench itself. If it did not, run `benchbar restart`. Until
then a running bench keeps the old behaviour, and `benchbar doctor` says
`Procfile.lean is outdated`.

### The bench listens on this computer only

The web server and socketio of a bench now listen on 127.0.0.1. Before, they
listened on every interface (Frappe's own default, with the developer debugger
on), so anyone on the same Wi-Fi who knew the site name could reach the dev
server.

- **Switch back:** `benchbar listen all`, then `benchbar restart`.
  `benchbar listen local` undoes it, and `benchbar listen` says which one a
  bench has. The choice is kept per bench.
- **Upgrade note:** reaching a bench by the address of the computer, from a
  phone or another PC, needs `benchbar listen all`. On Windows, a browser still
  opens `http://<site>.localhost:8000`.
- More: [listen](reference/cli/other.md#listen).

### Unknown options are errors

An option a command does not take now stops the run with exit 64 and changes
nothing. Before, it was ignored and the command ran:
`benchbar repair --dry-rn --yes` repaired for real. A flag that needs a value
and has none stops the same way.

- **Switch back:** set `BENCHBAR_LENIENT_FLAGS=1`. An unknown option is then a
  warning on stderr and the command runs, as before. It does not cover a flag
  with a missing value.
- **Upgrade note:** a script of yours that passes options a command never read
  now stops. Remove them, or set the variable for now. `benchbar COMMAND --help`
  lists every flag a command takes.
- More: [JSON API](json-schema.md) for the shape of the refusal under `--json`.

### pull neutralises the copy

`benchbar pull` now neutralises the copy it makes. Integrations are switched
off (email accounts, webhooks, OAuth, payment gateways, scheduled jobs that call
out) and stored passwords are deleted, except the Administrator login.
Customer data is not scrubbed.

- **Switch back:** `benchbar pull --keep-secrets` keeps production's
  integrations and passwords in the copy, as before. Email is still muted and
  the scheduler paused. It is a person's command: an agent run refuses it.
- **Upgrade note:** a copy you already pulled keeps what it has until you pull
  again with `--replace`. A script that pulls and then relies on production's
  SMTP, S3 or API credentials must add `--keep-secrets`.
- More: [pull](reference/cli/pull.md).

### Safer defaults

- **macOS, Linux, Windows.** The bench binds to 127.0.0.1 (see above).
  A room on your Wi-Fi now listens on this Mac's Wi-Fi address only, not
  on every interface.
- **All.** `benchbar mariadb-password`, `open --as --print-url` and the
  generated Administrator password of `benchbar_site_add` stay away from
  agents. The password goes to a file with mode 0600, and the result
  names the file.
- **macOS.** **Settings, Links, Ask before a link acts** asks before a
  `benchbar://` link starts or stops a bench. It is off by default.
  See [URL scheme](reference/url-scheme.md).
- **All.** `benchbar` refuses to run as root or with `sudo`: a
  `sudo benchbar repair` left files only root could change. It asks for
  `sudo` itself when a step needs it.
- **All.** Downloads are verified. `install.sh`, `install.ps1` and
  `self-update` check the checksum of what they download, and its build
  provenance when `gh` is signed in. See
  [Verify a download by hand](install.md#verify-a-download-by-hand).

### New commands

- **macOS, Linux.** `benchbar wait` blocks until a bench can serve, and
  says what is missing when it cannot. `status --json` has the same answer
  as `ready`. See [running](reference/cli/running.md#wait).
- `benchbar run -- migrate` runs `migrate`, `clear-cache`, `build`,
  `run-tests` and a few reads in the right bench and site, with a plan
  first for a change. See [run](reference/cli/run.md).
- `benchbar op` follows a long run by its `op_id`. `--background` starts
  an install, a repair, a pull or an app or site change detached. See
  [op](reference/cli/other.md#op).
- `benchbar history` lists every run that changed things on this computer
  and who started it. See [history](reference/cli/other.md#history).
- `benchbar lease take` holds a bench or a site while you or an agent
  work, so nothing else restarts, migrates, drops or restores it. See
  [lease](reference/cli/lease.md).
- `benchbar stats` shows the CPU and memory of a running bench.
- `benchbar bench forget` and `bench remove` retire a bench, with a plan
  first. `install --scratch` makes a bench that expires and `bench gc`
  lists the expired ones. `site hosts --prune` and `db orphans` find what
  a removed bench left behind. See [bench](reference/cli/bench.md).
- `site drop` and `pull` have a plan token: `--dry-run --json` prints it
  and `--apply TOKEN` runs exactly that plan.

### For agents

- **All.** New MCP tools: run a bench command, install and update an app,
  drop a site, take a lease, read the history and a long run, set the
  ports, and more read tools. See
  [Coding agents and MCP](guides/agents.md).
- An apply tool takes only a token that its plan tool returned, and every
  call is logged. `benchbar mcp --calls` prints the log.
- Every command with a JSON mode ends with the same fields under
  `--for-agent`: `exit`, and `error` when it failed.
- Text that comes from a bench is labeled as data, not instructions.

### Rooms on your Wi-Fi

- **Linux.** Rooms work on Linux: `benchbar share`, and a LAN guard made
  with nftables (`benchbar lan-guard install`). On WSL a room needs
  mirrored networking. See
  [Share a site on your network](guides/share-on-your-network.md).
- **macOS, Linux.** `benchbar share extend` no longer signs people out at
  the old deadline. The activity log names seats, not e-mail addresses,
  and old log files go when a room ends. A room no longer tells the name
  of the copied site to devices that have not joined.
- **macOS.** A guest who updates sees the room's site name only after
  they join. Forgetting your last room also deletes the key that shows
  your Mac to hosts.
- **Windows.** The **Sharing** tab of the BenchBar window hosts a room.
  It cannot join one yet. See [Rooms on Windows](windows.md#rooms-on-windows).
- **All.** The copy a room serves is neutralised the same way as a pulled
  site.

### Installs and first runs

- **macOS.** A first install on a Mac without `uv` works. A rerun after a
  failed `bench init` moves the empty folder aside and starts over.
- **macOS, Linux.** `install` says when it failed and exits with 1.
- **Linux.** `install` works under `sudo -iu`, `su -` and cron, and
  `benchbar status` says `unknown (no user bus)` when systemd cannot be
  reached.
- **Linux.** `install` takes `v16-lts` and team profiles. A bench that
  crashes three times shows a desktop notification.
- All entries are on [First run problems](first-run-problems.md).

### Faster

- `benchbar doctor` takes about 3 seconds instead of 10 on a bench with 41
  apps. `benchbar path`, `status` and `list` start about 20 ms faster.
- `benchbar down` and `restart` find the worker and scheduler processes
  of Homebrew Python and uv Python, so none is left running.
- A running bench no longer lets its logs grow without end: a log over
  20 MB is cut to its last 2000 lines.

### Backups and sites

- `site backup`, `site restore`, `site drop`, `pull --replace` and
  `app update` no longer delete the site's backups older than 23 hours.
- `site restore` and `pull` check a backup before they change anything. A
  dump that is empty or cut short stops the command and names the file.

### Mac app

- Quitting during an install, repair or update asks first.
- Fewer background processes, and one BenchBar at a time.
- VoiceOver reads each bench's state and each room's checks.
- A sharing setup that stopped half way shows **Finish setup** on the
  Sharing tab. The room code shows as dots.
- Notifications ask for permission once, with your first alert.
- A site has **Restore a Backup…** and the Sites tab has **Pull…**. Both
  show the plan first.
- The Apps tab lists **Unfinished changes** with **Resume…**, and
  **Add App…** takes several apps in one plan.
- Health has **Acknowledge** on a warning. A stopped bench has
  **Start Services Only**, and the Overview has **Start after login** and
  **Install Service…**.
- The bench pill says **Ready**, **Needs restart (code changed)** or
  **Running, not ready**, and a banner shows each default the update
  changed.

### Windows

- The BenchBar window has a **Labs** page, and the tray opens
  `benchbar://` links.
- `benchbar.exe` runs a command in the folder you are in, so
  `adopt .` and relative paths work.
- The BenchBar window has **Open as...** on a site, **Pull...** on the
  Sites tab, a **Sharing** tab and a banner for each default the update
  changed. The tray menu has **Quick Switch...**.
- The Apps tab adds several apps in one plan and finishes an update or an
  add that stopped part way. The first run wizard has a **Profile** list.
- `benchbar.exe doctor --json` prints one JSON document, with the Windows
  checks inside it.
- See [Windows](windows.md).

### Docs

- A [Features](features.md) page, a page per concept, and a CLI reference
  generated from the code. This page and [Privacy](privacy.md) are new.

## 0.8.3 (2026-11-17)

A fix pass for Windows. A PC goes from nothing to a running bench with
fewer dead ends.

- **Windows.** `benchbar.exe self-update` updates `benchbar.exe`, the tray
  and the command line tool in WSL to one release. The tray has **Update
  Now**. See [Update](windows.md#update).
- **Windows.** The installer stops before it writes anything when Smart App
  Control is on, and says what to do. `install.ps1 -Uninstall` removes
  BenchBar for Windows. See [Uninstall](windows.md#uninstall).
- **Windows.** `benchbar.exe` explains WSL errors and no longer hangs when
  `wsl.exe` does not answer. A Docker Desktop distro is never picked on its
  own.
- **Linux and WSL.** `install` checks systemd, ports and the network
  before it asks for `sudo`. `doctor` no longer warns that MariaDB is not
  running when it is.
- **All.** A guest of a room can open an app whose front end is not on the
  apps screen.

## 0.8.2 (2026-11-06)

Labs: experiments that stay off until you turn them on. See
[labs](reference/cli/labs.md).

- **macOS.** **Rooms on your Wi-Fi.** `benchbar share` opens a hardened copy
  of a dev site to people on the same Wi-Fi behind a room code.
  `benchbar lan-guard` keeps the bench ports off the network. See
  [How sharing keeps your bench safe](concepts/sharing-safety.md).
- **macOS.** **Quick Switch** opens a site as another user from any app
  with ⌃⌥U.
- **macOS.** Open as has shortcuts in the popover: ⌘0 for Administrator,
  ⌘1 to ⌘9 for a pinned user, ⇧⌘O to switch back.
- Turn on a Lab with `benchbar labs on NAME` or in **Settings > Labs**.

## 0.8.1 (2026-11-01)

- **Windows.** BenchBar for Windows is a beta. The tray takes a new PC from
  no WSL to a running bench, and **Report a Bug** sends a redacted report.
  See [Windows](windows.md).
- **macOS, Linux.** **Open as.** `benchbar open --as USER` signs a
  development site in as any of its users, with no password. You turn it
  on for each site. See [site open-as](reference/cli/site.md#site-open-as).
- **macOS.** Settings and About are panes of the one BenchBar window. The
  popover reads well in dark mode, and the menu bar has new runners.

## 0.8.0 (2026-10-30)

- **macOS.** **A bench without Terminal.** On a Mac with no bench, the app
  opens on a wizard that checks the Mac, creates a bench from a profile or
  adopts the one you have, and shows each step. See the
  [Quick start](quick-start.md).
- **Linux.** The command line tool runs on Ubuntu 24.04 with each bench
  under `systemd --user`. See [Install: Linux](install.md#linux).
- **Windows.** A preview: `benchbar.exe` forwards the CLI from PowerShell to
  WSL, and a tray app shows your benches.
- **All.** **Agents.** `--for-agent` prints JSON and asks nothing. Every
  change ends with one `done` line. `benchbar commands --json` lists every
  command. See [Coding agents and MCP](guides/agents.md).
- **All.** An `app update` that stops half way is finished by the next one.
  `site restore` puts a backup back, also into a copy for QA.
