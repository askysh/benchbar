---
title: "Uninstall"
description: "Remove BenchBar and the benchbar CLI on macOS and Linux, one bench's service or everything, and what stays on disk."
---

This page is for macOS and Linux. For Windows, see
[Uninstall](windows.md#uninstall).

Uninstalling removes BenchBar, not your benches: every bench, site,
database and the Homebrew packages they use stay. Two things are worth
knowing first:

- Removing a bench's agent stops that bench. Without the agent it no
  longer runs in the background; you can still run it by hand with
  `bench start` in its folder.
- The logs and file backups of every benchbar run, the remembered
  benches and the settings benchbar keeps for each bench are in
  `~/.local/state/benchbar`, for Homebrew and the one line installer
  alike. Uninstalling keeps that folder; move it to the Trash yourself
  when you no longer want them. When `~/.local/state` is on another
  volume than `~/.local/share/benchbar`, the state stays in that
  checkout's `.benchbar/` folder, and deleting the checkout deletes it.

What `install`, `adopt` and the rest wrote outside the bench stays too,
and you remove it yourself when you want it gone:

- The marked block in `/etc/hosts` with a line per site (macOS). `benchbar uninstall-service --all` offers to remove it, with `sudo` and a backup, when you run it in a terminal; with `--yes` it prints the command instead and never edits the file.
- The MariaDB root password: the Keychain item `benchbar-mariadb` on macOS, a 0600 file in the state folder on Linux.
- The patched wkhtmltopdf package that `install` put in for PDF output; remove it with the package tool of your system.
- On Linux, the apt packages `install` added (MariaDB, Redis and the rest), and uv and fnm with the Python and Node they fetched, under `~/.local`. On macOS the Homebrew packages stay.
- The app's login item, when you turned on "Open BenchBar at login": turn it off in the app's Settings first, or remove it in System Settings, General, Login Items. Deleting the app leaves a dead entry there.
- On Linux, linger for your user (`sudo loginctl disable-linger USER`), and the `~/.bashrc` helper block when you did not use `uninstall-service`.
- The LAN guard of a room: `benchbar lan-guard remove` takes out the pf anchor and its launch daemon (macOS), or the nftables table, its systemd unit and its rules file (Linux).

### Homebrew

```bash
benchbar uninstall-service --all
brew uninstall --cask benchbar-app
brew uninstall benchbar
```

Run `uninstall-service --all` first: `brew uninstall` cannot stop the
background agents. It asks once, then stops every bench that has a
benchbar agent and removes its agent, runner and `Procfile.lean`, and the
`# >>> benchbar >>>` block from `~/.zshrc`.

### The one line installer

To see the plan without changing anything, then to uninstall:

```bash
curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash -s -- --uninstall --dry-run
curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash -s -- --uninstall
```

It removes the app, the `benchbar` and `frappe-mac` (the old name) links and the PATH
block. Then it asks, for each bench's agent, whether to stop the bench
and remove its agent, runner and `Procfile.lean`, and last whether to
delete the checkout. Answer no to keep either. With `--yes` the answer
to both is yes. When `~/.local/state/benchbar` is a link into the
checkout, the checkout is kept even with `--yes`, and the run says to
move the state first.

### One bench

To remove only the background service of one bench and keep BenchBar:

```bash
benchbar uninstall-service --bench-dir ~/frappe-bench   # use your bench's folder
```

It stops the bench and removes its agent, runner and `Procfile.lean`.
It also removes the `# >>> benchbar >>>` block from `~/.zshrc`, so
`benchup` and the other helpers are gone for every bench until
`benchbar repair` on a remaining bench writes the block again.

benchbar never deletes a whole bench. The only commands that drop or
overwrite a site's database, `benchbar site drop` and `benchbar pull
--replace`, back it up first. To wipe a bench by hand, see
[Troubleshooting](troubleshooting.md#wiping-a-bench).
