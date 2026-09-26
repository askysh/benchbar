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

    @Test func logWindow() async throws {
        let bench = base.dir.url.appendingPathComponent("frappe-bench")
        try FileManager.default.createDirectory(at: bench.appendingPathComponent("logs"), withIntermediateDirectories: true)
        let log = """
        10:00:01 system      | redis_cache.1 started (pid=4101)
        10:00:01 redis_cache.1 | Ready to accept connections tcp
        10:00:02 web.1       | * Running on http://127.0.0.1:8000
        10:00:03 socketio.1  | Realtime service listening on: ws://0.0.0.0:9000
        10:00:05 web.1       | 127.0.0.1 - - "GET /api/method/ping HTTP/1.1" 200 -
        10:00:09 worker.1    | 10:00:09 default: frappe.utils.background_jobs.run_doc_method (job-1)
        10:00:12 web.1       | Traceback (most recent call last):
          File "apps/frappe/frappe/app.py", line 115, in application
            response = frappe.api.handle(request)
        frappe.exceptions.ValidationError: Customer Name is mandatory
        10:00:13 web.1       | 127.0.0.1 - - "POST /api/resource/Customer HTTP/1.1" 417 -
        10:00:15 worker.1    | 10:00:15 default: Job OK (job-1)

        """
        try Data(log.utf8).write(to: bench.appendingPathComponent("logs/bench.log"))
        let model = LogViewModel(benchName: "frappe-bench", benchPath: bench.path)
        model.start()
        model.query.search = "customer"
        try render(LogView(model: model, openInTerminal: {}).frame(width: 860, height: 400), "log-window")
        model.stop()
    }

    // MARK: the BenchBar window

    private func windowStore() async throws -> BenchStore {
        let v15 = "/Users/you/frappe-bench"
        base.cli.answer("list", json: try Fixture.string("list-two-benches"))
        base.cli.answer("status", bench: v15, json: #"{"schema_version":1,"bench":"\#(v15)","state":"running","stop_reason":null,"pid":4242,"started_at":"2026-09-26T01:00:00Z","last_exit_code":null,"web_url":"http://macdev:8000","web_ping_code":200,"scheduler":false}"#)
        base.cli.answer("status", bench: "/Users/you/dev/v16-bench", json: try Fixture.string("status-v16-two-sites"))
        base.cli.answer("app", json: try Fixture.string("app-list"))
        base.cli.answer("profile", json: try Fixture.string("profile-list"))
        base.cli.answer("doctor", json: try Fixture.string("doctor"))
        let store = base.makeStore()
        await store.start(polling: false)
        return store
    }

    private func window(_ store: BenchStore, _ workbench: Workbench, _ router: WindowRouter) -> some View {
        MainWindowView(store: store, router: router, workbench: workbench) { part in
            SettingsView(settings: base.settings, store: store, library: RunnerLibrary(folder: base.dir.url.appendingPathComponent("Runners")),
                         launchAtLogin: LaunchAtLogin(), notifier: Notifier(settings: base.settings), part: part, chooseCLI: {})
        }
        .frame(width: 900, height: 620)
    }

    @Test func windowBenchApps() async throws {
        let store = try await windowStore()
        let workbench = Workbench(store: store)
        let bench = try #require(store.benches.last)
        await workbench.loadApps(bench)
        let router = WindowRouter()
        router.show(bench: bench.path, tab: .apps)
        try render(window(store, workbench, router), "window-apps")
        router.benchTab = .sites
        try render(window(store, workbench, router), "window-sites")
        router.benchTab = .overview
        try render(window(store, workbench, router), "window-overview")
    }

    @Test func windowProfilesAndGeneral() async throws {
        let store = try await windowStore()
        let workbench = Workbench(store: store)
        await workbench.loadProfiles()
        let router = WindowRouter()
        router.pane = .profiles
        try render(window(store, workbench, router), "window-profiles")
        router.pane = .general
        try render(window(store, workbench, router), "window-general")
    }

    @Test func repairSheetWhileRunning() async throws {
        let store = try await windowStore()
        let bench = try #require(store.benches.last)
        base.cli.answer("repair", json: #"{"event":"plan","actions":[{"id":"node_requirements","label":"bench setup requirements --node","fixes":["socket.io module"],"sudo":false},{"id":"build","label":"bench build","fixes":["Built assets"],"sudo":false},{"id":"hosts_entry","label":"add v16two to /etc/hosts (sudo)","fixes":["/etc/hosts entry"],"sudo":true}],"log":null}"#)
        let run = RepairRun(bench: bench, store: store)
        await run.loadPlan()
        try render(RepairSheet(run: run, close: {}), "repair-plan")
        run.apply(.step(action: "node_requirements", status: "done", message: "bench setup requirements --node"))
        run.apply(.step(action: "build", status: "failed", message: "[FAIL] bench build failed (exit 1): see the log"))
        run.apply(.step(action: "hosts_entry", status: "skipped", message: "[WARN] skipped without sudo; run: printf '127.0.0.1 v16two' | sudo tee -a /etc/hosts"))
        run.apply(.done(exitCode: 1, log: "/Users/you/.local/share/benchbar/.benchbar/logs/20260926-101500.log"))
        try render(RepairSheet(run: run, close: {}), "repair-finished")
    }

    @Test func popoverCLIMissing() async throws {
        base.settings.cliPath = ""
        let store = base.makeStore()
        await store.start(polling: false)
        try render(PopoverView(store: store, commands: AppCommands()), "popover-cli-missing")
    }

    @Test func settingsWindow() async throws {
        base.cli.answer("list", json: base.listJSON())
        // a 0.4 CLI reports the scheduler, so the switch is live in the screenshot
        base.cli.answer("status", json: base.statusJSON("running").replacingOccurrences(of: "\"web_ping_code\":null}", with: "\"web_ping_code\":null,\"scheduler\":false}"))
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
