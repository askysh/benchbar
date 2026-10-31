import AppKit
import SwiftUI
import Testing
@testable import BenchBar

/// The screens the documentation shows (docs/images), rendered in a real,
/// key window so the selected sidebar row and tab draw as they do in the
/// app. Fixture data only: no bench, site or app of the machine it runs on.
extension SnapshotTests {
    private nonisolated static let docsCLI = "/Applications/BenchBar.app/Contents/Resources/cli/benchbar"
    private static let frappeBench = "/Users/you/frappe-bench"

    /// Two benches; the first runs and its default site has Open as on.
    private func docsStore() async throws -> BenchStore {
        base.cli.answer("list", json: try Fixture.string("list-two-benches"))
        let sites = #"[{"name":"macdev","default":true,"hosts_entry":true,"ping_code":200,"developer_mode":true,"open_as_enabled":true,"open_as":true},{"name":"qa","default":false,"hosts_entry":true,"ping_code":200,"developer_mode":true,"open_as_enabled":false,"open_as":false}]"#
        base.cli.answer("status", bench: Self.frappeBench, json: #"{"schema_version":1,"cli_version":"0.8.1","bench":"\#(Self.frappeBench)","name":"frappe-bench","site":"macdev","label":"com.benchbar.frappe-bench","state":"running","stop_reason":null,"pid":4242,"started_at":"2026-09-26T01:00:00Z","last_exit_code":null,"web_url":"http://macdev:8000","web_ping_code":200,"ports":{"web":8000,"socketio":9000,"redis_queue":11000,"redis_socketio":13000,"redis_cache":13000},"sites":\#(sites),"scheduler":true,"agent":"com.benchbar.frappe-bench","agent_state":"running","processes_running":true}"#)
        base.cli.answer("status", bench: "/Users/you/dev/v16-bench", json: try Fixture.string("status-v16-two-sites"))
        base.cli.answer("app", json: try Fixture.string("app-list"))
        base.cli.answer("profile", json: try Fixture.string("profile-list"))
        base.cli.answer("doctor", json: try Fixture.string("doctor"))
        base.cli.answer("users", json: try Fixture.string("open-as-users"))
        base.cli.answer("--version", json: "benchbar 0.8.1\nBenchBar app 0.8.1 (/Applications/BenchBar.app)\n")
        base.settings.cliPath = Self.docsCLI
        let runner = base.cli.runner()
        let store = BenchStore(
            settings: base.settings,
            locator: CLILocator(home: base.dir.url, isExecutable: { $0 == Self.docsCLI }),
            makeClient: { CLIClient(executable: $0, runner: runner) },
            pinger: { _, _ in 200 })
        await store.start(polling: false)
        return store
    }

    private func docsWindow(_ store: BenchStore, _ workbench: Workbench, _ router: WindowRouter, about: AboutModel? = nil) -> some View {
        let launch = LaunchAtLogin()
        launch.pinnedStatus = .disabled; launch.refresh()
        return MainWindowView(store: store, router: router, workbench: workbench, about: about ?? AboutModel(store: store),
                              discovery: BenchDiscovery(store: store), wizard: wizardView(store, WizardRun(store: store)),
                              makeSettings: { part in
                                  SettingsView(settings: base.settings, store: store, library: library(), launchAtLogin: launch,
                                               notifier: Notifier(settings: base.settings), part: part, chooseCLI: {})
                              })
            .frame(width: 1000, height: 700)
    }

    @Test func docsWindowPanes() async throws {
        let store = try await docsStore()
        let workbench = Workbench(store: store)
        let bench = try #require(store.benches.first { $0.path == Self.frappeBench })
        // ten minutes of samples: idle, a build, idle again
        let key = ProcessTree.Key(pid: 4242, startTime: 0)
        var cpu: UInt64 = 0
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0...20 {
            let busy: UInt64 = (8...12).contains(i) ? 45 : (i == 13 ? 12 : 1)
            cpu += busy * 300_000_000
            let memory = UInt64(700 + (i >= 8 ? 260 : 0) + i * 3) << 20
            bench.resources.record(ProcessTree.Snapshot(takenAt: UInt64(i) * 30_000_000_000, cpu: [key: cpu], memory: [key: memory]),
                                   root: 4242, at: start.addingTimeInterval(Double(i) * 30))
        }
        let router = WindowRouter()
        router.show(bench: bench.path, tab: .overview)
        try renderKey(docsWindow(store, workbench, router), "docs-window-overview", size: CGSize(width: 1000, height: 700), wholeWindow: true)
        router.pane = .general
        try renderKey(docsWindow(store, workbench, router), "docs-window-general", size: CGSize(width: 1000, height: 700), wholeWindow: true)

        let release = Data(try Fixture.string("github-release-latest").replacingOccurrences(of: "v0.6.0", with: "v0.8.1").utf8)
        let about = AboutModel(store: store, updates: UpdateChecker(currentVersion: "0.8.1") { _ throws(UpdateCheckError) in release })
        await about.loadCLIVersion()
        await about.updates.check()
        router.pane = .about
        try renderKey(docsWindow(store, workbench, router, about: about), "docs-window-about", size: CGSize(width: 1000, height: 700), wholeWindow: true)
    }

    @Test func docsFindUser() async throws {
        let store = try await docsStore()
        let bench = try #require(store.benches.first { $0.path == Self.frappeBench })
        let row = try #require(bench.siteRows.first { $0.name == "macdev" })
        try renderKey(FindUserSheet(store: store, bench: bench, row: row) {}.frame(width: 520), "docs-find-user", size: nil)
    }

    @Test func docsWizard() async throws {
        let (_, welcome) = try await wizardRun([])
        try renderKey(page(welcome).frame(width: 760, height: 380, alignment: .top), "docs-wizard-welcome", size: CGSize(width: 760, height: 380))
        let (_, check) = try await wizardRun([.chooseNewBench, .prerequisites(try report(ok: true))])
        try renderKey(page(check), "docs-wizard-check", size: CGSize(width: 760, height: 620))
        let form: [WizardState.Event] = [.chooseNewBench, .prerequisites(try report(ok: true)), .primary,
            .profiles(try BenchJSON.decode(ProfileList.self, from: try Fixture.data("profile-list-wizard"))),
            .setAdminPassword("s3cret"), .primary, .planned(try plan())]
        let (_, review) = try await wizardRun(form)
        try renderKey(page(review).frame(width: 760, height: 620, alignment: .top), "docs-wizard-review", size: CGSize(width: 760, height: 620))
    }

    /// Light and dark, in a titled window that is the key window.
    func renderKey(_ view: some View, _ name: String, size: CGSize?, wholeWindow: Bool = false) throws {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let look = try #require(NSAppearance(named: appearance))
            let hosting = NSHostingView(rootView: view.environment(\.drawsGlass, false))
            hosting.appearance = look
            let fitted = size ?? hosting.fittingSize
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: fitted),
                                  styleMask: wholeWindow ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.titled], backing: .buffered, defer: false)
            window.appearance = look
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentView = hosting
            window.setContentSize(fitted)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            // let .task loads and the first layouts land
            for _ in 0..<6 {
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            }
            let finalSize = size ?? hosting.fittingSize
            window.setContentSize(finalSize)
            hosting.frame = CGRect(origin: .zero, size: finalSize)
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            if wholeWindow {
                // the window as the window server draws it: sidebar, selection, traffic lights
                let image = try #require(Self.windowImage(window))
                try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                    .write(to: out.appendingPathComponent("\(name)-\(suffix).png"))
                window.orderOut(nil)
                continue
            }
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            look.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: rep) }
            let background = NSImage(size: finalSize)
            background.lockFocus()
            (appearance == .aqua ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.16, alpha: 1)).setFill()
            CGRect(origin: .zero, size: finalSize).fill()
            rep.draw(in: CGRect(origin: .zero, size: finalSize), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            background.unlockFocus()
            let tiff = try #require(background.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: out.appendingPathComponent("\(name)-\(suffix).png"))
            window.orderOut(nil)
        }
    }

    /// A process may capture its own windows without Screen Recording access.
    static func windowImage(_ window: NSWindow) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        // optionIncludingWindow = 1 << 3, boundsIgnoreFraming = 1 << 0
        return capture(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue()
    }
}
