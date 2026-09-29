---
title: "ports"
description: "benchbar ports plan, setup, apply, check and mode: give several benches their own port blocks, from a reviewed plan, and check a bench's ports before it starts."
---

Each bench needs four ports of its own: web `8000 + n`, socketio
`9000 + n`, and Redis `11000 + n` and `13000 + n`, a port block. The
`ports` commands plan and apply those blocks for several benches at
once, and check one bench for conflicts. The guide is
[Benches and sites](../../guides/benches-and-sites.md#port-blocks).

Plan, setup and apply take bench folders after `--`, one or more, and
use each bench's own site and profile; `--site` and `--profile` are
refused. None of them starts a bench.

## ports plan

```
benchbar ports plan [--json] -- PATH ...
```

Read only. For every bench: its port mode, its current and proposed
ports, the conflicts found (ports another bench reserves, or a program
listening on them), and the `adopt` plan it would run with the
proposed ports: `Procfile.lean`, the runner, the launchd agent, the
shell helpers and the `/etc/hosts` line. A bench is **blocked** when it
is running, when fixed ports conflict, or when no free block is left;
a plan with a blocked bench cannot be applied.

| Flag | What it does |
|---|---|
| `--json` | The plan with its approval `token` ([schema](../../json-schema.md#port-management)) |

Exit codes: 0; 1 when a path is not a bench or no path is given.

```bash
benchbar ports plan -- ~/frappe-bench ~/dev/v16-bench
```

## ports setup

```
benchbar ports setup [--dry-run] -- PATH ...
```

What it changes: for every bench in the plan it runs `adopt` with the
proposed ports. When a bench's ports change, `bench set-config -g`
writes them into `sites/common_site_config.json` (backed up first) and
`bench setup redis` rewrites `config/redis_*.conf`; the service files
and the hosts line are written as `adopt` does, and the bench is
remembered. Sites, databases and apps are not touched.

Stop the benches first (`benchbar down --bench-dir PATH`): a running
bench blocks the plan. Setup prints the plan, asks once, then applies
it bench by bench. When one bench fails, the benches before it stay
set up; run setup again for a fresh plan.

| Flag | What it does |
|---|---|
| `--dry-run` | Print the plan, change nothing |

Exit codes: 0 applied; 1 the plan is blocked, you declined, or a bench
failed.

```bash
benchbar ports setup --dry-run -- ~/frappe-bench ~/dev/v16-bench
benchbar ports setup -- ~/frappe-bench ~/dev/v16-bench
```

After setup, start each bench with `benchbar up --bench-dir PATH`.

## ports apply

```
benchbar ports apply TOKEN --yes -- PATH ...
```

Applies a plan that was reviewed as JSON, for the app and scripts. It
builds the plan again under the CLI lock and refuses when the token
does not match (a bench, its config or its agent changed since the
plan) or a bench is blocked; nothing is changed then. Otherwise it does
what `setup` does, without asking.

| Flag | What it does |
|---|---|
| `-y`, `--yes` | Required: the plan was already reviewed |

Exit codes: 0 applied; 1 the token is stale, a bench is blocked, or a
bench failed.

## ports check

```
benchbar ports check --bench-dir DIR
```

Read only. Prints, as JSON, the conflicts of one bench's ports: ports
that another bench benchbar knows reserves, and programs listening on
them that are not this bench. It also gives the bench's port mode and
whether it is running. `benchbar up` runs the same check before it
starts: it refuses when a running bench or another program holds the
ports, and asks when only a stopped bench shares them.

| Flag | What it does |
|---|---|
| `--bench-dir DIR` | The bench to check |
| `--json` | Accepted; the output is always JSON ([schema](../../json-schema.md#port-management)) |

Exit codes: 0; 1 when no bench is found.

```bash
benchbar ports check --bench-dir ~/dev/v16-bench
```

## ports mode

```
benchbar ports mode automatic|fixed --bench-dir DIR [--dry-run]
```

Sets how a bench's ports may change. **automatic** (the default) lets
a plan move the bench to a free block when its ports clash. **fixed**
pins the current ports: plans never move the bench, and a conflict
blocks the plan instead. Either way the ports do not move now; the mode
only applies to later plans. `--port-offset N` on `adopt` or `service`
still moves a fixed bench, because you asked for that block.

| Flag | What it does |
|---|---|
| `--bench-dir DIR` | The bench to set |
| `--dry-run` | Say what would be saved, save nothing |

Exit codes: 0; 1 for another mode, or when no bench is found.

```bash
benchbar ports mode fixed --bench-dir ~/frappe-bench
```
