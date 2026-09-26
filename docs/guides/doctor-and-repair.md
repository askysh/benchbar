---
title: "Doctor and repair"
description: "benchbar doctor checks a bench read only and names the exact fix; benchbar repair applies only the flagged fixes. Every check id, what it checks and its fix."
---

```bash
benchbar doctor              # read only, exit 1 when something fails
benchbar repair --dry-run    # show the plan, change nothing
benchbar repair              # apply, with a confirmation prompt
```

Doctor checks the Homebrew formulae, the bench env, `bench version`, the
socket.io module, the built assets that `assets.json` references, honcho,
`Procfile.lean`, the runner, the launchd agent and its last exit code,
the stop flag, the shell helpers, legacy agents, the MariaDB bind address
and charset config, the PDF engine (wkhtmltopdf, and on v16 the Chromium
frappe can use), a stray Homebrew Redis on 6379, Full Disk Access for
`crontab`, the toolchain as the bench sees it (Node, yarn, the MariaDB
server, pkg-config), honcho without `pkg_resources`, the fork safety
variables, stale processes on the bench's ports, the site
ping, `/etc/hosts`, log sizes, CleanMyMac, Mole, and port clashes with
other benches. Every warning and failure names its fix.

Repair runs only the flagged fixes, in dependency order. A broken `env/`
is moved to `env.broken.<timestamp>`, never deleted. The most common case,
a cleanup tool that removed `env/`, `node_modules` and the built assets,
is covered in [Troubleshooting](../troubleshooting.md#the-cleanup-tool-case).

## Reading the output

Each check prints one line, `[OK]`, `[WARN]` or `[FAIL]`, with its label
and a message. A `fix:` line with the exact command follows every WARN
and FAIL. `benchbar doctor --json` prints the same checks with their `id`,
`level`, `fix_command` and `action`: the id is the heading of each check
below, and the action is what `repair` would run. The format is in the
[JSON schema](../json-schema.md#benchbar-doctor---json).

Doctor exits 1 when any check fails. Warnings alone exit 0. It never
changes anything, never asks for a password and never reads the
Keychain, so the app runs it on a timer.

Checks with a repair action are fixed by `benchbar repair`. The others
name a command for you to run, because the change is a person's call
(for example which branch an app follows) or needs another app (Full
Disk Access, CleanMyMac, Mole). Commands and flags are in the
[CLI reference](../reference/cli/doctor.md).

## System checks

The checks run in four groups, in this order: system, bench, service and
site. `benchbar service` and `adopt` look only at the service group.

### brew

The Homebrew formulae of the bench's profile are installed: the Python,
Node and MariaDB formulae, and `redis`. A missing one fails. The build
formulae `pkgconf` and `mariadb-connector-c` (needed to build
`mysqlclient` for frappe v16) are a warning when missing.

Fix: install Homebrew from <https://brew.sh> when it is missing; run
`00-mac-system-deps.sh --profile <profile>` from the checkout for missing
formulae, or `brew install pkgconf mariadb-connector-c` for the build
formulae.

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
`$(brew --prefix)/etc/my.cnf.d/` and restarts MariaDB.

### mariadb_utf8

The utf8mb4 drop-in `frappe.cnf` in `$(brew --prefix)/etc/my.cnf.d/` is
current, and `my.cnf` includes that folder. Frappe needs utf8mb4 server
wide. A drop-in written by someone else that sets utf8mb4 is accepted and
left alone. Doctor reads the files only; it never logs in to MariaDB.

Fix: `benchbar repair` writes the drop-in and the `!includedir` line.

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
block, so a Homebrew Redis on 6379 is unused.

Fix: `brew services stop redis`, only if nothing else needs it.

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

Fix: `echo '<bench>' >> ~/.config/mole/whitelist`. When that file does
not exist yet, run `mo clean --whitelist` and save once first: a
whitelist file replaces Mole's built in entries, and its editor writes
them into the new file.

### full_disk_access

`crontab` is readable. Without Full Disk Access for the Terminal, `bench
init` and `bench setup backups` fail with "Operation not permitted". Not
checked when BenchBar runs doctor, since the permission belongs to the
Terminal that runs `bench`.

Fix: System Settings > Privacy & Security > Full Disk Access: add
Terminal (or the app that runs benchbar), then open a new window.

## Bench checks

### env_python

`env/bin/python` exists, runs, and is the Python version the profile
expects.

Fix: `benchbar repair` rebuilds the env; the old one is moved to
`env.broken.<timestamp>`.

### bench_version

`bench version` works in the bench folder. The message also says whether
pipx or uv owns `bench`.

Fix: `benchbar repair` rebuilds the env.

### toolchain_node

The `node` the bench's processes see (launchd's `PATH`, not your shell's)
has the major version the profile expects. nvm's node is only on your
shell's `PATH`, so the bench does not see it.

Fix: `brew install <node formula>`; the bench's `PATH` puts it first.

### toolchain_yarn

`yarn` is on the bench's `PATH`. `bench build` needs it.

Fix: `npm install -g yarn` with the bench's npm.

### mariadb_version

A MariaDB server listens on 3306 and its version is in the range the
profile accepts: 10.6 to 10.11 for v15, 10.6 to 11.8 for v16. Outside the
range is a warning, as it is in Frappe.

Fix: `brew services start <mariadb formula>` when nothing listens;
`brew install <mariadb formula>` for a version outside the range.

### toolchain_pkgconfig

`pkg-config` is on the bench's `PATH` and finds `mariadb-connector-c`.
`mysqlclient` for frappe v16 needs both.

Fix: `brew install pkgconf mariadb-connector-c`.

### socketio

`apps/frappe/node_modules/socket.io` exists. Without it socketio fails
with "Cannot find module 'socket.io'".

Fix: `benchbar repair` runs `bench setup requirements --node`.

### assets

`sites/assets/assets.json` exists and every dist file it references is
there. Missing files make the site load without styling.

Fix: `benchbar repair` runs `bench build`.

### apps_txt

Every app in `sites/apps.txt` has a folder in `apps/`, and every git app
in `apps/` is listed. A listed app without a folder fails, because every
bench command then fails to import it. An unlisted git app is a warning:
usually a `get-app` that did not finish.

Fix: `benchbar app add <app>` for a missing app. For an unlisted one, move
the folder aside, then `benchbar app add <its git URL>`. Repair has no
action here: changing code is your call.

### app_branch_policy

Each git app is on the branch `config/apps.tsv` names for the profile.

Fix: `git fetch` and `git checkout` the policy branch in the app, only if
you meant to follow the policy. Repair has no action here.

### lock_parse

The bench's `benchbar.toml` lockfile, when one is set, exists and parses.
See [the team lockfile](teams.md#the-team-lockfile).

Fix: correct the file by hand, or write it again with `benchbar lock
write`. A lockfile path that does not exist yet: `benchbar lock write
--lock <path>`.

### lock_drift

The bench matches its lockfile: the same apps, repos, branches and
pinned commits. Drift is a warning.

Fix: `benchbar lock apply` (`benchbar lock check` lists the differences).

### logs

`bench.log`, `worker.log` and `worker.error.log` are under 50 MB each.

Fix: `benchbar repair` moves large logs aside.

## Service checks

### port_block

Shown only in the plan of `install`, `adopt` or `service` when the bench's
ports are about to move to another block (because another bench uses
them, or `--port-offset` asked for it). Doctor never shows it.

Fix: part of the plan: `benchbar service --port-offset <n>` moves the
ports with `bench set-config -g`.

### honcho

`honcho`, which runs the Procfile, is found on `PATH`, in the pipx venv of
frappe-bench, or in the bench's `env/bin`.

Fix: `benchbar repair` installs it into the bench env. `adopt` never
installs into env; install it with `pipx install honcho` first.

### honcho_setuptools

honcho imports cleanly. honcho 1.x imports `pkg_resources`, which Python
3.12 and later only have with setuptools installed.

Fix: `benchbar repair` installs setuptools into honcho's own venv only.

### procfile

`Procfile.lean` exists, was written by benchbar, and matches its
template and the bench's settings (for example the scheduler choice).

Fix: `benchbar repair` writes it again; the old copy goes to the
backups.

### runner

The runner script `benchbar-run.sh` is current, and no old
`frappe-mac-run.sh` is left in the bench.

Fix: `benchbar repair` writes it again. A running bench picks the new
runner up on its next start.

### agent

The launchd agent plist is current and loaded, and its last exit code is
not an error.

Fix: `benchbar repair` writes and loads it. A non zero last exit code:
`benchbar logs` shows why.

### fork_safety

The agent passes `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` and
`NO_PROXY=*` to every process. Without them macOS kills forked workers.

Fix: `benchbar repair` writes the agent again.

### scheduler

Reports whether the scheduler runs in `Procfile.lean`. It is a choice, so
this check never warns.

Fix: none needed. `benchbar service --with-schedule` turns it on,
`--without-schedule` off.

### stop_flag

No stop flag, or a stop on purpose (`benchdown`). A flag of `crash` (three
crashes in ten minutes) or `broken` (honcho or env was missing) means
auto restart is paused.

Fix: `benchbar logs`, fix the cause, then `benchup`. For `broken`:
`benchbar repair`, then `benchup`.

### helpers

The `# >>> benchbar >>>` block in `~/.zshrc` with `benchup` and the other
helpers is present and current. Old helper blocks from earlier setups are
reported.

Fix: `benchbar repair` writes the block. Remove an old block by hand.

### cli_link

`~/.local/bin/benchbar` and `~/.local/bin/frappe-mac` are links to this
checkout, so both names work from any folder.

Fix: `benchbar repair` writes the links. A file that is not a link is
left alone: move it aside and link again.

### legacy_agents

No per process LaunchAgents (one each for web, worker, socketio and so
on) and no agent from frappe-mac 0.2.

Fix: `benchbar repair` boots them out and moves the plists to
`~/Library/LaunchAgents-disabled/<timestamp>/`.

### hosts

`/etc/hosts` maps the site to 127.0.0.1.

Fix: `benchbar repair` adds the line (with `sudo`), or
`printf '127.0.0.1 <site>\n' | sudo tee -a /etc/hosts`.

### port_clash

No other bench benchbar knows uses this bench's web, socketio or Redis
ports, running or not. Two benches set up with the same ports cannot run
at the same time.

Fix: `benchbar service --port-offset <n> --bench-dir <bench>` moves this
bench to the next free block (or stop the other bench). See
[Port blocks](benches-and-sites.md#port-blocks).

### orphans

No stale process holds the bench's ports while the agent and honcho are
not running. A killed `bench start` can leave Redis, socketio or gunicorn
behind, and the agent then cannot start.

Fix: `benchbar down` (or `benchbar restart`) stops only this bench's
leftovers.

## Site checks

### ping

`http://<site>:<port>/api/method/ping` returns 200. A stopped bench is
fine; processes that run but do not answer fail.

Fix: `benchbar logs` shows why; `benchup` starts a stopped bench.
