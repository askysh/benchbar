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
| `benchbar.exe path install\|status\|remove` | Put this folder on your user PATH, show where `benchbar.exe` resolves, or take exactly this folder out of the user PATH again (a clear line and no change when it is not there). |
| `benchbar.exe setup check [--json] [--probe] [--distro NAME]` | Read only. Checks the PC step by step (Windows build, virtualization, WSL, restart, distro, Linux release, Linux user, systemd, CLI, linger, keepalive, `.wslconfig`, PATH). Never starts a stopped distro unless `--probe`, never asks for admin rights. |
| `benchbar.exe setup run ACTION [--distro NAME] [--user NAME] [--force] [--jsonl]` | Runs one setup action (`wsl_enable`, `wsl_update`, `distro_install`, `distro_wsl2`, `distro_user`, `systemd`, `cli_install`, `linger`, `keepalive`, `wslconfig`, `path`). With `--jsonl` it prints only JSON lines. `wsl_enable` asks Windows for permission (UAC). |
| `benchbar.exe report-windows [--json] [--distro NAME] [--bench PATH] [--context TEXT] [--tray-version V] [--include FILE]...` | Write a redacted zip for a bug report. Works with no WSL, no distro and no CLI. See "Bug report zip". |
| `benchbar.exe doctor` | Windows checks first, then the CLI's doctor. `--json` and `--fix-hints` go straight to the CLI. See "Doctor". |

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
| `windows_build` | Windows version | yes | none: install the Windows update (Windows 10 22H2, build 19045, or later) |
| `virtualization` | Virtualization | yes | none, and never `fail`: a missing flag is a `warn`, because Windows can report it wrongly while a hypervisor runs. The hard answer comes from the step that fails with `0x80370102` (see below). |
| `wsl_feature` | Windows Subsystem for Linux | yes | `wsl_enable` |
| `reboot` | Restart Windows | yes | none in `setup run`: the tray asks you to restart. The detail says to choose Restart, not Shut down: with Fast Startup, Shut down does not count as a restart |
| `wsl_version` | WSL version | yes | `wsl_update` |
| `distro` | Linux distro | yes | `distro_install`; `distro_wsl2` when the distro runs as WSL 1 |
| `distro_os` | Linux version | yes | none: BenchBar supports Ubuntu 24.04, the detail says `DISTRO is NAME VERSION` and names the fix (`setup run distro_install --distro Ubuntu-24.04`, or `adopt-distro NAME`) |
| `distro_user` | Linux user | yes | `distro_user` |
| `systemd` | systemd | yes | `systemd` |
| `cli` | BenchBar command line tool | yes | `cli_install` (also when the CLI is older than this `benchbar.exe`, see below) |
| `linger` | Keep benches running | no | `linger` |
| `keepalive` | Keep the distro awake | no | `keepalive` |
| `wslconfig` | WSL idle settings | no | `wslconfig` |
| `shim_path` | benchbar.exe on PATH | no | `path` |

### Which distro, and which release

`setup` works on `--distro NAME`, else the `distro` in `config.json`, else the
one Ubuntu 24.04 distro that is already there (the only WSL 2 distro that is
not a container tool one, called `Ubuntu...`, whose `/etc/os-release` says
Ubuntu 24.04; a stopped distro is looked into only by `setup run` and by
`setup check --probe`), else `Ubuntu-24.04`, which `distro_install` installs.
Outside `setup`, a command picks the WSL default distro, but never one whose
name starts with `docker-desktop`, `rancher-desktop` or `podman-machine`,
default or not: it takes the only other distro, and with several (or none) it
stops and names `benchbar.exe adopt-distro NAME`. A `distro` in `config.json`
is always used as written.

`distro_os` is blocking: a distro that is not Ubuntu 24.04 (Debian 13, for
example) stops the setup before the install fails deep inside it. A distro
whose `/etc/os-release` cannot be read is a `warn`.

### The CLI and the shim stay on one release

A release build of `benchbar.exe` (`X.Y.Z`) wants the same release of the CLI
in the distro. When the CLI is older, the `cli` step is `missing` with the
action `cli_install` and a detail that names both versions; the step also
carries `cli_version`, the installed CLI release (a string, left out when
unknown), so a client can tell "update" (`missing` with a `cli_version`) from
"install" (`missing` without one). `cli_install`
then runs the installer pinned to this release (it fetches and checks out the
tag), so an upgrade of `benchbar.exe` brings the CLI along. A CLI that is
newer is only a `warn` with no action (nothing here takes a CLI back to an
older release). A dev build of the shim never reports a difference, and a
custom `cli_path` is never touched. `benchbar.exe doctor` shows the same as a
WARN with the fix line.

When the installer download fails, the failure names the cause: curl exit 22
(the release is not published for this build), 6, 7 or 28 (no network or DNS
from WSL: check the VPN and the proxy), 35 or 60 (a proxy or security product
changes the TLS certificate). `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` and
their lower case forms, when set in Windows, are passed into the distro for
the installer and for forwarded commands (see "Variables for the CLI").

`wsl_enable` failures print the exit code in hex (`0x80370102`) with advice:
`0x80370102` is virtualization turned off (Intel VT-x, AMD SVM, in the BIOS or
UEFI settings); `0x80072ee7`, `0x80072efd`, `0x80072ee2` are the network or a
proxy; `0x80070005` and `0x80070422` are a policy or a stopped Windows
service. Any other code points at `wsl --install --no-distribution` in a
terminal opened as administrator, which shows the message the hidden window
hides.

`error_id` values on a `done` event with `exit` 1:

| `error_id` | When | What to do |
| --- | --- | --- |
| `distro_running` | `systemd`, `distro_user` or `distro_wsl2` must restart the distro (`wsl.exe --terminate NAME`) and the distro is running. The message says what stops: the benches and MariaDB in it. Nothing was changed. | Ask the person, stop the benches (`benchbar down`), then run the action again, or pass `--force` to accept the stop. |

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
(Ctrl+C or Ctrl+Break, or the console is closed) while the install runs, the
shim reports that the install keeps running in Windows, asks for a restart and
writes the restart marker; it is not a failure. A second Ctrl+C ends the shim
at once. Only `setup run` listens for this; every other command keeps the
default behaviour of the console.
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

## Variables for the CLI

When set in the shim's environment, `ADMIN_PASSWORD`, `MARIADB_ROOT_PASSWORD`,
`BENCHBAR_SUDO`, `BENCHBAR_SUDO_PASSWORD` and `BENCHBAR_NONINTERACTIVE` are
passed into WSL for that one run through `WSLENV` (appended to the child's
copy; your own `WSLENV` is not changed). So are the proxy settings
`HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` and `http_proxy`, `https_proxy`,
`no_proxy` (Linux tools read the lower case ones). No other variable is
passed.

## Windows paths as arguments

An argument that is clearly a Windows path is turned into the Linux path
before the command is forwarded, in the shim, with no extra `wsl.exe` call:

| You type | The CLI gets |
| --- | --- |
| `C:\Users\me\bench` or `C:/Users/me/bench` | `/mnt/c/Users/me/bench` |
| `\\wsl.localhost\Ubuntu-24.04\home\me\bench` or `\\wsl$\...` of the same distro | `/home/me/bench` |
| `--bench-dir=D:\b` | `--bench-dir=/mnt/d/b` |

Only `X:\...`, `X:/...` and the two `\\wsl` shapes count. `C:`, `C:foo`, a path
of another distro, a UNC path of a server, and text that merely contains a
path are passed as typed. Arguments after a `--` are converted too: the CLI
uses `--` before bench paths (`benchbar ports plan -- PATH`), and a drive path
is never a valid Linux argument, so the conversion cannot break a command
that takes something else there. Benches still belong in the distro; a path
under `/mnt/c` is what you asked for, not a place the shim picks.

## Deadlines

The shim's own `wsl.exe` calls end after a deadline: 60 seconds for
`--status`, `--list` and `--version`, 60 seconds for `--terminate`, 90 seconds
for a call that may boot a distro (the probe, a command as root). The message
says `wsl.exe did not answer in N s`, tells you to wait a minute and run
`benchbar.exe setup check` again, and only then names `wsl.exe --shutdown` as
the last resort (it stops every WSL distro and everything running in them). A `wsl.exe` that
does not answer is never read as "WSL is not installed". The command you
forward has no deadline, and its exit code is returned unchanged. When
`wsl.exe` itself fails with a code outside 0 to 255 (for example
`0x80370102`), the shim still returns 1 and prints one line to stderr:
`wsl.exe itself failed (0x...): run benchbar.exe setup check`. A `wsl.exe`
that the console ended with Ctrl+C (`0xC000013A`) is an interrupt: no such
line, exit code 130.

## Doctor

`benchbar.exe doctor` prints the Windows checks first. Besides PATH, distro,
`.wslconfig` idle settings, keepalive and the tray checks it shows:

- `cli_version`: the CLI in the distro against this `benchbar.exe` (release
  builds only).
- `wsl_network`: `localhostForwarding=false`, or `networkingMode` bridged or
  virtioproxy, in `.wslconfig` (the site may not open from a Windows browser at
  `localhost`); `mirrored` is an information line.
- `keepalive`: also a WARN when the scheduled task runs another copy of
  `benchbar.exe` than the one you run (an upgrade into another folder); the fix
  is `benchbar.exe keepalive install`, which rewrites the task in place.
- `tray_logon`: a WARN when the Startup shortcut is there but Windows has it
  turned off (Settings > Apps > Startup).
- `install_files`: a WARN when a file that `install.ps1` recorded in
  `.installed-files.txt` (the tray, or the program the keepalive task runs) is
  gone from the install folder; a security product may have removed it (Windows
  Security > Virus & threat protection > Protection history).

## Settings and state

Settings and setup state live in `%LOCALAPPDATA%\BenchBar`: `config.json`
(below), `setup\` (the restart marker, `reboot-pending.json`), `reports\`
(the Report a Bug zips) and `runners\` (the tray's custom runners). The
benches and their state stay in the distro.

`%LOCALAPPDATA%\BenchBar\config.json`:

- `distro`: the WSL distro to use. Default: the WSL default distro (never a
  container tool distro, see "Which distro, and which release").
- `cli_path`: absolute path of the CLI inside the distro. Default: `benchbar`
  (looked up with `~/.local/bin` first on PATH).

The file may be UTF-8 (with or without a BOM) or UTF-16 (Windows PowerShell's
`Out-File`). A file that is not a JSON object stops the command with its path
and the fix: correct it, delete it, or run `benchbar.exe adopt-distro NAME`,
which keeps the old text as `config.json.invalid` and writes a new file. The
shim writes the file next to itself and renames it over the old one, and
holds the machine wide mutex `Local\BenchBarConfig` (waiting at most two
seconds) around read, change and write; a program that edits the file too
(the tray) should take the same name.

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
