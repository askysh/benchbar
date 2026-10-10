# BenchBar Windows session notes

You are in a local Claude Code session on Windows (PowerShell or Git Bash). AGENTS.md still
applies. Benches never run on Windows itself: they run inside WSL, and Windows only has the
shim (`windows/shim`, Go) and the tray app (`windows/tray`, .NET).

## What runs here
- The shim: `cd windows/shim; go vet ./...; go test ./...; go build`.
- The tray: `cd windows/tray; dotnet build -c Release; dotnet test`.
- The CLI through WSL: `wsl.exe -d <distro> -- benchbar status --json`, or `benchbar.exe` once
  the shim is built. Read bench state through the CLI, never by reading `\\wsl$` files.
- GitHub: `gh` for runs, PRs, logs and artifacts.

## What does not run here
- The bash test suite and the CLI itself: run them inside WSL (`wsl.exe -- bash tests/run-tests.sh`
  from the repo checkout inside the distro, not from a Windows checkout).
- Xcode, the Mac app, launchctl, codesign, notarization.
- Never put a bench or BenchBar state on a Windows drive, and never run `wsl.exe --unregister`.
- Defender exclusions and Task Scheduler changes need an elevated prompt: ask first.

## How to work
- Read first, put the plan in the draft PR description, then proceed without waiting. Stop only
  for something irreversible or a scope question the repo cannot answer.
- Fan independent work out to the agents in .claude/agents (shim-go, tray-dotnet, test-runner,
  Explore, reviewer).
- Non obvious choices: one line in docs/DECISIONS.md (CLI and shim) or the tray's own decisions
  file once it exists. User facing changes: ## Unreleased in CHANGELOG.md. No version bumps.
- No em dashes in anything you write.

## How to finish
PR links, test results, CI status per job, and a "Test on Windows" checklist.
