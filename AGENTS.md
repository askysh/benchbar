# Guidance for AI coding agents

People often point an agent at this repo and say "set up Frappe on my
Mac" or "my bench is broken, fix it". This file tells you how to do that
without surprising the user.

## Start with the facts

```bash
./frappe-mac doctor --json          # machine readable, read only, exit 1 on any FAIL
./frappe-mac status --json          # agent state, stop flag, site ping
./frappe-mac doctor                 # same, for humans
```

Both are safe to run at any time. Every check carries a `fix` string
(the exact command) and an `action` id (what `repair` would do).

## Fresh install

```bash
MARIADB_ROOT_PASSWORD='...' ADMIN_PASSWORD='...' ./frappe-mac install --yes
```

Ask the user for the two passwords before you start, or run without
`--yes` and let the user type them. The first run usually exits with code
2 after phase 1 and prints manual steps (`mariadb-secure-installation`,
the patched-Qt `wkhtmltopdf` package). Relay them to the user verbatim,
including the answer table in README, wait, then run the same command
again. Re-running is always safe.

When it finishes: tell the user to run `source ~/.zshrc` and `benchup`,
then open `http://<site>:8000`.

## Existing or broken bench

```bash
./frappe-mac doctor --bench-dir <path>
./frappe-mac repair --dry-run --bench-dir <path>   # show the plan first
./frappe-mac repair --yes --bench-dir <path>
```

`repair` only runs the fixes doctor flagged, in dependency order, with a
backup before each change. The bench path is remembered after the first
call, so later commands do not need `--bench-dir`.

## Rules

- Never `rm -rf` inside a bench, never drop databases, never edit
  `sites/`. The tool moves broken folders aside; do the same.
- Never run `bench update` unless the user asked for it by name.
- Never write your own LaunchAgents or `Procfile`. Use `frappe-mac
  service`, which generates `Procfile.lean`, the runner and the agent
  from templates with a version hash header.
- Never kill processes by pattern yourself. `frappe-mac down` stops only
  this bench's honcho, serve, worker, schedule, socketio and port
  listeners, and leaves the user's `bench migrate` or `bench console`
  alone.
- Do not edit inside the `# >>> frappe-mac >>>` block of the shell rc
  file. `repair` regenerates it.
- Use `--dry-run` before any `repair` or `install` on a machine you have
  not seen before, and show the plan to the user.
- `sudo` is only ever used for `/etc/hosts`. With `--yes` that happens
  without a prompt, so say so.
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
  `.frappe-local/logs/<timestamp>.log`. Backups are in
  `.frappe-local/backups/<timestamp>/`.
- Exit codes: 0 success, 1 failure or a failing check, 2 manual steps
  pending (phase 1 only).

## Daily operations for the user

`benchup`, `benchdown`, `benchrestart` (after Python changes),
`benchwatch` (while editing JS or CSS), `benchlogs`, `benchstatus`. All
of them are thin wrappers around `frappe-mac <command>`, so you can run
the long form yourself.
