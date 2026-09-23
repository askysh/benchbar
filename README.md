# Frappe Mac Local Install

Set up a local Frappe / ERPNext development server on macOS, run it in the
background, and keep it healthy. One command installs everything, one
command repairs a bench that a cleanup tool or an upgrade broke, and the
bench keeps running with no Terminal window left open.

This is the macOS counterpart to
[askysh/frappe_wsl_dev_server](https://github.com/askysh/frappe_wsl_dev_server)
(for Windows / WSL).

## What you get

- A Frappe v15 + ERPNext v15 dev server at `http://macdev:8000`, logged in
  as `Administrator` with a password you choose.
- The bench runs in the background under one launchd agent. It survives
  closing Terminal, comes back after a reboot if it was running, and
  restarts itself after a crash. If it crashes 3 times in 10 minutes it
  pauses and shows a macOS notification instead of looping forever.
- Shell helpers: `benchup`, `benchdown`, `benchrestart`, `benchstatus`,
  `benchlogs`, `benchfg`, `benchwatch`, `benchdoctor`, `benchcd`.
- `frappe-mac doctor` (read only) pinpoints what is broken and prints the
  exact fix. `frappe-mac repair` applies only those fixes, in the right
  order, with a backup before every change.
- Every run is idempotent: run `install` or `repair` as often as you like.
  If nothing changed, it says "unchanged" and writes nothing.

## Before you start

You need:

- **macOS** on Apple Silicon (M1 and later). Intel Macs may work but are
  not the primary target.
- **Homebrew** installed. Check with `brew --version`, install from
  <https://brew.sh> if that fails.
- **Xcode Command Line Tools**. Check with `xcode-select -p`, run
  `xcode-select --install` if it errors.
- **Internet** for downloads and about **5 GB free disk** under your home
  folder.

You do not need Docker, a VM, or any pre-installed Python, Node, MariaDB
or Redis. Homebrew provides all of it.

## Quick start (fresh Mac)

Open Terminal and run:

```bash
cd ~
git clone https://github.com/askysh/frappe_mac_dev_server.git
cd frappe_mac_dev_server
./frappe-mac install
```

`install` runs three phases and shows a numbered step list with live
status and timings:

1. **System dependencies**: Homebrew formulae (Python 3.11, Node 20,
   MariaDB 10.11, Redis), the utf8mb4 MariaDB config, and a managed block
   in your `~/.zshrc` with the profile exports and the `bench*` helpers.
2. **Bench and site**: `frappe-bench` via pipx, `bench init`, ERPNext,
   `bench new-site macdev`. You are asked for two passwords here.
3. **Background service**: honcho, `Procfile.lean`, the runner script,
   the launchd agent, the `/etc/hosts` entry (one `sudo` prompt), MariaDB
   bound to 127.0.0.1, and migration of any older per-process agents.

The first run stops after phase 1 with a short list of **manual steps**
that no script can do safely for you. Complete them, then run
`./frappe-mac install` again. It picks up where it left off.

### The manual steps

**Set a MariaDB root password** with `mariadb-secure-installation`. The
right answers for a Frappe dev box are not all defaults:

| Prompt | Answer |
|---|---|
| `Enter current password for root` | Press Enter (no password yet) |
| `Switch to unix_socket authentication` | `n` (Frappe needs password auth) |
| `Change the root password?` | `y`, then pick a strong password and **write it down** |
| `Remove anonymous users?` | `y` |
| `Disallow root login remotely?` | `y` |
| `Remove test database and access to it?` | `y` |
| `Reload privilege tables now?` | `y` |

**Install patched-Qt wkhtmltopdf** from
<https://github.com/wkhtmltopdf/packaging/releases> (the latest
`0.12.6.x` macOS `.pkg`). `wkhtmltopdf --version` must print
`with patched qt`. Homebrew's build crashes on real Frappe templates.

### Two passwords to write down

| # | Where you set it | What it unlocks | When you need it again |
|---|---|---|---|
| 1 | `mariadb-secure-installation` | MariaDB root (the database) | Phase 2 asks for it once, to create the site |
| 2 | Phase 2 prompt `Site admin password` | ERPNext `Administrator` login | Every login at `http://macdev:8000` |

Do not reuse the same password for both. If you forget #2 later:
`bench --site macdev set-admin-password <new>` inside the bench folder.

### Start it

When `install` ends with the "Next steps" box:

```bash
source ~/.zshrc
benchup
```

Then open `http://macdev:8000`, log in as `Administrator`, and walk
through the ERPNext setup wizard. You can close Terminal. The bench keeps
running.

## Daily commands

| Helper | Same as | What it does |
|---|---|---|
| `benchup` | `frappe-mac up` | Start the bench in the background and wait for the site to answer |
| `benchdown` | `frappe-mac down` | Stop it and keep it stopped, also across reboots |
| `benchrestart` | `frappe-mac restart` | Restart all processes. Needed after changing Python code |
| `benchstatus` | `frappe-mac status` | Agent state, pid, last exit code, stop flag, site ping |
| `benchlogs` | `frappe-mac logs` | Follow `logs/bench.log`. Add `--worker`, `--previous`, `--no-follow` |
| `benchfg` | `frappe-mac fg` | Stop the service and run honcho in the foreground (Ctrl+C to stop) |
| `benchwatch` | `frappe-mac watch` | `bench watch` for JS and CSS rebuilds |
| `benchdoctor` | `frappe-mac doctor` | Read-only health report |
| `benchcd` | `cd "$(frappe-mac path)"` | Jump into the bench folder |

Other commands: `frappe-mac repair`, `frappe-mac service`,
`frappe-mac autostart on|off`, `frappe-mac uninstall-service`,
`frappe-mac --help`.

### What recovers on its own, and what does not

| Situation | What happens |
|---|---|
| A process crashes | launchd restarts the whole bench after 20 seconds |
| It crashes 3 times in 10 minutes | Auto-restart pauses, a notification appears. Run `benchlogs`, fix the cause, then `benchup` |
| You reboot | The bench comes back only if it was running before (`benchdown` keeps it down) |
| You edit Python code | The web server reloads, the worker does not. Run `benchrestart` |
| You edit JS or CSS | Nothing rebuilds in the lean Procfile. Run `benchwatch` while you work |
| Scheduled jobs | The lean Procfile has no scheduler. Run `bench schedule` by hand if you need it |
| `bench update` or `bench setup procfile` | They rewrite `Procfile`. `Procfile.lean` is separate and untouched |

The bench log is `<bench>/logs/bench.log`. `benchup` keeps the tail of the
previous run in `logs/bench.previous.log`.

## Health: doctor and repair

```bash
./frappe-mac doctor
```

Read only. Each check prints `[OK]`, `[WARN]` or `[FAIL]` with the exact
fix command. Exit code 1 when anything fails. Checks cover: Homebrew
formulae, the profile's Python (and whether `brew autoremove` could
delete it), `env/bin/python`, `bench version`, the socket.io module, the
built assets that `assets.json` references, honcho, `Procfile.lean`, the
runner, the launchd agent and its last exit code, the stop flag, the
shell helper block, legacy agents, the MariaDB bind address, a stray
Homebrew redis on 6379, the site ping, `/etc/hosts`, log sizes,
CleanMyMac, and port clashes with other benches.

```bash
./frappe-mac repair --dry-run   # show the plan, change nothing
./frappe-mac repair             # apply, with a confirmation prompt
```

Repair runs only the fixes doctor flagged, in dependency order: Python
formula, env rebuild, honcho, node requirements, `bench build`, cache
clearing, MariaDB, legacy agents, then the generated files. A broken
`env/` is moved to `env.broken.<timestamp>`, never deleted.

### The cleanup-tool case

Something (most often CleanMyMac's developer junk cleanup) can delete
`env/`, `node_modules/` and `apps/*/public/dist`. The symptoms:

- `bench` commands fail with `FileNotFoundError` for `env/bin/python`,
- socketio fails with `Cannot find module 'socket.io'`,
- the site loads with no styling because `/assets/*/dist/*.bundle.*`
  returns 404, even though `sites/assets/assets.json` still exists.

`doctor` detects all three separately (it checks the actual dist files
that `assets.json` references), and `repair` rebuilds only what is
missing. If CleanMyMac is installed, doctor warns you to add the bench
folder to its Ignore List.

## Existing bench, or migrating from an older setup

Point the tool at any bench once. It remembers the path in
`.frappe-local/state.env`:

```bash
./frappe-mac doctor --bench-dir ~/dev/frappe-bench
./frappe-mac repair --bench-dir ~/dev/frappe-bench
```

Without `--bench-dir` it looks for a remembered bench, then
`~/frappe-bench`, `~/dev/frappe-bench`, and any folder under `~` or
`~/dev` that holds `sites/common_site_config.json`.

If you used per-process LaunchAgents before (one agent each for web,
worker, socketio and so on) or a hand-made agent, doctor lists them with
their launchctl state and last exit code. Repair boots them out and moves
the plists to `~/Library/LaunchAgents-disabled/<name>-<timestamp>/`.
Nothing is deleted.

Older `# >>> frappe-bench helpers >>>` blocks in `~/.zshrc` are reported
so you can remove them by hand. The frappe-mac block comes later in the
file, so its functions win in the meantime.

Multiple benches work side by side. Each gets its own agent
`com.frappe-mac.<bench folder name>`. `benchup` warns when another
running bench already uses the same web or socketio port.

## Safety rules

- Every component is check, plan, apply, verify. `--dry-run` prints the
  full plan and changes nothing.
- Generated files (runner, plist, `Procfile.lean`, the shell block, the
  MariaDB drop-ins) carry a version and content hash header. They are
  rewritten only when the template or its inputs changed, and the old
  copy goes to `.frappe-local/backups/<timestamp>/` first.
- `sites/`, databases, `apps/` source code and your files are never
  touched. Broken folders are moved aside, never removed.
- Stop and cleanup only match this bench's honcho, `serve`, `worker`,
  `schedule`, `socketio.js` and the listeners on its ports. Your own
  `bench migrate` or `bench console` keeps running.
- `sudo` is used for `/etc/hosts` only, and only after asking (or with
  `--yes`).
- A lock in `.frappe-local/lock` stops two runs from overlapping.
- Full logs of every mutating run: `.frappe-local/logs/<timestamp>.log`.

## Customizing

### App bundles

| Bundle | Apps |
|---|---|
| `minimal` | `erpnext` |
| `common` | `erpnext hrms payments` |
| `extended` | `erpnext hrms payments crm helpdesk insights` |

```bash
./frappe-mac install --bundle common
APPS="erpnext hrms crm" ./01-install-bench-and-site.sh
```

Definitions live in `config/app-bundles.tsv` and `config/apps.tsv`.

### Profiles

| Profile | Frappe | ERPNext | Python | Node | MariaDB |
|---|---|---|---|---|---|
| `v15-lts` (default) | `version-15` | `version-15` | `python@3.11` | `node@20` | `mariadb@10.11` |
| `v16-lts` | `version-16` | `version-16` | `python@3.14` | `node@24` | `mariadb@11.8` |

```bash
./frappe-mac install --profile v16-lts
./00-mac-system-deps.sh --list-profiles
```

### Non-interactive

```bash
MARIADB_ROOT_PASSWORD='...' ADMIN_PASSWORD='...' ./frappe-mac install --yes
```

`--yes` accepts every default and confirmation, including the `sudo`
line for `/etc/hosts`. It never stops a Homebrew redis on 6379 (that
stays a question).

### The phase scripts still work on their own

`00-mac-system-deps.sh`, `01-install-bench-and-site.sh` and
`02-background-service.sh` keep their flags: `--yes`, `--profile`,
`--advanced`, `--check-updates`, `--offline`, `--dry-run`,
`--repair-bench`. `00` exits with code 2 while manual steps remain.
`--repair-bench` only moves aside a folder that never became a bench; a
bench with apps or sites is always kept and sent to `frappe-mac repair`.

### Autostart

```bash
./frappe-mac autostart off   # never start at login, benchup still works
./frappe-mac autostart on
```

## Uninstall

Remove the background service and helpers but keep the bench:

```bash
./frappe-mac uninstall-service
```

Wipe the bench and site (this deletes your data; the tool never does
this for you):

```bash
./frappe-mac uninstall-service
rm -rf ~/frappe-bench
rm -rf ~/frappe_mac_dev_server/.frappe-local
```

Drop the site database in `mariadb -u root -p`: `SHOW DATABASES;` lists
it (the name starts with an underscore), then `DROP DATABASE` and
`DROP USER` for that name. To remove the Homebrew formulae:
`brew uninstall mariadb@10.11 redis node@20 python@3.11`.

## Common stumbles

**`benchup: command not found`.** Run `source ~/.zshrc` once, or open a
new Terminal tab.

**`benchstatus` says `stop flag crash`.** The bench crashed 3 times in 10
minutes and paused itself. `benchlogs` shows why (`--previous` shows the
run before). Fix it, then `benchup`.

**The site loads without styling.** Run `./frappe-mac doctor`. If the
built assets are missing, `./frappe-mac repair` runs `bench build`.

**`bench: command not found` after phase 2.** pipx installs to
`~/.local/bin`. Run `pipx ensurepath` and open a new Terminal.

**Browser says it cannot connect to `macdev`.** The `/etc/hosts` line is
missing. `./frappe-mac repair` adds it, or run
`printf '127.0.0.1 macdev\n' | sudo tee -a /etc/hosts`.

**MariaDB rejects the root password.** Confirm it with
`mariadb -u root -p` in another tab. If that fails too, re-run
`mariadb-secure-installation`.

**Phase 2 says the bench has apps or sites but no env.** That is the
cleanup-tool case above. Run `./frappe-mac repair`, not the installer.

**Something else.** `./frappe-mac doctor` first. Every line names its
fix. The run log in `.frappe-local/logs/` has the full command output.

## For AI coding agents

See [AGENTS.md](AGENTS.md). Short version: run `./frappe-mac doctor
--json` first, prefer `--dry-run` before `repair`, pass `--yes` with the
passwords in the environment for `install`, and never `rm -rf` anything
inside the bench.

## Files

```text
frappe-mac                    # the CLI: install, up, down, doctor, repair, ...
00-mac-system-deps.sh         # Phase 1: Homebrew formulae, MariaDB config, shell block
01-install-bench-and-site.sh  # Phase 2: bench init, apps, site
02-background-service.sh      # Phase 3: same as "frappe-mac service"
lib/frappe-local/             # shared shell library (ui, checks, repair, launchd, ...)
templates/                    # runner, plist, Procfile.lean, shell block, MariaDB drop-ins
config/                       # release profiles and app bundles
tests/                        # mocked test harness (launchctl, brew, lsof, bench, ...)
```

Generated at install time: `<bench>/frappe-mac-run.sh`,
`<bench>/Procfile.lean`, `~/Library/LaunchAgents/com.frappe-mac.<bench>.plist`,
the `# >>> frappe-mac >>>` block in `~/.zshrc`, and
`$(brew --prefix)/etc/my.cnf.d/frappe.cnf` plus `frappe-mac-local-only.cnf`.

Everything runs on the macOS `/bin/bash` 3.2 with no extra dependencies.
If `gum` is installed it is used for prompts.

## Tests

```bash
tests/run-tests.sh
```

The suite mocks `launchctl`, `brew`, `lsof`, `pkill`, `curl`, `osascript`,
`bench`, `honcho` and friends, so it never touches a real bench or your
LaunchAgents. It covers install run twice, legacy agent migration, every
doctor detection, the crash guard, scoped stop, dry-run and marker block
replacement. `shellcheck` runs on every script when installed
(`brew install shellcheck`).

See [CHANGELOG.md](CHANGELOG.md) for release notes and
[ROADMAP.md](ROADMAP.md) for what comes next.

## Important notes

- Do not use the unversioned Homebrew `mariadb` formula for the v15
  profile. Pin to `mariadb@10.11`.
- Do not `brew install wkhtmltopdf`. Use the official patched-Qt `.pkg`.
- Do not switch MariaDB root to `unix_socket` only. Frappe needs password
  auth.
- Do not delete `$(brew --prefix)/var/mysql` without a backup. It holds
  every database on the machine.
- Do not put the bench under an iCloud-synced folder such as `~/Desktop`
  or `~/Documents`.
- If CleanMyMac or a similar tool is installed, add the bench folder to
  its ignore list before running any cleanup.

## License

MIT. See [LICENSE](LICENSE).
