# BenchBar for Windows as an MSIX package

Issue 135. The package holds `benchbar.exe` (the shim) and `BenchBarTray.exe` (the tray app, .NET self contained) in one flat folder, so the tray finds the shim next to itself.

## Status

- CI builds the package. `.github/workflows/msix.yml` builds the unsigned Store bundle on pull requests that touch `windows/msix`, `windows/tray` or `windows/shim`, and can build the test package by hand (Actions, MSIX package, Run workflow). It uploads the result as an artifact and publishes nothing.
- No Microsoft Store submission in 0.9.0. The one line installer and the zip stay the way to install.
- Not signed. Store mode makes an unsigned package on purpose: Microsoft signs it after certification. Sideload mode signs a test package with a self signed certificate, for this PC only. A self signed package says nothing about Smart App Control; only a Store signed package does (see `docs/windows.md`).

## Files

| File | What it is |
| --- | --- |
| `AppxManifest.xml` | Manifest template. `build-msix.ps1` fills the `{{TOKEN}}` values. |
| `build-msix.ps1` | Builds both programs, lays out the package, packs it, and signs it for a test or makes the Store upload. |
| `Assets/` | The three logos the manifest names (`Square44x44Logo`, `Square150x150Logo`, `StoreLogo`), made from the tray icon. No `resources.pri` is built. The Store step adds the scale and target size variants. |

Two apps are declared. `BenchBarTray` has the Start menu entry and the startup task (`Enabled="false"`: the person turns it on). `BenchBarCli` has no Start entry and owns the `benchbar.exe` alias.

## Build locally

Needs Windows 10 22H2 or Windows 11, Go (see `windows/shim/go.mod`), the .NET 10 SDK (see `windows/tray/global.json`) and the Windows SDK (`makeappx.exe`, `signtool.exe`, `makepri.exe`). The script says what is missing.

```powershell
cd windows\msix
.\build-msix.ps1                          # Sideload: x64 (or this PC's CPU), self signed, prints the install lines
.\build-msix.ps1 -Mode Store -Arch x64    # unsigned x64 .msix and .msixupload (the default, -Arch both, adds arm64 and makes the bundle)
```

Options: `-Version A.B.C` (package version, the fourth part is 0), `-AppVersion X.Y.Z` (stamped into both programs), `-Arch x64|arm64|both`, `-OutDir`, `-SkipBuild` (repack `out\stage-<arch>`), `-FrameworkDependent` (a smaller tray, for a size check only; it does not start without the .NET runtime), `-MakePri`, `-SdkBin` (a folder with the SDK tools). Store mode defaults to BenchBar's product identity from Partner Center (Name `Askysh.BenchBar`); `-IdentityName`, `-Publisher` and `-PublisherDisplayName` override it and must equal the Partner Center values.

A Sideload package needs its test certificate trusted before it installs, and removed afterwards. The script prints both sets of lines; Smart App Control may block a self signed package.

## Open items

- Store certification. `runFullTrust` is a restricted capability: Partner Center asks for a justification ("BenchBar is a desktop program. Its tray app and its command line program start other programs: wsl.exe and the BenchBar CLI inside the user's WSL distro. They cannot run in an app container."). Policies 10.2.2 (a remote script is run: the setup runs the Linux installer inside WSL) and 10.2.3 (WSL, Ubuntu and MariaDB are secondary software) need notes for the testers. A privacy policy URL is also required.
- Elevation for `wsl --install` from a package. Store apps that need elevation are not accepted, and the setup step `wsl_enable` asks for it (UAC). Whether `runas` works from a packaged process, and what the package does instead, is not settled.
- arm64 is built in CI but not verified on arm64 hardware.
