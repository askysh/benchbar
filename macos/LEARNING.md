# Learning BenchBar

A guide to the Mac app for someone who has never built one. Each phase
explains the Swift, SwiftUI, AppKit and Xcode ideas it used, why, and
which files to read. Read it top to bottom once; later, jump to a phase.

## The big picture

```
 menu bar ──> StatusItemController ──> RunnerAnimator (Core Animation)
                     │
                     ├──> popover (SwiftUI) ──> BenchStore ──> CLIClient ──> benchbar CLI
                     │                              ▲
 logs/.benchbar/state.json ──> DirectoryWatcher ────┘
```

The app never touches launchd, bench, brew or your bench's files itself.
It runs `benchbar ... --json`, reads what comes back, and watches the
`state.json` file the CLI's runner writes. If you understand the CLI, you
understand what every button does.

## Phase 0: the CLI contract

Nothing Mac specific yet, but it shapes the app.

- **Why a JSON contract.** A Mac app and a bash script live in different
  worlds. The simplest bridge is: the app runs the CLI and parses JSON.
  `schema_version` lets either side change later without breaking the
  other. Read `docs/json-schema.md`.
- **Why the runner writes `state.json` with "write a temp file, then
  `mv`".** `mv` inside one folder is atomic: a reader sees the old file
  or the new file, never half of one. The catch for Phase 3: a watcher
  on the file itself stops working after the first `mv`, because the
  file it watched was replaced. So the app watches the folder.
- **launchd.** macOS's service manager. A LaunchAgent is a plist in
  `~/Library/LaunchAgents` that says "run this program for this user".
  `AssociatedBundleIdentifiers` in that plist tells macOS which app the
  background item belongs to, so System Settings, General, Login Items
  shows it under BenchBar instead of "unknown developer".

Files: `lib/frappe-local/benchstate.sh`, `templates/bench-run.sh.tmpl`,
`templates/launchagent.plist.tmpl`, `tests/test-json.sh`,
`tests/test-runner.sh`.

## Phase 1: the app skeleton

### What a Mac app is on disk

`BenchBar.app` is a folder that Finder shows as one file:

```
BenchBar.app/Contents/
  Info.plist          who the app is: bundle ID, version, LSUIElement
  MacOS/BenchBar      the compiled program
  Resources/          images, the asset catalog
  _CodeSignature/     the signature
```

Right click any app in Finder, choose Show Package Contents, and you see
the same thing.

### Xcode, projects, targets, schemes

- **Xcode** is Apple's IDE and toolchain. `xcodebuild` is its command
  line half. The Command Line Tools alone are not enough for apps.
- A **project** (`.xcodeproj`) lists source files and build settings.
- A **target** is one thing to build. We have two: `BenchBar` (the app)
  and `BenchBarTests` (a test bundle loaded into the app).
- A **scheme** says what to build, run and test together.
- **XcodeGen** writes the `.xcodeproj` from a short YAML file,
  `macos/project.yml`. The project file itself is huge and conflicts
  badly in git, so we do not commit it: run `xcodegen generate` (the
  build script does) and it appears.

### Info.plist keys that matter here

- `LSUIElement = true`: no Dock icon and no app menu. The app lives only
  in the menu bar. It also means the app is never "active" by default,
  which matters for the Settings window in Phase 5.
- `CFBundleIdentifier = com.akashmishra.benchbar`: the app's identity
  for macOS (notifications, login items, preferences file).

### Sandbox, Hardened Runtime, signing

- **App Sandbox** limits what an app can touch. A sandboxed app cannot
  run `benchbar`, so BenchBar is not sandboxed. That is also why it can
  never be on the Mac App Store, which requires the sandbox.
- **Hardened Runtime** is a separate set of protections (no code
  injection, no unsigned libraries). Notarization requires it, so we
  turn it on now: `ENABLE_HARDENED_RUNTIME = YES`, and the build script
  signs with `--options runtime`.
- **Code signing** proves who built the app. Without an Apple Developer
  account we sign "ad hoc" (`codesign --sign -`): macOS accepts it for
  apps you built yourself on this Mac, but it cannot be notarized, so it
  is not for sharing. Check a signature with
  `codesign -dv macos/build/BenchBar.app` (look for `flags=...(adhoc,runtime)`).
- **Entitlements** (`BenchBar.entitlements`) are signed claims such as
  "no sandbox".

### Swift 6 and concurrency in one paragraph

Swift 6 checks at compile time that data is never touched from two
threads at once. UI objects must be used on the main thread, which Swift
calls the **main actor**. Our project sets the default isolation to
`MainActor` (the Xcode 26 default), so every type is main thread only
unless we say otherwise. Code that must run in the background (running
the CLI, sampling CPU) is marked `nonisolated` or lives in an `actor`,
and uses `async`/`await` to hand results back.

### The AppKit lifecycle

`main.swift` creates `NSApplication`, sets our `AppDelegate`, and calls
`run()`, which is the event loop. When launching finishes, AppKit calls
`applicationDidFinishLaunching`, where we create an `NSStatusItem`: the
slot in the menu bar. A SwiftUI `App` could do this too, but a menu bar
only app has no windows to declare, and the plain lifecycle keeps the
Settings window under our control.

### Files to read

- `macos/project.yml`: targets, settings, the Swift package.
- `macos/BenchBar/App/main.swift`, `AppDelegate.swift`.
- `macos/BenchBar/Resources/BenchBar.entitlements`.
- `scripts/macos-build.sh`, `scripts/macos-install-local.sh`.

### Try it

```bash
scripts/macos-build.sh --test
```

```bash
scripts/macos-install-local.sh
```

To open the project in Xcode (optional, nothing needs clicking to build):

1. Run `scripts/macos-build.sh` once, so `macos/BenchBar.xcodeproj` exists.
2. Double click `macos/BenchBar.xcodeproj`, or run `open macos/BenchBar.xcodeproj`.
3. At the top of the window, the scheme menu should say BenchBar and
   My Mac. Press Cmd+R to build and run, Cmd+U to run the tests.
4. The app has no window: look for the runner in the menu bar.
5. Press Cmd+. (Cmd and period) to stop it.

## Phase 2: talking to the CLI

### Running another program from Swift

`SubprocessRunner` (in `CLI/CommandRunner.swift`) uses Apple's
**swift-subprocess** package. A **Swift package** is a library pulled
from a git URL; `project.yml` lists it under `packages:` and Xcode
downloads it on the first build (you will see it under Package
Dependencies in Xcode's file list).

```swift
let result = try await Subprocess.run(
    .path(FilePath("/Users/you/.local/bin/benchbar")),
    arguments: ["status", "--json"],
    output: .string(limit: 4 * 1024 * 1024))
```

- `async` / `await`: the call suspends instead of blocking the thread, so
  the menu bar stays responsive while the CLI runs.
- `throws(CLIError)` is **typed throws** (Swift 6): the compiler knows
  every error is a `CLIError`, so the UI can `switch` over the cases.
- **Timeouts** use a **task group**: two child tasks race, one runs the
  command, one sleeps. Whoever finishes first wins; `cancelAll()` stops
  the other. Cancelling the command makes swift-subprocess send SIGTERM,
  then SIGKILL.

### Why an explicit PATH

Apps started from Finder or at login inherit launchd's minimal
environment, not your `~/.zshrc`. `/opt/homebrew/bin` is not on it. So
the app (a) finds `benchbar` by absolute path (`CLILocator.swift`) and
(b) passes a PATH that includes Homebrew, because the CLI itself calls
brew, bench and curl.

### Codable

`Models.swift` declares structs that mirror the JSON. `Codable` makes
Swift generate the parsing code. `CodingKeys` maps `web_url` to
`webURL`. Two tricks:

- An `enum` with a custom `init(from:)` turns unknown strings into
  `.unknown`, so a newer CLI adding a state does not break the app.
- `SchemaProbe` decodes only `schema_version` first, so a future
  breaking schema gets a clear message instead of a confusing parse error.

### Protocols for testing

`CLIClient` does not start processes itself; it asks a `CommandRunning`.
The app passes `SubprocessRunner`, the tests pass `FakeRunner`, which
answers with the JSON files in `BenchBarTests/Fixtures`. This is how
you test code that talks to the outside world without the outside world.

### Swift Testing

Tests are functions marked `@Test`, grouped in a `@Suite` struct.
`#expect(a == b)` checks a value; `#expect(throws:)` checks an error;
`#require` stops the test if a value is missing. Run them with
`scripts/macos-build.sh --test` or Cmd+U in Xcode. In Xcode, the Test
navigator (Cmd+6) lists every test with a play button.

### Files to read

- `macos/BenchBar/CLI/CLIClient.swift`: the only door to the bench.
- `macos/BenchBar/CLI/CommandRunner.swift`, `CLILocator.swift`, `Models.swift`, `CLIError.swift`.
- `macos/BenchBarTests/CLIClientTests.swift`, `SubprocessRunnerTests.swift`.

## Phase 3: knowing the bench's state

### Observation

`BenchStore` and `BenchModel` are marked `@Observable` (the Observation
framework, macOS 14+). Any SwiftUI view that reads a property, say
`bench.state`, redraws when that property changes, with no
`@Published` or Combine. `@ObservationIgnored` opts out properties the
UI never reads (tasks, watchers, callbacks).

### A pure state machine

`State/BenchStateMachine.swift` has no I/O at all. You give it an
**event** (a status was observed, an action started or finished, the
CLI went missing) and it returns **effects** (show an alert, ping the
site, refresh). The store performs the effects. Because the machine is
just a value, `StateMachineTests.swift` can walk it through a crash, a
crash-guard pause and a recovery in a few lines, with no processes or
timers.

Two rules worth reading in the code:

- **Optimistic start**: pressing Start shows "starting" at once.
- **Stale answers**: while a start is in flight, a "stopped" answer is
  from before the start, so it is ignored.

### Three sources of truth, fastest first

1. **Folder watcher** (`DirectoryWatcher.swift`): a `DispatchSource`
   on the file descriptor of `logs/.benchbar`. The kernel tells us when
   a file there is created or renamed. We watch the folder, not the
   file, because the runner writes `state.json` with `mv`, which swaps
   in a new file; a watcher on the old one would never fire again.
2. **Polling**: `Task.sleep(for:tolerance:)` in a loop. The tolerance
   lets macOS group our wakeup with others, which saves battery.
3. **Ping** (`SitePinger.swift`): one HTTP request after a start. It
   uses the Network framework (`NWConnection`) because it must set the
   Host header, which URLSession does not allow.

### Continuations

`SitePinger` wraps callback-based `NWConnection` code into `async` with
`withCheckedContinuation`. A continuation must be resumed exactly once;
`ResultBox` uses a lock so whichever callback (reply, failure, timeout,
cancel) comes first wins and the rest do nothing.

### Files to read

- `macos/BenchBar/State/BenchStateMachine.swift` first, then `BenchStore.swift`.
- `macos/BenchBar/State/DirectoryWatcher.swift`, `SitePinger.swift`.
- `macos/BenchBarTests/StateMachineTests.swift`, `BenchStoreTests.swift`, `DirectoryWatcherTests.swift`.

## Phase 4: the animated runner

### A status item is a button with a layer

`NSStatusItem` gives you an `NSStatusBarButton` in the menu bar. Most
apps set `button.image`. We instead turn on `button.wantsLayer` and add
our own `CALayer` on top (`StatusItem/StatusItemController.swift`).
A **layer** is a rectangle Core Animation draws on the GPU; every
AppKit view can be backed by one.

### One animation, run by the system

`Runners/RunnerAnimator.swift` puts one `CAKeyframeAnimation` on the
layer's `contents` (the image it shows):

- `values` is the list of frames, `keyTimes` says when each starts.
- `calculationMode = .discrete` means "jump from frame to frame", no
  blending between them. In this mode `keyTimes` has one more entry
  than `values`: each frame holds until the next key time.
- `repeatCount = .infinity` loops it.

Once added, the animation runs in the render server, a separate
process. Our app does no work per frame and can sit idle, which is why
the brief rules out swapping images on a timer.

### Speed without restarting

Every layer has its own clock: local time is
`(parent time - beginTime) * speed + timeOffset`. Setting `speed = 3`
plays the loop three times faster. Changing `speed` alone would make
the animation jump (the whole past is suddenly scaled), so
`applySpeed()` first pins `beginTime` to now and `timeOffset` to the
current local time. `speed = 0` is how you pause a layer.

### Template images, by hand

A template image is black plus transparency; macOS paints it in the
menu bar's text color, so it works on light, dark and the macOS 26
transparent menu bar. A `CALayer` does not know about templates, so we
tint the frames ourselves with `NSColor.labelColor` resolved in the
button's `effectiveAppearance`, and tint again when that appearance
changes (key value observing on `effectiveAppearance`).

### Drawing the art in code

`Runners/BuiltInRunners.swift` draws both runners with Core Graphics:
rounded rectangles, lines and dots in an 18 point canvas, rendered at
2x into 36 pixel tall bitmaps. The faces are drawn with the `.clear`
blend mode, which punches holes. Legs are two segments whose angles
come from a sine wave (`Gait`), so a whole run cycle is a formula.

### State to animation is a table

`Runners/RunnerPlan.swift` maps a bench state to a plan: loop a pose,
stumble then hold the alert, or show one still frame (Reduce Motion).
It is a pure function, so `RunnerTests.swift` checks the whole table.

### Speed from CPU

`Speed/ProcessTreeCPU.swift` uses **libproc**, the C library behind
Activity Monitor:

- `proc_listchildpids` lists a process's children; walking them from
  the runner's pid gives the whole bench (honcho, web, workers,
  socketio, Redis).
- `proc_pid_rusage` gives each process's CPU time so far.

Two readings 2 seconds apart give CPU percent. On Apple Silicon these
times are in "mach ticks", not nanoseconds, so `MachTime` converts them
with `mach_timebase_info`. The percent becomes a speed
(`1 + cpu / 10`, kept between 1 and 12) and an exponential moving
average smooths it. `SpeedSource` is a protocol, so queue depth or
requests per second can replace CPU later.

An `actor` (`ProcessTreeCPUSource`) holds the previous reading. Actors
let only one caller at a time touch their state, so no locks.

### Being a good citizen

`System/SystemActivity.swift` listens for sleep, screen sleep, screen
lock (a distributed notification from loginwindow) and fast user
switching. While any of those is true the layer is paused, CPU sampling
stops and the store stops polling. It also watches
`accessibilityDisplayShouldReduceMotion`: with Reduce Motion on, every
state shows one still frame.

To try it: System Settings, Accessibility, Display (or Motion on macOS
26), turn on Reduce motion. The runner stops moving at once.

### Files to read

- `macos/BenchBar/Runners/RunnerPlan.swift`, then `RunnerAnimator.swift`.
- `macos/BenchBar/Runners/BuiltInRunners.swift` for the drawing.
- `macos/BenchBar/Speed/SpeedSource.swift`, `ProcessTreeCPU.swift`, `SpeedController.swift`.
- `macos/BenchBar/StatusItem/StatusItemController.swift`, `macos/BenchBar/System/SystemActivity.swift`.
- `macos/BenchBarTests/RunnerTests.swift`, `SpeedTests.swift`.

## Phase 5: the popover and Settings

### SwiftUI inside AppKit

The menu bar item is AppKit; what it opens is SwiftUI. The bridge is
`NSHostingController(rootView:)`, a view controller that hosts a SwiftUI
view. `sizingOptions = [.preferredContentSize]` lets the SwiftUI view
decide the size, so the popover grows when doctor results arrive.

- `Popover/PopoverController.swift` puts it in an `NSPopover` with
  `behavior = .transient` (a click elsewhere closes it).
- `Popover/PopoverView.swift` reads `BenchStore` and `BenchModel`
  directly. They are `@Observable`, so the view redraws when a state
  changes, with no extra wiring.

### Why the app activates itself

An accessory app is never frontmost on its own. If it does not call
`NSApp.activate()` before showing the popover, the popover's window never
becomes key, and key presses (the ⌘ shortcuts) go to whatever app was in
front. After showing it we also clear the first responder, so no button
starts with the focus ring: a stray Space must not stop your bench.

### Keyboard shortcuts

`.keyboardShortcut("u", modifiers: .command)` on a SwiftUI button fires
it on ⌘U while its window is key. A disabled button ignores its shortcut,
so ⌘U does nothing while the bench runs.

| Keys | Action |
|---|---|
| ⌘U / ⌘D / ⌘R | start (benchup) / stop (benchdown) / restart |
| ⌘O / ⌘L / ⌘F | open site / logs in Terminal / bench folder |
| ⌘K | run doctor (read only) |
| ⌘, / ⌘Q | Settings / quit |

### The Settings window pattern

A menu bar app has `LSUIElement = true`: no Dock icon, and macOS treats
its windows as second class (they open behind other apps). The pattern
that works (`Settings/SettingsWindowController.swift`):

1. On open: `NSApp.setActivationPolicy(.regular)`, which gives a Dock
   icon and a normal menu bar for as long as the window is open, then
   `NSApp.activate()` and `makeKeyAndOrderFront`.
2. On close (`windowWillClose`): `setActivationPolicy(.accessory)`, and
   the Dock icon goes away.

The app also installs a small main menu (`AppDelegate.makeMainMenu`).
Without an Edit menu, ⌘C and ⌘V do nothing in a text field, because
those shortcuts are menu items.

We do not use SwiftUI's `Settings` scene: it needs a SwiftUI `App`, and
opening it from a menu bar app is unreliable across macOS versions.

### Launch at login

`SMAppService.mainApp.register()` (ServiceManagement, macOS 13+) adds the
app itself to Login Items. There is no plist to write. The status can be:

- enabled
- not registered
- requires approval: the user has to allow it
- not found: macOS cannot register this copy, for example one running
  from Xcode's build folder

To approve it by hand:

1. Open System Settings, General, Login Items & Extensions.
2. Under "Open at Login", find BenchBar and switch it on.

The Settings window has a button that opens that page
(`SMAppService.openSystemSettingsLoginItems()`).

### Opening things

`System/Workspace.swift`: the site in your browser (`NSWorkspace.open`),
the folder in Finder, and the logs in Terminal. For the logs we write a
tiny `.command` script (`benchbar logs -n200 --bench-dir ...`) and open it
with Terminal. Terminal runs `.command` files, so we need no Apple Events
permission to "tell Terminal to do script".

### Seeing the UI without clicking

`BenchBarTests/SnapshotTests.swift` renders the popover and Settings
with fixture data to PNG files, light and dark:

```bash
mkdir -p ~/Library/Caches/BenchBarSnapshots
scripts/macos-build.sh --test
open ~/Library/Caches/BenchBarSnapshots
```

The suite is off unless that folder exists.

### Files to read

- `macos/BenchBar/Popover/PopoverView.swift`, `PopoverController.swift`, `BenchPresentation.swift`.
- `macos/BenchBar/Settings/SettingsWindowController.swift`, `SettingsView.swift`, `LaunchAtLogin.swift`, `RunnerPreview.swift`.
- `macos/BenchBar/App/AppDelegate.swift` for the wiring and the click handling.
- `macos/BenchBarTests/PresentationTests.swift`.

## Phase 6: notifications

### UserNotifications in three calls

`Notifications/Notifier.swift`:

1. `requestAuthorization(options: [.alert, .sound])` shows macOS's
   "BenchBar would like to send notifications" prompt. It only ever shows
   once; after that macOS remembers the answer, and changing it happens in
   System Settings.
2. `add(UNNotificationRequest(...))` posts one. `trigger: nil` means now.
   The same `identifier` replaces an older banner, so a crash loop does
   not pile up ten notifications.
3. The **delegate** (`UNUserNotificationCenterDelegate`) hears two things:
   `willPresent` (a notification arrives while BenchBar is the active app;
   we still want the banner) and `didReceive` (the user clicked it; we
   open the popover on that bench).

The delegate methods are `nonisolated` because macOS calls them from
its own queue; `MainActor.run` hops back to the main thread for the UI.

### Where alerts come from

The state machine from Phase 3 already returns `.alert(...)` effects on
exactly the three transitions the brief lists: running to crashed,
into paused because of crashes, and paused to running. The store hands
them to `Notifier.post`, which checks the toggle in Settings.

The CLI's runner also has an osascript notification for people without
the app. It stays quiet while a process named BenchBar runs, so you never
get two.

### If you said no to the prompt

1. Open System Settings, Notifications.
2. Find BenchBar in the list and turn on Allow notifications.

Settings shows a button for this when permission is off.

### Files to read

- `macos/BenchBar/Notifications/Notifier.swift`
- `macos/BenchBarTests/NotifierTests.swift`

## Phase 7: custom runners

### Reading files a stranger made

A runner comes from someone else, so `Runners/RunnerPackage.swift`
treats it like untrusted input:

- `Codable` decodes `manifest.json` into a struct. A missing field or a
  wrong type throws a `DecodingError`, which we turn into one sentence.
- Frame names are checked before any file is opened: no `/`, no `..`, no
  hidden files, `.png` only. That is what stops a manifest from pointing
  at `../../somewhere/else`.
- **ImageIO** (`CGImageSourceCreateWithURL`) opens the PNGs.
  `CGImageSourceGetType` tells us what the file really is, whatever its
  name says.
- Symlinks are refused: a link could point anywhere on disk.

**Typed throws** (`throws(RunnerError)`) means the compiler knows every
error is a `RunnerError`, so the Settings window can always show a
message, and the tests compare errors with `==`.

### Import without trusting the archive

`Runners/RunnerLibrary.swift`:

1. For a zip, `zipinfo -t` reads the listing first: too many files or
   too many unpacked bytes (a "zip bomb") and we stop before unpacking.
2. `ditto -x -k` (macOS's own archiver, the one Finder uses) unpacks it
   into a temporary folder.
3. The folder is validated as above.
4. Only `manifest.json` and the frames it lists are copied into a
   staging folder, which then replaces the installed one in one move.

### Where it lives

`~/Library/Application Support/BenchBar/Runners/<id>/`. Application
Support is the standard place for an app's own data; it is not synced or
cleaned by macOS.

### Files to read

- `macos/BenchBar/Runners/RunnerPackage.swift`, `RunnerLibrary.swift`
- `docs/runners.md`, `examples/runners/blob/`
- `macos/BenchBarTests/RunnerPackageTests.swift`

## Phase 8: shipping an app outside the App Store

Nothing here runs yet (no Apple Developer account); `docs/releasing.md`
is the full guide. The ideas, in plain words:

- **Code signing** proves who made the app and that nobody changed it.
  Today we sign "ad hoc" (`codesign --sign -`): valid, but it names no
  one, so only your own Mac trusts it. A **Developer ID** certificate
  from Apple names you.
- **Hardened Runtime** is a set of protections (no injected code, no
  unsigned libraries). Notarization requires it; we have had it on since
  Phase 1.
- **Notarization**: you upload the signed app to Apple, a machine scans
  it for malware, and Apple issues a ticket. `notarytool` does the upload.
- **Stapling** attaches that ticket to the app or DMG, so Gatekeeper
  (the "can this app open?" check) can confirm it offline.
- **Sparkle** is the standard update framework for apps outside the App
  Store. The app reads an RSS style feed (`appcast.xml`) and checks every
  download against a public key built into it; only the holder of the
  matching private key can publish an update.
- **A Homebrew cask** is a small Ruby file telling Homebrew where the DMG
  is and its checksum, so `brew install --cask` can install the app.
- **Compilation conditions**: `#if SPARKLE` in Swift keeps code out of
  the build entirely unless the flag is set. `macos/sparkle.yml` sets it
  only when `BENCHBAR_SPARKLE=YES`.
- **A guarded workflow**: GitHub Actions cannot test for a secret in a
  job's `if:`, so a tiny first job checks the secrets and outputs
  `ready`, and the release job runs only when `ready` is true.

Files to read: `docs/releasing.md`, `scripts/macos-release.sh`,
`.github/workflows/macos-release.yml`, `packaging/homebrew/benchbar.rb.tmpl`,
`macos/BenchBar/Updates/Updater.swift`.

## Phase 9: docs and wrap up

- The README now leads with BenchBar, uses `benchbar` for every command,
  and has a menu bar app section, an FAQ and the trademark note.
- The screenshots in `docs/images` are the snapshot test renders from
  Phase 5, so they can be made again after a UI change:
  ```bash
  mkdir -p ~/Library/Caches/BenchBarSnapshots
  scripts/macos-build.sh --test
  cp ~/Library/Caches/BenchBarSnapshots/popover-running-light.png docs/images/popover-light.png
  ```
- Before calling anything done, all four checks: `tests/run-tests.sh`
  (CLI and shellcheck), `shellcheck scripts/*.sh`,
  `scripts/macos-build.sh --test` (Swift), and a Release build.

## After the phases: renaming without breaking installs

Renaming files that are already on people's machines is a migration, not
a find and replace. The pattern used for every name (read
`lib/frappe-local/shellrc.sh`, `templates.sh`, `state.sh`,
`benchinfo.sh` and `tests/test-migrate.sh`):

1. **Recognize the old name as ours.** A block with the old markers is
   "legacy", a header with the old word still matches.
2. **Decide what counts as a change.** Only the name, version and hash of
   a template are compared, so the old word alone never triggers a
   rewrite (important for MariaDB, which restarts on a config change).
3. **Move once, atomically, and keep a backup.** `mv` of the state
   folder, an in place replacement of the rc block, a backup before the
   old runner is removed.
4. **Never pull the rug.** The old runner goes only after no agent points
   at it.
5. **Test the old state, not just the new one.** The tests build a bench
   and an rc file the way 0.2.0 left them and check the result.
