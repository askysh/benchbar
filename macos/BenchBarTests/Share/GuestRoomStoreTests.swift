import Foundation
import Network
import Testing
@testable import BenchBar

/// A host that answers from a table: path -> (status, JSON body).
nonisolated final class ScriptedTransport: RoomTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [String: (Int, String)]
    private var _calls: [String] = []
    var calls: [String] { lock.withLock { _calls } }
    var serverSPKIHash: Data? { Data(count: 32) }
    var exporter: Data? { Data(count: 32) }
    var remoteEndpoint: NWEndpoint? { .hostPort(host: "192.168.1.9", port: 8443) }

    init(_ table: [String: (Int, String)]) { self.table = table }

    func set(_ path: String, _ status: Int, _ body: String) { lock.withLock { table[path] = (status, body) } }
    func remove(_ path: String) { lock.withLock { _ = table.removeValue(forKey: path) } }

    func send(_ method: String, _ path: String, body: Data?) async throws(RoomConnectionError) -> RoomResponse {
        let answer = lock.withLock { () -> (Int, String)? in
            _calls.append("\(method) \(path)")
            return table[path]
        }
        guard let (status, text) = answer else { throw .unreachable }
        return RoomResponse(status: status, headers: [:], body: Data(text.utf8))
    }

    func close() {}
}

/// A room that completes TLS and never answers: every send waits until close().
nonisolated final class SilentTransport: RoomTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var _closed = false
    private var _sends = 0
    var closed: Bool { lock.withLock { _closed } }
    var sends: Int { lock.withLock { _sends } }
    var serverSPKIHash: Data? { Data(count: 32) }
    var exporter: Data? { Data(count: 32) }
    var remoteEndpoint: NWEndpoint? { nil }

    func send(_ method: String, _ path: String, body: Data?) async throws(RoomConnectionError) -> RoomResponse {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                _sends += 1
                if _closed { return true }
                waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        throw .closed
    }

    func close() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            _closed = true
            defer { waiting.removeAll() }
            return waiting
        }
        resumed.forEach { $0.resume() }
    }
}

nonisolated final class FakeForwarder: ForwarderRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var _shown: ForwarderPage?
    var shown: ForwarderPage? { lock.withLock { _shown } }
    var isRunning: Bool { lock.withLock { running } }
    let port: UInt16 = 41234
    func start() async throws { lock.withLock { running = true } }
    func stop() { lock.withLock { running = false } }
    func show(_ page: ForwarderPage?) { lock.withLock { _shown = page } }
    func signInURL(next: String) -> URL? { URL(string: "http://standup-1a2b3c4d.localhost:41234/_benchbar/signin?next=\(next)") }
    func stopIfIdle() -> Bool { false }
}

/// Every dial the store makes, and an optional failure to answer it with.
nonisolated final class DialLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _pins: [ServerPin] = []
    private var _failure: RoomConnectionError?
    var pins: [ServerPin] { lock.withLock { _pins } }
    var failure: RoomConnectionError? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }

    func record(_ pin: ServerPin) throws(RoomConnectionError) {
        let failure = lock.withLock { () -> RoomConnectionError? in
            _pins.append(pin)
            return _failure
        }
        if let failure { throw failure }
    }
}

nonisolated final class NoBrowser: RoomBrowsing, @unchecked Sendable {
    func start(onChange: @escaping @Sendable ([DiscoveredRoom]) -> Void, onDenied: @escaping @Sendable () -> Void) {}
    func stop() {}
}

@MainActor
private final class Harness {
    let transport = ScriptedTransport([
        "/_benchbar/seats": (200, #"[{"seat_id":"s1","full_name":"Sales One","roles":["Sales User"],"taken_by":null},{"seat_id":"s2","full_name":"Ops","roles":[],"taken_by":"Ravi"}]"#),
        "/_benchbar/seat": (200, #"{"ok":true,"seat_id":"s1","full_name":"Sales One"}"#),
        "/_benchbar/hello": (200, #"{"ok":true,"protocol":3,"device":"d_1","user_label":null,"deadline_epoch":1800003600,"label":"Priya","site_label":"macdev"}"#),
        "/_benchbar/leave": (200, #"{"ok":true,"wiped":true}"#),
        "/room/hello": (200, Harness.roomHello(salt: String(repeating: "00", count: 16))),
    ])
    let dials = DialLog()
    let forwarder = FakeForwarder()
    var opened: [URL] = []
    var joinResult: Result<JoinedRoom, JoinRefusal>
    var codesSeen: [String] = []
    var invitesSeen: [RoomJoin.InviteCheck?] = []
    var pasteboard: String?
    var pasteboardReads = 0
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    let defaults = UserDefaults(suiteName: "guest-store-\(UUID().uuidString)")!
    lazy var store: GuestRoomStore = makeStore()

    static let hello = RoomHello(v: 3, room: "Standup", host: "Priya", site: "macdev", salt: String(repeating: "00", count: 16),
                                 locked: false, full: false, people: 1, seats: 2)
    static func roomHello(salt: String) -> String {
        #"{"v":3,"room":"Standup","host":"Priya","site":"macdev","salt":"\#(salt)","locked":false,"full":false,"people":1,"seats":2}"#
    }

    static let room = DiscoveredRoom(id: "Priya's room", endpoint: .hostPort(host: "192.168.1.9", port: 8443),
                                     display: RoomDisplay(label: "Standup", site: "macdev", protocolV: 3))

    init() {
        joinResult = .success(JoinedRoom(deviceId: "d_1", hostPin: Data(repeating: 0xab, count: 32), hello: Self.hello))
    }

    private func makeStore() -> GuestRoomStore {
        let transport = transport
        let forwarder = forwarder
        let dials = dials
        return GuestRoomStore(dependencies: .init(
            browser: NoBrowser(),
            rooms: SavedRoomsStore(defaults: defaults),
            dial: { _, pin throws(RoomConnectionError) in
                try dials.record(pin)
                return transport
            },
            runJoin: { [unowned self] _, code, _, _, _, invite in
                await MainActor.run {
                    codesSeen.append(code)
                    invitesSeen.append(invite)
                    return joinResult
                }
            },
            clientFingerprint: { Data(count: 32) },
            makeForwarder: { _ in forwarder },
            openURL: { [unowned self] in opened.append($0) },
            readPasteboard: { [unowned self] in
                pasteboardReads += 1
                return pasteboard
            },
            now: { [unowned self] in now },
            model: "Mac14,2"), guestName: "Asha")
    }
}

@MainActor
@Suite struct GuestRoomStoreTests {
    @Test func joinSavesTheRoomWithoutTheCodeAndOffersSeats() async throws {
        let h = Harness()
        h.store.beginJoin(Harness.room)
        #expect(h.store.join == .enteringCode(Harness.room))
        await h.store.submit(code: "482 913", for: Harness.room)
        guard case .pickingSeat(let saved, let seats) = h.store.join else {
            Issue.record("expected the seat picker, got \(h.store.join)")
            return
        }
        #expect(seats.map(\.seat_id) == ["s1", "s2"])
        #expect(saved.deviceId == "d_1" && saved.lastHost == "192.168.1.9" && saved.port == 8443)
        #expect(h.store.saved == [saved])
        let everything = "\(h.defaults.dictionaryRepresentation())"
        #expect(!everything.contains("482913") && !everything.contains("482 913"))
        #expect(h.store.nearby.isEmpty)
    }

    @Test func pickingASeatOpensTheSignInPage() async throws {
        let h = Harness()
        await h.store.submit(code: "482913", for: Harness.room)
        guard case .pickingSeat(let room, let seats) = h.store.join else {
            Issue.record("no seat picker")
            return
        }
        await h.store.pick(seat: seats[0], in: room, seats: seats)
        #expect(h.store.join == .none)
        #expect(h.opened.map(\.absoluteString) == ["http://standup-1a2b3c4d.localhost:41234/_benchbar/signin?next=/app"])
        #expect(h.forwarder.isRunning)
        #expect(h.store.saved.first?.localPort == 41234)
        h.store.stopHealthLoop()
    }

    @Test func wrongCodesAreSpacedAndLockOutAfterFive() async {
        let h = Harness()
        h.joinResult = .failure(.wrongCode)
        for attempt in 0..<5 {
            await h.store.submit(code: "000000", for: Harness.room)
            #expect(h.store.join == .refused(Harness.room, .wrongCode), "attempt \(attempt)")
            h.now = h.now.addingTimeInterval(1)
            await h.store.submit(code: "000000", for: Harness.room)   // under 3 s: ignored
            h.now = h.now.addingTimeInterval(3)
        }
        #expect(h.codesSeen.count == 5)
        await h.store.submit(code: "000000", for: Harness.room)
        #expect(h.store.join == .refused(Harness.room, .rateLimited(retryAfter: 56)))
        #expect(h.codesSeen.count == 5)
        h.now = h.now.addingTimeInterval(61)
        await h.store.submit(code: "000000", for: Harness.room)
        #expect(h.codesSeen.count == 6)
    }

    @Test func refusalsAndBadCodesNeverReachTheHost() async {
        let h = Harness()
        await h.store.submit(code: "48291", for: Harness.room)
        #expect(h.store.join == .refused(Harness.room, .invalidCode))
        #expect(h.codesSeen.isEmpty)
        h.joinResult = .failure(.locked)
        await h.store.submit(code: "482913", for: Harness.room)
        #expect(h.store.join == .refused(Harness.room, .locked))
        #expect(h.store.saved.isEmpty)
    }

    @Test func aRoomOnAnotherProtocolCannotBeJoined() {
        let h = Harness()
        let old = DiscoveredRoom(id: "old", endpoint: Harness.room.endpoint, display: RoomDisplay(label: "Old", site: "", protocolV: 2))
        h.store.beginJoin(old)
        #expect(h.store.join == .none)
        #expect(NetworkPanePresentation.joinDisabledReason(old) == "Update BenchBar to join Old.")
    }

    @Test func healthPingTracksReadyGoneAndRemoved() async {
        let h = Harness()
        await h.store.submit(code: "482913", for: Harness.room)
        let room = h.store.saved[0]
        await h.store.open(room)
        h.store.stopHealthLoop()
        await h.store.pingAll()
        #expect(h.store.health[room.id] == .ready(deadline: Date(timeIntervalSince1970: 1_800_003_600)))
        h.transport.remove("/_benchbar/hello")
        await h.store.pingAll()
        #expect(h.store.health[room.id] == .hostGone(lastSeen: h.now))
        #expect(h.forwarder.shown == .hostOffline(host: "Priya", lastSeen: h.now.formatted(date: .omitted, time: .shortened)))
        h.transport.set("/_benchbar/hello", 403, #"{"error":"not_paired"}"#)
        await h.store.pingAll()
        #expect(h.store.health[room.id] == .removed)
        #expect(h.forwarder.shown == .removed(host: "Priya", askAgain: "benchbar://share/abababababababab/app"))
        // A removed room is never opened again.
        h.opened.removeAll()
        await h.store.open(room)
        #expect(h.opened.isEmpty)
    }

    @Test func aRestartReadsAsANewRoomAndTheRejoinIsPinned() async throws {
        let h = Harness()
        await h.store.submit(code: "482913", for: Harness.room)
        let room = h.store.saved[0]
        #expect(room.salt == String(repeating: "00", count: 16))
        await h.store.open(room)
        h.store.stopHealthLoop()
        h.transport.set("/_benchbar/hello", 403, #"{"error":"not_paired"}"#)
        h.transport.set("/room/hello", 200, Harness.roomHello(salt: String(repeating: "11", count: 16)))
        await h.store.pingAll()
        #expect(h.store.health[room.id] == .newRoom)
        #expect(NetworkPanePresentation.health(.newRoom, host: "Priya", now: h.now) == "Priya started a new room. Join with the new room code.")
        #expect(h.forwarder.shown == .ended(host: "Priya"))
        #expect(NetworkPanePresentation.canRejoin(h.store.health[room.id]))
        #expect(await h.store.open(link: .init(fp16: "abababababababab", path: "/app")) == false)

        h.store.beginRejoin(room)
        guard case .enteringCode(let target) = h.store.join else {
            Issue.record("expected the code sheet, got \(h.store.join)")
            return
        }
        #expect(target.id == room.serviceName && target.display.label == "Standup")
        let before = h.dials.pins.count
        h.now = h.now.addingTimeInterval(10)
        await h.store.submit(code: "123456", for: target)
        let rejoinDials = h.dials.pins.dropFirst(before)
        #expect(!rejoinDials.isEmpty && rejoinDials.allSatisfy { $0 == .pinned(Data(repeating: 0xab, count: 32)) })
        #expect(h.store.saved.count == 1)
        #expect(h.store.health[room.id] == .unknown)
        guard case .pickingSeat = h.store.join else {
            Issue.record("expected the seat picker, got \(h.store.join)")
            return
        }
    }

    @Test func aRemovalInTheSameRoomStillReadsAsRemoved() async {
        let h = Harness()
        await h.store.submit(code: "482913", for: Harness.room)
        let room = h.store.saved[0]
        h.transport.set("/_benchbar/hello", 403, #"{"error":"not_paired"}"#)
        await h.store.pingAll()
        #expect(h.store.health[room.id] == .removed)
        #expect(NetworkPanePresentation.canRejoin(.removed))
    }

    @Test func aPinnedRejoinToAnotherKeyShowsIdentityChangedAndKeepsThePin() async {
        let h = Harness()
        await h.store.submit(code: "482913", for: Harness.room)
        let room = h.store.saved[0]
        h.dials.failure = .identityChanged
        h.store.beginRejoin(room)
        guard case .enteringCode(let target) = h.store.join else {
            Issue.record("expected the code sheet, got \(h.store.join)")
            return
        }
        h.now = h.now.addingTimeInterval(10)
        await h.store.submit(code: "123456", for: target)
        #expect(h.dials.pins.last == .pinned(Data(repeating: 0xab, count: 32)))
        #expect(h.store.join == .refused(target, .identityChanged))
        #expect(h.store.health[room.id] == .identityChanged)
        #expect(h.store.saved == [room])
        #expect(!NetworkPanePresentation.canRejoin(.identityChanged))
        #expect(h.codesSeen == ["482913"])
    }

    @Test(.timeLimit(.minutes(1))) func cancelWhileJoiningClosesTheSheetAndTheConnection() async throws {
        let silent = SilentTransport()
        let store = GuestRoomStore(dependencies: .init(
            browser: NoBrowser(),
            rooms: SavedRoomsStore(defaults: UserDefaults(suiteName: "guest-cancel-\(UUID().uuidString)")!),
            dial: { _, _ throws(RoomConnectionError) in silent },
            runJoin: { transport, _, _, _, _, _ in
                do { _ = try await transport.send("GET", "/room/hello", body: nil) } catch { return .failure(.unreachable) }
                return .failure(.failed)
            },
            clientFingerprint: { Data(count: 32) },
            makeForwarder: { _ in FakeForwarder() },
            openURL: { _ in }, readPasteboard: { nil }), guestName: "Asha")
        store.beginJoin(Harness.room)
        let attempt = Task { await store.submit(code: "482913", for: Harness.room) }
        for _ in 0..<400 where silent.sends == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.join == .joining(Harness.room))
        store.cancelJoin()
        #expect(store.join == .none)
        await attempt.value
        #expect(silent.closed)
        #expect(store.join == .none)
        #expect(store.saved.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func aSilentRoomDoesNotHoldUpTheOthersPing() async throws {
        let defaults = UserDefaults(suiteName: "guest-ping-\(UUID().uuidString)")!
        let rooms = SavedRoomsStore(defaults: defaults)
        func saved(_ byte: UInt8, _ address: String) -> SavedRoom {
            SavedRoom(hostFingerprint: Fingerprint.prefix + Data(repeating: byte, count: 32).hex, deviceId: "d_\(byte)", room: "Room \(byte)",
                      host: "Host \(byte)", site: "macdev", serviceName: "room-\(byte)", lastHost: address, port: 8443, localPort: nil,
                      joinedAt: Date(timeIntervalSince1970: 1_800_000_000))
        }
        let quiet = saved(1, "10.0.0.1"), live = saved(2, "10.0.0.2")
        rooms.save(quiet)
        rooms.save(live)
        let silent = SilentTransport()
        let answering = ScriptedTransport(["/_benchbar/hello": (200, #"{"ok":true,"protocol":3,"device":"d_2","user_label":null,"deadline_epoch":1800003600,"label":"Room 2","site_label":"macdev"}"#)])
        let store = GuestRoomStore(dependencies: .init(
            browser: NoBrowser(),
            rooms: rooms,
            dial: { endpoint, _ throws(RoomConnectionError) in
                if case .hostPort(let host, _) = endpoint, "\(host)" == "10.0.0.1" { return silent }
                return answering
            },
            runJoin: { _, _, _, _, _, _ in .failure(.failed) },
            clientFingerprint: { Data(count: 32) },
            makeForwarder: { _ in FakeForwarder() },
            openURL: { _ in }, readPasteboard: { nil }), guestName: "Asha")
        let round = Task { await store.pingAll() }
        for _ in 0..<400 where store.health[live.id] == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.health[live.id] == .ready(deadline: Date(timeIntervalSince1970: 1_800_003_600)))
        #expect(silent.sends == 1)
        #expect(store.health[quiet.id] == nil)
        silent.close()
        await round.value
        #expect(store.health[quiet.id] == .offline)
    }

    @Test func theHostsWordsAreSanitizedBeforeTheyAreSaved() async {
        let h = Harness()
        var hello = Harness.hello
        hello.room = "Stand\u{202E}up\u{0007}"
        hello.host = "Pri\u{200B}ya"
        h.joinResult = .success(JoinedRoom(deviceId: "d_1", hostPin: Data(repeating: 0xab, count: 32), hello: hello))
        await h.store.submit(code: "482913", for: Harness.room)
        #expect(h.store.saved.first?.room == "Stand up")
        #expect(h.store.saved.first?.host == "Pri ya")
    }

    @Test func forgetTellsTheHostAndDropsTheRoom() async {
        let h = Harness()
        await h.store.submit(code: "482913", for: Harness.room)
        let room = h.store.saved[0]
        await h.store.forget(room)
        #expect(h.transport.calls.contains("POST /_benchbar/leave"))
        #expect(h.store.saved.isEmpty)
        #expect(SavedRoomsStore(defaults: h.defaults).load().isEmpty)
    }

    @Test func aDeepLinkOpensOnlyASavedRoom() async {
        let h = Harness()
        #expect(await h.store.open(link: .init(fp16: "abababababababab", path: "/app/todo")) == false)
        await h.store.submit(code: "482913", for: Harness.room)
        #expect(await h.store.open(link: .init(fp16: "abababababababab", path: "/app/todo")))
        #expect(h.opened.last?.absoluteString.hasSuffix("next=/app/todo") == true)
        h.store.stopHealthLoop()
    }
}

@Suite struct NetworkPanePresentationTests {
    @Test func copyForEveryGuestState() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(NetworkPanePresentation.title == "Rooms on this Wi-Fi")
        #expect(NetworkPanePresentation.codePrompt(Harness.room) == "Enter the room code from Standup")
        #expect(NetworkPanePresentation.nearbyRow(Harness.room) == "Standup · macdev")
        #expect(NetworkPanePresentation.refusal(.wrongCode, host: "Priya") == "That code didn't work. Check with Priya and try again.")
        #expect(NetworkPanePresentation.refusal(.locked, host: "Priya") == "Priya locked this room.")
        #expect(NetworkPanePresentation.refusal(.full, host: "Priya") == "This room is full.")
        #expect(NetworkPanePresentation.refusal(.codeDidNotCheckOut, host: "Priya") == "This room's code didn't check out. Ask Priya for the code again.")
        #expect(NetworkPanePresentation.health(.removed, host: "Priya", now: now) == "Priya removed you from this room.")
        #expect(NetworkPanePresentation.health(.ended, host: "Priya", now: now) == "Priya ended the room.")
        #expect(NetworkPanePresentation.health(.ready(deadline: now.addingTimeInterval(95 * 60)), host: "Priya", now: now) == "Ready · 1 h 35 min left")
        #expect(NetworkPanePresentation.health(.hostGone(lastSeen: now), host: "Priya", now: now).hasPrefix("Priya isn't sharing right now (last seen "))
        #expect(!NetworkPanePresentation.canOpen(.removed) && NetworkPanePresentation.canOpen(.ready(deadline: now)))
        let free = RoomSeat(seat_id: "s1", full_name: "Sales One", roles: ["Sales User", "Stock User"], taken_by: nil)
        let taken = RoomSeat(seat_id: "s2", full_name: "Ops", roles: [], taken_by: "Ravi")
        #expect(NetworkPanePresentation.seatRow(free) == ("Sales One · Sales User, Stock User", ""))
        #expect(NetworkPanePresentation.seatRow(taken) == ("Ops", "taken by Ravi"))
    }
}

@MainActor
@Suite struct GuestInviteTests {
    private let invite = InviteFixture.invite()!
    private var addressed: DiscoveredRoom {
        DiscoveredRoom(id: "Standup", endpoint: .hostPort(host: "192.168.1.9", port: 8443), display: RoomDisplay(label: "Standup", site: "", protocolV: 3))
    }

    @Test func aLinkOnlyOpensTheSheetAndJoinIsPinnedToTheInvite() async throws {
        let h = Harness()
        h.store.open(invite: .success(invite))
        #expect(h.store.join == .enteringCode(addressed))
        #expect(h.store.invite?.code == "482913")
        #expect(h.dials.pins.isEmpty && h.codesSeen.isEmpty && h.pasteboardReads == 0)

        await h.store.submit(code: "482913", for: addressed)
        #expect(!h.dials.pins.isEmpty && h.dials.pins.allSatisfy { $0 == .pinned(Data(repeating: 0xab, count: 32)) })
        #expect(h.invitesSeen == [invite.check])
        guard case .pickingSeat(let saved, _) = h.store.join else {
            Issue.record("expected the seat picker, got \(h.store.join)")
            return
        }
        #expect(saved.hostPin == invite.hostPin)
        #expect(h.store.invite == nil)
        #expect(!"\(h.defaults.dictionaryRepresentation())".contains("482913"))
    }

    /// `x` is advisory: the host may have extended the share, and a matching key and salt
    /// prove the code is current.
    @Test func aPastDeadlineStillJoinsALiveMatchingRoom() async {
        let h = Harness()
        h.now = invite.expires.addingTimeInterval(600)
        h.store.open(invite: .success(invite))
        #expect(h.store.join == .enteringCode(addressed))
        await h.store.submit(code: "482913", for: addressed)
        #expect(h.invitesSeen == [invite.check])
        guard case .pickingSeat = h.store.join else {
            Issue.record("expected the seat picker, got \(h.store.join)")
            return
        }
    }

    @Test func aPastDeadlineWithNoRoomAnsweringIsExpired() async {
        let h = Harness()
        h.dials.failure = .unreachable
        h.store.open(invite: .success(invite))
        h.now = invite.expires.addingTimeInterval(1)
        await h.store.submit(code: "482913", for: addressed)
        #expect(h.store.join == .refused(addressed, .inviteExpired))
        #expect(h.codesSeen.isEmpty)

        let early = Harness()
        early.dials.failure = .unreachable
        early.store.open(invite: .success(invite))
        await early.store.submit(code: "482913", for: addressed)
        #expect(early.store.join == .refused(addressed, .unreachable))
    }

    @Test func anotherKeyIsNotTheInvitedRoomAndNoJoinRuns() async {
        let h = Harness()
        h.dials.failure = .identityChanged
        h.store.open(invite: .success(invite))
        await h.store.submit(code: "482913", for: addressed)
        #expect(h.store.join == .refused(addressed, .notTheInvitedRoom))
        #expect(h.codesSeen.isEmpty)
        #expect(h.store.health.isEmpty)
    }

    @Test func theCodeIsBlankedOnceSentAndTheKeyStaysForARetry() async {
        let h = Harness()
        h.joinResult = .failure(.unreachable)
        h.store.open(invite: .success(invite))
        await h.store.submit(code: "482913", for: addressed)
        #expect(h.store.join == .refused(addressed, .unreachable))
        #expect(h.store.invite?.code == "")
        #expect(h.store.invite?.hostPin == invite.hostPin)
        h.store.cancelJoin()
        #expect(h.store.invite == nil)
    }

    @Test func thePasteboardIsReadOnlyByPasteInvite() async {
        let h = Harness()
        h.pasteboard = "see you there: \(InviteFixture.link())"
        h.store.startBrowsing()
        h.store.open(invite: .success(invite))
        h.store.cancelJoin()
        _ = URLRouter.route(URL(string: InviteFixture.link())!, benches: [], selected: nil)
        await h.store.pingAll()
        #expect(h.pasteboardReads == 0)

        h.store.pasteInvite()
        #expect(h.pasteboardReads == 1)
        #expect(h.store.join == .enteringCode(addressed))
        h.store.cancelJoin()

        h.pasteboard = "nothing to see"
        h.store.pasteInvite()
        #expect(h.pasteboardReads == 2)
        #expect(h.store.join == .none)
        #expect(h.store.inviteNotice == NetworkPanePresentation.inviteProblem(.notFound))
    }
}
