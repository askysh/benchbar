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
- `REDACTIONS.txt` reports what was replaced per file, so the sender can check the bundle before attaching it.
- `report` works without a bench (versions only) so a tester whose install failed early can still send something.
- The CLI job in CI runs on `macos-latest`, the app jobs on `macos-26`: the project uses Xcode 26 build settings (default MainActor isolation) that the Xcode on `macos-latest` does not have. The old release workflow already targeted `macos-26`.
- CI also runs the CLI tests on `ubuntu-latest`: it finishes in a minute and catches most breakage before the macOS runner is even assigned.
- The old `macos-release.yml` failed on every push with "workflow file issue": its job level `env` read `${{ runner.temp }}`, and the `runner` context is not available there. The merged `release.yml` uses `$RUNNER_TEMP` in steps.
- `release-local.sh` is the ad hoc path of the release and is also what CI runs on every pull request to produce a downloadable app; `macos-release.sh` stays the Developer ID path.
- `macos-build.sh` takes `BENCHBAR_VERSION` and `BENCHBAR_BUILD` and passes them to xcodebuild instead of editing `project.yml` in CI, so the checkout stays clean and the tag decides the version.

## Stage 2: the manual steps

- The MariaDB root password goes into the macOS Keychain (service `benchbar-mariadb`, account `root`) through `security add-generic-password -U`: the only non interactive way to write a Keychain item. The password is an argument of that one call; everywhere else it travels in `MYSQL_PWD`, never on a command line. The mocked test asserts that no call log ever contains it.
- Order of password sources: `MARIADB_ROOT_PASSWORD`, then the Keychain, then a prompt. A password that verifies against the server is always saved, whatever its source, so the next run needs no source at all.
- The secure installation is plain SQL (`DELETE FROM mysql.global_priv` for anonymous and remote root, `DROP DATABASE test`, `ALTER USER ... IDENTIFIED VIA mysql_native_password`): `mariadb-secure-installation` is interactive and the answer table in the old README was the whole reason it was manual. Native password auth is kept on purpose: Frappe needs it.
- Phase 00 exits 2 only when MariaDB already has a root password that no source knows and there is no terminal to ask; every other former manual step is automated or skipped with a warning, so `benchbar install --yes` normally finishes in one run.
- A generated password is 24 letters and digits: safe in SQL, in a shell and on bench's own `--mariadb-root-password` argument, which cannot be avoided.
- The pinned wkhtmltopdf is 0.12.6-2 from github.com/wkhtmltopdf/packaging, sha256 `81a66b77...94f8`, computed from a download made during this run. The package's binary is x86_64 only (checked by reading the Mach-O header inside the nested tarball: cputype 0x01000007, no arm64 slice), so on Apple Silicon Rosetta 2 is required and offered first; declining it or the download only costs PDFs, and the run continues.
- Rosetta is detected with `arch -x86_64 /usr/bin/true`, not by looking for the daemon: it is what the binary will actually need.
- Downloads land in `.benchbar/downloads/` and are reused when their checksum matches, so a re-run after a failed `installer` does not fetch 50 MB again.
- One sudo prompt per run: `benchbar install` looks ahead (patched wkhtmltopdf present? hosts line present?) and runs `sudo -v` with a keepalive before phase 00; the phase scripts inherit the session through `FL_SUDO_SESSION` and sudo's own per terminal timestamp. Standalone `00-mac-system-deps.sh` asks itself, only when it gets to the package.
- The `/etc/hosts` line sits inside `# >>> benchbar >>>` markers. A missing block is appended with `sudo tee -a`; an existing block gets the new line inside it through a temp copy and `sudo cp`, after `fl_backup_file`. Rewriting the whole file is limited to the second case.
- The utf8mb4 drop-in and wkhtmltopdf became doctor checks with repair actions (`mariadb_utf8`, `wkhtmltopdf_install`): the same code serves phase 00 and `benchbar repair`, and the tester guide can say "run doctor".
- `benchbar adopt` is `benchbar service` with a positional path, validation and an explicit safety statement, run through the same engine restricted to the service group: that group has no `migrate`, `build`, `update` or env rebuild by construction. It records the bench first, so a cancelled plan still leaves the bench remembered.
- `benchbar mariadb-password` asks before printing unless `--yes`: a terminal print is a deliberate act, and the app or a script can pass `--yes`.
- The mocks gained state (`mariadb_root_pw`, a keychain folder, `wkhtml_installed`, `rosetta`, `sudo_refused`, `download_payload`) instead of environment switches, so a test reads like a machine's history.

## Stage 3: install.sh

- `install.sh` is self contained bash 3.2 with its own small output helpers: it runs before the repository exists on the machine, so it cannot source `lib/`.
- Prompts read and write `/dev/tty` so `curl | bash` can ask; without a usable tty every question takes its default (`--yes` does the same). Defaults are "yes" for the things the person asked for (Homebrew installer, adopt) and "no" for anything destructive (removing agents or the checkout on `--uninstall`, where `--yes` flips them to yes because that is what a non interactive uninstall means).
- The CLI is cloned into `~/.local/share/benchbar` and updated with `git pull --ff-only`; `--version` pins the app only. Pinning the CLI to a tag would leave a detached checkout that the next `git pull` cannot update.
- `benchbar` and `frappe-mac` are symlinks into the checkout, so `git pull` is the whole CLI update; a regular file at either path is left alone with a warning.
- The PATH block in `~/.zshrc` uses its own markers (`# >>> benchbar-path >>>`): the CLI's `# >>> benchbar >>>` block is regenerated by `repair` from a template and only exists after `install` or `adopt`.
- The app zip is checked against the release's `SHA256SUMS`; a release without that file is refused, not installed unchecked. The installed version is read from `Info.plist` with awk (no `plutil`, so the same code runs in the Linux tests).
- The app is unpacked with `ditto -x -k` and copied with `ditto`: the tools macOS uses for bundles. Because `curl` writes the download without the `com.apple.quarantine` attribute, Gatekeeper never assesses the app on first open. That is the reason the one liner is the recommended install for an ad hoc signed build; the DMG path gets the "Open Anyway" steps in README instead.
- A found bench is offered to `benchbar adopt`, which keeps its own plan and question; `install.sh` only passes `--yes` on when it was given `--yes`. `benchbar install` is never started without a terminal: it needs the Administrator password.
- On an Intel Mac the app is skipped with a warning (it is built for arm64 only); the CLI installs.
- `--uninstall` removes only what the installer made (app, links, PATH block), offers `benchbar uninstall-service` per `com.benchbar.*` agent and the removal of the checkout, and never lists or touches a bench folder.
- The tests drive `install.sh` against a fake HOME with a `git` mock that copies this checkout, a `curl` mock that serves a release JSON, zip and `SHA256SUMS` from the mock state, and a `ditto` mock on top of `unzip`; scenarios: no release, fresh, unchanged rerun, upgrade with a running app, version pin, tampered zip, `--no-app`, `--app-only`, `--dry-run`, adopt offer, Intel, `--uninstall` twice.

## Stage 4: releases

- One `release.yml` replaces `macos-release.yml`: a `check` job reads the secrets and picks the path; the build job runs `scripts/macos-release.sh` (Developer ID, notarized, Sparkle, cask) or `scripts/release-local.sh` (ad hoc). Everything after the build is shared: notes from the CHANGELOG section, a workflow artifact, a draft release, uploads with `--clobber` so a re-run replaces files.
- The version comes from the tag and is passed to xcodebuild (`BENCHBAR_VERSION`, `BENCHBAR_BUILD` = commit count) instead of editing `project.yml`; the workflow still refuses a tag that disagrees with `MARKETING_VERSION` or has no CHANGELOG section, so the source of truth stays in the repo.
- Releases are created as drafts: the person publishes after looking at the files. `workflow_dispatch` with a version builds the artifact without touching releases, for a rehearsal.
- Sparkle stays out of the ad hoc path: unsigned updates would defeat its purpose, and the ad hoc app contains no update code.
- The DMG carries an Applications symlink and is not signed on the ad hoc path (signing a DMG ad hoc buys nothing); Gatekeeper's warning is expected and documented with the macOS 15 "Open Anyway" steps in README.
