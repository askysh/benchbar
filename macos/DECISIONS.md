# BenchBar decisions

One line per non obvious choice: the decision, then the reason.

## 0.5.5: about and help

- The update check is a button, not a timer: one `GET` of GitHub's latest release with a User-Agent (GitHub refuses requests without one), `Accept: application/vnd.github+json`, a 10 second limit and an ephemeral session (no cookies, no cache). Unsigned builds until 0.6 mean no Sparkle and no download: the answer links to the release page.
- Versions compare part by part as numbers (0.10 after 0.9), a missing part is 0, a leading `v` is dropped and a prerelease sorts before its release. A version that does not parse (a local build) is never told to update.
- A Sparkle build keeps Sparkle's own Check for Updates item; the default build gets one that opens the About pane and runs the check there, so the answer is visible.
- Report a Bug lives as a sheet on the About pane; the Help menu opens the pane and sets a flag on `WindowRouter` that the pane turns into the sheet, like `repairRequested`. The sheet explains what the zip holds before anything runs.
- After `report --json`, Finder selects the zip (`activateFileViewerSelecting`) and the browser opens `issues/new?template=bug_report.yml&macos-version=...&benchbar-version=...`; nothing is uploaded. A CLI older than 0.5.5 prints text instead of JSON, and the sheet says to run `benchbar report` in Terminal.
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
