---
title: "JSON: lock, profiles and pull"
description: "The JSON of benchbar lock check, the profile commands and pull, which a team uses to keep benches alike."
---

The documents of the commands that a team uses to keep benches alike. The [rules for readers](../../json-schema.md#rules-for-readers) apply to all of them.

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
| `python`, `node`, `mariadb` | string or null | 0.8: the versions the profile brings (`"3.11"`, `"22"`, `"10.11"`), a team profile's from its base; `null` for an invalid file |
| `linux_supported` | bool or null | 0.9: whether `install --profile NAME` passes the Linux profile gate (Python 3.10 or newer from uv, Node 18 or newer from fnm, a MariaDB that apt gives or the profile accepts). A team profile passes or fails with its base. `null` on macOS, where the gate does not exist, and for an invalid file (`error` says why) |
| `unsupported_reason` | string or null | 0.9: when `linux_supported` is `false`, the reasons the install prints after "is not supported on Linux yet:", joined with `; `; `null` otherwise |

0.8 adds `bundles` at the top: the app bundles `install --bundle` takes,
each with `name`, `label`, `apps` (array of app names) and `description`,
from `config/app-bundles.tsv`.

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
 "skipped_apps":["acme_ecr"],"runs_code_from":["github.com/acme"],"new_owners":["github.com/acme"],
 "digest":"c2a1f0...64 hex characters"}
```

`exists` is whether `~/.config/benchbar/profiles/NAME.toml` is there;
`diff` is the unified diff against it (`null` when there is none or they
are equal). `apps[].access` is `null` when the file does not say.
`skipped_apps` are the apps `install --profile` would leave out: the
unreachable ones and every app that requires one. `runs_code_from` is the
host and owner of each repo the profile names (installing it runs their
code: `pip install`, a build, the apps' hooks), and `new_owners` the ones
no app of the bench and no line of `config/apps.tsv` uses yet. `digest` is the SHA-256
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

`{"name","repos":[{"app","repo","reachable","reason","commit"}],"skipped_apps":[...],"frappe_commit","erpnext_commit"}`,
as in the import plan. Since 0.8 each repo carries the `commit` the profile pins it to (`null` for none), and
`frappe_commit` and `erpnext_commit` are the profile's pins for the two apps it does not list
as `[[apps]]` (`null` for none). A pin is read, not tried against the server: whether the clone
reaches it is checked by `install`, before anything is built.

## `benchbar pull --json`

Since 0.8 the `done` line also carries `changed`, `next_actions` and `state_after` ([done fields](../../json-schema.md#the-done-fields-08)); its `warnings` are as before. Since 0.9 the `plan` line has `neutralise` and the `done` line `neutralised`. Since 0.9 the `plan` line has `token` (see `--apply TOKEN`).

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
| `plan` | `source`, `host`, `remote_site`, `remote_bench`, `from_dir`, `bench`, `site`, `replace`, `backup`, `encryption_key`, `neutralise`, `apps`, `migrate`, `create_site`, `before_migrate`, `needs`, `steps`, `dry_run`, `token` | once, after the read only checks. `backup.name`, `bytes` and `age_hours` are `null` with `--new-backup` (that backup does not exist yet). `encryption_key` says whether production has one to carry over, never its value. Since 0.8 `create_site` says the target does not exist and a `new_site` step makes it, `before_migrate` is the path of the `--before-migrate` script or `null`, and `migrate` is `false` with `--no-migrate`. Since 0.9 `neutralise` is `false` with `--keep-secrets`. Since 0.9 `token` is a hash of the plan without `dry_run`, `bytes` and `age_hours`: pass it to `--apply TOKEN --yes` with the same arguments to run exactly this plan; a plan that changed since ends the run with exit 1 before anything is changed. A target the restore cannot go into (a folder without a `site_config.json`, a `bench new-site` that did not finish, no MariaDB root password) ends the run before this line, in a dry run too |
| `gate` | `name` (`new_backup`, `apply`, `replace`), `answer` (`yes`, `no`) | a question the run asked. `new_backup` is `yes` only when the typed (or `--confirm-site`) name matches |
| `progress` | `file`, `bytes`, `total` | after each downloaded file; `bytes` counts the files so far |
| `step` | `n`, `id`, `name`, `status` | `n` counts from 1 in the order of `plan.steps`; `status` is `done`, `unchanged`, `skipped` or `failed` |
| `done` | `exit`, `site`, `warnings`, and on success `url`, `decrypt` and `neutralised` | always the last line: also after a refusal or a failure (`exit` 1) and after `--dry-run` (`dry_run: true`) |

`apps[].status` is `ok`, `missing`, `skipped` (`--skip-app`), `branch
differs`, `local older` or `local newer`. `decrypt.ok` and
`decrypt.failed` count the encrypted `__Auth` rows that do and do not
decrypt with the site's `encryption_key`; `failed` above 0 means stored
passwords must be entered again; both are 0 when the copy was neutralised. `neutralised` is `{"on":false}` with `--keep-secrets`, else `{"on":true,"counts":{KEY:N,...},"labels":{KEY:"text",...}}`: the rows each part of the neutralisation changed (`stored_secrets` counts the deleted passwords) and the words for them. A key is never removed, so a count of 0 means there was nothing to do. Step ids: `new_backup`, `download`,
`decrypt`, `local_backup`, `quiesce`, `new_site`, `restore`,
`encryption_key`, `resume`, `dev_safety`, `neutralise`, `skip_apps`, `before_migrate`,
`migrate`, `clear_cache`, `admin_password`, `hosts`, `cleanup`, `verify`;
a run lists only the ones it needs.

No event ever holds a password, the encryption key or a token from an
app's remote URL.
