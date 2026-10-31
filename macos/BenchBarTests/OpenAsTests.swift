import Foundation
import Testing
@testable import BenchBar

/// Calls the store's CLI makes, answered from a table.
nonisolated final class FakeOpenAsCLI: OpenAsCLI, @unchecked Sendable {
    struct Open: Equatable {
        var site: String
        var user: String
        var path: String?
    }

    private let lock = NSLock()
    private var _opens: [Open] = []
    var failure: CLIError?
    var sid = "freshsid0001"
    var fullName: String? = "Priya Nair"
    var userType = "System User"

    var opens: [Open] { lock.withLock { _opens } }

    func openAs(bench: String, site: String, user: String, path: String?) async throws(CLIError) -> OpenAsResult {
        lock.withLock { _opens.append(Open(site: site, user: user, path: path)) }
        if let failure { throw failure }
        return OpenAsResult(site: site, user: user, fullName: fullName, userType: userType, path: path ?? "/app",
                            url: "http://\(site):8000/login?redirect-to=%2Fapp&sid=\(sid)&t=1")
    }

    func users(bench: String, site: String, search: String?, limit: Int) async throws(CLIError) -> UserList {
        UserList(site: site, users: [], truncated: false)
    }
}

/// An Open as CLI whose answers wait until the test lets them through, to hold switches in flight.
nonisolated final class GatedOpenAsCLI: OpenAsCLI, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var waitingCount: Int { lock.withLock { waiting.count } }

    func releaseOne() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock { waiting.isEmpty ? nil : waiting.removeFirst() }
        next?.resume()
    }

    func openAs(bench: String, site: String, user: String, path: String?) async throws(CLIError) -> OpenAsResult {
        await withCheckedContinuation { continuation in lock.withLock { waiting.append(continuation) } }
        return OpenAsResult(site: site, user: user, fullName: nil, userType: "System User", path: path ?? "/app",
                            url: "http://\(site):8000/login?redirect-to=%2Fapp&sid=gated\(user.count)&t=1")
    }

    func users(bench: String, site: String, search: String?, limit: Int) async throws(CLIError) -> UserList {
        UserList(site: site, users: [], truncated: false)
    }
}

final class FakeBrowser: BrowserOpening {
    var opened: [URL] = []

    func open(_ url: URL) { opened.append(url) }
}

@Suite("Open as")
struct OpenAsTests {
    let bench = "/Users/you/frappe-bench"
    let site = "macdev"
    let siteURL = "http://macdev:8000"

    func scratchDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "benchbar-open-as-\(UUID().uuidString)"))
    }

    func makeStore(defaults: UserDefaults? = nil, browser: FakeBrowser = FakeBrowser(),
               check: @escaping @Sendable (URL, String) async -> String? = { _, _ in nil }) throws -> OpenAsStore {
        OpenAsStore(defaults: try defaults ?? scratchDefaults(), browser: browser, checkSession: check)
    }

    func switchTo(_ user: String, on store: OpenAsStore, cli: any OpenAsCLI, path: String? = nil) async -> String? {
        await store.switchTo(user: user, bench: bench, site: site, siteURL: siteURL, path: path, client: cli)
    }

    // MARK: models

    @Test func openAsResultDecodesTheCLIDocument() throws {
        let result = try BenchJSON.decode(OpenAsResult.self, from: Fixture.data("open-as"))
        #expect(result.user == "priya@example.com" && result.fullName == "Priya Nair" && result.userType == "System User")
        #expect(result.path == "/app")
        #expect(OpenAsLink.sessionID(in: try #require(result.url)) == "fixturesid0123456789")
    }

    @Test func theLinkIsAbsentWithoutPrintURL() throws {
        let json = #"{"schema_version":1,"site":"macdev","user":"a@x.com","full_name":"A","user_type":"System User","path":"/app","opened":true}"#
        #expect(try BenchJSON.decode(OpenAsResult.self, from: Data(json.utf8)).url == nil)
    }

    @Test func theUserListDecodesWithMissingNamesAndLogins() throws {
        let list = try BenchJSON.decode(UserList.self, from: Fixture.data("open-as-users"))
        #expect(list.truncated)
        #expect(list.users.map(\.name) == ["Administrator", "priya@example.com", "customer@example.com"])
        #expect(list.users[1].roles.count == 5 && list.users[1].roleCount == 9)
        #expect(list.users[2].fullName == nil && list.users[2].lastLogin == nil && list.users[2].userType == "Website User")
    }

    @Test func aSiteWithoutDeveloperModeDecodesToNilAndAHiddenRow() throws {
        let old = #"{"name":"macdev","default":true,"hosts_entry":true,"ping_code":200}"#
        let info = try JSONDecoder().decode(SiteInfo.self, from: Data(old.utf8))
        #expect(info.developerMode == nil)
        #expect(SiteRow.make(sites: [info], defaultSite: "macdev", port: 8000).map(\.developerMode) == [false])
        #expect(SiteRow.make(sites: [info], defaultSite: "macdev", port: 8000).map(\.developerModeKnown) == [false])
        var on = info
        on.developerMode = true
        #expect(SiteRow.make(sites: [on], defaultSite: "macdev", port: 8000).map(\.developerMode) == [true])
        #expect(SiteRow.make(sites: [on], defaultSite: "macdev", port: 8000).map(\.developerModeKnown) == [true])
        let sent = #"{"name":"macdev","default":true,"hosts_entry":true,"ping_code":null,"developer_mode":true}"#
        #expect(try JSONDecoder().decode(SiteInfo.self, from: Data(sent.utf8)).developerMode == true)
    }

    // MARK: CLI client

    @Test func openAsPassesTheUserThePathAndPrintURL() async throws {
        let runner = FakeRunner { _ in .ok(try! Fixture.string("open-as")) }
        let client = CLIClient(executable: URL(fileURLWithPath: "/bin/benchbar"), runner: runner)
        let result = try await client.openAs(bench: bench, site: site, user: "a+b@x.com", path: "/app/nst?status=Open#x")
        #expect(result.user == "priya@example.com")
        #expect(runner.calls.first?.arguments == ["open", "--bench-dir", bench, "--site", site, "--as", "a+b@x.com",
                                                  "--path", "/app/nst?status=Open#x", "--print-url", "--json"])
        _ = try await client.openAs(bench: bench, site: site, user: "a@x.com", path: nil)
        #expect(runner.calls.last?.arguments == ["open", "--bench-dir", bench, "--site", site, "--as", "a@x.com", "--print-url", "--json"])
    }

    @Test func usersPassesTheSearchAsOneArgument() async throws {
        let runner = FakeRunner { _ in .ok(try! Fixture.string("open-as-users")) }
        let client = CLIClient(executable: URL(fileURLWithPath: "/bin/benchbar"), runner: runner)
        _ = try await client.users(bench: bench, site: site, search: "o'brien x", limit: 50)
        #expect(runner.calls.first?.arguments == ["users", "--bench-dir", bench, "--site", site, "--search", "o'brien x", "--limit", "50", "--json"])
        _ = try await client.users(bench: bench, site: site, search: "", limit: 50)
        #expect(runner.calls.last?.arguments == ["users", "--bench-dir", bench, "--site", site, "--limit", "50", "--json"])
    }

    @Test func aMalformedAnswerDoesNotKeepTheLinkInItsError() async {
        let runner = FakeRunner { _ in .ok("{\"schema_version\":1,\"url\":\"http://macdev:8000/login?sid=secretsid1&t=1\"") }
        let client = CLIClient(executable: URL(fileURLWithPath: "/bin/benchbar"), runner: runner)
        do {
            _ = try await client.openAs(bench: bench, site: site, user: "a@x.com", path: nil)
            Issue.record("expected a decoding failure")
        } catch {
            #expect(!String(describing: error).contains("secretsid1"))
            #expect(error.recoverySuggestion?.contains("secretsid1") != true)
        }
    }

    @Test func aRefusalIsShownWithoutAnySessionID() async {
        let runner = FakeRunner { _ in CommandOutput(exitCode: 1, stdout: "http://macdev:8000/login?sid=secretsid1&t=1", stderr: "[FAIL] Frappe refused the login: sid=secretsid1") }
        let client = CLIClient(executable: URL(fileURLWithPath: "/bin/benchbar"), runner: runner)
        do {
            _ = try await client.openAs(bench: bench, site: site, user: "a@x.com", path: nil)
            Issue.record("expected a refusal")
        } catch {
            #expect(!error.localizedDescription.contains("secretsid1"))
        }
    }

    // MARK: links

    @Test func theRedirectIsEncodedOnceAndAnOldSessionIDIsRemoved() throws {
        let url = try #require(OpenAsLink.url(base: siteURL, path: "/app/nst?status=Open&sid=old#x", sid: "SID1", millis: 42))
        #expect(url.absoluteString == "http://macdev:8000/login?redirect-to=%2Fapp%2Fnst%3Fstatus%3DOpen%23x&sid=SID1&t=42")
        #expect(OpenAsLink.removingSession(from: "/app/x?sid=old") == "/app/x")
        #expect(OpenAsLink.removingSession(from: "/app/x?a=1&sid=old&b=2") == "/app/x?a=1&b=2")
        #expect(OpenAsLink.removingSession(from: "/app/todo") == "/app/todo")
        let plus = try #require(OpenAsLink.url(base: siteURL, path: "/app/user/a+b@x.com", sid: "S", millis: 1))
        #expect(plus.absoluteString.contains("redirect-to=%2Fapp%2Fuser%2Fa%2Bb%40x.com&"))
    }

    @Test func scrubHidesEverySessionIDInAMessage() {
        #expect(OpenAsLink.scrub("bad link http://h/login?redirect-to=%2Fapp&sid=abc123&t=9 end sid=zzz") == "bad link http://h/login?redirect-to=%2Fapp&sid=…&t=9 end sid=…")
    }

    // MARK: switching

    @Test func eachSwitchGetsItsOwnTimestamp() async throws {
        let browser = FakeBrowser()
        let cli = FakeOpenAsCLI()
        let store = try makeStore(browser: browser, check: { _, sid in sid == "freshsid0001" ? "priya@example.com" : nil })
        _ = await switchTo("priya@example.com", on: store, cli: cli)
        _ = await switchTo("priya@example.com", on: store, cli: cli)
        _ = await switchTo("priya@example.com", on: store, cli: cli)
        #expect(cli.opens.count == 1)
        let stamps = browser.opened.dropFirst().compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "t" }?.value }
        #expect(stamps.count == 2 && Set(stamps).count == 2)
        #expect(browser.opened.dropFirst().allSatisfy { $0.absoluteString.contains("redirect-to=%2Fapp&sid=freshsid0001&t=") })
    }

    @Test func aDeadCachedSessionAsksTheCLIForANewOne() async throws {
        let cli = FakeOpenAsCLI()
        let browser = FakeBrowser()
        let store = try makeStore(browser: browser, check: { _, _ in "Guest" })
        #expect(await switchTo("priya@example.com", on: store, cli: cli) == nil)
        #expect(await switchTo("priya@example.com", on: store, cli: cli) == nil)
        #expect(cli.opens.count == 2)
        #expect(browser.opened.count == 2)
    }

    @Test func aLiveCachedSessionIsReusedWithoutTheCLI() async throws {
        let cli = FakeOpenAsCLI()
        let store = try makeStore(check: { _, _ in "priya@example.com" })
        _ = await switchTo("priya@example.com", on: store, cli: cli)
        #expect(await switchTo("priya@example.com", on: store, cli: cli) == nil)
        #expect(cli.opens.count == 1)
    }

    @Test func aSiteNoLongerUsableLosesItsCachedSessions() async throws {
        let cli = FakeOpenAsCLI()
        let store = try makeStore(check: { _, _ in "priya@example.com" })
        _ = await switchTo("priya@example.com", on: store, cli: cli)
        // another site of the bench, and another bench's macdev, keep theirs
        store.forgetSessions(bench: "/Users/you/other-bench", keeping: [])
        store.forgetSessions(bench: bench, keeping: [site])
        _ = await switchTo("priya@example.com", on: store, cli: cli)
        #expect(cli.opens.count == 1)
        // Open as off on macdev: the next switch asks the CLI, which refuses there
        store.forgetSessions(bench: bench, keeping: [])
        _ = await switchTo("priya@example.com", on: store, cli: cli)
        #expect(cli.opens.count == 2)
    }

    @Test func aSessionOfAnotherUserIsNotReused() async throws {
        let cli = FakeOpenAsCLI()
        let store = try makeStore(check: { _, _ in "someone.else@example.com" })
        _ = await switchTo("priya@example.com", on: store, cli: cli)
        _ = await switchTo("priya@example.com", on: store, cli: cli)
        #expect(cli.opens.count == 2)
    }

    @Test func aWebsiteUsersCachedSessionLandsOnTheSiteRoot() async throws {
        let cli = FakeOpenAsCLI()
        cli.userType = "Website User"
        let browser = FakeBrowser()
        let store = try makeStore(browser: browser, check: { _, _ in "customer@example.com" })
        _ = await switchTo("customer@example.com", on: store, cli: cli)
        _ = await switchTo("customer@example.com", on: store, cli: cli)
        #expect(browser.opened.last?.absoluteString.contains("redirect-to=%2F&sid=") == true)
    }

    @Test func aRefusalComesBackAsTextAndOpensNothing() async throws {
        let cli = FakeOpenAsCLI()
        cli.failure = .failed(command: "open", exitCode: 1, message: "macdev is not in developer mode, so benchbar will not sign in as another user.")
        let browser = FakeBrowser()
        let store = try makeStore(browser: browser)
        let error = await switchTo("a@x.com", on: store, cli: cli)
        #expect(error == "macdev is not in developer mode, so benchbar will not sign in as another user.")
        #expect(browser.opened.isEmpty)
        #expect(store.recents(bench: bench, site: site).isEmpty)
        #expect(!store.isSwitching(bench: bench, site: site))
    }

    @Test func theSpinnerStaysUntilTheLastOfTwoSwitchesOnASiteEnds() async throws {
        let cli = GatedOpenAsCLI()
        let store = try makeStore()
        let first = Task { await switchTo("a@x.com", on: store, cli: cli) }
        let second = Task { await switchTo("bb@x.com", on: store, cli: cli) }
        while cli.waitingCount < 2 { await Task.yield() }
        #expect(store.isSwitching(bench: bench, site: site))
        #expect(!store.isSwitching(bench: bench, site: "other"))
        cli.releaseOne()
        while cli.waitingCount > 1 || store.recents(bench: bench, site: site).isEmpty { await Task.yield() }
        #expect(store.isSwitching(bench: bench, site: site), "one switch is still running")
        cli.releaseOne()
        _ = await first.value
        _ = await second.value
        #expect(!store.isSwitching(bench: bench, site: site))
    }

    @Test func aSuccessClearsOnlyTheErrorAnEarlierSwitchLeft() throws {
        let store = try makeStore()
        #expect(store.lastError(afterSwitchOn: bench, current: "start failed", error: nil) == "start failed")
        #expect(store.lastError(afterSwitchOn: bench, current: "start failed", error: "no session") == "no session")
        #expect(store.lastError(afterSwitchOn: bench, current: "no session", error: nil) == nil)
        #expect(store.lastError(afterSwitchOn: bench, current: "start failed", error: nil) == "start failed")
        #expect(store.lastError(afterSwitchOn: "/other", current: "no session", error: nil) == "no session")
    }

    @Test func theSessionIDIsNotInUserDefaults() async throws {
        let defaults = try scratchDefaults()
        let cli = FakeOpenAsCLI()
        let store = try makeStore(defaults: defaults)
        _ = await switchTo("priya@example.com", on: store, cli: cli)
        store.pin("priya@example.com", fullName: "Priya Nair", bench: bench, site: site)
        #expect(!String(describing: defaults.dictionaryRepresentation()).contains(cli.sid))
        // pins are a Data blob, whose description is only a byte count: read it as text too
        let pinsText = (defaults.data(forKey: OpenAsStore.pinsKey)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        #expect(!pinsText.isEmpty && !pinsText.contains(cli.sid))
    }

    // MARK: pins and recents

    @Test func pinsRoundTripThroughUserDefaultsAndTheTenthIsRefused() throws {
        let defaults = try scratchDefaults()
        let first = try makeStore(defaults: defaults)
        for number in 1...9 { #expect(first.pin("user\(number)@x.com", fullName: nil, bench: bench, site: site)) }
        #expect(!first.pin("user10@x.com", fullName: nil, bench: bench, site: site))
        first.setLabel("NE Pune", for: "user2@x.com", bench: bench, site: site)
        first.setLabel("   ", for: "user3@x.com", bench: bench, site: site)
        let second = try makeStore(defaults: defaults)
        let pins = second.pins(bench: bench, site: site)
        #expect(pins.count == 9 && pins[1] == PinnedUser(user: "user2@x.com", label: "NE Pune"))
        #expect(pins[2].label == nil)
        #expect(second.pins(bench: bench, site: "other").isEmpty)
        second.unpin("user2@x.com", bench: bench, site: site)
        #expect(!second.isPinned("user2@x.com", bench: bench, site: site))
    }

    @Test func administratorCannotBePinnedAndAnEmptyLabelClears() throws {
        let store = try makeStore()
        #expect(!store.pin(OpenAsStore.administrator, fullName: nil, bench: bench, site: site))
        store.pin("a@x.com", fullName: nil, bench: bench, site: site)
        store.setLabel("CS", for: "a@x.com", bench: bench, site: site)
        store.setLabel("  ", for: "a@x.com", bench: bench, site: site)
        #expect(store.pins(bench: bench, site: site).first?.label == nil)
    }

    @Test func recentsKeepTwoNewestFirstAndSwitchBackIsThePreviousOne() async throws {
        let cli = FakeOpenAsCLI()
        let store = try makeStore()
        _ = await switchTo("a@x.com", on: store, cli: cli)
        _ = await switchTo("b@x.com", on: store, cli: cli)
        _ = await switchTo("c@x.com", on: store, cli: cli)
        let recents = store.recents(bench: bench, site: site)
        #expect(recents.map(\.user) == ["c@x.com", "b@x.com"])
        guard case .switchBack(let user, _)? = OpenAsMenuModel.items(pins: [], recents: recents).first else {
            Issue.record("expected Switch Back first")
            return
        }
        #expect(user == "b@x.com")
        _ = await switchTo(user, on: store, cli: cli)
        #expect(store.recents(bench: bench, site: site).map(\.user) == ["b@x.com", "c@x.com"])
        _ = await switchTo("b@x.com", on: store, cli: cli)
        #expect(store.recents(bench: bench, site: site).map(\.user) == ["b@x.com", "c@x.com"])
    }

    @Test func theRowSubtitleNamesTheCurrentUserByLabelThenFullNameThenID() async throws {
        let cli = FakeOpenAsCLI()
        let store = try makeStore()
        #expect(store.currentLabel(bench: bench, site: site) == nil)
        _ = await switchTo("priya@example.com", on: store, cli: cli)
        #expect(store.currentLabel(bench: bench, site: site) == "Priya Nair")
        store.pin("priya@example.com", fullName: "Priya Nair", bench: bench, site: site)
        store.setLabel("NE", for: "priya@example.com", bench: bench, site: site)
        #expect(store.currentLabel(bench: bench, site: site) == "NE")
        cli.fullName = nil
        _ = await switchTo("raw@example.com", on: store, cli: cli)
        #expect(store.currentLabel(bench: bench, site: site) == "raw@example.com")
        #expect(store.currentLabel(bench: bench, site: "other") == nil)
    }

    // MARK: the menu

    @Test func theMenuIsInTheDocumentedOrder() {
        let pins = [PinnedUser(user: "rahul@x.com", label: "CS", fullName: "Rahul Sharma"),
                    PinnedUser(user: "priya@x.com", label: nil, fullName: "Priya Nair"),
                    PinnedUser(user: "arun@x.com", label: nil, fullName: nil)]
        let recents = [RecentUser(user: "arun@x.com", fullName: nil), RecentUser(user: "priya@x.com", fullName: "Priya Nair")]
        #expect(OpenAsMenuModel.items(pins: pins, recents: recents) == [
            .switchBack(user: "priya@x.com", title: "Switch Back to Priya Nair"),
            .divider(1),
            .pin(user: "rahul@x.com", title: "CS (rahul@x.com)", fullName: "Rahul Sharma"),
            .pin(user: "priya@x.com", title: "Priya Nair (priya@x.com)", fullName: "Priya Nair"),
            .pin(user: "arun@x.com", title: "arun@x.com", fullName: nil),
            .administrator,
            .divider(2),
            .findUser,
        ])
    }

    @Test func withNoPinsTheMenuSaysHowToPin() {
        #expect(OpenAsMenuModel.noPinsHint == "Pin people from Find User… to switch to them here")
        let items = OpenAsMenuModel.items(pins: [], recents: [])
        #expect(items == [.administrator, .pinHint, .divider(2), .findUser])
        let pinned = OpenAsMenuModel.items(pins: [PinnedUser(user: "a@x.com", label: nil)], recents: [])
        #expect(!pinned.contains(.pinHint))
    }

    @Test func switchBackAndItsDividerAreHiddenWithoutAPreviousUser() {
        #expect(OpenAsMenuModel.items(pins: [], recents: []).first == .administrator)
        let one = [RecentUser(user: "a@x.com", fullName: nil)]
        #expect(OpenAsMenuModel.items(pins: [], recents: one).first == .administrator)
    }

    @Test func labelsFallBackFromPinLabelToFullNameToUserID() {
        let pins = [PinnedUser(user: "a@x.com", label: "NE"), PinnedUser(user: "b@x.com", label: " ")]
        #expect(OpenAsMenuModel.label(for: "a@x.com", fullName: "Anita", pins: pins) == "NE")
        #expect(OpenAsMenuModel.label(for: "b@x.com", fullName: "Bala", pins: pins) == "Bala")
        #expect(OpenAsMenuModel.label(for: "b@x.com", fullName: nil, pins: pins) == "b@x.com")
        #expect(OpenAsMenuModel.label(for: "c@x.com", fullName: "", pins: []) == "c@x.com")
    }

    @Test func aPinnedAdministratorIsNotListedTwice() {
        let items = OpenAsMenuModel.items(pins: [PinnedUser(user: OpenAsStore.administrator, label: nil)], recents: [])
        #expect(items.filter { $0 == .administrator }.count == 1)
        #expect(!items.contains { if case .pin = $0 { true } else { false } })
    }

    // MARK: the browser

    @Test func theTestingBrowserIsTheLastOneUsedElseTheFirstRunningSupportedOne() {
        let chrome = "com.google.Chrome"
        let running: Set = [chrome, BrowserRouter.firefox, "com.apple.finder"]
        #expect(BrowserRouter.browser(testing: BrowserRouter.firefox, running: running) == BrowserRouter.firefox)
        #expect(BrowserRouter.browser(testing: nil, running: running) == chrome)
        #expect(BrowserRouter.browser(testing: BrowserRouter.safari, running: running) == chrome, "the tested one has quit")
        #expect(BrowserRouter.browser(testing: nil, running: ["com.apple.finder"]) == nil)
        #expect(BrowserRouter.browser(testing: nil, running: [BrowserRouter.firefox, BrowserRouter.safari]) == BrowserRouter.safari)
        // the default browser wins over another one left running in the background
        #expect(BrowserRouter.browser(testing: nil, running: [chrome, BrowserRouter.safari], defaultBrowser: chrome) == chrome)
        #expect(BrowserRouter.browser(testing: nil, running: [BrowserRouter.safari], defaultBrowser: chrome) == BrowserRouter.safari)
    }

    @Test func onlyTheSupportedBrowsersAreTracked() {
        for id in ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac", "org.mozilla.firefox"] {
            #expect(BrowserRouter.supportedID(id) == id)
        }
        #expect(BrowserRouter.supportedID("com.apple.finder") == nil)
    }

    // MARK: the opt-in

    func optedIn(_ name: String = "macdev", isDefault: Bool = true, developerMode: Bool = true, openAs: Bool? = true) -> SiteRow {
        SiteRow(name: name, isDefault: isDefault, url: "http://\(name):8000", needsHosts: false,
                developerMode: developerMode, openAsEnabled: true, openAs: openAs)
    }

    @Test func siteInfoDecodesTheOptInAndAnOlderCLIGivesNil() throws {
        let sent = #"{"name":"m","default":true,"hosts_entry":true,"ping_code":null,"developer_mode":true,"open_as_enabled":true,"open_as":false}"#
        let info = try JSONDecoder().decode(SiteInfo.self, from: Data(sent.utf8))
        #expect(info.openAsEnabled == true && info.openAs == false)
        let old = try JSONDecoder().decode(SiteInfo.self, from: Data(#"{"name":"m","default":true,"hosts_entry":true,"ping_code":null}"#.utf8))
        #expect(old.openAsEnabled == nil && old.openAs == nil)
        #expect(SiteRow.make(sites: [info], defaultSite: "m", port: 8000).first?.openAsEnabled == true)
    }

    @Test func theMenuShowsOnlyWhereTheCLISaysOpenAsWorks() {
        #expect(OpenAsMenuModel.availability(optedIn(), benchRunning: true, benchName: "b") == .available)
        #expect(OpenAsMenuModel.availability(optedIn(), benchRunning: false, benchName: "frappe-bench") == .disabled("Start frappe-bench first"))
        var off = optedIn()
        off.openAsEnabled = false
        #expect(OpenAsMenuModel.availability(off, benchRunning: true, benchName: "b") == .hidden)
        off.openAsEnabled = nil
        #expect(OpenAsMenuModel.availability(off, benchRunning: true, benchName: "b") == .hidden, "an older CLI")
        var hosts = optedIn()
        hosts.needsHosts = true
        #expect(OpenAsMenuModel.availability(hosts, benchRunning: true, benchName: "b") == .hidden)
    }

    @Test func anOptedInDefaultSiteThatCannotBeUsedIsDisabledWithTheReason() {
        let production = optedIn(developerMode: false, openAs: false)
        guard case .disabled(let reason) = OpenAsMenuModel.availability(production, benchRunning: true, benchName: "b") else {
            Issue.record("expected a disabled control")
            return
        }
        #expect(reason == "macdev is not in developer mode. Run: bench --site macdev set-config developer_mode 1")
        let elsewhere = optedIn(openAs: false)
        #expect(OpenAsMenuModel.availability(elsewhere, benchRunning: true, benchName: "b")
                == .disabled("The web process answers as another site. Run: benchbar site default macdev, then benchrestart"))
    }

    @Test func anOptedInSiteThatIsNotTheDefaultHasNoMenuAndTheSitesTabSaysWhy() {
        let second = optedIn("second", isDefault: false, openAs: false)
        #expect(OpenAsMenuModel.availability(second, benchRunning: true, benchName: "b") == .hidden)
        let line = OpenAsMenuModel.statusLine(second)
        #expect(line?.warning == true)
        #expect(line?.text == "Open as is on, but not usable. Only the default site can be used: port 8000 serves only it")
        let both = OpenAsMenuModel.statusLine(optedIn("second", isDefault: false, developerMode: false, openAs: false))
        #expect(both?.text.contains("set-config developer_mode 1") == true && both?.text.contains("Only the default site") == true)
        // the CLI's open_as wins over BenchBar's default flag, which a hand-run `bench use` leaves behind
        #expect(OpenAsMenuModel.availability(optedIn("second", isDefault: false, openAs: true), benchRunning: true, benchName: "b") == .available)
    }

    @Test func theStatusLineIsAbsentWhileOpenAsIsOffAndPlainWhileItWorks() {
        var off = optedIn()
        off.openAsEnabled = false
        #expect(OpenAsMenuModel.statusLine(off) == nil)
        #expect(OpenAsMenuModel.statusLine(optedIn())?.text == "Open as is on")
        #expect(OpenAsMenuModel.statusLine(optedIn())?.warning == false)
    }

    @Test func theAlertSaysWhatASignInDoes() {
        let text = OpenAsMenuModel.allowMessage
        for part in ["without a password", "on_login and on_session_creation hooks", "Activity Log", "System Managers", "last_login", "oldest session", "development sites only"] {
            #expect(text.contains(part), "\(part)")
        }
    }

    @Test func setOpenAsRunsTheCLIWithYesAndNeverInheritsNonInteractive() async throws {
        let runner = FakeRunner { _ in .ok("") }
        let client = CLIClient(executable: URL(fileURLWithPath: "/bin/benchbar"), runner: runner)
        try await client.setOpenAs(true, site: "macdev", bench: bench)
        try await client.setOpenAs(false, site: "macdev", bench: bench)
        let calls = runner.calls
        #expect(calls[0].arguments == ["site", "open-as", "on", "macdev", "--yes", "--plain", "--bench-dir", bench])
        #expect(calls[1].arguments == ["site", "open-as", "off", "macdev", "--plain", "--bench-dir", bench])
        #expect(calls.allSatisfy { $0.environment["BENCHBAR_NONINTERACTIVE"] == "0" })
        #expect(calls.allSatisfy { $0.environment["BENCHBAR_SUDO"] == "gui" })
    }

    @Test func pinsOfGoneBenchesAndSitesArePruned() throws {
        let defaults = try scratchDefaults()
        let store = try makeStore(defaults: defaults)
        store.pin("a@x.com", fullName: nil, bench: bench, site: "macdev")
        store.pin("b@x.com", fullName: nil, bench: bench, site: "second")
        store.pin("c@x.com", fullName: nil, bench: "/gone", site: "macdev")
        store.pin("d@x.com", fullName: nil, bench: "/unknown", site: "macdev")
        store.prune(keeping: [bench: ["macdev"], "/unknown": nil])
        #expect(store.pins(bench: bench, site: "macdev").count == 1)
        #expect(store.pins(bench: bench, site: "second").isEmpty, "the site was dropped")
        #expect(store.pins(bench: "/gone", site: "macdev").isEmpty, "the bench is gone")
        #expect(store.pins(bench: "/unknown", site: "macdev").count == 1, "sites not known now: pins stay")
        #expect(try makeStore(defaults: defaults).pins(bench: "/gone", site: "macdev").isEmpty, "saved")
    }

    @Test func noDashesAppearInAPinTitle() {
        let items = OpenAsMenuModel.items(pins: [PinnedUser(user: "r@x.com", label: "CS")], recents: [])
        #expect(items.contains(.pin(user: "r@x.com", title: "CS (r@x.com)", fullName: nil)))
    }

    // MARK: the session check

    @Test func theSessionCheckReadsTheUserFromTheAnswer() {
        let ok = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"message\":\"priya@example.com\"}".utf8)
        #expect(SessionProbe.user(inResponse: ok) == "priya@example.com")
        let chunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1e\r\n{\"message\":\"Guest\"}\r\n0\r\n\r\n".utf8)
        #expect(SessionProbe.user(inResponse: chunked) == "Guest")
        #expect(SessionProbe.user(inResponse: Data("HTTP/1.1 403 FORBIDDEN\r\n\r\n{\"message\":\"x\"}".utf8)) == nil)
        #expect(SessionProbe.user(inResponse: Data()) == nil)
        #expect(SessionProbe.user(inResponse: Data("HTTP/1.1 200 OK\r\n\r\nnot json".utf8)) == nil)
    }

    @Test func theSessionCheckSendsTheCookieToTheSiteAndRefusesAnOddID() throws {
        let request = try #require(SessionProbe.request(site: "macdev", sessionID: "abc123"))
        #expect(request.hasPrefix("GET /api/method/frappe.auth.get_logged_user HTTP/1.1\r\nHost: macdev\r\nCookie: sid=abc123\r\n"))
        #expect(SessionProbe.request(site: "macdev", sessionID: "abc\r\nX-Evil: 1") == nil)
        #expect(SessionProbe.request(site: "macdev", sessionID: "") == nil)
        #expect(SessionProbe.request(site: "mac dev", sessionID: "abc") == nil)
    }
}
