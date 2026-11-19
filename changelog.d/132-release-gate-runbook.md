### Install

- `install.sh --version vX.Y.Z-rc.N` now also checks out that candidate's CLI on a Mac, and so does `--no-app` with `--version` (the CLI only install), where before only the app was pinned. Homebrew and `benchbar self-update` cannot install a release candidate, and the candidate's notes say so (#132).
- The release notes now tell Homebrew users `brew upgrade --cask askysh/tap/benchbar-app` (a plain `brew upgrade` skips a cask that updates itself) and say that updating only the formula leaves the app's command line tool, the one that runs, on the old version (#132).

### For contributors

- The signed release job no longer runs the whole test suite again, which took 45 of its 52 minutes: it checks that the CI result of the tagged commit is green (`scripts/release-ci-gate.sh`) and builds. A docs only commit runs no tests, so the check also needs a green result on the nearest commit that changed code (#132).
- `scripts/release-promote.sh` cuts a release: it checks that `main` is an ancestor of `next-release`, the version, the tag and CI, shows the plan and fast forwards `main` (`--dry-run`, `--yes`) (#132).
- `docs/releasing.md` has a runbook for a failed release run, a bad published release (mark it a pre-release, revert the tap, ship the next patch) and a leaked key (what to revoke and replace for each secret), and a checklist that says when a release candidate is required and what its live QA covers (#132).
