---
title: "Doctor checks: the system"
description: "The doctor checks of the system group: Homebrew formulae, MariaDB config, the PDF engine, Redis, the WSL clock, cleanup tools and Full Disk Access. What each looks at and its fix."
---

Part of the [doctor checks](../doctor-checks.md). `benchbar doctor` prints the id of a check, and each id below is a heading you can link to. How to read the report is in [Doctor and repair](../../guides/doctor-and-repair.md).

## System checks

### brew

The Homebrew formulae of the bench's profile are installed: the Python,
Node and MariaDB formulae, and `redis`. A missing one fails. The build
formulae `pkgconf` and `mariadb-connector-c` (needed to build
`mysqlclient` for frappe v16) are a warning when missing.

Fix: install Homebrew from <https://brew.sh> when it is missing; run
`00-mac-system-deps.sh --profile <profile>` from the checkout for missing
formulae, or `brew install pkgconf mariadb-connector-c` for the build
formulae. When only the profile's Node formula is missing (the profile
moved to a newer Node), `benchbar repair` installs it.

### formula_dates

Homebrew deprecates a formula about a year before it disables it, and a
disabled formula can no longer be installed, so a fresh install and every
`brew install` fix of the profile fail from that day. This check reads the
dates of the profile's Python, Node and MariaDB formulae from the local
tap (`brew info --json`, no network): a WARN within 90 days of a disable
date, a FAIL once it has passed or once Homebrew no longer knows the
formula.

Fix: update BenchBar (`brew upgrade benchbar`, or Check for Updates in the
app); a newer profile names the current formulae, and `benchbar repair`
then moves the bench to them. A bench keeps the formulae it has.

### python_leaves

The profile's Python (for example `python@3.11`) exists, has the version
the profile expects, and was installed on request, so `brew autoremove`
cannot delete it.

Fix: `brew install` or `brew reinstall` the formula when it is missing or
the wrong version. When it is only a dependency, repair marks it installed
on request (`brew tab --installed-on-request <formula>`).

### mariadb_bind

MariaDB listens on 127.0.0.1 only, or, when it is not running, the
bind address drop-in `frappe-mac-local-only.cnf` exists. A server
reachable from the network is a warning.

Fix: `benchbar repair` writes the drop-in into
`$(brew --prefix)/etc/my.cnf.d/` and restarts MariaDB when it is
running. Every bench on this Mac shares that server, so running benches
lose their database for a few seconds; stop them first, or repair when
nothing is mid request.

### mariadb_utf8

The utf8mb4 drop-in `frappe.cnf` in `$(brew --prefix)/etc/my.cnf.d/` is
current, and `my.cnf` includes that folder. Frappe needs utf8mb4 server
wide. A drop-in written by someone else that sets utf8mb4 is accepted and
left alone. Doctor reads the files only; it never logs in to MariaDB.

Fix: `benchbar repair` writes the drop-in and the `!includedir` line,
then restarts MariaDB when it is running and the drop-in changed. As
with `mariadb_bind`, every running bench loses its database for a few
seconds.

### pdf_engine

wkhtmltopdf is the patched Qt build, the one Frappe needs for PDFs, and
no unpatched Homebrew `wkhtmltopdf` comes first on `PATH`. On a v16
profile it also says whether the Chromium that Print Formats set to
"chrome" use has been downloaded.

Fix: `benchbar repair` installs the official patched package (with
`sudo`). A shadowing Homebrew build: `brew uninstall wkhtmltopdf`. The v16
Chromium: `cd <bench> && bench setup-chrome`.

### redis_6379

Nothing listens on port 6379. The bench runs its own Redis on its port
block, so a Homebrew Redis on 6379 is unused. `install` installs the
`redis` formula but does not start its service (0.9.0), so this warning
comes from a Redis someone else started, or from a Mac installed by an
older version.

Fix: `brew services stop redis`, only if nothing else on this Mac needs
it. `benchbar repair` offers the same and asks first; under `--yes` it
leaves Redis running and prints the command.

### wsl_time_sync

Linux in WSL only; it is left out elsewhere. Two clocks set the time of a
WSL distro: the Windows host (Hyper-V time sync) and NTP inside the distro
(`systemd-timesyncd`). Windows syncs its own clock about once a week; while
it is off from NTP by more than a fraction of a second, every NTP poll
(about every 32 seconds) steps the clock back. A step can end the worker's
blocking Redis wait, and then the whole bench stops and restarts. The host
sync cannot be turned off from inside WSL, so NTP in the distro is the one
to turn off. The check is OK when `timedatectl show -p NTP --value` says
`no` or `timedatectl` is missing, and a warning when it says `yes`.

Fix: `sudo timedatectl set-ntp false`. Repair does not run it, because
`sudo` on Linux is kept for apt, the wkhtmltopdf package and MariaDB.

### cleanmymac

CleanMyMac is not installed in `/Applications` or `~/Applications`, or in
the `Setapp` folder inside either. Its cleanup can delete `env/`,
`node_modules` and `public/dist`.

Fix: in CleanMyMac, add the bench folder to the Ignore List before
running any cleanup.

### mole

Mole (`mo`) is not installed, or the bench is protected in its whitelist.
`mo purge` looks for projects under `~/dev` and similar folders and
deletes their `node_modules` and `dist` folders and any folder with a
`CACHEDIR.TAG`, which includes the bench's `env/`. It skips any path in
`~/.config/mole/whitelist` and everything below it, so the check passes
when a line there is the bench folder or a folder above it. Lines with
`*`, `?` or `[` are not read.

Fix: when `~/.config/mole/whitelist` does not exist yet, first run
`mo clean --whitelist` and save once: a whitelist file replaces Mole's
built in entries, and its editor writes them into the new file. Then
add the bench folder, with your bench's path in place of `<bench>`:
`echo '<bench>' >> ~/.config/mole/whitelist`.

### app_copies

At most one `BenchBar.app`, in `/Applications` or `~/Applications`. Two
copies, typically Homebrew's cask in `/Applications` and the one line
installer's in `~/Applications`, share one bundle id, so macOS may open
either, and the login item and the updater may each pick a different one.

Fix: quit BenchBar and move the copy you do not use to the Trash. With
Homebrew's cask `benchbar-app` installed, that is the one in
`~/Applications`. `benchbar repair` never deletes an app.

### full_disk_access

`crontab` is readable. Without Full Disk Access for the Terminal, `bench
init` and `bench setup backups` fail with "Operation not permitted". Not
checked when BenchBar runs doctor, since the permission belongs to the
Terminal that runs `bench`.

Fix: System Settings > Privacy & Security > Full Disk Access: add
Terminal (or the app that runs benchbar), then open a new window.
