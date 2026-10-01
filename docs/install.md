---
title: "Install"
description: "Install the benchbar CLI and the BenchBar app with the one line installer, from the DMG, or from source, and uninstall them again."
---

There are three ways in. The one line installer sets up the CLI and the
app together and is the one most people want. The DMG gives you only the
app. Building from source is for contributors.

Check the [requirements](index.md#requirements) first: macOS 14 or later
on Apple Silicon, Homebrew and the Xcode Command Line Tools, about 5 GB
of free disk.

## The one line installer

```bash
curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash
```

The installer checks macOS, the Command Line Tools and Homebrew, clones
the CLI into `~/.local/share/benchbar` with links in `~/.local/bin`, adds
that folder to `~/.zshrc`, and installs the BenchBar app from the latest
release into `~/Applications` after checking its sha256. It then offers
`benchbar adopt` for a bench it finds, or `benchbar install`. The
installer itself never runs `sudo`.

In more detail, in this order, and it says so before each step:

1. It checks macOS and Apple Silicon (it warns on Intel), the Xcode
   Command Line Tools (it offers `xcode-select --install` and waits) and
   Homebrew (it offers the official installer).
2. It clones the CLI into `~/.local/share/benchbar`, or pulls when the
   clone exists, links `benchbar` and `frappe-mac` into `~/.local/bin`,
   and adds that folder to `PATH` in `~/.zshrc` inside a
   `# >>> benchbar-path >>>` marker block.
3. It installs or updates the BenchBar app from the latest GitHub
   release: the zip is checked against the release's `SHA256SUMS` and
   unpacked into `~/Applications`. This step is skipped when no release
   exists yet.
4. It offers `benchbar adopt` for a bench it finds, or `benchbar install`.

The installer never runs `sudo` itself. Homebrew's own installer, if
you accept it in step 1, asks for your password and says so first. If
you accept `benchbar install` or `benchbar adopt` in step 4, that
command asks for it once too, for the `/etc/hosts` line and the
wkhtmltopdf package. Prompts read from the terminal, so the installer
works when piped from `curl`.

### Installer flags

Pass flags after `bash -s --`, for example
`curl -fsSL .../install.sh | bash -s -- --no-app`.

| Flag | What it does |
|---|---|
| `--yes` | Accept every default, no questions (no terminal needed). On a Mac that already has the CLI in `~/.local/share/benchbar` this is an update: the CLI and the app only, no bench is adopted or installed and the Homebrew installer is never run |
| `--dry-run` | Print the plan and every command, change nothing |
| `--no-app` | The CLI only |
| `--app-only` | The app only |
| `--version vX.Y.Z` | Install that release of the app instead of the latest |
| `--uninstall` | Remove the app, the links and the PATH block; see [Uninstall](#uninstall) |

## The app from the DMG

Download `BenchBar-<version>.dmg` from the
[releases page](https://github.com/askysh/benchbar/releases), open it and
drag BenchBar to Applications. Since 0.6.1 the app and the DMG are
signed with a Developer ID, notarized by Apple and stapled, so BenchBar
opens like any other download, and later versions arrive through
**Check for Updates…** (Sparkle). Verify a download with
`shasum -a 256 -c SHA256SUMS` from the same release.

### Releases before 0.6.1

Releases up to 0.6.0 were not signed with an Apple Developer ID, and
macOS 15 and later stopped their first launch:

1. Double click BenchBar. A dialog says "BenchBar" Not Opened: Apple
   could not verify it is free of malware. Click **Done**. The highlighted
   button is **Move to Trash** (Move to Bin in British English), so do not
   press Return.
2. Open **System Settings > Privacy & Security**, scroll to the Security
   section: "BenchBar was blocked to protect your Mac".
3. Click **Open Anyway**, confirm with your password or Touch ID, then
   **Open Anyway** once more.

This happened once per install. The one line installer avoided it,
because `curl` sets no quarantine flag on the download.

The app needs the CLI. Install it with the one line installer and
`--no-app`, or from source below.

## From source

The CLI runs straight from the clone. Building the app needs full Xcode
26 or newer, not only the Command Line Tools.

```bash
git clone https://github.com/askysh/benchbar.git && cd benchbar
./benchbar install                 # optional: sets up a bench and a site, as in the Quick start
brew install xcodegen
scripts/release-local.sh           # the app: dist/BenchBar-<version>.zip and .dmg
scripts/macos-install-local.sh     # or build it and copy it to ~/Applications
```

`./benchbar install` is the full setup: Homebrew packages, a bench, a
site and the background service. It asks for passwords and `sudo`, and
the first run takes a while. Skip it when you only want to work on the
app or adopt a bench you have.

## Updating

In the app, click **Update Now**. BenchBar asks GitHub for the latest
release once a day (turn it off in General, **Check for updates
automatically**), and when there is a newer one it shows **Update to
X…** in the popover and the menu bar menu, and a banner on top of the
BenchBar window. Update Now opens Terminal with the installer, BenchBar
quits while it is replaced and opens again at the end. Your benches keep
running. **Copy Command** copies the same command, **Release Notes**
opens the release page.

In Terminal, the same update is:

```bash
benchbar self-update               # shows the plan, asks, then runs the installer
benchbar self-update --check       # this version against the latest release
```

or, on any version, including 0.5.x, which has no `self-update`:

```bash
curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash -s -- --yes
```

It pulls the CLI in `~/.local/share/benchbar`, replaces the app in
`~/Applications` (it quits a running BenchBar first), and changes no
bench: it never adopts, installs or updates a bench and never runs
`bench update`. It never runs `sudo`. An app in `/Applications` is
replaced there when that folder is writable (the app and `self-update`
pass `BENCHBAR_APP_DIR=/Applications`).

The pull is a fast forward only: local changes in
`~/.local/share/benchbar` stop it with a message instead of being
overwritten. After an update, run `benchbar doctor`: when it says the
runner is outdated, `benchbar repair` rewrites it, and a running bench
picks it up on its next start.

If your `benchbar` is a git checkout of your own, for example
`~/dev/benchbar`, the app and `self-update` update only the app
(`--app-only`) and tell you to update the CLI with `git pull` in that
checkout.

## After installing

Open a new Terminal tab, or run `source ~/.zshrc`, so `benchbar` and the
`bench*` helpers are on your `PATH`. Then follow the
[Quick start](quick-start.md).

## Uninstall

Uninstalling removes BenchBar, not your benches: every bench, site,
database and Homebrew package stays. Two things are worth knowing
first:

- Removing a bench's agent stops that bench. Without the agent it no
  longer runs in the background; you can still run it by hand with
  `bench start` in its folder.
- Removing the checkout, `~/.local/share/benchbar`, also deletes its
  `.benchbar/` folder: the logs and file backups of every benchbar run
  and the settings benchbar keeps for each bench. Copy `.benchbar/`
  somewhere else first if you may want them.

To see the plan without changing anything, then to uninstall:

```bash
curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash -s -- --uninstall --dry-run
curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash -s -- --uninstall
```

It removes the app, the `benchbar` and `frappe-mac` links and the PATH
block. Then it asks, for each bench's agent, whether to stop the bench
and remove its agent, runner and `Procfile.lean`, and last whether to
delete the checkout. Answer no to keep either. With `--yes` the answer
to both is yes.

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
