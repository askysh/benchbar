# Changelog

All notable changes to this project are documented here.

## 0.3.0 - 2026-09-24

The project is now **BenchBar**: the `benchbar` command line tool, plus a
native menu bar app. Built for Frappe and ERPNext on macOS; not
affiliated with Frappe Technologies.

### Added

- **BenchBar.app** (`macos/`, macOS 14+, Apple Silicon), built from the
  command line with `scripts/macos-build.sh` and installed with
  `scripts/macos-install-local.sh`:
  - an animated menu bar runner per state (sleeping, walking, running,
    stumbling, alert, question), one Core Animation keyframe animation,
    tinted for light, dark and the transparent menu bar;
  - running speed from the CPU use of the bench's process tree (libproc,
    every 2 seconds, smoothed), behind a `SpeedSource` protocol;
  - Reduce Motion support, and pausing on sleep, screen sleep, lock and
    user switching;
  - a popover with state, uptime, Start, Stop, Restart, open site, logs
    (Terminal) and folder, a read only doctor, a bench picker, repair
    hints and keyboard shortcuts;
  - a Settings window: runner picker with live preview, speed toggle,
    launch at login (`SMAppService`), notifications, CLI path;
  - notifications on crash, crash guard pause and recovery;
  - two original built in runners (a bench and a coffee cup) and custom
    runners: a folder with `manifest.json` and PNG frames, imported from
    a folder or zip with strict validation (`docs/runners.md`,
    `examples/runners/blob`).
- Versioned JSON API (`schema_version: 1`): `benchbar list --json`,
  `status --json`, `doctor --json`, and `<bench>/logs/.benchbar/state.json`
  written atomically by the runner on every transition
  (`docs/json-schema.md`).
- `stop_reason: "broken"` for a bench that cannot start until `repair`.
- Release plumbing, documented and not yet live (no Apple Developer
  account): Developer ID signing, notarization, DMG, Sparkle 2 behind a
  build flag, a Homebrew cask template and a guarded GitHub Actions
  workflow (`docs/releasing.md`).

### Changed

- The CLI is `benchbar`; `frappe-mac` stays as a link to it.
- Agents are `com.benchbar.<bench>` and carry
  `AssociatedBundleIdentifiers` so Login Items shows them under BenchBar.
  `benchbar repair` migrates `com.frappe-mac.<bench>` agents (only for
  this bench), restarting the bench if it was running. Old plists move to
  `~/Library/LaunchAgents-disabled/<timestamp>/`.
- `up`, `down` and `restart` on a bench that still has its old agent now
  say so and point at `benchbar repair`, instead of "not installed".
- The runner runs honcho as a child, forwards SIGTERM and records the
  final state; a SIGTERM without a stop flag is a clean stop. Its
  osascript crash notification stays as a fallback and is skipped while
  BenchBar runs.
- `status --json`: `state` is now the contract value (stopped, starting,
  running, crashed, paused); launchd's word moved to `agent_state`.
- README, AGENTS.md and the roadmap describe BenchBar and the new repo URL,
  github.com/askysh/frappe-mac-dev-server.

### Fixed

- Reading a missing stop flag no longer prints "No such file or
  directory".

## 0.2.0 - 2026-09-23

### Added

- `frappe-mac`, a single entrypoint (also linked into `~/.local/bin`) with `install`, `service`, `doctor`,
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
