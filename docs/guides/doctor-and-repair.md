---
title: "Doctor and repair"
description: "benchbar doctor checks a bench read only and names the exact fix; benchbar repair applies only the flagged fixes. Every check id, what it checks and its fix."
---

```bash
benchbar doctor              # read only, exit 1 when something fails
benchbar repair --dry-run    # show the plan, change nothing
benchbar repair              # apply, with a confirmation prompt
```

Doctor is read only, with one exception: the one time move of the state
folder on the first run after an upgrade (`~/.local/share/benchbar/.benchbar`
to `~/.local/state/benchbar`), which renames and links, and never copies
or deletes.

A few names used below: the **launchd agent** is the macOS background
job that runs the bench; **honcho** is the process manager that starts
the processes listed in **`Procfile.lean`**; the **runner** is the
script the agent starts; the **stop flag** is the file that says
whether the bench was stopped on purpose (`manual`) or paused after
crashes (`crash`), so it is not restarted.

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

Repair runs only the flagged fixes, in dependency order, and shows the
plan before it asks. A broken `env/` is moved to
`env.broken.<timestamp>`, never deleted. When every check passes, repair
prints `unchanged: all N checks pass, nothing to do`, and a second run
after a repair should say the same. The most common case,
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

### formula_dates

Homebrew deprecates a formula about a year before it disables it, and a
disabled formula can no longer be installed, so a fresh install and every
`brew install` fix of the profile fail from that day. This check reads the
dates of the profile's Python, Node and MariaDB formulae from the local
tap (`brew info --json`, no network): a WARN within 90 days of a disable
date, a FAIL once it has passed.

Fix: update BenchBar (`brew upgrade benchbar`, or Check for Updates in the
app); a newer profile names the current formulae, and `benchbar repair`
then moves the bench to them. A bench keeps the formulae it has.

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
`$(brew --prefix)/etc/my.cnf.d/` and restarts MariaDB when it is
running. Every bench on this Mac shares that server, so running benches
lose their database for a few seconds; stop them first, or repair when
nothing is mid request.

### mariadb_utf8

The utf8mb4 drop-in `frappe.cnf` in `$(brew --prefix)/etc/my.cnf.d/` is
current, and `my.cnf` includes that folder. Frappe needs utf8mb4 server
wide. A drop-in written by someone else that sets utf8mb4 is accepted and
left alone. Doctor reads the files only; it never logs in to MariaDB.

Fix: `benchbar repair` writes the drop-in and the `!includedir` line,
then restarts MariaDB when it is running and the drop-in changed. As
with `mariadb_bind`, every running bench loses its database for a few
seconds.

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

Fix: `brew services stop redis`, only if nothing else on this Mac needs
it. `benchbar repair` offers the same and asks first; under `--yes` it
leaves Redis running and prints the command.

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

Fix: when `~/.config/mole/whitelist` does not exist yet, first run
`mo clean --whitelist` and save once: a whitelist file replaces Mole's
built in entries, and its editor writes them into the new file. Then
add the bench folder, with your bench's path in place of `<bench>`:
`echo '<bench>' >> ~/.config/mole/whitelist`.

### app_copies

At most one `BenchBar.app`, in `/Applications` or `~/Applications`. Two
copies, typically Homebrew's cask in `/Applications` and the one line
installer's in `~/Applications`, share one bundle id, so macOS may open
either, and the login item and the updater may each pick a different one.

Fix: quit BenchBar and move the copy you do not use to the Trash. With
Homebrew's cask `benchbar-app` installed, that is the one in
`~/Applications`. `benchbar repair` never deletes an app.

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
`env.broken.<timestamp>`. When no profile matches the bench's Frappe (a
`develop` or v17 bench with no stored profile: doctor's header then says
`profile v15-lts (default: no profile matches this bench)`), the Python
to rebuild with is unknown, so a version mismatch is only a warning, no
rebuild is offered, and the fix is `benchbar install --profile NAME`.

### env_setuptools

On Frappe v15, `env/bin/python` imports `pkg_resources`: bench and honcho
need it, setuptools 70 and later dropped it, and an env made with Python
3.12 or newer has no setuptools at all. Skipped on other versions.

Fix: `benchbar repair` installs `setuptools<70` into the env (an env
rebuild on v15 does the same).

### bench_version

`bench version` works in the bench folder. The message also says whether
pipx or uv owns `bench`. A failure is classified first: a missing `bench`
command, or one whose own venv is broken (exit 126 or 127), is the CLI's
problem and gets `uv tool install frappe-bench` or the pipx equivalent;
an app in `sites/apps.txt` that does not import is named, with `bench
setup requirements --python` as the fix. Neither moves the env aside.

Fix: `benchbar repair` rebuilds the env only when frappe itself does not
import and the profile is this bench's (stored or detected).

### toolchain_node

The `node` the bench's processes see (launchd's `PATH`, not your shell's)
has the major version the profile expects. nvm's node is only on your
shell's `PATH`, so the bench does not see it.

Fix: `brew install <node formula>`; the bench's `PATH` puts it first.
When the profile's formula is not installed (a profile that moved to a
newer Node), `benchbar repair` runs the install (`node_install`); the old
formula is never removed.

### toolchain_yarn

`yarn` is on the bench's `PATH`. `bench build` needs it.

Fix: `npm install -g yarn` with the bench's npm; `benchbar repair` runs
it (`yarn_install`), since yarn is global to one node formula.

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

### dependency_behind

One warning for each app a focus app needs (its `required_apps` in
`hooks.py`, followed through other apps) that is behind its remote
branch, for example `exponent_custom_v1 (needed by exponent_ecr) is 30
commits / 12 days behind upstream/develop`. The days are the age of the
oldest commit you do not have yet. A focus app itself never gets this
warning: you pull the app you work on yourself. See
[focus apps](apps.md#focus-apps-and-their-dependencies).

Doctor stays read only and never fetches on its own: the numbers come
from the remote branches as git last fetched them, your own `git fetch`
included. When benchbar has not fetched them in the last day, the row
says so ("as of a fetch 3 days ago") and the OK line says to run
`benchbar doctor --fetch`. That fetches the focus apps' dependencies
first, with a 20 second timeout each and never a password prompt; only
`.git` changes. It never runs with `OFFLINE=1` or `--dry-run`. An app
never fetched is reported as unknown, and a fetch that fails is no
failure either.

Fix: `benchbar app update <app>`, which shows the changelog, backs up
the sites that have the app, fast forwards it and migrates. A dependency
with local changes gets `git status` first. Never `bench update`.

### apps_behind

One line about every other app: neither a focus app nor needed by one.
It reads the remote branches as they were last fetched (even `doctor
--fetch` does not fetch these) and is always OK.

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

### profile_outdated

The bench's team profile comes from a subscription whose clone is behind
its remote, as of the clone's last fetch. Doctor itself never fetches;
`benchbar doctor --fetch` fetches the subscription first (not with
`BENCHBAR_OFFLINE=1`), and the message says when the last fetch is
older than a day. See
[Sharing a profile](teams.md#sharing-a-profile).

Fix: `benchbar profile update NAME` (shows the changes and asks).

### logs

`bench.log`, `worker.log` and `worker.error.log` are under 50 MB each.

Fix: `benchbar repair` copies each large log to `<name>.old.<stamp>` and
empties the live file in place, so the bench's processes keep writing to
the file they have open. At most three copies are kept.

## Service checks

### port_block

Shown only in the plan of `install`, `adopt` or `service` when the bench's
ports are about to move to another block (because another bench uses
them, or `--port-offset` asked for it). Doctor never shows it.

Fix: part of the plan: `benchbar service --port-offset <n>` moves the
ports with `bench set-config -g`.

### bench_path

The bench path and the default site name are plain text to the runner
script (`BENCH="..."`), the launchd agent's plist and a hosts line: no
double quote, backslash, `$`, backtick, `<`, `>`, `&` or control
character, and no whitespace in the site name. Spaces and apostrophes in
the path are fine. Doctor only reports it; `service`, `repair`, `adopt`,
`install`, `up`, `autostart` and `site add` refuse to write for such a
bench and name the character.

Fix: move the bench to a folder without that character, then
`benchbar adopt <new path>`; for a site name, `benchbar site default
<name>` or rename the site folder.

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

### runner_heartbeat

A running runner rewrites `logs/.benchbar/heartbeat` every 30 seconds
(runners written by BenchBar 0.6.1 and later), and the app trusts the
runner's `state.json` only while that file is under 90 seconds old. A
warning means the bench runs a runner process older than its script:
`benchbar service` or `repair` rewrote the script, but a running bench
keeps the process it started with.

Fix: `benchbar restart`. Until then the app checks that bench with the
CLI once a minute, as it did before 0.6.1. When the script itself is
outdated, the runner check says so and this one waits.

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
reported. A block whose `BENCHBAR` path is gone fails: every helper runs
that path. That happens after `brew cleanup` deleted a versioned Cellar
folder an old block named, or after the one line installer's checkout
went to the Trash.

Under Homebrew a block that runs a git checkout with its own
`.benchbar` folder is a warning and stays as it is: Homebrew's CLI never
reads that checkout's state, so `benchup` would lose its benches. A
block that names Homebrew's or the one line installer's `benchbar`
stays as it is when that copy hands off to the CLI inside BenchBar.app.

The app's CLI writes a block that names Homebrew's or the installer's
`benchbar` when one of them hands off to it (the copy that was run first,
then Homebrew's, then the installer's), and the app's own link in
`~/.local/state/benchbar/bin` only when nothing else is installed: that
link goes with the app, and `benchup` would go with it, while a Homebrew
or installer copy runs the app's CLI as long as the app is there and
itself once it is gone. A block that names the link while such a copy is
installed is outdated (0.7.3).

Fix: `benchbar repair` writes the block. Remove an old block by hand.

### cli_link

`~/.local/bin/benchbar` and `~/.local/bin/frappe-mac` are links to this
checkout, so both names work from any folder. When Homebrew has the
`benchbar` formula, its own `bin` folder puts `benchbar` on PATH: the
links are optional then, and a link to Homebrew's benchbar always counts
as current. Under Homebrew a link that leads anywhere else, such as the
one line installer's checkout or a Cellar folder, comes first on PATH and
is a warning. A link to a git checkout with its own `.benchbar` folder is
a warning too, but repair leaves it: that checkout's state is not
Homebrew's. For the CLI inside BenchBar.app, links to a Homebrew or
installer copy that hands off to it are current.

Fix: `benchbar repair` writes the links. With Homebrew's benchbar
installed it never makes a new one: it points a wrong link at this CLI
and keeps the old link in its backups. A file that is not a link is left
alone: move it aside (and link again, without Homebrew).

### cli_duplicate

One copy of the CLI: not the one line installer's in
`~/.local/share/benchbar` next to Homebrew's `benchbar` formula. Both
copies work on the same state folder and the same benches, but only one
of them is `benchbar` on PATH, and the other one's `repair` or
`self-update` changes the copy nobody runs. A git checkout of your own
warns too while Homebrew has the formula. It keeps its own state, which
Homebrew's CLI never reads, so for a checkout the fix is `brew uninstall
benchbar`.

Fix: to keep Homebrew's, run its `repair` by its full path,
`$(brew --prefix)/opt/benchbar/bin/benchbar repair`, then move
`~/.local/share/benchbar` to the Trash; the benches and the state stay.
The check offers the Trash only once the state has moved out of that
folder: while a run of the old CLI holds its lock, run repair again when
it ends. When the two folders are on different volumes the state stays
in `~/.local/share/benchbar/.benchbar`, so keep that folder. To keep the
installer's, `brew uninstall benchbar`. There is no repair action: which
copy stays is your call.

The CLI inside BenchBar.app (0.7.1) next to Homebrew's or the
installer's copy is the normal case: since 0.7.1 those hand off to it,
so this check passes. A copy too old to hand off (before 0.7.1) is a
warning, because `benchbar` in Terminal may run that older copy. Fix:
`brew upgrade askysh/tap/benchbar` for Homebrew's, `git -C
~/.local/share/benchbar pull --ff-only` for the installer's. A copy newer
than the app's CLI (0.7.3) is a warning too: it hands off to the older
one, so every `benchbar` runs the older version until the app updates.
Fix: Check for Updates in BenchBar, or `brew upgrade
askysh/tap/benchbar-app` for the cask's app.

From the app's CLI the check also looks for a second state folder (0.7.3):
a real `.benchbar` (or `.frappe-local`) in `~/.local/share/benchbar` next
to the state in `~/.local/state/benchbar` means two states that never
merge, left by an older CLI or by a layout the move never saw. Fix: move
anything you still need out of it, then move the folder (the installer's
whole checkout when its `benchbar` is still there) to the Trash. When the
new path is a link to that folder (the two are on different volumes) it
holds the state and the check says to keep it. When the move was cut
short (the old folder holds the app's `bin/`, or the new folder holds no
state yet) the check says so and the next `benchbar` run completes it;
nothing is offered for the Trash then. Nothing is ever deleted for you.

### legacy_agents

No per process LaunchAgents (one each for web, worker, socketio and so
on) and no agent from frappe-mac 0.2.

Fix: `benchbar repair` boots them out and moves the plists to
`~/Library/LaunchAgents-disabled/<timestamp>/`.

### dead_agents

Every loaded `com.benchbar.*` agent still has its runner script. When a
bench folder is emptied or deleted (a cleanup tool, `rm`) while its agent
stays loaded, launchd starts the missing script every 20 seconds, it
exits with code 127, and each try adds a line to the bench's log. The
check looks at every bench's agent, not only the current one.

Fix: `benchbar uninstall-service --bench-dir <path>`, with the path the
warning shows. It works when the folder is no longer a bench: it boots
out the agent that points at the path and moves its plist to
`~/Library/LaunchAgents-disabled/<timestamp>/`.

### hosts

`/etc/hosts` maps the site to 127.0.0.1.

Fix: `benchbar repair` adds the line inside its `/etc/hosts` block (with
`sudo`). A declined question leaves the step `skipped`.

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
