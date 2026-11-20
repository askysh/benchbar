---
title: "report and other commands"
description: "benchbar report, self-update, where, list, op, commands, console, db, open, users, autostart, listen, mariadb-password, uninstall-service and help: the remaining commands with flags, exit codes and examples."
---

Every command takes the [options for every command](install.md#options-for-every-command).

## report

```
benchbar report [--print | --json]
```

Writes a redacted diagnostics zip, `~/Desktop/benchbar-report-<stamp>.zip`,
for a bug report. It holds doctor and status as JSON, the versions of
everything involved, the launchd agent, `Procfile.lean`, `state.json` and
the last 200 lines of `bench.log` and `worker.error.log`.

Site config files are never copied, only their key names. Any value
whose key looks like a password, secret, token, key, API or auth
credential is replaced by `***`, and so is anything shaped like a secret
whatever its key: `user:password@` in a URL (a redis URL, a git URL with
a token), JWTs, GitHub, Slack, OpenAI and AWS tokens. Cookie and
Set-Cookie headers, `--password VALUE` and `-pVALUE` are masked too. Email
addresses become `<email>`. Your home folder, user name and every name of
the Mac are replaced by placeholders. The log tails are program output and
can hold names or phone numbers from a database error: read them before you
attach the zip to a public issue. `REDACTIONS.txt` inside the zip lists what
was replaced. `benchbar logs --json` (and the MCP log tool) applies the
same rules.

| Flag | What it does |
|---|---|
| `--print` | Print the same contents to the terminal instead |
| `--json` | Write the zip and print `{"zip": path, "redactions": n}`, the [report schema](../../json-schema.md#benchbar-report---json) the app reads |

Exit codes: 0; 1 when the zip could not be written.

```bash
benchbar report --print
```

Attach the zip to an issue at <https://github.com/askysh/benchbar/issues>.

## self-update

```
benchbar self-update [--check] [--json] [--dry-run] [--yes]
```

Updates the benchbar CLI and the BenchBar app with the one line
installer (the app's Update Now ran the same command up to 0.7.0; since
0.7.1 it asks Sparkle). With BenchBar.app installed, `benchbar` hands
off to the app's CLI, so the app's case below applies. For release 0.7.2:
`curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/v0.7.2/install.sh | bash -s -- --yes --version v0.7.2`.
It asks the GitHub API for the latest release, shows this CLI's and the
app's versions and the command, and asks before it runs. The installer
comes from that release's tag and installs that release, even if a newer
one is published while you read the prompt. It changes no
bench and never runs `bench update`.

A CLI that is a git checkout of your own (not `~/.local/share/benchbar`)
gets `--app-only` and the `git -C PATH pull` to run; a CLI installed
some other way gets `--app-only` too. An app in a writable folder other
than `~/Applications` is replaced where it is (`BENCHBAR_APP_DIR`).

A CLI installed with Homebrew is upgraded by Homebrew: the command is
`brew upgrade askysh/tap/benchbar`, run after the same question, and the
installer never runs. The app is not this command's then: it updates
itself, or comes from the cask (`brew upgrade
askysh/tap/benchbar-app`), and a note says which.

The CLI inside BenchBar.app (`install` is `app`; Homebrew's and the
installer's benchbar hand off to it once the app is installed) updates
with the app. For the cask's app the command is `brew upgrade
askysh/tap/benchbar-app`, run after the same question. Otherwise
nothing runs: open BenchBar and choose **Check for Updates**, and Sparkle
replaces the app and its CLI. `update_available`
compares only the CLI. When brew says benchbar is already installed
right after a release, the tap has not caught up yet; try again a few
minutes later.

| Flag | What it does |
|---|---|
| `--check` | Only compare with the latest release |
| `--json` | The same as JSON, never runs anything: `current`, `app_version`, `app_path`, `latest`, `release_url`, `update_available` (true, false, null offline), `install` (`managed`, `checkout`, `other`, `homebrew`, `app`), `cli_dir`, `app_only`, `app_dir`, `command`, `notes`, `error` |
| `--dry-run` | The plan and the command, nothing runs |
| `--yes` | Do not ask |

Exit codes: 0; 1 when GitHub could not be reached or the question was
answered no.

```bash
benchbar self-update --check
```

## where

```
benchbar where [--json]
```

How this CLI was installed and where its things are: the install kind
(`homebrew`, `managed` for the one line installer, `app` for the CLI
inside BenchBar.app, `checkout` for a git clone, or `other`), the
Homebrew or installer CLI it was handed off from, the path it records
for itself in the helper block,
the `~/.local/bin` links and every fix command (under Homebrew
`<prefix>/opt/benchbar/bin/benchbar`, which `brew upgrade` keeps), its
state folder, and the BenchBar app it finds. Read only; it needs no
bench.

| Flag | What it does |
|---|---|
| `--json` | The same as JSON, the [where schema](../../json-schema.md#benchbar-where---json) |

Exit codes: 0; 1 for another argument.

```bash
benchbar where
```

## docs

```
benchbar docs [TOPIC] [--print]
```

Opens this documentation in your browser, or the page of one topic:
`install`, `quick-start`, `app`, `sites`, `apps`, `doctor`, `teams`,
`agents`, `mcp`, `cli`, `config`, `json`, `runners`, `troubleshooting`,
`decisions`, `roadmap` or `contributing`. `benchbar docs --help` lists
every topic with its aliases.

| Flag | What it does |
|---|---|
| `--print` | Print the URL instead of opening it |

Exit codes: 0; 1 for an unknown topic.

```bash
benchbar docs doctor
```

## --version

```
benchbar --version
```

The first line is always `benchbar <version>`, which the app and scripts
read. When BenchBar.app is installed in `~/Applications` or
`/Applications`, a second line gives the app's version.

## list

```
benchbar list [--json]
```

Every bench benchbar knows about: path, default site, sites, ports, and
whether its service is installed. It never pings a site. With `--json`,
the [list schema](../../json-schema.md#benchbar-list---json).

Exit codes: 0.

```bash
benchbar list --json
```

## console

```
benchbar console [--site NAME] [--bench-dir DIR]
```

`bench --site NAME console` in the bench folder: an IPython shell with
frappe connected to the site. Without `--site`, the bench's default site.
It replaces the benchbar process, so the terminal is bench's until you
leave with Ctrl-D. Nothing is written and no lock is taken. While the
bench is stopped, calls that need Redis (`frappe.cache`, `enqueue`) fail;
benchbar says so before it starts.

Exit codes: bench's; 1 when the site does not exist.

```bash
benchbar console --site macdev
```

## db

```
benchbar db [--site NAME] [--bench-dir DIR]
```

`bench --site NAME mariadb`: the MariaDB shell on the site's database,
logged in as the site's own database user from its `site_config.json`.
The MariaDB root password is not used and nothing is written to disk.

Exit codes: bench's; 1 when the site does not exist.

```bash
benchbar db --site macdev
```

## open

```
benchbar open [--site NAME] [--as USER] [--path /app/...] [--no-browser] [--print-url] [--json] [--bench-dir DIR]
```

Opens the site in your browser. With `--as USER` you are signed in as that
user, with no password: the quickest way to check what a role sees and which
workflow actions it gets. Without `--site`, the bench's default site;
without `--path`, `/app` (or `/` for a Website User).

`--as` works only on a site you turned Open as on for
([`benchbar site open-as on NAME`](site.md#site-open-as), in a terminal),
with `developer_mode` on (its `site_config.json`, else
`common_site_config.json`), for Administrator too, only while the bench
runs, and only on the site the web process answers as: `bench serve` serves
the `default_site` of `common_site_config.json` for every name, so on a
bench with one that is the only site you can sign in on
(`benchbar site default NAME`, then `benchrestart`, moves it;
`site list --json` says where it works in `open_as`, and whether you turned it on in `open_as_enabled`). Inside WSL the
browser is Windows', which reads its own hosts file, so `--as` opens only a
`*.localhost` name itself; for another name add it to the Windows hosts
file and open the `--print-url` link. Plain `open` (no `--as`) needs the
bench running and a name the browser can reach as well.

`--as` starts a Frappe session for the user the way
`bench browse --user` does and opens `/login?redirect-to=PATH&sid=…`;
frappe sets the cookie and sends the browser on to PATH, so the session id
does not stay in the address bar. It stays in the browser's history and the
web log, as with `bench browse`.

What a sign-in does on the site, as a real login would: the user's
`last_login` is updated, and every app's `on_login` and
`on_session_creation` hooks run. With Frappe and ERPNext that means:

- an Activity Log entry "USER logged in" for every switch;
- a mail to the System Managers when you sign in as Administrator
  (`notify_admin_access_to_system_manager`);
- for a Website User, ERPNext can create a Customer or a Supplier
  (`create_customer_or_supplier`, with the Portal Settings default role).

Frappe keeps only the newest sessions of that user (`simultaneous_sessions`,
2 by default), so an older one (another browser, a test run) can be signed
out. `benchbar site open-as off` does not end the sessions already made.
IP and login-hour restrictions on the user apply; two-factor login does not.
A site with `deny_multiple_sessions` on signs that user out everywhere else.

`--print-url` prints the link instead of opening it (in `--json` as `url`);
the link holds the session id, so treat it like a password. `--json` without
`--print-url` leaves it out. Nothing is written to disk and no run log is
kept. With `--as`, `--print-url` is refused under `BENCHBAR_NONINTERACTIVE=1`,
`--for-agent` and `benchbar mcp`, and when stdin is not a terminal unless the
caller sets `BENCHBAR_NONINTERACTIVE=0` itself, as `site open-as on` is: a
link in an agent's output stays in its transcript. A person at a terminal and
the Mac app (which sets the 0) get it. This is a guard against a mistake, not
a boundary: a process that runs as the same user and fakes a terminal, or
sets the variable, is not stopped.

Exit codes: 0 opened (or printed); 1 a refusal: no such site or user, a
disabled user, Open as is off for the site, the bench is stopped, the site is not in developer mode, the
site name does not resolve (`benchbar site hosts`), or Frappe refused the
login.

```bash
benchbar open --as priya@example.com --path /app/todo
benchbar open --site two.localhost --as Administrator --print-url
```

## users

```
benchbar users [--site NAME] [--search TEXT] [--limit N] [--json] [--bench-dir DIR]
```

The enabled users of a site, to pick one for `open --as` (refused while Open as
is off for the site): System Users
first, most recent login first, with up to five roles each (the automatic
All, Guest and Desk User left out). `--search` matches the user id or full
name; `--limit` is 1 to 500 (50 by default), and `truncated` in `--json`
says more users matched. Reads only; needs the bench running.

```bash
benchbar users --search priya
benchbar users --json --limit 200
```

## autostart

```
benchbar autostart on|off
```

Whether the bench may come back after login, when it was running before.
Without an argument it says which it is.

Exit codes: 0; 1 for another argument, or when the agent could not be
written.

```bash
benchbar autostart off
```

## listen

```
benchbar listen [local|all] [--bench-dir PATH] [--dry-run] [--yes]
```

Where the bench's web server (`bench serve`, with Frappe's debugger and
developer mode) and socketio listen. Since 0.9.0 the default is `local`:
both listen on 127.0.0.1 only, so another device on your Wi-Fi, a VPN or
the internet cannot reach them. `all` is what Frappe does on its own: every
interface, so `http://<this computer's address>:8000` answers for anyone
who can reach the computer. Without an argument it says which one the
bench has.

The choice is kept per bench, in the bench's state file, and written into
`Procfile.lean` the way the scheduler choice is, so `repair` and `service`
keep it. A running bench takes it at its next `benchbar restart`. The bench's
Redis and MariaDB were already on 127.0.0.1 only.

`local` starts the web line with `PYTHONPATH="$PWD/config/benchbar-listen..."` and
the socketio line with `NODE_OPTIONS="--require \"$PWD/config/benchbar-listen/socketio.js\" ..."`
(absolute, because `bench serve` changes into `sites/` before it starts the server).
The two files in `config/benchbar-listen` are written by benchbar from its
templates: the first replaces werkzeug's `run_simple` so that Frappe's host
`0.0.0.0` becomes `127.0.0.1`, the second gives `server.listen(port)` a
host. Neither Frappe v15 nor v16 has a setting for the host, which is why
the files exist. `all` leaves both lines as plain `bench serve` and
`bench socketio`.

`all` is a person's decision. It asks first (`--yes` answers it), and it is
refused under `--for-agent`, `mcp` and `BENCHBAR_NONINTERACTIVE`, like
`lan-guard`. `local` is always allowed. `benchbar doctor` warns for as long
as a bench is set to `all`, or listens on a non loopback address.

On Windows (WSL 2) Edge and Chrome still reach the site at
`http://<site>.localhost:8000`: WSL forwards `localhost` to a port that
listens on 127.0.0.1 in the distro (see [Windows](../../windows.md#localhost-names)).
A phone or another PC on your network no longer reaches the bench by the
address of the computer; `benchbar listen all` brings that back.

The Python realtime server of `socketio_backend: python` (Frappe v16 with a
bench that has the key) is not covered: it listens on every interface
whatever this setting says, and `doctor` reports it as not covered yet. A
restart does not change that; switching the bench to the node socketio server
does.

Exit codes: 0; 1 for another argument, a refused `all`, or when the files
could not be written.

```bash
benchbar listen            # which one
benchbar listen all        # asks first
benchbar listen local && benchbar restart
```

## mariadb-password

```
benchbar mariadb-password [--yes]
```

Prints the MariaDB root password kept in the Keychain (item
`benchbar-mariadb`; on Linux a 0600 file in the state folder), after
asking. `--yes` skips the question, not the person: the command is for a
person at a terminal. It is refused under `BENCHBAR_NONINTERACTIVE`,
`--for-agent` and `benchbar mcp`, and when stdin is not a terminal,
whatever `--yes` says, so the documented agent modes and a plain pipe do not
put the password in an agent's output. A process that runs as the same user
and fakes a terminal is not stopped, and any program of that user can read
the Keychain item through `security` (see SECURITY.md): these are guards
against mistakes, not a boundary. An agent that needs the password asks the
person.

Exit codes: 0 printed; 1 declined, no password in the Keychain, or
refused because no person is at a terminal.

```bash
benchbar mariadb-password
```

## uninstall-service

```
benchbar uninstall-service [--bench-dir DIR | --all] [--yes] [--dry-run]
```

Stops the bench (like `benchbar down`), then removes its launchd agent,
the runner and `Procfile.lean`, after asking. It also removes the
`# >>> benchbar >>>` block from your shell rc file, so `benchup` and the
other helpers are gone for every bench until `benchbar repair` or
`benchbar service` on a remaining bench writes the block again. The
bench, its sites, apps and databases are not touched; the plist is moved
to `~/Library/LaunchAgents-disabled/` and the other files are backed up
first. `--dry-run` shows the steps.

When the folder is no longer a bench (emptied by a cleanup tool, or
deleted) but its agent is still installed, it removes only that agent:
every `com.benchbar.*` agent whose working directory is the path is
booted out and its plist moved aside. Such an agent otherwise restarts
every 20 seconds, exits with code 127 and fills the log; doctor's
[`dead_agents`](../../guides/doctor-and-repair.md#dead_agents) check
points here.

With `--all` it does the same for every bench that has a benchbar agent
in `~/Library/LaunchAgents`, one after the other, after one question
that lists them; a folder that is no bench any more loses only its
agent. Run it before `brew uninstall benchbar`: Homebrew cannot stop the
agents itself. A bench that fails (launchd keeps its job) does not stop
the others; run it again for what is left.

| Flag | What it does |
|---|---|
| `--all` | Every bench with a benchbar agent, after one question; not with `--bench-dir` |
| `--yes` | Do not ask. Required without a terminal: a run with no terminal and no `--yes` is refused |
| `--dry-run` | Show the steps, change nothing |

Exit codes: 0; 1 declined, refused for lack of a terminal, no bench and no agent at the path, or with
`--all` a bench that could not be uninstalled.

```bash
benchbar uninstall-service --bench-dir ~/dev/v16-bench
benchbar uninstall-service --all
```

To remove BenchBar itself, see [Uninstall](../../install.md#uninstall).

## op

```
benchbar op status [OP_ID] [--json]
benchbar op list [--running] [--limit N] [--json]
benchbar op wait OP_ID [--timeout SECS] [--json]
```

Every run that changes things (`install`, `repair`, `up`, `app add`, `site
restore`, `pull` and the rest, but not a dry run or a command that only
reads) has an **op_id**, like `op-20261119-101500-4242`. It is in the
`plan`, `step`, `progress` and `done` lines of the run's JSON stream and in
the one document of a `--json` command, and the run keeps a small record
of itself in `ops/` in benchbar's state folder: its command, bench, site,
when it started, its pid, the step that runs, the last progress line, its
exit and its log. The record is rewritten at every step, so a program that
did not start the run can follow it. The newest 100 records are kept.

| Command | What it does |
|---|---|
| `op status OP_ID` | One operation. With `--json` it is the record, plus the run's `done` line as `result` once the run ended (for a run started with `--background`). Without an op_id: the ten newest |
| `op list` | The operations, newest first (`--running`: only the ones that run now; `--limit N`, 1 to 100, default 20) |
| `op wait OP_ID` | Waits until the operation is not running, then prints it. `--timeout SECS` gives up waiting; the operation goes on |

`state` is `starting` (a `--background` run that has not taken over yet),
`running`, `done`, `failed` (it ended with an exit other than 0) or
`interrupted`: the record says `running` but its process is gone (or its pid
belongs to another process now), so the run was killed and wrote no `done` line. Check `log` for how far it got.
`op wait` exits 0 when the run ended with exit 0 and 1 for anything else (a
failed run, an interrupted one, a timeout: `--json` says which, with
`timed_out: true` for a timeout). The `op` commands only read; they take no
lock and need no bench. The fields are in the
[JSON schema](../../json-schema.md#operation-handles-09).

### --background

```
benchbar site restore NAME --from STAMP --apply TOKEN --yes --background --json
```

`--background` starts the command again, detached, and returns at once with
the op_id. The run's JSON lines go to `ops/OP_ID.jsonl` (its `done` line is
`result` in `op status --json`), and `op status` and `op wait` follow it. It
is for the commands that take minutes: `install`, `repair`, `pull`,
`app add`, `app update`, `site add`, `site backup` and `site restore`. A
command that takes seconds (`up`, `down`, `restart`, `service`, `adopt`)
runs in front, and a command only a person runs (`share`, `lan-guard`,
`labs on`, `site open-as on`, `listen all`, `mariadb-password`,
`uninstall-service`) never runs unattended, so `--background` refuses them.

A run nobody watches cannot ask: `--background` implies
`BENCHBAR_NONINTERACTIVE=1`, so it needs `--yes` and the inputs in the
environment (`ADMIN_PASSWORD`, `MARIADB_ROOT_PASSWORD`, a `sudo` that does
not ask), and refuses before it starts when one is missing, as an agent run
does. It refuses `--dry-run` (a plan is instant) and
`BENCHBAR_SUDO_PASSWORD` (the password travels on a pipe the detached run
cannot read; cache the sudo credential, or run in front). The launcher waits up
to 5 seconds for the run to hold its lock: when another run holds it, that is the
launcher's refusal (the run's message, exit 1) and nothing was started. Else it
prints `{"op_id", "command", "state": "running", "pid", "output", "next_actions"}`
with `--json`, or two lines of text.

Exit codes: 0; 1 for an op that does not exist, a bad id or option, and
for `op wait` when the operation did not end with exit 0.

```bash
benchbar app add acme --apply TOKEN --yes --background --json   # {"op_id": "op-20261119-101500-4242", ...}
benchbar op status op-20261119-101500-4242
benchbar op wait op-20261119-101500-4242 --timeout 1800 --json
```

## commands

Experiments that are off are left out: see [labs](labs.md).

```
benchbar commands --json
```

Every command and subcommand as one JSON document: its usage line, a
summary, its flags with a line of help each, its environment variables,
and what it needs. The needs are `tty` (it may ask a question), `sudo`
and `network`. The document also says whether the command changes things
(`mutating`) and what `--json` gives (`json`: `document`, `stream` or
`none`). The same table prints `benchbar COMMAND --help`. Agents use it
to find out what a command does before they run it.

Exit codes: 0.

```bash
benchbar commands --json
```

## notices

```
benchbar notices [--json] [--dismiss ID|--all]
```

The notices an update left behind. A release that changes a default shows
one notice for it: what changed, the one command or variable that switches
it back, and a link to [What's new](../../whats-new.md). The first command you
type in a terminal after the update prints them once on stderr. They are not
printed for `--json`, `--for-agent`, `benchbar mcp` or
`BENCHBAR_NONINTERACTIVE=1`, and not after a fresh install. The Mac app shows
them as a banner in its window.

`benchbar notices` lists the ones still active. Until you dismiss them they are
also in `status --json` as `notices[]`, each with `id`, `title`, `text`,
`switch_back`, `doc` (a full URL) and `since`. `--dismiss ID` hides one and
`--all` hides every one, in the terminal list, in `status --json` and in the
app. An id that is hidden already is unchanged. The ids are `listen-local`,
`unknown-flags` and `pull-neutralise`.

Exit codes: 0; 1 for an unknown id or option.

```bash
benchbar notices --json
benchbar notices --dismiss listen-local
```

## help and version

```
benchbar --help
benchbar COMMAND --help
benchbar --version
```

`--help` (or `-h`, or `benchbar help`) prints every command and option.
`benchbar COMMAND --help` prints the usage, the flags and the needs of
one command (for example `benchbar logs --help`). `--version` prints
`benchbar` and the version.

## Flags, needs and environment

These tables come from the code (`benchbar commands --json`); the sections above explain them.

<!-- generated:cli-commands list console db open users autostart listen notices mariadb-password uninstall-service report self-update where docs op commands help -->
<!-- Generated by scripts/docs-reference.py from the code. Edit the code, then run: python3 -I scripts/docs-reference.py --write -->

| Command | Terminal | `sudo` | Network | Changes things | JSON |
|---|---|---|---|---|---|
| `benchbar mariadb-password [--yes]` | yes | no | no | no | none |
| `benchbar list [--json]` | no | no | no | no | document |
| `benchbar autostart [on\|off]` | no | no | no | yes | none |
| `benchbar listen [local\|all] [--dry-run] [--yes]` | yes | no | no | yes | none |
| `benchbar uninstall-service [--all] [--yes] [--dry-run]` | yes | no | no | yes | none |
| `benchbar console [--site S]` | yes | no | no | no | none |
| `benchbar db [--site S]` | yes | no | no | no | none |
| `benchbar open [--site S] [--as USER] [--path P] [--no-browser] [--print-url] [--json]` | no | no | no | no | document |
| `benchbar users [--site S] [--search Q] [--limit N] [--json]` | no | no | no | no | document |
| `benchbar report [--print] [--json]` | no | no | no | no | document |
| `benchbar docs [TOPIC] [--print]` | no | no | no | no | none |
| `benchbar self-update [--check] [--dry-run] [--json]` | yes | no | yes | yes | document |
| `benchbar where [--json]` | no | no | no | no | document |
| `benchbar op status\|list\|wait ...` | no | no | no | no | none |
| `benchbar op status [OP_ID] [--json]` | no | no | no | no | document |
| `benchbar op list [--running] [--limit N] [--json]` | no | no | no | no | document |
| `benchbar op wait OP_ID [--timeout SECS] [--json]` | no | no | no | no | document |
| `benchbar help` | no | no | no | no | none |
| `benchbar commands --json` | no | no | no | no | document |
| `benchbar notices [--json] [--dismiss ID\|--all]` | no | no | no | no | document |

Terminal: may ask a question on a terminal. `sudo`: may run `sudo`. Network: may reach the network.
JSON: `document` is one JSON line, `stream` is JSON lines ending in a `done` line.

| Command | Flag | Value | What it does |
|---|---|---|---|
| `mariadb-password` | `--yes` |  | Do not ask (still refused without a person at a terminal). |
| `uninstall-service` | `--all` |  | Every bench with a benchbar agent, after one question. |
| `uninstall-service` | `--yes` |  | Do not ask; required without a terminal. |
| `open` | `--as` | `USER` | Sign in as this user, no password. Refused unless site open-as is on for the site and developer_mode is on. A sign in runs the apps' on_login and on_session_creation hooks as a real login does: last_login, an Activity Log entry, a mail to System Managers for Administrator, an ERPNext Customer or Supplier for a Website User, and Frappe may end the user's oldest session (simultaneous_sessions). |
| `open` | `--path` | `P` | Where to land, for example /app/todo. Default: /app, or / for a Website User. |
| `open` | `--no-browser` |  | Start the session, open nothing. |
| `open` | `--print-url` |  | Print the link (it holds the session id) instead of opening it; in --json as url. With --as, refused under BENCHBAR_NONINTERACTIVE, --for-agent and mcp. |
| `open` | `--json` |  | One JSON document; url only with --print-url. |
| `users` | `--search` | `TEXT` | Only users whose id or full name contains TEXT. |
| `users` | `--limit` | `N` | At most N users (1 to 500, default 50). |
| `users` | `--json` |  | One JSON document. |
| `report` | `--print` |  | Print to the terminal instead of writing the zip. |
| `report` | `--out` | `DIR` | Write the zip into this folder (default: the Desktop). |
| `docs` | `--print` |  | Print the page's address instead of opening it. |
| `self-update` | `--check` |  | This version against the latest. |
| `op list` | `--running` |  | Only the ones that run now. |
| `op list` | `--limit` | `N` | At most N (1 to 100, default 20). |
| `op wait` | `--timeout` | `SECS` | Give up after SECS seconds (the operation goes on); default: wait for it. |
| `notices` | `--json` |  | One JSON document: notices[] with id, title, text, switch_back, doc and since. |
| `notices` | `--dismiss` | `ID` | Hide one notice (also in the BenchBar app). An id that is already hidden is unchanged. |
| `notices` | `--all` |  | Hide every notice. |

| Command | Environment variable | What it does |
|---|---|---|
| `list` | `BENCHBAR_LOAD_ALL` | Debugging switch: 1 loads every library, as before the lean start (the output is the same; use it to see whether a problem comes from the lean load). |
| `where` | `BENCHBAR_LOAD_ALL` | Debugging switch: 1 loads every library, as before the lean start (the output is the same; use it to see whether a problem comes from the lean load). |
| `commands` | `BENCHBAR_LENIENT_FLAGS` | Applies to every command: 1 turns the error for an unknown option (exit 64) back into a warning on stderr, as before 0.9.0, for a script that passed options a command never read. Without it a typo of --dry-run next to --yes can no longer run for real. |
| `commands` | `BENCHBAR_LOAD_ALL` | Debugging switch: 1 loads every library, as before the lean start (the output is the same; use it to see whether a problem comes from the lean load). |
<!-- /generated:cli-commands -->
<!-- Generated by scripts/docs-reference.py from the code. Edit the code, then run: python3 -I scripts/docs-reference.py --write -->

| Command | Terminal | `sudo` | Network | Changes things | JSON |
|---|---|---|---|---|---|
| `benchbar mariadb-password [--yes]` | yes | no | no | no | none |
| `benchbar list [--json]` | no | no | no | no | document |
| `benchbar autostart [on\|off]` | no | no | no | yes | none |
| `benchbar listen [local\|all] [--dry-run] [--yes]` | yes | no | no | yes | none |
| `benchbar uninstall-service [--all] [--yes] [--dry-run]` | yes | no | no | yes | none |
| `benchbar console [--site S]` | yes | no | no | no | none |
| `benchbar db [--site S]` | yes | no | no | no | none |
| `benchbar open [--site S] [--as USER] [--path P] [--no-browser] [--print-url] [--json]` | no | no | no | no | document |
| `benchbar users [--site S] [--search Q] [--limit N] [--json]` | no | no | no | no | document |
| `benchbar report [--print] [--json]` | no | no | no | no | document |
| `benchbar docs [TOPIC] [--print]` | no | no | no | no | none |
| `benchbar self-update [--check] [--dry-run] [--json]` | yes | no | yes | yes | document |
| `benchbar where [--json]` | no | no | no | no | document |
| `benchbar op status\|list\|wait ...` | no | no | no | no | none |
| `benchbar op status [OP_ID] [--json]` | no | no | no | no | document |
| `benchbar op list [--running] [--limit N] [--json]` | no | no | no | no | document |
| `benchbar op wait OP_ID [--timeout SECS] [--json]` | no | no | no | no | document |
| `benchbar help` | no | no | no | no | none |
| `benchbar commands --json` | no | no | no | no | document |
| `benchbar notices [--json] [--dismiss ID\|--all]` | no | no | no | no | document |

Terminal: may ask a question on a terminal. `sudo`: may run `sudo`. Network: may reach the network.
JSON: `document` is one JSON line, `stream` is JSON lines ending in a `done` line.

| Command | Flag | Value | What it does |
|---|---|---|---|
| `mariadb-password` | `--yes` |  | Do not ask (still refused without a person at a terminal). |
| `uninstall-service` | `--all` |  | Every bench with a benchbar agent, after one question. |
| `uninstall-service` | `--yes` |  | Do not ask; required without a terminal. |
| `open` | `--as` | `USER` | Sign in as this user, no password. Refused unless site open-as is on for the site and developer_mode is on. A sign in runs the apps' on_login and on_session_creation hooks as a real login does: last_login, an Activity Log entry, a mail to System Managers for Administrator, an ERPNext Customer or Supplier for a Website User, and Frappe may end the user's oldest session (simultaneous_sessions). |
| `open` | `--path` | `P` | Where to land, for example /app/todo. Default: /app, or / for a Website User. |
| `open` | `--no-browser` |  | Start the session, open nothing. |
| `open` | `--print-url` |  | Print the link (it holds the session id) instead of opening it; in --json as url. With --as, refused under BENCHBAR_NONINTERACTIVE, --for-agent and mcp. |
| `open` | `--json` |  | One JSON document; url only with --print-url. |
| `users` | `--search` | `TEXT` | Only users whose id or full name contains TEXT. |
| `users` | `--limit` | `N` | At most N users (1 to 500, default 50). |
| `users` | `--json` |  | One JSON document. |
| `report` | `--print` |  | Print to the terminal instead of writing the zip. |
| `report` | `--out` | `DIR` | Write the zip into this folder (default: the Desktop). |
| `docs` | `--print` |  | Print the page's address instead of opening it. |
| `self-update` | `--check` |  | This version against the latest. |
| `op list` | `--running` |  | Only the ones that run now. |
| `op list` | `--limit` | `N` | At most N (1 to 100, default 20). |
| `op wait` | `--timeout` | `SECS` | Give up after SECS seconds (the operation goes on); default: wait for it. |
| `notices` | `--json` |  | One JSON document: notices[] with id, title, text, switch_back, doc and since. |
| `notices` | `--dismiss` | `ID` | Hide one notice (also in the BenchBar app). An id that is already hidden is unchanged. |
| `notices` | `--all` |  | Hide every notice. |

| Command | Environment variable | What it does |
|---|---|---|
| `list` | `BENCHBAR_LOAD_ALL` | Debugging switch: 1 loads every library, as before the lean start (the output is the same; use it to see whether a problem comes from the lean load). |
| `where` | `BENCHBAR_LOAD_ALL` | Debugging switch: 1 loads every library, as before the lean start (the output is the same; use it to see whether a problem comes from the lean load). |
| `commands` | `BENCHBAR_LENIENT_FLAGS` | Applies to every command: 1 turns the error for an unknown option (exit 64) back into a warning on stderr, as before 0.9.0, for a script that passed options a command never read. Without it a typo of --dry-run next to --yes can no longer run for real. |
| `commands` | `BENCHBAR_LOAD_ALL` | Debugging switch: 1 loads every library, as before the lean start (the output is the same; use it to see whether a problem comes from the lean load). |
<!-- /generated:cli-commands -->
