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
| `benchbar.exe doctor` | Windows checks first, then the CLI's doctor. `--json` and `--fix-hints` go straight to the CLI. |

`wslconfig --apply` never runs `wsl.exe --shutdown`; WSL reads the file at its
next start.

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
