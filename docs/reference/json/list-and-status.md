---
title: "JSON: list, status, stats, wait and logs"
description: "The JSON of benchbar list, status, stats, wait and logs: the bench states, the ready object and the log lines."
---

The documents that tell you which benches exist and what state each one is in. The [rules for readers](../../json-schema.md#rules-for-readers) and the [result envelope](../../json-schema.md#the-result-envelope-09) apply to all of them.

## `benchbar list --json`

```json
{
  "schema_version": 1,
  "cli_version": "0.3.0",
  "default_bench": "/Users/you/frappe-bench",
  "benches": [
    {
      "path": "/Users/you/frappe-bench",
      "name": "frappe-bench",
      "site": "macdev",
      "label": "com.benchbar.frappe-bench",
      "web_url": "http://macdev:8000",
      "ports": { "web": 8000, "socketio": 9000, "redis_queue": 11000, "redis_socketio": 13000, "redis_cache": 13000 },
      "default": true,
      "service_installed": true,
      "state_file": "/Users/you/frappe-bench/logs/.benchbar/state.json"
    }
  ]
}
```

| Field | Type | Notes |
|---|---|---|
| `default_bench` | string or null | the bench commands use without `--bench-dir` |
| `benches[].path` | string | absolute path, the unique key of a bench |
| `benches[].name` | string | folder name, used in the agent label |
| `benches[].site` | string | default site |
| `benches[].label` | string | launchd label, `com.benchbar.<name>` |
| `benches[].web_url` | string | `http://<site>:<web port>` |
| `benches[].ports` | object | web, socketio, redis_queue, redis_socketio, redis_cache. `redis_socketio` was added in 0.4: bench keeps it equal to `redis_cache` and frappe v15 and v16 never connect to it; older CLIs leave it out |
| `benches[].sites` | array | added in 0.4, see [Sites](sites-and-backups.md#sites) |
| `benches[].default` | bool | same as `path == default_bench` |
| `benches[].service_installed` | bool | the agent plist exists |
| `benches[].adopted` | bool | benchbar knows this bench: it has a service, is registered or is the remembered bench. A folder that only looks like a bench under `~` or `~/dev` is listed with `false` (added in 0.9). The MCP tools that change a bench act only on `true` ones |
| `benches[].state_file` | string | where the runner writes `state.json` |

Benches are found in this order, without duplicates: the remembered
bench (`state.env` in benchbar's state folder), the `WorkingDirectory` of every
`com.benchbar.*` and `com.frappe-mac.*` agent, then `~/frappe-bench`,
`~/dev/frappe-bench` and any `~/*` or `~/dev/*` folder with
`sites/common_site_config.json`.

`list --json` never pings a site (every `ping_code` is `null`) and looks for no
listener: it is polled at rest (0.6.1).

## `benchbar status --json`

```json
{
  "schema_version": 1,
  "cli_version": "0.3.0",
  "bench": "/Users/you/frappe-bench",
  "name": "frappe-bench",
  "site": "macdev",
  "label": "com.benchbar.frappe-bench",
  "state": "running",
  "stop_reason": null,
  "pid": 4242,
  "started_at": "2026-09-23T10:00:00Z",
  "last_exit_code": 0,
  "web_url": "http://macdev:8000",
  "web_ping_code": 200,
  "ports": { "web": 8000, "socketio": 9000, "redis_queue": 11000, "redis_socketio": 13000, "redis_cache": 13000 },
  "state_file": "/Users/you/frappe-bench/logs/.benchbar/state.json",
  "log": "/Users/you/frappe-bench/logs/bench.log",
  "agent_loaded": true,
  "agent_state": "running",
  "processes_running": true,
  "url": "http://macdev:8000",
  "agent": "com.benchbar.frappe-bench",
  "loaded": "yes",
  "stop_flag": "none",
  "ping": "200"
}
```

| Field | Type | Notes |
|---|---|---|
| `bench` | string | absolute path of the bench |
| `name`, `site`, `label` | string | as in `list` |
| `state` | string | see [States](../../json-schema.md#states) |
| `stop_reason` | string or null | see [States](../../json-schema.md#states) |
| `pid` | number or null | the runner process launchd started; honcho and every bench process are its descendants. Set while `starting` or `running` |
| `started_at` | string or null | when the current (or last) run started |
| `last_exit_code` | number or null | exit code of the last run of honcho |
| `web_url` | string | |
| `web_ping_code` | number or null | HTTP code of `GET /api/method/ping` with the site as `Host`; `null` when nothing answered. Asked only while processes run, with a 2 second limit (3 seconds before 0.6.1) |
| `ports` | object | as in `list` |
| `state_file`, `log` | string | paths |
| `agent_loaded` | bool | the launchd agent (the systemd user unit on Linux) is loaded. `false` also when systemd cannot be asked (no user bus); the text `status` says `unknown (no user bus)` then |
| `agent_state` | string or null | launchd's own word, for example `running` or `not running` |
| `processes_running` | bool | any honcho, serve, worker, schedule or socketio process of this bench (before 0.6.1 a port listener counted too) |
| `sites` | array | added in 0.4, see [Sites](sites-and-backups.md#sites) |
| `scheduler` | bool | added in 0.4: `Procfile.lean` runs `bench schedule` (`benchbar service --with-schedule`) |
| `autostart` | bool | added in 0.9: the bench may come back after a login (`benchbar autostart on`, the default; `off` keeps it down until `benchbar up`) |
| `listen` | string | added in 0.9: `"local"` (the web server and socketio listen on 127.0.0.1) or `"all"` (every interface, `benchbar listen all`) |
| `redis` | object | added in 0.8: `{"queue": {"port", "running"}, "cache": {"port", "running"}}`. `running` is whether something accepts a connection on the port, read by bash itself (`/dev/tcp`), so status starts no new program for it (a subshell for the probe). `benchbar up --services-only` starts these two and nothing else, `benchbar down` stops them |
| `pending_operations` | array | `[]` when none. An `app update` or planned `app add` that stopped part way, one entry per app: `op` (`app_update` or `app_add`), `app`, `branch`, `from`, `to` (commits; `from` is null for an add), `steps[]` (`kind`, `target`, `name` of the steps not done yet), `failed_step` (the kind it stopped at, or null), `reason` (that step's own failure line, or null), `url` (an add's repo URL, so `app add NAME` can finish an app that was never cloned or that no profile lists; null for an update and for a record an older version wrote) and `updated_at`. Read from a record file in the bench's state folder: no extra process on the status path |
| `leases` | array | added in 0.9: the active [leases](../cli/lease.md) on this bench, its own and those of its sites, `[]` when none. Each: `scope` (`bench` or `site`), `site` (null for a bench lease), `holder`, `note` (null without one), `since` and `expires_at` (ISO 8601 UTC). Never the lease's id. One small file read in the state folder, none without leases, so status starts no new program for it |
| `ready` | object | added in 0.9: whether the bench can serve, and the parts that say so; see [Readiness](#readiness) |

Kept from frappe-mac 0.2.0 for older readers: `url`, `agent`,
`loaded` (`"yes"` or `"no"`), `stop_flag` (`"manual"`, `"crash"`,
`"broken"`, `"port_conflict"` or `"none"`), `ping` (string, `"000"` for no answer). In
0.2.0 `state` held launchd's word (now `agent_state`), and `pid` and
`last_exit_code` were strings.

Since 0.8, `bench_bin` is the `bench` executable the bench's service runs:
the first one on the PATH its agent (unit) bakes in, `null` without a
service or when no such file is there. It is read from the agent file in
bash, so `status` still starts no process for it. With `--ping`, every
site is asked only while the bench's processes run; a stopped bench is
never pinged and never started.

## `benchbar stats --json`

CPU and memory of a running bench, for the Windows tray (which cannot sample
processes inside WSL) and for agents. It is its own command, not a flag of
`status`, because status is polled for every bench and its process count is
pinned; `stats` reads the process table once, on request. Read only: no lock,
no log, no site ping.

```json
{
  "schema_version": 1,
  "cli_version": "0.9.0",
  "bench_dir": "/Users/me/frappe-bench",
  "running": true,
  "resources": {
    "cpu_percent": 112.8,
    "memory_bytes": 26624000,
    "processes": 4,
    "sampled_at": "2026-11-20T11:09:20Z",
    "cpu_source": "ps",
    "window_ms": null,
    "speed": {"raw": 12.0, "min": 1, "max": 12, "smoothing_alpha": 0.35,
              "formula": "clamp(1 + cpu_percent / 10, min, max)"}
  }
}
```

`resources` is `null` (and `running` false) while nothing serves the site: a
stopped bench, a bench with no processes, or a Redis kept alone by
`up --services-only`. The processes are the ones `benchbar down` stops (honcho,
serve, worker, schedule, socketio and the bench's listeners, each proven to
run in this bench's folder) and every descendant of them.

| Field | Type | Meaning |
|---|---|---|
| `cpu_percent` | number | summed over those processes, in percent of one core (250 is two and a half cores busy), one decimal |
| `memory_bytes` | number | the sum of their resident set sizes (RSS), in bytes. The Mac app reads the physical footprint instead, which is a little different |
| `processes` | number | how many processes were measured |
| `sampled_at` | string | ISO 8601 UTC time of the sample |
| `cpu_source` | string | `ps` (macOS: ps's own `%cpu`, the system's decaying average, one call) or `proc_delta` (Linux and WSL: two reads of `/proc` `window_ms` apart, so it is the load over that window) |
| `window_ms` | number or null | the time between the two samples; `null` for `ps` |
| `speed.raw` | number | the runner speed of the Mac app for this sample: `clamp(1 + cpu_percent / 10, 1, 12)`. 110 percent is already the top speed |
| `speed.smoothing_alpha` | number | a client smooths successive raw values the way the Mac app does: `value = alpha * raw + (1 - alpha) * value`, starting at 1 |

`benchbar_stats` is the same document through the MCP server.

## Readiness

`status --json` has a `ready` object, and `benchbar wait` blocks until it
says yes. It is one definition: `up` and `restart` wait for its `web` part,
`wait` for all of them, and `state_after` of every command that changes a
bench carries it. Use it instead of probing ports and processes yourself.

```json
"ready": {
  "ready": false,
  "deep": true,
  "agent": true, "processes": true, "web": true, "socketio": true, "redis": true,
  "workers": true, "stale": true,
  "stale_file": "apps/erpnext/erpnext/hooks.py",
  "waiting_on": ["stale"],
  "fix": "benchbar restart --bench-dir /Users/you/frappe-bench"
}
```

| Field | Type | Notes |
|---|---|---|
| `ready` | bool | true when no part is `false` and `stale` is not `true` |
| `deep` | bool | the deep parts (`workers`, `stale`) were asked: `status --json --deep`, `wait`, `up`, `restart` and the MCP tools. `false` means `workers` and `stale` are `null` because nobody asked |
| `agent` | bool | the service is loaded in launchd or systemd |
| `processes` | bool | the bench's processes run (`processes_running`) |
| `web` | bool | the default site's ping answered with a 2xx or 3xx (`web_ping_code`) |
| `socketio` | bool | the realtime port accepts a connection (asked only while processes run) |
| `redis` | bool | the queue and the cache Redis accept a connection (`redis`) |
| `workers` | bool or null | a background worker of this bench runs. `null` unless asked (see below) |
| `stale` | bool or null | a `*.py` file under `apps/` (not in `node_modules`, `.git` or `__pycache__`) changed after the bench started, so the running code is old and the bench needs `benchbar restart`. Any `*.py` counts, tests and docs too, so a false positive is possible (it errs towards a restart). `null` when not asked (`deep` is `false`), when the bench's processes do not run, or when the start time is not known (no `started_at`, so no `state.json`) |
| `stale_file` | string or null | the first such file, relative to the bench |
| `waiting_on` | array | the names of the parts that are not ready, in the order above |
| `fix` | string or null | the command that moves the first missing part; `null` when ready |

The start time is `started_at` of `logs/.benchbar/state.json`: when the
runner of the current run started, a second or two before the web server
loaded its code. Without `--deep`, `status` starts no program for `ready`:
`agent`, `processes` and `web` come from what status reads anyway, and
`socketio` and `redis` from bash itself (`/dev/tcp`). `workers` and `stale`
need `pgrep`, `lsof` and `find`, so they are `null` in a plain `status`
and are asked by `status --json --deep`, `benchbar wait`, and the MCP tool
`benchbar_status`. A `null` part never makes `ready` false: a reader that needs
`stale` to be known checks `deep` and that `stale` is not `null`.
Not ready is not an error: `status` exits 0.

### `benchbar wait --json`

```
benchbar wait [--ready] [--for PART] [--timeout SECS] [--json]
```

Polls once a second until the bench is ready, or until `PART` is
(`agent`, `processes`, `web`, `socketio`, `redis`, `workers` or `stale`),
and starts nothing. `--timeout` is whole seconds, 0 to 3600, default 60;
0 checks once. Exit 0 when ready, 1 when not: after the timeout, or at once
for a bench that cannot become ready by itself (`state` `paused`, or
`not_adopted`). A stopped bench is waited for, because another command may be
starting it. `--for stale` is refused (exit 1, with the reason) when `stale` is
`null`, that is for a bench that does not run or has no `started_at`: a `null`
part counts as holding, so the wait would end at once and say nothing. Exit 2
is never used (it stays the MariaDB password).

| Field | Type | Notes |
|---|---|---|
| `for` | string | `ready`, or the part waited for |
| `satisfied` | bool | the wait ended because it was ready |
| `timed_out` | bool | it gave up after `timeout_s` |
| `waited_s`, `timeout_s` | number | seconds waited, and the limit |
| `waiting_on` | array | what was still not ready; `[]` when satisfied |
| `ready` | object | the object above, as of the last look, with the deep parts |

The `done` fields follow (`exit`, `changed`, `warnings`, `next_actions`
with the fix, `state_after`). With `--jsonl` there is one `progress` line a
second while it waits. The MCP tool `benchbar_wait` is the same call,
capped at 120 seconds, with progress notifications.

## `benchbar logs --json`

```json
{"schema_version":1,"cli_version":"0.5.0","bench":"/Users/you/frappe-bench","file":"/Users/you/frappe-bench/logs/bench.log","process":"web","lines":["10:00:01 web.1 | * Running on http://127.0.0.1:8000"]}
```

`-nN` sets how many lines (after the filter), `--process NAME` keeps one
honcho process (`web`, `socketio`, `schedule`, `redis_queue`,
`redis_cache`); lines without a honcho prefix, such as a traceback, stay
with the process above them. `process` is `null` without a filter.
`file` is the file that was read: `logs/bench.log`, or `logs/worker.log`,
`logs/worker.error.log` and `logs/bench.previous.log` for `--worker`,
`--worker-error` and `--previous`. Since 0.7.3 `--process worker` reads
`logs/worker.log` unfiltered (and `process` is `null`): `Procfile.lean`
sends the worker there, so it never appears in `bench.log`; with
`--worker-error` that file is kept, and `--previous` is refused (there is
no previous worker log). Control characters are removed, a terminal
color code as a whole (`[31m` is never left behind). `benchbar mcp` uses it for `benchbar_logs_tail`, whose
`file` argument (`bench`, `worker`, `worker_error`, `previous`) stands
for these flags, and which adds `"truncated": true` when it had to drop
lines to stay under its size cap.

Since 0.7.3 the lines are redacted with the rules of `benchbar report`
(values of credential-like keys, `user:password@` in URLs, JWT and API
token shapes become `***`, email addresses `<email>`); the plain
`benchbar logs` is the file as it is. `-nN` is capped at 2000: when N was
larger the object carries `"truncated_to":2000` (absent otherwise) and
holds the newest 2000 lines after the process filter.

Since 0.8 the object also has `mtime` (the file's, `null` without one),
`since` (the cut off as an ISO time, `null` without one) and `ts`: one entry
per line of `lines`, in step, an ISO 8601 UTC time where the line carries
one and `null` where it does not (a traceback line inherits nothing). A
honcho line's `HH:MM:SS` and the leading `YYYY-MM-DD HH:MM:SS` of other logs
are local times; the day of a honcho line is worked out backwards from the
file's `mtime`. `--since TIME` keeps the lines at or after TIME (ISO 8601, a
zone or none for local time, `YYYY-MM-DD HH:MM:SS`, a date, or `HH:MM:SS`
today) and the untimed lines under a kept line; `--since-restart` is
`--since` the bench's last start (`started_at` of `state.json`; without one
the command refuses). Only the newest 20000 lines of the file are looked
at. `benchbar_logs_tail` takes `since` and `since_restart`.
