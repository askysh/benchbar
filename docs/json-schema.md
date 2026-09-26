---
title: "benchbar JSON API, schema version 1"
description: "The versioned JSON that benchbar prints for list, status, doctor, logs, repair, apps, lock, profiles and pull, and the state file the runner writes."
---

`benchbar` (and its alias `frappe-mac`) prints versioned JSON for three
commands, and the runner writes one state file per bench. The BenchBar
app reads nothing else, so this is a public API: coding agents, scripts,
Raycast extensions and the like can rely on it too.

| Source | What it is |
|---|---|
| `benchbar list --json` | every bench benchbar knows about |
| `benchbar status --json [--bench-dir DIR]` | the live state of one bench |
| `benchbar doctor --json [--bench-dir DIR]` | every health check with its fix |
| `benchbar app list --json` | the bench's apps, their git state and sites (0.5) |
| `benchbar app update NAME --dry-run --json` | the changelog and plan of an update (0.5) |
| `benchbar profile list --json` | built in and team profiles, with where each comes from (0.5) |
| `benchbar lock check --json` | how the bench differs from its `benchbar.toml` (0.5) |
| `<bench>/logs/.benchbar/state.json` | the last state transition, written by the runner and the CLI |
| `benchbar pull ... --json` | JSON lines while a production site is copied, see [pull](#benchbar-pull---json) |

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
| `benches[].sites` | array | added in 0.4, see [Sites](#sites) |
| `benches[].default` | bool | same as `path == default_bench` |
| `benches[].service_installed` | bool | the agent plist exists |
| `benches[].state_file` | string | where the runner writes `state.json` |

Benches are found in this order, without duplicates: the remembered
bench (`.benchbar/state.env`), the `WorkingDirectory` of every
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
| `sites` | array | added in 0.4, see [Sites](#sites) |
| `scheduler` | bool | added in 0.4: `Procfile.lean` runs `bench schedule` (`benchbar service --with-schedule`) |

Kept from frappe-mac 0.2.0 for older readers: `url`, `agent`,
`loaded` (`"yes"` or `"no"`), `stop_flag` (`"manual"`, `"crash"`,
`"broken"` or `"none"`), `ping` (string, `"000"` for no answer). In
0.2.0 `state` held launchd's word (now `agent_state`), and `pid` and
`last_exit_code` were strings.

## Sites

`list --json` (per bench), `status --json` and `benchbar site list --json`
carry the bench's sites, read from `sites/*/site_config.json`:

```json
"sites": [
  { "name": "v16dev", "default": true, "hosts_entry": true, "ping_code": 200 },
  { "name": "v16two", "default": false, "hosts_entry": false, "ping_code": null }
]
```

| Field | Type | Notes |
|---|---|---|
| `name` | string | the site folder |
| `default` | bool | the site `benchup` waits for, the runner pings and the app opens; `benchbar site default NAME` changes it (and runs `bench use`) |
| `hosts_entry` | bool | `/etc/hosts` maps it to 127.0.0.1; `benchbar site hosts` adds the missing lines |
| `ping_code` | number or null | HTTP code of `/api/method/ping` with this site as `Host`; `null` when nothing listens on the web port or nothing answered |

`benchbar site list --json` prints `{"schema_version":1,"cli_version":..,"bench":..,"sites":[..]}`.

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
| `checks[].id` | string | stable id, for example `env_python`, `assets`, `agent`, `legacy_agents`. `pdf_engine` replaced `wkhtmltopdf` in 0.4. 0.5 adds `apps_txt`, `app_branch_policy`, `lock_parse` and `lock_drift` (group `bench`, no repair action) |
| `checks[].group` | string | `system`, `bench`, `service` or `site` |
| `checks[].label` | string | short name for humans |
| `checks[].level` | string | `ok`, `warn` or `fail` |
| `checks[].message` | string | one line for humans |
| `checks[].fix_command` | string or null | the exact command a human would run; `null` when nothing needs doing |
| `checks[].action` | string or null | the `repair` action that fixes it, when `repair` can |
| `summary` | object | counts per level |

`status` and `fix` are the 0.2.0 names of `level` and `fix_command` (with
`""` instead of `null`), kept for older readers.

## `benchbar logs --json`

```json
{"schema_version":1,"cli_version":"0.5.0","bench":"/Users/you/frappe-bench","file":"/Users/you/frappe-bench/logs/bench.log","process":"web","lines":["10:00:01 web.1 | * Running on http://127.0.0.1:8000"]}
```

`-nN` sets how many lines (after the filter), `--process NAME` keeps one
honcho process (`web`, `worker`, `socketio`, `schedule`, `redis_queue`,
`redis_cache`); lines without a honcho prefix, such as a traceback, stay
with the process above them. `process` is `null` without a filter.
Control characters (terminal colors) are removed. `benchbar mcp` uses it
for `benchbar_logs_tail`.
## `benchbar repair --json`

A stream: one JSON object per line on stdout, as the run goes. The human
text goes to the run's log (`.benchbar/logs/<timestamp>.log`).

```json
{"event":"plan","schema_version":1,"cli_version":"0.5.0","bench":"/Users/you/frappe-bench","dry_run":false,"actions":[{"id":"build","label":"bench build","fixes":["Built assets"],"sudo":false},{"id":"hosts_entry","label":"add macdev to /etc/hosts (sudo)","fixes":["/etc/hosts entry"],"sudo":true}],"backups":"/Users/you/.local/share/benchbar/.benchbar/backups","log":"/Users/you/.local/share/benchbar/.benchbar/logs/20260926-101500.log"}
{"event":"step","action":"build","status":"running","message":"bench build"}
{"event":"step","action":"build","status":"done","message":"bench build"}
{"event":"step","action":"hosts_entry","status":"running","message":"add macdev to /etc/hosts (sudo)"}
{"event":"step","action":"hosts_entry","status":"skipped","message":"[WARN] skipped without sudo; run: printf '127.0.0.1 macdev\n' | sudo tee -a /etc/hosts"}
{"event":"done","exit_code":0,"log":"/Users/you/.local/share/benchbar/.benchbar/logs/20260926-101500.log"}
```

| Event | Fields |
|---|---|
| `plan` | `actions[]` with `id` (a repair action), `label`, `fixes` (the doctor checks it fixes), `sudo` (needs a password: skipped without a terminal); `dry_run`; `backups` (the backup root); `log` |
| `step` | `action`, `status` (`running`, then `done`, `skipped` or `failed`), `message` (for `failed` and `skipped`, the CLI's `[FAIL]` or `[WARN]` line) |
| `done` | `exit_code` (0 when every check passes afterwards), `log` |

`repair --dry-run --json` prints only the `plan` line and changes
nothing. Without `--yes` (and without `--dry-run`) nothing is applied:
the plan is printed, then `done` with exit code 1, because the question
cannot be answered. An empty `actions` means nothing needs repairing.
## `benchbar app list --json`

Added in 0.5. Every app of the bench: the lines of `sites/apps.txt` in
order, then any git app in `apps/` that is not listed. The sites come
from `bench --site S list-apps --format json` (15 seconds per site),
cached per bench; `--no-sites` reads only the cache, so it never needs
MariaDB.

```json
{"schema_version":1,"cli_version":"0.5.0","bench":"/Users/you/frappe-bench","profile":"v15-lts",
 "sites_checked_at":"2026-09-25T10:00:00Z","sites_error":null,
 "apps":[{"name":"erpnext","in_apps_txt":true,"repo":"https://github.com/frappe/erpnext","remote":"upstream",
  "branch":"version-15","policy_branch":"version-15","commit":"b5f784612d5b7969b72848dda5b22f10d3a8f764",
  "dirty":false,"shallow":true,"version":"15.115.0","sites":["macdev"]}]}
```

| Field | Type | Notes |
|---|---|---|
| `sites_checked_at` | string or null | when the site lists were last read from bench |
| `sites_error` | string or null | why the last read failed for a site (MariaDB down); its apps come from the previous read |
| `apps[].in_apps_txt` | bool | `false` for a git app that is only a folder (doctor warns) |
| `apps[].repo` | string or null | the URL of the remote the branch follows (else `upstream`, else the first), without a user name or token |
| `apps[].remote` | string or null | that remote's name |
| `apps[].branch` | string or null | `null` on a detached HEAD or without git |
| `apps[].policy_branch` | string or null | the branch `config/apps.tsv` (or the profile, for frappe) names |
| `apps[].commit` | string or null | the full HEAD commit |
| `apps[].dirty` | bool | tracked files have local changes (`git status --porcelain -uno`) |
| `apps[].shallow` | bool | a shallow clone (bench's `shallow_clone`) |
| `apps[].version` | string or null | from `sites/apps.json` |
| `apps[].sites` | array of strings | the sites that have the app installed |

## `benchbar app update NAME --dry-run --json`

Added in 0.5. The plan of an update, after `git fetch` (which changes
only the app's `.git`). `--json` without `--dry-run` is refused.

```json
{"schema_version":1,"cli_version":"0.5.0","bench":"/Users/you/frappe-bench","app":"erpnext","remote":"upstream","branch":"version-15",
 "from":"a1b2c3d...","to":"b5f7846...","commits":[{"sha":"b5f7846","subject":"fix: ..."}],"commits_total":12,
 "sites":["macdev"],"skip_backup":false,
 "steps":[{"name":"Back up macdev","command":"bench --site macdev backup"},{"name":"Fast forward","command":"git -C apps/erpnext merge --ff-only b5f784612d5b"}]}
```

| Field | Type | Notes |
|---|---|---|
| `from`, `to` | string | full commits; equal when there is nothing to take (also when the app is ahead of its remote) |
| `commits` | array | newest first, at most 30, `sha` short |
| `commits_total` | number | all commits in `from..to` |
| `sites` | array of strings | the sites that have the app: each is backed up (unless `skip_backup`) and migrated |
| `steps` | array | in order: `Back up S`, `Fast forward`, `Python requirements`, `Node requirements`, `Migrate S`, `Build`, and `Restart` when the bench runs; empty when there is nothing to do |

A dirty tree, a detached HEAD or a diverged branch exits 1 with the
reason as text.

## `benchbar lock check --json`

Added in 0.5. The bench compared with its lockfile (`benchbar.toml`).
Read only: no network, no database (a site's apps come from the cache
`app list` fills), only `bench --version` for the bench CLI. Exit 1 on
any drift; the JSON is still printed.

```json
{"schema_version":1,"cli_version":"0.5.0","bench":"/Users/you/frappe-bench","lock_file":"/Users/you/frappe-bench/apps/acme/benchbar.toml",
 "in_sync":false,
 "drift":[{"kind":"commit_behind","app":"erpnext","site":null,"expected":"b5f7846","actual":"a1b2c3d","level":"warn","fix_command":"benchbar lock apply"}],
 "summary":{"ok":12,"warn":1,"fail":0}}
```

| `kind` | `level` | Meaning |
|---|---|---|
| `profile_mismatch` | warn | the lock's `[bench] profile` differs from the bench's (a team profile's base) |
| `bench_version_mismatch` | warn | the `frappe-bench` CLI version differs |
| `app_missing` | fail | a lock app has no folder or no `apps.txt` line |
| `app_extra` | warn | an `apps.txt` app the lock does not name |
| `repo_mismatch` | warn | the app's remote is another repo (HTTPS and SSH spellings of one repo compare equal) |
| `branch_mismatch` | warn | another branch, or a detached HEAD (`actual` is `detached`) |
| `commit_behind` | warn | the pinned commit is ahead of the checkout; `lock apply` fast forwards |
| `commit_ahead` | warn | the checkout has commits after the pin; `lock apply` leaves it |
| `commit_diverged` | warn | neither contains the other; `lock apply` leaves it |
| `commit_unknown` | warn | the pin is not in the local history yet; `lock apply` fetches it |
| `dirty` | warn | tracked files have local changes |
| `site_missing` | warn | a lock site has no folder |
| `site_app_missing` | warn | the site lacks an app the lock lists for it (`app` and `site` are both set) |

`expected` and `actual` are strings or `null`; commits are 7 characters.
`summary.ok` counts the lock's apps, sites and bench fields without
drift. Doctor runs the same comparison as `lock_drift` (without the
bench version) and `lock_parse`, both in group `bench` with `action:
null`.

`list --json` gains `benches[].lock_file`: the path `lock check` would
use for that bench (remembered from `--lock`, or `<bench>/benchbar.toml`
when it exists), else `null`.

## `benchbar profile list --json`

Added in 0.5. The built in profiles, then every team profile file on the
lookup path (`~/.config/benchbar/profiles/`, then each folder of
`BENCHBAR_PROFILE_PATH`), invalid ones included so a reader can show why.

```json
{"schema_version":1,"cli_version":"0.5.0","profiles":[
 {"name":"v15-lts","kind":"builtin","source":"builtin","file":"/Users/you/benchbar/config/release-profiles.tsv","base":null,
  "label":"Frappe/ERPNext v15 LTS","frappe_branch":"version-15","valid":true,"error":null},
 {"name":"acme","kind":"team","source":"user","file":"/Users/you/.config/benchbar/profiles/acme.toml","base":"v15-lts",
  "label":"Acme ERP","frappe_branch":null,"valid":true,"error":null}]}
```

| Field | Type | Notes |
|---|---|---|
| `kind` | string | `builtin` or `team` |
| `source` | string | `builtin`, `user` (`~/.config/benchbar/profiles`) or `path` (a `BENCHBAR_PROFILE_PATH` folder) |
| `file` | string | where it was read from |
| `base` | string or null | the built in profile a team profile builds on; `null` for built in ones and invalid files |
| `label` | string or null | the built in label, or a team profile's `description` |
| `frappe_branch` | string or null | a team profile's override, else the built in branch |
| `valid` | bool | `false` when `install --profile NAME` would refuse it |
| `error` | string or null | why: a parse error (`FILE:LINE: not supported: ...`), a name that shadows a built in profile, or a name hidden by an earlier file |
## `benchbar pull --json`

Added in 0.5. Unlike the commands above, `pull` changes things, so it
streams: one JSON object per line on stdout, written as the run goes, and
every human line on stderr. Use it with `--yes` (a gate that cannot be
answered counts as no). Each line carries `schema_version`,
`cli_version` and `event`:

```json
{"schema_version":1,"cli_version":"0.5.0","event":"plan","source":"prod:erp.example.com","host":"prod","remote_site":"erp.example.com","remote_bench":"~/frappe-bench","from_dir":null,"bench":"/Users/you/frappe-bench","site":"erpcopy","replace":false,"backup":{"name":"20260925_020000-erp_example_com-database.sql.gz","new":false,"bytes":734003200,"age_hours":31,"encrypted":false},"encryption_key":true,"apps":[{"app":"frappe","production_version":"15.40.0","production_branch":"version-15","local_version":"15.41.0","local_branch":"version-15","status":"local newer"}],"migrate":true,"steps":["Download the backup","Restore into erpcopy","..."],"dry_run":false}
{"schema_version":1,"cli_version":"0.5.0","event":"gate","name":"apply","answer":"yes"}
{"schema_version":1,"cli_version":"0.5.0","event":"progress","file":"20260925_020000-erp_example_com-database.sql.gz","bytes":700000000,"total":734003200}
{"schema_version":1,"cli_version":"0.5.0","event":"step","n":1,"id":"download","name":"Download the backup","status":"done"}
{"schema_version":1,"cli_version":"0.5.0","event":"done","exit":0,"site":"erpcopy","url":"http://erpcopy:8000","decrypt":{"ok":12,"failed":0},"warnings":[]}
```

| Event | Fields | Notes |
|---|---|---|
| `plan` | `source`, `host`, `remote_site`, `remote_bench`, `from_dir`, `bench`, `site`, `replace`, `backup`, `encryption_key`, `apps`, `migrate`, `steps`, `dry_run` | once, after the read only checks. `backup.name`, `bytes` and `age_hours` are `null` with `--new-backup` (that backup does not exist yet). `encryption_key` says whether production has one to carry over, never its value |
| `gate` | `name` (`new_backup`, `apply`, `replace`), `answer` (`yes`, `no`) | a question the run asked. `new_backup` is `yes` only when the typed (or `--confirm-site`) name matches |
| `progress` | `file`, `bytes`, `total` | after each downloaded file; `bytes` counts the files so far |
| `step` | `n`, `id`, `name`, `status` | `n` counts from 1 in the order of `plan.steps`; `status` is `done`, `unchanged`, `skipped` or `failed` |
| `done` | `exit`, `site`, `warnings`, and on success `url` and `decrypt` | always the last line: also after a refusal or a failure (`exit` 1) and after `--dry-run` (`dry_run: true`) |

`apps[].status` is `ok`, `missing`, `skipped` (`--skip-app`), `branch
differs`, `local older` or `local newer`. `decrypt.ok` and
`decrypt.failed` count the encrypted `__Auth` rows that do and do not
decrypt with the site's `encryption_key`; `failed` above 0 means stored
passwords must be entered again. Step ids: `new_backup`, `download`,
`decrypt`, `local_backup`, `restore`, `encryption_key`, `dev_safety`,
`skip_apps`, `migrate`, `clear_cache`, `admin_password`, `hosts`,
`cleanup`, `verify`; a run lists only the ones it needs.

No event ever holds a password, the encryption key or a token from an
app's remote URL.

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
