# Changelog

All notable changes to this project are documented here.

## 0.2.0 - 2026-09-23

### Added

- `frappe-mac`, a single entrypoint with `install`, `service`, `doctor`,
  `repair`, `up`, `down`, `restart`, `status`, `logs`, `fg`, `watch`,
  `autostart on|off`, `uninstall-service` and `path`. Global flags
  `--bench-dir`, `--site`, `--profile`, `--bundle`, `--dry-run`, `--yes`,
  `--json`, `--plain`.
- Background service: one launchd agent per bench
  (`com.frappe-mac.<bench>`) runs honcho with a lean Procfile (no watch,
  no schedule) through a generated runner script. The runner clears stale
  processes of this bench, refuses to start while a stop flag exists, and
  pauses auto-restart after 3 starts in 10 minutes with a macOS
  notification. The agent bakes `PATH`,
  `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` and `NO_PROXY=*`, uses
  `KeepAlive SuccessfulExit=false` and `ThrottleInterval 20`.
- honcho resolution in order: `PATH`, the pipx venv of `frappe-bench`,
  `env/bin/honcho`, then install with `uv pip` (or pip) as a last resort.
  The absolute path is stored.
- Shell helpers `benchup`, `benchdown`, `benchrestart`, `benchstatus`,
  `benchlogs`, `benchfg`, `benchwatch`, `benchdoctor`, `benchcd` in one
  marker block (`# >>> frappe-mac >>>`) that also carries the profile
  exports. Blocks are replaced in place only when both markers exist
  exactly, otherwise appended with a warning. The rc file is backed up
  first.
- `doctor`: read-only checks with `[OK]`, `[WARN]`, `[FAIL]` and the exact
  fix command, plus `--json`. Covers Homebrew formulae, the profile Python
  and `brew leaves`, `env/bin/python`, `bench version`, socket.io, the
  dist files referenced by `assets.json`, honcho, the generated files and
  their version headers, the agent state and last exit code, the stop
  flag, the shell block and old helper blocks, legacy per-process agents
  with their exit codes, MariaDB bind address, redis on 6379, site ping,
  `/etc/hosts`, log sizes, CleanMyMac, and port clashes between benches.
- `repair`: runs only the flagged fixes in dependency order (Python
  formula, env rebuild, honcho, node requirements, build, cache clearing,
  MariaDB bind, legacy agent migration, generated files, hosts entry, log
  rotation, redis prompt), with a backup or move-aside before every
  change and a verify pass afterwards.
- Template versioning: runner, plist, `Procfile.lean`, shell block and
  MariaDB drop-ins carry a `frappe-mac-template: <name> vN <hash>` header
  and are rewritten only when the rendered content changed. Previous
  copies go to `.frappe-local/backups/<timestamp>/`.
- Legacy agent migration: older per-process or hand-made agents are
  booted out and moved to `~/Library/LaunchAgents-disabled/<name>-<timestamp>/`.
- MariaDB `bind-address = 127.0.0.1` drop-in in
  `$(brew --prefix)/etc/my.cnf.d/` with the `!includedir` line ensured in
  `my.cnf`.
- TUI: tput colors with `NO_COLOR` and non-TTY fallbacks, a header box,
  a numbered step list with live status and timings, spinners with a
  rolling tail for long commands (last 40 lines and the log path on
  failure), a plan summary with confirmation, a summary table and a
  "Next steps" box. Full logs in `.frappe-local/logs/<timestamp>.log`.
- A lock directory (`.frappe-local/lock`) so two runs cannot overlap.
- `02-background-service.sh` as the phase wrapper for `frappe-mac service`.
- Mocked tests for launchctl, brew, lsof, pkill, pgrep, curl, osascript,
  bench, honcho, uv, pipx and sudo, covering install run twice, legacy
  migration, every doctor detection, the crash guard, scoped stop,
  dry-run, marker blocks and the phase scripts. shellcheck runs on every
  script.
- `AGENTS.md` with guidance for AI coding agents.

### Changed

- `00-mac-system-deps.sh` now writes the shell block and the utf8mb4
  MariaDB drop-in itself (with backups) instead of printing them as
  manual steps, installs formulae behind a spinner, and exits with code 2
  while manual steps remain.
- `01-install-bench-and-site.sh` refuses to move a bench that has apps or
  sites aside and points to `frappe-mac repair` instead, asks for the two
  passwords only when the site must be created, resolves the bench
  directory to an absolute path (default `~/frappe-bench`), records the
  bench and site in `.frappe-local/state.env`, and runs `get-app`,
  `new-site` and `install-app` behind a spinner.
- Status lines print `[OK]`, `[WARN]`, `[FAIL]` in brackets.
- README rewritten around `frappe-mac install` and the daily helpers.

### Fixed

- The `/etc/hosts` check matched only lines with two spaces after the
  address; it now matches any whitespace.

## Unreleased (before 0.2.0)

### Added

- Added preflight checks for running as a normal user, available disk space, and internet access.
- Added a timeout guard around `bench init`.
- Added handling for background commands that stop while waiting for terminal input.
- Added safe reuse guidance when an existing MariaDB/MySQL service is detected on port `3306`.
- Added README status badges.
- Added a roadmap file.

### Changed

- Rewrote README as a phased beginner walkthrough. Advanced flags moved after the happy path.
- Refreshed roadmap: the WSL/Windows path now lives in [askysh/frappe_wsl_dev_server](https://github.com/askysh/frappe_wsl_dev_server).

## 0.1.0 - 2026-04-25

### Added

- Initial public macOS Frappe/ERPNext local installer.
- Added profile-driven system dependency setup.
- Added bench and site setup with public app bundles.
- Added local shell tests with mocked `bench` and `git` behavior.
