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

    func sharePeople(bench: String) async throws(CLIError) -> SharePeople {
        lock.withLock { SharePeople(state: .on, people: people) }
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

    func shareSetup(bench: String, request: ShareSetupRequest, onStep: @escaping @Sendable (String) -> Void) async throws(CLIError) { try record("setup") }
    func shareStart(bench: String, forHours hours: Int, label: String?) async throws(CLIError) { try record("start \(hours)") }
    func shareStop(bench: String) async throws(CLIError) { try record("stop") }
    func shareExtend(bench: String, byMinutes minutes: Int) async throws(CLIError) { try record("extend \(minutes)") }
    func shareLock(bench: String, locked: Bool) async throws(CLIError) { try record(locked ? "lock" : "unlock") }
    func shareRemove(bench: String, person: String, newCode: Bool) async throws(CLIError) { try record("remove \(person) \(newCode)") }
    func shareAssign(bench: String, person: String, seat: String) async throws(CLIError) { try record("assign \(person) \(seat)") }
    func shareOpenAs(bench: String, user: String) async throws(CLIError) { try record("open-as \(user)") }
    func shareTeardown(bench: String) async throws(CLIError) { try record("teardown") }
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

    @Test func olderProtocolNeedsNewerCLI() async throws {
        let old = try BenchJSON.decode(ShareStatus.self, from: Fixture.data("share-status-old"))
        let store = ShareStore(bench: "/b", client: FakeShareCLI([old]), log: { _ in })
        await store.refresh()
        #expect(store.availability == .needsNewerCLI)
    }

    @Test func pollsEveryFiveSecondsAndStopsWhenIdle() async {
        let fake = FakeShareCLI([on(), on(), on(), ShareStatus(state: .off)])
        let slept = SleepLog()
        let store = ShareStore(bench: "/b", client: fake, sleeper: { slept.add($0); await Task.yield() }, log: { _ in })
        await store.refresh()
        store.ensurePolling()
        await store.pollTask?.value
        #expect(fake.statusCalls.count == 4)
        #expect(slept.values == [.seconds(5), .seconds(5)])
        #expect(store.pollTask == nil)
        #expect(!store.shouldPoll)
    }

    @Test func checksRunEveryMinuteAndAfterANetworkChange() async {
        var now = Date(timeIntervalSince1970: 1_000)
        let fake = FakeShareCLI([on()])
        let store = ShareStore(bench: "/b", client: fake, clock: { now }, log: { _ in })
        await store.refresh()
        now += 5
        await store.refresh()
        now += 56
        await store.refresh()
        store.networkChanged()
        store.pollTask?.cancel()
        await store.refresh()
        #expect(fake.statusCalls.prefix(4) == [true, false, true, true])
    }

    @Test func aWrongCallSurfacesTheCLIMessageVerbatim() async {
        let fake = FakeShareCLI([on()])
        fake.actionFailure = .failed(command: "share", exitCode: 1, message: "d_00000000 is not in the room.")
        let store = ShareStore(bench: "/b", client: fake, log: { _ in })
        var benchError: String?
        store.onError = { benchError = $0 }
        let ok = await store.remove(SharePerson(id: "d_00000000", name: "Sam"), newCode: false)
        #expect(!ok)
        #expect(store.lastError == "d_00000000 is not in the room.")
        #expect(benchError == "d_00000000 is not in the room.")
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

    @Test func theCodeIsReadAsAPersonAndAFailedReadRepeatsNothing() async throws {
        let (good, runner) = client(try Fixture.string("share-code"))
        let code = try await good.shareCode(bench: "/b", new: true)
        #expect(code.code == "482913")
        #expect(runner.calls[0].arguments == ["share", "code", "--new", "--json", "--bench-dir", "/b"])
        #expect(runner.calls[0].environment["BENCHBAR_NONINTERACTIVE"] == "0")
        #expect(runner.calls[0].environment["BENCHBAR_SUDO"] == nil)

        let (bad, _) = client(#"{"schema_version":1,"code":482913}"#)
        do {
            _ = try await bad.shareCode(bench: "/b", new: false)
            Issue.record("expected a decoding failure")
        } catch {
            #expect(error == .invalidJSON(detail: "share code", preview: ""))
        }
    }

    @Test func personCallsSayTheyComeFromTheAppAndOthersDoNot() async throws {
        let (cli, runner) = client()
        try await cli.shareStart(bench: "/b", forHours: 4, label: nil)
        try await cli.shareTeardown(bench: "/b")
        try await cli.shareStop(bench: "/b")
        try await cli.shareRemove(bench: "/b", person: "d_0a1b2c3d", newCode: true)
        #expect(runner.calls[0].arguments == ["share", "start", "--for", "4h", "--plain", "--bench-dir", "/b"])
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
