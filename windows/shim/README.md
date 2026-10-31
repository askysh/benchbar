# benchbar.exe, the Windows shim

`benchbar.exe` runs the BenchBar CLI inside a WSL distro, so `benchbar status`
works from PowerShell and cmd. It passes stdin, stdout and stderr through and
returns the CLI's exit code. It never reimplements CLI logic, and it keeps
benches and state inside the distro, never under `C:\`.

Every command is forwarded to the CLI, except these (only as the first
argument):

| Command | What it does |
| --- | --- |
| `benchbar.exe --shim-version` | Print the shim version. |
| `benchbar.exe adopt-distro [NAME] [--yes] [--json]` | Check a distro (registered, WSL 2, systemd, benchbar, linger) and record it as the target. |
| `benchbar.exe wslconfig [--suggest] [--apply --yes] [--json]` | Show `.wslconfig` memory and idle settings, suggest or write safe values (with a backup). |
| `benchbar.exe keepalive install\|remove\|status\|run` | A logon task that keeps the distro running. No admin, no service. |
| `benchbar.exe path install\|status` | Put this folder on your user PATH. |
| `benchbar.exe setup check [--json] [--probe] [--distro NAME]` | Read only. Checks the PC step by step (Windows build, virtualization, WSL, restart, distro, Linux user, systemd, CLI, linger, keepalive, `.wslconfig`, PATH). Never starts a stopped distro unless `--probe`, never asks for admin rights. |
| `benchbar.exe setup run ACTION [--distro NAME] [--user NAME] [--force] [--jsonl]` | Runs one setup action (`wsl_enable`, `wsl_update`, `distro_install`, `distro_user`, `systemd`, `cli_install`, `linger`, `keepalive`, `wslconfig`, `path`). With `--jsonl` it prints only JSON lines. `wsl_enable` asks Windows for permission (UAC). |
| `benchbar.exe report-windows [--json] [--distro NAME] [--bench PATH] [--context TEXT] [--tray-version V] [--include FILE]...` | Write a redacted zip for a bug report. Works with no WSL, no distro and no CLI. See "Bug report zip". |
| `benchbar.exe doctor` | Windows checks first, then the CLI's doctor. `--json` and `--fix-hints` go straight to the CLI. |

`wslconfig --apply` never runs `wsl.exe --shutdown`; WSL reads the file at its
next start.

## Setup

`setup check` prints one JSON document (`schema_version`, `distro`, `ready`,
`reboot_pending`, `steps`); each step has an `id`, a `status` (`ok`, `missing`,
`warn`, `fail`), a `title`, a `detail`, the `action` that fixes it,
`needs_admin` and `blocking`. It exits 0 whenever the document printed. Once a
blocking step is not ok, the later steps read `waits for <id>`.

`blocking` is `true` for the steps that must be ok before the PC is `ready`
(Windows build through `cli`) and `false` for the advisory ones: `linger`,
`keepalive`, `wslconfig` and `shim_path`. An advisory step is `ok` or `warn`,
never `missing` or `fail` (except as a `waits for` row), and never changes
`ready`. When a `warn` has no `action`, its `detail` ends with the exact
command that fixes it (for example another `benchbar.exe` earlier on the
machine PATH). A blocking step without an `action` (a custom `cli_path` that
does not exist) also names its fix in the `detail`.

With `--jsonl`, `setup run` prints only JSON lines on stdout: `step` events (`running`,
`done`, `failed`, `skipped`), `log` events (the output of the commands it ran,
as data) and exactly one `done` event with `exit` (0 or 1), `changed`,
`reboot_required`, `cancelled`, `warnings` and `next_actions`. A failed action
may add `error_id`, a short id the caller can act on (see below); it is absent
otherwise. The password for
`distro_user` comes from `BENCHBAR_SETUP_PASSWORD` and reaches `chpasswd` on
stdin only.

The step ids of `setup check`, in order, and the `setup run` action that
fixes each one (the `action` field of the step):

| Step `id` | Title | Blocking | Fixed by |
| --- | --- | --- | --- |
| `windows_build` | Windows version | yes | none: install the Windows update (Windows 10 build 19041 or later) |
| `virtualization` | Virtualization | yes | none: turn on Intel VT-x or AMD-V (SVM) in the firmware |
| `wsl_feature` | Windows Subsystem for Linux | yes | `wsl_enable` |
| `reboot` | Restart Windows | yes | none in `setup run`: the tray asks you to restart |
| `wsl_version` | WSL version | yes | `wsl_update` |
| `distro` | Linux distro | yes | `distro_install` |
| `distro_user` | Linux user | yes | `distro_user` |
| `systemd` | systemd | yes | `systemd` |
| `cli` | BenchBar command line tool | yes | `cli_install` |
| `linger` | Keep benches running | no | `linger` |
| `keepalive` | Keep the distro awake | no | `keepalive` |
| `wslconfig` | WSL idle settings | no | `wslconfig` |
| `shim_path` | benchbar.exe on PATH | no | `path` |

`error_id` values on a `done` event with `exit` 1:

| `error_id` | When | What to do |
| --- | --- | --- |
| `distro_running` | `systemd` or `distro_user` must restart the distro (`wsl.exe --terminate NAME`) and the distro is running. The message says what stops: the benches and MariaDB in it. Nothing was changed. | Ask the person, stop the benches (`benchbar down`), then run the action again, or pass `--force` to accept the stop. |

The `done` event of `distro_user` also carries `"user_existed": true|false`
(no other action has it). When it is true the Linux user was there already: the
password in `BENCHBAR_SETUP_PASSWORD` was not applied, so it may not be that
user's sudo password. The `/etc/wsl.conf` backup is named
`wsl.conf.benchbar-backup-<time>-<pid>`, with `-N` added when the name exists;
an earlier backup is never overwritten.

Only `wsl_enable` needs administrator rights. The UAC prompt elevates
`System32\wsl.exe --install --no-distribution` itself (found with
`GetSystemDirectory`), never `benchbar.exe`, because the per user install
folder is writable by the user. The elevated window is hidden, so the `done`
event comes from the exit code (3010 and 1641 mean restart) and from
`wsl.exe --status` afterwards. A declined prompt ends with `cancelled: true`.
A second `wsl_enable` while one runs fails at once. If the caller is stopped
while the install runs, the shim reports that the install keeps running in
Windows, asks for a restart and writes the restart marker; it is not a failure.
The shim never runs `wsl.exe --unregister` or `--shutdown`. `systemd` and
`distro_user` stop the one distro with `wsl.exe --terminate NAME`.

The runas prompt may open behind other windows. The shim calls
`AllowSetForegroundWindow(ASFW_ANY)` before it starts the child, which helps
only if the shim itself may set the foreground; the caller (the tray) should
call it too, before it starts `setup run wsl_enable`. The shim finds
`wsl.exe` and `schtasks.exe` through `GetSystemDirectory`, never an
environment variable.

## Bug report zip

`benchbar.exe report-windows` writes
`%LOCALAPPDATA%\BenchBar\reports\benchbar-windows-report-YYYYMMDD-HHMMSS.zip`
and keeps the newest 10 of those zips. It never asks for administrator rights
and never starts a stopped distro (it asks `wsl.exe --list --running --quiet`,
like `setup check` without `--probe`). The zip holds:

- `summary.txt`: shim, tray and CLI versions, Windows product name, build and
  architecture, the WSL version text, the default and the configured distro,
  whether the distro is installed, running or stopped, and the `--context`.
- `setup-check.json`: the same data as `setup check --json` without `--probe`.
- `wsl-status.txt` and `wsl-list.txt`: the output of `wsl.exe --status` and
  `wsl.exe --list --verbose`.
- `included/NAME` for each `--include FILE` (repeat the flag; a file larger than
  1 MB keeps its last 1 MB).
- `cli-report.zip`, only when the distro runs and has the CLI: the zip that
  `benchbar report --json --out /tmp` names (with `--bench-dir PATH` for
  `--bench`), copied out with `wsl.exe --exec cat`.

The Windows user name, `%USERPROFILE%`, the Linux user name and `/home/<user>`
become `<user>` in every text part, and values next to words such as password,
secret, token or key become `<redacted>`. No environment is dumped.

With `--json` stdout is one line:

```json
{"schema_version":1,"zip":"C:\\Users\\...\\reports\\benchbar-windows-report-20260102-030405.zip","included":["summary.txt","wsl-status.txt","wsl-list.txt","setup-check.json","cli-report.zip"],"skipped":[{"part":"cli_report","reason":"the distro is stopped"}],"issue_url":"https://github.com/askysh/benchbar/issues/new?template=bug_report_windows.yml&title=..."}
```

`skipped` names what was left out and why (`cli_report`: WSL is not
installed, the distro is not installed, the distro is stopped, benchbar is not
installed in the distro, or the CLI report failed; `include:NAME`: the file
cannot be read). It exits 0 whenever a zip was written, 1 on a usage error or
when the zip cannot be written. Without `--json` it prints the zip path and the
issue URL. `issue_url` prefills the form fields `versions`, `windows`, `distro`
and `what`; it holds no paths or user names and stays under 4000 characters.

## Passwords for the CLI

When set in the shim's environment, `ADMIN_PASSWORD`, `MARIADB_ROOT_PASSWORD`,
`BENCHBAR_SUDO`, `BENCHBAR_SUDO_PASSWORD` and `BENCHBAR_NONINTERACTIVE` are
passed into WSL for that one run through `WSLENV` (appended to the child's
copy; your own `WSLENV` is not changed). No other variable is passed.

## Settings and state

Settings and setup state live in `%LOCALAPPDATA%\BenchBar`: `config.json`
(below), `setup\` (the restart marker, `reboot-pending.json`), `reports\`
(the Report a Bug zips) and `runners\` (the tray's custom runners). The
benches and their state stay in the distro.

`%LOCALAPPDATA%\BenchBar\config.json`:

- `distro`: the WSL distro to use. Default: the WSL default distro.
- `cli_path`: absolute path of the CLI inside the distro. Default: `benchbar`
  (looked up with `~/.local/bin` first on PATH).

## Build and test

Set `main.version` to the release version (`X.Y.Z`, without a `v`). The release
workflow does that from the tag; a build without it reports `dev`.

```
go build -ldflags "-X main.version=X.Y.Z" -o benchbar.exe .
go vet ./...
go test ./...
```

Integration tests need a real distro with benchbar installed:

```
set BENCHBAR_TEST_DISTRO=Ubuntu-24.04
go test -tags wslintegration -run Integration ./...
```
