# Decisions

One line per non obvious choice: the decision, then the reason. The
decisions of the app work live in `macos/DECISIONS.md`. The 0.4 run comes
first, the 0.3 easy install run follows.

## 0.4: roadmap

- Work happens in a second git worktree (`~/dev/benchbar-work`): `~/.local/bin/benchbar` and the app run the checkout in `~/dev/benchbar`, so a feature branch checked out there would change the CLI in daily use. That checkout stays on main and is fast forwarded after each merge.
- Pulling a production site moved from the 0.7 plan to Ideas, as a wizard that also handles the encryption key and the app list mismatch: without those two it restores a site that cannot decrypt its passwords or fails on missing apps, and it is not scheduled yet.
- The old 0.4 items the brief did not schedule (worker restart on Python changes, more speed sources, a runner gallery, running one scheduler event) moved to Ideas; runner import from a zip was dropped from the list because 0.3 already ships it.

## 0.4: the v16 profile

Checked in frappe `version-16` at 012667b and bench `develop` at c9d1250 (September 2026), not from memory:

- v16 needs Python 3.14 exactly (`requires-python = ">=3.14,<3.15"`) and Node 24 (`engines.node >=24`); frappe itself only warns below Node 18 at build time, so the profile's pin is what enforces 24.
- frappe v16 refuses no MariaDB version: `check_compatible_versions` in `frappe/database/mariadb/setup_db.py` only warns below 10.6 or above 11.8, at new-site and restore. 10.11 gets no warning at all. The docs' 11.8 is a recommendation.
- wkhtmltopdf stays installed on v16: `pdf_generator` on Print Format defaults to `wkhtmltopdf` and a v16 patch sets every existing format to it; Chromium is opt in per format. So the check became `pdf_engine` (wkhtmltopdf everywhere, plus Chromium on v16) instead of swapping one tool for the other.
- Chromium is looked up the way frappe does (`find_or_download_chromium_executable`): `chromium_path` from common_site_config, else `<bench>/chromium/chrome-mac/headless_shell`. A missing one is a warning with `bench setup-chrome`, not a repair action: frappe downloads it on first use anyway, and its download removes `<bench>/chromium` first, which benchbar should not trigger on its own.
- `pkgconf` and `mariadb-connector-c` are system dependencies of every profile: v16 pins `mysqlclient==2.2.7`, which does not build without them. `pkg-config` is only an alias of `pkgconf` in Homebrew, and `brew list pkg-config` does not follow it, so the formula is named `pkgconf`.
- bench sets `PKG_CONFIG_PATH` itself from `brew --prefix mariadb-connector-c`, only for frappe 16 or newer on darwin, when it builds the env or installs an app. benchbar adds the same folder to its own exports (shell block, repair, phase 01) so a pip build outside bench finds it too. The launchd plist and the runner set no `PKG_CONFIG_PATH`, so nothing undoes bench's value; the running bench needs none.
- Missing build formulae are a warning, not a failure: a v15 bench runs without them and a v15 machine set up before 0.4 should not turn red.
- bench 5.31 depends on uv and uses it for the env by default (`BENCH_DISABLE_UV=1` turns that off), so "uv or pipx" only decides how the `bench` command itself is installed. uv wins when it is on PATH, as in the Frappe docs; an existing pipx `bench` is reported and never moved.
- honcho 2.0.0 imports `importlib.metadata`, not `pkg_resources`; only honcho 1.x breaks on Python 3.12 or newer without setuptools.
- The v16 CI row is a separate job running `tests/test-profile-v16.sh` on macOS `/bin/bash` 3.2: the rest of the suite asserts v15 strings on purpose, and a second full run would only repeat them.

## 0.4: doctor hardening

- Full Disk Access: frappe/bench#1730 (crontab "Operation not permitted" during `bench init`) is still open with no fix merged as of 2026-09-25; the rollback bench offers is a prompt (`click.confirm`), not automatic. benchbar passes `--no-backups`, which skips python-crontab entirely, and keeps a doctor check plus a warning before `bench init`, since `bench setup backups` would still need it.
- The probe is `crontab -l`: "no crontab for" and exit 1 is a normal answer, only "Operation not permitted" counts. Run from BenchBar the check reports ok without probing: the access that matters is the Terminal's, not the app's.
- The toolchain is four checks (`toolchain_node`, `toolchain_yarn`, `toolchain_pkgconfig`, plus `mariadb_version`), one line each in doctor's existing one line per check format. Python is not repeated: `env_python` already compares the env's version with the profile.
- Tools are resolved on the launchd PATH the agent uses, not the caller's: the forum case "nvm's node is not seen by bench" is exactly a node that only exists on the shell's PATH. `env/bin/node` wins when bench put one there.
- The MariaDB server version comes from the binary of the process listening on 3306 (`ps`), else the installed formula's client; doctor never logs in, so it never reads the Keychain. The range is frappe's own: below 10.6 unsupported, above 11.8 untested, both warnings.
- `honcho_setuptools` imports `honcho.command` with the interpreter in honcho's shebang instead of importing `pkg_resources` directly: honcho 2.0 does not need it, and a bare `pkg_resources` probe would warn on every healthy Python 3.12 venv. The repair installs setuptools into that venv (pipx or uv), never into the bench env, and adopt skips it like `honcho_install`.
- `fork_safety` reads the plist only: the variables reach honcho and every worker through the agent's environment, and `Procfile.lean` does not need to repeat them. `benchfg` sets them itself.
- `orphans` counts listeners on the bench's ports only when neither the agent nor a honcho runs the bench, so a bench started with `benchfg` is not reported.
- Found while testing: `doctor --json` with a failing check went through the ERR trap on its way to exit 1 and printed `[FAIL] Last command failed` on stdout after the JSON. The dispatcher now exits 1 itself, and test-json parses a failing report.

## 0.4: several benches

- Per bench settings live in the checkout, `.benchbar/benches/<name>.env`, not in the bench: benchbar writes only its service files into a bench, and a folder name is already the agent's unique key (`com.benchbar.<name>`), so it is a safe file name too.
- Keys that were per bench but global before 0.4 (`PROFILE`, `SITE_NAME`, `AUTOSTART`, `HONCHO_BIN`, `APP_BUNDLE`, `APPS`) are read from `state.env` for the default bench until its own file has them, and moved by the next writing command. Doctor and status stay read only, and an upgrade needs no migration step.
- When the default bench changes, its old settings move into its own file first, so `AUTOSTART=off` of the old default never leaks to the new one.
- A second `install`, `adopt` or `service` keeps the default bench (`--make-default` changes it): "set up a v16 bench to try something" must not change what `benchup` starts.
- A bench with no stored profile gets the one whose Frappe branch matches `apps/frappe/frappe/__init__.py` (`__version__ = "16.x"` is `v16-lts`), before the default profile: doctor on a freshly found v16 bench would otherwise judge it by v15 rules.
- The shell block's PATH lines follow the default bench's profile, and every bench renders the block the same way. Before, a v16 bench would have put Python 3.14 and Node 24 first in the user's shell, and the two benches' doctors would have called each other's block outdated forever.
- Phase 00 writes the shell block only when it is missing: it knows a profile but not which bench is the default. `service` and `repair` keep it current.
- honcho and socketio are matched by their working folder (`lsof -a -p PID -d cwd`): both start with a relative path (`honcho start -f Procfile.lean`, `node apps/frappe/socketio.js`), so the command line is identical in every bench. A process whose folder cannot be read is still matched, the pre 0.4 behaviour, since it is usually exiting.
- The runner (template v3) clears only its own bench's stale socketio at start, with the same working folder test; before, starting a second bench killed the first bench's socketio.
- The launchctl mock now stops only the agent's own honcho, so the tests can run two benches at once.

## 0.4: Codex review findings on PRs 10 to 12

- Bench paths are resolved once, in `fl_abs_path` (symlinks, `.` and `..`), so state, ports, the default bench and agents see one spelling per bench; a stored `BENCH_DIR` from before is compared through `fl_same_path`. A local review before pushing found a symlinked spelling clashing with its own ports and getting its own state file.
- The per bench state file is `<name>-<8 hex of the canonical path>.env` (cksum of `pwd -P`, so every spelling of a bench maps to one file; a plain `<name>.env` from the first 0.4 builds is read and renamed on the next write, by the default bench, or by a bench no other known bench shares the folder name with): `~/frappe-bench` and `~/dev/frappe-bench` are both detected candidates and would otherwise share one file. The agent label still uses the folder name only; two benches with the same folder name remain unsupported, as before 0.4.
- A bench installed with uv is looked up in `uv tool dir --bin`, which follows `UV_TOOL_BIN_DIR` and `XDG_BIN_HOME`, instead of assuming `~/.local/bin`.
- Phase 01 records the default bench only after the site is verified, so a failed `install --make-default` leaves `benchup` pointing at the bench that worked.
- With `--make-default`, the shell block is rendered for the bench being set up even in a dry run, so the plan shows the PATH change the real run makes.
- The `orphans` finding (a machine wide `pgrep` for honcho) was already fixed by the working folder match in the multi bench PR.
## 0.4: port blocks

- `bench init` already chooses ports: `make_ports` in bench's `config/common_site_config.py` takes max+1 over the benches in the same parent folder. benchbar keeps that and only moves a bench when it clashes with another bench it knows (anywhere under `~` or `~/dev`, or registered by an agent) or a port is taken by a listener.
- The block is written with frappe's own `bench set-config -g` (`-p` for the two integer ports) and the Redis files with `bench setup redis`, not by editing `common_site_config.json` or `config/redis_*.conf`: the AGENTS.md rule "never edit sites/" holds, and the files look exactly as bench would write them. The config is backed up first.
- `redis_socketio` is written equal to `redis_cache` and no `12000 + n` port is reserved: bench keeps the two equal "for backward compatibility", and neither frappe v15 nor v16 connects to it (v16 realtime uses `redis_queue`).
- Only a newcomer moves: the default bench (or the one about to become it) never changes ports on its own, and a bench moves only when it clashes with an established bench, one with a benchbar agent or the default. Found by the tests: without that rule, adopting the first bench on a Mac with two more unregistered benches moved the first bench off 8000.
- Moving ports is the `port_block` action of the same plan as the service files (a check that exists only while a plan moves ports, never in doctor): one confirmation covers it, and a cancelled adopt really changed nothing. Codex found the first version asking separately and moving the ports before the plan could still be cancelled.
- Listener ownership has two strictness levels. For the bench's current ports an unreadable working folder counts as its own, so it never moves on a guess; for a block it does not use yet, only a listener known to run inside the bench is its own (Codex found the first version trusting every listener on the current ports, which could then be killed by the runner's cleanup).
- `service --port-offset` validates the block before remembering the bench, so a refused block never makes it the default (Codex).
- The action rewrites `Procfile.lean` and the runner itself after the move: they carry the ports, and when the plan was made they may have been current and therefore not in it.
- `--port-offset` checks the block for conflicts even when it is the current one, so two benches already sharing block 0 are not confirmed by asking for block 0 (Codex).
- A newcomer also moves when a foreign process listens on its own ports, not only when a known bench has them (Codex). "Foreign" is decided by working folder: honcho starts redis, web and socketio inside the bench, and an unreadable folder counts as the bench's own, so nothing moves on a guess. The default bench is never moved for a listener either; it gets a warning.
- The port clash check now also reports a bench that is only configured with the same ports, since only one of them can run; `benchbar up` still asks only about a running one, so the app (which cannot answer) can start either bench.
- MariaDB ranges live in the profile (`mariadb_min`, `mariadb_max`). v16 uses frappe's own bounds, 10.6 to 11.8. v15's code warns above 10.8, but the v15 docs and this installer use 10.11, so v15's range ends at 10.11; the check is a warning either way, as in frappe.
- The toolchain's MariaDB check was named `mariadb_version` before 0.4 shipped, to match the brief; nothing released used the other name.

## 0.4: the MariaDB decision

- Option (a), decided with Akash on 2026-09-26 ("let's struggle and find out"): the v16 bench uses the `mariadb@10.11` server the v15 bench already runs on 3306. frappe v16 accepts it without a warning, and it keeps one server, one data folder and one Keychain password. Option (b) (a second `mariadb@11.8` service on 3307) stays possible later if v16 turns out to need 11.8.
- The supported path: when a MariaDB server runs on 3306 and its version is inside the profile's range, phases 00 and 01 and every command use that server's formula instead of the profile's (named from the server binary's `opt/<formula>` or `Cellar/<formula>` path, read with `ps`), and the formula is stored per bench (`MARIADB_FORMULA`) by phase 01 or the first `service`, `adopt` or `install`. Daily commands read only the stored value: `test-process` guards that `down` never touches port 3306, and a detection in every command's context broke that guarantee. So a v16 install on this Mac never installs or starts `mariadb@11.8`, and a machine without MariaDB still gets the profile's formula. `mariadb_version` in doctor checks the range per profile.
## 0.4: sites and the scheduler

- The default site is the one benchbar remembers per bench; `site default` also runs `bench use`, so `currentsite.txt` agrees, and rewrites the runner, whose ping embeds the site. `benchup`'s wait, `status` and the app all use it; a second site never changes it on its own.
- `site add` creates a new site only, on the same MariaDB server as the bench (option (a) of the MariaDB decision), with the Keychain password; it never drops or overwrites a site, and there is no `site drop` in 0.4.
- Apps for a new site come only from `apps/` (`--bundle` or `--apps`); a missing app is refused with the `bench get-app` command. Fetching apps belongs to the 0.6 app commands.
- A site's `ping_code` is only tried when something listens on the web port, so `list --json` on stopped benches costs no three second timeouts per site.
- `site hosts` asks once for all missing lines and uses one sudo prompt, through the existing marker block logic.
- `site list` takes no lock (it is read only); `add`, `default` and `hosts` take the checkout's lock like every other writing command.
- The scheduler line is an optional template line: a line that is only a token rendering to nothing is dropped. With the scheduler off, `Procfile.lean` renders byte for byte as before 0.4 (hash 92548cf35913 checked against the real bench), so no existing bench sees an outdated Procfile. The file's comment still says "no schedule" when it is on: changing it would change every existing Procfile's hash.
- The scheduler choice is per bench state (`SCHEDULER` in its state file), so `repair` renders the same Procfile and never undoes it; `status --json` reports `scheduler`.

## 0.4: found on a real Mac (v16 bench, 2026-09-26)

- The MariaDB root password of a bench set up before 0.3 was never in the Keychain, so phase 00 stopped with exit 2 as designed; Akash reset it with the documented recipe (databases kept, the v15 bench stopped around it with `benchbar down` and brought back with `benchbar up`), and the next run verified the new password and saved it to the Keychain.
- `bench init` in `~/dev/v16-bench` chose 8001, 9001, 11001, 13001 (and file watcher 6788) by itself, as a sibling of `~/dev/frappe-bench`; benchbar's port check agreed and moved nothing.
- On v16, `bench --site v16dev install-app erpnext` failed with "Error 61 connecting to 127.0.0.1:11001. Connection refused": frappe v16 connects to the bench's Redis during site setup, and a fresh bench has none running. Phase 01 and `site add` now start the bench's own Redis servers from `config/redis_*.conf` when nothing listens on their ports, and stop only the ones they started: the queue with `shutdown save`, so jobs an app install enqueued wait for the first worker, the cache with `nosave` (Codex). Redis startup errors go to the run log. A running bench's Redis is used as it is.

# The easy install run (v0.3)

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
- `benchbar adopt` is `benchbar service` with a positional path, validation and an explicit safety statement, run through the same engine restricted to the service group: that group has no `migrate`, `build`, `update` or env rebuild by construction. It remembers the bench only after the plan was applied or found unchanged, so a cancelled adopt never makes that bench the default (a Codex review finding).
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

## Found on the macOS runners

- A generated password reads a bounded 4 KB of `/dev/urandom`: BSD `tr` on an endless stream never exits when `head` closes the pipe and SIGPIPE is ignored, as it is under GitHub Actions. The CLI job hung on that for 45 minutes before the cause was found.
- The sudo keepalive owns no stdio and sleeps in five second slices: with the caller's stdout inherited, every `$(...)` capture of a run waited for its `sleep 50`, and on macOS never returned. The tests capture output, so this showed up only in CI.
- The `git` mock's pass through to the real git picks the first `git` on PATH outside `tests/mocks` and refuses to exec itself: on macOS `/bin/bash` 3.2, `command -v -p git` still returned the mock, which then exec'd itself in a loop at full CPU. This was the hang behind three timed out macOS CLI jobs; the Linux job never saw it. The test runner now kills a test after ten minutes and prints its process tree, which is how this was found.

## Review findings on the pull request

- `fl_wkhtmltopdf_ensure` returns 2 for a deliberate skip (Rosetta or the package declined, no sudo) and 1 for an error; the repair action reports a skip as `skipped`, and the engine's verify pass ignores the optional actions `wkhtmltopdf_install` and `redis_stop`, so a bench install without PDFs exits 0.
- The report's assignment style masking takes a quoted value whole (`key="secret"`, `key='secret'`): the unquoted form stopped at the quote and left the secret in place.
- `install.sh --app-only` skips the Command Line Tools and Homebrew checks: the prebuilt app needs only `curl`, `shasum` and `ditto`; macOS and the architecture are still checked.
- The installer's PATH block is generated from the configured bin folder (`BENCHBAR_BIN_DIR`), written as `$HOME/...` when it lives under the home folder.
- A refused up-front `sudo -v` sets `FL_SUDO_REFUSED=1`, exported to the phase scripts, so an install asks for sudo exactly once whatever the answer and skips every sudo step with a message after a refusal.
- A hosts line that cannot be written because sudo was refused is a skipped step with the manual command printed, and `hosts_entry` joins the optional actions, so a run the user chose to keep sudo free still ends with exit 0 and warnings.
- The repair engine resets `FL_STEP_RESULT` before each action and reports it, so a skipped wkhtmltopdf or hosts step prints `skipped`, the documented step status, not `done`.
- The report's assignment style masking also treats `?` as a key boundary, so a credential in a URL query string (`?api_key=...&x=1`) is masked like any other.
- `release-local.sh` no longer re-signs the app: `macos-build.sh` already signed it ad hoc with the Hardened Runtime and the entitlements, and a plain `codesign --force -s -` dropped both. The script verifies the signature and the runtime flag instead.
- Phase 01 no longer requires `wkhtmltopdf`: a bench without it works, only PDF printing does not, and phase 00 already said so when the package was declined.
- The report's quoted value patterns accept backslash escaped characters inside the quotes, so `"api_key":"abc\"tail"` is masked whole.
- The utf8mb4 doctor check also requires the `!includedir` line in `my.cnf` (a missing `my.cnf` counts as missing). The live `character_set_server` query that 0.3.0 added was removed in 0.3.1: it read the root password from the Keychain, and doctor is read only and runs on a timer in the app, so it must never touch the Keychain. A test asserts that doctor makes no `security` call.
- `adopt --dry-run` never touched state (`fl_state_set` is a no-op under `FL_DRY_RUN`); a test now proves it.

- The report also masks Python repr mappings (`'password': 'x'`): worker logs print dicts that way.
- `adopt` runs the engine with `FL_ENGINE_SKIP_ACTIONS=honcho_install`: a missing honcho is reported with `pipx install honcho` or `benchbar repair` as the fix, and nothing is ever installed into the bench's `env/` by adopt.
- Phase 00 tells a failed wkhtmltopdf install (download, checksum, installer) apart from a deliberate skip: it prints FAILED and a manual step, but still exits 0, since PDFs are optional and the bench can be created.
- A generated MariaDB password is written to the Keychain before it is applied to the server; when the Keychain refuses (locked), MariaDB is left unchanged and the run stops with the fix, so no password ever exists only in a dying process.

- Phase 01 exits 2, the documented "root password unknown" code, when a fresh site needs the MariaDB password and no source has it; `benchbar install` reports it as a pending manual step like phase 00 does.
- wkhtmltopdf detection prefers the package binary at `/usr/local/bin/wkhtmltopdf` when it is the patched build, and warns with `brew uninstall wkhtmltopdf` when an unpatched build earlier on PATH would shadow it: Frappe finds the binary through PATH, and the launchd PATH puts Homebrew's bin before /usr/local/bin.
- A missing `my.cnf` counts as a missing `!includedir` in the utf8mb4 check: without it the drop-in folder is never read.

## Found on a real Mac (macOS 27, Apple Silicon)

- Verified read only on the real bench: `install.sh --dry-run` and `--dry-run --uninstall` write nothing; `doctor` and `report --print` run clean (no home path, username, hostname or site config value in the report); `adopt` on an already adopted bench is a no-op that only remembers the path. `release-local.sh` builds, passes the 114 Swift tests, and `shasum -a 256 -c dist/SHA256SUMS` passes; the DMG (UDZO, read-only, Applications symlink) mounts and the unpacked app carries a valid ad hoc signature. Every macOS flag the mocks assume was checked against the man pages: `security add-generic-password -U`, `arch -x86_64 prog`, `softwareupdate --install-rosetta --agree-to-license`, `installer -pkg X -target /`, `ditto -x -k` and `-c -k --keepParent`, `hdiutil create -format UDZO`, `sw_vers -productVersion` (the man page lists `--productVersion`; the single dash form still works and is what macOS 12 and older knew).
- `benchbar report` replaces every name the Mac goes by, not only `hostname`: on the test Mac `hostname` returned the router's name (`Mac.lan`) while the Bonjour name from `scutil --get LocalHostName` was the identifying one. The computer name (`scutil --get ComputerName`) is included too, and the sed patterns built from those names, `$HOME` and the username are escaped, since a computer name can hold brackets or a dot.
- `install.sh --uninstall --dry-run` ended with "BenchBar removed": the uninstall summary has its own dry-run branch now, and `quit_app` prints what it would do instead of hiding the line behind the redirected `osascript`.
- The Gatekeeper dialog for a quarantined ad hoc build reads "BenchBar" Not Opened, Apple could not verify it is free of malware, with Done and Move to Trash (Move to Bin in British English) where Move to Trash is the highlighted default. README says so. The System Settings steps were not clicked: Open Anyway changes a security setting, which the brief reserves for the user.
- `fl_password_generate` and the sudo keepalive were exercised on macOS `/bin/bash` 3.2: the generator returns 24 characters at once, also with SIGPIPE ignored, and 4 KB of urandom never yields fewer than about 900 usable characters; a captured `fl_sudo_begin` returns immediately and its keepalive exits within one five second slice of the parent leaving.
