---
title: "Coding agents and MCP"
description: "Let Claude Code, Cursor and other coding agents see and drive your Frappe benches through the benchbar MCP server, and what an agent should and should not run."
---

`benchbar mcp` is a Model Context Protocol server on stdio, so Claude
Code, Cursor and other agents can see and drive your benches:

```bash
claude mcp add benchbar -- benchbar mcp
```

For another client, add a stdio server whose command is `benchbar` with
the argument `mcp`.

## Tools

| Tool | What it does |
|---|---|
| `benchbar_list` | Every bench benchbar knows: path, default site, sites, ports, whether its service is installed |
| `benchbar_status` | Live state of one bench, with pid, ports, the `bench` its service runs (`bench_bin`), sites and the ping of every site while the bench runs. A bench folder benchbar does not manage has `state` `not_adopted` |
| `benchbar_doctor` | The read only health report of one bench, every check with its level and fix |
| `benchbar_logs_tail` | The last lines of one log file: `file` is `bench` (`logs/bench.log`, honcho's stream), `worker` (`logs/worker.log`, where the worker writes), `worker_error` or `previous`; `process` keeps one honcho process of `bench.log`. Each line has a time in `ts`; `since` (ISO 8601, a date or `HH:MM:SS` today) and `since_restart` keep only the newer lines |
| `benchbar_site_list` | The sites of one bench, the default, the hosts line, the ping code, the database name and the MariaDB port (never the password) |
| `benchbar_app_list` | Every app of one bench: repo, branch, commit, local changes, version, sites (from the last read, the database is not asked) and how far behind its dependencies it is |
| `benchbar_profile_list` | Built in and team profiles: where each comes from, how far a subscription is behind, what hides what |
| `benchbar_profile_check` | Whether git can read every repo of a team profile (`name`) with your credentials, and which apps `install --profile` would leave out |
| `benchbar_up` | Start a bench and wait for its default site |
| `benchbar_down` | Stop a bench and keep it stopped, also across reboots |
| `benchbar_restart` | Restart every process of a bench |
| `benchbar_app_add_plan` | The plan of adding an app from a git URL or a known name, with its token (read only) |
| `benchbar_app_add` | Apply that plan: needs the token, returns the output and a fresh app list |

`benchbar_list`, `benchbar_status`, `benchbar_doctor`,
`benchbar_logs_tail`, `benchbar_site_list`, `benchbar_app_list`,
`benchbar_profile_list`, `benchbar_profile_check` and
`benchbar_app_add_plan` read; `benchbar_up`, `benchbar_down`,
`benchbar_restart` and `benchbar_app_add` act. Each one runs
`benchbar ... --json` and returns what the CLI printed. The server sets
`BENCHBAR_NONINTERACTIVE=1`, so a command that needs an answer it cannot
ask for stops and names the missing input. An action also returns the
CLI's `done` line as `result`, with `changed`, `warnings` and
`next_actions`, next to the fresh status. Nothing that
repairs, installs a bench or needs `sudo` is offered. It needs only
`python3`, which the Command Line Tools provide.

Calls run side by side: a status answers while an app add runs, and the
client can cancel a running call (`notifications/cancelled`), which
stops the CLI and everything it started. Arguments are checked against
the schema first; a bad value (`lines: 99999`, `process: "nope"`) is a
tool error that names the rule. What the bench itself says, log lines,
git output, `hooks.py`, profile files and the output of an action, comes
back with a first line that labels it as data from the bench, not
instructions, with terminal colors removed and a 200 kB cap; the
[mcp reference](../reference/cli/mcp.md) has the details.

## Adding an app

Paste a GitHub URL into the chat and the agent can add the app, from a
plan it should show you first. Adding an app runs its code on your Mac:
its Python and Node requirements are installed and, on each site you
name, `bench install-app` runs its install hooks and writes its tables
into that site's database. A running bench is restarted at the end. So
add only repos you trust, and read the plan:

1. `benchbar_app_add_plan` with `url_or_name` (and `branch`, `name`,
   `site` or `all_sites`) reads the repo and its `hooks.py` and returns
   the plan: repo, branch, the required apps and where each comes from,
   the sites, the steps, and a `token`. Nothing changes.
2. The agent shows you that plan and waits for your OK. benchbar cannot
   tell whether you saw it: the token proves only that the bench has not
   changed since the plan, and the tool says so. What the server does
   check: the token must come from a plan it returned, at least 5 seconds
   ago, so a plan and its apply cannot run in one batch. And when your
   client supports MCP elicitation, the apply asks you itself, with the
   plan in the question, and runs only on your yes. Without elicitation
   the gate is your client's approval of the apply tool: keep it on
   "ask" for `benchbar_app_add` and the other apply tools, and do not
   auto approve them. The same holds for elicitation: a client that
   answers every question by itself, with nobody looking, defeats the
   gate, because its `accept` looks like yours. The question holds the
   whole plan (a plan over 20000 characters is cut, and the question says
   so).
3. `benchbar_app_add` with the same arguments and the `token` runs
   exactly that plan. If `sites/apps.txt`, `apps/` or the sites changed
   in between, the token is refused and the agent plans again.

The apply can take several minutes (clone, pip, yarn, build); the server
waits up to an hour and returns everything at the end. Some clients stop
waiting sooner: the run goes on, and `benchbar_status` or `app list`
shows the outcome.

Every tool but `benchbar_list` and the two profile tools takes an
optional `bench`, the absolute path from `benchbar_list`; without it the
tool acts on the default bench. The tools that change a bench refuse a
bench benchbar does not know. A folder that only looks like a bench
under `~` or `~/dev` is listed with `adopted: false` and is refused:
register it first in a terminal with `benchbar register PATH`, or name it
in your client's setup for that server (`benchbar mcp --allow-bench PATH`).

## What was run

Every call is logged in `mcp-calls.jsonl` in benchbar's state folder
(for Homebrew and the one line installer,
`~/.local/state/benchbar/mcp-calls.jsonl`): when, which client, which
tool, its arguments (anything named like a password, secret, token or
key is `***`, and so are the credentials of a URL) and how it ended. A
call that was rejected for its arguments logs only their names.
`benchbar mcp --calls 20` prints the last 20. After an agent session it
answers "what did it run, and in what order".

Fix commands in a doctor report come twice: the text, for you, and
`fix_argv` (with `fix_cwd`), an array a program can run without a shell.
It is there only when benchbar quoted the fix itself and it is one plain
command; for any other fix it is `null`: read the text then.
The JSON each one returns is described in the [JSON schema](../json-schema.md).

## The CLI as an agent contract

An agent that runs `benchbar` in a terminal gets the same contract as the
MCP tools:

```bash
benchbar COMMAND --help      # flags, what the command needs, whether it changes things
benchbar commands --json     # the same for every command, flag and environment variable
benchbar up --for-agent      # JSON lines, nothing is ever asked
benchbar doctor --for-agent  # one JSON document
```

- `--for-agent` prints JSON lines (`plan`, `step`, `progress`, `done`) for
  a command that changes things, and one document for a command that
  only reads. It also sets `BENCHBAR_NONINTERACTIVE=1`, `NO_COLOR=1` and
  `--plain`. `--jsonl` asks for the stream alone.
- The `done` line ends every command that changes things. It has `exit`,
  `changed[]` (what the run really changed), `warnings[]`,
  `next_actions[]` (the commands to run next, each with a reason) and
  `state_after` (the bench's `status --json` after the run). A second run
  that has nothing to do has an empty `changed`. The
  [JSON schema](../json-schema.md#the-done-fields-08) has every field.
- With `--json` stdout holds JSON and nothing else. A refusal is text on
  stderr.
- With `BENCHBAR_NONINTERACTIVE=1` a command that lacks an input
  (`ADMIN_PASSWORD`, `MARIADB_ROOT_PASSWORD`, `--yes`, a `sudo` that would
  ask) names all of them in one error before it takes the lock or touches
  the bench. It exits 2 when the MariaDB root password is one of them;
  then ask the person for it, do not look for it.
- Two commands are a person's and refuse in this mode and under MCP:
  `benchbar mariadb-password` (the root password) and `benchbar open --as
  USER --print-url` (a login session), whatever `--yes` says; both also
  refuse when stdin is not a terminal. That stops the documented agent modes
  and a missing terminal, not a process of the same user that fakes a
  terminal: they are guards against mistakes.
- `benchbar doctor --quick` skips the slow checks and names them.
  `doctor --ack CHECK` silences one warning until its message changes;
  `--unack CHECK` undoes it. A failure cannot be acknowledged, and
  `repair` ignores acknowledgements.
- `benchbar logs --json --since TIME` and `--since-restart` return the
  new lines only, each with its time in `ts`.

## Repairs and installs

Repairs and bench installs are deliberately not tools. An agent runs them in a
terminal, with you, and shows the plan first:

```bash
benchbar doctor --json
benchbar repair --dry-run
benchbar repair --yes
```

[AGENTS.md](../../AGENTS.md) in the repository is written for agents that
are pointed at BenchBar with "set up Frappe on my Mac" or "my bench is
broken, fix it": how to start from the facts, the rules they must keep
(never `rm -rf` inside a bench, never `bench update` unless asked, never
print the MariaDB root password, or a sign-in link), and how to read the
output.
