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
