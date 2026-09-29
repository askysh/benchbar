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
| `benchbar_status` | Live state of one bench, with pid, ports, sites and site ping |
| `benchbar_doctor` | The read only health report of one bench, every check with its level and fix |
| `benchbar_logs_tail` | The last lines of the bench log, one process if asked |
| `benchbar_site_list` | The sites of one bench, the default, the hosts line and the ping code |
| `benchbar_up` | Start a bench and wait for its default site |
| `benchbar_down` | Stop a bench and keep it stopped, also across reboots |
| `benchbar_restart` | Restart every process of a bench |
| `benchbar_app_add_plan` | The plan of adding an app from a git URL or a known name, with its token (read only) |
| `benchbar_app_add` | Apply that plan: needs the token, returns the output and a fresh app list |

`benchbar_list`, `benchbar_status`, `benchbar_doctor`,
`benchbar_logs_tail` (last lines, one process if asked),
`benchbar_site_list` and `benchbar_app_add_plan` read; `benchbar_up`,
`benchbar_down`, `benchbar_restart` and `benchbar_app_add` act. Each one
runs `benchbar ... --json` and returns what the CLI printed. Nothing that
repairs, installs a bench or needs `sudo` is offered. It needs only
`python3`, which the Command Line Tools provide.

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
   tell whether you saw it: the token proves only that nothing changed
   since the plan, so ask your agent to show the plan before it applies.
3. `benchbar_app_add` with the same arguments and the `token` runs
   exactly that plan. If `sites/apps.txt`, `apps/` or the sites changed
   in between, the token is refused and the agent plans again.

The apply can take several minutes (clone, pip, yarn, build); the server
waits up to an hour and returns everything at the end. Some clients stop
waiting sooner: the run goes on, and `benchbar_status` or `app list`
shows the outcome.

Every tool but `benchbar_list` takes an optional `bench`, the absolute
path from `benchbar_list`; without it the tool acts on the default bench.
The JSON each one returns is described in the [JSON schema](../json-schema.md).

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
print the MariaDB root password), and how to read the output.
