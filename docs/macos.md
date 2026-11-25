---
title: "BenchBar on macOS"
description: "Start here on a Mac: what you need, the one command to install, the menu bar app, and where to go next."
---

On a Mac you get the `benchbar` command line tool and BenchBar.app, the
menu bar app. Each bench runs as a launchd agent, so it keeps running
after you close Terminal.

## What you need

- macOS 14 or later on Apple Silicon.
- Homebrew, which needs the Xcode Command Line Tools. Install Homebrew
  first, then run the command below.
- About 5 GB of free disk.

## Install

```bash
brew install askysh/tap/benchbar askysh/tap/benchbar-app
```

Then run `benchbar install` and open `http://macdev:8000`. Other ways to
install are on the [Install](install.md) page.

## Next

- [Quick start](quick-start.md): the first ten minutes.
- [The menu bar app](app.md): the popover, the window and the shortcuts.
- [Update and migrate](upgrade.md) and [Uninstall](uninstall.md).
- [Troubleshooting](troubleshooting.md) and [First run problems](first-run-problems.md).
- [Glossary](glossary.md): bench, site, bench agent and the other words.
