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
| `benchbar.exe setup run ACTION [--distro NAME] [--user NAME] --jsonl` | Runs one setup action (`wsl_enable`, `wsl_update`, `distro_install`, `distro_user`, `systemd`, `cli_install`, `linger`, `keepalive`, `wslconfig`, `path`) and prints JSON lines. `wsl_enable` asks Windows for permission (UAC). |
| `benchbar.exe doctor` | Windows checks first, then the CLI's doctor. `--json` and `--fix-hints` go straight to the CLI. |

`wslconfig --apply` never runs `wsl.exe --shutdown`; WSL reads the file at its
next start.

## Setup

`setup check` prints one JSON document (`schema_version`, `distro`, `ready`,
`reboot_pending`, `steps`); each step has an `id`, a `status` (`ok`, `missing`,
`warn`, `fail`), a `title`, a `detail`, the `action` that fixes it and
`needs_admin`. It exits 0 whenever the document printed. Once a blocking step
is not ok, the later steps read `waits for <id>`.

`setup run` prints only JSON lines on stdout: `step` events (`running`,
`done`, `failed`, `skipped`), `log` events (the output of the commands it ran,
as data) and exactly one `done` event with `exit` (0 or 1), `changed`,
`reboot_required`, `cancelled`, `warnings` and `next_actions`. The password for
`distro_user` comes from `BENCHBAR_SETUP_PASSWORD` and reaches `chpasswd` on
stdin only.

The `done` event of `distro_user` also carries `"user_existed": true|false`
(no other action has it). When it is true the Linux user was there already: the
password in `BENCHBAR_SETUP_PASSWORD` was not applied, so it may not be that
user's sudo password. The `/etc/wsl.conf` backup is named
`wsl.conf.benchbar-backup-<time>-<pid>`, with `-N` added when the name exists;
an earlier backup is never overwritten.

Only `wsl_enable` needs administrator rights. The shim starts itself with the
`runas` verb as `benchbar.exe setup elevated wsl_enable --result FILE`. That
child accepts nothing else: one allow listed action, a result file named
`run-<16 hex>.jsonl` in `%LOCALAPPDATA%\BenchBar\setup`, no free text, and it
runs `System32\wsl.exe` only. A declined prompt ends with `cancelled: true`.
The shim never runs `wsl.exe --unregister` or `--shutdown`. `systemd` and
`distro_user` stop the one distro with `wsl.exe --terminate NAME`.

The runas prompt may open behind other windows. The shim calls
`AllowSetForegroundWindow(ASFW_ANY)` before it starts the child, which helps
only if the shim itself may set the foreground; the caller (the tray) should
call it too, before it starts `setup run wsl_enable`. The shim finds
`wsl.exe` and `schtasks.exe` through `GetSystemDirectory`, never an
environment variable.

## Passwords for the CLI

When set in the shim's environment, `ADMIN_PASSWORD`, `MARIADB_ROOT_PASSWORD`,
`BENCHBAR_SUDO`, `BENCHBAR_SUDO_PASSWORD` and `BENCHBAR_NONINTERACTIVE` are
passed into WSL for that one run through `WSLENV` (appended to the child's
copy; your own `WSLENV` is not changed). No other variable is passed.

## Settings

`%LOCALAPPDATA%\BenchBar\config.json`:

- `distro`: the WSL distro to use. Default: the WSL default distro.
- `cli_path`: absolute path of the CLI inside the distro. Default: `benchbar`
  (looked up with `~/.local/bin` first on PATH).

## Build and test

```
go build -ldflags "-X main.version=0.1.0" -o benchbar.exe .
go vet ./...
go test ./...
```

Integration tests need a real distro with benchbar installed:

```
set BENCHBAR_TEST_DISTRO=Ubuntu-24.04
go test -tags wslintegration -run Integration ./...
```
