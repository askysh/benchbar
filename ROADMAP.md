# Roadmap

Where BenchBar is and where it goes. Versions below 1.0 may change the
JSON API and the runner format; 1.0 freezes both. Dates are not promised.
Ideas are welcome as issues.

## Released

**0.1, the CLI.** Benches under launchd with one agent each, a crash
guard (three restarts in ten minutes, then pause and notify), resume
after reboot only when the bench was running, doctor and repair for the
common breakages (missing env, node modules or built assets, crash
looping agents, a stray Redis, MariaDB bound to the network, CleanMyMac),
idempotent installs, the lean Procfile and the `bench*` helpers.

**0.2, the menu bar app.** The rename to BenchBar with the `frappe-mac`
alias kept and old agents migrated, a versioned JSON API, the animated
runner that sleeps, runs, speeds up with load and stumbles on crashes,
start, stop, restart, site, logs and a read only doctor from the popover,
crash notifications, launch at login, Reduce Motion, custom runners.

**0.3, easy install.** The one line installer, the manual install steps
automated (MariaDB root password in the Keychain, the secure installation
in SQL, the utf8mb4 drop-in, the pinned and checksummed wkhtmltopdf with
Rosetta offered, the `/etc/hosts` line inside markers, one `sudo` prompt
per run), `benchbar adopt` for existing benches, `benchbar report` for
redacted bug reports, CI on macOS and Linux, unsigned releases built as
drafts from a tag.

## Next: 0.4

- Frappe v16 profile tested end to end (Python 3.14, Node 24, MariaDB 11.8),
  with a v16 row in CI.
- Repair from the app: doctor with a one click Repair that runs the CLI
  with live progress.
- A log viewer window with search and a per process filter (web, worker,
  socketio).
- Scheduler support: an optional scheduler in the lean Procfile
  (`benchbar service --with-schedule`) and "run a scheduler event now".
- Worker restart when Python files change, opt in.
- Multi bench polish in the menu, and port clash detection.
- More speed sources for the runner: job queue depth, requests per second.
- Runner import from a zip, and a runner gallery in the docs.

## Later

**0.5, public launch.** Developer ID signing and notarization, a signed
DMG, a cask in `askysh/homebrew-tap`, Sparkle updates, a documentation
site, and a launch post on discuss.frappe.io.

**0.6, sites and apps.** Pull a production site into a local bench over
SSH (backup, download, restore, rename), backup and restore from the app,
app installs from GitHub with branch picking and per bench updates with a
changelog preview, site management (create, drop with a backup first,
default site, hosts entry), a first run wizard in the app, profile
switching per bench.

**1.0.** A stable JSON API and runner format, an official Homebrew cask,
full doctor coverage for v15 and v16.

## Ideas

Not scheduled, kept because they came up more than once.

- Open a bench in VS Code or Cursor, open a bench console.
- A local mail catcher for development email.
- Resource graphs per bench.
- Shortcuts actions, a Raycast extension, desktop widgets.
- An MCP server so coding agents can check status, read logs and restart
  benches.
- Install `uv` before `bench init` when the installed `frappe-bench`
  needs it.
- Log rotation on a size limit without a manual `repair`.
- `benchbar doctor --fix-hints` for agents: only the fix commands, one per
  line.
- More failure path tests for bench creation and app installation.
- `benchbar wipe`, the uninstall recipe behind an explicit confirmation,
  never touching MariaDB data without a backup.
- Intel Mac verification of the CLI.
- Scope the honcho process match to one bench, so two running benches
  never see each other's honcho.

## Not planned

- **Docker or VMs.** A bench runs natively: Python, Node, MariaDB and
  Redis from Homebrew, the processes under launchd. File watching,
  `bench build` and debugging are faster than through a VM, there is no
  Docker Desktop license or memory overhead, and the setup matches what
  most Frappe developers run on Linux.
- **The Mac App Store.** App Store apps run in the App Sandbox, and a
  sandboxed app cannot run the CLI, start launchd agents or read a bench
  in your home folder. BenchBar ships as a signed, notarized download and
  a Homebrew cask instead.
- **Production deployment.** BenchBar is for development benches.
- **Windows or Linux.** The Windows and WSL path lives in
  [askysh/frappe_wsl_dev_server](https://github.com/askysh/frappe_wsl_dev_server).
