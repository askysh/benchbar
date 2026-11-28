---
title: "benchbar JSON API, schema version 1"
description: "The versioned JSON that benchbar prints, the rules every reader follows, the result envelope and the done fields. One page per command family lists each document."
head:
  - tag: script
    attrs:
      src: /moved/json-schema.js
      defer: true
  - tag: script
    attrs:
      src: /moved-anchors.js
      defer: true
---

`benchbar` (and its alias `frappe-mac`, the old name) prints versioned JSON for the
commands below, and the runner writes one state file per bench. The BenchBar
app reads nothing else, so this is a public API: coding agents, scripts,
Raycast extensions and the like can rely on it too.

| Source | What it is |
|---|---|
| `benchbar list --json` | every bench benchbar knows about |
| `benchbar status --json [--bench-dir DIR]` | the live state of one bench |
| `benchbar stats --json [--bench-dir DIR]` | CPU and memory of the running bench's own processes (0.9) |
| `benchbar doctor --json [--bench-dir DIR]` | every health check with its fix |
| `benchbar app list --json` | the bench's apps, their git state and sites (0.5) |
| `benchbar app update NAME --dry-run --json` | the changelog and plan of an update (0.5) |
| `benchbar app focus --json` | focus apps and how far behind the apps they need are (0.6), see [app focus](reference/json/apps.md#benchbar-app-focus---json) |
| `benchbar profile list --json` | built in and team profiles, with where each comes from (0.5) |
| `benchbar profile export\|import\|subscribe\|update\|remove\|check ... --json` | sharing team profiles (0.6), see [profile sharing](reference/json/teams.md#profile-sharing) |
| `benchbar lock check --json` | how the bench differs from its `benchbar.toml` (0.5) |
| `<bench>/logs/.benchbar/state.json` | the last state transition, written by the runner and the CLI |
| `<bench>/logs/.benchbar/heartbeat` | since 0.6.1: rewritten in place every 30 seconds while the runner runs; its mtime says the runner is alive |
| `benchbar pull ... --json` | JSON lines while a production site is copied, see [pull](reference/json/teams.md#benchbar-pull---json) |
| `benchbar install --json`, `benchbar adopt PATH --json` | JSON lines while a bench is created or adopted (0.8), see [install](reference/json/install-and-doctor.md#benchbar-install---json) |
| `benchbar doctor --prerequisites --json` | what the Mac needs before an install, without a bench (0.8), see [prerequisites](reference/json/install-and-doctor.md#benchbar-doctor---prerequisites---json) |
| `benchbar report --json` | where the redacted diagnostics zip went (0.5.5), see [report](reference/json/state-and-diagnostics.md#benchbar-report---json) |
| `benchbar commands --json` | every command, flag and what it needs (0.8), see [the done fields](#the-done-fields-08) |
| `benchbar where --json` | how this CLI was installed, the path it records for itself, its state folder and the app (0.7), see [where](reference/json/state-and-diagnostics.md#benchbar-where---json) |
| `benchbar site backup NAME --json` | the backup just taken (0.5.8), see [site backups](reference/json/sites-and-backups.md#site-backups) |
| `benchbar site backups NAME --json` | every backup of a site (0.5.8) |
| `benchbar site snapshot NAME --json`, `site snapshots NAME --json` | one snapshot, the snapshots of a site (0.9.0), see [site snapshots](reference/json/sites-and-backups.md#site-snapshots) |
| `benchbar site rollback NAME --to SNAPSHOT --dry-run --json` | the plan and result of a rollback: [site restore](reference/json/sites-and-backups.md#benchbar-site-restore---json) with a `rollback` block (0.9.0) |
| `benchbar up\|down\|restart\|service\|site add\|site default --json` | JSON lines ending in one `done` (0.8), see [the done fields](#the-done-fields-08) |
| `benchbar site drop NAME --json` | the plan (with `--dry-run`) or the result of dropping a site (0.5.8) |
| `benchbar op status [OP_ID]\|list\|wait OP_ID --json` | the long runs: one record or the recent ones (0.9), see [operation handles](reference/json/operations.md#operation-handles-09) |
| `<state folder>/ops/<op_id>.json` | the record a run keeps of itself, rewritten at each step (0.9) |
| `benchbar history [--bench PATH] [--since TIME] [--limit N] --json` | the runs that changed things on this machine, newest first (0.9), see [action history](reference/json/operations.md#action-history-09) |
| `<state folder>/history.jsonl` | one line per finished run, 1 MB and three older files (0.9) |

## The schema file

[`schema/benchbar.schema.json`](https://github.com/askysh/benchbar/blob/main/schema/benchbar.schema.json)
(JSON Schema 2020-12) is the source of truth. This page and the pages below
explain it; when they and the file disagree, the file is right and the pages
are a bug. It has one definition under `$defs` per document or stream line
that an app or the MCP server reads:

| Definition | What it describes |
|---|---|
| `status`, `stateFile` | `status --json` and `logs/.benchbar/state.json` |
| `list`, `listBench` | `list --json` |
| `doctor`, `doctorCheck`, `doctorPrerequisites` | `doctor --json` and `doctor --prerequisites --json` |
| `logs` | `logs --json` |
| `appList`, `appFocus` | `app list --json` and `app focus --json` |
| `siteList`, `siteBackups`, `siteBackup` | `site list`, `site backups` and `site backup` |
| `profileList` | `profile list --json` |
| `labsList` | `labs list --json` |
| `portsCheck` | `ports check --json` |
| `where`, `report` | `where --json` and `report --json` |
| `planLine`, `stepLine`, `repairStepLine`, `progressLine`, `doneLine`, `streamLine` | the lines of a `--json` or `--jsonl` stream |
| `doneFields` | the result envelope, see [the done fields](#the-done-fields-08) |
| `document` | any other document: the envelope only, until it has a definition of its own |

How to read it:

- `required` lists the fields that every CLI version since the field arrived
  prints, so a document recorded from an old CLI still fits. Everything else
  is optional for a reader.
- `x-since` says in which version a field arrived. `x-conditional` marks a
  field printed only in some cases (a plan field of one command, the done
  fields of a dry run). Every other field is printed by the CLI of the same
  checkout, always, and `null` where it does not apply.
- An `enum` lists the values this CLI prints. A reader still treats a value it
  does not know as unknown, see below.

`tests/test-json-schema.sh` keeps the file, the CLI and its readers together.
It checks that every recorded fixture of the Mac app and the Windows tray fits
its definition (`schema/fixtures.map`), that what the CLI prints under the
mocks fits and prints every non conditional field, that the Swift models, the
tray's C# models and the MCP server read only fields the schema has and need
only fields it requires (`schema/models.map`, `CLI_READS` in
`lib/frappe-local/mcp.py`), and that these pages name every field of the
schema. A pull request that adds a field to the CLI's JSON adds it to the
schema in the same pull request, or the test fails.

## The pages

This page holds what every document shares: the rules for readers, the
done fields, the result envelope and the bench states. Each command family
has its own page for the fields of its documents.

| Page | Documents |
|---|---|
| [List, status, stats, wait and logs](reference/json/list-and-status.md) | `list`, `status`, `stats`, `wait`, `logs` and the `ready` object |
| [Sites, backups and snapshots](reference/json/sites-and-backups.md) | `site add`, `users`, `service`, `site backup`, snapshots, `site restore` |
| [Install, adopt, doctor and repair](reference/json/install-and-doctor.md) | `install`, `adopt`, `doctor`, `doctor --prerequisites`, `repair` |
| [Apps](reference/json/apps.md) | `app list`, `app focus`, `app update`, `app add` |
| [Lock, profiles and pull](reference/json/teams.md) | `lock check`, the `profile` commands, `pull` |
| [Run, operation handles, history and leases](reference/json/operations.md) | `run`, `op`, `history`, `notices`, `lease` |
| [State files, discovery, report, where and labs](reference/json/state-and-diagnostics.md) | `state.json`, `heartbeat`, `scan`, `report`, `where`, `labs` |
| [Share and lan-guard](reference/json/share.md) | `share`, `lan-guard` |
| [Ports and the Windows shim](reference/json/ports-and-windows.md) | `ports`, and what `benchbar.exe` adds |

A link to an old heading of this page, such as
`/json-schema/#benchbar-doctor---json`, still works: the page sends the
reader to the new page.

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
- Strings and numbers the CLI writes follow these rules (the shell helpers
  `fl_json_str`, `fl_json_text` and `fl_json_num`, tested by `tests/test-json-strings.sh`):
  - A string is valid UTF-8, always. A byte that is not part of a valid
    character (a stray byte in a log line, a character cut in half) is written
    as U+FFFD. The CLI cuts a long message at a character boundary, so the
    cut never makes one. Quote and backslash are escaped; newline, tab and
    carriage return are `\n`, `\t` and `\r`; any other control character is
    `\u00XX`; a terminal color code (ESC `[` ... final byte) is dropped whole.
  - An empty value is `null` for a field documented as `string or null` (the
    usual case: `site`, `stop_reason`, `message`, `command`). A field that
    can be an empty string on purpose is documented as a plain `string`, and
    the CLI writes `""` for it (`fl_json_text`). A reader treats `""` and
    `null` alike for "no value" and must not rely on either for a field the
    document does not name.
  - A number is a JSON integer, `-?(0|[1-9][0-9]*)`. A value that is not one
    (`1-2`, `--`, `007`, `1.5`, empty) is written as `null`, never as the
    text.
- A document is one line on stdout. A stream (`--jsonl`, or `--json` of a
  command that changes things) is many lines, one JSON object each, ending
  in the `done` line. Errors and warnings go to stderr as text. Exit codes: 0 success, 1 failure (for `doctor`: at least one
  check is `fail`; the JSON is still printed), 2 the MariaDB root password
  is unknown, 64 a command line the CLI cannot read (see "Usage errors"
  below). A missing bench exits 1 with a message on stderr and nothing on stdout.
- `status --json`, `list --json` and `doctor --json` are read only. They
  never start, stop or write anything, so they are safe to poll. The one
  exception is the one time move of the state folder on the first run
  after an upgrade (state.sh), which renames and links, and never copies
  or deletes.

### The `done` fields (0.8)

Every command that changes things ends with the same fields, once: in the
`done` line of its stream, or added to the one document it prints. A
command that only reads has `exit` and, on a failure, `error` (see
[the result envelope](#the-result-envelope-09)).

| field | meaning |
|---|---|
| `op_id` | (0.9) the run's handle, also on every `plan`, `step` and `progress` line; absent when the run ended before it started (a refusal) and in a dry run. See [operation handles](reference/json/operations.md#operation-handles-09) |
| `exit` | the exit code; the process exits with the same number, so a pipe cannot hide a failure |
| `changed[]` | what the run changed: `{"kind": "bench"\|"site"\|"app"\|"service"\|"ports"\|"hosts"\|"backup"\|"process"\|"state", "name", "detail"}`. Only what the run really changed: empty on a second run, and in a dry run. A step that failed after it began to change something is listed with a `detail` that starts with `partial:` (a clone that was not built, an `install-app` or `migrate` that failed). `install` reports the bench, the site and the apps its phase scripts create |
| `warnings[]` | the run's `[WARN]` lines, as text |
| `next_actions[]` | `{"command", "why"}`: the fix lines and next steps the text output prints. `"quoted": true` is added when the command was built with every word quoted for the shell (a program may split it); it is absent for a command written as text |
| `state_after` | the bench's `status --json` object after the run (no per site ping), `null` when there is no bench, in a dry run, or when the run touched several benches (`ports apply`). A stream's is read after the CLI's locks are released; a one document command's and `pull`'s while its lock is still held (a read, so nothing waits on it) |
| `missing[]` | only on a refusal of the non interactive mode: the inputs the command lacked (`ADMIN_PASSWORD`, `--yes`, `sudo`, `BENCHBAR_SUDO_PASSWORD`, ...) |
| `error_id` | only on a failure that has a stable id, for programs to match instead of the text. Every CLI done line can carry it. So far: `unknown_flag`, `missing_value` and `root_refused` (exit 64, see "Usage errors"), `sudo_password_wrong` (the password in `BENCHBAR_SUDO_PASSWORD` was refused, before any change). `password_has_newline` (a password in `ADMIN_PASSWORD`, `MARIADB_ROOT_PASSWORD` or `BENCHBAR_SUDO_PASSWORD` holds a line break; it travels on one line; refused before any change, only the variable's name is printed). `systemd_not_running` (Linux, `install` only: PID 1 is not systemd, and MariaDB, Redis and the bench service are systemd services; on WSL the fix names `[boot] systemd=true` in `/etc/wsl.conf`), `bench_on_windows_fs` (WSL, `install` and `adopt`: the bench folder is on the Windows file system, `/mnt/<drive>` or a drvfs or 9p mount; slow, no file watching, broken permissions; `--allow-windows-fs` accepts it), `linux_distro_unsupported` (Linux, `install` only: the system is not Ubuntu 24.04, the one the install is tested on, so apt would give another MariaDB and the install would stop after it had installed packages; the plan's `blockers[]` names it and nothing was changed; `--allow-unsupported-distro` or `BENCHBAR_ALLOW_UNSUPPORTED_DISTRO=1` tries anyway), `user_bus_unreachable` (Linux, `install` only: `systemctl --user` cannot reach the user manager, as under `sudo -iu`, `su -` or cron, and turning on lingering did not start it; in a dry run it is a warning in `warnings[]`; the run stops before it changes anything, with the fix `sudo loginctl enable-linger USER`, then a login shell or `XDG_RUNTIME_DIR=/run/user/UID`), `github_unreachable` (Linux, `install` only: `github.com`, which holds frappe and the uv Pythons, did not answer within 10 seconds, after one retry; the plan's `blockers[]` names it, nothing was changed) and `port_3306_in_use` and `port_6379_in_use` (Linux, `install` only: another program, or on WSL another distro, already listens on the MariaDB or the system Redis port; the plan's `blockers[]` names them, the done line has `exit` 1, the `fix` and the `error`, and nothing was changed, no sudo asked). Docker, a native MariaDB or a second WSL distro are the usual cause: WSL distros share one network, so only one of them can run MariaDB on port 3306. Stop it in the other distro (`sudo systemctl stop mariadb`) and run `install` again; benchbar never stops it. The Windows shim adds `distro_running`, see [Windows shim](reference/json/ports-and-windows.md#windows-shim) |

Which shape a command prints:

- A command that printed one document before keeps printing exactly that
  one line with `--json`. The ones that change things (`site backup`,
  `site drop`, `app add --apply`, `doctor --ack` and `--unack`) get the
  `done` fields added to it; a plan or dry run document gets none; the
  ones that only read (`site backups`, `ports plan`, the profile commands)
  have none of them. A run that fails prints nothing on stdout and a
  message on stderr, except the refusal of the non interactive mode, which
  is one document with `exit`, `error` and `missing`.
- `--jsonl` asks any command that changes things for the stream (`plan`,
  `step`, `progress`, `done`): the `done` line carries the same fields and
  the fields of the document the command would have printed (`site backup`,
  `site drop`, `app add`, `app update`). On a command that only reads,
  `--jsonl` is `--json`.
- `up`, `down`, `restart`, `service`, `site add`, `site default`,
  `app update` (without `--dry-run`) and `ports apply` had no JSON before
  and stream with plain `--json`, as `install`, `adopt`, `repair` and
  `pull` do. A dry run streams the `plan` line and the `done` line only.
- `--for-agent` is `--jsonl` for a command that changes things, `--json` for
  one that reads, plus `BENCHBAR_NONINTERACTIVE=1`, `NO_COLOR=1` and
  `--plain`.
- stdout carries JSON and nothing else under `--json` and `--jsonl`: the
  `[OK]`, `[WARN]` and `[FAIL]` lines and the step lines go to the run's
  log and stderr, a refusal included.
- `repair --json` keeps `exit_code` in its `done` and adds `exit` with the
  same value. `install`, `adopt` and `pull` add the fields to their `done`.
- Usage errors: an option the command does not take (`error_id`
  `unknown_flag`), or a flag that needs a value and has none (`missing_value`:
  `--bench-dir`, `--site`, `--profile`, `--bundle`, `--port-offset`, `--ack`,
  `--unack`) exits **64**, the
  `EX_USAGE` of `sysexits.h`, before the stream, the log, the lock or any
  change. Exit 2 keeps one meaning, "the MariaDB root password is unknown"
  (a program that sees 2 asks for that password), and 1 keeps "failure", so a
  caller that accepts only 0 and 1 reads a usage error as the failure it is.
  With `--json`, `--jsonl` or `--for-agent` stdout holds the answer on one line
  and stderr the text: for a command that changes things (or with `--jsonl`) a
  `done` event with `exit` 64, `error_id`, `error` (the option, named), `fix`
  (the command's usage line) and the shared done fields; for a command that
  reads one document with `schema_version`, `cli_version`, `exit`, `error_id`,
  `error` and `fix`. `BENCHBAR_LENIENT_FLAGS=1` turns an unknown option into a
  warning on stderr; it does not cover a missing value.
  The refusal to run as root (`error_id` `root_refused`, a distro whose default
  user is `root` gets it) has the same shape and the same exit 64, for the same
  reasons: a client that asked for JSON must get JSON, and 1 or 2 would be read
  as another failure.
- `BENCHBAR_NONINTERACTIVE=1` (set by `benchbar mcp` for every CLI it
  starts): nothing is ever asked. A command that needs an input it does
  not have (`ADMIN_PASSWORD`, `MARIADB_ROOT_PASSWORD` when benchbar has none
  stored, `--yes` for a confirmation, a `sudo` that would ask) names all of
  them in one error and exit 1 (exit 2 when the MariaDB root password is
  one of them), before it takes the lock, writes a log or touches a bench.
  In a stream that is a `done` with `exit`, an `error` and `missing`; under
  `--json` on a one document command, one document with the same fields.
  `repair --json` also ends with a `done` when it stops early (no bench, a lease,
  or more than one bench and none chosen).
- `benchbar commands --json` lists every command and subcommand with its
  flags, environment variables and what it needs (`tty`, `sudo`, `network`,
  `mutating`, `json`: `document`, `stream` or `none`); `benchbar COMMAND
  --help` prints that entry.

### The result envelope (0.9)

One shape ends every command that has a JSON mode (`commands --json`
lists them: `json` is `document` or `stream`), whatever the command and
however it ended. A program reads the last line of stdout and finds the
same fields; it never parses stderr text to learn how a run ended. The
fields of the [done line](#the-done-fields-08) are the envelope.

| field | type | present |
|---|---|---|
| `schema_version`, `cli_version` | number, string | always, first |
| `exit` | integer | always. The process exits with the same number: 0 done, 1 failed, 2 refused (the one input that cannot be guessed, or a lab that is off) |
| `error` | string | when `exit` is not 0: one sentence, the run's last `[FAIL]` line or the message of the refusal. A read that failed after it printed its findings (`doctor`, `lock check`) has the sentence "the command exited with 1" and its findings say what |
| `changed[]` | array of `{kind, name, detail}` | commands that change things. Empty on a second run and in a dry run |
| `warnings[]` | array of strings | commands that change things, and the failure document of a read |
| `next_actions[]` | array of `{command, why, quoted?}` | the same as `warnings[]` |
| `state_after` | object or `null` | commands that change things; `null` in a dry run, without a bench, or for several benches |
| `missing[]`, `error_id` | array of strings, string | only where a refusal or a stable failure has them (see the table above) |
| `event` | `"done"` | the last line of a stream. A document has none |

Which line carries it:

- **`--for-agent` and `--jsonl`** are the modes with the guarantee. A
  command that changes things ends its stream with one `done` line (a
  dry run: `plan`, then `done`). A command that only reads prints one
  document with `exit` added to its own fields. When a read fails before it
  has a document (no bench, an unknown name, a bad argument) it prints one
  document: `schema_version`, `cli_version`, `exit`, `error`, `warnings[]`
  and `next_actions[]`. A command or subcommand that does not exist ends
  with a `done` line too.
- **`--json`** keeps the documents of 0.8 as they were, so a polled
  `status --json` costs what it did. A command that changes things has the
  envelope. A read has no `exit` (the process exit code is the answer) and
  a read that fails prints nothing on stdout and text on stderr. Use
  `--for-agent` when a program wants the envelope for reads and failures.
- `ok` is not a field of the envelope and is never needed: `exit == 0` says
  it. It stays where it already was, on the results of `app add --apply`
  and `site restore --apply` (always `exit == 0`), so no reader breaks;
  `share preflight` has its own `ok` (the critical checks passed) beside
  `exit`. Do not add it to a new command.
- A command that changes things, run by an agent with more than one bench
  known and none chosen (no `--bench-dir`, `BENCH_DIR` or remembered bench),
  is refused before it does anything. The text on stderr says
  `Choose one: benchbar LINE --bench-dir PATH`; the envelope carries the same
  in `next_actions[]`, for a program that reads only stdout: one action for
  each of the first five benches the `error` names (LINE is the line that was
  typed, `--bench-dir` is that bench's real path, `"quoted": true`), then
  `benchbar list --json`, with its `why` saying how many benches there are
  when more than five. A `...` in LINE means a word was left out (it could be a
  secret); then no action holds the line, and only the list action is given:
  its `why` says to run the command again with the words that were typed and
  `--bench-dir`. The forms of `app focus NAME` and `doctor --ack|--unack`
  that write while their command reads are refused the same way; the read
  document of `--for-agent` and `--jsonl` has the actions. Plain `--json` of
  a read still prints nothing for a refusal. `repair` and `pull` have a
  stream of their own, which their command opens late; the dispatch now opens
  it before the gates, so every refusal that comes before the command (a
  lease held by another caller, the non interactive preflight, this gate)
  ends with their own `done` line in every mode, plain `--json` included
  (`repair` keeps `exit_code` beside `exit`; `pull` has `exit` and `site`,
  which is `null`). Until then they printed nothing on stdout for these
  refusals.

  ```json
  {"schema_version":1,"cli_version":"0.9.0","event":"done","bench":"/home/u/frappe-bench","exit":1,"changed":[],"warnings":[],"next_actions":[{"command":"benchbar app unfocus frappe --for-agent --bench-dir /home/u/frappe-bench","why":"Run it on this bench","quoted":true},{"command":"benchbar app unfocus frappe --for-agent --bench-dir /home/u/dev/frappe-bench","why":"Run it on this bench","quoted":true},{"command":"benchbar list --json","why":"See the known benches","quoted":true}],"state_after":null,"log":null,"error":"More than one bench is possible and none was chosen: /home/u/frappe-bench, /home/u/dev/frappe-bench."}
  ```
- A refusal of the non interactive mode, a usage error and a failure
  before the command could start (`No bench at ...`) all end with this
  envelope. A distinct exit code for usage errors is not used yet: a usage
  error exits 1 with `error` saying what to fix.
- The MCP server returns the same fields in `structuredContent` of every
  tool that ran the CLI: `exit` (the CLI's exit code) in every result,
  `error` when it is not 0, and for an action tool `changed`, `warnings` and
  `next_actions` copied from the `done` line next to `result`. `exit_code`
  stays for readers of the first release. A tool error the server raises
  itself carries `exit` and `error` too: an invalid argument, a bench that is
  not known, a plan that is missing or stale, and a plan the person did not
  approve are `exit` 1; a call that ran out of time is 124 and a benchbar
  that could not be started is 127.
- A command with no JSON mode (`fg`, `watch`, `console`, `db`, `docs`,
  `mcp`, `help`, `mariadb-password`, `path` and the groups `site`, `app`,
  `ports`, `lock`, `profile`, `share`) has no envelope: they are terminals,
  a text helper or a usage page. `tests/test-envelope.sh` lists them, so a
  new command has to choose.

## States

| `state` | Meaning | `stop_reason` |
|---|---|---|
| `stopped` | not running | `manual` after `benchdown`, `null` otherwise (never started, logout or restart in progress) |
| `starting` | processes are up, the site does not answer yet | `null` |
| `running` | processes are up and the site answers HTTP | `null` |
| `crashed` | honcho exited with an error; launchd retries after 20 seconds | `crash` |
| `not_adopted` | (0.8) a folder that is a bench, with no benchbar service and not remembered (not the default bench, no state of its own, not registered), and nothing running. `site` and `web_url` are `null`: the site of the default bench is never named for it. `benchbar adopt PATH` or `register` changes it | `null` |
| `paused` | auto-restart is off until `benchup` | `crash` (the crash guard tripped: 3 starts in 10 minutes), `broken` (honcho or the env is missing, or the runner cannot write the crash history or the stop flag: run `benchbar repair` or `benchbar doctor`) or `port_conflict` (another process held the bench's ports when the runner started; it was not this bench's to stop: run `benchbar doctor`) |

`stop_reason` can be `manual`, `crash`, `broken`, `port_conflict` or
`null`. `broken` and `port_conflict` are additions to the original
`manual | crash | null` contract: they tell a reader that `repair` or
`doctor` is needed, not just `benchup`.

How `status` decides (live facts win over the state file):

1. Processes of this bench are running: `running` when the site answers
   any HTTP code, otherwise `starting`. A bench started by hand with
   `benchfg` counts as running. While the runner's `state.json` says
   `running` or `starting` and launchd runs that very pid, that is the
   answer; otherwise one process scan looks for this bench's honcho,
   serve, worker, schedule and socketio (0.6.1: port listeners alone no
   longer count, a leftover Redis is not a running bench).
2. The stop flag `logs/.bench-stopped` says `manual`: `stopped`.
3. It says `crash`: `paused` with `crash`. `port_conflict`: `paused` with `port_conflict`. Anything else: `paused` with `broken`.
4. `state.json` says `crashed`: `crashed` (launchd is about to retry).
5. Otherwise `stopped` with `stop_reason: null`.
