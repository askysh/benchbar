---
title: "JSON: install, adopt, doctor and repair"
description: "The JSON lines of benchbar install and adopt, the doctor report, the repair events and the prerequisites check."
---

The documents of the commands that create a bench and check or fix it. The [rules for readers](../../json-schema.md#rules-for-readers) and the [done fields](../../json-schema.md#the-done-fields-08) apply to all of them.

## `benchbar doctor --json`

```json
{
  "schema_version": 1,
  "cli_version": "0.3.0",
  "bench": "/Users/you/frappe-bench",
  "name": "frappe-bench",
  "site": "macdev",
  "profile": "v15-lts",
  "profile_source": "stored",
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
| `profile_source` | string | added in 0.7.3: where `profile` came from, `flag` (`--profile`), `team`, `stored` (remembered for the bench), `detected` (from the bench's Frappe) or `default` (no profile matches this bench; the env checks warn instead of offering a rebuild) |
| `checks[].id` | string | stable id, for example `env_python`, `assets`, `agent`, `legacy_agents`. 0.7.3 adds `env_setuptools` (group `bench`, action `env_setuptools`), `formula_dates` (group `system`, no action) and `bench_path` (group `service`, no action). `pdf_engine` replaced `wkhtmltopdf` in 0.4. 0.5 adds `apps_txt`, `app_branch_policy`, `lock_parse` and `lock_drift` (group `bench`, no repair action). 0.6 adds `dependency_behind`, `apps_behind` and `profile_outdated` (group `bench`, no repair action); `dependency_behind` is the one id that can appear several times, once per stale dependency. 0.7 adds `app_copies` (group `system`) and `cli_duplicate` (group `service`), both without a repair action, and `helpers` can be `fail` (the block's benchbar is gone) |
| `checks[].group` | string | `system`, `bench`, `service` or `site` |
| `checks[].label` | string | short name for humans |
| `checks[].level` | string | `ok`, `warn` or `fail` |
| `checks[].message` | string | one line for humans |
| `checks[].fix_command` | string or null | the exact command a human would run; `null` when nothing needs doing |
| `checks[].fix_quoted` | boolean | `true` when the code that built `fix_command` quoted every word for the shell and it is one plain command (optionally after `cd DIR &&`), so a program may split it; `false` for a fix written as text. Also on `prerequisites[]` |
| `checks[].action` | string or null | the `repair` action that fixes it, when `repair` can |
| `summary` | object | counts per level |

`status` and `fix` are the 0.2.0 names of `level` and `fix_command` (with
`""` instead of `null`), kept for older readers.

Since 0.8: every check has `"acked"`, and the document has `"acked": [ids]`,
`"quick"` and `"skipped_checks": [ids]`.

- `doctor --ack CHECK` silences one named `warn` for this bench: it is
  recorded in the bench's state file with the message it acknowledged, and
  lapses when the message changes. A `fail` cannot be acknowledged. The
  check stays in the JSON at level `warn` with `"acked": true`; the text
  output prints one dim `acked:` line instead of the `[WARN]` and its fix
  line, and `--fix-hints` leaves it out. `doctor --unack CHECK` undoes it.
  These two write one line to the state file under the CLI lock; `doctor`
  itself still writes nothing. Under `--json` they print one small
  document: `action` (`ack` or `unack`), `check`, `acked` (every id with a
  stored acknowledgement) and the done fields. An acknowledgement does not
  make a `not_adopted` bench look adopted. `repair` does not look at
  acknowledgements.
- `doctor --quick` leaves out the slow checks (those that start brew,
  python, node, bench or git, or ask the site) and says which:
  `"quick": true` and the ids in `skipped_checks`.

## `benchbar repair --json`

Since 0.8 its `done` also carries `exit` (the same number as `exit_code`) and the [done fields](../../json-schema.md#the-done-fields-08).

A stream: one JSON object per line on stdout, as the run goes. The human
text goes to the run's log, `logs/<date>-<time>-<pid>.log` in benchbar's state
folder: `~/.local/state/benchbar` for the one line installer and
Homebrew since 0.7.0, `.benchbar/` in a git checkout.

```json
{"event":"plan","schema_version":1,"cli_version":"0.5.0","bench":"/Users/you/frappe-bench","dry_run":false,"actions":[{"id":"build","label":"bench build","fixes":["Built assets"],"sudo":false},{"id":"hosts_entry","label":"add macdev to /etc/hosts (sudo)","fixes":["/etc/hosts entry"],"sudo":true}],"backups":"/Users/you/.local/state/benchbar/backups","log":"/Users/you/.local/state/benchbar/logs/20260926-101500-4242.log"}
{"event":"step","action":"build","status":"running","message":"bench build"}
{"event":"step","action":"build","status":"done","message":"bench build"}
{"event":"step","action":"hosts_entry","status":"running","message":"add macdev to /etc/hosts (sudo)"}
{"event":"step","action":"hosts_entry","status":"skipped","message":"[WARN] skipped without sudo; run: benchbar repair --bench-dir /Users/you/frappe-bench   (adds '127.0.0.1 macdev' inside the benchbar block)"}
{"event":"done","exit_code":0,"log":"/Users/you/.local/state/benchbar/logs/20260926-101500-4242.log"}
```

| Event | Fields |
|---|---|
| `plan` | `actions[]` with `id` (a repair action), `label`, `fixes` (the doctor checks it fixes), `sudo` (needs a password: skipped without a terminal, or asked for in a macOS dialog under `BENCHBAR_SUDO=gui`, see [the privileged steps](#the-privileged-steps-and-benchbar_sudogui)); `dry_run`; `token` (since 0.9, only when there is something to do; see below); `backups` (the backup root); `log` |
| `step` | `action`, `status` (`running`, then `done`, `skipped` or `failed`), `message` (for `failed` and `skipped`, the CLI's `[FAIL]` or `[WARN]` line) |
| `done` | `exit_code` (0 when every check passes afterwards), `log` |

`repair --dry-run --json` prints only the `plan` line and changes
nothing. Without `--yes` (and without `--dry-run`) nothing is applied:
the plan is printed, then `done` with exit code 1, because the question
cannot be answered. An empty `actions` means nothing needs repairing.

Since 0.9 the `plan` line has a `token`: a keyed, timed hash of the bench, the
site, the profile and the actions the run would take. `repair --apply TOKEN
--yes` makes the plan again and ends with exit 1 and a `done` that says `The
repair plan changed since it was shown` (or `The plan token expired`) before
any step, when it is not the same. A plan with nothing to do has no token. A
run without `--apply` is as before.
## `benchbar install --json`

Since 0.8 the `done` line also carries `changed`, `warnings`, `next_actions` and `state_after` ([done fields](../../json-schema.md#the-done-fields-08)); `adopt` the same.

Added in 0.8. A stream, like `pull --json`: one JSON object per line on
stdout as the run goes, the human text in the run's log
(`logs/<date>-<time>-<pid>.log` in benchbar's state folder). Every line
carries `schema_version`, `cli_version` and `event`. The BenchBar app's
New Bench page reads it.

Since 0.9 the `plan` line has a `token`, a keyed, timed hash of the plan's steps
and of the inputs that decide them (the bench, the site, the profile, the
bundle, the pins, the port block and the blockers). `install --apply TOKEN --yes`
with the same flags makes the plan again and ends with exit 1 and a `done` that
says `The install plan changed since it was shown` (or `The plan token expired`)
before any dialog or step, when it is not the same. A run without `--apply` is
as before.

The stream is only valid with `--yes` (or with `--dry-run`): no question
can be answered on it, so `install --json` without either prints one
`done` line with `exit` 1 and an `error`, and changes nothing. Every value
`install` would ask for comes as a flag or from the environment:
`--bench-dir`, `--profile`, `--bundle`, `--site`, `--port-offset`,
`ADMIN_PASSWORD` (the new site's Administrator password; required unless
the site exists) and the optional `MARIADB_ROOT_PASSWORD`. A missing
`ADMIN_PASSWORD` is refused the same way, before anything runs. stdin is
never read.

The stream never prompts for a password. Without `BENCHBAR_SUDO=gui`, a
cached `sudo` credential or a `NOPASSWD` rule is used (`sudo -n true`);
otherwise the privileged steps are `skipped` with their `command`, exactly
like a cancelled dialog (see [the privileged steps](#the-privileged-steps-and-benchbar_sudogui)). On Linux the apt step of phase 00 cannot be skipped: without a
cached credential the stream ends with `done` and `exit` 1, saying sudo
is needed.

```json
{"schema_version":1,"cli_version":"0.8.0","event":"plan","bench":"/Users/you/frappe-bench","site":"macdev","profile":"v15-lts","team_profile":null,"bundle":"minimal","port_offset":0,"web_url":"http://macdev:8000","dry_run":false,"sudo_mode":"gui","steps":[{"n":null,"id":"wkhtmltopdf_install","name":"Install the patched wkhtmltopdf package","sudo":true,"will_run":true},{"n":null,"id":"hosts_entry","name":"Add 127.0.0.1 macdev to /etc/hosts","sudo":true,"will_run":true},{"n":1,"id":"system_deps","name":"System dependencies (00-mac-system-deps.sh)","sudo":false,"will_run":true},{"n":2,"id":"bench_site","name":"Bench and site (01-install-bench-and-site.sh)","sudo":false,"will_run":true},{"n":3,"id":"service","name":"Background service","sudo":false,"will_run":true}],"log":"/Users/you/.local/state/benchbar/logs/20261010-101500-4242.log"}
{"schema_version":1,"cli_version":"0.8.0","event":"step","n":null,"id":"wkhtmltopdf_install","parent":null,"name":"Install the patched wkhtmltopdf package","status":"running"}
{"schema_version":1,"cli_version":"0.8.0","event":"progress","step":"wkhtmltopdf_install","label":"download wkhtmltopdf 0.12.6-2 (about 50 MB)","elapsed":10,"bytes":31457280,"total":null}
{"schema_version":1,"cli_version":"0.8.0","event":"step","n":null,"id":"wkhtmltopdf_install","parent":null,"name":"Install the patched wkhtmltopdf package","status":"done","secs":41}
{"schema_version":1,"cli_version":"0.8.0","event":"step","n":null,"id":"hosts_entry","parent":null,"name":"Add 127.0.0.1 macdev to /etc/hosts","status":"running"}
{"schema_version":1,"cli_version":"0.8.0","event":"step","n":null,"id":"hosts_entry","parent":null,"name":"Add 127.0.0.1 macdev to /etc/hosts","status":"skipped","secs":6,"message":"[WARN] the password dialog was cancelled; the line was not added","command":"benchbar site hosts --bench-dir /Users/you/frappe-bench"}
{"schema_version":1,"cli_version":"0.8.0","event":"step","n":1,"id":"system_deps","parent":null,"name":"System dependencies (00-mac-system-deps.sh)","status":"running"}
{"schema_version":1,"cli_version":"0.8.0","event":"step","n":null,"id":"python","parent":"system_deps","name":"PYTHON","status":"running"}
{"schema_version":1,"cli_version":"0.8.0","event":"step","n":null,"id":"python","parent":"system_deps","name":"PYTHON","status":"done","secs":3}
{"schema_version":1,"cli_version":"0.8.0","event":"step","n":1,"id":"system_deps","parent":null,"name":"System dependencies (00-mac-system-deps.sh)","status":"done","secs":95}
{"schema_version":1,"cli_version":"0.8.0","event":"done","exit":0,"bench":"/Users/you/frappe-bench","site":"macdev","url":"http://macdev:8000","skipped":[{"id":"hosts_entry","command":"benchbar site hosts --bench-dir /Users/you/frappe-bench"}],"fix":null,"log":"/Users/you/.local/state/benchbar/logs/20261010-101500-4242.log"}
```

| Event | Fields | Notes |
|---|---|---|
| `plan` | `bench`, `site`, `profile` (the built in profile it runs on), `team_profile` (string or null), `bundle`, `port_offset` (the port block the bench gets), `web_url`, `dry_run`, `sudo_mode` (`terminal`, or `gui` under `BENCHBAR_SUDO=gui`), `steps[]`, `blockers[]`, `warnings[]`, `log` | once, first. `blockers[]` is `{id, message, fix}` per thing that would stop the run before it changes anything (the `error_id` values above); empty on macOS and on a free Linux machine. `warnings[]` is `{id, message, fix}` per thing the plan shows and the run goes on from, next to `blockers[]` (empty on macOS and on a healthy machine; Linux only): `wsl_memory_low` (WSL has less than about 5.5 GB), `wsl_disk_low` (the Windows drive has less than 15 GB free), and a host that did not answer within 10 seconds, after one retry: `pypi_unreachable`, `npm_registry_unreachable`, `nodejs_unreachable`, `astral_unreachable` and `apt_mirror_unreachable` (the first `http` or `https` archive in `/etc/apt`; a `file:` or `mirror+file:` one is not probed, and curl does not know apt's own proxy, so it only warns). Pass `--offline` to skip the host probes. `steps[]` lists the two privileged steps first (`n` null, `sudo` true, `will_run` false when nothing needs doing: the patched package is in place, the line is in `/etc/hosts`), then the three numbered steps of the terminal output |
| `step` | `n`, `id`, `parent`, `name`, `status`, and on the end of a step `secs`; `message` for `failed`, `skipped` and `warning` (the CLI's `[FAIL]` or `[WARN]` line); `command` for a skipped privileged step (what to run by hand) | `status` is `running`, then `done`, `unchanged`, `skipped`, `warning` or `failed`. A step with a `parent` is a section of that phase script (`parent` is `system_deps` or `bench_site`) or an action of the service step (`parent` is `service`, the `id` is a [repair action](#benchbar-repair---json)); its `n` is null |
| `progress` | `step`, `label`, `elapsed` (seconds), `bytes` and `total` (int or null) | every 10 seconds while a long command runs (a download, `bench init`, `bench get-app`, `bench build`, `bench new-site`); `bytes` only for a download |
| `done` | `exit`, `bench`, `site`, `url` (null unless `exit` is 0), `skipped[]` (`id`, `command` of every privileged step that was skipped), `fix` (string or null), `log`, and `error` (only for a refusal before the plan) | always the last line, also after a failure or a signal (`exit` is then 128 plus the signal, 143 for SIGTERM, and a step that was running gets no end line). `exit` 2: the MariaDB root password is unknown, `fix` says what to pass (`MARIADB_ROOT_PASSWORD`); run again with it in the environment |

Section ids of the phase scripts: `profile`, `system`, `plan`, `dry_run`,
`python`, `node`, `database`, `redis`, `pdf`, `build_deps`,
`shell_config`, `summary`, `ready`, `pending_manual_steps` (phase 00;
on Linux `00-linux-system-deps.sh` adds `apt_packages` and has no
`build_deps`);
`profile`, `advanced_version_mode`, `precheck`, `inputs`, `plan`,
`verify_db_credentials`, `pipx`, `bench_cli`, `bench_init`, `get_apps`,
`create_site`, `verify_site`, `install_apps_on_site`, `ready` (phase 01). They are the section headings of the terminal output in
lowercase with `_`, so a reader should show `name` and treat an `id` it
does not know as any other section.

`install --dry-run --json` prints the `plan` line, then `done` with
`exit` 0 and `"dry_run":true`, and changes nothing; the human plan goes
to the log.

### The privileged steps and `BENCHBAR_SUDO=gui`

The wkhtmltopdf package and the `/etc/hosts` line are the only things
that run as root. In a terminal the run asks for `sudo` once up front.
With `BENCHBAR_SUDO=gui` in the environment (the BenchBar app sets it
for an install, adopt, repair or `site hosts` it started from a sheet the
user confirmed), each of the two runs as one script through
`osascript ... with administrator privileges`: macOS shows its own
password dialog with the step's name, benchbar never sees the password,
and there is no cached credential afterwards. At most two dialogs per
run. A cancelled dialog makes that step `skipped` with its `command`,
and the run goes on; a step that failed behind its dialog is not asked
again by a later pass of the same run. Only the value `gui` switches the
mode, on macOS (on Linux it is ignored). Rosetta 2, when the package
needs it and it is missing, is installed by the package's own script, in
the same dialog. Without `gui`, `install --json` and `adopt --json` never
prompt: they use `sudo` only when it needs no password (a cached
credential, a `NOPASSWD` rule) and skip the steps otherwise.

The commands that read `BENCHBAR_SUDO`: `install`, `adopt`, `repair` (the
`hosts_entry` and `wkhtmltopdf_install` actions), `site hosts`, `site add`,
`ports setup` and `ports apply`. `ports apply` puts the missing hosts lines
of every bench of the batch in one dialog (titled `Add 127.0.0.1 lines for N
sites to /etc/hosts`); if it is cancelled, each bench's setup prints
`benchbar site hosts --bench-dir PATH` as its manual step and the run goes
on. `site drop` still needs a terminal for the line it removes.

### `BENCHBAR_SUDO=env` (Linux)

On Linux, a program without a terminal (the Windows tray, an agent)
passes the user's sudo password in `BENCHBAR_SUDO_PASSWORD` with
`BENCHBAR_SUDO=env`. The CLI takes it out of its environment before
anything else runs (it starts itself once more without the variable, so
the running process has no copy in `/proc/PID/environ`), checks it once with `sudo -k` and `sudo -S -v`
before any change, and then runs its sudo steps without a prompt. A
wrong password ends the run with `exit` 1 and `error_id`
`sudo_password_wrong`. The password never goes into arguments, `bash -x`
output, the run log or a child process: in `install` only phase 00 gets
it, on a file descriptor. Every command forgets it, and drops the sudo
credential, when its sudo steps are done, before any bench, pip or npm
step runs. Without a
password and without a terminal, `install --json` with
`BENCHBAR_NONINTERACTIVE=1` names `BENCHBAR_SUDO_PASSWORD` in `missing`;
other commands skip their sudo step with a warning. The commands that
read it: `install`, `adopt`, `repair`, `service`, `site add` and
`ports apply`. On macOS it is ignored.

## `benchbar adopt PATH --json`

Added in 0.8, the same stream as `install --json`. Without `--yes` (or
`--dry-run`) it is refused with one `done` line. The `plan` carries
`bench`, `site`, `profile`, `port_offset`, `ports_move` (true when adopt
moves the bench to another port block with `bench set-config -g`),
`dry_run`, `sudo_mode`, `steps[]` and `log`. Its steps are the service
actions it applies, numbered from 1 as in the terminal output (`id` a
repair action, `sudo` true for `hosts_entry`), and they stream as `step`
events without a `parent`. `done` has `exit`, `bench`, `site`, `url`,
`skipped[]`, `fix` and `log`. An empty `steps` means the bench is already
set up.

## `benchbar doctor --prerequisites --json`

Added in 0.8. What a Mac needs before `install`, without a bench: the
BenchBar app's Check Your Mac page. `--bench-dir PATH` names the folder a
new bench would go to (default `~/frappe-bench`); it does not have to
exist.

```json
{"schema_version":1,"cli_version":"0.8.0","bench":"/Users/you/frappe-bench","prerequisites":[{"id":"apple_silicon","label":"Apple Silicon","level":"ok","message":"arm64","fix_command":null},{"id":"homebrew","label":"Homebrew","level":"fail","message":"brew was not found","fix_command":"/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""}],"summary":{"ok":7,"warn":0,"fail":1}}
```

| `id` | Checks | Levels |
|---|---|---|
| `apple_silicon` | `uname -m` is `arm64` | `ok`, `fail` |
| `macos_version` | macOS 14 or later | `ok`, `fail` |
| `command_line_tools` | `xcode-select -p` names a folder that exists | `ok`, `fail` (fix `xcode-select --install`) |
| `homebrew` | `brew` on PATH or in `/opt/homebrew/bin` | `ok`, `fail` (fix: the official install command) |
| `disk_free` | free space on the volume of `$HOME`; the check carries `free_gb` | `ok` from 20 GB, `warn` from 10 GB, `fail` below |
| `bench_folder` | the folder is a valid bench path and not under iCloud Drive, Desktop or Documents | `ok`, `warn` (Desktop, Documents), `fail` (iCloud Drive, a path benchbar refuses) |
| `cleanmymac` | as doctor's `cleanmymac` check, for that folder | `ok`, `warn` |
| `mole` | as doctor's `mole` check, for that folder | `ok`, `warn` |
| `default_ports` | ports 8000, 9000, 11000 and 13000 are free; the check carries `port_offset`, the block `install` would give a new bench | `ok`, `warn` (taken: the new bench gets `port_offset`), `fail` (no block up to the last offset is free; `port_offset` is null) |

Every object has the fields of a doctor check (`id`, `label`, `level`,
`message`, `fix_command`), and every check that is not `ok` has a
`fix_command`: the command to run, or a plain instruction where there is
none ("BenchBar needs an Apple Silicon Mac", "update macOS in System
Settings, Software Update", "free space on the volume of ...").

On Linux (Ubuntu 24.04, WSL too) the list is its own, in this order:
`linux_distro`, `architecture`, `regular_user`, `sudo` (installed, and
the user is in the `sudo` or `admin` group; the check never runs sudo),
`apt` (a mirror answers; unreachable is a `warn`), `systemd` (PID 1;
carries `enabled`), `linger` (carries `enabled`), `memory` (`warn` below
3500 MB, `fail` below 1800 MB; carries `total_mb`), `disk_free`,
`bench_folder`, `mariadb_password` (`warn` with `needs_password` when a
running MariaDB has a root password benchbar does not know) and
`default_ports`.

Exit 1 when one is `fail`. `benchbar doctor --prerequisites` prints
the same list for a person. A plain `doctor` does not print it (its WARN
and FAIL lines promise a fix line and its exit code the state of the
bench); `doctor --json` of a bench carries the same array as
`prerequisites` next to `checks`, not counted in `summary` or in the exit
code.
