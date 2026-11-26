---
title: "JSON: apps"
description: "The JSON of benchbar app list, app focus, app update and app add, with their plans and approval tokens."
---

The documents of the commands that list, update and add the apps of a bench. The [rules for readers](../../json-schema.md#rules-for-readers) apply to all of them.

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
| `apps[].behind` | number or null | commits on the upstream (as last fetched) that HEAD lacks, counted along the upstream's first parent line, so the commits a merge brings in count as the merge (0.8); `null` when unknown (never fetched) |
| `apps[].behind_days` | number or null | the age in days of the first of those commits (0.8: the first on the first parent line, never a commit a merge brought in) |

`app focus NAME [--auto] --json` and `app unfocus NAME --json` print
`{"schema_version","cli_version","bench","app","pin","focus","reasons"}`.

## `benchbar app update NAME --dry-run --json`

Since 0.8 `app update NAME --json` without `--dry-run` streams: the plan line (this document's fields), a step per plan step, and a `done` with `updated` and the [done fields](../../json-schema.md#the-done-fields-08). `--dry-run --json` is still this one document; `--dry-run --jsonl` is the same fields as a `plan` line, then `done`.

Added in 0.5. The plan of an update, after `git fetch` (which changes
only the app's `.git`). Without `--dry-run`, `--json` streams (see the top of this section).

```json
{"schema_version":1,"cli_version":"0.5.0","bench":"/Users/you/frappe-bench","app":"erpnext","remote":"upstream","branch":"version-15",
 "from":"a1b2c3d...","to":"b5f7846...","commits":[{"sha":"b5f7846","subject":"fix: ..."}],"commits_total":12,
 "newer_commits":0,"pending":null,"sites":["macdev"],"skip_backup":false,
 "steps":[{"name":"Back up macdev","command":"bench --site macdev backup","kind":"backup","target":"macdev"},{"name":"Fast forward","command":"git -C apps/erpnext merge --ff-only b5f784612d5b","kind":"fast_forward","target":""}]}
```

| Field | Type | Notes |
|---|---|---|
| `from`, `to` | string | full commits; equal when there is nothing to take (also when the app is ahead of its remote) |
| `commits` | array | newest first, at most 30, `sha` short |
| `commits_total` | number | all commits in `from..to` |
| `sites` | array of strings | the sites that have the app: each is backed up (unless `skip_backup`) and migrated |
| `steps` | array | in order: `Back up S`, `Fast forward`, `Python requirements`, `Node requirements`, `Migrate S`, `Build`, and `Restart` when the bench runs; empty when there is nothing to do. Each has `kind` (`backup`, `fast_forward`, `requirements_python`, `requirements_node`, `migrate`, `build`, `restart`) and `target` (a site, the app, or `""`) besides `name` and `command` |
| `pending` | object or null | the record of an earlier run of this update that stopped part way (the same object `status --json` lists in `pending_operations`, plus `schema_version`, `started_at`), or `null`. With a record, `from` and `to` are the range that run reviewed, `steps` are only the steps it did not finish (the run takes them even when the app is already at `to`), and `commits` is `from..to` |
| `newer_commits` | number | with a record: commits the remote has beyond `to`; they wait for the next run. `0` otherwise |

An app moved by hand since the record was written (its HEAD is neither
`from` nor `to`; or, once the fast forward is done, not `to`) exits 1 and
names `--discard-pending`, which drops the record (and logs what it
dropped) and stops: nothing else runs.

A dirty tree, a detached HEAD or a diverged branch exits 1 with the
reason as text.

## `benchbar app add URL --dry-run --json`

Since 0.8 the result of `--apply TOKEN --yes --json` (one line) also carries the [done fields](../../json-schema.md#the-done-fields-08); with `--jsonl` it is a `done` line with the same fields.

Added in 0.6.0. The plan of an app add, read only, with the token that
`--apply TOKEN --yes` (and `benchbar_app_add` over MCP) needs. The text
goes to stderr. A refusal the plain `app add` also makes (an unknown
name, a URL with a token in it, an unknown site, the app on another
branch) exits 1 with the reason as text; anything else is a plan, with
`can_apply` saying whether it can run.

```json
{"schema_version":1,"cli_version":"0.6.0","bench":"/Users/you/frappe-bench","profile":"v15-lts",
 "target":"https://github.com/acme/acme_crm","app":"acme_crm","package":"acme_crm",
 "repo":"https://github.com/acme/acme_crm","branch":"main","commit":"9b1d2c...40 hex characters","commit_source":"branch","branch_source":"remote_default",
 "present":false,"reachable":true,
 "sites":[{"name":"macdev","installed":false}],"sites_error":null,
 "required_apps":[{"name":"acme_base","required_by":"acme_crm","present":false,"resolves":true,
   "source":"apps_tsv","repo":"https://github.com/acme/acme_base","branch":"main","commit":"4e07aa..."}],
 "missing_required":["acme_base"],"order":["acme_base"],
 "steps":[{"kind":"clone_required","name":"Clone acme_base","command":"bench get-app --skip-assets --branch main https://github.com/acme/acme_base","note":"..."},
  {"kind":"clone","name":"Clone acme_crm","command":"bench get-app --skip-assets --branch main https://github.com/acme/acme_crm","note":"..."},
  {"kind":"build","name":"Build","command":"bench build --apps acme_base,acme_crm","note":"..."},
  {"kind":"install","name":"Install on macdev","command":"bench --site macdev install-app acme_crm","note":"..."},
  {"kind":"restart","name":"Restart","command":"benchbar restart","note":"only when the bench is running, ..."}],
 "errors":[],"changes":true,"can_apply":true,"reason":null,
 "token":"3f9c0e...64 hex characters"}
```

| Field | Type | Notes |
|---|---|---|
| `target` | string | what was asked for, without a user name or token |
| `app` | string | the app name: `--name`, else the package folder that holds `hooks.py`, else the repo name |
| `package` | string or null | that package folder; `null` when `hooks.py` could not be read |
| `repo` | string | the URL `get-app` gets |
| `branch` | string or null | `null` when it could not be told (then `errors` says so) |
| `commit` | string or null | the commit the plan read `hooks.py` from: the pin (always the full hash) when `--commit` is given, else the branch tip; `--apply` stops before build and install when `get-app` checks out another one, and when a pinned commit is not reached by the clone |
| `commit_source` | string | `pin` (`--commit`; for an app already in the bench, it is at the pin) or `branch` |
| `branch_source` | string or null | `given` (`--branch`), `policy` (`config/apps.tsv` or the team profile), `remote_default` (the remote's HEAD) or `present` (the branch of the app already in the bench) |
| `present` | bool | the bench already has the app; then no clone and no build, only installs |
| `reachable` | bool or null | git could read the repo without a prompt, within the timeout; `null` when the app is present (nothing is fetched) |
| `sites[]` | array | the target sites (`--site`, `--all-sites`, `--install-on`) and whether each has the app already (in a batch: the union over the apps, `installed` true when no app of the batch needs an install there) |
| `apps[]` | array | present only when several apps were given: one entry per target, in the order given, with its own `app`, `package`, `target`, `repo`, `branch`, `branch_source`, `commit`, `commit_source`, `present`, `reachable`, `install_on` (the sites of its `--install-on`, empty when it has none), `sites[]` (its own sites and whether it is installed there) and `required_apps` (the names its `hooks.py` requires). The fields above describe the first target; `required_apps[]`, `missing_required`, `order` and `steps[]` cover the whole batch |
| `sites_error` | string or null | as in `app list --json` |
| `required_apps[]` | array | every app `hooks.py` requires, followed through the ones that get cloned; `present` in the bench, `resolves` through `source` (`apps_tsv` or `team_profile`) with its `repo`, `branch` and `commit` |
| `missing_required` | array of strings | the required apps the plan clones or cannot resolve |
| `order` | array of strings | the apps the plan clones, each after the apps it requires (ties keep the order the plan always had), the apps being added after the ones they need when they are cloned; the required apps of every target are one graph, an app two targets require is cloned once. A cycle in `required_apps` is an `errors` entry, `required_apps cycle: a -> b -> a`, with `can_apply` false |
| `reason` | string or null | set when a record of an earlier, unfinished add of this app is merged into the plan (the build, installs and restart it did not finish are `steps`, `changes` is true); otherwise `null` |
| `steps[]` | array | in the order `--apply` runs them; `kind` is `clone_required`, `clone`, `requirements_python` (only when an earlier run left a cloned app without its pip install), `build` (one for every app that is cloned), `install` (one per app and site, site by site, each site in dependency order; named `Install APP on SITE` when several apps were given) or `restart` (once, run only when the bench is running); `note` says what else the step does, for `install` that it changes the site's database like a migrate of these apps |
| `errors` | array of strings | why the plan cannot run: an unreadable repo, a missing branch, no `hooks.py`, a required app nothing resolves |
| `changes` | bool | `false` when there is nothing to do |
| `can_apply` | bool | `false` when `errors` is not empty |
| `token` | string | SHA-256 of the plan (the commits included, so a branch that moves makes it stale) and of the bench's `sites/apps.txt`, `apps/` folders and site list |

`benchbar app add URL --apply TOKEN --yes --json`, the result:
`{"schema_version", "cli_version", "bench", "app", "branch", "commit",
"commit_source", "token", "applied": true, "ok", "steps": [{"kind", "name",
"status", "reason"}], "apps": [...], "required_apps": [...]}`. `apps[]` has one
entry per target (always, also for one app) and `required_apps[]` one per
required app that was cloned: `{"app", "cloned", "clone", "build",
"installs": [{"site", "status", "migrate", "reason"}]}`. `cloned` is true when
this run cloned the app; `clone` and `build` are the status of that step
(`null` when the app had none, for example `build` of an app that was
already there); each install has the status of its step and the same
status as `migrate`, because `install-app` is what runs the app's patches
and syncs its DocTypes (there is no separate migrate step). An install
skipped because an app it requires failed to install on that site has
`reason` `after failed install of APP`. Where
`status` is `done`, `failed`, `skipped` (after a failed step it depends on:
clone, then build, then install and restart; or a restart of a stopped
bench) or `pending`. `reason` is `after failed <kind>` for a step skipped
because of a failure, else null. A failed or skipped step stays in the
app's pending record, which the next plan merges. Exit 0 when `ok`. A stale
token or a plan that cannot run exits 1 with no JSON and the reason on
stderr.
