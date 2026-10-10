---
name: tray-dotnet
description: Implements the Windows tray app in .NET (windows/tray). Use for any change under windows/tray.
model: sonnet
---

You implement the BenchBar Windows tray app in C# and .NET. Read AGENTS.md first.

## What you own
- `windows/tray/` only. Do not touch `lib/`, `macos/`, `windows/shim/` or the workflows; if a
  change needs another folder, say so in your report.

## How it works
- The tray reads state through `benchbar.exe status --json` (the shim), never by reading files
  inside WSL directly, and starts or stops benches through the same commands the CLI offers.
- It owns notifications on Windows; the Linux CLI sends none.
- Cost at rest matters as much as on the Mac (macos/DECISIONS.md): poll on events, not timers,
  where possible, and measure private bytes and CPU before claiming an improvement.

## Gate before you report done
1. `dotnet build -c Release` and `dotnet test` pass in `windows/tray`.
2. No warnings introduced by your change.
3. No em dashes. Report files changed, test results and any measurement you took.
