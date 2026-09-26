---
title: "up, down, restart, status, logs"
description: "The daily benchbar commands: up, down, restart, status and logs, plus fg, watch and path. Flags, exit codes and examples."
---

The daily commands. Each has a shell helper (`benchup`, `benchdown`,
`benchrestart`, `benchstatus`, `benchlogs`, `benchfg`, `benchwatch`,
`benchcd`), see [Benches and sites](../../guides/benches-and-sites.md#daily-use).
Every command takes the [options for every command](install.md#options-for-every-command),
most often `--bench-dir DIR` for a bench that is not the default.

## up

```
benchbar up [--bench-dir DIR]
```

Starts the bench in the background and waits for the site's ping. It
clears the stop flag, loads the launchd agent when it is not loaded, and
asks before starting when another running bench uses the same web or
socketio port. A running bench is left as it is.

Exit codes: 0 the bench is up (or already was); 1 the site did not answer
in time (it may still be starting: `benchbar logs`), or you declined the
port question.

```bash
benchbar up --bench-dir ~/dev/v16-bench
```

## down

```
benchbar down [--bench-dir DIR] [--dry-run]
```

Stops the bench and keeps it stopped, also across reboots: it writes
`manual` to the stop flag, stops the agent, then only this bench's
leftover processes and port listeners. Your own `bench migrate` or `bench
console` keeps running.

Exit codes: 0 stopped; 1 some bench processes are still alive.

```bash
benchbar down
```

## restart

```
benchbar restart [--bench-dir DIR]
```

Restarts every process and waits for the site. Needed after Python
changes: the web server reloads by itself, the worker does not.

Exit codes: 0 the site answers; 1 it did not answer in time.

```bash
benchbar restart
```

## status

```
benchbar status [--json] [--bench-dir DIR]
```

Agent state, pid, stop reason, last exit code, the processes, the site
ping, the ports and the log path. `--json` prints the versioned JSON in
[the schema](../../json-schema.md#benchbar-status---json).

Exit codes: 0 always, whatever the state; 1 only when no bench is found.

```bash
benchbar status --json
```

## logs

```
benchbar logs [--worker | --worker-error | --previous] [-n50] [--no-follow] [--process NAME] [--json]
```

Tails `logs/bench.log` and follows it in a terminal.

| Flag | What it does |
|---|---|
| `--worker` | `logs/worker.log` instead |
| `--worker-error` | `logs/worker.error.log` instead |
| `--previous` | `logs/bench.previous.log`, the tail of the run before |
| `-n50` | The last 50 lines (the default); any number works, `-n` then the count |
| `--no-follow` | Print and exit |
| `--process NAME` | With `--json`: only the lines of one honcho process: `web`, `worker`, `socketio`, `schedule`, `redis_queue`, `redis_cache` |
| `--json` | The lines as JSON ([schema](../../json-schema.md#benchbar-logs---json)) |

Exit codes: 0; 1 for a bad `-n` or `--process` value.

```bash
benchbar logs --json --no-follow -n100 --process worker
```

## fg

```
benchbar fg [--bench-dir DIR]
```

Stops the service and runs honcho with `Procfile.lean` in the foreground.
Ctrl+C stops it; `benchup` brings the background service back.

Exit codes: honcho's; 1 when honcho or `Procfile.lean` is missing.

```bash
benchbar fg
```

## watch

```
benchbar watch [--bench-dir DIR]
```

Runs `bench watch` for JS and CSS rebuilds. The lean Procfile has no
watcher, so run this while you edit assets.

```bash
benchbar watch
```

## path

```
benchbar path [--bench-dir DIR]
```

Prints the bench directory. `benchcd` is `cd "$(benchbar path)"`.

```bash
cd "$(benchbar path)"
```
