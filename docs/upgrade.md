---
title: "Update and migrate"
description: "Update BenchBar and the benchbar CLI on macOS and Linux, and move from the one line installer to Homebrew without stopping your benches."
---

This page is for people who already installed BenchBar. To install it,
see [Install](install.md). For Windows, see [Update](windows.md#update).

## Update the app and the CLI

BenchBar.app carries its own copy of the CLI, and since 0.7.1 Homebrew's
and the one line installer's `benchbar` hand off to it once the app is
installed: whichever `benchbar` you run, it is the app's version. So with
the app, updating the app updates everything, by either channel:

- **In the app**: **Update Now** (or **Check for Updates…** in the menu
  bar menu). Sparkle downloads the new version and restarts BenchBar.
  Your benches keep running.
- **With Homebrew**, when the cask installed the app:

  ```bash
  brew upgrade
  ```

  The cask has `auto_updates`, so brew replaces the app only when the
  app itself is older than the tap's version: after Sparkle updated it,
  `brew upgrade` leaves it alone, and when Sparkle has not, brew updates
  it. Right after a release the tap can be a few minutes behind.

`benchbar where` shows which CLI runs (`install app`) and which one it
was handed off from, and `benchbar --version` adds a `via` line for it.
When Homebrew's or the installer's copy is newer than the app's CLI, both
say so: the app's older CLI still runs, so that one version works on your
benches, until the app updates. To run Homebrew's or the installer's own
copy for once, set `BENCHBAR_NO_HANDOFF=1`. A git checkout of your own
never hands off.

### Without the app

Homebrew's CLI updates with `brew upgrade askysh/tap/benchbar`, which
`benchbar self-update` runs after asking. The one line installer's CLI
updates with `benchbar self-update`:

```bash
benchbar self-update               # shows the plan, asks, checks the installer, then runs it
benchbar self-update --check       # this version against the latest release
```

or, on any version, including 0.5.x, which has no `self-update`:

```bash
curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash -s -- --yes
```

`self-update` runs the installer of the release it installs (the file at
that release's tag), and only after its sha256 matched the line for
`install.sh` in that release's `SHA256SUMS`. It then checks the CLI out at
the release's tag, so the CLI and the app are the same version. A release
whose sums do not list `install.sh` is refused, with the line above to
update by hand.

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
`~/dev/benchbar`, `self-update` updates only the app (`--app-only`) and
tells you to update the CLI with `git pull` in that checkout.

## From the one line installer to Homebrew

Your benches keep running through the move: their agents and runners
never name the CLI.

1. Install with Homebrew:

   ```bash
   brew install askysh/tap/benchbar askysh/tap/benchbar-app
   ```

2. Run Homebrew's `repair` by its full path. In this Terminal
   `~/.local/bin` still leads to the old copy, so plain `benchbar` would
   run that one:

   ```bash
   /opt/homebrew/opt/benchbar/bin/benchbar repair
   ```

   It moves the state to `~/.local/state/benchbar`, points the
   `~/.local/bin` links at Homebrew's CLI and rewrites the helper block in
   `~/.zshrc`.

3. Run `source ~/.zshrc`, or open a new Terminal tab.
4. Later, move `~/.local/share/benchbar` and `~/Applications/BenchBar.app`
   to the Trash.

Do not use `install.sh --uninstall` for this: it stops every bench's
agent. Until the old copies are gone, doctor's "Second CLI" and
"BenchBar.app copies" warnings point at them. Two copies of the app
matter more than two of the CLI: the login item and Spotlight may open
the old one, and its CLI is the one every `benchbar` hands off to.
