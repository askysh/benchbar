---
title: "mcp"
description: "benchbar mcp, the Model Context Protocol server on stdio for coding agents: how to add it, its tools, and what it never does."
---

```
benchbar mcp
```

A Model Context Protocol server on stdio for coding agents. It offers
read tools, `up`, `down` and `restart`, and app add from a reviewed plan
(`benchbar_app_add_plan`, then `benchbar_app_add` with the plan's token);
nothing that repairs, installs a bench or needs `sudo`. Each tool runs
`benchbar ... --json` with stdin closed, so a question from the CLI is
answered no and never hangs. A call may take 3 minutes, the plan 5 and
`benchbar_app_add` an hour. It needs only `python3` (3.9 or later),
which the Xcode Command Line Tools provide.

The tools and their arguments are in
[Coding agents and MCP](../../guides/agents.md#tools).

Exit codes: 1 when `python3` is missing; otherwise it runs until the
client closes the connection.

```bash
claude mcp add benchbar -- benchbar mcp
```
