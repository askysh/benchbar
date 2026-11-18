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
| `fixtures/` | Recorded `benchbar.exe` output for the demo mode and the tests: bench sets (`rest`, `crash`, `load`, `recorded`), the answers of the pages (`cli`) and of the setup wizard (`setup`). |

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
