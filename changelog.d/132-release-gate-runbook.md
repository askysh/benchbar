### Install

- The release notes now tell Homebrew users `brew upgrade --cask askysh/tap/benchbar-app` (a plain `brew upgrade` skips a cask that updates itself) and say that updating only the formula leaves the app's command line tool, the one that runs, on the old version (#132).

### For contributors

- The signed release job no longer runs the whole test suite again, which took 45 of its 52 minutes: it checks that the CI result of the tagged commit is green (`scripts/release-ci-gate.sh`) and builds (#132).
- `docs/releasing.md` has a runbook for a failed release run, a bad published release (mark it a pre-release, revert the tap, ship the next patch) and a leaked key (what to revoke and replace for each secret), and a checklist that says when a release candidate is required and what its live QA covers (#132).
