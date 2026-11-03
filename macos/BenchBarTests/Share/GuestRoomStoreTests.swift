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
    ])
    let forwarder = FakeForwarder()
    var opened: [URL] = []
    var joinResult: Result<JoinedRoom, JoinRefusal>
    var codesSeen: [String] = []
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    let defaults = UserDefaults(suiteName: "guest-store-\(UUID().uuidString)")!
    lazy var store: GuestRoomStore = makeStore()

    static let hello = RoomHello(v: 3, room: "Standup", host: "Priya", site: "macdev", salt: String(repeating: "00", count: 16),
                                 locked: false, full: false, people: 1, seats: 2)
    static let room = DiscoveredRoom(id: "Priya's room", endpoint: .hostPort(host: "192.168.1.9", port: 8443),
                                     display: RoomDisplay(label: "Standup", site: "macdev", protocolV: 3))

    init() {
        joinResult = .success(JoinedRoom(deviceId: "d_1", hostPin: Data(repeating: 0xab, count: 32), hello: Self.hello))
    }

    private func makeStore() -> GuestRoomStore {
        let transport = transport
        let forwarder = forwarder
        return GuestRoomStore(dependencies: .init(
            browser: NoBrowser(),
            rooms: SavedRoomsStore(defaults: defaults),
            dial: { _, _ throws(RoomConnectionError) in transport },
            runJoin: { [unowned self] _, code, _, _, _ in
                await MainActor.run {
                    codesSeen.append(code)
                    return joinResult
                }
            },
            clientFingerprint: { Data(count: 32) },
            makeForwarder: { _ in forwarder },
            openURL: { [unowned self] in opened.append($0) },
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
