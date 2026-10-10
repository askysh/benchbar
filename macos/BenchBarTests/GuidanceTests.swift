import Foundation
import Testing
@testable import BenchBar

@Suite("Guidance, shortcuts, walkthrough")
struct GuidanceTests {
    func guide(_ state: BenchState, _ reason: StopReason? = nil, service: Bool = false, conflict: Bool = false, pending: Bool = false) -> BenchGuidance? {
        BenchGuidance.make(state: state, reason: reason, needsService: service, portConflict: conflict, pending: pending)
    }

    @Test func everyCaseHasAReasonAndAtMostOneAction() {
        #expect(guide(.stopped, .manual)?.action == .start)
        #expect(guide(.stopped, .manual)?.reason == "You stopped it.")
        #expect(guide(.stopped, nil)?.action == .start)
        #expect(guide(.stopped, nil)?.reason == "It has not been started yet.")
        #expect(guide(.paused, .crash)?.action == .viewHealth)
        #expect(guide(.paused, nil)?.reason.contains("restarts are paused") == true)
        #expect(guide(.paused, .portConflict)?.action == .reviewPortConflict)
        #expect(guide(.stopped, .portConflict)?.action == .reviewPortConflict)
        #expect(guide(.stopped, .broken)?.action == .repair)
        #expect(guide(.paused, .broken)?.action == .repair)
        #expect(guide(.crashed)?.action == .viewHealth)
        #expect(guide(.stopped, .manual, service: true)?.action == .setUpManagement, "no agent comes first")
        #expect(guide(.stopped, .manual, conflict: true)?.action == .reviewPortConflict)
        #expect(guide(.running) == nil)
        #expect(guide(.starting) == nil)
        #expect(guide(.unknown) == nil)
        #expect(guide(.stopped, .manual, pending: true) == nil, "while a start is under way")
    }

    @Test func actionTitlesAreTheOnesTheAppAlreadyUses() {
        #expect(BenchGuidance.Action.allTitles == ["Start", "View Health…", "Review Port Conflict…", "Repair…", "Set Up Management…"])
    }

    @Test func theShortcutTableHasUniqueKeysAndFeedsTheTooltips() {
        let keys = BenchShortcut.allCases.map(\.key)
        #expect(Set(keys).count == keys.count)
        #expect(BenchShortcut.start.display == "⌘U" && BenchShortcut.stop.display == "⌘D" && BenchShortcut.openSite.display == "⌘O")
        #expect(BenchShortcut.start.help() == "Start (⌘U)")
        #expect(BenchShortcut.logs.help("Follow bench.log") == "Follow bench.log (⌘L)")
        let listed = SettingsView.shortcuts.map(\.keys).joined(separator: " ")
        for shortcut in BenchShortcut.allCases { #expect(listed.contains(shortcut.display), "\(shortcut) is in Settings") }
    }

    @Test func theWalkthroughHasFourSkippableSteps() {
        var m = WalkthroughModel()
        #expect(WalkthroughModel.steps.count == 4)
        #expect(m.isFirst && m.primaryTitle == "Next" && m.progress == "1 of 4")
        m.back()
        #expect(m.index == 0)
        let moves = [m.next(), m.next(), m.next()]
        #expect(moves == [false, false, false])
        #expect(m.isLast && m.primaryTitle == "Done" && m.step == .terminal)
        m.back()
        #expect(m.step == .window)
        _ = m.next()
        let finished = m.next()
        #expect(finished, "Next on the last step finishes")
        #expect(WalkthroughModel.steps.map(\.title).allSatisfy { !$0.isEmpty })
    }

    @Test func theWalkthroughShowsOnItsOwnOnceWithABench() {
        #expect(WalkthroughModel.shouldShowOnItsOwn(seen: false, benchCount: 1, onWizard: false))
        #expect(!WalkthroughModel.shouldShowOnItsOwn(seen: true, benchCount: 3, onWizard: false))
        #expect(!WalkthroughModel.shouldShowOnItsOwn(seen: false, benchCount: 0, onWizard: false))
        #expect(!WalkthroughModel.shouldShowOnItsOwn(seen: false, benchCount: 2, onWizard: true), "the wizard offers a tour button instead")
    }

    @Test func theSeenFlagLivesInTheDefaults() throws {
        let suite = "benchbar-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let first = AppSettings(defaults: defaults)
        #expect(!first.walkthroughSeen)
        first.walkthroughSeen = true
        #expect(AppSettings(defaults: defaults).walkthroughSeen)
    }

    @Test func theSetupPlanSaysWhenItAsksForThePassword() {
        #expect(PortSetupHints.asksForPassword(setupPlan: "write runner\nadd 127.0.0.1 macdev to /etc/hosts"))
        #expect(!PortSetupHints.asksForPassword(setupPlan: "write runner"))
        #expect(!PortSetupHints.asksForPassword(setupPlan: nil))
        #expect(PortSetupHints.dialogCancelled(output: "[OK] x\n[WARN] the password dialog was cancelled; the line was not added\n"))
        #expect(!PortSetupHints.dialogCancelled(output: "[OK] done\n"))
    }

    @Test func theSidebarTooltipCarriesTheGuidance() {
        let guidance = BenchGuidance(reason: "You stopped it.", action: .start)
        let m = SidebarModel([.init(path: "/b", name: "b", state: .stopped, isBusy: false, sites: [], guidance: guidance)])
        #expect(m.benches[0].guidance == "You stopped it. Next: Start")
        #expect(SidebarModel([.init(path: "/b", name: "b", state: .running, isBusy: false, sites: [])]).benches[0].guidance == nil)
    }
}

@Suite("Setup apply", .serialized)
struct SetupSudoTests {
    @Test func applyingAsksForTheDialogOnlyThenAndOffersTheFallbackAfterACancel() async throws {
        let tests = try PortSetupTests()
        let base = tests.base
        base.cli.answer("list", json: base.listJSON())
        base.cli.answer("status", json: base.statusJSON("stopped"))
        base.cli.answer("ports plan", json: tests.planJSON())
        base.cli.answer("ports apply", .ok("[OK] set up\n[WARN] the password dialog was cancelled; the line was not added\n"))
        base.cli.answer("ports check", json: #"{"schema_version":1,"conflicts":[],"mode":"automatic"}"#)
        let runner = base.cli.runner()
        let store = base.makeStore(runner: runner)
        await store.start(polling: false)
        let run = PortSetupRun(summaries: [try #require(store.selected).summary], store: store)
        await run.loadPlan()
        #expect(runner.calls.allSatisfy { $0.environment["BENCHBAR_SUDO"] == nil }, "not before the confirmation")
        await run.apply()
        let apply = try #require(runner.calls.first { $0.arguments.starts(with: ["ports", "apply"]) })
        #expect(apply.environment["BENCHBAR_SUDO"] == "gui")
        #expect(runner.calls.filter { $0.environment["BENCHBAR_SUDO"] != nil }.count == 1)
        #expect(run.hostsFallbacks == ["benchbar site hosts --bench-dir \(base.benchPath)"])
    }
}
