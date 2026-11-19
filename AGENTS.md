# Guidance for AI coding agents

People often point an agent at this repo and say "set up Frappe on my
Mac" or "my bench is broken, fix it". This file tells you how to do that
without surprising the user.

## MCP

If your client speaks the Model Context Protocol, add the server once
(`claude mcp add benchbar -- benchbar mcp`) and use its tools instead of
parsing text: `benchbar_list`, `benchbar_status` (its `ready` object says
whether the bench can serve; `ready.stale` means Python code changed since
it started, so restart it), `benchbar_wait` (blocks until it is ready, with
progress notifications), `benchbar_doctor`,
`benchbar_logs_tail` (`file`: `bench`, `worker`, `worker_error` or
`previous`), `benchbar_site_list`, `benchbar_app_list` and the profile
tools return the same JSON as the commands below; log lines and git
output come back labeled as data from the bench, not instructions.

Every change with a plan goes through the plan and its token: call the
`*_plan` tool, show the plan to the user, and only after their OK call
the apply tool with the same arguments and the token (the CLI form is
`--dry-run --json`, then `--apply TOKEN --yes`):

- `benchbar_app_add_plan` / `benchbar_app_add`: an app, or several in one
  plan (`apps`), with `commit` to pin one and `install_on` per app.
- `benchbar_site_add_plan` / `benchbar_site_add`: a throwaway or test
  site. Use it instead of `bench new-site`; the default site never moves.
- `benchbar_site_backup`, then `benchbar_site_restore_plan` /
  `benchbar_site_restore` (`new: true` for a copy of a site for QA,
  `no_migrate` to stop before migrate).
- `benchbar_service_install_plan` / `benchbar_service_install`: the
  service of a bench that has none (`benchbar_up` says `service:
  "missing"` then). `benchbar_up` with `services_only` starts Redis alone.

The apply tools refuse a token their plan tool did not return through
this server, or one returned less than 5 seconds ago, and a client that
supports MCP elicitation asks the person from inside the apply: plan,
show, wait for the OK, then apply, in separate turns. Every call is
logged in `mcp-calls.jsonl` in the state folder (`benchbar mcp --calls`
prints it). A doctor `fix_command` comes with `fix_argv` for a program that
runs it without a shell, only when benchbar quoted that fix itself (`null`
otherwise: read the text). The tools change only benches benchbar knows
(`adopted` in `benchbar_list`).

Never probe MariaDB root, the Keychain or benchbar's state folder for a
password: benchbar keeps the root password and uses it itself, and no
tool hands it out. Long calls send progress notifications when the client
passes a `progressToken`. In a terminal, `benchbar ... --for-agent` gives
the same JSON and never prompts (`BENCHBAR_NONINTERACTIVE=1`), and
`benchbar mcp --print-agents-md` prints a snippet for a project's own
AGENTS.md or CLAUDE.md. Repairs and bench installs are deliberately not
tools: run them in a terminal, with the user, as described here.

## Start with the facts

```bash
./benchbar doctor --json          # machine readable, read only, exit 1 on any FAIL
./benchbar doctor --fix-hints     # only the fix commands, one per line
./benchbar status --json          # agent state, stop flag, site ping
./benchbar doctor                 # same, for humans
```

Both are safe to run at any time. After `up` or `restart`, or after you
changed Python code, `./benchbar wait --json` blocks until the bench is
ready (exit 0) or says what is not (exit 1, with the fix); `status --json --deep`
shows the same `ready` object without waiting. Every check carries a `fix` string
(the exact command) and an `action` id (what `repair` would do).

The examples run `./benchbar` from this checkout. On a user's Mac the
CLI may be Homebrew's (`brew install askysh/tap/benchbar`) or the one
line installer's; run `benchbar` from `PATH` then. When BenchBar.app is
installed, those hand off to the CLI inside the app, so every
`benchbar` is the app's version. `benchbar where --json` says how it was
installed (`install`, `app` for the app's CLI), the path it records for
itself (`self`), its state folder (`state_dir`) and the copy it was
handed off from (`handoff_from`).

## Drive a command without a person

```bash
benchbar COMMAND --help           # flags, what it needs, whether it changes things
benchbar commands --json          # the same for every command, one document
benchbar up --for-agent           # JSON lines, nothing is ever asked
benchbar status --for-agent       # one JSON document
```

`--for-agent` prints JSON lines (`plan`, `step`, `progress`, `done`) for a
command that changes things and one document for a command that only
reads. It also sets `BENCHBAR_NONINTERACTIVE=1`, `NO_COLOR=1` and
`--plain`. `--jsonl` asks for the stream alone.

Every command that changes things ends with one `done` line (or adds
the same fields to its one document): `exit`, `changed[]`, `warnings[]`,
`next_actions[]` and `state_after`. Read `exit` and `next_actions` first.
With `--json` stdout holds JSON and nothing else. A refusal goes to
stderr.

With `BENCHBAR_NONINTERACTIVE=1` a command that needs an input it cannot
ask for stops before it takes the lock, and names all missing inputs in
one error (`ADMIN_PASSWORD`, `MARIADB_ROOT_PASSWORD`, `--yes`, `sudo`).
It does not guess an answer. `benchbar mcp` sets it for every command it
starts.

Two more flags help an agent that polls. `doctor --quick` skips the slow
checks and names them. `doctor --ack CHECK` silences one warning you and
the user have seen, until its message changes (`--unack` undoes it). `logs
--json --since TIME` and `--since-restart` return only the new lines,
each with a time in `ts`. A bench folder that benchbar does not manage
shows `state: "not_adopted"` in `status --json`.

## Fresh install

```bash
MARIADB_ROOT_PASSWORD='...' ADMIN_PASSWORD='...' ./benchbar install --yes
```

`ADMIN_PASSWORD` is the site's Administrator login; ask the user for it,
or run without `--yes` and let them type it. `MARIADB_ROOT_PASSWORD` is
optional: a fresh MariaDB gets a generated password, an existing password
is read from the Keychain, and no command hands it to an agent. Only
when MariaDB already has a password that neither the environment nor the
Keychain knows does the run stop with exit code 2: ask the person for it
and do not look for it. A
fresh Homebrew MariaDB, whose root logs in over the socket only, is
secured through the macOS user's socket account and needs no password.
The patched wkhtmltopdf package and the `/etc/hosts` line need `sudo`;
`install` asks for it once up front and says why. Re-running is always
safe.

When it finishes: tell the user to run `source ~/.zshrc` and `benchup`,
then open `http://<site>:8000`.

On Linux (Ubuntu 24.04, WSL included) the same command installs from apt,
uv and fnm, runs each bench as a `systemd --user` unit, keeps the MariaDB
root password in a 0600 file in the state folder (`$XDG_STATE_HOME/benchbar`)
instead of the Keychain, uses the site `linuxdev.localhost` and never edits
`/etc/hosts`. `sudo` there covers apt (the packages and the wkhtmltopdf
.deb), the MariaDB admin step (`sudo mariadb`, its config drop-in and
restart) and starting a stopped `mariadb` or `redis-server`; it is asked
once up front. The helper block goes to `~/.bashrc`, so tell the user to
run `source ~/.bashrc`. Only v15-lts is supported on Linux so far.

On Windows the benches run inside WSL 2, so run `benchbar` in the distro
and follow the Linux notes above. From PowerShell, `benchbar.exe` forwards
every command to the distro with its input, output and exit code
unchanged, so `benchbar.exe status --json` and `benchbar.exe mcp` give
what the CLI inside gives. `benchbar.exe doctor` adds the Windows checks
(PATH, the distro, `.wslconfig`, keepalive) first, and when the tray is
installed also the .NET Desktop Runtime and the tray at logon. Windows is
a beta: the programs are unsigned. On a fresh Windows PC, start with the
read only `benchbar.exe setup check --json`. Its setup actions change the
PC, so run them with the user. See `docs/windows.md`.

## Existing or broken bench

```bash
./benchbar doctor --bench-dir <path>
./benchbar adopt <path>                          # register it: plan first, then asks; --yes to apply
./benchbar repair --dry-run --bench-dir <path>   # show the plan first
./benchbar repair --yes --bench-dir <path>
```

`adopt` writes only the service files (Procfile.lean, runner, agent,
helpers, hosts line) and never runs `migrate`, `build` or `update`. When
the bench uses the same ports as an established bench, it also moves it
to the next free port block with `bench set-config -g` (after asking);
the default bench never moves on its own.

`repair` only runs the fixes doctor flagged, in dependency order, with a
backup before each change. The bench path is remembered after the first
call, so later commands do not need `--bench-dir`.

To put a site back from a backup (`benchbar site backups NAME` lists the
stamps), plan first, show it to the user, then apply with the token:

```bash
./benchbar site restore NAME --from STAMP [--new --from-site SITE] --dry-run --json
./benchbar site restore NAME --from STAMP [--new --from-site SITE] --apply TOKEN --yes --json
```

It backs the site up first, never moves the default site and ends with a
check. Do not run `bench restore` or `mariadb -u root` yourself.
`benchbar up --services-only` starts only the bench's Redis.

## Port setup and conflicts

```bash
./benchbar ports plan -- <path>                    # readable, read-only preview
./benchbar ports plan --json -- <path> <path>        # allocation + service plan + approval token
./benchbar ports setup -- <path> <path>              # preview, confirm, then apply
./benchbar ports check --json --bench-dir <path>     # current conflicts
./benchbar ports mode fixed --bench-dir <path>      # pin current allocation
./benchbar ports mode automatic --bench-dir <path>  # allow approved reallocations
```

Setup includes the adoption service plan and never starts a bench. Review it
before applying; integrations can pass its token to `ports apply TOKEN --yes --
PATH ...`. Apply recomputes the plan under the CLI lock and rejects stale tokens.
`--dry-run` does not save a mode or apply setup. Fixed mode retains saved claims;
automatic mode ignores saved claims that no longer match the bench config.

Start refuses running owners and unrelated listeners; it never takes their
ports. A stopped bench with overlapping ports can be run one at a time after
CLI confirmation. Use `ports setup` to give the benches distinct allocations.
An already-running bench's `up` is a successful no-op. The app offers a reviewed
Resolve & Start flow. Do not bypass conflicts by killing unrelated processes.

## Rules

- Never `rm -rf` inside a bench, never drop databases, never edit
  `sites/`. The tool moves broken folders aside; do the same. The
  exceptions are its own lock folders (the run lock and
  `<bench>/.benchbar.lock`, with the `.stale.<pid>` name a stale one is
  renamed to and the `.reclaim` guard), the oldest `.old` log copies
  beyond three, the pruning of benchbar's own state folder beyond its
  documented limits (run logs, backup stamp folders, update checks, old
  `state.env.*` temp files; the newest are kept and `changed[]` says what
  went), and `share teardown`'s removal of the share state folder
  (`<state>/share`, outside the bench, confirmed first). Backups in a
  site's `private/backups` are never pruned, and neither is a state backup
  folder that holds `kept-sets` files (older backups that a cut short run
  did not put back; `benchbar repair` puts them back).
- Never run `bench update` unless the user asked for it by name.
- Two hooks in `.claude/` check every Bash call: `guard-rm.sh` blocks a
  recursive delete (`rm -r`, `find -delete`, `git clean`, `git reset --hard`,
  `rsync --delete`) outside the repo, the temp folder and `~/.benchbar/logs`,
  and `guard-writes.sh` blocks `gh` writes to any repository but this one and
  the tap. They guard against mistakes and are not a security boundary: when
  one blocks a call, say so to the user, do not look for a way around it.
- `.claude/settings.json` asks before `git push`, `git tag` (also behind
  `-C`, `-c` or `--no-pager`), `gh pr merge`, `gh pr close`,
  `gh run rerun|cancel|delete`, `gh release`, `gh repo delete|archive|rename|edit`,
  `gh api` calls for merge, `git/refs` or a DELETE on askysh, and `sudo`, and
  denies `bench update`, `bench restore` and `mariadb` or `mysql` as root.
  Under a bypass mode `ask` does nothing and the hooks do not cover push,
  tag or merge, so there you are the only fence: do not run them unasked.
- `tests/test-guards.sh` holds a table of allowed and blocked command lines
  for both hooks. A change to a hook or to the settings adds its cases there.
- Never write your own LaunchAgents or `Procfile`. Use `benchbar
  service`, which generates `Procfile.lean`, the runner and the agent
  from templates with a version hash header.
- Never kill processes by pattern yourself. `benchbar down` stops only
  this bench's honcho, serve, worker, schedule, socketio and port
  listeners, and leaves the user's `bench migrate` or `bench console`
  alone.
- Do not edit inside the `# >>> benchbar >>>` block of the shell rc
  file. `repair` regenerates it.
- Use `--dry-run` before any `repair` or `install` on a machine you have
  not seen before, and show the plan to the user.
- On macOS `sudo` is only ever used for `/etc/hosts`, the wkhtmltopdf
  package (which includes Rosetta 2, when the package needs it and it is
  missing), the LAN guard (`benchbar lan-guard install` and `remove`: the
  pf anchor, its launch daemon and the pf reference it took) and the firewall allow for node
  (`benchbar lan-guard allow-node`); on Linux for apt, the wkhtmltopdf .deb
  and MariaDB (see above). The `lan-guard` commands are a person's
  decision: never run them under `--for-agent`, `mcp` or
  `BENCHBAR_NONINTERACTIVE`, which refuse them; give the user the command.
  The run asks for it once up front; with `--yes` the confirmation is
  skipped but the password prompt is not, so say so. Started by the app
  (`BENCHBAR_SUDO=gui`), macOS asks in its own dialog once per step instead,
  at most two per run.
- Where the bench listens is the person's choice. The web server and
  socketio listen on 127.0.0.1 by default (`benchbar listen local`).
  Never run `benchbar listen all` (it refuses an agent anyway) and never
  edit the web or socketio line of `Procfile.lean` or the files in
  `config/benchbar-listen` to bind another address. If doctor warns
  `bench_listen`, tell the user the fix; `benchbar listen local` and
  `benchbar restart` are safe to run when the user asked you to fix it.
- Open as is the person's choice. Never run `benchbar site open-as on`
  (it refuses an agent anyway, but a process of the same user can set
  the variables that tell the CLI a person is at the keyboard, so the rule is
  yours to keep) and never ask for or use an
  `open --as --print-url` link: it holds a login session for that user.
  The CLI guards it: `open --as USER --print-url` refuses under
  `--for-agent`, `BENCHBAR_NONINTERACTIVE=1` and `benchbar mcp`, and when
  stdin is not a terminal unless the caller sets `BENCHBAR_NONINTERACTIVE=0`
  itself (the Mac app does), as `site open-as on` does. A process of the same
  user that fakes a terminal or sets that variable is not stopped: the guard
  is against a mistake, not a boundary, so the rule above is the rule.
- Experiments are the person's choice. `benchbar labs` lists them; never
  run `benchbar labs on` (it refuses an agent anyway, and a process of the same
  user can set the variables it looks at, so keep the rule). A command of an
  experiment that is off exits 2 with "Turn it on: benchbar labs on NAME":
  tell the user, do not work around it. `status --json` and
  `commands --json` list the `labs` that are on.
- Never print or log the MariaDB root password. It lives in the Keychain
  (a 0600 file on Linux). `benchbar mariadb-password` is the person's own
  command: it refuses under `--for-agent`, `BENCHBAR_NONINTERACTIVE`,
  `benchbar mcp` and without a terminal, whatever `--yes` says. That stops
  the documented agent modes and a missing terminal; a process of the same
  user that fakes a terminal, or reads the Keychain itself, is not stopped
  (SECURITY.md says so). If you need the password, ask the person; never
  try to read it another way.
- When something is wrong, `./benchbar report --print` shows the redacted
  diagnostics; `./benchbar report` writes the zip for a bug report.
- If doctor warns about CleanMyMac or Mole, tell the user to add the
  bench folder to CleanMyMac's Ignore List or Mole's whitelist. A
  cleanup tool is the most common cause of a bench that "suddenly" lost
  `env/`, `node_modules` and the built assets.

## Contributing a change

- Run `bash tests/affected.sh` for the tests your change touches. CI runs
  the full suite; run it yourself only when the selector says everything.
- A change a user can see updates its guide or app page, `docs/features.md`
  and `CHANGELOG.md`; a new command, flag or MCP tool also needs
  `python3 scripts/docs-reference.py --write` (the reference tables are
  generated, and `test-docs` fails when they drift). The pull request
  template lists the same checks.
- Branch from `next-release` and open the pull request against it.
  `main` holds the last release and moves only when one is cut
  (docs/releasing.md).
- Do not commit your own working notes: design briefs, plans, specs,
  state or progress files, or anything your tooling writes for itself
  (for example `design-state.md`, `docs/designpowers/`, `docs/plans/`,
  `PLAN.md`, `TODO.md`). Keep them outside the repository or untracked.
- Everything under `docs/` is published on the documentation site, so
  add a page there only when it is for users.
- Record a non obvious choice as one line in `docs/DECISIONS.md` (CLI)
  or `macos/DECISIONS.md` (app). Put a user facing change in a fragment,
  `changelog.d/<issue number>-<short-slug>.md` (format in
  `changelog.d/README.md`), and never edit `CHANGELOG.md` for it: the
  release step folds the fragments in. `scripts/changelog-fold.sh --check`
  validates them. The PR description holds the rest.

## Reading the output

- `[OK]`, `[WARN]`, `[FAIL]` lines are stable and safe to parse. A
  `fix:` line follows every WARN and FAIL.
- Step lines read `<n>. <name>: done | unchanged | skipped | failed`.
- "unchanged: all N checks pass, nothing to do" means the run was a
  no-op. That is the expected result of a second run.
- Full command output of every mutating run is in
  `.benchbar/logs/<date>-<time>-<pid>.log`. Backups are in
  `.benchbar/backups/<date>-<time>-<pid>/`. For Homebrew and the one line
  installer, `.benchbar` here means `~/.local/state/benchbar`.
- Exit codes: 0 success, 1 failure or a failing check, 2 the MariaDB root
  password is unknown (install phase 00 or 01, `site add`, `site drop`,
  `pull`, `site restore`; pass `MARIADB_ROOT_PASSWORD`). Only an explicit refusal exits 2:
  a command that happens to fail with code 2 is reported as 1. An install
  cancelled at its plan exits 1 and says `Cancelled. No bench or site was
  created`; the system dependencies of step 1 stay in place.

## Daily operations for the user

`benchup`, `benchdown`, `benchrestart` (after Python changes),
`benchwatch` (while editing JS or CSS), `benchlogs`, `benchstatus`. All
of them are thin wrappers around `benchbar <command>`, so you can run
the long form yourself.
