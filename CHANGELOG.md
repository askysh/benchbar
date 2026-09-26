# Changelog

All notable changes to this project are documented here.

## Unreleased

### Repo

- `CONTRIBUTING.md`: the tests, bash 3.2 and shellcheck, idempotency,
  what a pull request needs (small, CHANGELOG, DECISIONS, tested on) and
  the AI policy. README's Contributing section now points to it.
- `CODE_OF_CONDUCT.md` (Contributor Covenant 3.0) and `SECURITY.md`
  (private vulnerability reports, what counts, latest release supported).
- Issue forms for bugs (macOS, version, install method, profile, the
  `benchbar report` zip, doctor output) and features, blank issues off
  with a link to Discussions Q&A, a pull request template with an AI
  disclosure line, `CODEOWNERS`, Dependabot for Actions and Swift, and a
  commented out `FUNDING.yml`.
- `docs/images/social-preview.png` and `docs/images/og-image.png`, drawn
  by `scripts/social-preview.swift` from the icon, the light popover and
  the runner frames.
- ROADMAP: Vouch under 1.0, once drive-by pull requests appear.

### Docs

- **A docs site** at <https://benchbar.akashmishra.com>: Astro Starlight
  in `site/`, built with Bun from the markdown in `docs/`, with search,
  dark mode that follows the system, an edit link and the last updated
  date on every page. Start (Introduction, Install, Quick start, The menu
  bar app), Guides (Benches and sites, Apps, Doctor and repair, Teams,
  Coding agents and MCP), a CLI reference with one page per command group
  (flags, exit codes, an example each), Configuration, and the existing
  JSON schema, Runners, Troubleshooting, Decisions, Releasing and Testing
  pages. `ROADMAP.md` and `CONTRIBUTING.md` stay at the repo root and
  appear as `/roadmap/` and `/contributing/`.
- Every paragraph of the old README now lives in `docs/`, rewritten into
  those pages.
- `docs/guides/doctor-and-repair.md` has a `### <check_id>` heading for
  every doctor check, with what it checks and its fix, so
  `/guides/doctor-and-repair/#<check_id>` links land on the right check.
- Every markdown file in `docs/` has `title` and `description`
  frontmatter; the duplicate `# ` headings are gone.
- `.github/workflows/docs.yml` builds the site and checks its links on
  every pull request, and deploys it to GitHub Pages on a push to `main`
  that changed the docs. `tests/test-docs.sh` checks that every doctor
  check id has its heading, that every flag in the CLI reference exists in
  `benchbar --help`, and that every page has its frontmatter.
- CI skips the CLI and app jobs when a change touches only `docs/` or
  `site/`.

### Readme

- README rewritten as the front door: logo and popover in light and dark,
  why, install, quick start, eight features and links into the new
  documentation site, about 800 words instead of 3,200. Everything it no
  longer says lives in the docs.

## 0.5.0 - 2026-09-26

BenchBar grows from a start and stop button into the place you run your
benches from: a window with every bench's sites, apps and health, Repair
from the app, a log window, apps from any GitHub repository (private
ones too), team profiles and a lockfile for the whole team, `benchbar
pull` for a production copy, and `benchbar mcp` for coding agents. A new
app icon, and the window uses the macOS 27 tab style and Liquid Glass
buttons (older macOS versions get the classic look).

### Added: the app

- **The BenchBar window** replaces the sparse Settings window: General,
  Menu Bar, Team Profiles and About, then a page per bench with Overview
  (actions, ports, the scheduler), Sites (add a site with its
  Administrator password, make one the default, the hosts fix), Apps (add
  from the registry or any GitHub URL, public or private, install on a
  site, update after a changelog preview) and Health (doctor, and Repair
  with the plan first and a live step list). The popover links into it
  (⌘M) and offers Repair when doctor found something repairable.
- A new app icon: the menu bar runner, a park bench on the run, drawn
  for Icon Composer (`macos/BenchBar/Resources/AppIcon.icon`,
  `scripts/app-icon.py`).

- A log window per bench (⌘L): follows `logs/bench.log` with smart
  scroll, search with a match count and next and previous (⌘G, ⇧⌘G), a
  filter per honcho process, errors and tracebacks in red, the previous
  log, clear, select and copy, and Open in Terminal. It survives the
  runner's log rotation and keeps at most 5000 lines.

### Added: the command line

- `benchbar mcp`: a Model Context Protocol server on stdio (stdlib only
  Python) with `benchbar_list`, `benchbar_status`, `benchbar_doctor`,
  `benchbar_logs_tail`, `benchbar_site_list`, `benchbar_up`,
  `benchbar_down` and `benchbar_restart`, each backed by the CLI's JSON.
- `benchbar logs --json` with `-nN` and `--process NAME`.
- `benchbar repair --json` streams a plan, a step event per action and a
  done event with the exit code; `--dry-run --json` prints only the plan.

- App commands. `benchbar app list [--json] [--no-sites]` shows every
  app with its branch, commit, local changes, shallow clone, version,
  the `apps.tsv` branch and the sites that have it (read with
  `bench list-apps`, cached per bench). `app add NAME|URL` gets an app
  from `config/apps.tsv` or any git URL (GitHub over HTTPS, SSH, or an
  SSH host alias from `~/.ssh/config`), with `--branch`, `--name`, and
  `--site S` or `--all-sites`: it checks access first with a git that
  never prompts, so a missing key or token fails in a second with a fix
  line, clones with `bench get-app --skip-assets` (never `--overwrite`
  or `--resolve-deps`), clones the `required_apps` of `hooks.py` after
  a second plan, installs on the sites, builds once and restarts a
  running bench. A half finished clone moves to the backups. `app
  install NAME --site S` installs an app the bench has. `app update
  NAME` fetches, shows the changelog, backs up every site that has the
  app, fast forwards, runs requirements, migrate and build; it refuses
  a dirty tree, a detached HEAD or a diverged branch, and on a failure
  prints (never runs) the way back. `app update --dry-run --json` is the
  plan for the app.
- Doctor checks `apps_txt` (an `apps.txt` line without its folder
  fails, a git app missing from `apps.txt` warns) and
  `app_branch_policy` (an app off its `apps.tsv` branch warns). Both
  read only local files and git; `repair` has no action for them.
- Team profiles: an organisation's bench recipe in a TOML file outside
  BenchBar, in `~/.config/benchbar/profiles/NAME.toml` or a folder on
  `BENCHBAR_PROFILE_PATH` (a clone of the team's config repo). It names
  a built in `base` for Python, Node and MariaDB, an optional
  `frappe_branch`, a `bundle` or `[[apps]]` with repo, branch and an
  optional commit, and optional `site` and `scheduler`. `benchbar
  install --profile NAME` uses it, and the bench keeps following it.
  `benchbar profile list [--json]`, `profile show NAME` and `profile
  create NAME --from-bench PATH [--dir DIR]` (reads a bench, never
  writes a credential or a commit). A team profile may not shadow a
  built in one.
- The team lockfile `benchbar.toml`: every app's repo, branch and
  commit in `apps.txt` order, and each site with its apps, in the same
  strict TOML subset. `benchbar lock write` writes it from the bench
  (refuses local changes or a detached HEAD unless `--allow-dirty`,
  `--no-commits` for branches only, shows the diff, backs up the old
  file), `lock check [--json]` reports drift (13 kinds, from a missing
  app to a site without an app) with no network or database, and `lock
  apply` clones missing apps, switches clean apps to the locked branch
  and fast forwards to pinned commits, then runs requirements and
  build. It never touches a site, never resets local work (ahead,
  diverged and dirty apps are skipped), and prints the site steps to run
  by hand. `--lock PATH` (remembered per bench) or `BENCHBAR_LOCK`
  points at a file kept in the team's app. Doctor gains `lock_parse`
  and `lock_drift`; `list --json` gains `benches[].lock_file`.
- Access checks before cloning (phase 01 and `app add`) run git with
  `GIT_TERMINAL_PROMPT=0` and SSH in batch mode, so a private repo fails
  at once instead of waiting on a prompt.

### Added: pull

- `benchbar pull HOST:SITE --as NAME` copies a production site over SSH
  into a new local site. It uses the latest backup that already exists on
  the server, so a plain pull writes nothing there; `--new-backup` runs
  `bench backup` first, after the production site name is typed (or
  given with `--confirm-site`), because that also deletes older backups
  on the server. The download resumes (`rsync --partial`, `scp` when the
  server has no rsync) into `<bench>/.benchbar/pulls/`, mode 0700.
- The copy keeps its stored passwords: the production `encryption_key` is
  written into the new site config through stdin and never shown or
  logged, and a probe counts the encrypted rows that decrypt. Encrypted
  backups are decrypted locally with `gpg --passphrase-fd 0`.
- Before the restore, pull compares the production apps with the bench
  and stops with the `bench get-app` commands when one is missing
  (`--skip-app APP` restores without it and says what that leaves
  behind), and stops when production frappe is newer than the bench.
- After the restore: `mute_emails`, `pause_scheduler` and
  `disable-scheduler` (unless `--keep-scheduler`), `host_name`, the
  removal of skipped apps, `bench migrate` when the apps differ,
  `clear-cache`, an optional Administrator password (`ADMIN_PASSWORD` or
  a prompt, on stdin), the hosts line, and a verify pass.
- `--replace` restores over an existing local site after a
  `bench backup --with-files` of it; `--from-dir DIR` restores a backup
  set downloaded by hand (Frappe Cloud); `--dry-run` connects read only
  and prints the plan; `--json` streams `plan`, `gate`, `progress`,
  `step` and `done` events (docs/json-schema.md).

### Changed

- The window's settings panes are laid out like System Settings: a
  header per pane, Startup, Notifications, Command line tool and
  Keyboard shortcuts on General, a runner preview on Menu Bar. The
  sidebar's benches have a context menu (start, stop, restart, open,
  show, copy path).
- `app add URL` for an app in `config/apps.tsv` follows its branch there
  when the repository has it, instead of the repository's default
  branch, so doctor does not warn about an app it just added. Raven's
  registry entry points at `github.com/frappe/raven`.
- `bench new-site` gets the MariaDB root and Administrator passwords on
  stdin, never in its arguments.
- CI runs the CLI tests in three parallel macOS shards (about 4 minutes
  per pull request, from about 13); the Linux job is gone.

### Fixed

- `app update` refuses to run when a site's app list cannot be read, so
  it never skips a site's backup or migrate.
- `pull` into a running bench pauses the bench's scheduler until the
  copy has its own `pause_scheduler` and `mute_emails`.
- A git repository or branch from a team profile or lockfile can no
  longer be read as a git option (`--` everywhere, values starting with
  `-` refused).
- The window no longer jumps wider when you open General, and a
  change's result shows only on the page it belongs to.

## 0.4.0 - 2026-09-26

Frappe v16 is a first class profile, and more than one bench runs on the
same Mac: each with its own ports, sites, settings and scheduler choice,
side by side in the menu bar. Verified on a real Mac with a v15 and a v16
bench running at once (docs/DECISIONS.md, "the v16 bench on a real Mac").

### Added

- **Frappe v16, supported.** The `v16-lts` profile (Python 3.14, Node 24)
  installs and runs end to end. `pkgconf` and `mariadb-connector-c` are
  system dependencies of every profile and on `PKG_CONFIG_PATH` (v16
  pins `mysqlclient`, which builds against them); a CI job runs the v16
  profile under mocks.
- **One MariaDB for every bench.** A bench uses the MariaDB server
  already running on 3306 when the profile accepts its version (v16
  accepts 10.6 to 11.8), so a v16 bench next to a v15 bench shares
  `mariadb@10.11` instead of installing `mariadb@11.8`.
- **Several benches side by side.** Every bench keeps its own profile,
  site, autostart, scheduler, honcho and ports in
  `.benchbar/benches/<name>-<hash>.env`; settings from before 0.4 still
  count for the default bench and move there on the next `service`,
  `adopt` or `install`. A bench without a stored profile gets it from its
  frappe version. A second bench no longer becomes the default by being
  set up; `--make-default` does that.
- **Port blocks.** A new bench that clashes with an established one moves
  to the next free block (web `8000 + n`, socketio `9000 + n`, Redis
  `11000 + n` and `13000 + n`), written with `bench set-config -g` and
  `bench setup redis` as part of the plan; `--port-offset N` picks one.
  The default bench never moves on its own.
- **Sites.** `benchbar site list`, `site add NAME` (with the Keychain
  MariaDB password, the hosts line, and apps from `apps/`),
  `site default NAME` and `site hosts`.
- **The scheduler, opt in per bench:** `benchbar service --with-schedule`
  and `--without-schedule`; `repair` keeps the choice.
- **Doctor checks from the community threads**, each with its fix:
  `full_disk_access`, `toolchain_node`, `toolchain_yarn`,
  `toolchain_pkgconfig` (the tools as the bench's launchd PATH sees them,
  so nvm's node shows up as missing), `mariadb_version` (the profile's
  range), `honcho_setuptools` (with a repair that touches only honcho's
  venv), `fork_safety`, `orphans` (stale processes on the bench's ports)
  and `scheduler`.
- **BenchBar.app with several benches:** a bench list with state, uptime
  and Start, Stop and Restart per row; the runner shows the worst state
  across all benches, with an "n of m up" count; the selected bench lists
  its sites with Open buttons, the default marked, and the `site hosts`
  fix when a hosts line is missing; a scheduler switch per bench in
  Settings.
- JSON (still `schema_version: 1`): `sites[]` in `list` and `status`,
  `scheduler` in `status`, `redis_socketio` in `ports`.
- `bench` itself is installed with `uv tool install frappe-bench` when uv
  is on PATH; pipx stays the fallback and existing pipx installs are left
  alone. Doctor names the owner.

### Changed

- **Benches never touch each other's processes.** `down`, `status` and
  the runner match honcho and socketio by their working folder: both run
  with the same relative command line in every bench, and before 0.4
  starting or stopping one bench also stopped the other's. The runner
  template is v3; run `benchbar repair` on every bench once.
- The shell block's PATH lines follow the default bench's profile, so a
  v16 bench never changes the Python and Node of your shell; phase 00
  writes the block only when there is none.
- The doctor check `wkhtmltopdf` is now `pdf_engine`: wkhtmltopdf on
  every profile (still v16's default engine) and, on v16, the Chromium
  used by Print Formats set to `chrome`, with `bench setup-chrome` as
  the fix.
- `bench init` runs with `--no-backups`: a dev bench needs no backup
  cron, and the crontab write is what fails without Full Disk Access.
- Site setup runs the bench's own Redis while it creates the site and
  installs apps (frappe v16 needs it; a new bench has none running yet),
  and stops only what it started.
- v16 sites are created with `--mariadb-user-host-login-scope=%`; v16
  calls `--no-mariadb-socket` deprecated.
- The port clash check also reports a bench that is only configured with
  the same ports, with the `--port-offset` that fixes it.
- ROADMAP.md: 0.5 is one bigger release (repair from the app, a log
  viewer, `benchbar mcp`, app installs from any GitHub repo, team
  profiles, a team lockfile and pulling a production site); the public
  launch moves to 0.6.

### Fixed

- `doctor --json` with a failing check printed a `[FAIL] Last command
  failed` line after the JSON, so the app could not read the report.
- The Python formula check read `brew leaves`, which hides a formula
  other formulae depend on (python@3.14 under pipx and uv); it now reads
  "installed on request".
- A run that ended on verify warnings no longer adds a misleading
  `[FAIL] Last command failed` line naming a command that succeeded.

## 0.3.1 - 2026-09-24

### Fixed

- `benchbar doctor` no longer reads the MariaDB root password from the
  Keychain: the live `character_set_server` query added in 0.3.0 is gone.
  Doctor is read only and the app runs it on a timer, so it must never
  touch the Keychain. The `!includedir` check stays; a missing `my.cnf`
  counts as a missing includedir.
- Phase 01 exits 2, the documented "root password unknown" code, when a
  fresh site needs the MariaDB root password and no source has it, and
  `benchbar install` reports that as a pending manual step.
- wkhtmltopdf detection prefers the official package binary in
  `/usr/local/bin` when it is the patched build, and warns (fix:
  `brew uninstall wkhtmltopdf`) when an unpatched Homebrew build earlier
  on PATH would shadow it.

## 0.3.0 - 2026-09-24

The project is now **BenchBar**: the `benchbar` command line tool, plus a
native menu bar app. Built for Frappe and ERPNext on macOS; not
affiliated with Frappe Technologies.

### Added

- **One line installer**, `install.sh`: checks macOS, the Command Line
  Tools and Homebrew (offering their installers), clones the CLI into
  `~/.local/share/benchbar` with links in `~/.local/bin` and a PATH block
  in `~/.zshrc`, installs the BenchBar app from the latest GitHub release
  (zip checked against the release's `SHA256SUMS`, unpacked with `ditto`,
  so no Gatekeeper prompt), then offers `benchbar adopt` for a bench it
  finds or `benchbar install`. Flags `--yes`, `--dry-run`, `--no-app`,
  `--app-only`, `--version vX.Y.Z`, `--uninstall`. Re-runs say
  `unchanged`.
- **The manual install steps are gone.** Phase 00 sets the MariaDB root
  password itself (generated, or `MARIADB_ROOT_PASSWORD`), applies the
  secure installation steps in SQL, and keeps the password in the macOS
  Keychain (`benchbar-mariadb`); every later step reads it from there and
  passes it through `MYSQL_PWD`. The utf8mb4 drop-in is a doctor check and
  repair action. The patched Qt wkhtmltopdf is downloaded from the pinned
  official package (`config/wkhtmltopdf.tsv`, sha256 checked) and
  installed with `installer`; on Apple Silicon Rosetta 2 is offered first
  because the package is an Intel binary, and skipping it only costs
  PDFs. The `/etc/hosts` line sits inside `# >>> benchbar >>>` markers,
  with a backup first. One `sudo` prompt covers a whole run.
- `benchbar adopt PATH`: registers an existing bench (Procfile.lean,
  runner, launchd agent, helpers, hosts line) after showing the plan and
  asking. Never runs `migrate`, `build` or `update`.
- `benchbar report [--print]`: a redacted diagnostics zip on the Desktop
  with doctor and status JSON, versions, the agent, `Procfile.lean`,
  `state.json`, log tails and the key names of the site configs. Secrets
  are masked by key name, paths and names are replaced by placeholders,
  and `REDACTIONS.txt` lists what was replaced.
- `benchbar mariadb-password`: prints the Keychain password after a
  confirmation.
- Doctor checks `MariaDB utf8mb4` and `wkhtmltopdf`, with repair actions.
- CI (`.github/workflows/ci.yml`) on pull requests and pushes to main:
  shellcheck and the CLI tests on macOS (`/bin/bash` 3.2) and Linux, an
  unsigned app build and the Swift tests, and `scripts/release-local.sh`
  whose zip, dmg and `SHA256SUMS` are uploaded as a workflow artifact.
- Releases (`.github/workflows/release.yml`): a `v*` tag drafts a GitHub
  release with the CHANGELOG section as notes. Without Developer ID
  secrets the app is ad hoc signed (`scripts/release-local.sh`); with
  them it is signed, notarized and stapled, with the Sparkle appcast and
  the Homebrew cask (`docs/releasing.md`).
- `docs/testing.md`, a three step guide for testers, and
  `docs/DECISIONS.md`.
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

- `00-mac-system-deps.sh` exits 2 only when MariaDB already has a root
  password that neither the environment nor the Keychain knows; it takes
  `--yes`. `01-install-bench-and-site.sh` reads the root password from
  the Keychain and no longer passes it on the `mariadb` command line.
- The test suite runs on Linux as well as macOS (GNU stat and sed, a
  `uname` mock), so a Linux machine gives quick feedback.
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
- The repository is now github.com/askysh/benchbar (the old URLs
  redirect). README, AGENTS.md, the docs, the cask and the Sparkle feed use
  it.
- Names from before 0.3.0 move over once, on the next run or `repair`:
  the checkout's `.frappe-local/` becomes `.benchbar/`,
  `frappe-mac-run.sh` in the bench becomes `benchbar-run.sh` (the old file
  goes to the backups once no agent uses it), the `# >>> frappe-mac >>>`
  block in the shell rc is replaced in place by `# >>> benchbar >>>`, and
  new files carry a `benchbar-template:` header. Files are not rewritten
  for the header word alone, so MariaDB is not restarted.

### Fixed

- Reading a missing stop flag no longer prints "No such file or
  directory".
- Reloading the agent of a running bench (a repair after a template or
  setting change, `autostart on|off`) could leave it stopped and unloaded:
  `launchctl bootout` returns while the job is still shutting down, the
  immediate `bootstrap` failed, and the `load -w` fallback exits 0 without
  loading anything. The CLI now waits until launchd has let go of the job
  (up to 30 seconds), confirms the load with `launchctl print`, and fails
  the step clearly instead of reporting success.

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
