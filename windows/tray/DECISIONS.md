# Windows tray decisions

One line per non obvious choice. The 0.8.0 spike that chose WPF over WinUI was deleted in 0.9.0; its numbers are below, and git history keeps the code at `3de8812`.

## Spike: the shell (0.8.0)

- **The tray app is WPF on .NET 10 with the Fluent theme**, chosen under the rule below (2026-10-10, PR #70). Laptop (Ryzen 7 6800H, Windows
  11 26300, medians of 5): private bytes at rest WPF 16.7 MB, WinUI 73.5 MB; CPU while animating WPF 0.94%, WinUI 1.12% of one core, both at
  21 fps; click to flyout 4.7 and 12.1 ms; logon to icon 316 and 194 ms cold; the rule picks WPF. windows-latest: private bytes 16.6 and
  23.6 MB; CPU not comparable by the rule (WinUI animated at 25.5 fps, WPF at 20.9), a tie per frame. Deployment points the same way:
  framework dependent WPF needs the .NET 10 Desktop Runtime (25.5 MB), WinUI also the Windows App SDK runtime (94.8 MB); self contained
  186.5 and 276.1 MB.
- Decision rule, fixed before any numbers existed: choose the shell with the lower private bytes at rest and CPU while animating, unless click to flyout is above 150 ms or logon to icon is above 2 s for that shell. A difference under 10% on a metric is a tie. On an overall tie, prefer the shell with less deployment friction on a clean Windows 11.
- The shell is the only variable: both shells use one shared library (`spike/Tray.Core`) for the state model, the poller, the frame sequencer, the icon frames and the harness pipe, H.NotifyIcon for the icon (`.WinUI` and `.Wpf`), and the same flyout policy.
- Runner frames are drawn to an HICON at run time, not exported to an `.ico` per frame: the tray slot's pixel size follows the taskbar
  monitor's DPI and can change while the app runs (16, 20, 24 or 32 px), the template runner is tinted for the taskbar's light or dark
  theme, custom runners are PNG folders loaded at run time anyway, and no Mac or Swift step enters the Windows build. Each frame is drawn
  once per (size, tint) and cached; an animation tick only swaps the cached handle with `NIM_MODIFY`.
- Visual Studio 2026 has no `Microsoft.VisualStudio.Workload.WinUI`: "WinUI application development" is `Microsoft.VisualStudio.Workload.Universal` (the old UWP id, renamed). The preflight check uses that id, and installing it fails with exit code 8006 while Visual Studio or any MSBuild process runs (`--passive` answers the "close these processes" prompt with Cancel).
- `benchbar` is on PATH only in a login shell inside the distro (`~/.local/bin` comes from `~/.profile`), so the fixture was recorded with `wsl.exe -d Ubuntu-24.04 -- bash -lc 'benchbar status --json'`. The shim must start a login shell, or call the CLI by its full path.
- Smart App Control is on and enforcing on the development laptop and blocks freshly built, unsigned binaries now and then (`0x800711C7`, Code Integrity events 3077 and 3033). A clean Windows 11 with Smart App Control on would block an unsigned tray app outright, whichever shell is chosen, so the shipped app needs code signing; that is out of this spike's scope and does not change the comparison.
- The harness checks the frame rate each shell actually achieves (`stats` over the pipe, answered by Tray.Core for both), because a cheaper
  CPU number would mean nothing if one shell drew fewer frames. Both reach 21.3 fps at the 30 fps target: a one shot dispatcher timer of 33
  ms waits for the next 15.6 ms system timer tick, so it fires every 46.9 ms. The real app accepts the steps (64, 32, 21.3 fps) instead of
  calling `timeBeginPeriod`, which raises timer resolution for the whole process and costs power.
- Icon order is the same in both shells: the controller and the first runner frame exist before `NIM_ADD`, so "icon added" means a runner is visible. It is reported from H.NotifyIcon's `TrayIcon.Created`, which fires after `Shell_NotifyIcon(NIM_ADD)` succeeded.
- Both shells call H.NotifyIcon's `ForceCreate()` with its default, which puts the process in Windows efficiency mode (EcoQoS, idle priority). Neither shell leaves it when the flyout opens, so both are measured in efficiency mode for every metric, clicks included: equal, and if anything pessimistic for the click. The real app should leave efficiency mode while the flyout is open.
- The WinUI shell's right click menu uses H.NotifyIcon's `ContextMenuMode.PopupMenu`, not `SecondWindow`: `SecondWindow` builds a hidden
  XAML window (`WinUIDesktopWin32WindowClass` plus a popup bridge) when the icon is created, which broke "no window at startup" and cost 25
  MB private at rest (98.8 MB with it, 73.7 MB without, one run each). Found by counting each shell's top level windows at rest; WPF's
  `ContextMenu` gets its window only when it first opens.
- Both shells stamp the flyout's first frame the same way on every open, the first one included (the first `CompositionTarget.Rendering` after `Show` or `Activate`), and rebuild the bench rows only when a poll changed something. The click gate uses the warm opens; the cold first open is reported apart.
- The harness sets `BENCHBAR_TRAY_REDUCE_MOTION=0` for both shells: the windows-latest runner has animation effects off, so its first measured run showed a still frame (0 fps) and the CPU "while animating" was idle CPU. The verdict now refuses the CPU comparison unless both shells reach 15 fps and are within 10% of each other.
- WinUI's private bytes at rest depend on the graphics driver: 23.6 MB on the CI runner (a basic display adapter) and 73.5 MB on the laptop (AMD and NVIDIA drivers), while WPF is 16.4 and 16.7 MB on both. The XAML compositor sets up its Direct3D device even with no window shown. The laptop is the representative number: a real user has a GPU driver.
- The cold logon variant on CI also purges the standby list (the runner is elevated): 1.5 s (WPF) and 1.8 s (WinUI) medians, with one WinUI run at 8 s. The laptop variant (working sets only, not elevated) gives 0.32 s and 0.19 s. Both pass the 2 s gate on the median; real logon to icon is measured by hand.
- `BENCHBAR_TRAY_THEME=light|dark` forces both the flyout theme and the runner's tint, so light and dark can be tested without changing the Windows theme. The real app should have the same as a setting (Appearance: System, Light, Dark), with System following `AppsUseLightTheme` for the flyout and `SystemUsesLightTheme` for the runner (Akash, 2026-10-10).
- Real logon to icon is measured across a real sign in: each shell started from the Startup folder with `--logon-log <file>` appends when its icon was added, and the sign in time is the Winlogon 7001 event in the System log (logged when the session starts, 0.7 s before Explorer here). It leaves out the moment between pressing Enter and Windows accepting the password.
- CI runs the 25 minute measurement only when started by hand (Tray spike, Run workflow); pull requests and pushes build and test only, and the workflow is path filtered to `windows/tray/spike/**`, so the real tray app's pull requests never wait on it (Akash, 2026-10-10).

## v1: the tray app (0.8.0)

- The app is `windows/tray/BenchBarTray` with `Tray.Core` promoted out of the spike (copied, then grown); the spike was kept as measured until 0.9.0 and then deleted (`spike/` and `tray-spike.yml`). One solution, `BenchBarTray.sln`, classic format as asked.
- The promoted `PollerTests.StartPollsAtOnceAndReportsTheBenches` failed every time on the laptop (2026-10-29) and passed on CI by timing: the probe's `Updated` handler was subscribed before the test's own, released the waiting test, and the test read the result before its handler ran. The promoted test reads `poller.Last`; the spike keeps the bug (Akash, 2026-10-29: the spike stays untouched).
- Every fact comes from `benchbar.exe` (next to the tray exe first, then PATH). The spike's `wsl.exe bash -lc` fallback is gone: one path to the CLI, and the shim's one line fixes (no distro, no benchbar inside it) reach the flyout as text.
- Before any `list` or `status` the poller asks `wsl.exe --list --running --quiet`, which never boots a distro (`-d` would). While the distro is stopped the tray makes no shim call at all and the probe backs off 30, 60, 120, 300 s (5 s with the flyout open): a `status` call boots the distro and would fight `vmIdleTimeout`. Keeping the distro up is the keepalive task's job, not the tray's.
- The flyout's Start for a stopped distro starts `benchbar.exe keepalive run` detached and hidden, the same program the keepalive task runs; its named mutex keeps it to one run, and it outlives the tray. The poller then polls every 2 s until the distro answers.
- A failed `list` skips the status calls of that poll and shows the benches it knew as unknown with the problem line, so a missing shim costs one timeout, not one per bench.
- After `up`, `down` or `restart` the poller polls every 2 s for 60 s: stopping has no state of its own in `status --json`, so a time window stands in for it.
- `paused` (crash guard, broken or port conflict) holds the alert pose without the stumble; only `crashed` stumbles three times. A setup problem shows the unknown pose, a stopped distro the sleeping one.
- An unknown `state` keeps its raw name and shows as "unknown (NAME)", unknown fields are ignored, `site: null` shows "no site": Session 5 adds `not_adopted`, `pending_operations`, `redis` and `sites[].served` while this is built, and neither side waits for the other.
- There is no CPU source on Windows yet (a Windows process cannot sample processes inside WSL and `status --json` carries no load), so the running loop plays at speed 1. `ILoadSource` and the Mac's speed mapping stay unused for the icon: the CLI reports load now (`stats`), and the Overview charts it, but the icon stays at 1 to keep nothing running at rest.
- Toasts: one per bench when it enters crashed, paused by the crash guard, paused by a port conflict or paused broken, with the fix line.
  The first good snapshot only seeds (no toast for a state found at launch, as on the Mac); unknown, distro stopped and problem snapshots
  never reset the memory, so crashed, unknown, crashed is one toast. Turned off, the policy keeps tracking, so turning it on does not replay
  old news.
- Toasts go through the tray icon's own notification (`Shell_NotifyIcon` with `NIF_INFO`), which Windows 10 and 11 show as a toast under the app's name: no AppUserModelID registration, no Start menu shortcut and no extra package.
- `config.json` is the shim's file; the tray writes only its `tray` object and keeps every other key, at the top level and inside `tray`, atomically. A file that is not JSON loads as defaults and is copied to `config.json.bad` before the first save, so the shim's keys are never lost silently.
- Custom runners use the Mac's manifest and rules unchanged (36 px tall frames), scaled to fit the square tray slot with the aspect kept; Windows adds refusals for reserved device names and any reparse point in the folder. Frames are decoded when drawn, not held in memory.
- `up`, `down` and `restart` return the exit code and the shim's first stderr line; a failure shows under that bench's row until its state changes, and the button comes back for a retry. A bench in an unknown state (`not_adopted`) gets no Start, Stop or Restart: the CLI would refuse it.
- The flyout rebuilds a row only when its path, name, state, raw state, stop reason, site, URL, busy flag or failure line changed, and keeps the keyboard focus on the same bench: a poll that changed nothing touches no visual.
- Report a Bug shows a message instead of running `report` while the distro is stopped: the zip is written inside the distro, and the call would boot it.
- Efficiency mode (H.NotifyIcon's default) is left while the flyout, a Logs or a Doctor window is open and restored when the last one closes, so a click is not served at idle priority.
- Single instance through a named mutex; a second start signals the first to open its flyout and exits.
- The Startup shortcut is `BenchBar Tray.lnk`, written through `IShellLinkW`: the name the shim's doctor and `install.ps1` look for.
- Measured 2026-10-29 on the laptop (Ryzen 7 6800H, RTX 3070 Ti; the display ran at 2560 by 1440 and 100 percent scaling that day, not the
  1920 by 1080 at 125 percent the brief named), framework dependent Release build, the spike's harness pattern (the app's own pipe, 20 s
  warm up, 60 s window, medians of 5): at rest with the benches stopped 17.0 MB private, 0.08 percent of one core; the real frappe-bench
  running (the running loop at 4.8 fps) 17.4 MB, 0.57 percent; the spike's load fixture (21.1 fps) 18.9 MB, 0.93 percent. The spike's WPF
  shell measured with the same script: 17.4 MB at rest. Both targets (under 20 MB at rest, under 1.5 percent animating) hold until the
  flyout first opens.
- The first build measured 39.8 MB at rest: the right click menu was built at startup, and building it loaded WPF's render stack (wpfgfx, d3d9 and the NVIDIA user mode driver). The menu is now built on the first right click (`TrayRightMouseDown`, `TrayKeyboardContextMenu`, `PreviewTrayContextMenuOpen`). Found by stopping startup at each step and comparing loaded modules.
- Once the flyout has opened, WPF keeps d3d9 and the GPU driver loaded for good, even in software rendering (it creates the device to read
  the render tier): 62.6 MB private after one open with hardware rendering. `RenderMode.SoftwareOnly` (the flyout is plain 2D; the acrylic
  is DWM's) and closing a flyout that stayed hidden for 30 s, with a compacting collection, bring that to 42.7 MB (3 runs). The remaining 25
  MB is native WPF and driver memory no in process switch frees; the way below 20 MB after use is a flyout in a short lived second process,
  left for later. `BENCHBAR_TRAY_GPU=1` turns hardware rendering back on for comparison.
- Click to flyout on the laptop: warm 30 to 54 ms, after the 30 s release 15 to 17 ms, the first open of a process 321 to 353 ms (the spike's WPF shell: 266 to 273 ms first, 14 to 16 ms warm). The first open loads the render stack and the Fluent theme; ReadyToRun did not change it (tried, removed: it only grew the download).
- The harness `stats` reply also carries `gc_heap` and `gc_committed`, so a measurement can split managed from native memory without a diagnostics tool.
- The test host's `Post` takes a lock that the tests' own UI calls take too, as a dispatcher would serialize them: `RunnerIcons` is UI thread only, and running posted work inline on the poller's thread made two controller tests fail now and then with "Collection was modified".
- The flyout is placed again from its real window rectangle after `Show`: the measure before the first show ran without the theme's template and gave 80 DIP for a 123 DIP flyout, so the bottom of the flyout covered the taskbar. Found in the first screenshot.
- A distro probe that fails or times out is a snapshot problem ("wsl.exe did not answer"), never a reason to call the shim: calling it would boot the distro. A missing `wsl.exe` says "WSL is not installed: wsl.exe --install".
- Timeouts per command: `up`, `down` and `restart` 180 s (a cold `up` waits up to 45 s for the site, `restart` adds the stop), `report` and `doctor` 120 s, `list`, `status` and `logs` 30 s. A timed out action is a failure line under its row ("may still be starting"), and the fast poll window keeps running.
- The snapshot's problem is only a missing shim, a failing `list` or a failing probe. One bench whose `status` fails is unknown with its own line under its row, so the other benches keep their icon state and their toasts.
- `TrayConfig.Save` re-reads `config.json` and replaces only the `tray` object, and `distro` is read again whenever the file changes: an `adopt-distro` while the tray runs is never reverted, and the probe follows the new distro. A file that cannot be read is never overwritten.
- A duplicate JSON key counts as invalid JSON (`JsonStrict`): System.Text.Json reports it only when the member is first read.
- Runner folders are checked for links and size before the manifest is read, and the manifest's size before it is read.
- Open in VS Code refuses a distro name or bench path with a cmd metacharacter or a quote: `code.cmd` runs inside cmd.exe, where argument quoting does not stop `&`, `|`, `^` or `%VAR%`.
- Toasts seed only from a snapshot with at least one bench in a known state.
- The flyout raises Opened before `Show` and Hidden only after an Opened, so a deactivation during `Show` cannot leave efficiency mode off or the poller at the flyout rate. Report a Bug asks the probe afresh before running `report`, which would boot a stopped distro.
- The unused Doctor console (`cmd /k`) was removed; the Doctor window is the only doctor in the tray.
- `config.json` is replaced with up to ten short retries: Windows refuses the replace while another process holds the file without delete sharing (an antivirus scan, the indexer, the shim reading it). Found as a test that failed one run in twenty.
- Controller tests dispose the controller and advance the fake clock only after a poll has reported (its timer is armed by then), on the same lock that stands in for the UI thread; three tests failed one run in about seven before that, and none in 30 runs after.

## The release path (0.8.0)

- A zip per CPU plus `install.ps1`, no MSI and no Inno Setup in v1: both add a toolchain and a second file to sign, and a zip plus a script matches `install.sh`. winget comes after the first signed release (an unsigned package gets SmartScreen warnings there too).
- `release-windows.yml` is its own workflow; release.yml stays as it is. It attaches to the draft release.yml creates for the tag. On a tag
  push it waits up to 130 minutes (release.yml's macOS job allows 120) and creates a draft only when none appears, with a warning that a
  later release.yml run replaces the notes, so this workflow must be re-run afterwards. A manual run needs the draft to exist and fails
  otherwise. It never publishes.
- The Windows sums file is `benchbar-windows-X.Y.Z-SHA256SUMS.txt`, not `SHA256SUMS`: the Mac release already has an asset with that name, and `install.sh` takes the first asset whose name ends in `SHA256SUMS`.
- Signing through SignPath runs only when `SIGNPATH_API_TOKEN` and `SIGNPATH_ORGANIZATION_ID` exist and the run builds the release tag (tag
  push, or dispatch with `draft_release` on); never on pull requests or for an artifact only dispatch. It covers the project's own binaries
  only (`benchbar.exe`, `BenchBarTray.exe`, `BenchBarTray.dll`, `BenchBar.Tray.Core.dll`), because SignPath Foundation signs a project's own
  code, not NuGet libraries. It is best effort: a signed file replaces the unsigned one only when `Get-AuthenticodeSignature` says Valid
  (and, for an exe, its PE machine type matches the zip's CPU). A broken signature never ships.
- The README and the release notes list what `Get-AuthenticodeSignature` says about every `.exe` and `.dll` in the zip, read after the swap: third party DLLs (H.NotifyIcon) show as not signed by this project, Microsoft's as signed. "Every file is signed" is written only when it is true.
- A run that attaches to a release checks out `refs/tags/vX.Y.Z` and fails when the tag is missing, so a manual run can never put the wrong
  commit into a release. `draft_release` defaults to off: an artifact only dispatch builds the dispatched ref and is never signed. The
  package job has `contents: read` and `actions: read` (SignPath's action downloads the unsigned artifact with the GitHub token); only the
  release job has `contents: write`, and it runs on ubuntu so the long wait is cheap.
- No release step signs anything (2026-11-19, issue 135). The SignPath steps, the `SIGNPATH_*` secret checks, the 360 minute timeout, the
  `actions: read` grant and the `SIGNING_REQUIRED` gate left `release-windows.yml`, because SignPath Foundation declined the project and
  nothing could ever run them. `Get-AuthenticodeSignature` stays: the package job records it per file in `signing-ARCH.json` and README.txt
  and the release notes quote it, so a download says what is unsigned. A future signing route comes back as its own job.
- The README and the release notes list what `Get-AuthenticodeSignature` says about every `.exe` and `.dll` in the zip, read after the swap: third party DLLs (H.NotifyIcon) show as not signed by this project, Microsoft's as signed. "Every file is signed" is written only when it is true.
- A run that attaches to a release checks out `refs/tags/vX.Y.Z` and fails when the tag is missing, so a manual run can never put the wrong commit into a release. `draft_release` defaults to off: an artifact only dispatch builds the dispatched ref. The package job has only `contents: read`; only the release job has `contents: write`, and it runs on ubuntu so the wait for the Mac draft is cheap.
- Every exe's PE machine type (0x8664, 0xAA64) is checked before packing, so an amd64 build cannot land in the Arm64 zip.
- The workflow skips the tray with a warning when `windows/tray/BenchBarTray` is missing on the checked out ref, so it does not depend on the order the tray and release pull requests merge.
- `workflow_dispatch` works only once the file is on main, so pull requests that change the workflow or `install.ps1` build both zips and run the installer on windows-latest (PowerShell 7, then Windows PowerShell 5.1 as an update, plus a refused bad checksum) without touching releases.
- `install.ps1` replaces only files an earlier install wrote (`.installed-files.txt` in the install folder), renames a locked exe (a running
  keepalive holds `benchbar.exe`) to `.old` before the new copy goes in, and closes a running tray only by its exact path, never by name.
  Native programs run with `ErrorActionPreference=Continue`, because Windows PowerShell 5.1 turns their stderr into a terminating error
  under `Stop`.
- `install.ps1` runs inside one script block, so piped into `iex` it leaves no variable or function behind and cannot overwrite the user's
  `$Version` or `$Source`; the file form still takes `-Version`, `-NoTray`, `-Yes` and `-Source`. It picks the zip from
  `RuntimeInformation.OSArchitecture` (the machine's CPU, so x64 PowerShell emulated on Arm64 installs the arm64 zip), checks the .NET
  runtime in the same two places as `benchbar.exe doctor`, and when `benchbar.exe` cannot start (Smart App Control, an antivirus) says so
  plainly and exits 1 before any PATH write. A tray app it closed is started again whatever fails.
- Shim: `benchbar.exe doctor` gains `dotnet_desktop` and `tray_logon` (text form only) when `BenchBarTray.exe` sits next to it, about 50 lines. A missing runtime is a warning, so the optional tray never makes doctor exit 1; the check proves the shortcut and the tray exe exist and does not read the shortcut's target. Recorded here because docs/DECISIONS.md belongs to the CLI session this week.
- The code signing policy in docs/windows.md is written in SignPath Foundation's required form and marked pending until the application is approved.
- Test builds go to testers by hand before any release, unsigned (Akash, 2026-10-29: no signing yet). Each zip carries `install.ps1`; run
  from the unpacked zip (benchbar.exe and SHA256SUMS beside it, no `-Version`, `-Zip` or `-Source`) it installs that folder, and `-Zip PATH`
  installs a zip downloaded by hand. Every file is checked against the zip's own SHA256SUMS, and a program file the list does not name is
  refused; that finds a damaged or half unpacked download, not a swapped one, so a checksums file next to a `-Zip` is checked as well when
  present and its absence is a warning. The signing steps stay in the workflow and run only once the SignPath secrets exist.
- Test builds go to testers by hand before any release, unsigned (Akash, 2026-10-29: no signing yet). Each zip carries `install.ps1`; run
  from the unpacked zip (benchbar.exe and SHA256SUMS beside it, no `-Version`, `-Zip` or `-Source`) it installs that folder, and `-Zip PATH`
  installs a zip downloaded by hand. Every file is checked against the zip's own SHA256SUMS, and a program file the list does not name is
  refused; that finds a damaged or half unpacked download, not a swapped one, so a checksums file next to a `-Zip` is checked as well when
  present and its absence is a warning. The workflow has no signing step.
- The wizard state is a plain model in `Tray.Core` (`WizardModel`) that the views only draw. Pages are built once and then refreshed, so a poll or log line never takes the caret out of a field.
- Passwords are `Secret`s (`SecureString`). They are read back only to fill the environment of the one child process, hidden in anything the child prints back, and never put in arguments, config or logs.
- The tray never runs `reboot` through the shim. It confirms, writes a one-shot Startup shortcut (`--resume-setup`, deleted when the tray starts with it) and runs `shutdown /r /t 15`, so `shutdown /a` still aborts it.
- The launch check never boots a stopped distro: no `--probe` outside the wizard, and a stopped distro skips the auto-open entirely. The wizard probes once, only after the distro exists.
- The bench folder is made absolute with `wsl.exe --exec printenv HOME`, because the shim's `sh -c` forwarding does not expand `~`.
- Stop on the Install page kills the process tree.
- The resume flag is removed whenever the wizard opens because of a resume, by either path (a direct start or a signal from a second instance). A restart that Windows refused keeps the flag, since a restart by hand still needs it.
- The Linux password typed in the wizard is never used for sudo when the shim's `distro_user` says `user_existed`; the install asks for the real one.
- Before an admin action the tray calls `AllowSetForegroundWindow(ASFW_ANY)`, so the Windows prompt comes to the front instead of flashing on the taskbar.

## Bench pages: the shared pieces

- Every page gets one `PageServices` (the CLI client and the shared sheets) in its constructor and never builds its own client or dialogs. Models that parse JSON live in `Tray.Core` and are tested with a `ScriptedStreamRunner`; views only draw them.
- `ICliClient` runs both one document calls and streams through `IStreamRunner`, so environment secrets (`SecretEnvironment`) work the same for both and tests need no process. A failed call (no shim, a refusal, a timeout) is a result, not an exception.
- The plan sheet reads any plan document generically (`steps[]`, `touches`, `errors`, `token`, `can_apply`, `changes`); what only one command has stays in `PlanDocument.Raw`. A refused token ("changed since it was shown") becomes the Stale phase with Refresh Plan, and nothing is applied twice.
- The sheet cannot be closed while an apply runs. Stop is offered only when the request says the run is safe to kill (a clone, not a restore or a migrate).
- Find Benches and Team Profiles are rows under the benches, not list items, so the bench list model and its tests stay as they were. A site row opens the Sites tab; a poll never changes the tab.

## Bench pages

- `PlanReviewRequest.RequiresToken` is true unless the CLI prints that plan without a token (`adopt`, `app update`, `site drop`); a request that sets it false confirms on the plan alone, and its apply call has no token to go stale.
- A `ports plan` document becomes plan steps (one per bench, the web port move or the service files, conflicts as the note); a blocked bench is an error, so Confirm stays off.
- Test fixtures are copied next to the test binaries by the csproj (`CopyToOutputDirectory`), and one `FixtureFiles` class (compiled into both test projects) finds them, so a build with an artifacts path outside the repository passes. Walking up from the binaries stays as the fallback.
- Start and Restart from the flyout go through `ports check` in `TrayController` (`TrayOptions.PortCheck`), as the Overview already did. The Overview passes `checkPorts: false` because it checked first and shows the conflict in its own guidance row. A refusal is one flyout line with where the fix is; nothing is killed.
- The Overview's Doctor button became Health and opens the Health tab. The flyout's Doctor button still opens the Doctor window.
- Demo mode (`BENCHBAR_TRAY_FIXTURES`) gives the pages a `FixtureCliRunner`: recorded answers for the read only calls from `fixtures/cli`, and a plain refusal for every other call, so the demo can never change a bench.
- Shared UI pieces live in one place: `PageParts.cs` (`PagePanels`, `PageMenuEntry`), `Ui.CriticalText` and `Ui.Mono`; the view tests share `PageKit.cs` and the model tests `CliFixture`.
- The Sites and Apps tabs show Add Site, Backups, Restore, Drop, Add App and Update as panels in the page, not dialogs. While Drop or Update runs the panel has no buttons and the tab is off, so it cannot be dismissed.
- The Administrator password is asked in the Add Site form and reaches the CLI only as `ADMIN_PASSWORD` in the environment of the plan and apply calls. The CLI has no generate option, so the tray offers none.
- Windows resolves `*.localhost` itself and the tray never edits a hosts file. A site whose name does not end in `.localhost` gets Set Up..., which offers adding it as `NAME.localhost`.
- Console and Database open Windows Terminal with `wsl.exe -d DISTRO --cd BENCH -- bench --site S console|mariadb`. Backup folders open as `\wsl.localhost\DISTRO\path` in Explorer, which is for opening only; data still comes from the CLI.
- The app list is read with `--no-sites` when the tab is first shown for a bench and after a change, never on a timer. Refresh asks for the live site lists. Check Remotes runs `app focus --fetch`.
- Restore takes a typed site name before the plan sheet. Encrypted and partial backups cannot be restored.
- The Health tab runs doctor and `setup check --json` (never `--probe`) once when first shown for a bench and on request, never on a timer; the repair sheet takes the Linux password once, up front, through the environment of that one run, and cannot be closed while it runs.
- The Overview adds no timer and no poll: uptime and Scheduler come from fields of the `status --json` the poll already reads, and `lock check` runs only when the Overview is the shown tab (once per bench, and on Check Again).
- The log viewer reads only through `logs --json`; Follow polls `--since` the last line's time every 2 s and only while the window is open, Follow is on and the current log is shown.
- Find Benches takes a Linux path in a text box with recent folders, not a folder picker, because benches live in WSL. A Windows path is converted with `wsl.exe wslpath -a -u`. Set Up Selected reads `ports plan` itself first, so a blocked plan is said in the pane and the plan sheet opens only for a plan that can be applied.
- Team Profiles Import and Export accept Windows file paths and convert them with wslpath before the CLI call. Show in Explorer opens `\wsl.localhost\DISTRO\...`.
- One SitesView, AppsView and HealthView serve every bench, so a panel remembers the bench it was opened for (`_panelBench`, `DropState.BenchPath`, `UpdateState.BenchPath`, `RepairModel.BenchPath`). Showing another bench closes the panels, and an action refuses to run when its captured path is not the bound one; the call always uses the captured path.
- The sudo password goes only to install, adopt (when the plan has sudo steps) and repair (when an action needs sudo). Ports apply never gets it: on Linux it runs nothing as root and the CLI checks the password up front. `SudoRuleTests` lists every place that can build the variable, so a new one fails until someone decides.
- `CliTimeouts.Apply` is infinite. Killing a restore, drop, update, add or repair part way is worse than waiting; only reads and plans time out. A long run shows its elapsed time and offers Stop only where the request says the run is safe to kill.
- Log Follow asks `wsl.exe --list --running --quiet` before each poll and pauses with "The distro stopped. Follow is paused." instead of booting the distro. Only turning Follow on again resumes it.
- Closing the main window during a page run asks first (default No). If the person closes anyway the run keeps going in the background and its result comes as a Windows notification. The window is not kept hidden, because the views are rebuilt on the next open.
- Terminal commands use `wsl.exe --exec` so no shell parses the words, site names pass `SiteNames.IsValid` before they reach a command, and `;` is written `\;` for wt.exe.
- A stale plan is recognised by the CLI's own refusal wording ("plan changed since it was shown", "The port plan changed.", "changed since it was reviewed"), not by the word "stale".
- Add App refuses a source or branch that starts with a dash. `--` before the positionals is not used where the plan sheet appends its own flags after the arguments.

## 0.8.1: beta, Report a Bug and the review fixes

- **BenchBar for Windows says it is a beta** in the window title, a "Beta" pill beside the app name (sidebar and About), the tooltip (`BenchBar (Beta): ...`), the Welcome page and a banner that stays until it is dismissed once (`tray.beta_banner_dismissed` in config.json). The wording lives in `BetaText` so the views and tests agree.
- **Report a Bug is one flow for every entry point** (tray menu, About, beta banner, wizard footer, every Report This Problem button):
  `benchbar.exe report-windows --json` with the configured distro, the bench selected in the window (never the first bench), a context line
  (`ReportContext`: entry point, window or wizard page, the failure beside the button), the tray version and `--include` of the tray error
  log. The shim works with no WSL, a stopped distro and no CLI, so the old "distro is stopped" refusal is gone. A second click while a
  report is written is ignored.
- **When benchbar.exe cannot start** (missing, SmartScreen, antivirus) or prints no report, the tray writes its own zip
  (`benchbar-tray-report-*.zip` in `%LOCALAPPDATA%\BenchBar\reports`, newest 10 kept: versions, Windows, context, the error, the tray log)
  and opens the same issue form with `versions`, `windows` and `what` filled. Names become `<user>` and paths `<path>` in the URL, which
  stays under 3900 characters.
- **Continue on Check Your PC reads each step's `blocking` flag**, not the shim's `ready`. A blocking step in `warn` counts as done, except "not checked" (the distro was stopped and the probe did not run). An older shim without the field gets it from the step id (linger, keepalive, wslconfig, shim_path are advice).
- **The tray cannot cancel the shim part way through `wsl_enable` in a way the shim could report**: the shim's context is never cancelled,
  and the tray ends it by killing the process tree. The elevated `wsl.exe` belongs to Windows and keeps running, so a cancel or the 10
  minute timeout says "Stopped waiting" and lets the next check decide; only the shim's own `reboot_required` result forces Restart Now. A
  restart an action asked for stays on screen until Windows has restarted (the check may not read the marker yet).
- **Stop Waiting on the plan sheet detaches the run instead of cancelling it**: the model stays alive, the sheet closes, and the result comes as a notification. The window close prompt counts it as a run in flight.
- **The wizard makes the distro it checked the shim's distro** (`adopt-distro NAME --json`, once per name, without `--yes` so the linger change is never applied silently). If that fails, Continue stays off and the line says why.
- **The Linux home folder is read, never guessed.** If `printenv HOME` fails and the wizard did not just create the user, Continue stays on the Check page with the reason.
- **An adopt asks for the Linux password only when its dry run has sudo steps**; if the plan cannot be read it asks, as before.
- **The first poll failing is not a new user.** The launch check opens the wizard only for a blocking step that is open, and not when the poll failed while benchbar is installed in the distro.
- **`_ = SomethingAsync()` became `.Forget()`** (`Observe`): a failure is written to the error log at once instead of whenever the task is finalized. The wizard models also catch a start failure of benchbar.exe, so no page stays on Running or Loading.
- **Rebuilt lists restore the focus by automation name**, and the plan sheet's clock only moves the elapsed time. Status and progress lines are polite live regions.

## 0.8.1: live QA on a real Windows 11 PC

- **The tray does not use InvariantGlobalization.** The Fluent ScrollViewer template asks for a specific culture, and with the invariant
  mode the XAML parse failed with "Cannot find non-neutral culture related to 'en-us'" about 35 times a second (the Check page never drew,
  the tray ran at 100 percent CPU). The flag came from the spike, where it kept the two shells' sizes like for like; the real tray has no
  size target for it, and the code already passes `InvariantCulture`/`Ordinal` wherever output is parsed or compared (a search of `ToLower`,
  `StartsWith`, `IndexOf` and number formats found nothing culture dependent). Re-measure private bytes at rest with the flag off before
  quoting the 17 MB figure again.
- **The error log writes an identical exception from the same place once a minute** and counts the rest ("repeated N more times since the last line"): a render or layout loop can throw faster than the 256 KB cap rotates, and the fix for the cause is not the log's job.
- **A left aligned panel with a MaxWidth shrinks to its widest child**, so wizard rows changed width from state to state. Each page now sits in `Ui.Constrain`: a star column with a MaxWidth (560, 640 or 720) next to an auto column, so the column is the same width in every state and never wider than the window. The wizard's scroll viewer never scrolls sideways.
- **An icon glyph with no brush was drawn in no color.** `Ui.Glyph` assigned `Foreground = null`, which is a local value that beats the inherited one; every glyph without a brush (More actions, the sidebar) was invisible while the ones with a status brush showed. It assigns only when it has a brush.
- **A step that is done shows no message**, and the detail line names the step it waits for by its title. The shim's keepalive line about another distro is rewritten on the Check page (the shim's text stays in the JSON).
- **WSL not having the distro is its own state** (`TraySnapshot.DistroMissing`, from `wsl.exe --list --quiet` after the running list said no). It has no Start, because starting nothing helps; the card offers setup or Settings.
- **Switching the distro in Settings asks first and kicks the poller**, so the sidebar shows the new distro's benches at once instead of after the idle back off.
- **The Windows restart question is a themed dialog** ("Windows restarts in 15 seconds. Save your work first."), not a MessageBox; Cancel is the default. The 30 second hint under Restart Now is unchanged.
- **Report a Bug reads no stale snapshot for the bench**: the distro comes from the config (read afresh), and the only bench taken from the last poll is the single bench of a poll that was for the same distro and neither stopped nor failed. The busy window says after 6 seconds that a distro that does not answer can take up to a minute (the shim waits up to 20 seconds for each `wsl.exe` call).
- **GDI+ is one test collection.** `Image.Save` failed now and then with ArgumentNullException (encoder) when two test classes used GDI+ at once and the codec list came back empty; every class that draws or saves a bitmap is in the "GDI+" collection, and the PNG helper looks the encoder up under a lock.
- **Render smoke tests** measure and arrange every wizard page, the main window states and tabs, the log window and Settings at their real sizes on an STA thread, and fail on an exception or on a button outside the window.
- **The report ready window opens nothing by itself.** It used to open the GitHub issue and Explorer and then win the foreground back; on
  Windows 11 Chrome (after 0.15 s) and Explorer (after 0.8 s) always took it again, because the foreground rules favour the process that was
  started last. The window now lists the three steps and has Open GitHub Issue (the default button) and Show Zip in Explorer; a click is a
  user action, so what it opens comes to the front by the rules instead of against them. This also ends the occasional second Explorer
  window. A second Report a Bug click while the window is open brings it forward and starts no report.
- **Start for a distro checks itself.** After a Start the tray checks once, 30 seconds later, that the distro is up; if it is still stopped (the shim's keepalive refused, for example because another keepalive holds the mutex) a notice says "NAME did not start. Open the log or try again."
- **The Review page shows blocker cards only when the plan has blockers**, each with its message and fix once; the red error line and the plan's own fix line show only when there are none. A step the person stopped shows no Report This Problem link.
- **Five more built in runners are ports.** The runners added in 0.8.1 (Kettle, Server rack, Paper plane, Snail, Rocket) are hand ports of the Mac's drawing code, as the Bench and the Cup are. `RunnerCanvas` gained `Shape`, `CutDot`, `CutLine` and `CutArc` to match the Mac's new helpers; `BuiltInRunners.IsReserved` now checks every built in.
- **Runner holes are cut through a mask.** `RunnerCanvas.Cutting` draws the hole shapes into a mask and keeps the part of each pixel's alpha
  the mask does not cover, as the Mac's clear blend mode does. It used to paint transparent ink with SourceCopy, which seems to wipe every
  pixel an antialiased edge touches: at 16 px the new Snail's spiral took most of its shell (7 inked pixels where the Mac drawing has 36).
  The Bench's and the Cup's eyes go through the same path and are now a little closer to the Mac's too.

## Windows onboarding fixes (review of 0.8.2 and a live test on Windows 11)

- **The PC is held awake (`ES_CONTINUOUS | ES_SYSTEM_REQUIRED`) from the first install or setup action to the last exit path**: the end, an
  exception, Stop, the window closing, Quit. `IWizardHost.KeepAwake(bool)` is called from the UI thread only and the model counts holds,
  because the execution state belongs to the thread that set it. The timeouts stay (90 minutes for an install, 45 for an action) and keep
  counting in sleep; the awake hold is what keeps them honest. The display may still turn off. The Install page says to keep the PC plugged
  in and awake.
- **A timeout is said in the unit it was set in** (`60 seconds`, `90 minutes`), not as `(int)TotalMinutes`, which printed "0 minutes" for the 60 s read timeout.
- **A distro that WSL does not list is not a returning user's stopped distro**: `LaunchPlanner` lets `DistroMissing` fall through to the
  setup check, so a PC with WSL and no usable distro opens the wizard. `DistroName.FromRegistry` never returns `docker-desktop*`,
  `rancher-desktop*` or `podman-machine*`, default or not: the default when it is usable, else the only usable distro, else none.
  `windows/shim/distro.go` has the same rule.
- **The poll and the setup check pick the document out of the output like `CliClient` does** (the whole output, else the first object among
  its lines, else an object that starts on a line and spans the next ones), refuse a newer `schema_version`, and turn anything unreadable
  into one line that names a version mismatch and quotes the first line of the output. No page shows a `System.Text.Json` message.
  `benchbar.exe --shim-version` is compared with the tray's version once at start (a dev build 0.0.0 never warns); a difference stays on the
  flyout and the window until they match, and the flyout footer shows the tray's version.
- **A step id or an action id the tray does not know is shown and run, not hidden.** The row uses the step's own `title`, `detail` and optional `fix` (or `fix_command`), a blocking one holds Continue back, and its action runs through the generic `setup run ACTION` path with the label Set Up (`cli_update` says Update). The tray decides nothing from an id except the few it names.
- **Polling counts windows, not a flag.** The flyout and each window of ours add one viewer; only the last close drops polling to the slow
  rate. While every window is minimized or another program has had the focus for 30 seconds, the 5 s rate gives way to the rates of no
  window (30 s with a bench running, the idle back off otherwise); coming back polls at once. Measured live before the change: one open
  window cost one `benchbar.exe` and six `wsl.exe` starts every 5.4 s.
- **The old WSL share is a fallback**: `\\wsl.localhost\DISTRO\...` first, `\\wsl$\DISTRO\...` only when the first does not exist and the second does (older Windows 10 builds).
- **Stop, a timeout and closing the window kill the Windows process tree only**; apt, dpkg or the CLI inside Ubuntu can keep going and hold
  the CLI's lock. The tray relies on the CLI's own refusal (`lib/frappe-local/lock.sh`: "Another benchbar run is active (pid N)", "... is
  starting", "Could not take the lock"), which has no stable id, so the lines are matched in `LockText`. After a Stop or a timeout, Retry
  first runs the read only setup check, and a run that meets the lock waits and tries again every 15 seconds for at most 10 minutes (the
  Install page says it is waiting, Stop ends the wait) instead of failing at once or starting a second install. The CLI refuses at the lock
  before it changes anything, so trying is safe.
- **A closed tray leaves a trace.** `%LOCALAPPDATA%\BenchBar\running` (holding the version) is written at start and removed on a clean exit;
  found at the next start with the same version it means the tray ended some other way, and one notice says so with Report a Bug (and a
  balloon). A different version in the file is an update that closed the old tray: no notice. A caught exception on the UI thread shows one
  notice too instead of nothing. A fatal one takes the icon out of the notification area before the process ends.
- **The update banner and the menu offer a release only when it has `benchbar-windows-<version>-<arch>.zip` for this PC's CPU**
  (`releases/latest` is shared with the Mac app). The action copies the documented one line installer, `irm
  https://raw.githubusercontent.com/askysh/benchbar/main/install.ps1 | iex`, and says it closes BenchBar and starts it again; the release
  page stays as a second button. The tag pinned form is not used: `install.ps1` at a tag installs the latest release anyway, it has no
  version of its own.
- **Open at logon honours Windows' own switch**: `HKCU\...\Explorer\StartupApproved\StartupFolder` (value named after the `.lnk`, first byte odd means off). `IsEnabled` reports off when it is off there, and Enable and Disable clear the value (absent means on). The registry is behind `IStartupApproval`.
- **A password that is shown back is hidden in its JSON forms too** (as written, with `"` and `\` escaped, and as `System.Text.Json` escapes it), at any length. The forms ask for 8 characters or more (the CLI states no minimum) and refuse a line break in the Linux and the Administrator password.
- **`benchbar.exe` not starting is told by the Windows error code**: 2 and 3 (missing: where it was expected, how to reinstall, that a security product may have removed it), 1260, 4551 and their HRESULTs (blocked: names Smart App Control), 5 (access denied).
- **The wizard keeps its flow across a restart** (`resume_flow` in the tray config, `new` or `existing`), re-subscribes to its model when it is loaded again, and the Create User row names the user it will create before the click. The pipe pumps of a streamed child are waited for 5 seconds after it exits, so a grandchild holding the pipe cannot hang the call.
- **A window the tray opens by itself is brought forward**: restore, Activate, a Topmost toggle, SetForegroundWindow, and when Windows refuses, the taskbar button flashes until the person comes to it. The flyout opens on the monitor of the click (cursor position), with that monitor's DPI.
- **Text colors in the light theme are darker** (red C42B31, amber 8A5800: 4.7:1 or better on the card; E5484D was 3.5:1 and D98E04 2.4:1) and the dark red is lighter (FF7075); high contrast uses the system's HotTrack color. Dots and glyphs keep their colors.
- **ReadyToRun stays off** for the release publish: it was measured in 0.8.0 and only grew the download (see above). The numbers that mention it belong to the spike's variants.
- **Save takes the shim's config lock**: the named mutex `Local\BenchBarConfig`, created (never waited on) around the read, modify, replace; "already exists" means held, so 20 tries 100 ms apart, then it goes on without. Never held across a process call.
- **The cli step says Update from `cli_version`**: the shim keeps the action `cli_install` for an older CLI and adds `cli_version`; the label is Update when the step is `missing` and has one (or its detail says "does not match"). There is no `cli_update` action.
- **The Linux password minimum of 8 is advice on the Create User page**: the user may already exist with a shorter password and the shim then keeps it. Empty and line breaks still block; the Administrator password minimum for a new site is still a blocker.
- **Setup check waits 120 s, 150 s with `--probe`**: the shim's probe may take 90 s and its quick calls 60 s each.
- 2026-11-13: SignPath Foundation declined the application, so the SignPath policy text left docs/windows.md; the section is now "Signing and verification" and says the programs are not signed yet.

## Update Now from the app

- **One source of truth for updates: `benchbar.exe self-update --check --json`.** The tray's own GitHub call is gone; the shim picks the
  release as install.ps1 does (the Windows zip for this CPU and its sums), says how this copy was installed (`installer`, `store`, `other`)
  and never starts a stopped distro. The cost at rest does not change: the check still runs only when the BenchBar window opens, with the
  Settings switch on, at most once in six hours (plus the menu item and About on request), and it costs two short `benchbar.exe` starts
  instead of one HTTP call in the tray.
- **The tray asks `--shim-version` before every check and only a shim of its own version is asked `self-update`.** An older shim forwards an unknown command to the Linux CLI, which would boot the distro and answer for the CLI only. An answer without `install` and `current` is not the shim's and counts as a failed check (quiet, logged).
- **What is offered follows `install`**: `installer` gets Update Now with the update line under Other Ways; `other` (a dev build, a loose
  copy, an install kind this tray does not know) gets the update line only, as before; `store` gets no banner, and Check for Updates says
  the Store updates it. A check error behaves as a failed check did: nothing on screen, a line in tray.log, words only when the person
  asked.
- **Update Now runs `powershell.exe -NoProfile -NoLogo -EncodedCommand ...` through ShellExecute**, a console window of its own in the
  profile folder, not a hidden child of the tray. The script runs `& 'PATH\benchbar.exe' self-update --yes`, says whether it finished and
  waits for Enter, so the result stays readable after the installer has closed and restarted the tray. `-EncodedCommand` means no shell
  parses the profile path; inside the single quoted string a quote (and PowerShell's typographic single quotes) is doubled. `cmd /k` was not
  used because cmd expands `%NAME%` inside quotes.
- **A second Update Now while the window runs starts nothing** and says "An update is already running in its own window."; the buttons show Updating... and are off until the window closes (the process's Exited event, no timer).
- **The installer can close the tray politely through the named event `Local\BenchBarTray.Quit`**: the tray quits as from its menu, so the run marker goes. `CloseMainWindow` cannot do it, because the tray usually has no visible window. install.ps1 is outside this folder; until it sets the event it falls back to its forced stop, which removes the marker itself.
- **"BenchBar was updated to X" compares `tray.last_version` in config.json with the running version** at start: newer shows one notice with
  What's New (the release page of that version, as the banner's Release Page) and a balloon; the same version, an older one (a downgrade)
  and a first install say nothing; a dev build neither shows nor records. A config with a `tray` object but no `last_version` is a tray from
  before this change, so that start counts as an update. Notices now have a `Critical` flag: this one is news, drawn in the normal text
  color.
- **The first BenchBar window that closes shows one balloon** ("BenchBar is still running. Find it in the notification area near the clock ... or open BenchBar from the Start menu."), `tray.running_hint_shown` in config.json. Someone who updated already knows where BenchBar lives, so the updated notice marks the hint shown. The "Your Bench Is Ready" subtitle stays; it is a page, not a close hint.
- **The wizard opens by itself only when that helps** (`LaunchPlanner.Decide`): the resume start after the restart for WSL (always), and
  while setup is unfinished the installer's `--installed` start (over an old `wizard_dismissed`, since uninstall keeps config.json) and the
  first start of a tray that never ran here (config.json had no `tray` object) unless dismissed. An ordinary logon start and a start after
  an update (`--restarted`, or a newer version than `tray.last_version`) never open it; a real PC with WSL and no distro had it open at
  every start. Any close before Done (Cancel, the window's X, Alt+F4, Quit) sets `wizard_dismissed`; the "Stop it and close?" question for a
  running step stays.
- **Set Up BenchBar stays reachable while setup is unfinished**: the launch check runs `setup check` once at start on a PC with no bench,
  dismissed or not (it skipped dismissed PCs before), and its answer shows "Set Up BenchBar..." in the tray menu and a Set Up BenchBar
  button on the flyout's problem card; the window's cards had it already. A bench in a later poll or Done hides them. No timer is added.

## 0.9.0: robustness (issue 167)

- **`SystemProcessRunner` has the pipe grace of the stream runner** (5 s after the child exits; `ProcessKill.Tree` catches the Win32 and Aggregate exceptions of a kill that fails). It reads into buffers, not with `ReadToEnd`, so a call whose grandchild holds the pipe returns what the child printed. Two runners remain, for lines and for the whole text; they share the constant and the kill.
- **Follow asks `logs --json --since` through one process while lines arrive, and the distro probe (a second process) only before the first
  poll, after an empty poll and after a pause.** A distro that stopped is found on the first empty poll, at most one poll late, instead of
  paying a probe per 2 s. The wait doubles from 2 s to 10 s while nothing arrives. Paused (locked, asleep, window minimized or hidden) holds
  no timer and catches up with one poll; battery saver means at least 30 s. It does not copy the bench poller's "30 s without focus" rule: a
  log on a second monitor is the use of Follow.
- **The bench poller stretches the running interval to 60 s on battery** (`GetSystemPowerStatus`, read at start, on resume and on a power status change). The second part of the finding (skip the CLI poll while every bench is stopped and the distro is up) is left: it needs the probe to tell a keepalive only distro from a bench one.
- **Newer schema: read only documents are read, changes are not.** `list`, `status`, `doctor`, `logs`, `setup check`, `site list`, `app
  list` and the other read commands of a newer `schema_version` are parsed anyway and refused (with "speaks schema N") only when the member
  the view is made of is missing; plans, applies and streams of a newer schema are still refused. docs/json-schema.md promises that new
  fields are not a break and that a break bumps the version, and the schema number is one constant for every document, so a bump for one
  command would have blanked the flyout.
- **Versions: an older shim warns, a newer patch of the same minor does not, and a newer shim may be asked for the update check.** Only the old shim forwards `self-update` to the Linux CLI and boots the distro. A tray whose DLLs could not all be replaced can now reach the updater that fixes it.
- **Install and adopt keep their passwords in the child's environment** (`ADMIN_PASSWORD`, `BENCHBAR_SUDO_PASSWORD`,
  `MARIADB_ROOT_PASSWORD`). The CLI reads them from there only (it removes `BENCHBAR_SUDO_PASSWORD` at once, docs/DECISIONS.md) and the shim
  forwards exactly those names through `WSLENV`; a stdin or file channel needs the CLI and the shim to change first. `docs/windows.md` says
  so. Left for a CLI and shim change.
- **Config saves run on a pool thread, one after the other, and quit waits up to 3 s for the last one.** `Save` retries with `Thread.Sleep` for up to a second; on the UI thread that froze the window.
- **The harness pipe, the logon log and `BENCHBAR_TRAY_THEME` are in Debug builds only** (`HARNESS` is defined unless the configuration is
  Release; the Release `HarnessLink` is an empty type, so no pipe, thread or variable read exists in what ships). The spike harness that
  used them is deleted. The fixtures mode stays (the docs and the demo use it) and now shows a "Demo data" notice that cannot be dismissed
  while `BENCHBAR_TRAY_FIXTURES` is set, so a stale user variable cannot pass for the real thing.
- **The release builds run the tray tests and start the tray** (`scripts/smoke.ps1`): the amd64 job tests the solution and starts the
  published, signed files on recorded data (`BENCHBAR_TRAY_FIXTURES=fixtures/rest`); the arm64 zip, built on an x64 runner, is started in
  its own job on `windows-11-arm`, which gates the release job. The script needs no debug hook: the run marker
  (`%LOCALAPPDATA%\BenchBar\running`, written at start, removed on a clean exit, holds the version) shows the app started and stamped the
  version the build was given, and the `Local\BenchBarTray.Quit` event is the way the installer closes a running tray. `tray.yml` tests and
  starts arm64 natively too, and also runs on pushes to `next-release`.
- **`labs on` from the Labs page runs `--yes --json` with `BENCHBAR_NONINTERACTIVE=0`, as the Mac app does.** The CLI refuses an experiment turned on under a non interactive run so that no agent can; the page's switch is the person's click and the warning is on the row, so there is no extra dialog. Turning one off never asks.
- **A link goes to the running tray over a named pipe, not a file or the open event.** `BenchBarTray.Link.SESSION` takes one UTF-8 line (at
  most 2048 characters) from this user only (`PipeOptions.CurrentUserOnly`), so a link that carries a token never reaches the disk; the
  server waits for a connection and costs no timer at rest. A second copy that cannot reach the pipe (an older tray) falls back to the old
  open-flyout event and the link is dropped.
- **The `benchbar:` registration is per user and the tray never takes it from another program.** `HKCU\Software\Classes\benchbar` is written
  at start when it is missing or points at a `BenchBarTray.exe` that is gone; another copy that still exists, or another program (also one
  registered for the whole machine: the tray reads the merged `HKEY_CLASSES_ROOT` view), is left alone. install.ps1 follows the same rule,
  so neither takes a link from the other. The command is `"BenchBarTray.exe" "%1"` and the tray reads only an argument that starts with
  `benchbar:` and is at most 2048 characters. A link may not hold `"`, `\`, `^`, `|`, `<`, `>` or a backtick (a real link percent encodes
  them): a `"` would end the quoted `%1` and turn the rest into arguments, so a start from a link also ignores the tray's own flags. Only a
  process named `BenchBarTray.exe` registers (a `dotnet run` start would register dotnet.exe). A demo run on recorded data never registers.
- **Links wait for the first poll, and `~` in `bench=` means a bench under `/home/USER/` or `/root/`.** The bench list decides which bench a
  link means, so a link that starts the tray waits for the first snapshot (at most 16 wait). The tray does not know the distro's home
  folder, and a bench is never matched by a trailing part of its path. `.` and `..` in a path are resolved first, as the Mac's
  `standardizedFileURL` does.
- **The tray log gets fixed sentences only for links, and no bench name.** The Mac logs the bench of a link that ran; this log goes into bug reports, which keep bench names out, so it holds the action word and a fixed reason or a short hash.
- **A timer poll skips the CLI while the distro is up and every bench was stopped on the last poll.** The probe alone runs, because every
  `benchbar.exe` call touches the VM and keeps WSL from its idle shutdown. A kick (unlock, action, flyout), a bench that was not stopped, a
  boost or an open flyout makes it a full poll, and a full poll runs at least every 20 minutes so a bench started from a terminal still shows up.
- **Tests wait for outcomes, never for time.** A poll is held with a `TaskCompletionSource` gate or ended by the fake clock; "nothing happened"
  is checked from state (`BenchPoller.IsPolling`, `LogViewModel.PausedWaits`), and `Eventually.Async` waits for a condition with no fixed sleep.
  The only sleeps left are the retries for the GDI+ PNG encoder list, which depends on the system, not on time.
- **A fatal fault (out of memory, access violation) is not handled by the UI exception hook.** Any other UI fault is logged, shown as one notice and survived;
  a fatal one ends the process so the next start reports it from the run marker.
- **Dates for display use the current culture (`UiText.Date`), user text lives in `Strings.resx`.** The tray menu, crash toasts, tooltip and WSL messages are moved;
  `UiTextTests` fails when code asks for a missing name or an entry is unused. The pages of the BenchBar window still hold inline text.

## Tray parity: Open as (0.9.0, #174)

- **Open as is a person's decision, so the tray asks and never decides.** "Allow Open as..." shows the Mac's text and runs `site open-as on
  SITE --yes --json` only after a yes; `--yes` skips the CLI's copy of the question, not the person's. The tray runs it with
  `BENCHBAR_NONINTERACTIVE=0` and `BENCHBAR_SUDO=gui` (the CLI refuses an opt in that nothing at a terminal or an app confirmed), and no
  poll, link, retry or repair turns it on. Turning it off needs no question, as in the Mac app.
  The environment goes only to `site open-as on` and `open --as` (a click or Enter); the search for users is a read and never claims one.
- **A refusal of `open` and `users` is stderr text, not JSON.** They are not in the CLI's JSON modes, so a refusal prints nothing on stdout
  and `  [FAIL] message` on stderr; the tray shows the message without the tag. A test scans the code so `site open-as on` has one way in.
- **The sign in link never reaches the tray.** Find User runs `open --site S --as USER --json` (no `--print-url`, a test pins it) and the
  CLI opens the browser itself (`wslview`, else `explorer.exe`), so the session id is not in the tray's memory, logs, clipboard or screen.
  The Mac app reads the link to cache and reuse sessions; the tray does not cache, so each Open makes a new session on the site.
- **Open as follows `status --json`.** A site's `open_as_enabled`, `developer_mode` and `open_as` come from the poll that is already running
  (an older CLI has none and shows no Open as at all). A site whose name Windows cannot find has no Open as: the CLI would refuse it (WSL's
  browser reads Windows' hosts file), and the tray never edits that file.

## Tray parity: Quick Switch (0.9.0, #174)

- **Quick Switch is the Mac's panel, not a bench switcher.** The Mac app's Quick Switch (`macos/BenchBar/QuickSwitch`) opens a site as
  Administrator or a pinned user from the keyboard, and "switch the default bench or site" is already `benchbar default` and the sidebar.
  The tray follows the Mac: the panel, the pins (nine per site, Administrator never one), the digits, the arrows, search from two characters
  (eight results) and the "last opened" mark.
- **It is not a Lab on Windows.** The Mac gates it by the `quick-switch` lab because the lab holds a system wide shortcut. Here the panel holds nothing: it opens from the tray menu on a click, and `labs list` says `quick-switch` is macOS only (so `labs on` would refuse it). A global shortcut is a separate opt in, below.
- **The panel decides nothing for the person.** A site without Open as on is not a target and the panel says how to turn it on in the Sites tab; the one call is `open --site S --as USER --json`, and the answer `opened: false` or a refusal stays in the panel in the CLI's words.
- **Pins are the tray's own record** (`tray.open_as_pins` in `config.json`, saved when pinned, replaced as one immutable map so the thread that saves never sees a half edit). The shim's keys are kept. A pinned user's row in Find User has a label field (the Mac's), saved as typed and trimmed when read.
- **A digit opens a row only with no modifier down, and a label is saved when the person is done.** Shift+1 on an empty field is "!", not pin 1 (a
  digit is a one key sign in), and Ctrl, Alt and Win digits are not ours. The label field of Find User saves on Enter
  or leaving the field, because each save writes config.json. A blocker never says "turn it on" where Allow Open as is not offered (a name Windows
  cannot find, a CLI too old to send the fields).

## Tray parity: Quick Switch shortcut (0.9.0, #174)

- **The shortcut is a Settings option, not a Lab.** The Mac holds it behind the `quick-switch` lab; here that lab is "not on Windows yet", so the switch is Settings > General, off by default, saved as `tray.quick_switch_hotkey` (`enabled`, `key`). The default is Ctrl+Alt+U.
- **`RegisterHotKey` on a message only window the tray creates when the first key is registered** (`HotKeyHost`), with `MOD_NOREPEAT`. A tray with the option off owns no extra window and no timer. The key is given back when the option is off, while recording and at exit.
- **The rules** (`HotKeyRules`): Ctrl or Alt must be in it (the Mac's rule), so Shift or Win alone is refused; Ctrl with a letter or digit and no Alt is refused too, because that is Ctrl+C, V, X, Z of every app; Alt+F4 and Alt+Space are the system's. Keys offered: letters, digits, F1 to F24, arrows, Home, End, PageUp, PageDown, Insert, Delete, Space. A stored key that breaks the rules (a hand edit) reads as the default.
- **A taken key keeps the old one.** A change registers the new key before it replaces the old; when Windows refuses, the old key is registered again and a line says so. A key taken at start leaves the option on and says so (as the Mac, `macos/DECISIONS.md` 0.9 Quick Switch): turning it off and on tries again. The message is not stored.
- **The recorder pauses the key** so the current shortcut can be recorded again; leaving the button, Esc or Reset gives it back. A chord is applied after the old key is registered again, so the "taken" test is real.
- **The registrar is an interface** (`IHotKeyRegistrar`): the rules, the store, the taken key and pause/resume are tested in `Tray.Core.Tests` with a fake; the Win32 calls are two lines in `HotKeyHost`.

## Tray parity: rooms (0.9.0, #174)
- **The Sharing tab is the host side only (P30).** The guest side of a room (the code exchange, the pinned certificate, the local forwarder)
  is Mac app code with no `benchbar` command behind it, and the tray drives the CLI through `benchbar.exe` JSON only, so P31 stays open: a
  `benchbar://share/join` link still shows the note. Writing that protocol again in C# would be a security review of its own.
- **The tab exists only while the lan-rooms lab is on and available here**, the same switch as the Mac app and the CLI (`labs list`), read once per bench selection through the Labs model, never per poll. With the lab off or "not on Windows yet" there is no tab and no call.
- **The setup plan has no token.** `share setup --dry-run --json` prints one plan line, so the sheet runs with `RequiresToken` off and its
  Summary carries the data classes and the acknowledgement; the ticked box in the form and the sheet's "Make the copy" are the person's
  answer, and the apply passes `--acknowledge-data --yes`. The view reads the plan itself first (for that summary), and the sheet reads it
  again.
- **The lan-guard buttons (`install`, `allow-node`) are the person's decision.** Each runs only from a click after its own question (the
  Mac's wording), with the person environment, and never from a check, a poll, a link or a retry. They do not go through the sudo password
  prompt of the plan sheet: on Linux the CLI has no LAN guard yet (another change adds nftables), so what it answers, including a refusal,
  is shown as it is.
- **Reading is all a poll or opening the tab does:** `share status --preflight` and, while the room is on, `share people` (at most every 8 s). Start, stop, extend, lock, code, invite and remove each follow a click, and start, stop and remove a question, with the CLI's person environment (`BENCHBAR_NONINTERACTIVE=0`, `BENCHBAR_SUDO=gui`, as on the Mac).
- **The room code and the invite are read on a click and kept in memory only.** `ShareCode` and `ShareInvite` print as `hidden`, a failed
  read says that it failed without repeating stdout, the card shows dots until Show, the lines the tests read never hold the code, and Copy
  uses a clipboard write marked `ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory` 0 and
  `CanUploadToCloudClipboard` 0 (the Mac's concealed and transient types).
- **Show and Copy read the current code on a click when none is in memory.** After a tray restart or "Start again" the tab holds no code, and
  New code would end the invites already sent. So these clicks run `share code` without `--new`. Opening the tab still never reads it.
- **A refusal is shown as the CLI worded it, never as an old CLI.** A status call that fails and has no `state` (the lab is off, exit 2) sets the
  error line from its `error` or first stderr line. "Needs a newer command line tool" is only for an ok document without the protocol fields.
- **The lan-guard buttons follow the guard, not the lab.** The CLI's guard is a pf anchor and a macOS firewall rule, and `lan-guard` has no Linux
  refusal of its own. `ShareModel.LanGuardSupported` is false here (`ShareText.LanGuardSupportedHere`) until the nftables guard lands: no button is
  drawn, nothing runs, and the tab says so. A lab that lists Linux first cannot make the tray run root steps meant for a Mac.
- **An unknown MariaDB root password (exit 2 on the copy) shows the CLI sentence and then what to do in a terminal.** The tray cannot ask for the
  password. `PlanReviewRequest.ExplainFailure` adds the advice only when the CLI's own sentence does not already name `MARIADB_ROOT_PASSWORD`.
- **Not ported from the Mac tab:** Move to (`share assign`), the activity log, Open copy as and teardown.
- **Not ported from the Mac tab in this change:** setup and Refresh copy and the lan-guard buttons (next change), Move to (`share assign`), the activity log, Open copy as and teardown.
## The Microsoft Store package (MSIX)

- A process is packaged when `kernel32!GetCurrentPackageFamilyName` answers; 15700 (no package) or any failure means unpackaged and nothing changes for the one line installer's copy. The family name is read at run time, never written in code. Everything that differs sits behind `IPackageInfo`, so `Tray.Core` logic is tested in both states.
- Packaged, every file the tray keeps (`config.json`, `tray.log`, `running`, `runners`, `reports`, `recent-scan-folders.txt`,
  `resume-setup`) is under `%LOCALAPPDATA%\Packages\<PackageFamilyName>\LocalCache\Local\BenchBar`, built in one place (`DataFolder`).
  Writes to `%LOCALAPPDATA%\BenchBar` from a package are redirected to a private store whose content depends on what already existed, which
  split `config.json` in two and made every shown path false; the physical path is never redirected. The shim uses the same expression and
  does the one time import of an old `config.json`; the tray never writes to the old folder from a package.
- `DisabledByUser` and `DisabledByPolicy` show the switch off and disabled, one line (Settings > Apps > Startup) and an "Open Startup
  Settings" button (`ms-settings:startupapps`): an app cannot turn its own startup task back on after the person or a policy turned it off.
  `EnabledByPolicy` shows on and disabled. A failed read shows off, disabled, with the same pointer, and writes the exception to `tray.log`.
- A start with `--restarted` runs `benchbar.exe keepalive start` once, hidden, off the UI thread, 30 s timeout, and only logs a failure to
  `tray.log` (`KeepaliveRestart`). A package update stops the keepalive process with the old package and nothing else starts it before the
  next logon. The call is safe for everyone because the shim does nothing and exits 0 when there is no keepalive task or it already runs. A
  normal start never makes the call.

- Open at logon packaged is the manifest's startup task `BenchBarTrayLogon` and nothing in the Startup folder is read, written or deleted:
  the folder holds the other install's `BenchBar Tray.lnk`, and a shortcut into the versioned `WindowsApps` folder breaks on the next
  update. The WinRT call needed no new reference: the project already targets `net10.0-windows10.0.19041.0`, so
  `Microsoft.Windows.SDK.NET.dll` (24.9 MB) ships in the framework dependent publish with or without it. The publish grew 22 KB (27,398,386
  to 27,420,402 bytes, 10 files without pdbs), and the call works from Windows 10 19041, so 19045 is covered. The WinRT type is touched only
  when Settings, the menu or the wizard asks, never at start, so private bytes at rest do not change.
- The setup wizard's resume flag (`BenchBar Setup Resume.lnk` in the Startup folder, which starts the tray with `--resume-setup`) is a file
  `resume-setup` in the data folder when packaged, read when the tray next starts (at logon if open at logon is on, else when the person
  opens BenchBar). A package cannot write a Startup shortcut, and a registry RunOnce value written from a package lands in its private hive.
- Packaged: no update check through benchbar.exe, no banner, no Update Now, no "Copy Update Line", no "Check for Updates" in the menu or
  About, no "Check for updates" switch in Settings; Settings and About say "Updates come from the Microsoft Store". The version mismatch
  notice stays and loses its "Copy Install Line" button (one package: the install line is not its fix). The CLI inside WSL updates as
  before.
- The packaged gate is also inside `SelfUpdateClient` and `SelfUpdateLauncher` (they take `IPackageInfo`): a packaged tray gets the Store answer and `UpdateStartKind.StoreManaged` without running a process, so no surface (flyout, menu, About, Settings) can reach the zip self-update even if its button were shown. `App.RunUpdateCheckAsync` and `App.UpdateNow` return early on the same policy.
- Settings shows the alias `%LOCALAPPDATA%\Microsoft\WindowsApps\benchbar.exe` when packaged, not the versioned package folder that changes on every update; the tray still runs the `benchbar.exe` next to itself.
- `RegisterApplicationRestart("--restarted", RESTART_NO_CRASH | RESTART_NO_HANG)` runs only when packaged: unpackaged, `install.ps1` starts
  the tray again itself, and a second start would only raise the first one's flyout. A start with `--restarted` never counts a leftover
  `running` marker as a crash (Windows ended the earlier run on purpose; a crash or hang is never restarted) and never signals a running
  tray to open its flyout.
- Two installs: packaged, when `%LOCALAPPDATA%\Programs\BenchBar\BenchBarTray.exe` exists, one dismissible notice in the BenchBar window and
  flyout with "Copy Uninstall Line" (the installer run as a script block with `-Uninstall`, which leaves no variable set in the window). The
  dismissal is `tray.two_installs_dismissed`; it is reset when the other copy is gone, so a later second install is told once more. The
  unpackaged tray says nothing: the named mutex is shared, and whichever tray started second exits, so the notice shows only when the
  packaged tray is the one that runs.
- The logon checkbox listens to Checked and Unchecked, not Click: UI Automation's Toggle pattern flips a WPF CheckBox through `OnToggle` and
  raises no Click, so the request was never sent and the box kept the flipped value (shown On while the task stayed disabled). Whatever
  flipped the box, the handler puts it back to the model's value at once; the box changes only when the startup task's answer (after
  `RequestEnableAsync` or `Disable` plus a read) is published. The setup wizard's box does the same and re-reads the task when it opens.
  `LogonModel` runs one request at a time and ignores a toggle while one is in flight.
- **The wizard reads which profiles Linux takes from `profile list --json`** (`linux_supported`, `unsupported_reason`, the install's own gate). A CLI without the field gets `install --dry-run` per profile, one by one. A profile the person picked that is refused keeps its place and the form says why (#175).
- **A pending operation is finished by the same command, shown in the plan sheet, never by a command of the tray's own.** `app add NAME` also works for an app added by URL or never cloned: the CLI takes it from `apps/` or the record's `url`. Discard asks first (`app update NAME --discard-pending`). The fix line is doctor's (#175).
- **Several apps in one add put each app's `--branch`, `--commit` and `--install-on` right after its own name**, as the CLI reads them; the form allows 8 apps and refuses a name given twice before any call (#175).
- **The wizard asks the install itself which profiles it takes.** `profile list --json` has no per platform field, so each profile gets `install --dry-run --json --offline --profile NAME`, one after the other: a plan line means taken, a `done` that failed before any plan is the refusal, shown as the CLI worded it. No answer leaves the profile on offer; Review then says more (#175).
- **A command is offered only when the CLI lists it.** `commands --json` is read once per window (`CommandSupport`, a failed read is asked again). An older CLI keeps the old menu, and the scheduler keeps `service --yes` without `--apply`.
- **`lock write` and `lock apply` have no JSON plan or token, so the sheet shows the dry run's text.** `PlanReviewRequest.PlanIsText` reads `--dry-run` as text, shows it, and runs `--yes` after the yes. A failed preview shows its `[FAIL]` line. To be replaced by a token when the CLI has one.
- **`watch` and `fg` open a terminal and are not children of the tray.** They run until ended and have no stop command. Killing `benchbar.exe` may leave `bench watch` running in WSL, and the tray never kills processes by pattern. The command is `/bin/sh -c 'exec benchbar "$@"'` with the bench path as an argument.
- **`autostart` is read from its text line.** The CLI has no JSON for it and `status` has no field. `AutostartText` matches `autostart is on` or `is off`; any other wording leaves the box disabled instead of guessing. Read once per bench.
- **Prerequisites are read on the New Bench page, not on Health.** `doctor --json` already carries them for a bench; `doctor --prerequisites` is the read that needs no bench. They show warnings and failures with the fix to copy and never disable Review.

## Tray parity part 2: notices, readiness, pull, MCP (0.9.0, #187)

- **Notices are a banner above the bench page's tabs, in the window only, and only a click dismisses one.** `notices[]` is the person's state, not a bench's, so every bench's status carries the same list. After Dismiss (`notices --dismiss ID`) the notice stays hidden even if a poll that started earlier still lists it; once the CLI stops listing it the memory is dropped.
- **`notices` and `ready` are read from `JsonNode` by hand (`StatusExtras`), not through the generated DTO.** A member of an unexpected shape counts as absent and never fails the whole status, so one odd field cannot blank the flyout. An older CLI sends neither, and the window then shows neither.
- **A notice's link is opened only when it is an https URL.** The text is the CLI's own, but the system opens the link, so `javascript:`, `file:` and plain http are dropped and the notice shows without a Read More.
- **Readiness uses the Mac's three words (Ready, Needs restart (code changed), Running, not ready) and shows in the Overview only.** It is not in the flyout rows or the icon: `ready` without `--deep` has `workers` and `stale` null, which never make a bench not ready. The fix line is shown with Copy; no button runs it, Restart is the existing one.
- **Pull applies by the token of its own plan and the tray never computes one.** The plan and apply come from `PlanReviewRequest.Tokened` (`--dry-run --json`, then `--apply TOKEN --yes --jsonl`). A plan without a token cannot be confirmed and says to update the CLI; "The plan token expired" counts as a stale plan like "changed since it was shown".
- **Pull's fixtures come from the Mac's, which tests/test-pull.sh checks against the CLI** (names and paths changed; real step strings and 64 hex tokens kept; no Neutralise step under keep secrets). The recorder cannot make an SSH plan, so they are in neither of its lists. The status fixtures derive from the recorded status and are in SHAPES.
- **`--keep-secrets` is a box that starts off, with its warning beside it and again at the top of the plan.** An absent `neutralise` in a plan reads as not neutralised, never as neutralised, as in the Mac app.
- **A pull has Stop Waiting and no Stop, with or without keep secrets.** `PullCommands.Review` sets `CanStop = false` for every pull, since a restore is not killed part way; the sheet's Stop Waiting closes it and the run goes on.
- **Pull takes a backup folder as a path inside Ubuntu, and `HOST` must work without a prompt.** The tray has no Windows to WSL path translation and a call has no terminal for an SSH passphrase; the form says both. A host that starts with `-` is refused (it would be an option of ssh). The new name follows `SITE.local` until it is typed over.
- **Pull is offered when `commands --json` lists `pull` with `--apply`.** The bench page asks once when the Sites tab is first shown (`CommandSupport.Current`); the tab reads the cached answer and starts no call of its own, so its tests keep exact run counts.
- **P05 `fg` and `watch` need no new action.** Part 1 added Watch Assets in Terminal and Run in Foreground in Terminal (Overview, More), Logs follows the log and Start starts the bench; `watch` is the one with no equivalent, and it is there.
- **P44 `mcp`: About and the wizard's Done page show the `claude mcp add` line, and About also copies the JSON entry** (`mcpServers.benchbar`, command `benchbar.exe`, args `mcp`) for clients that are not Claude Code, as docs/guides/agents.md describes it for `benchbar`.
- Every process the tray starts says `BENCHBAR_CALLER=tray` (`TrayCaller.Apply`, in `SystemProcessRunner` and `SystemStreamRunner`), and the shim forwards the variable into the distro, so `benchbar history` and the run log name the tray (#185). An environment a caller passes wins over it. A history page is a later change.
- **P47 speed and P48 charts read `stats --json`, only while the Overview is on screen.** The CLI now has the data (cpu, memory, processes, `speed.raw`), so the earlier "no data" lines are gone. Every 5 s while the card is visible and the catalogue lists `stats`; one round at a time; a stopped bench makes no call.
- **The tray icon's runner speed stays 1.** The charts show the speed figure, but sampling it for the icon needs a timer at rest, which cost at rest rules out. `ILoadSource` stays unused until a sample comes for free.
- **Speed is smoothed as on the Mac (alpha 0.35, from 1) and cleared when the bench stops.** A missing `speed` falls back to `SpeedMapping.Speed(cpu_percent)`. An unusable number is no sample and a failed call keeps the last chart, so nothing is invented.
- **Leases come from `lease list --bench PATH --json`, every third round (15 s), not from `status.leases`.** As on the Mac, the document has the note and the length. The id is never read: the tray holds no lease and never takes, renews or releases one.
- **Break Lease is only the person's click after an alert, and it runs the same command with `--break-lease`.** Start, stop, restart and the plan sheet's apply offer it when the CLI says `is leased by`; the call sets `BENCHBAR_NONINTERACTIVE=0` like Open as. A poll, a link or a retry never does. Other Sites actions show the holder only (left for a next part).
- **Rollback asks for the site name before the plan sheet, as Restore does.** The Mac types it inside the sheet; here the typed dialog is the pattern of Restore and Drop. Both calls run as the person (`BENCHBAR_NONINTERACTIVE=0`) because the CLI allows the default site's rollback to a person only. The default site's plan line says so.
- **Remove runs `site snapshot drop ID --yes` as the person and never passes `--force-undo-point`.** The undo point of the last rollback has Remove off, with the reason. Taking a snapshot has no plan, as it changes nothing in the site.
- **The word `null` as a snapshot label (the mocked CLI prints it) reads as no label, like an empty string,** as on the Mac. A snapshot really called "null" shows its stamp.
- **History reads `history --json --limit 100` when shown and on Refresh, never on a timer.** An unknown caller is shown as it came. There is no Show Log: the log is a path inside the distro, so a row has Copy Log Path.
- **Op handles (R03): the Overview lists the bench's running operations (`op list`, with `--running` when listed); an apply keeps its streamed view.** The plan sheet follows a run by its step and progress lines, and Stop Waiting detaches it without killing it. `--background` would trade that stream for an id to poll.
- **Run Bench Command keeps the allow list in the tray (`RunAllowList`); the CLI stays the judge.** `commands --json` does not list it. A flag must be one the row names and a value one plain word, checked before the call. A read runs in the dialog; a change closes it and goes through the plan sheet with the plan's own token.
- **`--break-lease` goes before `--` when an apply has one (`LeaseCommands.WithBreak`),** because the words after `--` belong to the bench command.
- **Tidy (issue 183): removing data runs as the person after a typed name or a plan, `site hosts --prune` has no entry, and orphan databases are only listed.** `bench remove` and `bench gc` set `BENCHBAR_NONINTERACTIVE=0` (the CLI refuses an agent), and Remove types the folder name that `--confirm-bench` repeats. The CLI's `site hosts --prune` is macOS only (on Linux it prints nothing to prune) and the tray never edits the Windows hosts file, so there is nothing for the tray to offer. `db orphans` never drops: its list and the CLI's note are shown, and a person drops in Terminal.
- **Repair and the first run wizard pass the reviewed plan's token (UI-15, `repair --apply TOKEN --yes`, `install --apply TOKEN --yes`).** The token comes from the plan line the tray already reads (`RepairPlan.Token`, `InstallPlan.Token`; `InstallRequest.ApplyToken` carries it to the one real run, never to the plan call). A refusal that `PlanStale.Looks` knows ends in `RepairPhase.Stale` or back on the wizard's Review page (`StaleMessage`), nothing changed, with Review Again. A Retry or Run Again after a run started passes no token (the machine is part way through), an older CLI with no token keeps the old call, and adopt has no token in the CLI yet.
- **Move to Another Bench reuses the plan sheet, with three small hooks (issue 183).** `PlanReviewRequest` gained `ConfirmName` (the site's name is typed in the sheet, so the plan is read first, and Move is never the accent button), `BlockedBy` (Stop Bench runs the tray's own `down` and reads the plan again; the CLI's `benchbar down` text is not run) and `RefreshLabel` ("Review Again"). A step line with a `parent` is progress of that step, not its status: `site move` restore sub steps share the restore's id. No `BENCHBAR_NONINTERACTIVE=0`: `site move` has no agent refusal.
