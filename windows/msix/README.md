# BenchBar for Windows as an MSIX package (Microsoft Store spike)

## Assessment (written on a Mac, from Microsoft Learn; nothing here has run on Windows yet)

- **Verdict: feasible with changes.** Packaging is the easy part. Store certification and the AppData and registry virtualization are the real risks. Both can only be settled by the test below and by one real submission.
- **Why it helps.** The Store signs the package for you and a Store signed app needs no certificate from you (Learn, "Packaging MSIX apps"). Smart App Control allows apps signed by a CA in the Microsoft Trusted Root Program. A self signed test package proves none of this: test it with Smart App Control off.
- **Cost.** The new Partner Center flow for an individual has no registration fee (Learn, "Open a developer account"). India is not named as a supported or excluded country there. Check at sign up.
- **Code changes needed (do not start before the test passes).**
- Shim: detect package identity with `GetCurrentPackageFullName` (S, about 50 lines). In a package, `path install` and `setup`'s `path` step become no ops that say the alias provides `benchbar` (S).
- Shim: `keepalive install` must not write the package path into the task, because `C:\Program Files\WindowsApps\<name>_<version>\` changes on every update and is not launchable by path. Run it through the alias, or let the tray run `keepalive run` hidden (M, 100 to 200 lines with tests).
- Shim: in a package, `setup run wsl_enable` must not use `runas`. Print the command for an administrator terminal instead (S). Learn says apps that require elevation for any part of their functionality are not accepted into the Store.
- Shim and tray: anything the user must find (report zips, `tray.log`, config) is written to a per package private store that Explorer cannot see. Write those to a real folder, such as `%USERPROFILE%\BenchBar`, or open the physical `LocalCache\Local\BenchBar` path (M).
- Tray: replace the Startup and Setup Resume shortcuts with `StartupTask` (WinRT, already in the `net10.0-windows10.0.19041.0` target). Drop PATH editing, the install files check and the GitHub update banner in a package (M).
- Tray build: publish self contained (`--self-contained true`). There is no .NET framework package to depend on, so the runtime must ship inside (S, but the package grows by the runtime, about 70 MB per CPU, to be measured).
- Installer and CI: `install.ps1` stops when the Store package is installed. A release job builds the unsigned `.msixupload` (M). New docs page and a privacy policy page (S).
- **Store review.** `runFullTrust` is a restricted capability: Partner Center asks how you use it. Text to paste: "BenchBar is a desktop program. Its tray app and its command line program (benchbar.exe) start other programs: wsl.exe and the BenchBar CLI inside the user's WSL distro. They are Win32 programs and cannot run in an app container."
- Also needed: a privacy policy URL (policy 10.5.1 says Win32 and Desktop Bridge products always need one), the age rating questionnaire, the WSL 2 dependency stated at the start of the description (10.2.4), a clean uninstall (10.2.7) and consent before changing Windows settings (10.2.8).
- Policy risks for this app: 10.2.2 (no downloading a remote script and running it: the setup runs the Linux installer from GitHub inside WSL), 10.2.3 (no offering secondary software that is not yours unless it enhances the product: WSL, Ubuntu, MariaDB). Explain both in the certification notes, and tell testers that the wizard needs virtualization.
- **Steps for the maintainer (Partner Center).** 1) Go to storedeveloper.microsoft.com, Get started for free, Individual developer. 2) Sign in with a personal Microsoft account, then verify with a government ID and a selfie on a phone. 3) Wait about 5 minutes, open Partner Center, Apps and games.
- 4) New product, MSIX or PWA app, reserve the name `BenchBar` (it may be taken; the name must not mislead, so say "unofficial" for Frappe). 5) Product management, Product identity: copy `Package/Identity/Name`, `Package/Identity/Publisher` and `Package/Properties/PublisherDisplayName`, and the Store ID (12 characters).
- 6) Run `build-msix.ps1 -Mode Store` with those three values. They land in `Identity Name`, `Identity Publisher` and `Properties PublisherDisplayName` of `AppxManifest.xml`, and the upload is refused if they differ. 7) Submission: pricing free, properties (category, privacy URL), age rating, packages (the `.msixupload`), listing, submission options (the `runFullTrust` text), notes for certification. Submit.
- **Updates.** The Store updates the package. The tray's GitHub "Check for Updates" and banner must be hidden in a package. The CLI inside the distro still follows the shim version through `setup check` and `cli_install`, so a Store update is followed by one prompt to update the CLI.
- **Coexistence with the zip and the one line installer: yes, one at a time per PC.** The alias lives in `%LOCALAPPDATA%\Microsoft\WindowsApps`. `benchbar.exe path install` appends its folder to the user PATH, so the alias normally wins, and `doctor` already warns about another `benchbar.exe` earlier on PATH. `install.ps1` should refuse while the package is installed, and the package should warn when `Programs\BenchBar` exists. Both would also run a tray and a keepalive: the mutexes should stop that, to be tested.
- **winget.** A Store app is in the `msstore` source: `winget install <StoreID> --source msstore` (Learn gives `winget install XP9KHM4BK9FZ7Q -s msstore` as the form). The first use asks to accept the source terms (`--accept-source-agreements`, `--accept-package-agreements` skip the prompts). Whether msstore needs a Store sign in is not in the docs. The zip can stay in winget-pkgs under a different id.
- **Main risks, most severe first.** 1) Certification rejects elevation or the remote installer script (unknown until submitted). 2) HKCU and AppData writes are virtualized: PATH, RunOnce and Startup shortcuts written by a packaged process do not take effect, and files are invisible to Explorer. 3) The alias is a stub: stdio, exit codes and non interactive parents (MCP clients) are not documented. 4) The keepalive task cannot run from the package folder. 5) No test can prove Smart App Control or SmartScreen behaviour before a real Store signed build exists.

## What is in this folder

| File | What it is |
| --- | --- |
| `AppxManifest.xml` | Manifest template. `{{TOKEN}}` values come from `build-msix.ps1`. |
| `build-msix.ps1` | Builds both programs, lays out the package, packs, signs for a test, or makes the Store upload. |
| `Assets/` | Placeholder logos made from the tray icon with `sips`. Replace them before a Store submission. |
| `../../.github/workflows/msix-spike.yml` | The same build on a GitHub runner. By hand only. |

The package folder is flat: `benchbar.exe`, `BenchBarTray.exe` and the .NET runtime files sit together, because the tray looks for `benchbar.exe` next to itself first. Two apps are declared. `BenchBarTray` has the Start menu entry and the startup task (`Enabled="false"`: the person must turn it on). `BenchBarCli` has no Start entry and owns the `benchbar.exe` alias.

Logo files (all generated, 34 files): `Square44x44Logo` (44 and 88 px, plus `targetsize-N` and `targetsize-N_altform-unplated` for N in 16, 20, 24, 30, 32, 36, 40, 48, 60, 64, 72, 80, 96, 256), `Square150x150Logo` (150 and 300 px) and `StoreLogo` (50 and 100 px). The Store listing also wants its own images in Partner Center (a 1:1 300 x 300 icon, screenshots). Learn says the Medium tile at 100% is the minimum for publishing. Without `-MakePri` there is no `resources.pri`, so Windows may not choose the `scale-` and `targetsize` files: check the icons in the taskbar and Start.

## Run the spike on a Windows 11 PC

Needs: Windows 10 22H2 or Windows 11, Developer Mode is not required for the signed route, Go (see `windows/shim/go.mod`), the .NET 10 SDK (see `windows/tray/global.json`), and the Windows SDK (MakeAppx.exe, signtool.exe, MakePri.exe). The script stops with a clear message when the SDK is missing.

```powershell
git clone https://github.com/askysh/benchbar; cd benchbar
git checkout spike/windows-msix        # or the branch the maintainer names
cd windows\msix
.\build-msix.ps1                       # x64, self signed, prints the commands below
.\build-msix.ps1 -MakePri              # same, with resources.pri for the logos
```

It prints the exact commands. In short:

```powershell
# elevated PowerShell (Run as administrator): trust the test certificate
Import-Certificate -FilePath .\out\BenchBar-Spike-Test.cer -CertStoreLocation Cert:\LocalMachine\TrustedPeople
# normal PowerShell: install
Add-AppxPackage -Path .\out\BenchBar_0.0.1.0_x64.msix
# uninstall
Get-AppxPackage BenchBar.Spike | Remove-AppxPackage
```

Other modes:

- `.\build-msix.ps1 -FrameworkDependent` builds the small tray (for the size note only).
- `.\build-msix.ps1 -Mode Store -Version 0.8.2 -IdentityName ... -Publisher ... -PublisherDisplayName ...` makes `out\*.msix` per CPU, `out\*.msixbundle` and `out\*.msixupload`, all unsigned. These values come from Partner Center.
- Loose layout, no signing, Developer Mode on: `Add-AppxPackage -Register .\out\pkg-x64\AppxManifest.xml`.
- GitHub: Actions, MSIX spike, Run workflow.

Remove the test certificate afterwards (the script prints the lines). It is trusted machine wide while it is in `TrustedPeople`.

## Test checklist

Copy this table into the report. For each row write pass or fail, and what you saw. Note the Windows build (`winver`), the CPU, whether Smart App Control is Off, Evaluation or On, and the PackageFamilyName (`Get-AppxPackage BenchBar.Spike`).

| # | Check | How | Expect (docs) or hypothesis |
| --- | --- | --- | --- |
| 1 | Install | Commands above. Note any error code. | Installs. Add-AppxPackage fails with 0x800B0109 or similar if the certificate is not trusted. |
| 2 | Start menu | Start, type BenchBar. | One entry, "BenchBar". No entry for "BenchBar command line" (AppListEntry none). Check the icon at several sizes. |
| 3 | Alias in a terminal | New cmd and new PowerShell: `where.exe benchbar`, `benchbar --shim-version`. | Path under `%LOCALAPPDATA%\Microsoft\WindowsApps\benchbar.exe`. Prints the version. |
| 4 | Alias from a non interactive parent | `cmd /c benchbar --shim-version`. `python -c "import subprocess;print(subprocess.run(['benchbar','--shim-version'],capture_output=True,text=True))"`. Node: `node -e "console.log(require('child_process').spawnSync('benchbar',['--shim-version']).stdout.toString())"`. A process started by another GUI program (for example VS Code's terminal, a Claude or Cursor MCP client). Also with a stripped environment: `cmd /c "set PATH=C:\Windows\System32&& %LOCALAPPDATA%\Microsoft\WindowsApps\benchbar.exe --shim-version"`. | Output captured. Hypothesis: works, because CreateProcess resolves the alias. Not documented by Microsoft in what I found. |
| 5 | stdio passthrough | `echo {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}} \| benchbar mcp` then run the same with `out\stage-x64\benchbar.exe` and compare. Also `benchbar status --json > a.json` against the stage exe (`fc`). Also `benchbar nosuchcommand` then `echo %ERRORLEVEL%` (and `$LASTEXITCODE`). Pipe a large output: `benchbar doctor --json \| find /c /v ""`. Ctrl+C a long `benchbar logs`. | Same bytes, same exit codes, stdin EOF ends the process, no console window pops up. The alias is a stub that Windows resolves, so a difference would be a finding. |
| 6 | Tray starts | Start menu. Icon in the notification area, right click menu, open the window. In Task Manager, see that `benchbar.exe` runs as a child with the package path (`C:\Program Files\WindowsApps\...`). | Tray runs. It finds `benchbar.exe` next to itself. Status polling works. |
| 7 | Where config.json and tray.log land | Before and after: `dir $env:LOCALAPPDATA\BenchBar` and `dir "$env:LOCALAPPDATA\Packages\<PackageFamilyName>\LocalCache\Local\BenchBar"`. Run `benchbar adopt-distro` (writes config.json) from the alias, then open the tray Settings. Then run `out\stage-x64\benchbar.exe setup check --json` (unpackaged) and see if it reads the same distro. Repeat with a config.json that existed before the install. | Learn: on Windows 10 1903 and later, new files under `Local` (and `Local\Microsoft`, `Roaming`, `Roaming\Microsoft`, `Roaming\Microsoft\Windows\Start Menu\Programs`) go to the per package private store. Existing files are opened in place. The packaged shim and tray share it. An unpackaged copy does not. Explorer does not show the private files. A rename over an existing real file may create a new private copy: look for two diverging config.json files. |
| 8 | Startup task and consent | Task Manager, Startup apps: "BenchBar" should be listed as Disabled. Settings, Apps, Startup. Turn it on, sign out and in. Then set `Enabled="true"` in the template, rebuild, reinstall and see if it starts enabled after the first launch. Turn it off in Task Manager and see if the tray can turn it on again (it cannot, by the docs). | Learn: the user can disable the task in Task Manager and the app cannot re-enable it. The spike tray does not call `RequestEnableAsync` (no code change), so only the manual route is tested. |
| 9 | Single instance and named events | Start the tray from the Start menu. Start `out\stage-x64\BenchBarTray.exe` (unpackaged). Does the second one exit and raise the first? Look in WinObj (Sysinternals) at `\Sessions\1\BaseNamedObjects` for `BenchBarTray`, `BenchBarConfig`. Try `uap17:BaseNamedObjectsIsolation` only if they are not shared. | Hypothesis: a full trust package uses the normal namespace, so the mutex and events are shared with unpackaged processes. The manifest has an attribute for isolating them (none or package), so the default is worth confirming. |
| 10 | UAC for wsl.exe | On a PC where it is safe: `benchbar setup run wsl_enable --jsonl` from the alias. | UAC prompt, hidden elevated `System32\wsl.exe --install --no-distribution`, `done` line with the exit code. Hypothesis: ShellExecute runas works from a packaged full trust process. Not documented. Store policy risk is separate. |
| 11 | schtasks from a package | `benchbar keepalive install`, then `schtasks /Query /TN "BenchBar Keepalive" /XML` and look at `<Command>` and `<Arguments>`. Then `schtasks /Run /TN "BenchBar Keepalive"` and `schtasks /Query /TN "BenchBar Keepalive" /V /FO LIST` for Last Result. Then edit the task to run `%LOCALAPPDATA%\Microsoft\WindowsApps\benchbar.exe keepalive run` directly, then via `cmd.exe /c`. | Task creation works (Task Scheduler is not virtualized). Hypothesis: the task holds the real package path (`os.Executable` gives the real path), and it fails ("the file cannot be accessed by the system") and breaks on every update. Community reports say the alias name or `cmd /c` works with "run only when user is logged on". Not confirmed by Microsoft. |
| 12 | .wslconfig | `benchbar wslconfig --suggest`, then `--apply --yes`. Open `%UserProfile%\.wslconfig` in Notepad and look for the backup. | Learn: only AppData and HKCU are virtualized. A file in the profile root is real. Expect the change to be visible everywhere. |
| 13 | Lxss registry | `benchbar setup check --json` from the alias and from the stage exe. Diff the output. | Same output. HKLM and HKCU reads merge the real and the private hive, so reads work. |
| 14 | HKCU writes | `benchbar path install` from the alias, then in a new unpackaged cmd: `echo %PATH%`, `reg query HKCU\Environment /v Path` (unpackaged) and from the alias `benchbar path status`. | Learn: all HKCU writes go to a private per app location. Expect the PATH change not to appear outside the package. This is why the shim must skip `path install` in a package. Remove with `benchbar path remove`. |
| 15 | \\wsl.localhost | Tray, a bench, Open Folder (Explorer). `benchbar adopt \\wsl.localhost\Ubuntu-24.04\home\<user>\frappe-bench --dry-run`. | Opens. UNC paths are not AppData, so no virtualization. |
| 16 | .NET runtime | On a PC or VM with no .NET 10 runtime (`dotnet --list-runtimes`): install the self contained package and start the tray. Note the `.msix` size from the script output and the installed size (`Get-ChildItem -Recurse` of InstallLocation). Optional: the `-FrameworkDependent` build on a PC that has the runtime. | Self contained starts anywhere. A framework dependent package cannot install the runtime for the user: Learn and community answers say to ship self contained. |
| 17 | H.NotifyIcon and notifications | The icon shows, the menu works, it survives an Explorer restart (`taskkill /f /im explorer.exe`, then `explorer`). Trigger a balloon (stop a bench). Settings, System, Notifications: is "BenchBar" listed with its logo? | Hypothesis: unchanged from the unpackaged build. Package identity gives the app a proper notification entry. Windows App SDK app notifications are not supported for elevated apps, and the tray is never elevated. |
| 18 | Smart App Control | Record the state. With the state On, Add-AppxPackage of the self signed package. | A self signed package is not Store signed. Do not read a pass or fail as the Store result. Only a certified package shows that. |
| 19 | Upgrade | Build `-Version 0.0.2`, `Add-AppxPackage` over the first. | State kept. Alias still works. The keepalive task from row 11 now points at a folder that is gone. |
| 20 | Uninstall | `Get-AppxPackage BenchBar.Spike \| Remove-AppxPackage`. | Package files, the alias, the startup entry and the private AppData and HKCU are removed (Learn). The scheduled task from row 11 and any change outside the package (`.wslconfig`) stay. |
| 21 | Coexistence | With the zip install present (`install.ps1`) and the package installed: `where.exe benchbar`, `benchbar.exe doctor`. | Alias first. Doctor warns about another `benchbar.exe`. Start both trays and see that only one stays. |

Report any row as "blocked" with the reason, not as a guess.

## What is verified and what is assumed

Verified in Microsoft Learn (see Sources):

- Full trust manifest shape (`runFullTrust`, `uap10:RuntimeBehavior="packagedClassicApp"`, `uap10:TrustLevel="mediumIL"`), `TargetDeviceFamily Windows.Desktop`, one package per CPU.
- The app execution alias (`uap3:Extension Category="windows.appExecutionAlias"` with `desktop:ExecutionAlias`), one alias per Application, the last registered wins, the user can switch it off in Settings.
- The startup task (`desktop:Extension Category="windows.startupTask"`), `Enabled`, the user can disable it in Task Manager and the app cannot re-enable it. The user must run the app once before the task is registered.
- AppData and HKCU virtualization rules, the package is read only, uninstall removes redirected writes. HKLM writes in a package fail.
- Self signed certificate subject must equal the Publisher. The certificate must be in `TrustedPeople` (machine) to install. Store signs Store packages. Apps that require elevation are not accepted into the Store.
- `uap10:Parameters` exists for desktop apps with identity. `.msixupload` is a zip of the packages or a bundle. Medium tile at 100% is required for publishing.

Assumed, from memory or inference, and to be confirmed:

- Alias stdio, pipes and exit codes behave like a normal process (rows 4 and 5).
- The mutex and named events are shared by default (row 9). `GetCurrentPackageFullName` is the right check for identity.
- `runas` from a package works (row 10). A task through the alias works (row 11).
- The Store reserves the fourth part of the version (the script enforces 0).
- A reserved name expires if you do not submit. Review takes a few business days. The privacy URL must be public.
- The self contained size (about 70 MB per CPU) is an estimate.
- Whether the Windows 10 S compatibility rule from the packaging notes still gates submissions, and whether a certification tester can run the setup wizard without WSL.
- Whether `win32App` runtime behavior would avoid virtualization without `unvirtualizedResources`. Not tried. The manifest keeps `unvirtualizedResources` only as a commented fallback.

## Sources

- Packaging a desktop app manually (manifest shape, MakeAppx, certificate): https://learn.microsoft.com/en-us/windows/msix/desktop/desktop-to-uwp-manual-conversion
- How packaged desktop apps run (virtualization, install, uninstall): https://learn.microsoft.com/en-us/windows/msix/desktop/desktop-to-uwp-behind-the-scenes
- Prepare to package (elevation not accepted in the Store, HKLM, AppData, starting utilities): https://learn.microsoft.com/en-us/windows/msix/desktop/desktop-to-uwp-prepare
- Packaging extensions (alias, startup task): https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/desktop-to-uwp-extensions
- `uap5:ExecutionAlias`: https://learn.microsoft.com/en-us/uwp/schemas/appxpackage/uapmanifestschema/element-uap5-executionalias
- `desktop:StartupTask`: https://learn.microsoft.com/en-us/uwp/schemas/appxpackage/uapmanifestschema/element-desktop-startuptask
- `Application` element (`uap10` attributes, `Parameters`, BNO isolation): https://learn.microsoft.com/en-us/uwp/schemas/appxpackage/uapmanifestschema/element-application
- Capabilities, restricted capability approval, `runFullTrust`, `unvirtualizedResources`: https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/app-capability-declarations
- Microsoft Store Policies 7.20 (10.1.1, 10.2.2, 10.2.3, 10.2.4, 10.2.7, 10.2.8, 10.5.1): https://learn.microsoft.com/en-us/windows/apps/publish/store-policies
- Open a developer account (individual, no fee, ID and selfie): https://learn.microsoft.com/en-us/windows/apps/publish/partner-center/open-a-developer-account
- Packaging MSIX apps (package types, upload file, Store signing): https://learn.microsoft.com/en-us/windows/msix/package/packaging-uwp-apps
- MakeAppx: https://learn.microsoft.com/en-us/windows/msix/package/create-app-package-with-makeappx-tool
- Certificate for package signing: https://learn.microsoft.com/en-us/windows/msix/package/create-certificate-package-signing
- App icon assets: https://learn.microsoft.com/en-us/windows/apps/design/iconography/app-icon-construction
- Smart App Control: https://learn.microsoft.com/en-us/windows/apps/develop/smart-app-control/overview
- winget install (msstore source): https://learn.microsoft.com/en-us/windows/package-manager/winget/install
- App notifications (not for elevated apps): https://learn.microsoft.com/en-us/windows/apps/develop/notifications/app-notifications/app-notifications-quickstart
- Community, not Microsoft: task scheduler and aliases, https://techcommunity.microsoft.com/t5/msix/msix-app-execution-alias-from-cannot-be-selected-from-task/m-p/3805369 ; .NET runtime in MSIX, https://github.com/dotnet/runtime/discussions/100880
