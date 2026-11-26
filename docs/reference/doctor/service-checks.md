---
title: "Doctor checks: the service and the site"
description: "The doctor checks of the service group (ports, honcho, Procfile, runner, agent, stop flag, helpers, hosts) and the site group (ping, served sites). What each looks at and its fix."
---

Part of the [doctor checks](../doctor-checks.md). `benchbar doctor` prints the id of a check, and each id below is a heading you can link to. How to read the report is in [Doctor and repair](../../guides/doctor-and-repair.md).

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
template and the bench's settings (for example the scheduler choice). With
the default `listen local` the two files in `config/benchbar-listen` that
its web and socketio lines start with are part of this check: a Procfile
that names a file that is gone would stop the bench.

Fix: `benchbar repair` writes them again; the old copies go to the
backups. A running bench takes them at its next `benchbar restart`.

### bench_listen

The dev web server and socketio listen on 127.0.0.1 only. Frappe binds
both to every interface, with its debugger on; 0.9.0 starts them on
loopback unless the bench was set to `all` with `benchbar listen all`.
A warning means one of four things:

- the bench is set to `all` (the message says so). Fix: `benchbar listen local`, then `benchbar restart`.
- the bench is set to `local` but `Procfile.lean` is the one of before 0.9.0 (or a file in `config/benchbar-listen` is missing). This is reported while the bench is stopped too. Fix: `benchbar restart` (or `benchbar up` for a stopped bench): both write `Procfile.lean` and the two files again before they start the bench, with a backup of the old file, and say so once. `benchbar repair` does the same without a start. A `Procfile.lean` that benchbar did not write is never replaced by `up` or `restart`.
- a listener on the bench's web or socketio port is not on loopback although the files are current, because it was started before 0.9.0 or outside benchbar (`bench start`). Fix: `benchbar restart`.
- the realtime server is the Python one (`socketio_backend: python`, Frappe v16). benchbar does not cover that backend yet: it listens on every interface whatever `listen` says, and a restart does not change that. Fix: switch the bench to the node socketio server (remove `socketio_backend` or set it to `node` in `sites/common_site_config.json`).

The check only reads, and `benchbar listen all` is a person's command.

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

### share_scheduler

Warns when a `benchbar share setup` stopped after it paused the scheduler of
every site on the bench (`pause_scheduler` in `common_site_config.json`) and
did not resume it. The restore of the share copy needs that bench wide
pause, so setup leaves a marker in its state folder first. A pause without
the marker is yours and is never flagged.

Fix: `cd BENCH && bench config remove-common-config pause_scheduler`, or
`benchbar repair`. The next `share setup` or `share start` resumes it too.

### stop_flag

No stop flag, or a stop on purpose (`benchdown`). A flag of `crash` (three
crashes in ten minutes), `broken` (honcho or env was missing) or
`port_conflict` (a process that is not this bench's held one of its
ports when the runner started) means auto restart is paused.

Fix: `benchbar logs`, fix the cause, then `benchup`. For `broken`:
`benchbar repair`, then `benchup`. For `port_conflict`: `benchbar
doctor` names the process; free the port or run `benchbar ports setup`,
then `benchup`.

### helpers

The `# >>> benchbar >>>` block in `~/.zshrc` (`$ZDOTDIR/.zshrc` when
ZDOTDIR is set) with `benchup` and the other helpers is present and
current. Old helper blocks from earlier setups are
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

`~/.local/bin/benchbar` and `~/.local/bin/frappe-mac` (the old name of
`benchbar`) are links to this
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

No per process LaunchAgents of this bench (one each for web, worker,
socketio and so on) and no agent from frappe-mac 0.2 (the old name of `benchbar`). An agent counts
only when its plist names this bench's folder and runs honcho, a
BenchBar or frappe-mac runner, socketio, or `bench` with serve, worker,
schedule, socketio or start.
Your own agents never count, even when their name or script says
"frappe" or they run honcho for another project or a one off command
such as `bench backup` in this folder.

Fix: `benchbar repair` boots them out and moves the plists to
`~/Library/LaunchAgents-disabled/<timestamp>/`.

### dead_agents

Every loaded `com.benchbar.*` agent still has its runner script. When a
bench folder is emptied or deleted (a cleanup tool, `rm`) while its agent
stays loaded, launchd starts the missing script every 20 seconds, it
exits with code 127, and each try adds a line to the bench's log, for as
long as you are logged in. That is a FAIL, not a hint. The check looks at
every bench's agent, not only the current one. Only agents that run a
runner benchbar wrote (`benchbar-run.sh`, or `frappe-mac-run.sh` from
before 0.3.0) count: your own agents, and a `com.benchbar` label you
pointed at your own script, are never listed or touched.

Fix: `benchbar repair` (from any bench) boots out the agent of a folder
that is no bench any more and moves its plist to
`~/Library/LaunchAgents-disabled/<timestamp>/`. A bench that is still
there gets its runner written again: `benchbar repair` in the bench for
the current one, `benchbar repair --bench-dir <path>` for another.
`benchbar uninstall-service --bench-dir <path>` does the removal for one
folder by hand.

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
[Port blocks](../../concepts/port-blocks.md).

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

### site_not_served

Every site folder in `sites/` is served by the running web process. The
check asks each site once with its own `Host` header; a 404 means the
folder is on the bench but the process does not serve it (it was started
before the folder appeared, or something else holds the port). It asks
only while the bench runs: a stopped bench is never pinged or woken, and
the check passes with "the bench is not running".

Fix: `benchbar restart`. `benchbar status --json` shows `sites[].served`
(`true`, `false`, or `null` when the bench is stopped or did not answer).
