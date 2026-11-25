# BenchBar tray (Windows)

The tray app of BenchBar for Windows: a WPF program on .NET 10 that shows your benches in the
notification area and starts, stops and watches them through `benchbar.exe` (the shim, which
forwards to the CLI inside WSL). It reads no file inside WSL by itself. User guide:
[docs/windows.md](../../docs/windows.md). Why things are the way they are: [DECISIONS.md](DECISIONS.md).

## Layout

| Folder | What it is |
| --- | --- |
| `BenchBarTray/` | The app: windows, the flyout, the tray icon (WPF, H.NotifyIcon). |
| `Tray.Core/` | Everything without a window: the poller, the state model, the CLI client, the setup service, the view models, the runner art. |
| `Tray.Core.Tests/`, `BenchBarTray.Tests/` | xUnit tests of the library and of the windows. |
| `fixtures/` | Recorded `benchbar.exe` output for the demo mode and the tests: bench sets (`rest`, `crash`, `load`, `recorded`), the answers of the pages (`cli`) and of the setup wizard (`setup`). Some are generated from the CLI, see below. |
| `scripts/smoke.ps1` | Starts a published `BenchBarTray.exe` on recorded data, checks it stays up and quits it cleanly. |

`Directory.Build.props` holds the settings every project shares, `Directory.Packages.props` the
package versions. The SDK is pinned in `global.json`.

## Build and test

The tray targets `net10.0-windows`, so the tests run on Windows only (CI: `.github/workflows/tray.yml`).

```powershell
dotnet build BenchBarTray.sln -c Release
dotnet test BenchBarTray.sln -c Release --no-build
```

On a Mac or Linux machine the code builds, but does not run:
`dotnet build BenchBarTray.sln -p:EnableWindowsTargeting=true`.

## Fixtures follow the CLI

`bash tests/record-tray-fixtures.sh` (from the repository root, on any machine that runs the mocked
tests) runs the CLI of this checkout under the test mocks and rewrites the generated fixtures:
`recorded/list.json`, `recorded/status.json`, `cli/ports-check-clean.json` and `cli/scan-empty.json`.
Review the diff and commit it. The other files in `cli/` are scenarios the mocks cannot make (an
older CLI, a refusal, three apps with focus reasons); the script checks only that every field in them is
still printed by the command they stand for. The check runs as `tests/test-tray-fixtures.sh` in
the CLI test suite (`--check` changes nothing and exits 1 on a difference), so a CLI change that
renames or drops a field the tray reads fails there, not on a user's PC. A new CLI field shows up as a
difference in the generated files; the tray ignores fields it does not know.

## Start check of the published app

`scripts/smoke.ps1 -Dir DIR -Fixtures fixtures/rest` starts `DIR\BenchBarTray.exe` with
`BENCHBAR_TRAY_FIXTURES` set, waits for the run marker, checks the app is still running after 8
seconds, sets the `Local\BenchBarTray.Quit` event and checks for exit code 0 and a removed marker.
`tray.yml` runs it on the x64 and arm64 builds; `release-windows.yml` runs it on the amd64 files that
ship (after signing) and on the arm64 zip, on a Windows on Arm runner (`windows-11-arm`). It writes to
`%LOCALAPPDATA%\BenchBar`, so run it on a CI runner or a test PC, not where the tray is in use.

## Run with recorded data

Set `BENCHBAR_TRAY_FIXTURES` to a fixtures folder and the tray shows recorded benches and a setup
that installs nothing. It says "Demo data" in its windows while the variable is set.

```powershell
$env:BENCHBAR_TRAY_FIXTURES = "$PWD\fixtures\rest"
dotnet run --project BenchBarTray -c Debug
```

Debug builds also read `BENCHBAR_TRAY_THEME` (`light` or `dark`), `BENCHBAR_TRAY_HARNESS_PIPE` and
`--logon-log FILE`; Release builds do not contain them.

## Text

User text goes in `Tray.Core/Resources/Strings.resx` and is read with `UiText.Get`. A
`Strings.<culture>.resx` next to it translates it. Dates and sizes for display go through
`UiText.Date` and `ByteSize.Format` with the current culture; machine output stays invariant.

## NuGet lock files

Each project commits a `packages.lock.json` that holds `win-x64` and `win-arm64`, and CI restores with `-p:RestoreLockedMode=true`. After a change to `Directory.Packages.props`, refresh the lock files with `dotnet restore --force-evaluate` from `windows/tray`, without `-r` (a `-r` restore would drop the other runtime from the file), and commit them.
