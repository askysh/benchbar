---
title: "mcp"
description: "benchbar mcp, the Model Context Protocol server on stdio for coding agents: how to add it, its tools, and what it never does."
---

```
benchbar mcp
```

A Model Context Protocol server on stdio for coding agents. It offers
read tools and `up`, `down` and `restart`; nothing that repairs, installs
or needs `sudo`. Each tool runs `benchbar ... --json` with stdin closed,
so a question from the CLI is answered no and never hangs. It needs only
`python3` (3.9 or later), which the Xcode Command Line Tools provide.

The tools and their arguments are in
[Coding agents and MCP](../../guides/agents.md#tools).

Exit codes: 1 when `python3` is missing; otherwise it runs until the
client closes the connection.

```bash
claude mcp add benchbar -- benchbar mcp
```
