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

**0.4, Frappe v16 and more than one bench.** The v16 profile tested end to
end on a real Mac, one MariaDB server shared by every bench, several
benches side by side with their own port blocks, settings and processes,
sites (`site add`, `site default`, `site hosts`), the scheduler opt in,
doctor checks from the community threads (Full Disk Access, the toolchain
as the bench sees it, honcho without `pkg_resources`, stale processes),
and the app with a bench list, the worst state in the menu bar and the
sites of each bench.

## Next: 0.5, the app does more, apps and team profiles

A bigger release: the app work, and everything a team needs to share one
way of setting up benches.

- Repair from the app: the plan in a sheet, then a live step list, from
  `benchbar repair --json`, which streams one event per line.
- A log viewer window: follow with smart scroll, search, a filter per
  process (web, worker, socketio, schedule, redis), errors tinted, the
  previous log one click away.
- `benchbar mcp`: a Model Context Protocol server over stdio, so coding
  agents can list benches, read status, doctor and logs, and start, stop
  or restart a bench. Nothing that repairs, installs or needs `sudo`.
- App installs: `benchbar app list`, `app add` from the app registry or
  any GitHub repo, public or private (SSH keys and host aliases),
  `app install` on a site, and `app update` for one app with a changelog
  preview and a backup before `migrate`. Never `bench update`.
- Team profiles: an org's recipe (base profile, apps with repos and
  branches, site defaults) in a TOML file on the Mac or in the team's own
  config repo, never in BenchBar's code. `benchbar profile create NAME
  --from-bench PATH` turns an existing bench into one, and
  `benchbar install --profile NAME` uses it like a built in profile.
- A team lockfile, `benchbar.toml`, pinning the profile, bench and app
  branches or commits: `benchbar lock write`, `lock check` (also in
  doctor) and `lock apply`, so teammates get identical benches.
- `benchbar pull`: a production site into a new local site over SSH. It
  uses the latest backup on the server unless asked to take one, carries
  the encryption key over without printing it, brings missing apps in at
  the production branch first, and mutes email and the scheduler on the
  copy.

## Later

**0.6, public launch.** Developer ID signing and notarization, a signed
DMG, a cask in `askysh/homebrew-tap`, Sparkle updates, a documentation
site, and a launch post on discuss.frappe.io.

**0.7, the app for sites and apps.** Backup and restore from the app,
dropping a site with a backup first, app installs, team profiles and
pulls in the app, a first run wizard, profile switching per bench.

**1.0.** A stable JSON API and runner format, an official Homebrew cask,
full doctor coverage for v15 and v16.

## Ideas

Not scheduled, kept because they came up more than once.

- A URL scheme for Raycast and Shortcuts, then Shortcuts actions, a
  Raycast extension, desktop widgets.
- Open a bench in VS Code or Cursor, open a bench console.
- A local mail catcher for development email.
- Resource graphs per bench.
- Run one scheduler event now from the app.
- Worker restart when Python files change, opt in.
- More speed sources for the runner: job queue depth, requests per second.
- A runner gallery in the docs.
- Log rotation on a size limit without a manual `repair`.
- `benchbar doctor --fix-hints` for agents: only the fix commands, one per
  line.
- More failure path tests for bench creation and app installation.
- `benchbar wipe`, the uninstall recipe behind an explicit confirmation,
  never touching MariaDB data without a backup.
- Intel Mac verification of the CLI.

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
