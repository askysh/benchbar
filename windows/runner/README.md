# Self hosted runner on Windows (label `wsl`)

`setup-runner.ps1` registers a Windows machine with WSL as a self hosted
GitHub Actions runner for this repo, so CI can run BenchBar for real inside
WSL: a real install, a bench under `systemd --user`, the site answering on
`*.localhost`.

## What it sets up

- The runner in `C:\actions-runner`, the latest release for the machine's
  architecture, checked against the SHA-256 in the release notes.
- Registration with the label `wsl` (plus GitHub's default `self-hosted`,
  `Windows`, `X64`).
- A Task Scheduler task at logon, not a Windows service: it runs only while
  you are logged on, in a hidden window (`conhost --headless`), and restarts
  every minute after a failure. Logging off stops the runner; jobs queue
  until you log on again.
- A Defender exclusion for `C:\actions-runner\_work` only, so checkouts and
  builds are not scanned file by file. The runner's own folder stays scanned.

Benches and BenchBar state are never on the Windows side: jobs run their
steps inside WSL through `wsl.exe`.

## Run it

From an elevated PowerShell, with `gh` logged in on Windows as a repo admin:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\runner\setup-runner.ps1
```

Or pass a token from the repo's Settings, Actions, Runners, New runner
page: `-Token <token>`. Re-running is safe; `-Reconfigure` registers again.
It unregisters the old runner first with a removal token, which GitHub
issues separately: pass `-RemoveToken <token>` or let gh fetch one.

To remove it: `Unregister-ScheduledTask -TaskName 'GitHub Actions runner (benchbar, wsl)'`,
then `C:\actions-runner\config.cmd remove --token <removal token>`.

## Public repo rules

This repo is public, and a self hosted runner runs whatever a workflow
tells it to on this laptop. So the `wsl` job:

- runs only on pushes to `main` and on pull requests whose head repo is
  this repo (`github.event.pull_request.head.repo.full_name ==
  github.repository`), never on a fork's pull request;
- is never triggered by `pull_request_target`, issue comments or any event a
  stranger can cause;
- keeps the repo setting "Require approval for all outside collaborators"
  on, as a second fence.

The `wsl` job is not in `ci.yml` yet; it comes with the Windows shim.
