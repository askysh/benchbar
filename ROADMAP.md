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

**0.5, the app does more, apps and team profiles.** The BenchBar window
with a page per bench (sites, apps, doctor and Repair with its plan
first), a log window, `benchbar repair --json`, `benchbar mcp` for coding
agents, app installs and updates from the registry or any GitHub repo
(private ones too), team profiles kept outside BenchBar, the
`benchbar.toml` team lockfile, `benchbar pull` for a production copy
with the encryption key carried over and email and the scheduler off, a
new app icon, and the macOS 27 look.

**0.5.5, the project skin.** The documentation site at
benchbar.akashmishra.com with a page per command, a short README, the
community files (contributing with an AI policy, code of conduct,
security policy, issue forms), and in the app an About pane with an
update check, a Help menu and Report a Bug; `benchbar docs` and doctor
links into the docs.

**0.5.6, cleanup tools.** Doctor warns about Mole until the bench is in
its whitelist, finds CleanMyMac installed from Setapp, and no longer
flags the installer's PATH block.

**0.5.7, find your benches.** Scan Folder in the menu bar and Find
Benches in the app find existing benches in a folder, remember the ones
you pick, and set up their service after showing the plan.

**0.5.8, quick wins.** `benchbar://` links for Raycast and Shortcuts,
CPU and memory charts per bench, site backup, backups and drop with a
backup first, the lockfile badge, Open in VS Code or Cursor, `benchbar
console` and `db`, `doctor --fix-hints`, and port blocks planned across
benches with a check before every start.

**0.6, sharing profiles between teams.** `benchbar profile export` writes
a portable copy (SSH host aliases resolved, each app on its repo's
default branch after a review, public, private and personal repos
marked, the apps each one requires listed), `profile import` takes a
file or an https URL and checks access to every repo first, `profile
subscribe` follows a team's config repo with an outdated warning instead
of silent pulls. Doctor warns when an app your work depends on falls
behind, never about the app you are working on. The app checks for
updates once a day and updates in one click, the CLI with `benchbar
self-update`.

## Later

**0.7, public launch.** Developer ID signing and notarization, a signed
DMG, a cask in `askysh/homebrew-tap`, Sparkle updates, and a launch post
on discuss.frappe.io. Moved from 0.6 while the Apple developer account
is approved.

**0.8, the app for sites.** Restore from the app (backup and drop
shipped in 0.5.8), pull and lock apply in the app, a first run wizard,
new bench from a profile.

**1.0.** A stable JSON API and runner format, an official Homebrew cask,
full doctor coverage for v15 and v16. Vouch
([github.com/mitchellh/vouch](https://github.com/mitchellh/vouch)) when
drive-by PRs appear. Not before.

## Ideas

Not scheduled, kept because they came up more than once.

- Shortcuts actions, a Raycast extension, desktop widgets (the URL scheme
  shipped in 0.5.8).
- A local mail catcher for development email.
- Run one scheduler event now from the app.
- Worker restart when Python files change, opt in.
- More speed sources for the runner: job queue depth, requests per second.
- A runner gallery in the docs.
- Log rotation on a size limit without a manual `repair`.
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
