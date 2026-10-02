---
title: "Quick start"
description: "Register a bench you already have with benchbar adopt, or install a new bench and site with benchbar install, then start it."
---

First [install](install.md) BenchBar; with Homebrew that is
`brew install askysh/tap/benchbar askysh/tap/benchbar-app`. Then there
are two starting points. Pick the one that matches your Mac.

A few words first. A **bench** is the folder that holds a Frappe
installation: the apps in `apps/`, a Python environment in `env/` and
the sites in `sites/`. A **site** is one Frappe instance in that bench,
with its own database and its own address, such as `http://macdev:8000`.
benchbar runs each bench as a **launchd agent**, the macOS way of
keeping a program running in the background.

## You already have a bench

The examples use `~/frappe-bench`; put your bench's folder in its place.

```bash
benchbar doctor --bench-dir ~/frappe-bench   # read only
benchbar adopt ~/frappe-bench                # shows its plan and asks
```

`doctor` prints `[OK]`, `[WARN]` or `[FAIL]` per check, and a `fix:`
line with the exact command under every WARN and FAIL. It changes
nothing.

`adopt` writes only the service files: `Procfile.lean` (the list of
processes the bench runs), the runner script, the launchd agent, the
shell helpers and the `/etc/hosts` line for the site, then remembers the
bench. It shows this plan and waits for your yes. It never runs
`migrate`, `build` or `update`, and never touches your apps, sites or
databases. The one exception: when the bench uses the same ports as
another bench benchbar knows, the plan says so and, after asking, writes
the next free port block into `sites/common_site_config.json` (with a
backup first). The `/etc/hosts` line needs your `sudo` password once.
See [install and adopt](reference/cli/install.md#adopt).

## You have no bench yet

```bash
benchbar install
```

`install` runs three phases with a live step list: system dependencies
(Python, Node, MariaDB and Redis from Homebrew), the bench and a site,
and the background service. It asks for:

- the bench folder, `~/frappe-bench` unless you change it (or pass
  `--bench-dir`);
- the site name, `macdev` unless you change it;
- the site's Administrator password (or reads `ADMIN_PASSWORD`). You log
  in with it later.

A fresh MariaDB gets a generated root password, kept in your Keychain
(the macOS password store); set `MARIADB_ROOT_PASSWORD` to choose your
own. When MariaDB already has a root password that the Keychain does
not know, `install` asks for it once and saves it.
It asks for `sudo` once, only when a step ahead needs it: the
wkhtmltopdf package and the `/etc/hosts` line.

The first run downloads a lot and takes a while. Each step ends as
`done`, `unchanged` or `skipped`; a `failed` step stops the run, and
the full output is in `~/.local/state/benchbar/logs/` (`.benchbar/logs/`
in a git checkout of benchbar). Re-running `install` is safe: it skips
what is already done.

To pick the Frappe version or the apps, pass a profile and a bundle, for
example `benchbar install --profile v16-lts --bundle common`. The choices
are in [Configuration](reference/configuration.md).

## Start it

```bash
source ~/.zshrc
benchup
open http://macdev:8000
```

`source ~/.zshrc` loads the shell helpers such as `benchup` into this
Terminal (a new tab has them already). `benchup` starts the bench in the
background, waits for the site and ends with
`bench is up: http://macdev:8000`.

`macdev` is the default site name. When you picked another one, or
adopted a bench, `benchbar status` shows the site's URL; use that.

In the browser, log in as `Administrator` with the password you gave
`install` (or your existing one), and walk through the setup wizard. You
can close Terminal; the bench keeps running until `benchdown`.

## What next

- Learn the daily helpers in [Benches and sites](guides/benches-and-sites.md).
- Open the [menu bar app](app.md) to start, stop and check the bench with
  a click.
- Add apps with [benchbar app](guides/apps.md).
- When something looks wrong, run `benchbar doctor`: see
  [Doctor and repair](guides/doctor-and-repair.md).
