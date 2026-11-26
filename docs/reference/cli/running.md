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
benchbar up [--services-only] [--json] [--bench-dir DIR]
```

Starts the bench in the background and waits for the site's ping. It
clears the stop flag and loads the launchd agent when it is not loaded.
Before that it checks the bench's ports: it refuses to start when a
running bench, or any other program, listens on one of them (it never
takes their ports), and asks when only a stopped bench shares them.
Both print `benchbar ports setup -- PATH` as the fix. A running bench is
left as it is.

With `--json` (or `--jsonl`, `--for-agent`) it prints JSON lines: the
steps, then a `done` with `exit`, `changed`, `warnings`, `next_actions`
and `state_after` ([the done fields](../../json-schema.md#the-done-fields-08)).

`--services-only` starts the bench's Redis (queue and cache) and nothing
else: no agent, no web process, no stop flag, and no service needs to be
installed. It is for a `site restore`, a `pull` or a `bench migrate` on a
bench that is not running, which need that Redis. It stays up until
`benchbar down`. A Redis port held by another program is refused.
`benchbar status --json` shows both in `redis`.

Exit codes: 0 the bench is up (or already was); 1 the site did not answer
in time (it may still be starting: `benchbar logs`), a port is taken, or
you declined the port question.

```bash
benchbar up --bench-dir ~/dev/v16-bench
```

## down

```
benchbar down [--json] [--bench-dir DIR] [--dry-run]
```

Stops the bench and keeps it stopped, also across reboots: it writes
`manual` to the stop flag and stops the agent. Then it stops what is
left: this bench's honcho, serve, worker, schedule and socketio
processes, and the processes listening on the bench's web, socketio or
Redis ports that run inside the bench folder. A listener started
elsewhere, such as another bench or an unrelated server, is left alone;
`benchbar ports check --bench-dir DIR` shows whether one holds the
ports. Your own `bench migrate` or `bench console` keeps running.

With `--json` it prints the same JSON lines as `up`.

Exit codes: 0 stopped; 1 some bench processes are still alive.

```bash
benchbar down
```

## restart

```
benchbar restart [--json] [--bench-dir DIR]
```

Restarts every process and waits for the site. Needed after Python
changes: the web server reloads by itself, the worker does not. With
`--json` it prints the same JSON lines as `up`.

Exit codes: 0 the site answers; 1 it did not answer in time, a port is
taken, or you declined the port question.

```bash
benchbar restart
```

## status

```
benchbar status [--json] [--ping] [--bench-dir DIR]
```

Agent state, pid, stop reason, last exit code, the processes, the site
ping, the ports and the log path. In `--json`, `bench_bin` is the
`bench` its service runs, `pending_operations` lists an `app update` or
`app add` that stopped half way, and `state` is `not_adopted` for a bench
folder that benchbar does not manage yet (`benchbar adopt PATH` changes
that). `--json` prints the versioned JSON in
[the schema](../json/list-and-status.md#benchbar-status---json).

The app runs `status` for every bench, so it is cheap: one `launchctl`
call, and one ping of the default site while the bench runs. The other
sites are not asked; `--ping` asks each of them once and fills
`ping_code` in the JSON's `sites`, but only while the bench runs. A
stopped bench is never pinged.

`--json` also has a `ready` object (added in 0.9.0): whether the bench can
serve, and the parts that say so (service loaded, processes, site ping 2xx
or 3xx, socketio, Redis; with `--deep` also a worker and `stale`, a Python
file under `apps/` that changed after the bench started). `--deep` starts
`pgrep`, `lsof` and `find`, so the plain `status` leaves those parts `null`.
See [Readiness](../json/list-and-status.md#readiness).

Exit codes: 0 always, whatever the state; 1 only when no bench is found.

```bash
benchbar status --json
```

## wait

```
benchbar wait [--ready] [--for PART] [--timeout SECS] [--json] [--bench-dir DIR]
```

Blocks until the bench is ready: the service is loaded, its processes run,
the default site answers its ping with a 2xx or 3xx, socketio and both Redis
ports accept connections, a worker runs, and no Python file under `apps/`
changed since the bench started. `--for PART` waits for one part only
(`agent`, `processes`, `web`, `socketio`, `redis`, `workers` or `stale`;
`--for stale` is refused with the reason for a bench that does not run or
has no start time, since `stale` is not known then). `--timeout` is in seconds (default 60; 0 checks once). It reads only: it
starts nothing and takes no lock.

Exit 0 when ready. Exit 1 when it is not ready in time, naming what is not
ready and the fix (after a code change, `benchbar restart`). A bench that
cannot become ready by itself, one that is paused after crashes or that
benchbar does not manage, ends the wait at once; a stopped bench is waited
for, because another command may be starting it. Exit 2 is never used.
`--json` prints one document with `satisfied`, `timed_out`, `waited_s`,
`waiting_on` and the `ready` object, then the usual `done` fields; see
[the schema](../json/list-and-status.md#readiness).

```bash
benchbar restart && benchbar wait --timeout 90
```

## logs

```
benchbar logs [--worker | --worker-error | --previous] [-n50] [--no-follow] [--process NAME] [--since TIME] [--since-restart] [--json]
```

Tails `logs/bench.log` and follows it in a terminal.

| Flag | What it does |
|---|---|
| `--worker` | `logs/worker.log` instead |
| `--worker-error` | `logs/worker.error.log` instead |
| `--previous` | `logs/bench.previous.log`, the tail of the run before (the starts before that are `bench.previous.1.log` to `.3.log`, read them with `cat`) |
| `-n50` | The last 50 lines (the default); any number works, `-n` then the count |
| `--no-follow` | Print and exit |
| `--process NAME` | Only the lines of one honcho process: `web`, `socketio`, `schedule`, `redis_queue`, `redis_cache`. `worker` reads `logs/worker.log` instead, where `Procfile.lean` sends the worker (it never writes to `bench.log`); `--previous` does not combine with it, since `worker.log` has no previous file |
| `--since TIME` | With `--json`: only the lines at or after TIME (ISO 8601, `YYYY-MM-DD HH:MM:SS`, a date, or `HH:MM:SS` today; a time with no zone is local time) |
| `--since-restart` | With `--json`: only the lines after the bench's last start |
| `--json` | The lines as JSON, with `mtime` and one time per line in `ts` ([schema](../json/list-and-status.md#benchbar-logs---json)) |

Exit codes: 0; 1 for a bad `-n` or `--process` value, or for
`--process worker` with `--previous`.

```bash
benchbar logs --json --no-follow -n100 --process worker
```

## fg

```
benchbar fg [--bench-dir DIR]
```

Stops the service and runs honcho, the process manager, with
`Procfile.lean` in the foreground, so the output of every process shows
in the terminal.
Ctrl+C stops it; `benchup` brings the background service back.

Exit codes: honcho's; 1 when honcho or `Procfile.lean` is missing, a
port is taken, or the background bench could not be stopped.

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

## Flags, needs and environment

These tables come from the code (`benchbar commands --json`); the sections above explain them.

<!-- generated:cli-commands up down restart status stats wait logs fg watch path -->
<!-- Generated by scripts/docs-reference.py from the code. Edit the code, then run: python3 -I scripts/docs-reference.py --write -->

| Command | Terminal | `sudo` | Network | Changes things | JSON |
|---|---|---|---|---|---|
| `benchbar status [--json] [--ping] [--deep]` | no | no | no | no | document |
| `benchbar stats [--json]` | no | no | no | no | document |
| `benchbar up [--services-only] [--json]` | yes | no | no | yes | stream |
| `benchbar down [--json]` | no | no | no | yes | stream |
| `benchbar restart [--json]` | yes | no | no | yes | stream |
| `benchbar wait [--ready] [--for PART] [--timeout SECS] [--json]` | no | no | no | no | document |
| `benchbar logs [-nN] [--worker\|--worker-error\|--previous] [--process NAME] [--since TIMESTAMP] [--since-restart] [--no-follow] [--json]` | no | no | no | no | document |
| `benchbar fg` | yes | no | no | yes | none |
| `benchbar watch` | no | no | no | no | none |
| `benchbar path` | no | no | no | no | none |

Terminal: may ask a question on a terminal. `sudo`: may run `sudo`. Network: may reach the network.
JSON: `document` is one JSON line, `stream` is JSON lines ending in a `done` line.

| Command | Flag | Value | What it does |
|---|---|---|---|
| `status` | `--ping` |  | Ask every site, not only the default one. |
| `status` | `--deep` |  | Also ask the ready parts that start programs: workers (pgrep, lsof) and stale (find: a Python file under apps/ changed after the bench started). Without it ready.workers and ready.stale are null. |
| `status` | `--json` |  | One JSON document. It adds redis, sites[].served (does the running bench serve the site) and the ready object (is the bench ready to serve). |
| `up` | `--services-only` |  | Start only the bench's Redis (for a restore or a migrate); down stops it. |
| `wait` | `--ready` |  | Wait for every part (the default). |
| `wait` | `--for` | `PART` | Wait for one part only: agent, processes, web, socketio, redis, workers or stale. |
| `wait` | `--timeout` | `SECS` | Give up after SECS seconds, 0 to 3600 (default 60). 0 checks once. |
| `logs` | `--worker` |  | Read logs/worker.log. |
| `logs` | `--worker-error` |  | Read logs/worker.error.log. |
| `logs` | `--previous` |  | Read logs/bench.previous.log (the starts before it are bench.previous.1.log to .3.log). |
| `logs` | `--process` | `NAME` | web, socketio, schedule or worker. The worker one reads logs/worker.log. |
| `logs` | `--since` | `TIMESTAMP` | Only lines at or after it (--json; ISO 8601, or HH:MM:SS today). |
| `logs` | `--since-restart` |  | Only lines after the bench's last start (--json). |
| `logs` | `--no-follow` |  | Print and exit. |
| `logs` | `-n` | `N` | The last N lines (default 50); -nN, or a bare number, also works. |
| `logs` | `--json` |  | The lines as JSON. |

| Command | Environment variable | What it does |
|---|---|---|
| `status` | `BENCHBAR_LOAD_ALL` | Debugging switch: 1 loads every library, as before the lean start (the output is the same; use it to see whether a problem comes from the lean load). |
| `stats` | `FL_STATS_WINDOW` | Linux only: seconds between the two CPU samples (default 0.5). |
| `path` | `BENCHBAR_LOAD_ALL` | Debugging switch: 1 loads every library, as before the lean start (the output is the same; use it to see whether a problem comes from the lean load). |
<!-- /generated:cli-commands -->
