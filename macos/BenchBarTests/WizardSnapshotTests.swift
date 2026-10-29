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
        // the CLI's words when another bench holds the default ports: long, and they must wrap
        var ports = try report()
        if let i = ports.prerequisites.firstIndex(where: { $0.id == "default_ports" }) {
            ports.prerequisites[i].message = ["8000", "9000", "11000", "13000"].map { "\($0) used by /Users/you/dev/frappe-bench" }
                .joined(separator: "; ") + "; a new bench gets port block 1"
        }
        // a bench already has ~/frappe-bench and macdev
        return [.suggest(WizardState.Taken(folders: ["/Users/you/frappe-bench"], sites: ["macdev": "frappe-bench"])),
                .chooseNewBench, .prerequisites(ports), .primary,
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
        var cleanup = try report(ok: true)
        // a fix in words and Mole's "then:" fix: only the command is in a copy box
        for (id, message, fix) in [
            ("cleanmymac", "CleanMyMac X.app is installed; its cleanup can delete env/, node_modules and public/dist",
             "In CleanMyMac, add /Users/you/frappe-bench to the Ignore List before running any cleanup"),
            ("mole", "Mole is installed (/opt/homebrew/bin/mo); 'mo purge' can delete env/, node_modules and dist folders inside the bench",
             "run 'mo clean --whitelist' and save once (it writes Mole's defaults), then: echo '/Users/you/frappe-bench' >> ~/.config/mole/whitelist"),
        ] {
            if let i = cleanup.prerequisites.firstIndex(where: { $0.id == id }) {
                cleanup.prerequisites[i].level = .warn
                cleanup.prerequisites[i].message = message
                cleanup.prerequisites[i].fixCommand = fix
            }
        }
        let (_, warned) = try await wizardRun([.chooseNewBench, .prerequisites(cleanup)])
        try render(page(warned), "wizard-check-cleanup-tools")
    }

    @Test func wizardNewBenchReviewAndInstall() async throws {
        let (_, run) = try await wizardRun(try formEvents())
        try render(page(run), "wizard-new-bench")
        run.preview([.primary, .planned(try plan(site: "macdev2"))])
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

    /// The dry run's plan (site macdev); another site gets port block 1, and
    /// `hostsInPlace` its hosts line already in /etc/hosts.
    private func plan(site: String? = nil, hostsInPlace: Bool = false) throws -> InstallPlan {
        guard case .plan(var plan)? = try InstallEvent.decodeAll(try Fixture.lines("install-dry-run")).first else { throw Fixture.FixtureError.missing("plan") }
        if let site {
            plan.site = site
            plan.webURL = "http://\(site):8001"
            plan.portOffset = 1
        }
        if let i = plan.steps.firstIndex(where: { $0.id == "hosts_entry" }) {
            plan.steps[i].name = "Add 127.0.0.1 \(plan.site) to /etc/hosts"
            plan.steps[i].willRun = !hostsInPlace
        }
        return plan
    }

    /// A typed site name another bench uses: flagged in the form, and the
    /// Review does not call that bench's hosts line done.
    @Test func wizardSiteNameOfAnotherBench() async throws {
        let (_, run) = try await wizardRun(try formEvents() + [.setSite("macdev")])
        try render(page(run), "wizard-new-bench-site-taken")
        var shared = try plan(site: "macdev", hostsInPlace: true)
        shared.webURL = "http://macdev:8001"
        run.preview([.primary, .planned(shared)])
        try render(page(run), "wizard-review-site-taken")
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
        try render(SettingsTabsView(tabs: tabs, general: part(.general), menuBar: part(.menuBar))
            .frame(width: SettingsTabsView.size.width, height: SettingsTabsView.size.height), "settings-window")
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
