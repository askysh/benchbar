---
title: "benchbar JSON API, schema version 1"
description: "The versioned JSON that benchbar prints for list, status, doctor, logs, repair, apps, lock, profiles, pull and site backups, and the state file the runner writes."
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
| `benchbar app focus --json` | focus apps and how far behind the apps they need are (0.6), see [app focus](#benchbar-app-focus---json) |
| `benchbar profile list --json` | built in and team profiles, with where each comes from (0.5) |
| `benchbar profile export\|import\|subscribe\|update\|remove\|check ... --json` | sharing team profiles (0.6), see [profile sharing](#profile-sharing) |
| `benchbar lock check --json` | how the bench differs from its `benchbar.toml` (0.5) |
| `<bench>/logs/.benchbar/state.json` | the last state transition, written by the runner and the CLI |
| `benchbar pull ... --json` | JSON lines while a production site is copied, see [pull](#benchbar-pull---json) |
| `benchbar report --json` | where the redacted diagnostics zip went (0.5.5), see [report](#benchbar-report---json) |
| `benchbar site backup NAME --json` | the backup just taken (0.5.8), see [site backups](#site-backups) |
| `benchbar site backups NAME --json` | every backup of a site (0.5.8) |
| `benchbar site drop NAME --json` | the plan (with `--dry-run`) or the result of dropping a site (0.5.8) |

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
   `benchfg` counts as running. While the runner's `state.json` says
   `running` or `starting` and launchd runs that very pid, that is the
   answer; otherwise one process scan looks for this bench's honcho,
   serve, worker, schedule and socketio (0.6.1: port listeners alone no
   longer count, a leftover Redis is not a running bench).
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
| `web_ping_code` | number or null | HTTP code of `GET /api/method/ping` with the site as `Host`; `null` when nothing answered. Asked only while processes run, with a 2 second limit (3 seconds before 0.6.1) |
| `ports` | object | as in `list` |
| `state_file`, `log` | string | paths |
| `agent_loaded` | bool | the launchd agent is loaded |
| `agent_state` | string or null | launchd's own word, for example `running` or `not running` |
| `processes_running` | bool | any honcho, serve, worker, schedule or socketio process of this bench (before 0.6.1 a port listener counted too) |
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
| `ping_code` | number or null | HTTP code of `/api/method/ping` with this site as `Host`; `null` when nothing listens on the web port or nothing answered. Since 0.6.1 `list --json` and `status --json` leave it `null` (they are polled; `web_ping_code` is the default site's ping) unless `status --json --ping` asks every site once; `site list --json` always asks |

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
| `checks[].id` | string | stable id, for example `env_python`, `assets`, `agent`, `legacy_agents`. `pdf_engine` replaced `wkhtmltopdf` in 0.4. 0.5 adds `apps_txt`, `app_branch_policy`, `lock_parse` and `lock_drift` (group `bench`, no repair action). 0.6 adds `dependency_behind`, `apps_behind` and `profile_outdated` (group `bench`, no repair action); `dependency_behind` is the one id that can appear several times, once per stale dependency |
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
| `apps[].focus`, `focus_pin`, `focus_reasons`, `requires`, `needed_by`, `upstream`, `behind`, `behind_days` | | added in 0.6, the same fields as [app focus](#benchbar-app-focus---json) |

## `benchbar app focus --json`

Added in 0.6. Every app of the bench, whether it is a focus app (one you
work on) and why, what it needs, which focus apps need it, and how far it
is behind its remote branch. Local reads only; `--fetch` fetches the
dependencies of the focus apps first (so does `doctor --fetch`; nothing
fetches without the flag). `fetched_at` is benchbar's last such fetch.

```json
{"schema_version":1,"cli_version":"0.6.0","bench":"/Users/you/frappe-bench","focus_days":14,"fetched_at":"2026-09-29T08:00:00Z",
 "apps":[{"name":"exponent_ecr","focus":true,"focus_pin":"auto","focus_reasons":["your commit 2 day(s) ago"],"requires":["exponent_custom_v1"],
  "needed_by":[],"upstream":"upstream/develop","behind":0,"behind_days":0},
  {"name":"exponent_custom_v1","focus":false,"focus_pin":"auto","focus_reasons":[],"requires":[],
  "needed_by":["exponent_ecr"],"upstream":"upstream/develop","behind":30,"behind_days":12}]}
```

| Field | Type | Notes |
|---|---|---|
| `fetched_at` | string or null | the last fetch of the dependencies that worked |
| `focus_days` | number | how recent a commit of yours must be to count |
| `apps[].focus` | bool | a focus app: pinned so, or (pin `auto`) with a reason |
| `apps[].focus_pin` | string | `auto`, `focus` (`app focus NAME`) or `ignore` (`app unfocus NAME`) |
| `apps[].focus_reasons` | array of strings | `pinned`, `local changes`, `on BRANCH, not POLICY`, `your commit today` or `your commit N day(s) ago`; empty when not a focus app |
| `apps[].requires` | array of strings | `required_apps` from the app's `hooks.py`, frappe left out |
| `apps[].needed_by` | array of strings | the focus apps that need it, directly or through another app; empty for a focus app |
| `apps[].upstream` | string or null | `REMOTE/BRANCH` the app's branch follows; `null` on a detached HEAD |
| `apps[].behind` | number or null | commits on the upstream (as last fetched) that HEAD lacks; `null` when unknown (never fetched) |
| `apps[].behind_days` | number or null | the age in days of the oldest of those commits |

`app focus NAME [--auto] --json` and `app unfocus NAME --json` print
`{"schema_version","cli_version","bench","app","pin","focus","reasons"}`.

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

## `benchbar app add URL --dry-run --json`

Added in 0.6.0. The plan of an app add, read only, with the token that
`--apply TOKEN --yes` (and `benchbar_app_add` over MCP) needs. The text
goes to stderr. A refusal the plain `app add` also makes (an unknown
name, a URL with a token in it, an unknown site, the app on another
branch) exits 1 with the reason as text; anything else is a plan, with
`can_apply` saying whether it can run.

```json
{"schema_version":1,"cli_version":"0.6.0","bench":"/Users/you/frappe-bench","profile":"v15-lts",
 "target":"https://github.com/acme/acme_crm","app":"acme_crm","package":"acme_crm",
 "repo":"https://github.com/acme/acme_crm","branch":"main","commit":"9b1d2c...40 hex characters","branch_source":"remote_default",
 "present":false,"reachable":true,
 "sites":[{"name":"macdev","installed":false}],"sites_error":null,
 "required_apps":[{"name":"acme_base","required_by":"acme_crm","present":false,"resolves":true,
   "source":"apps_tsv","repo":"https://github.com/acme/acme_base","branch":"main","commit":"4e07aa..."}],
 "missing_required":["acme_base"],
 "steps":[{"kind":"clone_required","name":"Clone acme_base","command":"bench get-app --skip-assets --branch main https://github.com/acme/acme_base","note":"..."},
  {"kind":"clone","name":"Clone acme_crm","command":"bench get-app --skip-assets --branch main https://github.com/acme/acme_crm","note":"..."},
  {"kind":"build","name":"Build","command":"bench build --apps acme_base,acme_crm","note":"..."},
  {"kind":"install","name":"Install on macdev","command":"bench --site macdev install-app acme_crm","note":"..."},
  {"kind":"restart","name":"Restart","command":"benchbar restart","note":"only when the bench is running, ..."}],
 "errors":[],"changes":true,"can_apply":true,
 "token":"3f9c0e...64 hex characters"}
```

| Field | Type | Notes |
|---|---|---|
| `target` | string | what was asked for, without a user name or token |
| `app` | string | the app name: `--name`, else the package folder that holds `hooks.py`, else the repo name |
| `package` | string or null | that package folder; `null` when `hooks.py` could not be read |
| `repo` | string | the URL `get-app` gets |
| `branch` | string or null | `null` when it could not be told (then `errors` says so) |
| `commit` | string or null | the commit the plan read `hooks.py` from; `--apply` stops before build and install when `get-app` checks out another one |
| `branch_source` | string or null | `given` (`--branch`), `policy` (`config/apps.tsv` or the team profile), `remote_default` (the remote's HEAD) or `present` (the branch of the app already in the bench) |
| `present` | bool | the bench already has the app; then no clone and no build, only installs |
| `reachable` | bool or null | git could read the repo without a prompt, within the timeout; `null` when the app is present (nothing is fetched) |
| `sites[]` | array | the target sites (`--site`, `--all-sites`) and whether each has the app already |
| `sites_error` | string or null | as in `app list --json` |
| `required_apps[]` | array | every app `hooks.py` requires, followed through the ones that get cloned; `present` in the bench, `resolves` through `source` (`apps_tsv` or `team_profile`) with its `repo`, `branch` and `commit` |
| `missing_required` | array of strings | the required apps the plan clones or cannot resolve |
| `steps[]` | array | in the order `--apply` runs them; `kind` is `clone_required`, `clone`, `build`, `install` or `restart` (run only when the bench is running); `note` says what else the step does, for `install` that it changes the site's database like a migrate of these apps |
| `errors` | array of strings | why the plan cannot run: an unreadable repo, a missing branch, no `hooks.py`, a required app nothing resolves |
| `changes` | bool | `false` when there is nothing to do |
| `can_apply` | bool | `false` when `errors` is not empty |
| `token` | string | SHA-256 of the plan (the commits included, so a branch that moves makes it stale) and of the bench's `sites/apps.txt`, `apps/` folders and site list |

`benchbar app add URL --apply TOKEN --yes --json`, the result:
`{"schema_version", "cli_version", "bench", "app", "branch", "token",
"applied": true, "ok", "steps": [{"kind", "name", "status"}]}`, where
`status` is `done`, `failed`, `skipped` (after a failed clone, or a
restart of a stopped bench) or `pending`. Exit 0 when `ok`. A stale
token or a plan that cannot run exits 1 with no JSON and the reason on
stderr.

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
lookup path (`~/.config/benchbar/profiles/`, then each subscription in
subscribe order, then each folder of `BENCHBAR_PROFILE_PATH`), invalid
ones included so a reader can show why. Read only and offline: how far a
subscription is behind comes from its last fetch.

```json
{"schema_version":1,"cli_version":"0.6.0","profiles":[
 {"name":"v15-lts","kind":"builtin","source":"builtin","source_url":null,"subscription":null,"shadowed_by":null,"schema":null,
  "file":"/Users/you/benchbar/config/release-profiles.tsv","base":null,
  "label":"Frappe/ERPNext v15 LTS","frappe_branch":"version-15","valid":true,"error":null},
 {"name":"acme","kind":"team","source":"subscribed","source_url":"git@github.com:acme/bench-config.git",
  "subscription":{"repo":"git@github.com:acme/bench-config.git","dir":"/Users/you/.config/benchbar/sources/acme-bench-config",
   "behind":2,"days":5,"fetched_at":"2026-09-29T10:00:00Z"},"shadowed_by":null,"schema":2,
  "file":"/Users/you/.config/benchbar/sources/acme-bench-config/profiles/acme.toml","base":"v15-lts",
  "label":"Acme ERP","frappe_branch":null,"valid":true,"error":null}]}
```

| Field | Type | Notes |
|---|---|---|
| `kind` | string | `builtin` or `team` |
| `source` | string | `builtin`, `user` (a file in `~/.config/benchbar/profiles`) or `path` (a `BENCHBAR_PROFILE_PATH` folder); 0.6 adds `imported` (a file there that `profile import` wrote) and `subscribed` |
| `source_url` | string or null | 0.6: the URL or path an imported file came from, or a subscription's repo URL; `null` otherwise |
| `subscription` | object or null | 0.6: for a subscribed profile, `repo`, `dir`, `behind` (commits the clone lacks, int or null), `days` (age of the oldest of them, int or null) and `fetched_at` (the last successful fetch, or null) |
| `shadowed_by` | string or null | 0.6: the file that hides this one (an earlier file of the same name, or the built in profiles' file) |
| `schema` | int or null | 0.6: the file's `schema` (1 when it has none); `null` for built in profiles and invalid files |
| `file` | string | where it was read from |
| `base` | string or null | the built in profile a team profile builds on; `null` for built in ones and invalid files |
| `label` | string or null | the built in label, or a team profile's `description` |
| `frappe_branch` | string or null | a team profile's override, else the built in branch |
| `valid` | bool | `false` when `install --profile NAME` would refuse it |
| `error` | string or null | why: a parse error (`FILE:LINE: not supported: ...`), a name that shadows a built in profile, or a name hidden by an earlier file |

## Profile sharing

Added in 0.6. With `--json`, each of these prints one document on stdout
and every human line on stderr. `--plan` is read only (it may ask git and
the network, never writes) and takes no lock. A write needs `--yes`: a
question that cannot be answered counts as no and exits 1. A refusal or
error exits 1; `profile check` exits 0 whatever it finds. `reachable` is
`true`, `false` (git answered no: no access, no such repo or branch) or
`null` (offline or timed out, 10 seconds per repo), with `reason` saying
why when it is not `true`.

### `benchbar profile export NAME --plan --json`

```json
{"schema_version":1,"cli_version":"0.6.0","name":"acme","base":"v15-lts","apps":[
 {"name":"acme_ecr","repo":"git@github-work:acme/acme_ecr.git","exported_repo":"git@github.com:acme/acme_ecr.git",
  "current_branch":"wip","exported_branch":"develop","default_branch":"develop","branch_verified":true,
  "access":"private","requires":["acme_base"],"keep":true}],
 "warnings":["acme_ecr: git@github-work:acme/acme_ecr.git is written as git@github.com:acme/acme_ecr.git"],
 "digest":"5d41aa...64 hex characters"}
```

| Field | Type | Notes |
|---|---|---|
| `apps[].repo` | string | the URL in the profile |
| `apps[].exported_repo` | string | the URL written: SSH alias resolved with `ssh -G`, user info removed |
| `apps[].current_branch` | string | the branch in the profile |
| `apps[].exported_branch` | string | the branch written: `--branch APP=BR`, else the repo's default branch; an app of `config/apps.tsv` on the base's release branch (erpnext on `version-15`) keeps it |
| `apps[].default_branch` | string or null | what the remote's HEAD points at; `null` when git could not tell |
| `apps[].branch_verified` | bool | the exported branch exists on the remote |
| `apps[].access` | string | `public` (a stranger can read it over https), `private`, `personal` (private, and its GitHub owner is a user, not an organisation) or `unknown` (offline, or not an https or SSH URL) |
| `apps[].requires` | list of strings | from the profile, else from the app's `hooks.py` in the bench (`--bench-dir`) |
| `apps[].keep` | bool | `false` for an app given to `--drop` |
| `warnings` | list of strings | for a person: rewritten URLs, unverified branches, personal repos, drops that are refused |
| `digest` | string | 0.6: SHA-256 of what the plan read: the profile file and each app's URLs, branches, access and requires; the same with or without `--branch` and `--drop` |

`profile export NAME --out FILE [--branch APP=BR]... [--drop APP]... --yes --json`
writes the file and prints `{"path","apps","dropped"}`: the path, how many
apps it holds and the dropped ones. Dropping an app that a kept app
requires is refused with exit 1 and
`{"error":"...","blocked":[{"app":"acme_base","required_by":["acme_ecr"]}]}`.
With `--expect DIGEST` it refuses (exit 1, nothing written) when the plan
no longer matches that digest. BenchBar passes the digest and every kept
app's branch, so it writes exactly what the sheet showed.

### `benchbar profile import SRC [--as NAME] --plan --json`

```json
{"schema_version":1,"cli_version":"0.6.0","name":"acme","source":"https://github.com/acme/config/blob/main/acme.toml",
 "exists":true,"diff":"@@ -3 +3 @@\n-description = \"Acme\"\n+description = \"Acme ERP\"","base":"v15-lts",
 "apps":[{"name":"acme_ecr","repo":"git@github.com:acme/acme_ecr.git","branch":"develop","access":"private","requires":["acme_base"]}],
 "check":{"repos":[{"app":"acme_ecr","repo":"git@github.com:acme/acme_ecr.git","reachable":false,"reason":"Permission denied (publickey)."}]},
 "skipped_apps":["acme_ecr"],"digest":"c2a1f0...64 hex characters"}
```

`exists` is whether `~/.config/benchbar/profiles/NAME.toml` is there;
`diff` is the unified diff against it (`null` when there is none or they
are equal). `apps[].access` is `null` when the file does not say.
`skipped_apps` are the apps `install --profile` would leave out: the
unreachable ones and every app that requires one. `digest` is the SHA-256
of the file the import would write. With `--yes --json` it writes and
prints `{"name","path","source"}`; with `--expect DIGEST` as well, it
refuses (exit 1, nothing written) when the source changed since that plan.

### `benchbar profile subscribe GIT_URL [--plan|--yes] --json`

`{"repo","dir","profiles"}`: the URL, the clone's folder
(`~/.config/benchbar/sources/OWNER-REPO`) and the valid profile names in
it. Subscribing to a URL already subscribed prints the same and changes
nothing.

### `benchbar profile update NAME|--all --plan --json`

```json
{"schema_version":1,"cli_version":"0.6.0","updates":[
 {"name":"acme","kind":"subscribed","behind":2,"diff":"diff --git a/profiles/acme.toml ..."}],
 "digest":"77e3b9...64 hex characters"}
```

`kind` is `imported` or `subscribed`; `behind` is the new commits of a
subscription (`null` for an import); `diff` is `null` when there is
nothing new. `digest` covers what the plan showed: each import's fetched
file and each subscription's upstream commit. With `--yes` the same
document adds `"applied":true` (`false` when one of them could not be
applied); `--expect DIGEST` refuses (exit 1, nothing changed) when the
source has moved on since that plan, and a subscription fast forwards to
the reviewed commit, not a newer one.

### `benchbar profile remove NAME --yes --json`

`{"name","moved_to"}`: the file or subscription folder now under
`~/.config/benchbar/removed/<timestamp>/`.

### `benchbar profile check NAME --json`

`{"name","repos":[{"app","repo","reachable","reason"}],"skipped_apps":[...]}`,
as in the import plan.

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

## `benchbar report --json`

Writes the redacted diagnostics zip (to `~/Desktop`, or `--out DIR`) and
prints one line on stdout; the human text goes to stderr. The BenchBar
app's Report a Bug uses it.

```json
{"schema_version":1,"cli_version":"0.5.5","zip":"/Users/you/Desktop/benchbar-report-20260926-101500.zip","redactions":14}
```

| Field | Type | Meaning |
|---|---|---|
| `zip` | string | absolute path of the zip just written |
| `redactions` | number | lines on which something was replaced (a credential, the home folder, the username, a name of this Mac); `REDACTIONS.txt` in the zip lists them |

Exit 0 when the zip was written. `--json` with `--print` exits 1.

## Site backups

`site backup`, `site backups` and `site drop` (0.5.8) describe a backup
the same way. A backup is the files in the site's backup folder that
share one timestamp:

```json
{
  "stamp": "20260929_101500",
  "time": "2026-09-29T04:45:00Z",
  "path": "/Users/you/frappe-bench/sites/macdev/private/backups/20260929_101500-macdev-database.sql.gz",
  "database": "/Users/you/frappe-bench/sites/macdev/private/backups/20260929_101500-macdev-database.sql.gz",
  "files": "/Users/you/frappe-bench/sites/macdev/private/backups/20260929_101500-macdev-files.tar",
  "private_files": "/Users/you/frappe-bench/sites/macdev/private/backups/20260929_101500-macdev-private-files.tar",
  "config": "/Users/you/frappe-bench/sites/macdev/private/backups/20260929_101500-macdev-site_config_backup.json",
  "size_bytes": 5242880,
  "with_files": true,
  "encrypted": false,
  "partial": false
}
```

| Field | Meaning |
|---|---|
| `stamp` | the timestamp at the start of the file names, in the site's time zone |
| `time` | when the database file was written, UTC |
| `path` | the database file, the one a restore needs (else the first file of the set) |
| `database`, `files`, `private_files`, `config` | each part, `null` when the set has none |
| `size_bytes` | all parts together |
| `with_files` | the set has the public or private files |
| `encrypted`, `partial` | bench's encrypted and partial backups (`-enc`, `-partial`) |

`benchbar site backups NAME --json`: `{"schema_version", "cli_version",
"bench", "site", "folder", "backups": [backup, ...]}`, newest first.

`benchbar site backup NAME --json`: `{"schema_version", "cli_version",
"bench", "site", "dry_run", "backup": backup}`; `backup` is `null` in a
dry run.

`benchbar site drop NAME --confirm-site NAME --dry-run --json`, the plan:

```json
{
  "schema_version": 1, "cli_version": "0.5.8",
  "bench": "/Users/you/frappe-bench", "site": "bbtest.localhost",
  "dry_run": true, "is_default": false, "new_default": null,
  "steps": [
    {"title": "Back up bbtest.localhost with files, drop its database and user, move the folder to archived/sites", "command": "bench drop-site bbtest.localhost", "needs_password": false},
    {"title": "Remove '127.0.0.1 bbtest.localhost' from /etc/hosts", "command": "sudo, backup first", "needs_password": true}
  ]
}
```

And the result, without `--dry-run`:

| Field | Meaning |
|---|---|
| `dropped` | `true`; a failed drop exits 1 with no JSON |
| `archived_path` | the site folder in `archived/sites/`, `null` if bench put it elsewhere |
| `backup` | the backup bench took before dropping (inside the archived folder), or `null` |
| `new_default` | the site that became the default, or `null` |
| `hosts_removed` | the `/etc/hosts` line was removed |
| `manual_step` | the command that removes the hosts line by hand when benchbar could not (no terminal for `sudo`, a line outside benchbar's block), else `null` |

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

## Folder discovery

`benchbar scan PATH --json` is read only and returns a schema-version-1 object:
`schema_version`, `cli_version`, `root` (canonical selected folder), `benches`
(the same entries as `list`), and `warnings` (strings for skipped unreadable
folders). A valid folder with no benches returns an empty array; an invalid or
unreadable root exits 1. Hidden directories, symlinks, dependency/build folders,
and test/fixture folders are skipped. A found bench's children are not scanned.

`benchbar register PATH ... --json` validates every path, atomically remembers
the canonical paths in `.benchbar/registered-benches.txt`, then returns the
normal `list` response. It does not create services or change the default bench.
`--dry-run` does not write the registry. List includes these registered paths
while they still identify bench directories. Registration is idempotent.

Same-named benches receive distinct launchd labels when necessary, using a
canonical-path checksum suffix. An installed label owned by the same bench
is retained. Clients should always use the returned label rather than deriving
it from the directory name.

## Port management

`benchbar ports plan --json -- PATH ...` is read-only. Canonical paths are
sorted and deduplicated. The response has `schema_version: 1`, an opaque `token`,
`can_apply` (boolean), and `entries`. Each entry includes `path`, `name`, `site`,
`mode` (`automatic` or `fixed`), `current` and `proposed` port objects (`web`,
`socketio`, `redis_queue`, `redis_cache`), `conflicts` (strings), `blocked`
(string or null), `service_installed` (boolean), and `setup_plan` (string, or null when setup is blocked):
the adoption dry-run output for the proposed allocation, including service
and hosts changes. The approval token covers this plan.

`ports plan` without `--json` renders a readable preview. `ports setup -- PATH ...`
shows that preview and asks before applying, without manual token copying.
`ports setup --dry-run` only previews. Plan, setup and apply use each bench’s
detected site/profile and reject `--site` or `--profile` overrides.

`ports apply TOKEN --yes -- PATH ...` recomputes the selection under the CLI lock;
a changed token or any blocked entry fails before adoption. It emits human
progress, including completed paths and any failing path, and exits nonzero on
failure. Earlier completed entries remain configured. A new preview is required
before retrying. Apply does not start services. Socket availability cannot be
reserved against unrelated programs; start checks again before launching.

`ports check --json --bench-dir PATH` returns `schema_version: 1`, `conflicts`
(strings), `mode`, and `already_running` (boolean, positively owned running
processes). Clients may treat `up` as idempotent when `already_running` is true;
restart still needs a conflict check. It checks configured reservations and all listening PIDs,
ignoring only listeners positively identified as belonging to that bench.

`ports mode automatic|fixed --bench-dir PATH` saves the policy and reserves the
current ports without moving them. `--dry-run` does not save it. New benches
default to automatic. Fixed mode means the current allocation stays pinned until
the policy changes or an explicit CLI `--port-offset` override is requested.
