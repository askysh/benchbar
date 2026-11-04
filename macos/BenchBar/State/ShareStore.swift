import Foundation
import Observation
import os

/// What happened in the room, for notifications and the menu bar. No case
/// can carry the room code, so nothing built from an event can leak it.
nonisolated enum ShareEvent: Equatable, Sendable {
    case joined(name: String, model: String?, ip: String?)
    case left(name: String)
    /// The failure budget ran out (lock_reason "budget").
    case lockedByWrongCodes
    /// status.join_trouble turned true.
    case joinTrouble
    /// The share ends in `minutes` (10, then 1).
    case reminder(minutes: Int)
    case stateChanged(from: ShareState, to: ShareState)
    /// Wake or a network change while sharing: the checks run again.
    case networkChanged
}

/// Whether this bench's CLI can share at all.
nonisolated enum ShareAvailability: Equatable, Sendable {
    case unknown
    case available
    /// The CLI has no `share` command: the Sharing tab hides itself.
    case unavailable
    /// The CLI speaks an older share protocol than rooms need.
    case needsNewerCLI
}

/// The pure part of the store's event logic: what a new status (and people
/// list) means compared with the last one. The first status a store sees is
/// recorded without events, so an app relaunch never repeats "joined" or a
/// reminder that already fired.
nonisolated struct ShareEventTracker: Sendable, Equatable {
    static let reminderMinutes = [10, 1]

    private(set) var seeded = false
    private var state: ShareState = .off
    private var lockReason: ShareLockReason?
    private var joinTrouble = false
    private var firedReminders: Set<Int> = []
    private var peopleByID: [String: String] = [:]
    private var peopleSeeded = false

    mutating func status(_ status: ShareStatus) -> [ShareEvent] {
        var events: [ShareEvent] = []
        let due = Self.reminderMinutes.filter { status.isOn && status.secondsLeft > 0 && status.secondsLeft <= $0 * 60 }
        if status.state != .on { firedReminders = [] }
        defer {
            state = status.state
            lockReason = status.lockReason
            joinTrouble = status.joinTrouble
            if !status.isOn { peopleByID = [:] }
        }
        guard seeded else {
            seeded = true
            firedReminders.formUnion(due)
            return []
        }
        if status.state != state { events.append(.stateChanged(from: state, to: status.state)) }
        if status.isOn {
            if status.lockReason == .budget && lockReason != .budget { events.append(.lockedByWrongCodes) }
            if status.joinTrouble && !joinTrouble { events.append(.joinTrouble) }
            // the smallest threshold reached is the one worth saying; the larger ones are spent with it
            if let minutes = due.filter({ !firedReminders.contains($0) }).min() { events.append(.reminder(minutes: minutes)) }
            firedReminders.formUnion(due)
        }
        return events
    }

    mutating func people(_ people: [SharePerson]) -> [ShareEvent] {
        let now = Dictionary(people.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        defer { peopleByID = now; peopleSeeded = true }
        guard peopleSeeded else { return [] }
        let joined = people.filter { peopleByID[$0.id] == nil }.map { ShareEvent.joined(name: $0.name, model: $0.model, ip: $0.ip) }
        let left = peopleByID.filter { now[$0.key] == nil }.sorted { $0.key < $1.key }.map { ShareEvent.left(name: $0.value) }
        return joined + left
    }
}

/// The host side of sharing for one bench: the room's status, its people,
/// the code (in memory only), and the actions, all through the CLI.
///
/// The room code lives in `code` and nowhere else: not in UserDefaults, not
/// in a log line, not in an event or a notification. It is fetched while
/// sharing is on and the Sharing tab or the menu shows it, and forgotten
/// when sharing stops.
@Observable
final class ShareStore {
    nonisolated static let pollInterval: Duration = .seconds(5)
    nonisolated static let preflightInterval: TimeInterval = 60

    let bench: String
    private(set) var status: ShareStatus?
    private(set) var availability: ShareAvailability = .unknown
    private(set) var people: [SharePerson] = []
    private(set) var users: [ShareUser] = []
    private(set) var log: [ShareLogEntry] = []
    private(set) var code: ShareCode?
    /// Seats seen held in this room (id → full name). The CLI lists only the
    /// seats people hold, so a free seat is one seen earlier that nobody holds now.
    private(set) var knownSeats: [String: String] = [:]
    private(set) var busy: String?
    /// Setup or teardown calls the CLI is running: quitting now stops one
    /// halfway, and the copy needs setup again.
    private(set) var setupOrTeardownCalls = 0
    var stopsHalfwayIfQuit: Bool { setupOrTeardownCalls > 0 }
    private(set) var lastError: String?
    /// Set after Copy invite put the message on the pasteboard.
    private(set) var inviteCopied = false
    /// The Sharing tab is on screen: poll even while sharing is off.
    var tabVisible = false {
        didSet { if tabVisible && !oldValue { forcePreflight = true; ensurePolling() } }
    }

    @ObservationIgnored var onEvent: ((ShareEvent) -> Void)?
    /// Every status read, for the menu bar and the popover.
    @ObservationIgnored var onStatus: (() -> Void)?
    /// Errors also land on the bench (`BenchModel.lastError`), like Open as.
    @ObservationIgnored var onError: ((String) -> Void)?
    @ObservationIgnored private let client: any ShareCLI
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let sleeper: @Sendable (Duration) async -> Void
    @ObservationIgnored private let logLine: (String) -> Void
    @ObservationIgnored private var tracker = ShareEventTracker()
    @ObservationIgnored private var lastPreflight: Date?
    @ObservationIgnored private var forcePreflight = false
    @ObservationIgnored private(set) var pollTask: Task<Void, Never>?

    init(bench: String, client: any ShareCLI, clock: @escaping () -> Date = Date.init,
         sleeper: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
         log: @escaping (String) -> Void = ShareStore.defaultLog) {
        self.bench = bench
        self.client = client
        self.clock = clock
        self.sleeper = sleeper
        logLine = log
    }

    private nonisolated static let logger: Logger = {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return Logger(.disabled) }
        return Logger(subsystem: "com.akashmishra.benchbar", category: "share")
    }()

    nonisolated static func defaultLog(_ line: String) {
        logger.info("\(line, privacy: .public)")
    }

    var isSharing: Bool { status?.isOn == true }
    var shouldPoll: Bool { tabVisible || status?.state == .on || status?.state == .starting }

    // MARK: polling

    /// Starts the poll loop unless it runs; it ends by itself once nothing
    /// needs it (sharing off and the tab hidden).
    func ensurePolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                guard self.shouldPoll else { break }
                await self.sleeper(Self.pollInterval)
            }
            self?.pollTask = nil
        }
    }

    /// Wake or a network change: the checks run on the next poll.
    func networkChanged() {
        forcePreflight = true
        if isSharing { onEvent?(.networkChanged) }
        ensurePolling()
    }

    /// One status read, with the checks when they are due.
    func refresh() async {
        let now = clock()
        let wantPreflight = forcePreflight || lastPreflight.map { now.timeIntervalSince($0) >= Self.preflightInterval } ?? true
        let next: ShareStatus
        do throws(CLIError) {
            next = try await client.shareStatus(bench: bench, preflight: wantPreflight)
        } catch {
            if case .failed(_, _, let message) = error, message.localizedCaseInsensitiveContains("unknown command") {
                availability = .unavailable
                status = nil
                return
            }
            report(error)
            return
        }
        if wantPreflight { lastPreflight = now; forcePreflight = false }
        apply(next, keepingChecksOf: wantPreflight ? nil : status)
    }

    private func apply(_ next: ShareStatus, keepingChecksOf previous: ShareStatus?) {
        var next = next
        if next.preflight == nil, let checks = previous?.preflight { next.preflight = checks }
        availability = next.needsNewerCLI ? .needsNewerCLI : .available
        let countsMoved = status.map { $0.people != next.people || $0.devicesOnline != next.devicesOnline } ?? true
        status = next
        onStatus?()
        logLine("share: status \(next.state.rawValue)")
        for event in tracker.status(next) { emit(event) }
        if !next.isOn {
            code = nil
            knownSeats = [:]
            if !people.isEmpty { people = [] }
            return
        }
        if countsMoved || tabVisible { Task { await loadPeople() } }
        if tabVisible && code == nil { Task { await loadCode() } }
    }

    private func emit(_ event: ShareEvent) {
        logLine("share: event \(Self.kind(event))")
        onEvent?(event)
    }

    /// The event's kind only: names and addresses stay out of the log.
    nonisolated static func kind(_ event: ShareEvent) -> String {
        switch event {
        case .joined: "joined"
        case .left: "left"
        case .lockedByWrongCodes: "locked_by_wrong_codes"
        case .joinTrouble: "join_trouble"
        case .reminder(let minutes): "reminder_\(minutes)"
        case .stateChanged(_, let to): "state_\(to.rawValue)"
        case .networkChanged: "network_changed"
        }
    }

    func loadPeople() async {
        do throws(CLIError) {
            let list = try await client.sharePeople(bench: bench)
            people = list.people
            for person in list.people { if let seat = person.seatID { knownSeats[seat] = person.seatFullName ?? seat } }
            for event in tracker.people(list.people) { emit(event) }
        } catch {
            report(error)
        }
    }

    // MARK: the code

    /// Reads the code (`new`: draws a new one, which resets the wrong-code budget).
    func loadCode(new: Bool = false) async {
        guard isSharing else { return }
        if new { inviteCopied = false }
        do throws(CLIError) {
            code = try await client.shareCode(bench: bench, new: new)
            logLine(new ? "share: new code drawn" : "share: code read")
        } catch {
            report(error)
        }
        if new { await refresh() }
    }

    /// Copy invite: `share invite --json`, then `write` puts the message on the pasteboard.
    /// Runs only on that click; the message is never kept or logged.
    func copyInvite(installURL: String? = nil, write: (String) -> Void) async {
        guard isSharing else { return }
        inviteCopied = false
        do throws(CLIError) {
            let invite = try await client.shareInvite(bench: bench, installURL: installURL)
            write(invite.text)
            inviteCopied = true
            logLine("share: invite copied")
        } catch {
            report(error)
        }
    }

    // MARK: actions

    func loadUsers(site: String) async {
        do throws(CLIError) { users = try await client.shareUsers(bench: bench, site: site).users } catch { report(error) }
    }

    func loadLog(limit: Int = 50) async {
        do throws(CLIError) { log = try await client.shareLog(bench: bench, device: nil, since: nil, limit: limit).entries } catch { report(error) }
    }

    func setupPlan(_ request: ShareSetupRequest) async -> ShareSetupPlan? {
        do throws(CLIError) { return try await client.shareSetupPlan(bench: bench, request: request) } catch { report(error); return nil }
    }

    /// Runs setup; `onStep` hears each step name. Returns true on success.
    @discardableResult
    func setup(_ request: ShareSetupRequest, onStep: @escaping @Sendable (String) -> Void) async -> Bool {
        setupOrTeardownCalls += 1
        defer { setupOrTeardownCalls -= 1 }
        return await perform("Making the copy…") { client, bench throws(CLIError) in
            try await client.shareSetup(bench: bench, request: request, onStep: onStep)
        }
    }

    @discardableResult
    func start(hours: Int, label: String?) async -> Bool {
        let ok = await perform("Starting…") { client, bench throws(CLIError) in try await client.shareStart(bench: bench, forHours: hours, label: label) }
        ensurePolling()
        return ok
    }

    @discardableResult
    func stop() async -> Bool {
        await perform("Stopping…") { client, bench throws(CLIError) in try await client.shareStop(bench: bench) }
    }

    @discardableResult
    func extend(minutes: Int) async -> Bool {
        await perform("Extending…") { client, bench throws(CLIError) in try await client.shareExtend(bench: bench, byMinutes: minutes) }
    }

    @discardableResult
    func setLocked(_ locked: Bool) async -> Bool {
        await perform(locked ? "Locking…" : "Unlocking…") { client, bench throws(CLIError) in try await client.shareLock(bench: bench, locked: locked) }
    }

    @discardableResult
    func remove(_ person: SharePerson, newCode: Bool) async -> Bool {
        let ok = await perform("Removing…") { client, bench throws(CLIError) in try await client.shareRemove(bench: bench, person: person.id, newCode: newCode) }
        if ok && newCode { code = nil; await loadCode() }
        await loadPeople()
        return ok
    }

    @discardableResult
    func assign(_ person: SharePerson, seat: String) async -> Bool {
        let ok = await perform("Moving…") { client, bench throws(CLIError) in try await client.shareAssign(bench: bench, person: person.id, seat: seat) }
        await loadPeople()
        return ok
    }

    @discardableResult
    func openAs(_ user: String) async -> Bool {
        await perform(nil) { client, bench throws(CLIError) in try await client.shareOpenAs(bench: bench, user: user) }
    }

    @discardableResult
    func teardown() async -> Bool {
        setupOrTeardownCalls += 1
        defer { setupOrTeardownCalls -= 1 }
        return await perform("Removing the copy…") { client, bench throws(CLIError) in try await client.shareTeardown(bench: bench) }
    }

    @discardableResult
    func installNetworkProtection() async -> Bool {
        await perform("Turning on network protection…") { client, _ throws(CLIError) in try await client.lanGuardInstall() }
    }

    @discardableResult
    func allowNodeThroughFirewall() async -> Bool {
        await perform("Allowing…") { client, _ throws(CLIError) in try await client.lanGuardAllowNode() }
    }

    func clearError() { lastError = nil }

    /// Runs one action, then reads the status again (with the checks).
    private func perform(_ label: String?,
                         _ body: (any ShareCLI, String) async throws(CLIError) -> Void) async -> Bool {
        busy = label ?? busy
        defer { if label != nil { busy = nil } }
        lastError = nil
        var ok = true
        do throws(CLIError) {
            try await body(client, bench)
        } catch {
            report(error)
            ok = false
        }
        forcePreflight = true
        await refresh()
        return ok
    }

    /// The CLI's words, verbatim, minus the code if it ever appeared in them.
    private func report(_ error: CLIError) {
        var text = error.localizedDescription
        if let code = code?.code, !code.isEmpty {
            text = text.replacingOccurrences(of: code, with: "······")
        }
        lastError = text
        logLine("share: error")
        onError?(text)
    }
}
