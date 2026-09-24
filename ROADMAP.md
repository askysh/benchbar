# BenchBar roadmap

Native Frappe and ERPNext dev benches on macOS, from the command line or
the menu bar. Built for Frappe and ERPNext; not affiliated with Frappe
Technologies.

## v0.1 CLI: shipped

- Background benches under launchd, one agent per bench, no Terminal needed
- Crash guard: 3 restarts in 10 minutes, then pause and notify
- Resumes after reboot only if it was running before
- doctor and repair: missing env, missing node modules, missing built
  assets, crash looping agents, stray Redis, MariaDB bound to the network,
  CleanMyMac warnings
- Idempotent installs: re-runs only change what changed, user data never moved
- Lean Procfile (no watcher, no scheduler), benchup / benchdown /
  benchrestart / benchstatus / benchlogs / benchfg / benchwatch

## v0.2 BenchBar app alpha: shipped

- Rename to BenchBar, frappe-mac alias kept, automatic migration of old agents
- Versioned JSON API: list, status, doctor, plus state.json events
- Menu bar runner that sleeps, runs, speeds up with load and stumbles on crashes
- Start, stop, restart, open site, logs and folder, read only doctor
- Crash notifications, launch at login, Reduce Motion support
- Custom runner format and 2 original built-in runners

## v0.3 Easy install: this release

- `benchbar report`: a redacted diagnostics zip for bug reports
- CI on GitHub Actions: shellcheck, the CLI tests on macOS and Linux, the
  app build and Swift tests, an unsigned app bundle on every pull request
- The manual install steps automated: MariaDB root password set in SQL
  and kept in the Keychain, the secure installation steps, the utf8mb4
  drop-in, the patched Qt wkhtmltopdf package (pinned, sha256 checked,
  Rosetta 2 offered), the `/etc/hosts` line inside markers, one sudo
  prompt per run
- `benchbar adopt`: register an existing bench without touching its data
- One line installer (`install.sh`): CLI, app from the latest release,
  then adopt or install; `--uninstall`
- Unsigned (ad hoc signed) releases built by CI as drafts: zip, DMG,
  SHA256SUMS, release notes from the CHANGELOG; the same workflow signs
  and notarizes once a Developer ID exists
- Tester guide (`docs/testing.md`)

## v0.4 v16 and daily driver

- Frappe v16 profile tested end to end (Python 3.14, Node 24,
  MariaDB 11.8), with a v16 row in CI
- Multi bench menu polish and port clash detection
- Doctor with one click Repair in the app (runs the CLI repair with live
  progress)
- Log viewer window with filters: search, per process (web, worker,
  socketio)
- Scheduler toggle and "run scheduler event now"; optional scheduler in
  the lean Procfile (`benchbar service --with-schedule`)
- Worker auto restart when Python files change (opt in)
- More speed sources for the runner: background job queue depth,
  requests per second
- Import runners from a zip, runner gallery page in the docs

## v0.5 Public launch

- Apple Developer ID signing and notarization
- Signed DMG, a cask in askysh/homebrew-tap
- Sparkle auto updates
- Docs site with install guide and troubleshooting
- Launch post on discuss.frappe.io with the runner GIF

## v0.6 Sites and apps

- Pull a production site into a local bench over SSH (backup, download,
  restore, rename)
- One click backup and restore, restore a production backup into a local
  site
- App installs from GitHub with branch picking, from a URL or a curated
  list; app updates per bench with a changelog preview, switch branches
  safely
- Site management: create, drop (with backup first), set default,
  `/etc/hosts` entry
- First run setup wizard in the app: checks Homebrew, picks a profile
  (v15 or v16), creates bench and site with live progress
- Profile switching per bench (Python, Node, MariaDB versions)

## v1.0

- Stable JSON API and runner format
- Official Homebrew cask
- Full doctor coverage for v15 and v16

## Ideas

- Open in VS Code or Cursor, open a bench console
- Local mail catcher for dev emails
- Resource graphs per bench
- Shortcuts actions, a Raycast extension, desktop widgets
- MCP server so coding agents can check status, read logs and restart benches
- Install `uv` before `bench init` when the installed `frappe-bench` needs it
- Log rotation for `bench.log` and the worker logs on a size limit,
  without the manual `repair` step
- `benchbar doctor --fix-hints` for agents: print only the fix commands,
  one per line
- More failure-path tests for bench creation and app installation
- A `benchbar wipe` that automates the "Uninstall" recipe in the README
  behind an explicit confirmation, still never touching MariaDB data
  without a backup
- Intel Mac verification of the CLI (the app targets Apple Silicon)
- Scope the honcho process match to one bench, so two running benches
  never see each other's honcho as their own

## Not planned

- Docker or VMs
- Production deployment
- Windows or Linux (the Windows / WSL path lives in its own repo:
  [askysh/frappe_wsl_dev_server](https://github.com/askysh/frappe_wsl_dev_server))
- Mac App Store distribution (the app has to be unsandboxed to run the CLI)
