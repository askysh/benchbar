# BenchBar decisions

One line per non obvious choice: the decision, then the reason.

## Folder discovery

- Scan Folder opens a native directory picker and routes results to a persistent Find Benches pane: a long, selectable result list does not fit the menu bar popover.
- Adding a bench and setting up management are separate actions; setup previews the existing adoption command and checks for running processes again before applying it.
- Cancelling a scan invalidates its generation as well as cancelling its task: a late subprocess result must not replace a newer selection or repopulate a cancelled scan.
- Duplicate bench names show their parent folder in the sidebar, and scan results always show full paths: the user must be able to distinguish projects before configuring a service.

## 0.5.5: about and help

- The update check is a button, not a timer: one `GET` of GitHub's latest release with a User-Agent (GitHub refuses requests without one), `Accept: application/vnd.github+json`, a 10 second limit and an ephemeral session (no cookies, no cache). Unsigned builds until 0.6 mean no Sparkle and no download: the answer links to the release page.
- Versions compare part by part as numbers (0.10 after 0.9), a missing part is 0, a leading `v` is dropped and a prerelease sorts before its release. A version that does not parse (a local build) is never told to update.
- A Sparkle build keeps Sparkle's own Check for Updates item; the default build gets one that opens the About pane and runs the check there, so the answer is visible.
- Report a Bug lives as a sheet on the About pane; the Help menu opens the pane and sets a flag on `WindowRouter` that the pane turns into the sheet, like `repairRequested`. The sheet explains what the zip holds before anything runs.
- After `report --json`, Finder selects the zip (`activateFileViewerSelecting`) and the browser opens `issues/new?template=bug_report.yml&macos=...&version=...`; nothing is uploaded. A CLI older than 0.5.5 prints text instead of JSON, and the sheet says to run `benchbar report` in Terminal.
- The report is of the selected bench (`--bench-dir`): the one the person is looking at when something went wrong.
- About BenchBar in the menus opens the About pane, not `orderFrontStandardAboutPanel`: the pane has the CLI version and the links, the standard panel had neither.
- Help > Keyboard Shortcuts opens General and scrolls to its shortcuts section (a `ScrollViewReader` around the form and a `scrollTarget` on the router) instead of a second list of shortcuts that could drift.
- The status item menu gets About and Documentation, the two things a person looks for there when the window is closed.
- `CLIClient.version()` returns only the first line of `benchbar --version`, which a 0.5.5 CLI follows with the app's version.
- Links live in one `BenchBarLinks` enum, with the same paths as `benchbar docs`.
- The live app could not be driven with the computer use tools on this Mac (an ad hoc signed accessory app is not in their app list), so the About pane, both sheet states and the empty popover are checked through snapshots, and the menus through a unit test of the built `NSMenu`.

## Setup

- Branched `feat/benchbar-app` from `origin/main` at 7f0653e: the CLI work was already merged there, as the brief's update said.
- Pointed `origin` at `https://github.com/askysh/frappe-mac-dev-server.git`: the repo was renamed.
- Installed XcodeGen 2.46 with brew; Xcode 27.0 (Swift 6.4) is the toolchain.
- Conflict with AGENTS.md: it says "never write your own LaunchAgents"; this run changes the CLI templates that write them (label, AssociatedBundleIdentifiers). The brief wins; nothing was loaded or written on the real machine.

## Phase 0: CLI

- `benchbar` is the real file, `frappe-mac` is a symlink to it: the entrypoint already resolves symlink chains, so `~/.local/bin/frappe-mac` from 0.2.0 keeps working without a wrapper.
- CLI version 0.3.0: 0.2.0 was the frappe-mac release in CHANGELOG; the roadmap's "v0.2 BenchBar alpha" is a product milestone, not the CLI version (open question in the summary).
- Kept internal names: `FL_` variable prefix, `.frappe-local/` state dir, `frappe-mac-run.sh`, the `# >>> frappe-mac >>>` rc markers and the `frappe-mac-template:` header token. Renaming them would mark every installed file as foreign and force needless rewrites. (Superseded for the user visible ones: see "Rename follow-up" at the end.)
- Kept the MariaDB drop-in templates byte for byte: a changed comment would make repair restart MariaDB for nothing.
- Shell helper variable is now `BENCHBAR` (was `FRAPPE_MAC`); helper names are unchanged.
- `~/.local/bin` gets both `benchbar` and `frappe-mac` links; an old `frappe-mac` link that points at the checkout's `frappe-mac` counts as current.
- Old agents move to `~/Library/LaunchAgents-disabled/<timestamp>/<file>.plist` (was `<name>-<timestamp>/`), as the brief asks.
- `com.frappe-mac.*` plists are migrated only when their `WorkingDirectory` is this bench, so repairing one bench never unloads another.
- Migration remembers whether the bench was running before bootout and kickstarts it under the new agent, so a repair does not silently stop a running bench.
- `status --json`: `state` now carries the contract value (stopped, starting, running, crashed, paused); launchd's word moved to `agent_state`. All other 0.2.0 fields stay. `bench` stays the absolute path (it is the unique key); the folder name is `name`.
- `doctor --json` checks carry both `level`/`fix_command` (contract) and `status`/`fix` (0.2.0).
- Added `stop_reason: "broken"` next to `manual | crash | null`: a missing env needs `repair`, not `benchup`, and the app should say so.
- `web_ping_code` is `null` when nothing answered (the CLI's internal "000").
- `started_at` keeps the last run's start after it stops, so the app can show "stopped, last run started at".
- The runner no longer `exec`s honcho: it runs it as a child, traps SIGTERM and forwards it, so it can write the final transition. launchd still kills the whole process group on bootout.
- A SIGTERM without a stop flag (kickstart -k, logout) records `stopped`, not `crashed`, and exits 0.
- One background ping loop in the runner (every 2 s for 4 min) writes `running`; `status` stays the truth because it checks processes and the site live.
- The runner skips its osascript notification while a process named `BenchBar` runs, so people with the app get one notification, not two.
- `BENCHBAR_STATE_LOG` makes the runner append every transition to a file: used by the tests, harmless in production.
- Fixed in passing: reading a missing stop flag printed "No such file or directory" on stderr (redirect order).

## Phase 1: app skeleton

- AppKit app lifecycle (`main.swift` plus `AppDelegate`) instead of a SwiftUI `App`: a menu bar only app needs no scenes, and it keeps the Settings window pattern under our control.
- Swift 6 language mode with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (the Xcode 26 template default): UI code needs no annotations, background work is marked `nonisolated` on purpose.
- Tests are hosted in the app (`TEST_HOST`), so `@testable import BenchBar` works; the app skips its real startup under XCTest.
- Info.plist is generated by XcodeGen from `project.yml` and gitignored, like the `.xcodeproj`.
- Sparkle sits in `macos/sparkle.yml`, included only when `BENCHBAR_SPARKLE=YES`: the default build has no Sparkle code or network fetch.
- Arm64 only (`ARCHS = arm64`), macOS 14 deployment target, as locked.
- `scripts/macos-build.sh` signs with `codesign --options runtime --sign -` after `xcodebuild`, so the app in `macos/build` always has the Hardened Runtime flag even though the ad hoc identity cannot be notarized.
- `scripts/macos-install-local.sh` quits a running copy through Apple Events first and falls back to `pkill -x BenchBar`.

## Phase 2: talking to the CLI

- swift-subprocess 1.0.0 (not Foundation `Process`): it supports macOS 13+, so it works with the macOS 14 target, and gives async/await, output limits and a teardown sequence on cancel.
- Timeouts race the command against `Task.sleep` in a task group; cancelling the loser makes swift-subprocess send SIGTERM, wait 2 s, then SIGKILL.
- The environment inherits the app's (HOME, USER, TMPDIR, SHELL) and overrides PATH, NO_COLOR, TERM and LANG; a fully custom environment would lose TMPDIR and SHELL, which the CLI uses.
- stdin is closed and `--yes` is never passed: if the CLI needs to ask (a port clash), it answers no and fails with a message the popover shows.
- `~/.local/bin/frappe-mac` is a last fallback after the four locations in the brief: installs from before the rename only have that link until `benchbar repair` runs.
- A user CLI path that is not executable is an error, not skipped, so a typo in Settings is visible.
- Unknown `state`, `stop_reason` and `level` values decode as `.unknown`; a `schema_version` above 1 is refused with "update BenchBar".
- `doctor` exit code 1 is accepted when stdout is a valid report (it means a check failed, not that doctor failed).
- Failed actions show the CLI's `[FAIL]`/`[WARN]` lines, or the last three lines when there are none.
- `tests/test-json.sh` compares the live CLI output's keys with the app's fixture files, so the fixtures cannot drift from the CLI.
- Test helpers are `nonisolated`: the test target also defaults to MainActor.

## Phase 3: state store

- The state logic is a pure value type, `BenchStateMachine`: events in, effects (alert, ping, refresh) out. The store does the I/O. This keeps every transition unit-testable without a CLI, clock or file system.
- `status --json` is the truth; `state.json` is a fast hint applied first, then confirmed by a status call. Both go through the same machine.
- Start and restart are optimistic (show "starting" at once). While an action is in flight, an observed state from before it (stopped during a start, running during a stop) is ignored as stale.
- Crash-guard alerts fire on any move into `paused` with reason `crash`, not only from `crashed`: a 30 s poll can miss the short crashed state between launchd retries.
- The watcher watches the folder `logs/.benchbar`, not `state.json`, because the runner replaces the file with `mv`. If the folder is missing, it watches the parent until it appears; the app never creates folders in a bench.
- Folder events are debounced by 150 ms: one `mv` gives several events.
- Status calls for one bench never overlap; a request during a call is coalesced into one more call afterwards.
- Poll every 30 s (5 s tolerance) with the popover closed, every 5 s (1 s tolerance) while it is open; tolerance lets macOS batch wakeups.
- The site ping is raw HTTP/1.1 over `NWConnection` to 127.0.0.1 with the site in the Host header, like the CLI, because URLSession will not send a custom Host header. It runs once after a successful start, then triggers a refresh.
- `suspend()` / `resume()` exist on the store for sleep and wake; wiring them to `NSWorkspace` notifications is left to Phase 5, with the popover.

## Phase 4: animated runner

- Frames are tinted in code, not shown as template NSImages: a CALayer ignores `isTemplate`, so the animator fills each frame's alpha with `labelColor` resolved in the button's `effectiveAppearance` and re-tints on appearance changes. A mask layer would avoid the re-tint, but its timing parent is unclear, and layer.speed must work.
- Pose names (`sleeping, starting, running, crashed, alert, unknown`) are the manifest keys from the Phase 7 format, so built in and custom runners share one model.
- crashed and paused map to the same plan, and the same plan twice is a no-op, so crashed to paused does not start the stumble over.
- The stumble is one non repeating keyframe animation (stumble x3, then the alert frames); the layer's model `contents` is the alert frame, so it rests there with no completion callback.
- Base rates: running 5 fps at speed 1 (60 fps at speed 12), walking 6, stumble 8, sleeping and still poses 2. Only the running loop follows `layer.speed`.
- CPU is summed over cores, so 110% (about one busy core) is already top speed, as the brief's formula gives.
- Processes are keyed by pid plus start time; a process that appears between samples counts all its CPU time only if it started after the last sample, and exited ones drop out, so the total never goes negative.
- EMA alpha 0.35: a single busy sample moves the speed about a third of the way.
- Both runners are 24 pt wide (48 px @2x) so the "z", "!" and "?" marks fit beside the character.
- No RunCat code or art was used; the technique (keyframes on `contents`) is standard Core Animation, so no NOTICE entry is needed.
- Sleep, screen sleep, lock and session resign also suspend the store's polling and watchers (the Phase 3 note left this for Phase 5).
- The app skips all startup when `XCTestConfigurationFilePath` is set, as the Phase 1 note says; the placeholder app had nothing to skip before.
- Until the popover (Phase 5) the status item has a one item menu, Quit BenchBar.

## Phase 5: menu and settings

- Left click opens the popover, right click or control click shows a two item menu (Settings, Quit): the standard menu bar convention, and a way out if the popover ever misbehaves.
- The app activates itself before showing the popover and then clears the first responder: without activation the ⌘ shortcuts never reach it, and without clearing, Stop starts focused and a Space stops the bench.
- Shortcuts follow the CLI helpers: ⌘U up, ⌘D down, ⌘R restart; ⌘O site, ⌘L logs, ⌘F folder, ⌘K doctor, ⌘, Settings, ⌘Q quit.
- Button rules live in a pure `BenchControls`: a bench with `stop_reason: broken` or without an agent cannot be started from the app, and shows `benchbar repair --bench-dir ...` with a Copy button instead. The app never runs repair itself (the brief keeps doctor read only in v0.2).
- Open logs writes a `.command` file under the app's temp folder and opens it with Terminal: no Apple Events entitlement or permission prompt, unlike "tell application Terminal to do script". It runs `benchbar logs`, which execs `tail -f` when it has a terminal.
- Settings is an AppKit window hosting SwiftUI (not the SwiftUI `Settings` scene), with the .regular / .accessory activation policy switch from the brief.
- A small main menu (app, Edit, Window) exists only so ⌘C, ⌘V, ⌘W work while Settings is open.
- The runner preview in Settings reuses RunnerAnimator at 2x, running at speed 3, and respects Reduce Motion.
- Launch at login shows the SMAppService status; "not found" gets an explanation (a copy in DerivedData or a disk image cannot register).
- The CLI file picker is shown automatically once, only when the CLI is not found anywhere (`askedForCLI`); after that, Settings and the popover have Choose buttons.
- Snapshot tests render the popover and Settings to PNG, gated on `~/Library/Caches/BenchBarSnapshots` existing, because xcodebuild passes neither environment variables nor its TMPDIR to a hosted test.
- The notifications toggle is stored now and used in Phase 6.

## Phase 6: notifications

- Permission is asked on first launch only if notifications are on (the default), and again only when the user turns the toggle on while macOS has never been asked; a denial shows a button to System Settings.
- One notification identifier per bench and kind (crashed, paused, recovered): a crash loop replaces its banner instead of stacking them.
- Crash and crash guard notifications play the default sound; recovery is silent.
- Banners show even while BenchBar is active (`willPresent` returns banner, sound, list), since the popover being open makes BenchBar the active app.
- Clicking a notification selects that bench and opens the popover; other actions (dismiss) do nothing.
- Not tested end to end with a real crash: that needs a throwaway bench with a loaded LaunchAgent, which the brief's hard stops rule out without asking. The transitions are covered by the state machine tests and the wording by NotifierTests.

## Phase 7: custom runners

- `frame_order` (optional in the brief, unspecified) is `"forward"` (default) or `"ping_pong"` (1 2 3 2): the one ordering option that saves artists frames.
- Unknown state names are errors, not ignored: a typo like "runing" would otherwise silently fall back to running.
- A state listed with no frames is an error ("leave it out instead"), so fallback is always explicit.
- The 2 MB limit counts every regular file in the folder, and a zip is refused before unpacking if its listing has more than 200 files or more than 4 MB unpacked.
- Import copies only manifest.json and the listed frames, staged and then swapped in, so a bad or partial import never leaves a half runner behind.
- The id is the folder name made safe (lowercase, `[a-z0-9._-]`); for a zip it is the single folder inside, or the zip's name. Re-importing the same id replaces it. `bench` and `cup` are reserved.
- Remove moves the runner to the Trash instead of deleting it.
- A broken runner already in the folder is listed in Settings with its error; if it was selected, the default runner shows.
- Custom runners load when the app starts and whenever Settings opens; there is no folder watcher for them (rarely changed, one less thing running).
- The example runner (`examples/runners/blob`) ships with its generator script, and a test loads it from the repo so it cannot drift from the rules.

## Phase 8: release plumbing

- Developer ID signing happens in xcodebuild (`CODE_SIGN_IDENTITY`, `DEVELOPMENT_TEAM`, `OTHER_CODE_SIGN_FLAGS=--timestamp`), not by re-signing afterwards with `--deep`: xcodebuild signs Sparkle's nested helpers correctly, `--deep` is not recommended for distribution. The ad hoc path is unchanged.
- One script, `scripts/macos-release.sh`, does the whole release locally or in CI; `--check` validates tools, settings, the keychain identity and that the version matches `MARKETING_VERSION`.
- Both the app zip (for Sparkle) and the DMG (for people and Homebrew) are notarized and stapled; the zip is made again after stapling so updates carry the ticket.
- The appcast is generated per release and served from `releases/latest/download/appcast.xml`, so there is no separate hosting.
- The workflow guard is a separate job that outputs `ready`; missing secrets give a notice and a skipped job, never a red run. The Homebrew tap update is a pull request, and optional (`HOMEBREW_TAP_TOKEN`).
- The runner label is `macos-26` and Xcode is `latest-stable`: the project needs Xcode 26 or newer.
- Sparkle's `Check for Updates…` item exists only in Sparkle builds; the default `Updater` is an empty stub, so no `#if` spreads through the app.
- The cask is Apple Silicon and macOS 14+ only, with caveats pointing at the CLI install and the trademark note.
- Verified locally: the Sparkle build compiles and embeds Sparkle.framework with SUFeedURL; `macos-release.sh --check` fails cleanly listing missing settings; shellcheck passes; the workflow parses. Not run: signing, notarization, the workflow itself.

## Phase 9: docs and wrap up

- The README title is now BenchBar with the tagline; the repo name stays descriptive. Every command example uses `benchbar`, the clone URL is the renamed repo, and `frappe-mac` is mentioned only as the old name. Internal names (rc markers, `frappe-mac-run.sh`, the MariaDB drop-in) are unchanged, as decided in Phase 0.
- The README update the brief asked for in Phase 0 (new repo URL) had not been done; it is done here, with AGENTS.md.
- Screenshots are real renders of the SwiftUI views with fixture data (snapshot tests), not mockups; the menu bar strip is the built in runner sheet.
- CHANGELOG: one 0.3.0 entry for the rename, the JSON API and the app, matching `FL_VERSION` and `MARKETING_VERSION`.

## Rename follow-up

Asked for after the phases, to stop naming drift before the first release.

- Repo renamed from `askysh/frappe-mac-dev-server` to `askysh/benchbar` (`gh repo rename`); GitHub redirects the old URLs, but the Sparkle feed, the cask and the docs point at the new one so nothing relies on the redirect.
- User visible names move to benchbar, each with a one time migration: the checkout's `.frappe-local/` becomes `.benchbar/`, `frappe-mac-run.sh` becomes `benchbar-run.sh`, the rc markers become `# >>> benchbar >>>`, and new files carry `benchbar-template:`.
- Template headers: both `benchbar-template:` and `frappe-mac-template:` count as ours and only `<name> vN <hash>` is compared, so the word alone never rewrites a file; the MariaDB drop-ins stay byte for byte and MariaDB is not restarted. (The hash is computed with the header placeholder in place, so it does not depend on the word.)
- `.frappe-local/` is renamed by the first command that runs (one `mv` in the checkout), except while a run holds its lock; a concurrent second process falls back to whichever folder exists. This includes read only commands: it is the tool's own state, not the bench or the system.
- A frappe-mac rc block is "legacy": doctor calls it outdated, and `repair` replaces it in place with benchbar markers, keeping its position. A stray frappe-mac block next to a benchbar block is reported like any other old block.
- The old runner is backed up and removed only once no installed agent (new or legacy plist) points at it, so a running bench is never left without its script; write_plist retires it after loading the new agent, write_runner after an interrupted repair, and doctor flags a leftover.
- Kept: `FL_` and `lib/frappe-local/` (internal, never shown), the MariaDB drop-in names (renaming restarts MariaDB), `~/.local/bin/frappe-mac` and the `com.frappe-mac` label migration (until 1.0). The local checkout folder is the user's to rename; `benchbar repair` repoints the rc block and links afterwards.
- Found while running the migration on the real bench: reloading a running agent left it unloaded (bootout is asynchronous, the immediate bootstrap failed with 5: Input/output error, and `load -w` exits 0 without loading). Reproduced with a throwaway launchd job from the scratch folder (not in ~/Library/LaunchAgents). Fix: bootout waits until `launchctl print` no longer lists the job (FL_BOOTOUT_WAIT_SECS, 30 s; launchd kills after 20), bootstrap retries and trusts only `launchctl print`, and write_plist fails the step if the job never goes. The mock launchctl can now linger (MOCK_BOOTOUT_LINGER) to cover it.

## 0.4: several benches and sites

- The menu bar shows the worst state across benches (crashed or paused, then starting, then running, then stopped), so a crash in a bench that is not selected is never hidden; the running speed still comes from one bench, the selected one while it runs, else the first running one.
- The bench picker became a list above the detail when there is more than one bench: state, uptime and per row Start, Stop and Restart that act without changing the selection; clicking a row selects it. The row buttons follow the same `BenchControls` rules as the big buttons.
- Sites come from `status --json` (fresh) and fall back to `list --json`; a CLI older than 0.4 has no `sites` and the popover shows the bench's one site as before. The section appears only with more than one site or a missing hosts line, to keep the single site popover unchanged.
- A missing hosts line shows `benchbar site hosts --bench-dir ...` with a Copy button, never a button that runs it: it needs sudo, which the app never asks for.
- The scheduler toggle in Settings is the first app action that changes a bench's files: it asks in an alert, then runs `benchbar service --yes --with-schedule` (or `--without-schedule`) and restarts the bench only when it was running. `--yes` stands for the alert's answer, since the CLI would otherwise ask on a closed stdin and answer no.
- `ScriptedCLI` in the tests answers per `--bench-dir` when told to, before the answer per command, so two benches can report different states.
- Verified on the real Mac (2026-09-26) with `frappe-bench` (v15, port 8000) and `v16-bench` (v16, port 8001, sites `v16dev` and `v16two`) both running: the popover shows the Benches list with both green and "2 of 2 up", the row actions, the `v16-bench` detail with its two sites (default starred) and Open buttons, and a scheduler switch per bench in Settings (checked by Akash; not flipped, since that restarts a bench). Computer use could not open the app: the fresh copy in `~/Applications` was not indexed yet while Spotlight worked through the new bench.
- While the scheduler changes, the bench is busy (`isChangingScheduler`): its row and detail buttons and its switch are disabled until `benchbar service` and any restart finish, since the CLI holds its lock meanwhile (Codex).
- The CLI takes one lock for the whole checkout, so the app runs one change at a time across all benches: while any bench starts, stops, restarts or changes its scheduler, every other bench's buttons and switch wait (`waitsForOtherBench`), instead of failing on "Another benchbar run is active" (Codex).
- The bench list shows up to four rows and scrolls beyond that, at a fixed height, so the selected bench and the footer stay reachable with many benches (Codex).
- A failed background status call sets `refreshError`, which the next successful refresh clears; before, it went into `lastError`, which only a new action cleared, so one call that timed out on a busy Mac left a red banner for good (found by Akash on the real Mac).
## 0.5: the log viewer

- ⌘L opens a log window per bench inside the app; "Open in Terminal" in its toolbar is the old `.command` path. A second ⌘L brings the bench's window forward instead of opening another.
- The reader is a `FileHandle` with two watchers: a `DispatchSource` on the open file (appends, truncation, rename, delete) and the existing `DirectoryWatcher` on `logs/` (the file coming back). Every event ends in one `readNew()` that compares the inode and the size with what it read, so the runner's truncation (`: > bench.log` at every start) and a replacement with `mv` both restart it from the top, with a "log restarted" line in the view.
- Only whole lines are decoded (bytes after the last newline wait), so a UTF-8 character split across two reads is never mangled; tested with "é" cut in half.
- Memory is capped at 5000 lines in the view, and an existing file is read from its last 256 KB, starting at a line boundary: a long lived bench.log never lands in memory whole.
- The text is an `NSTextView`, not a SwiftUI list: thousands of lines scroll fast, and select and copy work as in any Mac text view. New lines are appended to the text storage; the whole text is redrawn only when the filter, the search or the current match changes.
- Smart scroll, as in Docker Desktop: at the bottom the view follows new lines; scrolling up turns Follow off (the checkbox shows it), scrolling back to the end turns it on. The view's own scrolling is flagged, so it is never mistaken for the user scrolling.
- The process filter reads honcho's `HH:MM:SS name.N |` prefix; lines without a prefix (a traceback) belong to the process above them, and stay red until the next prefixed line when they follow a "Traceback" line. Errors are lines with ERROR, CRITICAL, "Exception:", "Error:" or a traceback.
- Settings and log windows share one counter (`WindowPresence`) for the switch to a regular app, so closing one window does not hide the other's Dock icon and focus.

## 0.5: the BenchBar window

- The sparse Settings window became the BenchBar window, laid out like System Settings: the app's own panes (General, Menu Bar, Team Profiles, About) on top of the sidebar, then one page per bench with four tabs (Overview, Sites, Apps, Health). Per bench settings (the scheduler) moved from Settings to the bench's page. ⌘, still opens General; the popover links in with "Apps, sites and settings…" (⌘M) and a Repair… button in its Doctor section.
- The popover stays the quick path (start, stop, open, doctor); anything that takes a form or minutes (add an app, a site, a profile, an update, a repair) lives in the window, where a sheet can hold a plan and a confirmation.
- The app still never runs bench, git, brew or launchctl: every action is a `benchbar` command. Commands that ask for confirmation get `--yes` only after the app asked in its own dialog; stdin stays closed.
- Every longer change runs in the one change slot (`BenchStore.runChange`), so the bench shows a spinner, every bench's buttons wait, and the CLI's checkout wide lock is never hit. Afterwards the bench list and status are read again.
- The Administrator password of a new site goes into the environment of that one `benchbar site add` process (`ADMIN_PASSWORD`, which the CLI already reads), never onto a command line or to disk; a test checks the arguments and that no other call carries it. The MariaDB password stays in the Keychain, read by the CLI.
- Nothing in the app asks for sudo. A missing hosts line shows `benchbar site hosts --bench-dir ...` with Copy, and repair steps that need a password are marked "needs password" in the plan and come back as skipped with their manual command.
- The Apps tab reads `app list --json --no-sites` first (the cached site lists, no MariaDB needed, instant) and asks bench only on Refresh or after a change.
- Update shows `app update --dry-run --json` first: the commits (newest 30 of the total), the steps and the sites that get a backup; the Update button exists only when there is something to take. An app with local changes cannot be updated from the app.
- The Repair sheet reads `repair --dry-run --json`, then streams `repair --yes --json` through a new line streaming call of the subprocess runner (swift-subprocess `.sequence` output); the real run's plan replaces the dry run's, since the bench may have changed in between. The sheet cannot be dismissed while it runs.
- Mobbin was not usable for references (the MCP server answered that a paid plan is needed); the layout follows Apple's own Settings instead.

## 0.5: finishing the window, the icon

- The icon is an Icon Composer `.icon` (Xcode 27 compiles it to `Assets.car` and `AppIcon.icns`, Liquid Glass on macOS 26 and later, a flat render before). Its layers are SVGs drawn by `scripts/app-icon.py` from the same geometry as the menu bar runner, so the icon and the runner are one character; `icon.json` holds the gradient and the glass. XcodeGen adds the `.icon` as one file (`type: file`), or it would copy the SVGs as loose resources.
- `.tabs` is also behind `#if compiler(>=6.4)`: the GitHub runners build with Xcode 26.6, whose SDK does not have it, and `#available` is only a run time check. A release built there shows segmented tabs on macOS 27 until the runners get Xcode 27; everything else in the new look needs only the macOS 26 SDK.
- macOS 27's `.pickerStyle(.tabs)` for the bench tabs and macOS 26's `.glassProminent` for each pane's main action, behind `#available` with the segmented and bordered styles before: the deployment target stays macOS 14, the testers are on 27.
- Every pane starts with a `PaneHeader` (a tinted symbol tile, the name, one line on what it is for), like System Settings; explanations moved from inline captions to section footers.
- `NSHostingController.sizingOptions = [.minSize]`: the default also follows each pane's ideal size, and the window jumped to 1285 points wide on General.
- The change banner carries a scope (a bench's path, or profiles) and shows only there.
- Opening BenchBar again (Finder, Spotlight) shows the window: an accessory app otherwise gives no sign it heard.
- The README's window pictures are screenshots of the real window (`screencapture -l`); the offscreen snapshots draw a selected sidebar row and tab as solid black, since the view is in no key window.

## Batch setup and port conflicts

- The CLI owns the allocation and its approval token; the app displays the
  complete proposal and returns that token, never recalculating ports itself.
- Automatic/Fixed mode saves immediately with explicit explanatory text. A new
  preview follows every mode change; moving ports is a separate apply action.
- A shared operation anchor guards setup even before a selected bench is in the
  store. Full failed-batch output remains available, including partial success.

- Bound the popover body and keep its footer outside scrolling; a bench picker and three-site summary replace nested diagnostic and bench lists.
- Route setup and hostname fixes to the persistent management window; the transient popover must not own a long-running setup sheet.
- Keep stale diagnostic errors visible ahead of a previous passing report; Health retains full action and refresh errors.
- Setup displays the CLI's adoption service preview alongside addresses before approval; a CLI without that preview must be upgraded before the app can apply.

## 0.5.8: quick wins

- `benchbar://` routes are an allow list in a pure `URLRouter` (URL and bench list in, one outcome out); a web page can open any link, so only launches and up, down, restart are routes, and anything else is ignored and logged under the `url` category, never guessed at.
- Links go through `BenchStore.perform`, the same path as the buttons: port checks and the one change slot apply, and a busy bench ignores the link rather than queueing it.
- The Apple Event handler is registered in `applicationWillFinishLaunching` and links wait until the first bench list is loaded, so a link that launches the app acts on real benches instead of an empty list.
- Without `bench=` a link uses the selected bench only when it still exists, else the only bench; a stale selection or two benches with the same name open the window with a notice instead of picking one.
- No confirmation for up, down and restart from a link: browsers already ask before a page opens an app, and a prompt would break Raycast and Shortcuts, which exist to skip clicks.
- Resource samples ride on the store's status refresh (30 seconds, 5 with the popover open) instead of the runner's 2 second speed timer: every running bench gets a history, not only the one that sets the speed, and no new timer wakes the Mac. Twenty points for ten minutes is enough for a sparkline.
- Memory is the sum of `ri_phys_footprint` over the bench's process tree, read in the same `proc_pid_rusage` call as the CPU time: the figure Activity Monitor calls Memory. MariaDB is shared by every bench and is not in the tree, so it is not counted.
- The history belongs to one run: a new runner pid starts it over, so a restart never draws a line across the gap. It is bounded by age (ten minutes) and by count (600), and a clock that goes back starts it over.
- Memory switches to GB at 1000 MB, not 1024, so the popover never shows "1020 MB".
- Two charts, one measure each, no axes: CPU percent and bytes have nothing in common to share a scale. The line has no animation, so Reduce Motion needs nothing extra beyond dropping any transaction animation.
- Back Up and Drop Site live in a per site ⋯ menu, not as more buttons: a row already has Open and Make Default, and a destructive action should not sit one click from Open.
- The Drop sheet reads the plan with `--dry-run --json` on open and again when the new default changes, and cannot be dismissed while the drop runs; the typed name goes to `--confirm-site` as typed.
- The lockfile badge runs `lock check` when the Overview opens, with Check Again, and after a change on that bench, not on the status poll: `lock check` runs `bench --version` and reads every app's git state, too slow for every 30 seconds. `lock check` exits 1 on drift, so exit 1 with JSON counts as a result.
- No Apply button in 0.5.8: `lock apply` moves app checkouts and runs migrate, which needs its own plan sheet; the footer names the command instead.
- Editors are found by bundle id through Launch Services (VS Code, Cursor, VS Code Insiders), not by path or the `code` shell command: they can live anywhere, and the shell command is often not installed. A saved choice that is uninstalled falls back to the first installed editor.
- Console and Database reuse the `.command` file of Open in Terminal: it needs no Apple Events permission. The script runs `benchbar console|db`, never bench directly, so the CLI stays the only way into a bench and no password is in the script.
- `console`, `db` and `editor` became link routes: they only open a window at a prompt, like `logs`.
- The resource charts' time axis starts at the first sample and grows to ten minutes; memory is scaled to its own range without a fill. A fixed ten minute axis and a zero based memory scale drew a fresh bench as a sliver and a flat memory line as a solid block (found by Akash on the real Mac).
- While resource charts are on screen the store polls every 5 seconds, as with the popover open (the same loop, no new timer), so a chart has a line within seconds.

## 0.6.0: update path

- Background update checks are now on by default (once a day, launch, wake and an hourly look at the clock). 0.5 did none because an update meant a manual download of an unsigned DMG; now the update is the one line installer, which checks the zip against SHA256SUMS and downloads with curl, so the unsigned app opens without Gatekeeper. Signing moves to 0.7. The check is one unauthenticated GET to the releases API with no identifier beyond the app version in the User-Agent, and a toggle in General turns it off.
- A Sparkle build (BENCHBAR_SPARKLE=YES) makes no checks of its own and hides the toggle: Sparkle has its own schedule, and two checkers would offer two different update paths.
- The last check time, the latest version seen, its page and the dismissed version live in UserDefaults, so Update to X shows right after launch without waiting for the network. A failed check is not recorded and is retried at the next wake or hour; an answered one waits a day.
- The banner is dismissed per version, the menu item is not: hiding a nag should not hide the way to update.
- Update Now writes a `.command` file and opens it with Terminal, the same path as Open in Terminal: `osascript` or `do script` would need the Automation consent prompt. The app quits itself 1.5 seconds later so the installer can replace it (the installer's own quit is the fallback), and the script opens the app again at the end, the new one or the old one when the update failed.
- Command selection (install.sh's CLI, a developer checkout, another install, the app in `/Applications`) is a pure `UpdatePlan.make` with the file system passed in, so every case is a unit test. An app in `/Applications` gets `BENCHBAR_APP_DIR=/Applications` when writable; otherwise the update goes to `~/Applications` and says to trash the old copy.
- The automatic check does not go through the About pane's `UpdateChecker`, so a failure in the background never shows an error the person did not ask for; a manual check feeds the offer through `onStatus`.

## 0.6.0: profile sharing in the app

- Profile runs call the CLI directly, not through a bench's change slot: profiles live in ~/.config/benchbar and no bench is touched, so an import should not wait for a bench's build, and there may be no bench at all.
- Each sheet has its own `@Observable` run (`ProfileExportRun`, `ProfileImportRun`, ...) like `PortSetupRun`, so the rules and the CLI arguments are tested without views and the snapshots render real plans.
- `ProfileInfo.source` stays the kind and the URL is the new optional `source_url`, so a 0.5 CLI's list decodes unchanged; a kind the app does not know reads as a local file.
- A profile row's id is name plus file: a shadowed file has the same name as the one that wins, and an id of the name alone drew the winner twice.
- `ProfileName` is its own rule (`^[a-z0-9][a-z0-9._-]*$`), not `SiteName`: the CLI allows `_` in profile names, and `acme_hr` was refused by Create.
- A profile link only prefills the sheet; even Review (read only, but it fetches the URL and runs git ls-remote) waits for a click, so a web page cannot make the Mac reach out. A file the user picked or dropped is reviewed right away: that was the click.
- Links and text fields pass `ProfileSourceRule` before any argument list: import takes https or an absolute local `.toml` (links: https only), subscribe https, ssh or scp style remotes. A leading `-`, whitespace, `::` (git's `ext::` transport) and file:// are refused, so nothing can turn into a git option.
- Add Profile only applies the plan that matches the fields as they are now; editing the source or Save As after Review needs a new Review.
- Export works out blocked drops itself from `requires` and disables Export with the reason, and still reads the CLI's refusal JSON (exit 1) in case the two disagree.
- Only changed branches go to `--branch APP=BR`; an unchanged row sends nothing, so the CLI's default branch logic stays the one source of truth.
- Copy Import Link asks for the hosted https address instead of guessing it from the saved path: the app cannot know where the team puts the file.
- Remove is offered only for imported and subscribed profiles, which the CLI moves aside; a subscribed profile's confirmation names every profile of that repository, since the whole subscription goes.
- Scroll views in the sheets get an explicit height from their row count: a scroll view inside a sheet has no height of its own and showed only the first repository.
- Prompts that hold a URL or `git@host` use `Text(verbatim:)`, or SwiftUI draws them as links.

## 0.6.0: dependency freshness

- The focus state rides on `app list --json` (the Apps page's existing read), and the Auto / Focus / Ignore menu calls `benchbar app focus NAME [--auto]` or `app unfocus NAME` directly, not through `runChange`: a pin is a preference in the bench's state file, not a change to the bench, so it must not take the one change slot or show a banner.
- Doctor rows are identified by id and message in the lists (`DoctorCheck.rowKey`): `dependency_behind` can appear once per stale dependency, and SwiftUI must not see duplicate ids.
- The warning itself needs no new UI: it is a doctor WARN with a fix command, so Health and the popover show it like every other check.
- Check Remotes on the Apps page is the app's only fetch (`app focus --fetch --json`, then the list is read again); the app's doctor runs never pass `--fetch`, so doctor stays read only (Akash, 2026-09-29). It takes no change slot: only the apps' `.git` changes.

## 0.6.1: cost at rest

- Every phase reports BenchBar's own CPU, its children's CPU and the total over ten minutes at rest, the children read with `proc_pid_rusage` (`ri_child_user_time` plus `ri_child_system_time`): `ps cputime` counts only the app's own time, and macOS bills the `benchbar` processes it starts to BenchBar too. The 0.6.0 baseline was 0.12 percent own and 6.05 percent children; the measurements of every phase are in the 0.6.1 pull request (#44).

### Phase 1: fast status (CLI)

- `status --json`, `list --json` and `ports check` run with `FL_CONTEXT_LIGHT=1`: `fl_context_init` stops after the bench, site, ports and label. No profile, team profile, `brew --prefix`, `uname -m`, honcho lookup or template renders: only the commands that write or check files use them, and they keep the full init.
- `status` trusts `state.json` only when it says running or starting, launchd runs that very pid and `kill -0` succeeds. The brief asked only for a live pid; the launchd check is free (the one `launchctl print` is needed for `agent_state` anyway) and rules out a pid left by a runner that was killed before its last write and reused since.
- Otherwise one `pgrep -lf` over honcho, serve/worker/schedule and socketio, and one `lsof -d cwd` for all of them at once; a pid counts when its folder is the bench or inside it (serve and the workers run in `sites/`). The brief said the honcho pattern; the wider pattern costs the same one process and keeps a `bench serve` run by hand from reading as stopped while `up` says it runs. No pattern carries the bench's path: a Homebrew Python re-executes itself, so serve's command line starts with the framework's interpreter, never `<bench>/env/bin/python` (the review found the anchored pattern matched nothing on this Mac). Honcho comes first in the result: it is the fallback `pid`, the root of the tree the app samples.
- Port listeners alone no longer make `processes_running` true: `status` never runs `lsof` on the ports, and a leftover Redis is not a running bench. `down` and the port checks still find and stop listeners.
- The site is pinged only while processes run, once, with a 2 second limit (was 3, always). The brief said 1; 2 is the runner's own ping limit, so a busy bench the runner calls running is not called starting by `status`. `sites[].ping_code` is null in `status` and `list` unless `status --json --ping`, which asks each site once and reuses the default site's answer; `site list --json` still asks every site. The app never read the per site codes.
- The readers that ran `sed`, `awk`, `tr`, `head`, `tail`, `basename`, `dirname`, `grep` and `cat` on small files we own are bash: state and per bench files, `common_site_config.json`, `state.json`, the stop flag, the plist's WorkingDirectory, `/etc/hosts`, the registered benches, the JSON escape. `tests/test-status-cost.sh` checks each against the tool it replaced, in a UTF-8 and the C locale.
- The bench name and the JSON escape list their characters one by one: in bash 3.2 a bracket range follows the locale's collation, so `[A-Za-z]` kept an "é" that `tr` replaces (a renamed state file and agent label) and `[\001-\037]` missed tab and newline under UTF-8.
- The JSON escape removes control characters by cutting the string at each one, not with `${x//[set]/}`: that form is quadratic in bash 3.2, and a colored 10 KB log line took 20 seconds in `logs --json`.
- `fl_bench_canonical` skips its `cd -P` only for the bench `fl_bench_detect` resolved from an existing folder (`FL_BENCH_DIR_CANON`): `install` names a folder before `bench init` creates it, and its later steps must resolve the path again or they write to another state file.
- `fl_regex_escape` must give `sed`'s bytes exactly: the rendered runner embeds its output, and one different byte would mark every installed runner outdated.
- `sort` stays for a bench with two or more sites: a glob's order differs from `sort`'s under UTF-8 (upper and lower case), and bash 3.2's `[[ < ]]` compares bytes. One process keeps the site order the app shows.
- `cksum` stays, once per bench per run (`FL_BENCH_HASH`): the state file and the hashed label come from its CRC, and a CRC in bash would be forty lines to save one process. `readlink` stays in `fl_resolve_self`: bash 3.2 has no builtin for it.
- The bench state file and `common_site_config.json` are cached (`FL_BS_*`, `FL_SCC_*`) only in the light mode: a writing command could write from a subshell, which a parent's cache would never see. The label (`FL_AGENT_LABEL`) is cached in every mode, keyed by `FL_BENCH_DIR`: the label a run computes is the one it writes, so it cannot change during the run.
- `fl_honcho_resolve` tries one candidate at a time in the old order: the word list expanded every candidate first, so `pipx environment` (a Python start that also writes a log file) ran on every command, `status` included, even with honcho on PATH.
- `--ping` needs nothing from the app: a 0.6.0 CLI passes an unknown option after the command through and ignores it.
- `pid` liveness goes through `FL_KILL_CMD` (unset: the `kill` builtin), so the tests answer it from the fake process table instead of probing real pids on the host.
- Measured on this Mac (M4, macOS 27.0), through the `~/.local/bin` link as the app runs it: `status --json` on the running bench went from 212 to 5 programs (bash, readlink, cksum, launchctl, curl; 6 with the shebang's env), about 576 to 34 forks, 0.86 to 0.03 s of CPU; on the stopped bench 198 to 6 programs (pgrep and lsof in place of curl) and about 568 to 38 forks. `list --json` for two benches went from 119 to 4 programs, about 323 to 60 forks and 0.39 to 0.04 s of CPU. The JSON of `status`, `list`, `site list` and `ports check` for both real benches is identical to 0.6.0's, key order included, except `sites[].ping_code`.

### Phase 2: runner heartbeat

- The heartbeat is its own file, `logs/.benchbar/heartbeat`, rewritten in place every 30 seconds (`printf '%s\n' "$SECONDS" >"$HEARTBEAT"`: no temp file, no `mv`, no `date`), not a fresh `updated_at` in `state.json` as the brief first said (Akash, 2026-09-30). `state.json` is replaced with `mv` and the app's folder watcher wakes on every such replace: a 0.6.0 app would have run `status` twice a minute per running bench, and a 0.6.1 app would have been woken as often. A write inside an existing file changes no folder entry, so neither wakes; `state.json` keeps carrying transitions only, and `updated_at` keeps its meaning.
- Readers use the file's mtime, never its content (the runner's age in seconds, for a person reading it). Fresh means under 90 seconds old: three beats.
- The first beat is written by the runner itself just before `starting`, so a reader woken by that transition finds it fresh; the loop then sleeps and beats while honcho lives. `sleep` runs as a child the loop waits for, and the loop's TERM trap kills it, so a stop is not held up by a 30 second sleep and leaves no sleep behind. `sleep` is the loop's one process every 30 seconds.
- The file stays when the runner stops: deleting it would be a folder event, and a reader only looks at it while `state.json` says running or starting.
- The runner template is version 4, so `doctor` reports an installed runner as outdated and `service` or `repair` writes the new one.
- Doctor's `runner_heartbeat` warns only when the runner script is current and the runner `state.json` names is alive but beats no more (no file, or 90 seconds or older): that process started before its script was rewritten, since `benchbar service` does not restart a bench. Its fix is `benchbar restart --bench-dir ...` (Akash's call); an outdated script stays the runner check's `benchbar repair`. It carries no repair action: repair never restarts a bench on its own, and an action would fail repair's verify pass while the old process runs.

### Phase 3: the app polls on events

- Measured 2026-10-01, ten minutes at rest, window closed, frappe-bench running with a heartbeat and migration-16 stopped: BenchBar own 0.056 percent, children 0.042 percent, total 0.098 percent (Phase 2 with the 0.6.0 app: 0.067, 0.579, 0.647; 0.6.0: 0.12, 6.05, 6.16). Two `status` calls in the ten minutes, both the safety poll asking about the stopped bench; none for the running one.
- The store has no clock of its own: `status --json` runs on launch and wake, after an action, when the popover or the window opens (with `list`, as the popover always did), and when a bench's files cannot be believed (`BenchTrust`). A bench whose runner beats gets no timer at all; the CLI calls are at utility quality of service.
- The safety poll (`NSBackgroundActivityScheduler`, 5 minutes, 150 seconds of tolerance) takes a beating bench from its files and asks the CLI about every other one: the brief did not say what it does, and only the CLI sees a bench started by hand (benchfg) or a runner killed without a last write. A beating bench costs no process; a stopped one costs one `status` per 5 minutes.
- A change in `logs/.benchbar` of a bench in legacy trust applies the file as a hint, then asks the CLI, as 0.6.0 did for every change; the hint now goes through `merged(over:)` too, so ports and sites do not blink.
- A bench with no `state.json` (never started under the runner) is in the minute loop, as the brief lists: one `status` a minute until its runner first writes, which the folder watcher sees.
- The minute loop is never cancelled: suspend bumps a generation and the loop ends at its next wake, so a status call it started finishes instead of being SIGTERMed into a fake "timed out". The 5 second chart loop is cancelled freely: it reads only libproc.
- The speed loop records into the bench's resource history quietly; views hear of samples only while the popover is open or the window is on screen (`BenchModel.record(publish:)`). The popover and the window keep their SwiftUI graphs when closed, and a sample every 2 seconds would redraw both at rest; opening either shows what was recorded, so the charts have their ten minutes at once.
- The status item's occlusion and Low Power Mode stop the speed loop only (the runner holds a frame, or plays at speed 1). The chart loop follows the popover and the window instead: a full screen BenchBar window hides the menu bar, and a person looking at the charts wants them to move.
- The chart loop also samples the popover's bench (its CPU line) when the speed loop does not: speed off in Settings, Reduce Motion, Low Power Mode, the menu bar hidden.
- `onChange` fires on the menu bar's facts: the CLI, every bench's state (the tooltip counts the benches up, which `displayState` and the bench count do not show), the selection and its name, and the speed bench with its pid (a restart with a new pid must move the speed loop).
- The window reports open, close, occlusion and the page shown through `SettingsWindowController.onSight`; the charts sample the bench whose Overview it shows. `ResourceSection` starts nothing: SwiftUI's onDisappear never comes on a close, since the window keeps its views. The `setChartsVisible` log line went with it.
- `ports check` runs at utility like the other queries the brief lists, even right before `up`: it takes a few tens of milliseconds.
- The `.info` line per process is in `SubprocessRunner`, not `CLIClient.run`: `ports apply` and the repair stream bypass `run`, and the test fakes never reach it. The log is silent in the test host, a BenchBar process with the same subsystem whose fake calls would count next to a running app.
- `stopped` and `unknown` loop three times, then hold the first frame (`RunnerPlan.settle`); a re-tint after that holds it too, like the end of a stumble. The preview in Settings plays the same plan.
- The 30 frames a second cap clamps `layer.speed` to 30 / 5 = 6; the speed keeps its 1 to 12 range, so the mapping and the smoother are unchanged.
- The installed editors are looked up at launch and on every app launch or quit, not only an editor's: installing one is not an event, its first launch is.
- A state.json transition taken while a status call for the same bench waits drops that call's answer and asks once more: the CLI read the bench before the transition, the state machine has no order between sources, and with no clock nothing else would correct a late `running` over a `crashed` or `stopped` (nor stop a second crash alert).
- A failed status call reads the files (a beating or final one is taken at once) and puts the bench in the minute loop until a call works: before its first answer a bench has no mode, and no other timer runs.
- A file that claims running or starting with a dead pid or no fresh heartbeat, after the CLI said stopped, crashed or paused (no action pending), is `overruled`: not taken, no hint, asked about only by the safety poll, until state.json changes. The CLI never rewrites state.json, so the minute loop would otherwise ask about a stopped bench for good. A CLI answer of running puts it back in the minute loop.
- A `starting` file for the pid the CLI already called running is not applied: the runner writes running only on a 200 and stops asking after its ping window, the CLI counts any answer. A new pid is a new run and is applied.
- The folder watcher checks that its folder still exists with the same inode (`needsRestart`), and the store starts it again whenever it reads a bench's files: a cleanup tool deleting `logs/` left a watcher on a deleted folder that nothing rebuilt.
- 5 s poll reproduction (2026-10-01, the 0.6.0 app code plus log lines): opening frappe-bench's Overview with `benchbar://window?bench=frappe-bench` logged "charts appeared: 1 on screen" and fast ticks every 5 to 6 seconds. Closing the window with the red button at 13:23:04 logged no "went away": in the next 90 seconds the app ran 18 fast ticks and 36 `status` calls (two benches each tick) and no slow tick. The retained hosting view never sends onDisappear, so once a bench Overview has been shown the 5 second poll stays on until the app quits. Root cause 2 holds; Phase 3 gates fast mode on the window and the popover instead.

### Phase 4: on-demand cost

- The log tailer's 100 ms debounce does not start over on each event: the first event opens the window and one read at its end takes everything that came. A debounce that restarts shows nothing while a busy bench writes more than ten times a second.
- A read asks the open descriptor for its size (`fstat`); the path is looked at (`stat`, not `FileManager`) only after a delete or rename event, a change in the folder, or with nothing open. `fstat` alone, as the brief reads, would never see a new file under the name, and an append cannot bring one.
- The log text view remembers the last line it drew and appends what came after, instead of the model handing it `appended` to clear: `updateNSView` only reads. The lines the 5000 line buffer drops leave the top of the text in the same edit, so the text is the buffer; before, it grew until a filter or a search redrew it. Scrolled up (follow off) the top stays until the view follows again or redraws: the clip view keeps its offset in points, so a cut above the reader slid the text under them on every read of a busy log. Measuring the cut's height would need the TextKit 1 layout manager.
- Doctor and the app list are kept per bench for the window session, from open to close: a page asks only when its bench has no answer under `BenchStore.stamp(for:)`, the session and the bench's revision. The stamp is the page's `.task` id, since the window's views live on when it closes and get no onAppear when it opens again.
- Every action that ends on a bench moves its revision: start, stop, restart, the scheduler, a change from the window, a focus pin, Check Remotes. A start or stop reads the app list again although it changes nothing there; one rule is easier to trust, and only a page on screen asks.
- "When the bench changes" is read as the page showing another bench, which has its own answer. A new list entry from outside the app does not count: with a 0.6.0 CLI the list's per site pings change on every call. Run Doctor, Refresh or the next session asks.
- A page asks nothing while the window is closed or while a change runs on its bench. Closed views still update, so an action from the popover would run doctor in a hidden window; the end of a change moves the revision, which asks.
- The CLI call runs in a task of its own and a call under way is joined: SwiftUI cancels a page's `.task` on every tab switch, which made swift-subprocess SIGTERM doctor and show "timed out". The answer of a page that went away is kept, not dropped.
- An explicit request that finds a call under way joins it instead of asking twice: Run Doctor was already disabled while doctor runs, and Refresh now is too while the list is read. A call that began before the last action is old by its stamp, and one more follows.
- The Health page opens a requested Repair sheet before it asks for doctor, not after: a new session runs doctor, and the popover's Repair… would wait seconds for a report it already shows.
- Resolve & Start starts through `store.perform(.up)` once the change slot is free, as the Start button does. Its ports check replaces the one that ran inside the change, so a port taken meanwhile now sets the bench's conflict (Review Port Conflict… shows again), and up's output no longer joins the sheet's Setup output.
- `perform` returns the error text like `runChange` does, nil on success: the sheet says why the bench did not start.
- `canChange` is the one busy guard: the actions, the window's buttons and Repair… ask it. It also counts a change held by another model of the same path (a bench being set up), and Repair… now waits while the bench starts or stops; both used to reach the CLI's lock and fail there.
- The uptime helper counts its 30 second schedule from the run's start, not `.now`: the popover's header redraws every 2 seconds while open, and a schedule from `.now` is a new one on every redraw.
