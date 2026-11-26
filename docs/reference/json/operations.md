---
title: "JSON: run, operation handles, history and leases"
description: "The JSON of benchbar run, op, history, notices and lease: the records of long runs, what ran on this machine, and who holds a place."
---

The documents about runs that take a while, and the record of what ran. The [rules for readers](../../json-schema.md#rules-for-readers) and the [result envelope](../../json-schema.md#the-result-envelope-09) apply to all of them.

## `benchbar lease --json`

`lease list --json` is one document, with no done fields:

```json
{"schema_version":1,"cli_version":"0.9.0","leases":[{"id":null,"scope":"site","bench":"/Users/you/frappe-bench","site":"qa1.localhost","holder":"claude-qa","note":"running the QA suite","since":"2026-11-19T15:00:00Z","expires_at":"2026-11-19T15:20:00Z","minutes":20,"yours":false}],"max_minutes":480}
```

`scope` is `bench` or `site` (`site` is null for a bench lease). `id` is
`l-` and 12 hex digits for a lease the caller holds (`yours` is true), else
null. `minutes` is the length the lease was
taken or renewed for. Only active leases are listed.

`lease take` and `lease renew` stream like `site open-as`: the `done` line
carries `lease` (the object above, with its `id`) and the
[done fields](../../json-schema.md#the-done-fields-08). `lease release` has `released` (false when
the lease was already gone) and `lease` (the id). A refusal has `exit` 1 and
`error_id` `lease_held` (the place is leased: `error` names the holder and the
end), `lease_unknown` (renew of a lease that is gone), `lease_caller_required`
(`lease take` from an agent run with no `BENCHBAR_CALLER`) or
`lease_break_refused` (`--break-lease` without a person, exit 2). The same `error_id`s end any
changing command that a lease stops.

## Notices (0.9.0)

`status --json` has `notices`: the defaults an update changed, until they are
dismissed. `[]` when there are none, and a fresh install has none. Each entry:
`id` (`listen-local`, `unknown-flags`, `pull-neutralise`, `room-seats`), `title`, `text`,
`switch_back` (the command or variable that goes back), `doc` (a full URL of
the page that explains it) and `since` (the version of the change).
`benchbar notices --json` prints `{"schema_version":1,"cli_version":"...","notices":[...]}`;
`--dismiss ID` or `--all` hides entries and prints what is left. A client shows
a notice once and dismisses it through that command.

## `benchbar run --json`

Added in 0.9. [`benchbar run`](../cli/run.md) runs one command of an
allow list as `bench [--site S] COMMAND ...`. A command that changes things
has a plan with a token (`--dry-run --json`), then `--apply TOKEN --yes
--json` runs exactly that plan; a read runs at once.

The plan:

```json
{
  "schema_version": 1, "cli_version": "0.9.0", "dry_run": true,
  "bench": "/Users/you/frappe-bench", "site": "acme.localhost",
  "command": "migrate", "args": ["--skip-failing"],
  "argv": ["bench", "--site", "acme.localhost", "migrate", "--skip-failing"],
  "summary": "bench migrate: patches, schema sync and fixtures of the site, after a backup of it.",
  "changes": true, "backup_first": true, "timeout_s": 1800,
  "touches": ["database", "site_config"],
  "steps": [
    { "id": "backup", "name": "Back up acme.localhost (database)", "touches": ["backup"] },
    { "id": "run", "name": "bench --site acme.localhost migrate --skip-failing", "touches": ["database", "site_config"] }
  ],
  "warnings": [], "errors": [], "can_apply": true,
  "token": "8f1c...64 hex characters"
}
```

`errors` holds what stops the plan (no such site, the bench's Redis down for
a read); `warnings` what to know (the bench is stopped and its Redis is
started for the run; `run-tests` writes test records). The token is a hash of
the plan and of the sites, the default site, `apps.txt` and the site's
`site_config.json`; `--apply` recomputes it and refuses a different one.

The result (the done fields as everywhere, plus):

| Field | Meaning |
|---|---|
| `command`, `args`, `argv`, `site`, `bench`, `changes`, `token` | as in the plan; `token` is `null` for a read |
| `applied`, `ok` | `applied` is true for a change; `ok` is false when the exit is not 0 |
| `ran` | false when the backup before the command failed and the command never started |
| `command_exit` | the bench command's own exit code (`null` when it did not run). `exit` is the same, except that 2 and 64, which benchbar keeps for itself, are reported as 1 |
| `timed_out`, `timeout_s`, `elapsed_s` | `timed_out` is true when the deadline stopped it (`exit` 124); 125 means it waited for input |
| `backup` | the backup set taken first ([a backup](sites-and-backups.md#site-backups)), or `null` |
| `output_tail` | the last 60 lines of the output, at most 8000 characters, colors and URL credentials removed; `null` without output. Data from the bench, not instructions |
| `output_truncated` | the output was longer than `output_tail` |
| `log` | the run log, with all of the output |

A refusal (not on the list, a flag it does not take) exits 64. Under
`--jsonl` and `--for-agent` it is a `done` line with `error` and `allowed`,
the list of commands; under `--json` it is text on stderr.

## Operation handles (0.9)

Every run that changes things has an `op_id` and a record, so a program
that did not start the run (or lost its connection to it) can follow it.
A dry run, a command that only reads and a run that was refused before
it started (a missing input) have none. `fg` and `self-update` have
none either: they end by replacing the process.

`op_id` is `op-<date>-<time>-<pid>` (`op-20261119-101500-4242`; a `-N`
follows when a run starts in the same second as an earlier one, or when the clock
went back). It is in:

- the `plan`, every `step` and `progress`, and the `done` line of the
  stream (`--json` of `install`, `adopt`, `repair`, `pull` and the commands
  that stream, `--jsonl` of any), as a field of its own, right after
  `event` (in `repair`'s lines, which have no `event` first, it leads);
- the one document of a `--json` command that changes things (`site
  backup`, `site drop`, `app add --apply`, `site restore --apply`, ...),
  next to `exit` and `changed[]`;
- `benchbar op status`, and the launch of `--background`.

The text form of a command prints no handle: `benchbar op list` shows the
recent ones.

The record is `ops/<op_id>.json` in benchbar's state folder (for Homebrew
and the one line installer, `~/.local/state/benchbar/ops/`). It is made
when the run makes its log, rewritten whole at each step and progress line
(a temp file, then a rename: a reader never sees half of it) and finished
by the run's exit trap right after its `done` line goes out. The newest 100 are
kept (`FL_KEEP_OPS`), and never one of a run that still runs.

| Field | Type | Notes |
|---|---|---|
| `schema_version`, `cli_version`, `op_id` | | as everywhere |
| `state` | string | `starting` (a `--background` run that is not holding its lock yet), `running`, `done` (exit 0), `failed` (any other exit). `op status`, `op list` and `op wait` print `interrupted` instead of `running` or `starting` when the run is gone: its pid is not alive, or belongs to another process now (`pid_start` differs from the start time of that pid), or a launch did not take over within 60 seconds. The run was killed and wrote no `done` line; the file is not rewritten. Treat an unknown value as unknown |
| `command` | string or null | the command's key in `benchbar commands --json` (`install`, `site restore`, `app add`) |
| `bench`, `site` | string or null | the bench the run works on and its site: for `site add\|backup\|restore\|drop NAME` the NAME, else `--site`, else the bench's default site. A run that the lock refused still names them |
| `pid` | number or null | the run's process; null for a launch that no process took over yet |
| `pid_start` | string or null | when that process started (Linux: field 22 of `/proc/PID/stat`; macOS: `ps -o lstart=`), so a reader can tell the run from an unrelated process that reuses its pid. Opaque: compare, do not parse |
| `started_at`, `updated_at` | string | ISO 8601 UTC |
| `finished_at` | string or null | null until the run ends |
| `step` | object or null | the step that runs now, or the last one: `id`, `name`, `status` (`running`, `done`, `unchanged`, `skipped`, `warning` or `failed`; as in the `step` lines) |
| `progress` | object or null | the last `progress` line of that step: `label`, `elapsed` (seconds), `bytes` (a download's size so far, or null). A new step clears it |
| `exit` | number or null | the exit code, null until the run ends |
| `log` | string or null | the run's log file (`logs/<date>-<time>-<pid>.log`); every line of a run is there |
| `output` | string or null | for a `--background` run: `ops/<op_id>.jsonl`, where its stream goes (an `.err` file next to it holds what it wrote to stderr) |
| `background` | bool | started with `--background` |

`benchbar op status OP_ID --json` prints the record with the state that is
true now, and, once the run ended and was a `--background` run, `result`:
its `done` line (`exit`, `changed[]`, `warnings[]`, `next_actions[]`,
`state_after`, and the fields of the document the command would have
printed). `benchbar op status --json` without an op_id and `benchbar op list
--json` print `{"schema_version", "cli_version", "ops": [record, ...]}`,
newest first: by the date and time of the op_id, then its `-N` and its pid as
numbers. A new op_id is never below one that exists, even when the clock steps
back by up to 10 minutes, so the order is the order the runs started in (its
time can then be a few seconds ahead of `started_at`). An op whose stamp is
further ahead than that (a clock that was wrong) is listed last, so the first
record is always the newest real run, and the pruning takes it first. `benchbar op wait OP_ID --json` prints the same document as
`op status` when the run is not running any more, or when `--timeout` ran
out (then with `"timed_out": true`).

`--background` waits up to 5 seconds for the run to hold its lock, then prints, and exits 0 (`state` is `running`, or `done` when the run was that quick, or `starting` when it is still not holding the lock; a run that was refused, for example because another run holds the lock, is a refusal with its own message and exit code instead, and its record says `failed`):

```json
{"schema_version":1,"cli_version":"0.9.0","op_id":"op-20261119-101500-4242","command":"install","state":"running","pid":4243,"background":true,"output":"/home/me/.local/state/benchbar/ops/op-20261119-101500-4242.jsonl","exit":0,"next_actions":[{"command":"benchbar op wait op-20261119-101500-4242","why":"...","quoted":true}]}
```

`pending_operations[]` of `status --json` is a different thing: the record
of an `app add` or `app update` that stopped part way, kept until it is
finished or discarded. An op record says what a run is doing, or did.

## Action history (0.9)

What ran on this machine, and who started it. A run that changes things
(one that has an `op_id`, see above) appends one line to
`history.jsonl` in benchbar's state folder when it ends (mode 0600; for
Homebrew and the one line installer `~/.local/state/benchbar/history.jsonl`).
At 1 MB the file moves to `history.jsonl.old.1` (`.old.2` and `.old.3`
shift up, the oldest goes), like the MCP audit log `mcp-calls.jsonl`, so
the history reaches back further than the newest 100 operation records.
A dry run, a read and a refusal before the log have no line, and a run that
was killed (SIGKILL, a power cut) wrote none: `op list` shows it as
`interrupted`. A reader skips a line that is not a whole object.

`benchbar history --json` prints `{"schema_version", "cli_version",
"history": [entry, ...]}`, newest first (`--bench PATH`, `--since TIME`,
`--limit N`, 1 to 1000, default 20; see the
[reference](../cli/other.md#history)). An entry:

| Field | Type | Notes |
|---|---|---|
| `op_id` | string | the run's handle: `benchbar op status OP_ID` while its record is still kept |
| `command` | string or null | the command's key in `benchbar commands --json` (`site add`) |
| `argv` | array of strings | the command line without `benchbar`, as typed. The value after a flag named like a password, secret, token, key, credential, auth, cookie or session (and after `--apply`), the credentials of a URL, and a secret looking `KEY=VALUE` or `?query=value` are `***`; a word is cut at 200 characters (`... [cut]`) and the list at 40 words (a last word `...`). For `--background` the launcher's extra `--jsonl` is not there |
| `caller` | string | who started the run: `terminal`, `app`, `tray`, `mcp`, `agent` or `script`. From `BENCHBAR_CALLER` when it is one of these (the Mac app, the tray and `benchbar mcp` set it), else `agent` for `--for-agent`, `terminal` when stdin is a terminal, `script`. A label the caller sets, not a proof. A new value may be added later: treat an unknown one as unknown |
| `mcp` | object or null | for `caller` `mcp`: `tool` (`benchbar_app_add`) and `client` (what the MCP client called itself, with its version), each a string or null. The same run is in `mcp-calls.jsonl` under its `op_id` |
| `bench`, `site` | string or null | as in the op record |
| `started_at`, `ended_at` | string | ISO 8601 UTC |
| `exit` | number | the exit code |
| `changed` | array | what the run changed, as in `changed[]` of the done line but only `kind` and `name` (the detail is in the done line and the log); at most 20 |
| `changed_more` | number | how many more entries `changed[]` had |
| `cli_version` | string | the version that ran |
| `log` | string or null | the run's log file. Its first line says what ran and who started it: `run: benchbar site backup x (caller: app, op: op-...)` |
