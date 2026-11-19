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
the first run bugs of Linux and macOS, and gives agents safer tools.

### Upgrade notes

1. **Your bench listens on 127.0.0.1 only.** The web server and socketio
   no longer accept connections from other devices on your network. To go
   back, run `benchbar listen all`, then `benchbar restart`.
   `benchbar listen local` undoes it. A phone or another PC that opens
   your bench by the address of the computer needs `listen all`.
2. **An unknown option is an error.** `benchbar repair --dry-rn --yes`
   used to ignore the typo and run for real. Now it exits with 64 and
   changes nothing. A script that passes an option the command never read
   must remove it. To get the old behavior for now, set
   `BENCHBAR_LENIENT_FLAGS=1`.
3. **`benchbar pull` neutralizes the copy.** After the restore, it
   switches off email accounts, webhooks, payment and storage
   integrations, API keys and the jobs that call out. It deletes every
   stored password except the Administrator login. Add `--keep-secrets`
   to keep production's integrations as 0.8 did. A copy you already
   pulled keeps what it has until you pull again with `--replace`. See
   [pull](reference/cli/pull.md).
4. **Run `benchbar repair` once after you update.** It rewrites the
   service files of each bench. Until then, `doctor` says that
   `Procfile.lean` is outdated. When the agent or the unit file changed,
   `repair` restarts a running bench itself. If it did not, run
   `benchbar restart` so the bench picks up the new files. The bench stops
   for a moment.

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

### Windows

- The BenchBar window has a **Labs** page, and the tray opens
  `benchbar://` links.
- `benchbar.exe` runs a command in the folder you are in, so
  `adopt .` and relative paths work.

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
