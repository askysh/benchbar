---
title: "BenchBar on Linux"
description: "Start here on Linux: what you need, the one line installer, how a bench runs under systemd, and where to go next."
---

On Linux you get the `benchbar` command line tool. Each bench runs as a
`systemd --user` unit, so it keeps running after you close the terminal.
Ubuntu 24.04 is the tested system. WSL counts as Linux.

## What you need

- An x86_64 or arm64 PC with systemd.
- A user that can run `sudo`. Do not run the installer as root.
- About 5 GB of free disk.

Run `benchbar doctor --prerequisites` first. It checks what it can and
changes nothing.

## Install

```bash
curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash
```

Open a new terminal, run `benchbar install` and open
`http://linuxdev.localhost:8000`. The details are in
[Install: Linux](install.md#linux).

## Next

- [Quick start](quick-start.md): the first ten minutes.
- [Update and migrate](upgrade.md) and [Uninstall](uninstall.md).
- [Troubleshooting](troubleshooting.md) and [First run problems](first-run-problems.md).
- [Glossary](glossary.md): bench, site, bench agent and the other words.
