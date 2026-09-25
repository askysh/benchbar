import AppKit
import SwiftUI
import Testing
@testable import BenchBar

/// Renders the popover and Settings window to PNG files, to look at them
/// without clicking the menu bar. Off unless the output folder exists
/// (xcodebuild passes no environment variables, and its own TMPDIR, to a
/// hosted test):
///
///   mkdir -p ~/Library/Caches/BenchBarSnapshots
///   scripts/macos-build.sh --test
nonisolated let snapshotDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/BenchBarSnapshots")

@Suite("Snapshots", .serialized, .enabled(if: FileManager.default.fileExists(atPath: snapshotDir.path)))
struct SnapshotTests {
    let base: BenchStoreTests
    let out = snapshotDir

    init() throws { base = try BenchStoreTests() }

    @Test func popoverRunningWithDoctor() async throws {
        base.cli.answer("list", json: base.listJSON())
        base.cli.answer("status", json: base.statusJSON("running").replacingOccurrences(of: "\"pid\":null", with: "\"pid\":4242"))
        base.cli.answer("doctor", json: try Fixture.string("doctor"))
        let store = base.makeStore()
        await store.start(polling: false)
        await store.runDoctor(on: try #require(store.selected))
        try render(PopoverView(store: store, commands: AppCommands()), "popover-running")
    }

    @Test func popoverNeedsRepair() async throws {
        base.cli.answer("list", json: base.listJSON(installed: false))
        base.cli.answer("status", json: base.statusJSON("stopped", reason: "manual"))
        let store = base.makeStore()
        await store.start(polling: false)
        try render(PopoverView(store: store, commands: AppCommands()), "popover-needs-repair")
    }

    @Test func popoverCrashPaused() async throws {
        base.cli.answer("list", json: base.listJSON())
        base.cli.answer("status", json: base.statusJSON("paused", reason: "crash", exit: 1))
        let store = base.makeStore()
        await store.start(polling: false)
        try render(PopoverView(store: store, commands: AppCommands()), "popover-paused")
    }

    @Test func popoverTwoBenches() async throws {
        let v15 = "/Users/you/frappe-bench", v16 = "/Users/you/dev/v16-bench"
        base.cli.answer("list", json: try Fixture.string("list-two-benches"))
        base.cli.answer("status", bench: v15, json: #"{"schema_version":1,"bench":"\#(v15)","state":"running","stop_reason":null,"pid":4242,"started_at":"2026-09-26T01:00:00Z","last_exit_code":null,"web_url":"http://macdev:8000","web_ping_code":200}"#)
        base.cli.answer("status", bench: v16, json: try Fixture.string("status-v16-two-sites"))
        let store = base.makeStore()
        await store.start(polling: false)
        store.selectedPath = v16
        try render(PopoverView(store: store, commands: AppCommands()), "popover-two-benches")
    }

    @Test func popoverCLIMissing() async throws {
        base.settings.cliPath = ""
        let store = base.makeStore()
        await store.start(polling: false)
        try render(PopoverView(store: store, commands: AppCommands()), "popover-cli-missing")
    }

    @Test func settingsWindow() async throws {
        base.cli.answer("list", json: base.listJSON())
        base.cli.answer("status", json: base.statusJSON("running"))
        // a path that reads well in the README screenshot
        let cliPath = "/Users/you/.local/bin/benchbar"
        base.settings.cliPath = cliPath
        let runner = base.cli.runner()
        let store = BenchStore(
            settings: base.settings,
            locator: CLILocator(home: base.dir.url, isExecutable: { $0 == cliPath }),
            makeClient: { CLIClient(executable: $0, runner: runner) },
            pinger: { _, _ in 200 })
        await store.start(polling: false)
        let view = SettingsView(settings: base.settings, store: store,
                                library: RunnerLibrary(folder: base.dir.url.appendingPathComponent("Runners")), launchAtLogin: LaunchAtLogin(),
                                notifier: Notifier(settings: base.settings), chooseCLI: {})
        try render(view, "settings")
    }

    private func render(_ view: some View, _ name: String) throws {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let look = try #require(NSAppearance(named: appearance))
            let hosting = NSHostingView(rootView: view.padding(0))
            hosting.appearance = look
            let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = look
            window.contentView = hosting
            let size = hosting.fittingSize
            window.setContentSize(size)
            hosting.frame = CGRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            look.performAsCurrentDrawingAppearance {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
            }
            let background = NSImage(size: size)
            background.lockFocus()
            (appearance == .aqua ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.16, alpha: 1)).setFill()
            CGRect(origin: .zero, size: size).fill()
            rep.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            background.unlockFocus()
            let tiff = try #require(background.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try png.write(to: out.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }
}
