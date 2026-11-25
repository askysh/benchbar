import Foundation
import Testing
@testable import BenchBar

/// The share CLI, answered from a queue of statuses and fixtures.
nonisolated final class FakeShareCLI: ShareCLI, @unchecked Sendable {
    private let lock = NSLock()
    private var _statuses: [ShareStatus]
    private var _statusCalls: [Bool] = []
    private var _calls: [String] = []
    var statusFailure: CLIError?
    var actionFailure: CLIError?
    var code = "482913"
    var people: [SharePerson] = []

    init(_ statuses: [ShareStatus]) { _statuses = statuses }

    var statusCalls: [Bool] { lock.withLock { _statusCalls } }
    var calls: [String] { lock.withLock { _calls } }
    func setPeople(_ list: [SharePerson]) { lock.withLock { people = list } }
    private var seats: [ShareSeat] = []
    private var seatMode: ShareSeatMode?
    func setSeats(_ list: [ShareSeat], mode: ShareSeatMode?) { lock.withLock { seats = list; seatMode = mode } }

    private func record(_ call: String) throws(CLIError) {
        lock.withLock { _calls.append(call) }
        if let actionFailure { throw actionFailure }
    }

    func shareStatus(bench: String, preflight: Bool) async throws(CLIError) -> ShareStatus {
        if let statusFailure { throw statusFailure }
        return lock.withLock {
            _statusCalls.append(preflight)
            return _statuses.count > 1 ? _statuses.removeFirst() : _statuses[0]
        }
    }

    func shareCode(bench: String, new: Bool) async throws(CLIError) -> ShareCode {
        try record(new ? "code --new" : "code")
        return ShareCode(code: code, isNew: new, budgetLeft: 10)
    }

    func shareInvite(bench: String, installURL: String?) async throws(CLIError) -> ShareInviteMessage {
        try record(installURL.map { "invite \($0)" } ?? "invite")
        return ShareInviteMessage(text: "Join my BenchBar room \"Standup\"\nbenchbar://share/join?v=1&c=\(code)", url: "benchbar://share/join?v=1&c=\(code)",
                                  expiresAt: Date(timeIntervalSince1970: 1_800_003_600), room: "Standup")
    }

    func sharePeople(bench: String) async throws(CLIError) -> SharePeople {
        lock.withLock { SharePeople(state: .on, people: people, seats: seats, seatMode: seatMode) }
    }

    func shareUsers(bench: String, site: String) async throws(CLIError) -> ShareUsers {
        try BenchJSON.decode(ShareUsers.self, from: Data(#"{"schema_version":1,"site":"s","users":[],"truncated":false}"#.utf8))
    }

    func shareLog(bench: String, device: String?, since: String?, limit: Int) async throws(CLIError) -> ShareLog {
        try BenchJSON.decode(ShareLog.self, from: Data(#"{"schema_version":1,"entries":[],"truncated":false}"#.utf8))
    }

    func shareSetupPlan(bench: String, request: ShareSetupRequest) async throws(CLIError) -> ShareSetupPlan {
        try BenchJSON.decode(ShareSetupPlan.self, from: Data(#"{"schema_version":1,"site":"s","size_gb":1.5,"est_minutes":4}"#.utf8))
    }

    /// While true, setup and teardown wait inside the call (`inCall` says one is there).
    private var _hold = false
    private var _inCall = false
    var hold: Bool {
        get { lock.withLock { _hold } }
        set { lock.withLock { _hold = newValue } }
    }
    var inCall: Bool { lock.withLock { _inCall } }

    private func held(_ call: String) async throws(CLIError) {
        lock.withLock { _inCall = true }
        while hold { try? await Task.sleep(for: .milliseconds(5)) }
        lock.withLock { _inCall = false }
        try record(call)
    }

    func shareSetup(bench: String, request: ShareSetupRequest, onStep: @escaping @Sendable (String) -> Void) async throws(CLIError) { try await held("setup") }
    func shareStart(bench: String, forHours hours: Int, label: String?, assignSeats: Bool?) async throws(CLIError) {
        try record(assignSeats.map { $0 ? "start \(hours) assign-seats" : "start \(hours) open-seats" } ?? "start \(hours)")
    }
    func shareStop(bench: String) async throws(CLIError) { try record("stop") }
    func shareExtend(bench: String, byMinutes minutes: Int) async throws(CLIError) { try record("extend \(minutes)") }
    func shareLock(bench: String, locked: Bool) async throws(CLIError) { try record(locked ? "lock" : "unlock") }
    func shareRemove(bench: String, person: String, newCode: Bool) async throws(CLIError) { try record("remove \(person) \(newCode)") }
    func shareAssign(bench: String, person: String, seat: String) async throws(CLIError) { try record("assign \(person) \(seat)") }
    func shareOpenAs(bench: String, user: String) async throws(CLIError) { try record("open-as \(user)") }
    func shareTeardown(bench: String) async throws(CLIError) { try await held("teardown") }
    func lanGuardInstall() async throws(CLIError) { try record("lan-guard install") }
    func lanGuardAllowNode() async throws(CLIError) { try record("lan-guard allow-node") }
}

/// Captures what the store would write to the log.
final class LogSink {
    var lines: [String] = []
}

private func on(secondsLeft: Int = 3600, people: Int = 0, online: Int = 0, lockReason: ShareLockReason? = nil,
                joinTrouble: Bool = false) -> ShareStatus {
    ShareStatus(state: .on, secondsLeft: secondsLeft, canExtendS: 3600, seats: 2, people: people, devicesOnline: online,
                locked: lockReason != nil, lockReason: lockReason, budgetLeft: lockReason == .budget ? 0 : 10, joinTrouble: joinTrouble)
}

@Suite("Share models")
struct ShareModelsTests {
    @Test func statusFixtureDecodes() throws {
        let status = try BenchJSON.decode(ShareStatus.self, from: Fixture.data("share-status"))
        #expect(status.state == .on)
        #expect(status.protocolVersion == 3)
        #expect(!status.needsNewerCLI)
        #expect(status.label == "Priya's room")
        #expect(status.lanIP == "192.168.1.20")
        #expect(status.secondsLeft == 3540)
        #expect(status.copy?.drifted == true)
        #expect(status.copy?.apps.first?.atCopy?.hasPrefix("aaaa") == true)
        #expect(status.allowedUsers == ["priya@example.com", "sam@example.com"])
        #expect(status.budgetLeft == 10)
        #expect(status.lockReason == nil)
        #expect(status.lanGuard == .installed)
        #expect(status.deadline != nil)
        #expect(status.preflight?.checks.count == 3)
        #expect(status.preflight?.checks[1].fixAction == .openLocalNetworkSettings)
    }

    @Test func setupInterruptedIsDecodedAndOffersFinishSetup() throws {
        let plain = try BenchJSON.decode(ShareStatus.self, from: Fixture.data("share-status"))
        #expect(!plain.setupInterrupted)
        let halfway = try BenchJSON.decode(ShareStatus.self, from: Fixture.data("share-status-interrupted"))
        #expect(halfway.setupInterrupted)
        #expect(halfway.state == .off && halfway.copy == nil)
        #expect(SharePrimary.from(halfway) == .finishSetup)
        #expect(SharePrimary.finishSetup.title == "Finish setup")
        // an older CLI without the key reads as not interrupted
        #expect(try BenchJSON.decode(ShareStatus.self, from: Fixture.data("share-status-old")).setupInterrupted == false)
        // a copy that is still there does not hide the notice
        #expect(SharePrimary.from(ShareStatus(state: .off, copy: ShareCopy(made: "2026-11-03T08:40:00Z", sourceSite: "s", ageS: 1), setupInterrupted: true)) == .finishSetup)
    }

    @Test func theRoomCodeIsDotsUntilShown() {
        let code = ShareCode(code: "482913", isNew: false, budgetLeft: nil)
        #expect(SharePresentation.codeText(code, revealed: false) == "••• •••")
        #expect(SharePresentation.codeText(code, revealed: true) == "482 913")
        #expect(SharePresentation.codeText(nil, revealed: true) == "••• •••")
        #expect(!SharePresentation.codeText(code, revealed: false).contains("482"))
    }

    @Test func unknownFixActionIsNone() throws {
        let status = try BenchJSON.decode(ShareStatus.self, from: Fixture.data("share-status"))
        #expect(status.preflight?.checks[2].fixAction == ShareFixAction.none)
    }

    @Test func olderCLIDecodesWithDefaultsAndAsksForAnUpdate() throws {
        let status = try BenchJSON.decode(ShareStatus.self, from: Fixture.data("share-status-old"))
        #expect(status.needsNewerCLI)
        #expect(status.state == .off)
        #expect(status.copy == nil)
        #expect(status.locked == nil)
        #expect(status.budgetLeft == nil)
        #expect(status.allowedUsers.isEmpty)
        #expect(status.joinTrouble == false)
        #expect(status.lanGuard == .missing)
    }

    @Test func peopleUsersLogAndCodeDecode() throws {
        let people = try BenchJSON.decode(SharePeople.self, from: Fixture.data("share-people"))
        #expect(people.people.map(\.id) == ["d_0a1b2c3d", "d_99887766"])
        #expect(people.people[0].seatFullName == "Sam Rao")
        #expect(people.people[1].seatID == nil)
        #expect(people.people[1].online == false)
        // every seat of the room, held or free, and who gives them out (#159 SHARE-5)
        #expect(people.seats.map(\.id) == ["s_1234abcd", "s_5678efab"])
        #expect(people.seats[0].heldBy == "d_0a1b2c3d" && people.seats[0].heldByName == "Sam")
        #expect(people.seats[1] == ShareSeat(id: "s_5678efab", fullName: "Mgr Singh", roles: ["Sales Manager", "Accounts User"]))
        #expect(people.seatMode == .host)
        // a CLI before 0.9.0 sends neither
        let old = try BenchJSON.decode(SharePeople.self, from: Data(#"{"schema_version":1,"cli_version":"0.8.3","state":"on","people":[]}"#.utf8))
        #expect(old.seats.isEmpty && old.seatMode == nil)
        #expect(try BenchJSON.decode(ShareStatus.self, from: Fixture.data("share-status")).seatMode == .open)
        #expect(try BenchJSON.decode(ShareStatus.self, from: Fixture.data("share-status-old")).seatMode == nil)
        // #159 SHARE-8: the host's key, for the host to read out
        let keyed = try BenchJSON.decode(ShareStatus.self, from: Fixture.data("share-status"))
        #expect(keyed.hostKey == "0123456789abcdef")
        #expect(SharePresentation.hostKeyLine(keyed) == "Host key: 0123 4567 89ab cdef")
        #expect(SharePresentation.hostKeyLine(try BenchJSON.decode(ShareStatus.self, from: Fixture.data("share-status-old"))) == nil)
        #expect(SharePresentation.hostKeyLine(ShareStatus(state: .on, hostKey: "not sixteen hex")) == nil)

        let users = try BenchJSON.decode(ShareUsers.self, from: Fixture.data("share-users"))
        #expect(users.users[0].codeCapableRoles == ["System Manager"])
        #expect(users.users[0].willDemote)
        #expect(users.users.filter(\.selectable).map(\.name) == ["priya@example.com"])

        let log = try BenchJSON.decode(ShareLog.self, from: Fixture.data("share-log"))
        #expect(log.entries.count == 2)
        #expect(log.entries[1].method == "POST")

        let code = try BenchJSON.decode(ShareCode.self, from: Fixture.data("share-code"))
        #expect(code.spaced == "482 913")
    }
}

@Suite("Share store")
@MainActor
struct ShareStoreTests {
    @Test func unknownCommandHidesSharing() async {
        let fake = FakeShareCLI([on()])
        fake.statusFailure = .failed(command: "share", exitCode: 1, message: "Unknown command: share")
        let store = ShareStore(bench: "/b", client: fake, log: { _ in })
        await store.refresh()
        #expect(store.availability == .unavailable)
        #expect(store.lastError == nil)
    }

    /// Quitting while setup or teardown runs stops the CLI halfway, so the app asks first.
    @Test func setupIsInFlightUntilItReturns() async { await inFlightUntilItReturns("setup") }
    @Test func teardownIsInFlightUntilItReturns() async { await inFlightUntilItReturns("teardown") }

    private func inFlightUntilItReturns(_ call: String) async {
        let fake = FakeShareCLI([ShareStatus(state: .off)])
        let store = ShareStore(bench: "/b", client: fake, log: { _ in })
        #expect(!store.stopsHalfwayIfQuit)
        fake.hold = true
        let run = Task { @MainActor in
            if call == "setup" {
                await store.setup(ShareSetupRequest(site: "s", users: ["u"], backupNow: false, refresh: false), onStep: { _ in })
            } else {
                await store.teardown()
            }
        }
        while !fake.inCall { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(store.stopsHalfwayIfQuit)
        fake.hold = false
        await run.value
        #expect(!store.stopsHalfwayIfQuit)
        #expect(fake.calls == [call])
    }

    @Test func otherActionsAreNotInFlightForQuit() async {
        let fake = FakeShareCLI([ShareStatus(state: .off)])
        let store = ShareStore(bench: "/b", client: fake, log: { _ in })
        await store.stop()
        #expect(!store.stopsHalfwayIfQuit)
    }

    @Test func olderProtocolNeedsNewerCLI() async throws {
        let old = try BenchJSON.decode(ShareStatus.self, from: Fixture.data("share-status-old"))
        let store = ShareStore(bench: "/b", client: FakeShareCLI([old]), log: { _ in })
        await store.refresh()
        #expect(store.availability == .needsNewerCLI)
    }

    /// MAC-8: 17,000 process launches a day while a room stays open is too many for a
    /// tab nobody looks at; the notices can wait 15 seconds.
    @Test func pollsEveryFifteenSecondsWhileTheTabIsHiddenAndStopsWhenIdle() async {
        let fake = FakeShareCLI([on(), on(), on(), ShareStatus(state: .off)])
        let slept = SleepLog()
        let store = ShareStore(bench: "/b", client: fake, sleeper: { slept.add($0); await Task.yield() }, log: { _ in })
        await store.refresh()
        store.ensurePolling()
        await store.pollTask?.value
        #expect(fake.statusCalls.count == 4)
        #expect(slept.values == [.seconds(15), .seconds(15)])
        #expect(store.pollTask == nil)
        #expect(!store.shouldPoll)
    }

    @Test func theIntervalFollowsTheTab() {
        let store = ShareStore(bench: "/b", client: FakeShareCLI([ShareStatus(state: .off)]), sleeper: { _ in }, log: { _ in })
        #expect(store.currentPollInterval == .seconds(15))
        store.tabVisible = true
        #expect(store.currentPollInterval == .seconds(5))
        store.shutDown()
    }

    @Test func aStateChangeFromOutsideTheAppRunsTheChecksOnTheNextPoll() async {
        // sharing started in a terminal while the tab was open: the cached "off" checks must not linger a minute
        let now = Date(timeIntervalSince1970: 1_000)
        let fake = FakeShareCLI([ShareStatus(state: .off), on(), on()])
        let store = ShareStore(bench: "/b", client: fake, clock: { now }, log: { _ in })
        await store.refresh()
        await store.refresh()
        await store.refresh()
        #expect(fake.statusCalls.prefix(3) == [true, false, true])
    }

    @Test func checksRunEveryMinuteAndAfterANetworkChange() async {
        var now = Date(timeIntervalSince1970: 1_000)
        let fake = FakeShareCLI([on()])
        let store = ShareStore(bench: "/b", client: fake, clock: { now }, log: { _ in })
        var events: [ShareEvent] = []
        store.onEvent = { events.append($0) }
        await store.refresh()
        now += 5
        await store.refresh()
        now += 56
        await store.refresh()
        store.networkChanged()
        store.pollTask?.cancel()
        await store.refresh()
        #expect(fake.statusCalls.prefix(4) == [true, false, true, true])
        // a path update alone (a VM's bridge, a VPN) is no news: the checks rerun without a banner
        #expect(!events.contains(.networkChanged))
    }

    @Test func aRemovalOffersANewInviteThatLetsThePersonBackIn() async {
        let fake = FakeShareCLI([on()])
        let store = ShareStore(bench: "/b", client: fake, log: { _ in })
        await store.refresh()
        await store.remove(SharePerson(id: "d_1", name: "Alcin"), newCode: false)
        #expect(store.removedName == "Alcin")
        var written: [String] = []
        await store.copyNewInvite { written.append($0) }
        #expect(fake.calls == ["remove d_1 false", "code --new", "invite"])
        #expect(written.count == 1)
        #expect(store.removedName == nil)
        #expect(store.inviteCopied)
        // a removal that also drew a new code has nothing to offer: the new code already lifted it
        await store.remove(SharePerson(id: "d_2", name: "Sam"), newCode: true)
        #expect(store.removedName == nil)
    }

    @Test func copyInviteWritesTheMessageOnceAndLogsNoCode() async {
        let fake = FakeShareCLI([on()])
        let sink = LogSink()
        let store = ShareStore(bench: "/b", client: fake, log: { sink.lines.append($0) })
        var written: [String] = []
        await store.copyInvite { written.append($0) }
        #expect(written.isEmpty)
        #expect(fake.calls.isEmpty)

        await store.refresh()
        await store.copyInvite { written.append($0) }
        #expect(fake.calls == ["invite"])
        #expect(written.count == 1 && written[0].contains("482913"))
        #expect(store.inviteCopied)
        #expect(sink.lines.contains("share: invite copied"))
        #expect(!sink.lines.joined().contains("482913"))
        await store.loadCode(new: true)
        #expect(!store.inviteCopied)
    }

    @Test func aWrongCallSurfacesTheCLIMessageVerbatim() async {
        let fake = FakeShareCLI([on()])
        fake.actionFailure = .failed(command: "share", exitCode: 1, message: "d_00000000 is not in the room.")
        let store = ShareStore(bench: "/b", client: fake, log: { _ in })
        let ok = await store.remove(SharePerson(id: "d_00000000", name: "Sam"), newCode: false)
        #expect(!ok)
        #expect(store.lastError == "d_00000000 is not in the room.")
    }

    @Test func theCodeIsInNoDefaultsKeyNoLogLineAndNoEvent() async throws {
        let suite = "benchbar.share.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fake = FakeShareCLI([on(), on(people: 1, online: 1, lockReason: .budget, joinTrouble: true)])
        fake.setPeople([SharePerson(id: "d_11111111", name: "Sam", model: "MacBook Air", ip: "192.168.1.31")])
        let sink = LogSink()
        var events: [ShareEvent] = []
        let store = ShareStore(bench: "/b", client: fake, log: { sink.lines.append($0) })
        store.onEvent = { events.append($0) }
        await store.refresh()
        await store.loadCode()
        await store.loadCode(new: true)
        await store.refresh()
        await store.loadPeople()
        fake.actionFailure = .failed(command: "share", exitCode: 1, message: "echo 482913 back")
        await store.stop()

        #expect(store.code?.code == "482913")
        #expect(!sink.lines.isEmpty)
        #expect(sink.lines.allSatisfy { !$0.contains("482913") && !$0.contains("482 913") })
        #expect(!"\(events)".contains("482913"))
        #expect(store.lastError?.contains("482913") == false)
        for (_, value) in defaults.dictionaryRepresentation() { #expect(!"\(value)".contains("482913")) }
        for (_, value) in UserDefaults.standard.dictionaryRepresentation() { #expect(!"\(value)".contains("482913")) }
    }

    @Test func seatsSeenHeldAreRememberedUntilSharingStops() async {
        let fake = FakeShareCLI([on(), on(), ShareStatus(state: .off)])
        fake.setPeople([SharePerson(id: "d_1", name: "Sam", seatID: "s_a", seatFullName: "Sam Rao")])
        let store = ShareStore(bench: "/b", client: fake, log: { _ in })
        await store.refresh()
        await store.loadPeople()
        fake.setPeople([])
        await store.refresh()
        await store.loadPeople()
        #expect(store.knownSeats == ["s_a": "Sam Rao"])
        let ok = await store.assign(SharePerson(id: "d_2", name: "Asha"), seat: "s_a")
        #expect(ok)
        #expect(fake.calls.contains("assign d_2 s_a"))
        await store.refresh()
        #expect(store.knownSeats.isEmpty)
    }

    /// #159 SHARE-5: the room's seat list fills the menu before anybody holds a seat, so the first
    /// guest of a room where the host gives out the seats can get one.
    @Test func theSeatListOfTheRoomIsKnownBeforeAnybodyHoldsASeat() async {
        let fake = FakeShareCLI([on(), on(), ShareStatus(state: .off)])
        let asha = SharePerson(id: "d_2", name: "Asha")
        fake.setPeople([asha])
        fake.setSeats([ShareSeat(id: "s_a", fullName: "Sam Rao", roles: ["Sales User"]),
                       ShareSeat(id: "s_b", fullName: "Mgr Singh", roles: ["Sales Manager", "Accounts User"])], mode: .host)
        let store = ShareStore(bench: "/b", client: fake, log: { _ in })
        await store.refresh()
        await store.loadPeople()
        #expect(store.knownSeats == ["s_a": "Sam Rao", "s_b": "Mgr Singh"])
        #expect(store.hostGivesSeats)
        let targets = SharePresentation.moveTargets(for: asha, people: store.people, known: store.knownSeats, seats: store.seats)
        #expect(targets.map(\.id) == ["s_b", "s_a"])
        #expect(targets.map(\.name) == ["Mgr Singh · Sales Manager, Accounts User", "Sam Rao · Sales User"])
        let ok = await store.assign(asha, seat: "s_b")
        #expect(ok && fake.calls.contains("assign d_2 s_b"))
        await store.refresh()
        await store.refresh()
        #expect(store.knownSeats.isEmpty && store.seats.isEmpty && !store.hostGivesSeats)
    }

    @Test func startSaysWhoGivesOutTheSeats() async {
        let fake = FakeShareCLI([ShareStatus(state: .off), on()])
        let store = ShareStore(bench: "/b", client: fake, log: { _ in })
        await store.refresh()
        await store.start(hours: 2, label: nil, assignSeats: true)
        await store.start(hours: 4, label: nil, assignSeats: false)
        #expect(fake.calls.filter { $0.hasPrefix("start") } == ["start 2 assign-seats", "start 4 open-seats"])
    }

    /// A CLI from before the seat flags (its status has no `seat_mode`) refuses them with "Unknown
    /// argument for share start", so none is sent: the room it starts has open seats, as it always had.
    @Test func anOlderCLIIsStartedWithoutASeatFlag() async throws {
        let old = try BenchJSON.decode(ShareStatus.self, from: Fixture.data("share-status-old"))
        #expect(!old.knowsSeatMode)
        #expect(try BenchJSON.decode(ShareStatus.self, from: Fixture.data("share-status")).knowsSeatMode)
        let fake = FakeShareCLI([ShareStatus(state: .off, knowsSeatMode: false)])
        let store = ShareStore(bench: "/b", client: fake, log: { _ in })
        await store.refresh()
        #expect(!store.cliKnowsSeatMode)
        await store.start(hours: 4, label: nil, assignSeats: true)
        #expect(fake.calls.filter { $0.hasPrefix("start") } == ["start 4"])
        // before the first status nothing is known either: no flag
        let unread = FakeShareCLI([ShareStatus(state: .off)])
        await ShareStore(bench: "/b", client: unread, log: { _ in }).start(hours: 4, label: nil, assignSeats: true)
        #expect(unread.calls.filter { $0.hasPrefix("start") } == ["start 4"])
        #expect(SharePresentation.startDetail(site: "s", assignSeats: false).hasSuffix("Each of them can take any free seat."))
    }

    @Test func theCodeIsForgottenWhenSharingStops() async {
        let fake = FakeShareCLI([on(), ShareStatus(state: .off)])
        let store = ShareStore(bench: "/b", client: fake, log: { _ in })
        await store.refresh()
        await store.loadCode()
        #expect(store.code != nil)
        await store.refresh()
        #expect(store.code == nil)
    }
}

@Suite("Share events")
struct ShareEventTrackerTests {
    @Test func theFirstStatusIsRecordedSilently() {
        var tracker = ShareEventTracker()
        #expect(tracker.status(on(secondsLeft: 30, lockReason: .budget, joinTrouble: true)).isEmpty)
        #expect(tracker.status(on(secondsLeft: 25, lockReason: .budget, joinTrouble: true)).isEmpty)
    }

    @Test func onlyANewLANAddressWhileSharingIsANetworkChange() {
        func at(_ ip: String?, _ state: ShareState = .on) -> ShareStatus {
            var status = state == .on ? on() : ShareStatus(state: state)
            status.lanIP = ip
            return status
        }
        var tracker = ShareEventTracker()
        _ = tracker.status(at("192.168.1.20"))
        #expect(tracker.status(at("192.168.1.20")).isEmpty)
        #expect(tracker.status(at("10.0.0.7")) == [.networkChanged])
        #expect(tracker.status(at(nil)) == [.networkChanged])
        #expect(tracker.status(at(nil)).isEmpty)
        _ = tracker.status(at("10.0.0.7", .off))
        #expect(tracker.status(at("10.0.0.9", .off)).isEmpty)
    }

    @Test func remindersFireOnceEachAtTenAndOneMinutes() {
        var tracker = ShareEventTracker()
        var events: [ShareEvent] = []
        for left in [3600, 900, 600, 590, 300, 61, 60, 30, 5] { events += tracker.status(on(secondsLeft: left)) }
        #expect(events == [.reminder(minutes: 10), .reminder(minutes: 1)])
    }

    @Test func aRestartedStoreDoesNotRepeatAReminder() {
        var first = ShareEventTracker()
        _ = first.status(on(secondsLeft: 3600))
        #expect(first.status(on(secondsLeft: 590)) == [.reminder(minutes: 10)])
        var restarted = ShareEventTracker()
        #expect(restarted.status(on(secondsLeft: 580)).isEmpty)
        #expect(restarted.status(on(secondsLeft: 300)).isEmpty)
        #expect(restarted.status(on(secondsLeft: 50)) == [.reminder(minutes: 1)])
    }

    @Test func aBudgetLockAndJoinTroubleEachNotifyOnce() {
        var tracker = ShareEventTracker()
        _ = tracker.status(on())
        #expect(tracker.status(on(lockReason: .budget)) == [.lockedByWrongCodes])
        #expect(tracker.status(on(lockReason: .budget)).isEmpty)
        #expect(tracker.status(on(lockReason: .budget, joinTrouble: true)) == [.joinTrouble])
        #expect(tracker.status(on(lockReason: .budget, joinTrouble: true)).isEmpty)
    }

    @Test func aPersonJoiningOrLeavingNotifiesOnce() {
        var tracker = ShareEventTracker()
        let sam = SharePerson(id: "d_11111111", name: "Sam", model: "MacBook Air", ip: "192.168.1.31")
        let asha = SharePerson(id: "d_22222222", name: "Asha")
        #expect(tracker.people([sam]).isEmpty)
        #expect(tracker.people([sam, asha]) == [.joined(name: "Asha", model: nil, ip: nil)])
        #expect(tracker.people([sam, asha]).isEmpty)
        #expect(tracker.people([asha]) == [.left(name: "Sam")])
    }

    @Test func stateChangesAreEvents() {
        var tracker = ShareEventTracker()
        _ = tracker.status(ShareStatus(state: .off))
        #expect(tracker.status(on()) == [.stateChanged(from: .off, to: .on)])
    }
}

@Suite("Share CLI calls")
struct ShareCLITests {
    private func client(_ stdout: String = "{}") -> (CLIClient, FakeRunner) {
        let runner = FakeRunner { _ throws(CLIError) in .ok(stdout) }
        return (CLIClient(executable: URL(fileURLWithPath: "/usr/local/bin/benchbar"), runner: runner), runner)
    }

    @Test func theCodeIsReadAsAPersonFromTheAppAndAFailedReadRepeatsNothing() async throws {
        let (good, runner) = client(try Fixture.string("share-code"))
        let code = try await good.shareCode(bench: "/b", new: true)
        #expect(code.code == "482913")
        #expect(runner.calls[0].arguments == ["share", "code", "--new", "--json", "--bench-dir", "/b"])
        #expect(runner.calls[0].environment["BENCHBAR_NONINTERACTIVE"] == "0")
        #expect(runner.calls[0].environment["BENCHBAR_SUDO"] == "gui")

        let (bad, _) = client(#"{"schema_version":1,"code":482913}"#)
        do {
            _ = try await bad.shareCode(bench: "/b", new: false)
            Issue.record("expected a decoding failure")
        } catch {
            #expect(error == .invalidJSON(detail: "share code", preview: ""))
        }
    }

    @Test func theInviteIsReadAsAPersonLenientlyAndAFailedReadRepeatsNothing() async throws {
        let json = #"{"schema_version":1,"cli_version":"0.9.0","bench":"/b","share_site":"share.localhost","url":"benchbar://share/join?v=1&c=482913","text":"Join my BenchBar room\nbenchbar://share/join?v=1&c=482913","expires_at":"2027-01-15T08:00:00Z","room":"Standup","wipe":null}"#
        let (good, runner) = client(json)
        let invite = try await good.shareInvite(bench: "/b", installURL: nil)
        #expect(invite.text == "Join my BenchBar room\nbenchbar://share/join?v=1&c=482913")
        #expect(invite.expiresAt == Date(timeIntervalSince1970: 1_800_000_000) && invite.room == "Standup")
        #expect(runner.calls[0].arguments == ["share", "invite", "--json", "--bench-dir", "/b"])
        #expect(runner.calls[0].environment["BENCHBAR_NONINTERACTIVE"] == "0")
        #expect(runner.calls[0].environment["BENCHBAR_SUDO"] == "gui")
        #expect(!"\(invite)".contains("482913"))

        let (install, installRunner) = client(#"{"text":"t","expires_at":1800000000}"#)
        let minimal = try await install.shareInvite(bench: "/b", installURL: "https://example.com/benchbar")
        #expect(minimal == ShareInviteMessage(text: "t"))
        #expect(installRunner.calls[0].arguments == ["share", "invite", "--install-url", "https://example.com/benchbar", "--json", "--bench-dir", "/b"])

        let (bad, _) = client(#"{"url":"benchbar://share/join?v=1&c=482913"}"#)
        do {
            _ = try await bad.shareInvite(bench: "/b", installURL: nil)
            Issue.record("expected a decoding failure")
        } catch {
            #expect(error == .invalidJSON(detail: "share invite", preview: ""))
        }
    }

    @Test func startPassesTheSeatSwitchToTheCLI() async throws {
        let (cli, runner) = client()
        try await cli.shareStart(bench: "/b", forHours: 4, label: nil, assignSeats: true)
        #expect(runner.calls[0].arguments == ["share", "start", "--for", "4h", "--assign-seats", "--plain", "--bench-dir", "/b"])
        // the way back is said out loud too, so the room never depends on the CLI's default
        try await cli.shareStart(bench: "/b", forHours: 4, label: nil, assignSeats: false)
        #expect(runner.calls[1].arguments == ["share", "start", "--for", "4h", "--open-seats", "--plain", "--bench-dir", "/b"])
        try await cli.shareStart(bench: "/b", forHours: 4, label: nil, assignSeats: nil)
        #expect(runner.calls[2].arguments == ["share", "start", "--for", "4h", "--plain", "--bench-dir", "/b"])
        #expect(SharePresentation.assignSeatsDefault)
    }

    @Test func personCallsSayTheyComeFromTheAppAndOthersDoNot() async throws {
        let (cli, runner) = client()
        try await cli.shareStart(bench: "/b", forHours: 4, label: nil, assignSeats: false)
        try await cli.shareTeardown(bench: "/b")
        try await cli.shareStop(bench: "/b")
        try await cli.shareRemove(bench: "/b", person: "d_0a1b2c3d", newCode: true)
        #expect(runner.calls[0].arguments == ["share", "start", "--for", "4h", "--open-seats", "--plain", "--bench-dir", "/b"])
        #expect(runner.calls[0].environment["BENCHBAR_SUDO"] == "gui")
        #expect(runner.calls[1].arguments.contains("--yes"))
        #expect(runner.calls[1].environment["BENCHBAR_SUDO"] == "gui")
        #expect(runner.calls[2].environment["BENCHBAR_SUDO"] == nil)
        #expect(runner.calls[3].arguments == ["share", "remove", "d_0a1b2c3d", "--yes", "--new-code", "--plain", "--bench-dir", "/b"])
        #expect(runner.calls[3].environment["BENCHBAR_SUDO"] == nil)
    }
}

nonisolated final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Duration] = []
    var values: [Duration] { lock.withLock { _values } }
    func add(_ value: Duration) { lock.withLock { _values.append(value) } }
}
