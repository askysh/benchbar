---
title: "Quick start"
description: "Register a bench you already have with benchbar adopt, or install a new bench and site with benchbar install, then start it."
---

Two starting points. Pick the one that matches your Mac.

## You already have a bench

```bash
benchbar doctor --bench-dir ~/frappe-bench   # read only
benchbar adopt ~/frappe-bench                # shows its plan and asks
```

`doctor` prints `[OK]`, `[WARN]` or `[FAIL]` per check with the exact
fix. `adopt` writes only the service files (`Procfile.lean`, the runner
script, the launchd agent, the shell helpers and the hosts line) and
remembers the bench. It never runs `migrate`, `build` or `update`, and
it never touches `sites/`. When the bench uses the same ports as another
bench benchbar knows, it moves this one to the next free port block, after
asking. See [install and adopt](reference/cli/install.md#adopt).

## You have no bench yet

```bash
benchbar install
```

`install` runs three phases with a live step list: system dependencies,
bench and site, background service. It asks for two passwords, the
MariaDB root password (generated unless you set `MARIADB_ROOT_PASSWORD`,
kept in your Keychain) and the site's Administrator password (or
`ADMIN_PASSWORD`). It asks for `sudo` once, only when a step ahead needs
it: the wkhtmltopdf package and the `/etc/hosts` line.

To pick the Frappe version or the apps, pass a profile and a bundle, for
example `benchbar install --profile v16-lts --bundle common`. The choices
are in [Configuration](reference/configuration.md).

## Start it

```bash
source ~/.zshrc
benchup
open http://macdev:8000
```

Log in as `Administrator` and walk through the setup wizard. You can
close Terminal; the bench keeps running.

`macdev` is the default site name. When you picked another one, or
adopted a bench, `benchbar status` shows the site's URL.

## What next

- Learn the daily helpers in [Benches and sites](guides/benches-and-sites.md).
- Open the [menu bar app](app.md) to start, stop and check the bench with
  a click.
- Add apps with [benchbar app](guides/apps.md).
- When something looks wrong, run `benchbar doctor`: see
  [Doctor and repair](guides/doctor-and-repair.md).
