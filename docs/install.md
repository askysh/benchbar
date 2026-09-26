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
`benchbar adopt` for a bench it finds, or `benchbar install`. It never
runs `sudo`.

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

The only step that may ask for your password is Homebrew's own
installer, and it says so first. Prompts read from the terminal, so the
installer works when piped from `curl`.

### Installer flags

Pass flags after `bash -s --`, for example
`curl -fsSL .../install.sh | bash -s -- --no-app`.

| Flag | What it does |
|---|---|
| `--yes` | Accept every default, no questions (no terminal needed) |
| `--dry-run` | Print the plan and every command, change nothing |
| `--no-app` | The CLI only |
| `--app-only` | The app only |
| `--version vX.Y.Z` | Install that release of the app instead of the latest |
| `--uninstall` | Remove the app, the links and the PATH block; see [Uninstall](#uninstall) |

## The app from the DMG

Download `BenchBar-<version>.dmg` from the
[releases page](https://github.com/askysh/benchbar/releases), open it and
drag BenchBar to Applications. The app is not yet signed with an Apple
Developer ID, so macOS 15 and later stop the first launch:

1. Double click BenchBar. A dialog says "BenchBar" Not Opened: Apple
   could not verify it is free of malware. Click **Done**. The highlighted
   button is **Move to Trash** (Move to Bin in British English), so do not
   press Return.
2. Open **System Settings > Privacy & Security**, scroll to the Security
   section: "BenchBar was blocked to protect your Mac".
3. Click **Open Anyway**, confirm with your password or Touch ID, then
   **Open Anyway** once more.

This happens once. The one line installer avoids it, because `curl` sets
no quarantine flag on the download. Verify a download with
`shasum -a 256 -c SHA256SUMS` from the same release.

The app needs the CLI. Install it with the one line installer and
`--no-app`, or from source below.

## From source

```bash
git clone https://github.com/askysh/benchbar.git && cd benchbar
./benchbar install                 # the CLI needs nothing else
brew install xcodegen
scripts/release-local.sh           # the app: dist/BenchBar-<version>.zip and .dmg
scripts/macos-install-local.sh     # or build it and copy it to ~/Applications
```

The app needs full Xcode 26 or newer.

## After installing

Open a new Terminal tab, or run `source ~/.zshrc`, so `benchbar` and the
`bench*` helpers are on your `PATH`. Then follow the
[Quick start](quick-start.md).

## Uninstall

```bash
benchbar uninstall-service     # remove the agent, runner, Procfile.lean and helpers; keep the bench
curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash -s -- --uninstall
```

The second line removes the app, the links and the PATH block, and offers
to remove the agents and the checkout (with `--yes`: yes to both).
Benches, sites and databases are never deleted by benchbar; the recipe
for wiping one by hand is in
[Troubleshooting](troubleshooting.md#wiping-a-bench).
