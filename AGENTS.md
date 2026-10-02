# Guidance for AI coding agents

People often point an agent at this repo and say "set up Frappe on my
Mac" or "my bench is broken, fix it". This file tells you how to do that
without surprising the user.

## MCP

If your client speaks the Model Context Protocol, add the server once
(`claude mcp add benchbar -- benchbar mcp`) and use its tools instead of
parsing text: `benchbar_status`, `benchbar_doctor`, `benchbar_logs_tail`
and friends return the same JSON as the commands below. Adding an app
goes through a plan and its token: call `benchbar_app_add_plan`, show
the plan to the user, and only after their OK call `benchbar_app_add`
with the same arguments and the token (the CLI form is `benchbar app add
URL --dry-run --json`, then `--apply TOKEN --yes`). Repairs and bench
installs are deliberately not tools: run them in a terminal, with the
user, as described here.

## Start with the facts

```bash
./benchbar doctor --json          # machine readable, read only, exit 1 on any FAIL
./benchbar doctor --fix-hints     # only the fix commands, one per line
./benchbar status --json          # agent state, stop flag, site ping
./benchbar doctor                 # same, for humans
```

Both are safe to run at any time. Every check carries a `fix` string
(the exact command) and an `action` id (what `repair` would do).

The examples run `./benchbar` from this checkout. On a user's Mac the
CLI may be Homebrew's (`brew install askysh/tap/benchbar`) or the one
line installer's; run `benchbar` from `PATH` then. When BenchBar.app is
installed, those hand off to the CLI inside the app, so every
`benchbar` is the app's version. `benchbar where --json` says how it was
installed (`install`, `app` for the app's CLI), the path it records for
itself (`self`), its state folder (`state_dir`) and the copy it was
handed off from (`handoff_from`).

## Fresh install

```bash
MARIADB_ROOT_PASSWORD='...' ADMIN_PASSWORD='...' ./benchbar install --yes
```

`ADMIN_PASSWORD` is the site's Administrator login; ask the user for it,
or run without `--yes` and let them type it. `MARIADB_ROOT_PASSWORD` is
optional: a fresh MariaDB gets a generated password, an existing password
is read from the Keychain (`benchbar mariadb-password` prints it). Only
when MariaDB already has a password that neither the environment nor the
Keychain knows does the run stop with exit code 2 and say what to pass.
The patched wkhtmltopdf package and the `/etc/hosts` line need `sudo`;
`install` asks for it once up front and says why. Re-running is always
safe.

When it finishes: tell the user to run `source ~/.zshrc` and `benchup`,
then open `http://<site>:8000`.

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
  `sites/`. The tool moves broken folders aside; do the same.
- Never run `bench update` unless the user asked for it by name.
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
- `sudo` is only ever used for `/etc/hosts` and the wkhtmltopdf package.
  The run asks for it once up front; with `--yes` the confirmation is
  skipped but the password prompt is not, so say so.
- Never print or log the MariaDB root password. It lives in the Keychain;
  `benchbar mariadb-password --yes` prints it when a user asks for it.
- When something is wrong, `./benchbar report --print` shows the redacted
  diagnostics; `./benchbar report` writes the zip for a bug report.
- If doctor warns about CleanMyMac or Mole, tell the user to add the
  bench folder to CleanMyMac's Ignore List or Mole's whitelist. A
  cleanup tool is the most common cause of a bench that "suddenly" lost
  `env/`, `node_modules` and the built assets.

## Contributing a change

- Do not commit your own working notes: design briefs, plans, specs,
  state or progress files, or anything your tooling writes for itself
  (for example `design-state.md`, `docs/designpowers/`, `docs/plans/`,
  `PLAN.md`, `TODO.md`). Keep them outside the repository or untracked.
- Everything under `docs/` is published on the documentation site, so
  add a page there only when it is for users.
- Record a non obvious choice as one line in `docs/DECISIONS.md` (CLI)
  or `macos/DECISIONS.md` (app), and user facing changes under
  `## Unreleased` in `CHANGELOG.md`. The PR description holds the rest.

## Reading the output

- `[OK]`, `[WARN]`, `[FAIL]` lines are stable and safe to parse. A
  `fix:` line follows every WARN and FAIL.
- Step lines read `<n>. <name>: done | unchanged | skipped | failed`.
- "unchanged: all N checks pass, nothing to do" means the run was a
  no-op. That is the expected result of a second run.
- Full command output of every mutating run is in
  `.benchbar/logs/<timestamp>.log`. Backups are in
  `.benchbar/backups/<timestamp>/`. For Homebrew and the one line
  installer, `.benchbar` here means `~/.local/state/benchbar`.
- Exit codes: 0 success, 1 failure or a failing check, 2 the MariaDB root
  password is unknown (phase 1 only; pass `MARIADB_ROOT_PASSWORD`).

## Daily operations for the user

`benchup`, `benchdown`, `benchrestart` (after Python changes),
`benchwatch` (while editing JS or CSS), `benchlogs`, `benchstatus`. All
of them are thin wrappers around `benchbar <command>`, so you can run
the long form yourself.
