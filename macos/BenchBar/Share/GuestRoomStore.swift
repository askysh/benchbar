import Foundation
import Network
import Observation

/// What the app needs from a running forwarder; ShareForwarder in the app, a fake in tests.
nonisolated protocol ForwarderRunning: AnyObject, Sendable {
    var isRunning: Bool { get }
    var port: UInt16 { get }
    func start() async throws
    func stop()
    func show(_ page: ForwarderPage?)
    func signInURL(next: String) -> URL?
    @discardableResult func stopIfIdle() -> Bool
}

extension ShareForwarder: ForwarderRunning {}

/// The guest side as the window sees it: rooms found on this Wi-Fi, the join with a code,
/// the seat pick, Open, Forget, and each saved room's health from the 10-second ping.
@Observable
final class GuestRoomStore {
    enum JoinStep: Equatable {
        case none
        case enteringCode(DiscoveredRoom)
        case joining(DiscoveredRoom)
        case refused(DiscoveredRoom, JoinRefusal)
        case pickingSeat(SavedRoom, [RoomSeat])
        case seatRefused(SavedRoom, [RoomSeat], RoomAPIError)
    }

    enum RoomHealth: Equatable {
        case unknown
        case ready(deadline: Date)
        case hostGone(lastSeen: Date)
        case offline
        case removed
        case ended
        case identityChanged
    }

    struct Dependencies {
        var browser: any RoomBrowsing
        var rooms: SavedRoomsStore
        var dial: @Sendable (NWEndpoint, ServerPin) async throws(RoomConnectionError) -> any RoomTransport
        /// The join itself; the code is passed through and never kept.
        var runJoin: @Sendable (any RoomTransport, String, String, String, Data) async -> Result<JoinedRoom, JoinRefusal>
        var clientFingerprint: @Sendable () -> Data?
        var makeForwarder: (SavedRoom) -> any ForwarderRunning
        var openURL: (URL) -> Void
        var now: () -> Date = Date.init
        var model: String = GuestRoomStore.hardwareModel()
    }

    static let pingInterval: Duration = .seconds(10)
    static let attemptSpacing: TimeInterval = 3
    static let lockoutAfter = 5
    static let lockout: TimeInterval = 60

    private(set) var discovered: [DiscoveredRoom] = []
    private(set) var saved: [SavedRoom]
    private(set) var health: [String: RoomHealth] = [:]
    private(set) var localNetworkDenied = false
    var join: JoinStep = .none
    var guestName: String

    private let deps: Dependencies
    private var forwarders: [String: any ForwarderRunning] = [:]
    private var lastAttempt: Date?
    private var wrongInARow = 0
    private var lockedUntil: Date?
    private var pingTask: Task<Void, Never>?

    init(dependencies: Dependencies, guestName: String = NSFullUserName()) {
        deps = dependencies
        saved = dependencies.rooms.load()
        self.guestName = guestName
    }

    /// Rooms found that this Mac has not joined (the saved row stands for them).
    var nearby: [DiscoveredRoom] {
        let joined = Set(saved.map(\.serviceName))
        return discovered.filter { !joined.contains($0.id) }
    }

    // MARK: Finding rooms (only while the pane is visible)

    func startBrowsing() {
        deps.browser.start(onChange: { [weak self] rooms in
            Task { @MainActor in self?.discovered = rooms }
        }, onDenied: { [weak self] in
            Task { @MainActor in self?.localNetworkDenied = true }
        })
    }

    func stopBrowsing() {
        deps.browser.stop()
    }

    // MARK: Joining

    func beginJoin(_ room: DiscoveredRoom) {
        guard !room.display.needsUpdate else { return }
        if case .joining = join { return }
        join = .enteringCode(room)
    }

    func cancelJoin() {
        if case .joining = join { return }
        join = .none
    }

    /// One human attempt: no automatic retry, at most one per 3 s, and a 60 s pause after
    /// 5 wrong codes in a row (J12).
    func submit(code: String, for room: DiscoveredRoom) async {
        let now = deps.now()
        if let lockedUntil, now < lockedUntil {
            join = .refused(room, .rateLimited(retryAfter: Int(lockedUntil.timeIntervalSince(now).rounded(.up))))
            return
        }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < Self.attemptSpacing { return }
        guard RoomCode.normalize(code) != nil else {
            join = .refused(room, .invalidCode)
            return
        }
        guard let fg = deps.clientFingerprint() else {
            join = .refused(room, .failed)
            return
        }
        lastAttempt = now
        join = .joining(room)

        // A host this Mac joined before must show the same key (rejoins are pinned).
        let earlier = saved.first { $0.serviceName == room.id }
        let pin: ServerPin = earlier?.hostPin.map(ServerPin.pinned) ?? .firstJoin
        let transport: any RoomTransport
        do {
            transport = try await deps.dial(room.endpoint, pin)
        } catch {
            join = .refused(room, error == .identityChanged ? .identityChanged : error == .localNetworkDenied ? .localNetworkDenied : .unreachable)
            if error == .localNetworkDenied { localNetworkDenied = true }
            return
        }
        let result = await deps.runJoin(transport, code, guestName, deps.model, fg)
        let address = transport.remoteEndpoint
        transport.close()

        switch result {
        case .failure(let refusal):
            if refusal == .wrongCode {
                wrongInARow += 1
                if wrongInARow >= Self.lockoutAfter {
                    wrongInARow = 0
                    lockedUntil = deps.now().addingTimeInterval(Self.lockout)
                }
            }
            join = .refused(room, refusal)
        case .success(let joined):
            wrongInARow = 0
            var lastHost = ""
            var port: UInt16 = 0
            if case .hostPort(let host, let hostPort)? = address {
                lastHost = "\(host)"
                port = hostPort.rawValue
            }
            let entry = SavedRoom(hostFingerprint: Fingerprint.prefix + joined.hostPin.hex, deviceId: joined.deviceId, room: joined.hello.room,
                                  host: joined.hello.host, site: joined.hello.site, serviceName: room.id, lastHost: lastHost, port: port,
                                  localPort: earlier?.localPort, joinedAt: deps.now())
            if let old = forwarders.removeValue(forKey: entry.id) { old.stop() }
            deps.rooms.save(entry)
            saved = deps.rooms.load()
            health[entry.id] = .unknown
            await chooseSeat(entry)
        }
    }

    /// Lists the seats for a joined room (also how a guest switches seat later).
    func chooseSeat(_ room: SavedRoom) async {
        do {
            let seats = try await withAPI(room) { api async throws(RoomAPIError) in try await api.seats() }
            join = .pickingSeat(room, seats)
        } catch {
            note(error, for: room)
            join = .seatRefused(room, [], error)
        }
    }

    func pick(seat: RoomSeat, in room: SavedRoom, seats: [RoomSeat]) async {
        do {
            try await withAPI(room) { api async throws(RoomAPIError) in try await api.takeSeat(seat.seat_id) }
            join = .none
            await open(room)
        } catch {
            if error == .seatTaken {
                await chooseSeat(room)
                if case .pickingSeat(_, let fresh) = join { join = .seatRefused(room, fresh, .seatTaken) }
            } else {
                note(error, for: room)
                join = .seatRefused(room, seats, error)
            }
        }
    }

    // MARK: Open and Forget

    /// Starts the room's forwarder if needed and opens the sign-in page in the browser.
    /// Does nothing for a room the host removed this Mac from, or whose key changed.
    func open(_ room: SavedRoom, path: String = "/app") async {
        switch health[room.id] {
        case .removed?, .identityChanged?, .ended?: return
        default: break
        }
        let forwarder = forwarders[room.id] ?? deps.makeForwarder(room)
        forwarders[room.id] = forwarder
        if !forwarder.isRunning {
            do { try await forwarder.start() } catch { return }
            if room.localPort != forwarder.port {
                var moved = room
                moved.localPort = forwarder.port
                deps.rooms.save(moved)
                saved = deps.rooms.load()
            }
        }
        if let url = forwarder.signInURL(next: path) { deps.openURL(url) }
        startHealthLoop()
    }

    /// `benchbar://share/<fp16>/app…`: opens a saved room only; false shows the pane instead.
    func open(link: ShareDeepLink.Target) async -> Bool {
        guard let room = saved.first(where: { $0.hostPin.map(ShareDeepLink.fp16(of:)) == link.fp16 }) else { return false }
        await open(room, path: link.path)
        return true
    }

    /// Tells the host first, best effort, so the seat's sessions are wiped there.
    func forget(_ room: SavedRoom) async {
        _ = try? await withAPI(room) { api async throws(RoomAPIError) in try await api.leave() }
        forwarders.removeValue(forKey: room.id)?.stop()
        deps.rooms.forget(room)
        saved = deps.rooms.load()
        health[room.id] = nil
        if case .pickingSeat(let picking, _) = join, picking.id == room.id { join = .none }
    }

    func forgetAll() async {
        for room in saved { await forget(room) }
    }

    // MARK: Health

    func startHealthLoop() {
        guard pingTask == nil else { return }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pingAll()
                try? await Task.sleep(for: Self.pingInterval)
            }
        }
    }

    func stopHealthLoop() {
        pingTask?.cancel()
        pingTask = nil
    }

    /// One `GET /_benchbar/hello` per saved room. A failure after a good hello is "host gone";
    /// 403 not_paired is "removed"; a changed key is never connected to again.
    func pingAll() async {
        for room in saved {
            switch health[room.id] {
            case .removed?, .identityChanged?, .ended?: continue
            default: break
            }
            do {
                let hello = try await withAPI(room) { api async throws(RoomAPIError) in try await api.hello() }
                health[room.id] = .ready(deadline: Date(timeIntervalSince1970: TimeInterval(hello.deadline_epoch)))
                forwarders[room.id]?.show(nil)
            } catch {
                note(error, for: room)
            }
            if forwarders[room.id]?.stopIfIdle() == true { forwarders[room.id] = nil }
        }
    }

    private func note(_ error: RoomAPIError, for room: SavedRoom) {
        let state: RoomHealth
        switch error {
        case .removed: state = .removed
        case .ended: state = .ended
        case .identityChanged: state = .identityChanged
        case .unreachable:
            switch health[room.id] {
            case .ready?: state = .hostGone(lastSeen: deps.now())
            case .hostGone(let seen)?: state = .hostGone(lastSeen: seen)
            default: state = .offline
            }
        case .seatTaken, .rateLimited, .refused: return
        }
        health[room.id] = state
        forwarders[room.id]?.show(NetworkPanePresentation.page(for: state, host: room.host, askAgain: "benchbar://share/\(room.hostPin.map(ShareDeepLink.fp16(of:)) ?? "")/app"))
    }

    /// The saved address first, then the Bonjour service of the same name; always pinned.
    private func withAPI<T>(_ room: SavedRoom, _ body: (RoomAPI) async throws(RoomAPIError) -> T) async throws(RoomAPIError) -> T {
        guard let pin = room.hostPin else { throw .refused }
        var endpoints: [NWEndpoint] = []
        if !room.lastHost.isEmpty, let port = NWEndpoint.Port(rawValue: room.port), room.port != 0 {
            endpoints.append(.hostPort(host: NWEndpoint.Host(room.lastHost), port: port))
        }
        if let found = discovered.first(where: { $0.id == room.serviceName }) { endpoints.append(found.endpoint) }
        for endpoint in endpoints {
            let transport: any RoomTransport
            do {
                transport = try await deps.dial(endpoint, .pinned(pin))
            } catch {
                if error == .identityChanged { throw .identityChanged }
                continue
            }
            defer { transport.close() }
            return try await body(RoomAPI(transport: transport))
        }
        throw .unreachable
    }

    nonisolated static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 1 else { return "Mac" }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

extension GuestRoomStore.Dependencies {
    /// The real thing: Keychain identity, pinned mTLS, the bundled map, the loopback forwarder.
    static func live(identity: KeychainIdentity, defaults: UserDefaults = .standard, openURL: @escaping (URL) -> Void) -> Self {
        let suffix = LocalShareName.installSuffix(defaults: defaults)
        return Self(
            browser: LanRoomBrowser(),
            rooms: SavedRoomsStore(defaults: defaults),
            dial: { endpoint, pin throws(RoomConnectionError) in
                guard let secIdentity = try? identity.identity() else { throw .unreachable }
                let connection = RoomConnection(endpoint: endpoint, identity: secIdentity, pin: pin)
                try await connection.open()
                return connection
            },
            runJoin: { transport, code, name, model, fg in
                await RoomJoin(name: name, model: model).join(over: transport, code: code, fg: fg)
            },
            clientFingerprint: { (try? identity.spkiDER()).map(Fingerprint.raw(spki:)) },
            makeForwarder: { room in
                let pin = room.hostPin ?? Data()
                let endpoint: NWEndpoint = room.lastHost.isEmpty
                    ? .service(name: room.serviceName, type: LanRoomBrowser.serviceType, domain: "local.", interface: nil)
                    : .hostPort(host: NWEndpoint.Host(room.lastHost), port: NWEndpoint.Port(rawValue: room.port) ?? 0)
                let port = room.localPort ?? LocalShareName.port(for: pin, isFree: { _ in true }) ?? UInt16(LocalShareName.portRange.lowerBound)
                return ShareForwarder(localHost: LocalShareName.host(label: room.room, suffix: suffix, hostPin: pin), port: port, hostLabel: room.host, pin: pin,
                                      makeUpstream: ShareForwarder.pinnedUpstream(to: endpoint, identity: identity, pin: pin))
            },
            openURL: openURL)
    }
}
