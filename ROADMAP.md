# BenchBar roadmap

Native Frappe and ERPNext dev benches on macOS, from the command line or
the menu bar. Built for Frappe and ERPNext; not affiliated with Frappe
Technologies.

## Shipped: v0.1 CLI

- Background benches under launchd, one agent per bench, no Terminal needed
- Crash guard: 3 restarts in 10 minutes, then pause and notify
- Resumes after reboot only if it was running before
- doctor and repair: missing env, missing node modules, missing built
  assets, crash looping agents, stray Redis, MariaDB bound to the network,
  CleanMyMac warnings
- Idempotent installs: re-runs only change what changed, user data never moved
- Lean Procfile (no watcher, no scheduler), benchup / benchdown /
  benchrestart / benchstatus / benchlogs / benchfg / benchwatch

## Now: v0.2 BenchBar app alpha

- Rename to BenchBar, frappe-mac alias kept, automatic migration of old agents
- Versioned JSON API: list, status, doctor, plus state.json events
- Menu bar runner that sleeps, runs, speeds up with load and stumbles on crashes
- Start, stop, restart, open site, logs and folder, read only doctor
- Crash notifications, launch at login, Reduce Motion support
- Custom runner format and 2 original built-in runners

## Next: v0.3 Daily driver

- Multiple benches in one menu, port clash detection
- Doctor with one click Repair (runs the CLI repair with live progress)
- Log viewer window with search and per process filters (web, worker, socketio)
- More speed sources: background job queue depth, requests per second
- Scheduler toggle and "run scheduler event now"
- Worker auto restart when Python files change (opt in)
- Import runners from a zip, runner gallery page in the docs

## Then: v0.4 App installs and sites

- First run setup wizard: checks Homebrew, picks a profile (v15 or v16),
  creates bench and site with live progress
- Add apps from a GitHub URL or a curated list, pick a branch, install to a site
- Update apps per bench with a changelog preview, switch branches safely
- Site management: create, drop (with backup first), set default, /etc/hosts entry
- Backups: one click backup and restore, restore a production backup into a local site
- Pull a site from a server over SSH (backup, download, restore, rename)
- Profile switching per bench (Python, Node, MariaDB versions)

## Later: v0.5 Public release

- Developer ID signing and notarization
- Sparkle auto updates
- Homebrew cask in askysh/homebrew-tap, then the official cask once eligible
- Release CI on GitHub Actions
- Docs site with install guide and troubleshooting

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

## Not planned

- Docker or VMs
- Production deployment
- Windows or Linux (the Windows / WSL path lives in its own repo:
  [askysh/frappe_wsl_dev_server](https://github.com/askysh/frappe_wsl_dev_server))
- Mac App Store distribution (the app has to be unsandboxed to run the CLI)

## Backlog

Carried over from the earlier CLI roadmap and not covered above.

- Run `mariadb-secure-installation` inline from `00-mac-system-deps.sh`
  with the answer table printed first, instead of leaving it as a manual
  step. This is the last manual step on a fresh Mac besides wkhtmltopdf.
- Install patched-Qt wkhtmltopdf by downloading the official `.pkg` with
  checksum verification and running `installer -pkg ... -target /`.
- Install `uv` before `bench init` when the installed `frappe-bench` needs it.
- Optional scheduler in the lean Procfile (`benchbar service
  --with-schedule`) for people who develop scheduled jobs.
- Log rotation for `bench.log` and the worker logs on a size limit,
  without the manual `repair` step.
- `benchbar doctor --fix-hints` for agents: print only the fix commands,
  one per line.
- More failure-path tests for bench creation and app installation.
- A `benchbar wipe` that automates the "Uninstall" recipe in the README
  behind an explicit confirmation, still never touching MariaDB data
  without a backup.
- Intel Mac verification of the CLI (the app targets Apple Silicon).
- Scope the honcho process match to one bench, so two running benches
  never see each other's honcho as their own.
