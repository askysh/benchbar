# BenchBar cloud session notes

You are in a Claude Code cloud session: Ubuntu 24.04 x86_64, no macOS. AGENTS.md still applies.

## What runs here
- CLI: `bash tests/run-tests.sh` (all) or `bash tests/run-tests.sh test-<name>`. Mocked, runs on
  Linux; macOS /bin/bash 3.2 in CI is the authority. Write bash 3.2 compatible code: no
  associative arrays, no mapfile/readarray, no ${var,,}, no negative array indexes, no &>>.
- Docs site: `cd site && bun install --frozen-lockfile && bun run build && bun run linkcheck`.
  If `bun --version` differs from site/.bun-version, stop: never commit a rewritten bun.lock.
- GitHub: use gh for runs, PRs, logs and artifacts (`gh run view --log-failed`,
  `gh run download`). Ignore `gh auth status`; it misreports the proxy's placeholder token.

## What does not run here
Xcode, the SwiftUI/AppKit app, Swift tests, launchctl, codesign, notarization, DMGs.
- For any change under macos/: push and let the ci.yml "app" job on macos-26 compile and test.
  Iterate until green.
- To see the UI: render snapshots in CI (macos/BenchBarTests/SnapshotTests.swift; the
  snapshots workflow or label if present on main), download the PNGs and look at them before
  claiming anything looks right. Offscreen renders draw the selected sidebar row and tab solid
  black; that is expected.
- If a download or log fetch is blocked, report the blocked host and stop that line of work.
  Do not work around the network policy.
- Anything that needs the real menu bar goes in a "Test on Mac" checklist in the PR.
- docs/images/window-*.png are real screenshots from Akash's Mac: never replace them with
  offscreen renders; list the ones to retake.

## How to work
- Read first, put the plan in the draft PR description, then proceed without waiting. Stop only
  for something irreversible or a scope question the repo cannot answer.
- Fan independent work out to parallel subagents.
- Non obvious choices: one line in docs/DECISIONS.md (CLI) or macos/DECISIONS.md (app). User
  facing changes: ## Unreleased in CHANGELOG.md. No version bumps unless asked.
- Never touch release secrets, signing, Sparkle, notarization or release.yml unless asked.
- No em dashes in anything you write.
- Finish with: PR links, CLI test result, CI status, and the Test on Mac checklist.
