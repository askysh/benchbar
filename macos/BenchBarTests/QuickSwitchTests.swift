import Foundation
import Testing
@testable import BenchBar

@Suite("Quick Switch")
struct QuickSwitchTests {
    let bench = "/Users/you/frappe-bench"

    /// `openAs` is what the CLI reports: turned on, in developer mode and the default site.
    func row(_ name: String, developerMode: Bool = true, isDefault: Bool = false, needsHosts: Bool = false,
             openAsEnabled: Bool = true) -> SiteRow {
        SiteRow(name: name, isDefault: isDefault, url: "http://\(name):8000", needsHosts: needsHosts, developerMode: developerMode,
                openAsEnabled: openAsEnabled, openAs: openAsEnabled && developerMode && isDefault)
    }

    var devBench: QuickSwitchBench {
        QuickSwitchBench(path: bench, running: true, rows: [row("macdev", isDefault: true), row("prod.example", developerMode: false), row("second")])
    }

    let otherBench = "/Users/you/other-bench"

    var otherDevBench: QuickSwitchBench {
        QuickSwitchBench(path: otherBench, running: true, rows: [row("other.site", isDefault: true)])
    }

    func pin(_ user: String, _ label: String? = nil, _ fullName: String? = nil) -> PinnedUser {
        PinnedUser(user: user, label: label, fullName: fullName)
    }

    func model(pins: [PinnedUser] = [], recents: [RecentUser] = [], benches: [QuickSwitchBench]? = nil,
               last: String? = nil, site: String = "macdev", loaded: Bool = true) -> QuickSwitchModel {
        let key = OpenAsStore.siteKey(bench: bench, site: site)
        return QuickSwitchModel(benches: benches ?? [devBench], selectedPath: bench, lastSwitchedKey: last,
                                pins: [key: pins], recents: [key: recents], loaded: loaded)
    }

    let ne = PinnedUser(user: "ne@x.com", label: "NE Pune", fullName: "Priya Nair")
    let tech = PinnedUser(user: "tech@x.com", label: nil, fullName: "Ravi Kumar")

    func recents(_ users: String...) -> [RecentUser] { users.map { RecentUser(user: $0, fullName: nil) } }

    @Test func rowsAreSwitchBackThenPinsThenAdministrator() {
        let m = model(pins: [ne, tech], recents: recents("tech@x.com", "ne@x.com"))
        #expect(m.rows.map(\.kind) == [.switchBack, .pin, .pin, .administrator])
        #expect(m.rows.map(\.user) == ["ne@x.com", "ne@x.com", "tech@x.com", "Administrator"])
        #expect(m.rows[0].title == "Switch Back to NE Pune")
    }

    @Test func defaultSelectionIsSwitchBackElseTheFirstPin() {
        let withBack = model(pins: [ne, tech], recents: recents("tech@x.com", "ne@x.com"))
        #expect(withBack.selectable[withBack.selection].kind == .switchBack)
        let pinsOnly = model(pins: [ne, tech])
        #expect(pinsOnly.selectable[pinsOnly.selection].user == "ne@x.com")
        let nothing = model()
        #expect(nothing.selectable[nothing.selection].kind == .administrator)
    }

    @Test func upAndDownWrapAround() {
        var m = model(pins: [ne, tech])
        #expect(m.selectable.count == 3)
        _ = m.handle(.up)
        #expect(m.selection == 2)
        _ = m.handle(.down)
        #expect(m.selection == 0)
        _ = m.handle(.down)
        _ = m.handle(.down)
        _ = m.handle(.down)
        #expect(m.selection == 0)
    }

    @Test func digitsSwitchAdministratorAndThePinsAtOnce() {
        var m = model(pins: [ne, tech])
        #expect(m.handle(.digit(2)) == .switchTo(QuickSwitchRequest(user: "tech@x.com", fullName: "Ravi Kumar", target: m.target!)))
        var admin = model(pins: [ne])
        guard case .switchTo(let request) = admin.handle(.digit(0)) else { Issue.record("0 did not switch"); return }
        #expect(request.user == "Administrator")
        var none = model(pins: [ne])
        #expect(none.handle(.digit(5)) == .none)
        #expect(!none.isSwitching)
    }

    @Test func aDigitWithNoRowIsTypedIntoTheField() {
        let m = model(pins: [ne])
        #expect(m.key(keyCode: 21, characters: "4", hasModifier: false) == nil)
        #expect(m.key(keyCode: 29, characters: "0", hasModifier: false) == .digit(0))
        #expect(m.key(keyCode: 18, characters: "1", hasModifier: false) == .digit(1))
    }

    @Test func digitsAreTextOnceSomethingIsTyped() {
        var m = model(pins: [ne])
        m.setQuery("a")
        #expect(m.key(keyCode: 18, characters: "1", hasModifier: false) == nil)
        #expect(m.handle(.digit(1)) == .none)
        m.setQuery("")
        #expect(m.key(keyCode: 18, characters: "1", hasModifier: false) == .digit(1))
    }

    @Test func keyCodesMapToKeys() {
        let m = model()
        #expect(m.key(keyCode: 126, characters: nil, hasModifier: false) == .up)
        #expect(m.key(keyCode: 125, characters: nil, hasModifier: false) == .down)
        #expect(m.key(keyCode: 36, characters: "\r", hasModifier: false) == .confirm)
        #expect(m.key(keyCode: 53, characters: nil, hasModifier: false) == .escape)
        #expect(m.key(keyCode: 48, characters: "\t", hasModifier: false) == .tab)
        #expect(m.key(keyCode: 0, characters: "a", hasModifier: false) == nil)
        #expect(m.key(keyCode: 18, characters: "1", hasModifier: true) == nil)
    }

    @Test func typingFiltersByLabelIdAndFullName() {
        var m = model(pins: [ne, tech])
        m.setQuery("pune")
        #expect(m.rows.map(\.user) == ["ne@x.com"])
        m.setQuery("TECH@")
        #expect(m.rows.map(\.user) == ["tech@x.com"])
        m.setQuery("ravi")
        #expect(m.rows.map(\.user) == ["tech@x.com"])
        m.setQuery("priya")
        #expect(m.rows.map(\.user) == ["ne@x.com"])
        m.setQuery("admin")
        #expect(m.rows.map(\.user) == ["Administrator"])
    }

    @Test func twoCharactersAskForASearchAfterTheDebounceAndOneDoesNot() {
        var m = model(pins: [ne])
        m.setQuery("p")
        #expect(m.searchRequest == nil)
        m.setQuery("pr")
        let request = m.searchRequest
        #expect(request?.query == "pr")
        #expect(request?.debounce == .milliseconds(250))
        #expect(request?.limit == 8)
        #expect(request?.target.site == "macdev")
        m.setQuery(" p ")
        #expect(m.searchRequest == nil)
    }

    @Test func searchResultsLandBelowTheMatchesAndStaleOnesAreDropped() {
        var m = model(pins: [ne])
        m.setQuery("ne")
        let found = [SiteUser(name: "ne@x.com", fullName: "Priya Nair", userType: "System User", roles: [], roleCount: 0, lastLogin: nil),
                     SiteUser(name: "neha@x.com", fullName: "Neha Rao", userType: "System User", roles: [], roleCount: 0, lastLogin: nil)]
        m.applySearch(query: "n", users: found)
        #expect(m.otherRows.isEmpty)
        m.applySearch(query: "ne", users: found)
        #expect(m.rows.map(\.user) == ["ne@x.com"])
        #expect(m.otherRows.map(\.user) == ["neha@x.com"])
        #expect(m.otherRows.first?.title == "Neha Rao")
        #expect(m.selectable.map(\.user) == ["ne@x.com", "neha@x.com"])
        m.setQuery("nex")
        #expect(m.otherRows.isEmpty)
    }

    @Test func onlyDefaultSitesAreOfferedBecausePortServesOnlyTheDefault() {
        #expect(devBench.rows.contains { $0.name == "second" && $0.developerMode })
        #expect(QuickSwitchModel.targets(benches: [devBench], selectedPath: bench).map(\.site) == ["macdev"])
    }

    @Test func tabCyclesTheBenchesDefaultSites() {
        var m = model(pins: [ne], benches: [devBench, otherDevBench])
        #expect(m.targets.map(\.site) == ["macdev", "other.site"])
        #expect(m.title == "Open macdev as…")
        _ = m.handle(.tab)
        #expect(m.title == "Open other.site as…")
        _ = m.handle(.tab)
        #expect(m.title == "Open macdev as…")
        var single = model(benches: [QuickSwitchBench(path: bench, running: true, rows: [row("macdev", isDefault: true)])])
        _ = single.handle(.tab)
        #expect(single.title == "Open macdev as…")
    }

    @Test func aDefaultSiteInDeveloperModeIsNotOfferedUntilOpenAsIsTurnedOn() {
        let off = QuickSwitchBench(path: bench, running: true, rows: [row("macdev", isDefault: true, openAsEnabled: false)])
        #expect(QuickSwitchModel.targets(benches: [off], selectedPath: bench).isEmpty)
        #expect(model(benches: [off]).blockerText == "Open as is off for macdev. Turn it on with Allow Open as… in its Sites tab.")
    }

    @Test func aSiteThatNeedsAHostsLineOrAStoppedBenchIsNotOffered() {
        let hosts = QuickSwitchBench(path: bench, running: true, rows: [row("macdev", needsHosts: true)])
        #expect(QuickSwitchModel.targets(benches: [hosts], selectedPath: bench).isEmpty)
        let stopped = QuickSwitchBench(path: bench, running: false, rows: [row("macdev")])
        #expect(QuickSwitchModel.targets(benches: [stopped], selectedPath: bench).isEmpty)
    }

    @Test func itOpensOnTheLastSwitchedSiteElseTheSelectedBenchsDefault() {
        let other = OpenAsStore.siteKey(bench: otherBench, site: "other.site")
        #expect(model(benches: [devBench, otherDevBench], last: other).title == "Open other.site as…")
        #expect(model(last: "gone|site").title == "Open macdev as…")
        #expect(model().title == "Open macdev as…")
        let m = QuickSwitchModel(benches: [otherDevBench, devBench], selectedPath: bench, lastSwitchedKey: nil, pins: [:], recents: [:])
        #expect(m.title == "Open macdev as…")
    }

    @Test func theCurrentUserCarriesATickAndTheWordsLastOpened() {
        let m = model(pins: [ne, tech], recents: recents("tech@x.com", "ne@x.com"))
        let current = m.rows.filter(\.isCurrent)
        #expect(current.map(\.user) == ["tech@x.com"])
        #expect(current.first?.hint == "last opened")
        #expect(current.first?.spokenLabel == "Ravi Kumar, tech@x.com, last opened")
        #expect(m.rows.first { $0.user == "ne@x.com" && $0.kind == .pin }?.hint == nil)
        let admin = model(pins: [ne], recents: recents("Administrator"))
        #expect(admin.rows.first { $0.kind == .administrator }?.isCurrent == true)
    }

    static let developerModeOff = "macdev is not in developer mode. Run: bench --site macdev set-config developer_mode 1"

    func blocker(_ benches: [QuickSwitchBench], loaded: Bool = true) -> QuickSwitchModel.Blocker? {
        model(benches: benches, loaded: loaded).blocker
    }

    @Test func emptyAndStoppedStatesUseTheExactCopy() {
        let none = QuickSwitchBench(path: bench, running: true, rows: [row("macdev", developerMode: false, isDefault: true)])
        #expect(model(benches: [none]).blockerText == Self.developerModeOff)
        let stopped = QuickSwitchBench(path: bench, running: false, rows: [row("macdev", isDefault: true)])
        #expect(model(benches: [stopped]).blockerText == "Start frappe-bench first")
        #expect(model().blockerText == nil)
        var blocked = model(benches: [none])
        #expect(blocked.handle(.confirm) == .none)
        #expect(blocked.handle(.escape) == .close)
    }

    @Test func eachCauseOfNothingToSwitchOnHasItsOwnCopy() {
        func bench(running: Bool = true, _ rows: [SiteRow]) -> QuickSwitchBench { QuickSwitchBench(path: self.bench, running: running, rows: rows) }
        #expect(blocker([], loaded: false)?.text == "Loading benches…")
        #expect(QuickSwitchModel(benches: [], selectedPath: nil, lastSwitchedKey: nil, pins: [:], recents: [:],
                                 loaded: false, cliAvailable: false).blocker?.text == "The benchbar command line tool is not available.")
        #expect(blocker([bench([row("second")])])?.text == "frappe-bench has no default site. Make one the default in its Sites tab.")
        #expect(blocker([])?.text == "No bench to open as a user on. Add one in BenchBar.")
        var unknown = row("macdev", developerMode: false, isDefault: true)
        unknown.developerModeKnown = false
        #expect(blocker([bench([unknown])])?.text == "Update the benchbar CLI to use Open as")
        #expect(blocker([bench([row("macdev", developerMode: false, isDefault: true)])])?.text == Self.developerModeOff)
        #expect(blocker([bench(running: false, [row("macdev", isDefault: true)])])?.text == "Start frappe-bench first")
        #expect(blocker([bench([row("macdev", isDefault: true, needsHosts: true)])])?.text == "Add the hosts line for macdev in the BenchBar window")
        #expect(blocker([bench([row("macdev", isDefault: true, openAsEnabled: false)])])?.text
                == "Open as is off for macdev. Turn it on with Allow Open as… in its Sites tab.")
        #expect(blocker([bench([row("macdev", developerMode: false, isDefault: true), row("second")])])?.text == Self.developerModeOff,
                "a developer-mode site that is not the default does not count")
        #expect(model().blocker == nil)
    }

    @Test func noMatchesSaysSoOnceNothingIsLeftAndNothingIsPending() {
        var m = model(pins: [ne])
        m.setQuery("z")
        #expect(m.emptyResultCopy == "No users match")
        m.setQuery("zz")
        #expect(m.emptyResultCopy == nil)
        m.applySearch(query: "zz", users: [])
        #expect(m.emptyResultCopy == "No users match")
    }

    @Test func returnOnARowIsOneSwitchEvenWhenPressedTwice() {
        var m = model(pins: [ne, tech], recents: recents("tech@x.com", "ne@x.com"))
        let first = m.handle(.confirm)
        guard case .switchTo(let request) = first else { Issue.record("Return did not switch"); return }
        #expect(request.user == "ne@x.com")
        #expect(request.target.site == "macdev")
        #expect(m.isSwitching && m.switchingUser == "ne@x.com")
        #expect(m.handle(.confirm) == .none)
        #expect(m.handle(.digit(1)) == .none)
        #expect(m.handle(.down) == .none)
        #expect(m.handle(.escape) == .close)
    }

    @Test func aFailedSwitchStaysInlineAndAllowsAnotherTry() {
        var m = model(pins: [ne])
        _ = m.handle(.confirm)
        m.finishSwitch(error: "benchbar could not sign in")
        #expect(m.errorMessage == "benchbar could not sign in")
        #expect(!m.isFinished)
        guard case .switchTo = m.handle(.confirm) else { Issue.record("retry did not switch"); return }
        m.finishSwitch(error: nil)
        #expect(m.isFinished && m.errorMessage == nil)
    }

    @Test func theFooterShowsQuickPickOnlyWhileDigitsSwitch() {
        var m = model(pins: [ne])
        #expect(m.footerHint == "↑↓ select   ↩ switch   0 to 9 quick pick   esc close")
        m.setQuery("n")
        #expect(m.footerHint == "↑↓ select   ↩ switch   esc close")
        m.setQuery("")
        #expect(m.footerHint.hasSuffix("esc close") && !m.footerHint.contains("⎋"))
    }

    @Test func noPinsShowsTheHowToPinHint() {
        #expect(model().pinHint == "Pin people from Find User… to switch to them here")
        #expect(model(pins: [ne]).pinHint == nil)
    }

    @Test func theOtherUsersHeadingNeedsResultsAndSearchingShowsItsOwnLine() {
        var m = model(pins: [ne])
        m.setQuery("ne")
        #expect(m.searchingText == "Searching…")
        #expect(!m.showsOtherUsersHeading)
        m.applySearch(query: "ne", users: [])
        #expect(m.searchingText == nil && !m.showsOtherUsersHeading)
        m.setQuery("neh")
        let found = [SiteUser(name: "neha@x.com", fullName: "Neha Rao", userType: "System User", roles: [], roleCount: 0, lastLogin: nil)]
        m.applySearch(query: "neh", users: found)
        #expect(m.showsOtherUsersHeading && m.searchingText == nil)
    }

    @Test func aFreshOfferIsComparedByWhatItOffers() {
        let loading = model(benches: [], loaded: false)
        #expect(loading.blocker == .loading)
        #expect(!loading.offersSame(as: model()))
        #expect(model().offersSame(as: model(pins: [ne])))
    }

    // MARK: the lab is the one switch

    final class FakeHotKey: HotKeyRegistering {
        var accept = true
        var registered = false
        var registerCalls = 0
        func register() -> Bool {
            registerCalls += 1
            registered = accept
            return accept
        }
        func unregister() { registered = false }
    }

    func labEntries(quickSwitch: Bool) throws -> [LabEntry] {
        let json = """
        {"schema_version":1,"labs":[{"name":"quick-switch","title":"Quick Switch panel","description":"d","warning":"w","since":"0.9.0","enabled":\(quickSwitch),"commands":[]}]}
        """
        return try BenchJSON.decode(LabsDocument.self, from: Data(json.utf8)).labs
    }

    /// Labs wired to a fake CLI, and a controller on a fake key, hooked up as the app does.
    @MainActor func wired(startsOn: Bool, accept: Bool = true) throws -> (Labs, QuickSwitchController, FakeHotKey, FakeLabsBackend) {
        let backend = FakeLabsBackend()
        backend.result = .success(try labEntries(quickSwitch: startsOn))
        let labs = Labs(loader: backend.loader)
        let key = FakeHotKey()
        key.accept = accept
        let controller = QuickSwitchController(store: BenchStore(settings: AppSettings(defaults: UserDefaults(suiteName: "benchbar-tests-\(UUID().uuidString)")!)),
                                               labs: labs, hotKey: key)
        labs.observe(.quickSwitch) { _ in controller.sync() }
        controller.sync()
        return (labs, controller, key, backend)
    }

    @MainActor @Test func theKeyIsNotRegisteredBeforeLabsAnswered() throws {
        let (_, _, key, _) = try wired(startsOn: true)
        #expect(key.registerCalls == 0 && !key.registered)
    }

    @MainActor @Test func labOnRegistersAndOffUnregisters() async throws {
        let (labs, _, key, backend) = try wired(startsOn: true)
        await labs.refresh()
        #expect(labs.isOn(.quickSwitch) && key.registered)
        try await labs.set(.quickSwitch, on: false)
        #expect(!key.registered)
        #expect(backend.sets == ["quick-switch:false"])
        try await labs.set(.quickSwitch, on: true)
        #expect(key.registered)
    }

    @MainActor @Test func aRefusedKeyRollsTheLabBackThroughTheCLIAndLeavesTheNote() async throws {
        let (labs, _, key, backend) = try wired(startsOn: false, accept: false)
        await labs.refresh()
        try await labs.set(.quickSwitch, on: true)
        for _ in 0..<200 where labs.isOn(.quickSwitch) || labs.errors["quick-switch"] == nil { await Task.yield() }
        #expect(!labs.isOn(.quickSwitch) && !key.registered)
        #expect(backend.sets == ["quick-switch:true", "quick-switch:false"], "the CLI flag rolled back too")
        #expect(labs.errors["quick-switch"] == QuickSwitchController.conflictNote)
    }

    @MainActor @Test func aRefusedKeyWithAFailingRollbackKeepsTheCLITruthAndSaysHowToFixIt() async throws {
        let (labs, _, key, backend) = try wired(startsOn: false, accept: false)
        backend.failTurningOff = true
        await labs.refresh()
        try await labs.set(.quickSwitch, on: true)
        for _ in 0..<200 where labs.errors["quick-switch"] != QuickSwitchController.stuckOnNote { await Task.yield() }
        #expect(labs.isOn(.quickSwitch) && !key.registered, "the toggle reads what the CLI holds")
        #expect(labs.errors["quick-switch"] == QuickSwitchController.stuckOnNote)
    }

    @MainActor @Test func thePanelDoesNotOpenWhileTheLabIsOff() throws {
        let (labs, controller, _, _) = try wired(startsOn: false)
        controller.toggle()
        #expect(!controller.isShowing && !labs.isOn(.quickSwitch))
    }

    @Test func thePopoverBindingsAreAbsentWhileTheLabIsOff() {
        let items = OpenAsMenuModel.items(pins: [PinnedUser(user: "a@x.com", label: "A", fullName: nil)], recents: [])
        #expect(OpenAsMenuModel.popoverShortcuts(items, quickSwitchOn: false).isEmpty)
        #expect(!OpenAsMenuModel.popoverShortcuts(items, quickSwitchOn: true).isEmpty)
    }

    @Test func theMenuItemsCarryTheirKeyAsTrailingTextOnlyWhenBound() {
        let items = OpenAsMenuModel.items(pins: [], recents: [])
        let keys = OpenAsMenuModel.popoverShortcuts(items, quickSwitchOn: true)
        let admin = items.first { if case .administrator = $0 { true } else { false } }!
        #expect(OpenAsMenuModel.titled("Administrator", key: keys[admin.id]) == "Administrator    ⌘0")
        #expect(OpenAsMenuModel.titled("Administrator", key: OpenAsMenuModel.popoverShortcuts(items, quickSwitchOn: false)[admin.id]) == "Administrator")
    }

    @Test func theShortcutRowsForQuickSwitchShowOnlyWhileTheLabIsOn() {
        let off = SettingsView.shortcuts(quickSwitch: false).map(\.keys).joined(separator: " ")
        let on = SettingsView.shortcuts(quickSwitch: true).map(\.keys).joined(separator: " ")
        #expect(!off.contains("⌃⌥U") && !off.contains("⇧⌘O"))
        #expect(on.contains("⌃⌥U") && on.contains("⇧⌘O"))
    }

    @Test func theSpokenTitleDropsTheEllipsis() {
        #expect(model().spokenTitle == "Open macdev as")
    }
}
