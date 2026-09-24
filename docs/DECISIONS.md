# Decisions: the easy install run (v0.3)

One line per non obvious choice: the decision, then the reason. The
decisions of the app work live in `macos/DECISIONS.md`.

## Setup and environment

- Work happened in a Linux cloud container, not on a Mac: there is no Xcode, launchctl, codesign or hdiutil here. Everything Mac only (the app build, the Swift tests, `release-local.sh`) is exercised on GitHub Actions macOS runners; the CLI is tested locally under mocks and in CI under macOS `/bin/bash` 3.2.
- Branch `feat/easy-install` is pushed and a draft pull request opened against `main`: the brief for this environment allows exactly that remote write and nothing else (no tags, no releases, no settings).
- Conflict with AGENTS.md: it says never write LaunchAgents or `Procfile` yourself; this run changes the code that generates them (`adopt`, `install`). The brief wins; nothing was loaded on a real machine.
- bash 3.2 could not be built locally: the proxy blocks the GNU mirrors and only the project repository is reachable on GitHub. CI's macOS `/bin/bash` 3.2 is the bash 3.2 check.
- The mocked test suite was made to run on Linux too (GNU stat and sed, a `uname` mock, a fake uid): it gives fast local feedback here and a quick Linux job in CI, while the macOS job stays the one that counts.

## Stage 1: harden

- `benchbar report` masks by key name (password, secret, token, key, api, auth, case insensitive, anywhere in the key) rather than by value shape: values are unpredictable, key names are not. Over masking (for example `encryption_key`, `Authorization:` headers) is accepted.
- Header style `Key: value` masking runs to the end of the line, or to the next quote, comma or brace inside a one line JSON document, so a bearer token after `Authorization:` is gone but a JSON file is not wiped.
- The username and hostname are replaced by simple string substitution (any occurrence, no word boundaries, names shorter than three characters skipped): BSD sed has no `\b`, and replacing too much is safer than too little.
- Site config files are never copied; `site-config-keys.txt` lists their key names so a helper can still see whether, say, `developer_mode` or `db_host` is set.
- The report has no sensitive-line count guarantee: `REDACTIONS.txt` reports what was replaced per file so the sender can check before attaching.
- `report` works without a bench (versions only) so a tester whose install failed early can still send something.
- The CLI job in CI runs on `macos-latest`, the app jobs on `macos-26`: the project uses Xcode 26 build settings (default MainActor isolation) that the Xcode on `macos-latest` does not have. The old release workflow already targeted `macos-26`.
- CI also runs the CLI tests on `ubuntu-latest`: it finishes in a minute and catches most breakage before the macOS runner is even assigned.
- The old `macos-release.yml` failed on every push with "workflow file issue": its job level `env` read `${{ runner.temp }}`, and the `runner` context is not available there. The merged `release.yml` uses `$RUNNER_TEMP` in steps.
- `release-local.sh` is the ad hoc path of the release and is also what CI runs on every pull request to produce a downloadable app; `macos-release.sh` stays the Developer ID path.
- `macos-build.sh` takes `BENCHBAR_VERSION` and `BENCHBAR_BUILD` and passes them to xcodebuild instead of editing `project.yml` in CI, so the checkout stays clean and the tag decides the version.
