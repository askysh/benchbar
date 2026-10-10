# Windows tray decisions

One line per non obvious choice. The spike's code is in `spike/` and is not shipped.

## Spike: the shell (0.8.0)

- Decision rule, fixed before any numbers existed: choose the shell with the lower private bytes at rest and CPU while animating, unless click to flyout is above 150 ms or logon to icon is above 2 s for that shell. A difference under 10% on a metric is a tie. On an overall tie, prefer the shell with less deployment friction on a clean Windows 11.
- The shell is the only variable: both shells use one shared library (`spike/Tray.Core`) for the state model, the poller, the frame sequencer, the icon frames and the harness pipe, H.NotifyIcon for the icon (`.WinUI` and `.Wpf`), and the same flyout policy.
- Runner frames are drawn to an HICON at run time, not exported to an `.ico` per frame: the tray slot's pixel size follows the taskbar monitor's DPI and can change while the app runs (16, 20, 24 or 32 px), the template runner is tinted for the taskbar's light or dark theme, custom runners are PNG folders loaded at run time anyway, and no Mac or Swift step enters the Windows build. Each frame is drawn once per (size, tint) and cached; an animation tick only swaps the cached handle with `NIM_MODIFY`.
- Visual Studio 2026 has no `Microsoft.VisualStudio.Workload.WinUI`: "WinUI application development" is `Microsoft.VisualStudio.Workload.Universal` (the old UWP id, renamed). The preflight check uses that id.
- `benchbar` is on PATH only in a login shell inside the distro (`~/.local/bin` comes from `~/.profile`), so the fixture was recorded with `wsl.exe -d Ubuntu-24.04 -- bash -lc 'benchbar status --json'`. The shim must start a login shell, or call the CLI by its full path.
