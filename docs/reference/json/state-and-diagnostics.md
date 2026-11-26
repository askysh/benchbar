---
title: "JSON: state files, discovery, report, where and labs"
description: "The state file and heartbeat the runner writes, the folder discovery documents, and the JSON of report, where and labs."
---

The files the runner writes into a bench, and the documents of the commands that describe this installation. The [rules for readers](../../json-schema.md#rules-for-readers) apply to all of them.

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

## `benchbar where --json`

How this CLI was installed and where its things are, since 0.7.0. Read
only: it needs no bench, takes no lock and writes no log. Scripts, agents
and the app can use it to tell a Homebrew install from the others instead
of guessing from paths.

```json
{"schema_version":1,"cli_version":"0.7.2","install":"app","self":"/Users/you/.local/state/benchbar/bin/benchbar","state_dir":"/Users/you/.local/state/benchbar","state_dir_real":"/Users/you/.local/state/benchbar","app_version":"0.7.2","app_path":"/Applications/BenchBar.app","handoff_from":"/opt/homebrew/opt/benchbar/bin/benchbar","handoff_from_version":"0.7.2"}
```

| Field | Type | Meaning |
|---|---|---|
| `install` | string | `homebrew` (the `benchbar` formula), `managed` (the one line installer's checkout, `~/.local/share/benchbar`), `app` (the CLI inside BenchBar.app, 0.7.1), `checkout` (another git clone, such as `./benchbar` in the repo) or `other`. Treat a value you do not know as `other` |
| `self` | string | the path of this CLI that the helper block, the `~/.local/bin` links and every printed fix command use. Under Homebrew it is `<prefix>/opt/benchbar/bin/benchbar`, which `brew upgrade` keeps; never a versioned Cellar path. For `app` it is `~/.local/state/benchbar/bin/benchbar`, the link the app keeps to its CLI, or the CLI's own path in an app that is not installed (a build from Xcode) |
| `state_dir` | string | the folder of the remembered benches, per bench settings, run logs, backups and the lock: `~/.local/state/benchbar` for `homebrew`, `managed` and `app` (a symlink to `~/.local/share/benchbar/.benchbar` when the two are on different volumes), `.benchbar` next to the CLI for the others, or `FL_STATE_DIR` when that is set |
| `state_dir_real` | string | the folder behind `state_dir`, with every link resolved (0.7.3). The same as `state_dir` unless `~/.local/state/benchbar` is a link to the installer checkout's `.benchbar` on another volume; the human output then shows `state LINK -> REAL` |
| `app_version` | string or null | the BenchBar app's version, `null` when no app is installed |
| `app_path` | string or null | for `app`, the app this CLI is part of; otherwise the app it found first, `/Applications` before `~/Applications`; `null` when none |
| `handoff_from` | string or null | the Homebrew or installer CLI that was run and handed off to this one (0.7.1), `null` when this CLI was run directly |
| `handoff_from_version` | string or null | the version of that copy (0.7.3), `null` when this CLI was run directly or that copy's version is unknown. A copy newer than `cli_version` hands off to an older CLI: update the app (doctor's `cli_duplicate` says so) |

Exit 0. An argument other than `--json` exits 1.

## `benchbar labs --json`

`labs list --json` is one document, with no done fields:

```json
{"schema_version":1,"labs":[{"name":"lan-rooms","title":"...","description":"...","warning":"...","since":"0.8.2","enabled":false,"commands":["share","lan-guard"],"platforms":["macos"],"available":false}]}
```

`commands` are the top level commands the lab gates (it may be empty, or name
a command this version does not have). `platforms` is the list the lab runs
on (`macos`, `linux`, `windows`) and `available` is true when this machine is
one of them (WSL counts as `windows` and also runs a `linux` lab). `labs on`
exits 1 with "NAME is not available on PLATFORM yet" when it is not. `labs status NAME --json` is
`{"schema_version":1,"name":"lan-rooms","enabled":false}` and exits 1 when off.
`labs on` and `labs off` stream like `site open-as`: the `done` line carries
`lab`, `enabled` and the [done fields](../../json-schema.md#the-done-fields-08). `labs on` exits 2
with `error` "turning on an experiment is a person's decision" when nothing
can ask. Added after 0.8.1: `status --json` and `commands --json` have `labs`
(the enabled names); `commands --json` also has `gated` (`[{"name","lab"}]`
for a command left out because its lab is off) and a command of an enabled lab
has `lab`.

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
| `updated_at` | string | when this transition was written; it does not move between transitions (the heartbeat is its own file, below) |
| `source` | string | `runner` (the launchd runner) or `cli` (`up`, `down`, `restart`) |

`cli_version` is the version of the benchbar that wrote the transition:
for `source: runner`, the one that wrote the runner script. Since 0.7.0 a
new CLI version alone no longer rewrites the runner (doctor does not count
it as outdated), so this can be older than `benchbar --version`.

Transitions the runner writes:

| When | `state` | `stop_reason` |
|---|---|---|
| the agent starts while a stop flag exists | `stopped` or `paused` | from the flag |
| honcho or `env/bin/python` is missing | `paused` | `broken` |
| the runner cannot write the crash history or the stop flag | `paused` | `broken` |
| the crash guard trips | `paused` | `crash` |
| a process that is not this bench's still holds one of its ports after the cleanup | `paused` | `port_conflict` |
| honcho started | `starting` | `null` |
| the site answered 200 (checked every 2 seconds for 4 minutes) | `running` | `null` |
| the runner got SIGTERM without a stop flag (logout, restart, shutdown) | `stopped` | `null` |
| honcho exited 0 without a stop flag (0.7.3: a bench never ends on its own, so launchd restarts it) | `crashed` | `crash` |
| `benchdown` stopped it | `stopped` | `manual` |
| honcho exited with an error | `crashed` | `crash` |

The CLI writes `starting` just before `up` and `restart` kick the agent,
and `stopped` with `manual` after `down`. The state file is a hint for
fast updates; `status --json` is the truth, because it also checks the
processes and the site.

## `logs/.benchbar/heartbeat`

Since 0.6.1 the runner rewrites this file every 30 seconds while honcho
runs, starting just before it writes `starting`. The write is in place
(no temp file, no rename), so it changes no entry of the folder and a
folder watcher is not woken by it; only the transitions in `state.json`
are. The content is the runner's age in seconds, one line; read the
file's modification time, not the content. The file stays after the
runner stops.

How a reader uses it, while `state.json` says `running` or `starting`:

| The runner's `pid` | `heartbeat` mtime | Meaning |
|---|---|---|
| alive | under 90 seconds old | fresh: `state.json` is the truth, no need to ask the CLI |
| alive | missing, 90 seconds or older, or dated more than 5 seconds in the future (a clock moved back; a beating runner rewrites it within 30 seconds) | a runner from before 0.6.1 (or one that hangs): ask `status --json`; `benchbar restart` gives the bench a runner that beats |
| dead | any | the runner is gone without writing its last state: ask `status --json` |

`benchbar doctor` reads the same file (check `runner_heartbeat`).

## Folder discovery

`benchbar scan PATH --json` is read only and returns a schema-version-1 object:
`schema_version`, `cli_version`, `root` (canonical selected folder), `benches`
(the same entries as `list`), and `warnings` (strings for skipped unreadable
folders). A valid folder with no benches returns an empty array; an invalid or
unreadable root exits 1. Hidden directories, symlinks, dependency/build folders,
and test/fixture folders are skipped. A found bench's children are not scanned.

`benchbar register PATH ... --json` validates every path, atomically remembers
the canonical paths in `registered-benches.txt` in the state folder, then returns the
normal `list` response. It does not create services or change the default bench.
`--dry-run` does not write the registry. List includes these registered paths
while they still identify bench directories. Registration is idempotent.

Same-named benches receive distinct launchd labels when necessary, using a
canonical-path checksum suffix. An installed label owned by the same bench
is retained. Clients should always use the returned label rather than deriving
it from the directory name.
