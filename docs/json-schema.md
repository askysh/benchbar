# benchbar JSON API, schema version 1

`benchbar` (and its alias `frappe-mac`) prints versioned JSON for three
commands, and the runner writes one state file per bench. The BenchBar
app reads nothing else, so this is a public API: coding agents, scripts,
Raycast extensions and the like can rely on it too.

| Source | What it is |
|---|---|
| `benchbar list --json` | every bench benchbar knows about |
| `benchbar status --json [--bench-dir DIR]` | the live state of one bench |
| `benchbar doctor --json [--bench-dir DIR]` | every health check with its fix |
| `<bench>/logs/.benchbar/state.json` | the last state transition, written by the runner and the CLI |

## Rules for readers

- Every document has `"schema_version": 1` and `"cli_version"` at the top.
  The schema version goes up only for a change that breaks readers:
  removing or renaming a field, or changing its type or meaning.
- Adding fields is not a breaking change. Ignore fields you do not know.
- Treat an enum value you do not know (a new `state` or `stop_reason`) as
  "unknown", never as an error.
- Timestamps are ISO 8601 in UTC with a `Z` suffix, for example
  `2026-09-23T10:00:00Z`.
- `null` means "not known" or "does not apply". Numbers are JSON numbers.
- JSON goes to stdout on one line. Errors and warnings go to stderr as
  text. Exit codes: 0 success, 1 failure (for `doctor`: at least one
  check is `fail`; the JSON is still printed). A missing bench exits 1
  with a message on stderr and nothing on stdout.
- `status --json`, `list --json` and `doctor --json` are read only. They
  never start, stop or write anything, so they are safe to poll.

## States

| `state` | Meaning | `stop_reason` |
|---|---|---|
| `stopped` | not running | `manual` after `benchdown`, `null` otherwise (never started, clean exit, restart in progress) |
| `starting` | processes are up, the site does not answer yet | `null` |
| `running` | processes are up and the site answers HTTP | `null` |
| `crashed` | honcho exited with an error; launchd retries after 20 seconds | `crash` |
| `paused` | auto-restart is off until `benchup` | `crash` (the crash guard tripped: 3 starts in 10 minutes) or `broken` (honcho or the env is missing: run `benchbar repair`) |

`stop_reason` can be `manual`, `crash`, `broken` or `null`. `broken` is
an addition to the original `manual | crash | null` contract: it tells a
reader that `repair` is needed, not just `benchup`.

How `status` decides (live facts win over the state file):

1. Processes of this bench are running: `running` when the site answers
   any HTTP code, otherwise `starting`. A bench started by hand with
   `benchfg` counts as running.
2. The stop flag `logs/.bench-stopped` says `manual`: `stopped`.
3. It says `crash`: `paused` with `crash`. Anything else: `paused` with `broken`.
4. `state.json` says `crashed`: `crashed` (launchd is about to retry).
5. Otherwise `stopped` with `stop_reason: null`.

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
      "ports": { "web": 8000, "socketio": 9000, "redis_queue": 11000, "redis_cache": 13000 },
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
| `benches[].ports` | object | web, socketio, redis_queue, redis_cache |
| `benches[].default` | bool | same as `path == default_bench` |
| `benches[].service_installed` | bool | the agent plist exists |
| `benches[].state_file` | string | where the runner writes `state.json` |

Benches are found in this order, without duplicates: the remembered
bench (`.frappe-local/state.env`), the `WorkingDirectory` of every
`com.benchbar.*` and `com.frappe-mac.*` agent, then `~/frappe-bench`,
`~/dev/frappe-bench` and any `~/*` or `~/dev/*` folder with
`sites/common_site_config.json`.

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
  "ports": { "web": 8000, "socketio": 9000, "redis_queue": 11000, "redis_cache": 13000 },
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
| `state` | string | see [States](#states) |
| `stop_reason` | string or null | see [States](#states) |
| `pid` | number or null | the runner process launchd started; honcho and every bench process are its descendants. Set while `starting` or `running` |
| `started_at` | string or null | when the current (or last) run started |
| `last_exit_code` | number or null | exit code of the last run of honcho |
| `web_url` | string | |
| `web_ping_code` | number or null | HTTP code of `GET /api/method/ping` with the site as `Host`; `null` when nothing answered within 3 seconds |
| `ports` | object | as in `list` |
| `state_file`, `log` | string | paths |
| `agent_loaded` | bool | the launchd agent is loaded |
| `agent_state` | string or null | launchd's own word, for example `running` or `not running` |
| `processes_running` | bool | any honcho, serve, worker, socketio or port listener of this bench |

Kept from frappe-mac 0.2.0 for older readers: `url`, `agent`,
`loaded` (`"yes"` or `"no"`), `stop_flag` (`"manual"`, `"crash"`,
`"broken"` or `"none"`), `ping` (string, `"000"` for no answer). In
0.2.0 `state` held launchd's word (now `agent_state`), and `pid` and
`last_exit_code` were strings.

## `benchbar doctor --json`

```json
{
  "schema_version": 1,
  "cli_version": "0.3.0",
  "bench": "/Users/you/frappe-bench",
  "name": "frappe-bench",
  "site": "macdev",
  "profile": "v15-lts",
  "checks": [
    {
      "id": "assets",
      "group": "bench",
      "label": "Built assets",
      "level": "fail",
      "message": "2 of 2 dist files referenced by assets.json are missing (site loads unstyled)",
      "fix_command": "cd /Users/you/frappe-bench && bench build",
      "action": "build",
      "status": "fail",
      "fix": "cd /Users/you/frappe-bench && bench build"
    },
    {
      "id": "agent",
      "group": "service",
      "label": "launchd agent",
      "level": "ok",
      "message": "agent com.benchbar.frappe-bench loaded, running (pid 4242)",
      "fix_command": null,
      "action": null,
      "status": "ok",
      "fix": ""
    }
  ],
  "summary": { "ok": 19, "warn": 1, "fail": 1 }
}
```

| Field | Type | Notes |
|---|---|---|
| `checks[].id` | string | stable id, for example `env_python`, `assets`, `agent`, `legacy_agents` |
| `checks[].group` | string | `system`, `bench`, `service` or `site` |
| `checks[].label` | string | short name for humans |
| `checks[].level` | string | `ok`, `warn` or `fail` |
| `checks[].message` | string | one line for humans |
| `checks[].fix_command` | string or null | the exact command a human would run; `null` when nothing needs doing |
| `checks[].action` | string or null | the `repair` action that fixes it, when `repair` can |
| `summary` | object | counts per level |

`status` and `fix` are the 0.2.0 names of `level` and `fix_command` (with
`""` instead of `null`), kept for older readers.

## `logs/.benchbar/state.json`

Written on every transition, always by writing a temp file in the same
folder and renaming it over `state.json`. A reader never sees half a
file, but a file watcher on `state.json` itself breaks at the first
rename: watch the `logs/.benchbar/` folder instead.

```json
{"schema_version":1,"cli_version":"0.3.0","bench":"/Users/you/frappe-bench","name":"frappe-bench","site":"macdev","label":"com.benchbar.frappe-bench","state":"running","stop_reason":null,"pid":4242,"started_at":"2026-09-23T10:00:00Z","last_exit_code":null,"web_url":"http://macdev:8000","web_ping_code":200,"updated_at":"2026-09-23T10:00:14Z","source":"runner"}
```

It has the core fields of `status` (`schema_version` to `web_ping_code`)
plus:

| Field | Type | Notes |
|---|---|---|
| `updated_at` | string | when this transition was written |
| `source` | string | `runner` (the launchd runner) or `cli` (`up`, `down`, `restart`) |

Transitions the runner writes:

| When | `state` | `stop_reason` |
|---|---|---|
| the agent starts while a stop flag exists | `stopped` or `paused` | from the flag |
| honcho or `env/bin/python` is missing | `paused` | `broken` |
| the crash guard trips | `paused` | `crash` |
| honcho started | `starting` | `null` |
| the site answered 200 (checked every 2 seconds for 4 minutes) | `running` | `null` |
| honcho exited 0, or the runner got SIGTERM without a stop flag | `stopped` | `null` |
| `benchdown` stopped it | `stopped` | `manual` |
| honcho exited with an error | `crashed` | `crash` |

The CLI writes `starting` just before `up` and `restart` kick the agent,
and `stopped` with `manual` after `down`. The state file is a hint for
fast updates; `status --json` is the truth, because it also checks the
processes and the site.
