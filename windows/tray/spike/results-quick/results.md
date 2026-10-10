# Windows tray shell spike: results

> Quick smoke run (few runs, short windows). Not for the decision.

## Verdict

Rule (windows/tray/DECISIONS.md): choose the shell with the lower private bytes at rest and CPU while animating, unless click to flyout is above 150 ms or logon to icon is above 2 s for that shell. A difference under 10% of the larger value is a tie. On an overall tie, deployment friction: decided by the lead.

The gate uses the median over all opens for click to flyout (the cold first open is listed apart), and the cold median for logon to icon when it was measured, else the warm one.

**Step 1, gates** (a shell above a limit is not chosen):
- WinUI click to flyout: median 15.3 ms over 3 opens, limit 150 ms: pass
- WinUI logon to icon (cold): median 424 ms over 1 runs, limit 2000 ms: pass
- WPF click to flyout: median 14.7 ms over 3 opens, limit 150 ms: pass
- WPF logon to icon (cold): median 358 ms over 1 runs, limit 2000 ms: pass

**Step 2, metrics** (lower is better; a difference under 10% of the larger value is a tie):
- Private bytes at rest: WinUI 98.4 MB, WPF 16.8 MB; difference 82.9% of the larger value, WPF is lower
- CPU while animating: WinUI 0.78 % of one core, WPF 1.09 % of one core; difference 28.5% of the larger value, WinUI is lower

**Step 3, outcome: Split: WPF is lower on private bytes, WinUI is lower on CPU. The rule does not say how to weigh the two: decided by the lead.**

## Machine

- cpu: AMD Ryzen 7 6800H with Radeon Graphics
- logical_cores: 16
- ram: 15.2 GB
- os: Microsoft Windows 10.0.26300
- os_build: 10.0.26300.0
- primary_monitor_dpi: 96
- elevated: false
- dotnet_runtime: .NET 10.0.12

## Method

- Publish mode: self contained, ReadyToRun, not trimmed, x64 for the measured builds (winui-sc, wpf-sc); framework dependent builds are sized only.
- Click to flyout: the shell's own open flyout entry point over the harness pipe; a synthesized click is not used because Windows 11 puts a new icon in the overflow area.
- Logon to icon, cold: empty-working-set.
- Logon to icon, warm: QPC before Process.Start to QPC when Shell_NotifyIcon(NIM_ADD) returned success, reported by the shell.
- Runs: rest 1 x 10 s, cpu 2 x 10 s after a 3 s warm up, click 3 opens per shell, logon 1 warm and 1 cold. Shells alternate run by run; medians use the mean of the two middle values for an even count.

## Private bytes at rest (MB)

| Shell | median | min | max | n |
|---|---|---|---|---|
| WinUI | 98.4 | 98.4 | 98.4 | 1 |
| WPF | 16.8 | 16.8 | 16.8 | 1 |

## Working set at rest (MB)

| Shell | median | min | max | n |
|---|---|---|---|---|
| WinUI | 128.0 | 128.0 | 128.0 | 1 |
| WPF | 63.8 | 63.8 | 63.8 | 1 |

## CPU while animating (% of one core)

| Shell | median | min | max | n |
|---|---|---|---|---|
| WinUI | 0.78 | 0.47 | 1.09 | 2 |
| WPF | 1.09 | 0.78 | 1.40 | 2 |

## Achieved frame rate while animating (frames per second, target 30)

| Shell | median | min | max | n |
|---|---|---|---|---|
| WinUI | 21.3 | 21.2 | 21.4 | 2 |
| WPF | 21.2 | 21.2 | 21.3 | 2 |

## Click to flyout (ms)

| Shell | median | min | max | n | first open (cold) |
|---|---|---|---|---|---|
| WinUI | 15.3 | 13.3 | 124.3 | 3 | 124.3 |
| WPF | 14.7 | 13.0 | 706.4 | 3 | 706.4 |

## Logon to icon, warm (ms)

| Shell | median | min | max | n |
|---|---|---|---|---|
| WinUI | 416 | 416 | 416 | 1 |
| WPF | 329 | 329 | 329 | 1 |

## Logon to icon, cold (ms), method: empty-working-set

| Shell | median | min | max | n |
|---|---|---|---|---|
| WinUI | 424 | 424 | 424 | 1 |
| WPF | 358 | 358 | 358 | 1 |

## Size on disk

| Shell | self contained (sc) MB | files | framework dependent (fd) MB | files |
|---|---|---|---|---|
| WinUI | 276.1 | 527 | - | - |
| WPF | 194.7 | 407 | - | - |

## Failures

None.
