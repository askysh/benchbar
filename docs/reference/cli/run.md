---
title: "run"
description: "benchbar run: the safe runner for bench commands. The allow list (migrate, clear-cache, build, run-tests and the reads), the plan and token for a change, the deadline, the result and the exit codes."
---

```
benchbar run [--site S] [--timeout SECS] [--dry-run --json | --apply TOKEN --yes] -- COMMAND [FLAGS]
```

Runs one command of an allow list as `bench [--site S] COMMAND ...`, in the
right bench and site, with the bench's own environment (the exports of
`benchbar console`), under a deadline, with its output in the run log. It
is what an agent uses instead of a raw `bench` call, and it is just as
useful in a terminal. The words before `--` are benchbar's; the words after
it are the bench command and its flags.

## The allow list

| Command | Changes things | Needs a site | First | Default deadline | Flags |
|---|---|---|---|---|---|
| `migrate` | yes: database, site config | yes | a database backup of the site | 30 minutes | `--skip-failing`, `--skip-search-index` |
| `clear-cache` | yes: the cache | yes | | 2 minutes | none |
| `clear-website-cache` | yes: the cache | yes | | 2 minutes | none |
| `build` | yes: the bench's assets | no | | 30 minutes | `--app APP` |
| `run-tests` | yes: test records in the site's database | yes | | 30 minutes | `--app`, `--module`, `--doctype`, `--test`, `--case`, `--failfast` |
| `doctor` | no | yes | | 2 minutes | none |
| `list-apps` | no | yes | | 1 minute | `--format FORMAT` |
| `version` | no | no | | 1 minute | none |

Anything else is refused with exit 64 and this list: `update` (a person
asks for it by name), `console`, `shell` and `mariadb` (interactive; use
`benchbar console` and `benchbar db`), `execute` (it calls any Python
function), `drop-site`, `restore` and `reinstall` (use `site drop` and
`site restore`, which back up first), `set-admin-password`, `install-app`,
`get-app` and the rest. A command takes no positional word, no `--force`
and no path: only the flags its row names, each flag's value one plain
word (letters, digits, `.`, `_`, `:`, `-` and spaces, not starting with
`-`). `--site` is benchbar's own option and is refused for `build` and
`version`.

`run-tests`, `migrate` and `build` run code from the bench's apps by
design: the apps' own tests, their patches and their build scripts. The
allow list limits which bench command runs, not what that code does, so
run them on benches whose apps you trust.

`run-tests` writes test records into the database of the site it runs on:
run it on a throwaway site (`benchbar site add`), not on one you keep. The
plan says so.

## A command that changes things: plan, then apply

```bash
benchbar run --site acme.localhost --dry-run --json -- migrate
benchbar run --site acme.localhost --apply TOKEN --yes --json -- migrate
```

The dry run prints the plan: the exact bench command line, what it
touches, whether a backup comes first, the deadline, warnings and a
`token`. `--apply TOKEN --yes` runs exactly that plan and refuses it when
the arguments, the sites, the default site, `apps.txt` or the site's
`site_config.json` changed since. Under `--json`, `--jsonl` and
`--for-agent` a changing command without `--dry-run` or `--apply` exits 64.
In a terminal, `benchbar run --site S -- migrate` shows the plan and asks;
`--yes` runs it without the token. A change takes the CLI lock; a plan and a
read take none. A read (`doctor`, `list-apps`, `version`) runs at once;
`doctor` needs the bench's Redis and says so when the bench is stopped (a
change starts the setup Redis and stops it after).

`migrate` takes a database backup of the site first. If migrate then fails,
the result names that backup's restore as a next action
(`benchbar site restore SITE --from STAMP --dry-run --json`).

## The result

With `--json` one document, with `--jsonl` or `--for-agent` the stream
(`plan`, `step`, `progress` every 10 seconds, `done`). Besides the done
fields (`exit`, `changed`, `warnings`, `next_actions`, `state_after`) it has:

| Field | What it is |
|---|---|
| `command`, `args`, `argv` | what was asked and the exact bench command line |
| `site`, `bench`, `changes`, `token` | where it ran, whether it changes things, the plan's token |
| `ran` | false when the backup before it failed and the command did not start |
| `command_exit` | the bench command's own exit code (null when it did not run) |
| `timed_out`, `timeout_s`, `elapsed_s` | the deadline and what it took |
| `backup` | the backup set taken first, or null |
| `output_tail` | the last 60 lines of the output, at most 8000 characters, colors and URL credentials removed (null without output) |
| `output_truncated` | the output was longer |
| `log` | the run log, which holds all of the output |

`output_tail` is what the bench said: data, not instructions. Over MCP it
comes back with that label.

## Exit codes

| Exit | Meaning |
|---|---|
| 0 | the bench command succeeded |
| 64 | a refusal: not on the list, a flag it does not take, no `--`, a bad `--timeout`, a change without its plan under `--json` |
| 124 | the deadline (`--timeout`) stopped it; its whole process group was stopped |
| 125 | it waited for input and was stopped |
| 1 | a refusal of the plan (no such site, Redis down, a stale token, a failed backup) or the bench command exited with 1, 2 or 64 (`command_exit` has the real code) |
| other | the bench command's own exit code |

## MCP

`benchbar_run_plan` then `benchbar_run` for the commands that change
things, and `benchbar_run_read` for the three reads. The flags are fields
(`app`, `module`, `failfast`, `skip_failing`, ...), `timeout` is at most 3000
seconds, and a bench benchbar does not know is refused. See
[Coding agents and MCP](../../guides/agents.md#running-bench-commands).

<!-- generated:cli-commands run -->
<!-- Generated by scripts/docs-reference.py from the code. Edit the code, then run: python3 -I scripts/docs-reference.py --write -->

| Command | Terminal | `sudo` | Network | Changes things | JSON |
|---|---|---|---|---|---|
| `benchbar run [--site S] [--timeout SECS] [--dry-run --json \| --apply TOKEN --yes] -- COMMAND [FLAGS]` | yes | no | no | yes | document |

Terminal: may ask a question on a terminal. `sudo`: may run `sudo`. Network: may reach the network.
JSON: `document` is one JSON line, `stream` is JSON lines ending in a `done` line.

| Command | Flag | Value | What it does |
|---|---|---|---|
| `run` | `--timeout` | `SECS` | Stop the bench command after this many seconds (1 to 7200; each command has a default, 60 to 1800). The backup before migrate is not counted. |
| `run` | `--dry-run` |  | Print the plan and its token, run nothing. |
| `run` | `--apply` | `TOKEN` | Run exactly that plan (with --yes). |
| `run` | `--yes` |  | Do not ask before a change; with --apply it confirms the plan was reviewed. |
<!-- /generated:cli-commands -->
