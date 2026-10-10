import AppKit
import SwiftUI
import Testing
@testable import BenchBar

/// Snapshots of the 0.8 screens: the wizard pages, the sidebar, Settings,
/// About, the walkthrough, guidance and the empty states.
extension SnapshotTests {
    private func wizardRun(_ events: [WizardState.Event], empty: Bool = true) async throws -> (BenchStore, WizardRun) {
        base.cli.answer("list", json: try Fixture.string(empty ? "list-empty" : "list"))
        let store = base.makeStore()
        await store.start(polling: false)
        let run = WizardRun(store: store, state: WizardState(home: "/Users/you"))
        run.preview(events)
        return (store, run)
    }

    private func page(_ run: WizardRun) -> some View {
        wizardView(run.store, run).frame(width: 760, height: 620)
    }

    private func installEvents(_ name: String, upTo count: Int? = nil) throws -> [WizardState.Event] {
        let all = try InstallEvent.decodeAll(try Fixture.lines(name)).map(WizardState.Event.install)
        return count.map { Array(all.prefix($0)) } ?? all
    }

    private func report(failing ids: Set<String> = [], ok: Bool = false) throws -> PrerequisiteReport {
        var r = try BenchJSON.decode(PrerequisiteReport.self, from: try Fixture.data("doctor-prerequisites"))
        for i in r.prerequisites.indices {
            if ids.contains(r.prerequisites[i].id) { r.prerequisites[i].level = .fail }
            if ok { r.prerequisites[i].level = .ok }
        }
        return r
    }

    private func formEvents() throws -> [WizardState.Event] {
        [.chooseNewBench, .prerequisites(try report()), .primary,
         .profiles(try BenchJSON.decode(ProfileList.self, from: try Fixture.data("profile-list-wizard"))),
         .setAdminPassword("s3cret")]
    }

    @Test func wizardWelcomeAndCLIOnly() async throws {
        let (_, run) = try await wizardRun([])
        try render(page(run), "wizard-welcome")
        run.preview([.chooseCLIOnly])
        try render(page(run), "wizard-cli-only")
    }

    @Test func wizardCheckYourMac() async throws {
        var failing = try report(failing: ["command_line_tools", "homebrew"])
        failing.prerequisites[2].message = "xcode-select -p names no folder"
        failing.prerequisites[3].message = "brew was not found"
        failing.prerequisites[3].fixCommand = "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        let (_, run) = try await wizardRun([.chooseNewBench, .prerequisites(failing)])
        try render(page(run), "wizard-check-failing")
        let (_, ok) = try await wizardRun([.chooseNewBench, .prerequisites(try report(ok: true))])
        try render(page(ok), "wizard-check-ok")
    }

    @Test func wizardNewBenchReviewAndInstall() async throws {
        let (_, run) = try await wizardRun(try formEvents())
        try render(page(run), "wizard-new-bench")
        run.preview([.primary, .planned(try plan())])
        try render(page(run), "wizard-review")

        run.preview([.primary])
        run.preview(try installEvents("install-stream-success", upTo: 13))
        run.setLogLines(["==> System dependencies", "Updating Homebrew...", "==> Installing python@3.11", "bench init --frappe-branch version-15 frappe-bench"])
        try render(page(run), "wizard-install-running")

        let (_, failed) = try await wizardRun(try formEvents() + [.primary, .planned(try plan()), .primary] + (try installEvents("install-stream-failed")) + [.installEnded(exitCode: 1, error: nil)])
        try render(page(failed), "wizard-install-failed")

        let (_, exit2) = try await wizardRun(try formEvents() + [.primary, .planned(try plan()), .primary] + (try installEvents("install-stream-exit2")) + [.installEnded(exitCode: 2, error: nil)])
        try render(page(exit2), "wizard-install-exit2")

        let (_, done) = try await wizardRun(try formEvents() + [.primary, .planned(try plan()), .primary] + (try installEvents("install-stream-cancelled")) + [.installEnded(exitCode: 0, error: nil)])
        try render(page(done), "wizard-done-skipped")
    }

    private func plan() throws -> InstallPlan {
        guard case .plan(let plan)? = try InstallEvent.decodeAll(try Fixture.lines("install-dry-run")).first else { throw Fixture.FixtureError.missing("plan") }
        return plan
    }

    @Test func sidebarZeroOneAndSeveral() async throws {
        let (zero, zeroRun) = try await wizardRun([])
        let router = WindowRouter()
        func side(_ store: BenchStore, _ run: WizardRun) -> some View {
            MainWindowView(store: store, router: router, workbench: Workbench(store: store), about: AboutModel(store: store),
                           discovery: BenchDiscovery(store: store), wizard: wizardView(store, run))
                .frame(width: 900, height: 560)
        }
        try render(side(zero, zeroRun), "sidebar-zero")
        let (one, oneRun) = try await wizardRun([], empty: false)
        let oneRouter = router
        oneRouter.pane = .bench(one.benches[0].path)
        try render(side(one, oneRun), "sidebar-one")
        let store = try await windowStore()
        let several = WizardRun(store: store)
        router.pane = .bench(store.benches[1].path)
        router.benchTab = .sites
        try render(side(store, several), "sidebar-several")
    }

    @Test func settingsAndAboutWindows() async throws {
        // the Settings tabs are rendered by settingsWindow(); About by windowAbout()
        let (store, _) = try await wizardRun([], empty: false)
        let tabs = SettingsTabs()
        let part: (SettingsView.Part) -> SettingsView = { part in
            SettingsView(settings: base.settings, store: store, library: library(), launchAtLogin: LaunchAtLogin(),
                         notifier: Notifier(settings: base.settings), part: part, showsHeader: false, chooseCLI: {})
        }
        try render(SettingsTabsView(tabs: tabs, general: part(.general), menuBar: part(.menuBar)), "settings-window")
    }

    // MARK: the teaching surfaces

    @Test func walkthroughSteps() throws {
        for step in WalkthroughModel.Step.allCases {
            var model = WalkthroughModel()
            for _ in 0..<step.rawValue { _ = model.next() }
            try render(WalkthroughSheetPreview(index: step.rawValue), "walkthrough-\(step.rawValue + 1)")
        }
    }

    @Test func guidanceInThePopoverAndTheBenchHeader() async throws {
        base.cli.answer("list", json: base.listJSON())
        base.cli.answer("status", json: base.statusJSON("paused", reason: "crash", exit: 1))
        let store = base.makeStore()
        await store.start(polling: false)
        try render(PopoverView(store: store, commands: AppCommands()), "guidance-popover-paused")
        let bench = try #require(store.selected)
        let router = WindowRouter()
        router.show(bench: bench.path)
        try render(BenchPage(store: store, workbench: Workbench(store: store), bench: bench, router: router).frame(width: 760, height: 420),
                   "guidance-bench-header")
    }

    @Test func emptyStates() async throws {
        let store = try await windowStore()
        let workbench = Workbench(store: store)
        let bench = try #require(store.benches.first)
        base.cli.answer("profile", json: try Fixture.string("profile-list"))
        await workbench.loadProfiles()
        let router = WindowRouter()
        let onlyBuiltIn = Workbench(store: store)
        base.cli.answer("profile", json: #"{"schema_version":1,"profiles":[{"name":"v15-lts","kind":"builtin","source":"builtin","file":"/x.tsv","base":null,"label":"Frappe/ERPNext v15 LTS","frappe_branch":"version-15","valid":true,"error":null}]}"#)
        await onlyBuiltIn.loadProfiles()
        try render(ProfilesPane(store: store, workbench: onlyBuiltIn, router: router).frame(width: 700, height: 460), "empty-profiles")
        try render(BenchSites(store: store, workbench: workbench, bench: bench).frame(width: 640, height: 360), "empty-sites")
    }
}

/// The walkthrough sheet on a given step, for the snapshots.
struct WalkthroughSheetPreview: View {
    let index: Int

    var body: some View {
        WalkthroughSheet(start: index) {}
    }
}
