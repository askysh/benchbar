# Guidance for AI coding agents

People often point an agent at this repo and say "set up Frappe on my
Mac" or "my bench is broken, fix it". This file tells you how to do that
without surprising the user.

## MCP

If your client speaks the Model Context Protocol, add the server once
(`claude mcp add benchbar -- benchbar mcp`) and use its tools instead of
parsing text: `benchbar_status`, `benchbar_doctor`, `benchbar_logs_tail`
and friends return the same JSON as the commands below. Repairs and
installs are deliberately not tools: run them in a terminal, with the
user, as described here.

## Start with the facts

```bash
./benchbar doctor --json          # machine readable, read only, exit 1 on any FAIL
./benchbar status --json          # agent state, stop flag, site ping
./benchbar doctor                 # same, for humans
```

Both are safe to run at any time. Every check carries a `fix` string
(the exact command) and an `action` id (what `repair` would do).

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
- If doctor warns about CleanMyMac, tell the user to add the bench folder
  to its Ignore List. This is the most common cause of a bench that
  "suddenly" lost `env/`, `node_modules` and the built assets.

## Reading the output

- `[OK]`, `[WARN]`, `[FAIL]` lines are stable and safe to parse. A
  `fix:` line follows every WARN and FAIL.
- Step lines read `<n>. <name>: done | unchanged | skipped | failed`.
- "unchanged: all N checks pass, nothing to do" means the run was a
  no-op. That is the expected result of a second run.
- Full command output of every mutating run is in
  `.benchbar/logs/<timestamp>.log`. Backups are in
  `.benchbar/backups/<timestamp>/`.
- Exit codes: 0 success, 1 failure or a failing check, 2 the MariaDB root
  password is unknown (phase 1 only; pass `MARIADB_ROOT_PASSWORD`).

## Daily operations for the user

`benchup`, `benchdown`, `benchrestart` (after Python changes),
`benchwatch` (while editing JS or CSS), `benchlogs`, `benchstatus`. All
of them are thin wrappers around `benchbar <command>`, so you can run
the long form yourself.
