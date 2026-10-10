# BenchBar Linux session notes

You are in a local Claude Code session on Linux, most likely Ubuntu 24.04 inside WSL on
Akash's Windows laptop. AGENTS.md still applies. This distro is disposable: benches and MariaDB
here are test material, not anyone's real work.

## What runs here
- CLI tests: `bash tests/run-tests.sh` (all) or `bash tests/run-tests.sh test-<name>`. They run
  under mocks; macOS `/bin/bash` 3.2 in CI is the authority for the Mac. Write bash 3.2
  compatible code: no associative arrays, no mapfile/readarray, no ${var,,}, no negative array
  indexes, no &>>.
- The real CLI on Linux: `./benchbar install`, `up`, `down`, `doctor --json`, `status --json`,
  against real MariaDB, Redis, uv Python and fnm Node, with each bench under `systemd --user`
  (`systemctl --user status 'benchbar-*'`, `journalctl --user -u <unit>`).
- Opening a URL in Windows: `wslview URL`. A site at `http://<name>.localhost:8000` answers from
  Chrome on Windows because WSL forwards localhost.
- GitHub: `gh` for runs, PRs, logs and artifacts (`gh run view --log-failed`).

## What does not run here
Xcode, the Mac app, Swift tests, launchctl, codesign, notarization, DMGs, the Keychain.
- For any change under macos/: push and let the ci.yml "app" job compile and test it.
- Anything that needs the real menu bar goes in a "Test on Mac" checklist in the PR.
- Never put a bench or state under /mnt/c (that is Windows) and never run `wsl.exe --unregister`.

## How to work
- Read first, put the plan in the draft PR description, then proceed without waiting. Stop only
  for something irreversible or a scope question the repo cannot answer.
- Fan independent work out to the agents in .claude/agents (linux-layer for lib/ and tests/,
  test-runner for test runs, Explore for searches, reviewer before marking a PR ready).
- `sudo` needs a password here unless Akash set it up otherwise; ask before a step that needs it.
- Non obvious choices: one line in docs/DECISIONS.md. User facing changes: ## Unreleased in
  CHANGELOG.md. No version bumps unless asked. Never touch release.yml, signing or Sparkle.
- No em dashes in anything you write.

## How to finish
PR links, Linux test result, CI status per job, and a "Test on Windows" or "Test on Mac"
checklist for what only a person can check.
