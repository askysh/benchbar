import AppKit
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
        /// 403 not_paired while the room's salt changed: the host ended that room and started
        /// another, which deletes every device (R3.5); a rejoin with the new code is pinned.
        case newRoom
        case ended
        case identityChanged
    }

    /// Who wants rooms found: browsing (and the nearby hellos) run while either is on screen.
    enum BrowseOwner: Hashable {
        case pane
        case popover
    }

    /// A nearby room's live state, from its pre-auth `/room/hello` over an unpinned TLS
    /// connection: display only, and no code material is ever sent for it.
    enum NearbyState: Equatable {
        case checking
        case open
        case locked
        case full
        case notAnswering
    }

    struct NearbyStatus: Equatable {
        var state: NearbyState
        var hello: RoomHello?
    }

    struct Dependencies {
        var browser: any RoomBrowsing
        var rooms: SavedRoomsStore
        var dial: @Sendable (NWEndpoint, ServerPin) async throws(RoomConnectionError) -> any RoomTransport
        /// Nearby discovery's hello: unpinned and without this Mac's client identity, so a room
        /// the user never chose cannot learn which Mac is looking. Join and saved rooms use `dial`.
        var discoveryDial: @Sendable (NWEndpoint) async throws(RoomConnectionError) -> any RoomTransport
        /// The join itself; the code is passed through and never kept.
        var runJoin: @Sendable (any RoomTransport, String, String, String, Data, RoomJoin.InviteCheck?) async -> Result<JoinedRoom, JoinRefusal>
        var clientFingerprint: @Sendable () -> Data?
        var makeForwarder: (SavedRoom) -> any ForwarderRunning
        var openURL: (URL) -> Void
        /// Read only by Paste invite, on its click.
        var readPasteboard: () -> String?
        var now: () -> Date = Date.init
        var model: String = GuestRoomStore.hardwareModel()
    }

    static let pingInterval: Duration = .seconds(10)
    /// At most one nearby hello per room this often: the gateway allows 10 hellos a minute per
    /// address, shared with the join's own hello and the saved rooms' checks.
    static let helloSpacing: TimeInterval = 15
    static let nearbyInterval: Duration = .seconds(5)
    static let attemptSpacing: TimeInterval = 3
    static let lockoutAfter = 5
    static let lockout: TimeInterval = 60

    private(set) var discovered: [DiscoveredRoom] = []
    private(set) var saved: [SavedRoom]
    private(set) var health: [String: RoomHealth] = [:]
    private(set) var localNetworkDenied = false
    /// Live state per nearby room (Bonjour service name), while browsing.
    private(set) var nearbyStatus: [String: NearbyStatus] = [:]
    var join: JoinStep = .none
    var guestName: String
    /// The invite the join sheet is for. Its code is the sheet's prefill and is blanked as the
    /// join is sent; the key, salt and deadline stay for a retry. Cleared when the sheet closes.
    private(set) var invite: ShareInvite?
    /// Why a link or a paste did not open the join sheet.
    private(set) var inviteNotice: String?

    private let deps: Dependencies
    private var forwarders: [String: any ForwarderRunning] = [:]
    private var lastAttempt: Date?
    private var wrongInARow = 0
    private var lockedUntil: Date?
    private var pingTask: Task<Void, Never>?
    /// The saved room the join sheet is for, so its pin is used and never replaced (J19).
    private var rejoining: SavedRoom?
    /// Bumped by Cancel while joining: a join that resumes afterwards leaves the sheet closed.
    private var joinAttempt = 0
    private var joinTransport: (any RoomTransport)?
    private var browseOwners: Set<BrowseOwner> = []
    private var lastHello: [String: Date] = [:]
    private var helloInFlight: Set<String> = []
    private var nearbyTask: Task<Void, Never>?

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

    /// Nearby rooms, Open first, then still checking, Locked, Full and not answering.
    var sortedNearby: [DiscoveredRoom] {
        NetworkPanePresentation.sortedNearby(nearby, status: nearbyStatus)
    }

    var openNearbyCount: Int {
        nearby.filter { nearbyStatus[$0.id]?.state == .open }.count
    }

    // MARK: Finding rooms (only while the pane or the popover is visible)

    func startBrowsing(for owner: BrowseOwner = .pane) {
        let idle = browseOwners.isEmpty
        browseOwners.insert(owner)
        guard idle else { return }
        startBrowser()
        nearbyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.nearbyInterval)
                await self?.checkNearby()
            }
        }
    }

    func stopBrowsing(for owner: BrowseOwner = .pane) {
        guard browseOwners.remove(owner) != nil, browseOwners.isEmpty else { return }
        deps.browser.stop()
        nearbyTask?.cancel()
        nearbyTask = nil
    }

    /// Find rooms / Refresh: browse again and ask every room whose spacing allows it now.
    func refreshNearby() async {
        guard !browseOwners.isEmpty else { return }
        deps.browser.stop()
        startBrowser()
        await checkNearby()
    }

    private func startBrowser() {
        deps.browser.start(onChange: { [weak self] rooms in
            Task { @MainActor in
                self?.discovered = rooms
                await self?.checkNearby()
            }
        }, onDenied: { [weak self] in
            Task { @MainActor in self?.localNetworkDenied = true }
        })
    }

    /// One pre-auth hello for each nearby room not asked within `helloSpacing`.
    func checkNearby() async {
        let now = deps.now()
        let due = nearby.filter { room in
            !room.display.needsUpdate && !helloInFlight.contains(room.id)
                && lastHello[room.id].map { now.timeIntervalSince($0) >= Self.helloSpacing } ?? true
        }
        for room in due {
            lastHello[room.id] = now
            helloInFlight.insert(room.id)
            if nearbyStatus[room.id] == nil { nearbyStatus[room.id] = NearbyStatus(state: .checking) }
        }
        await withTaskGroup(of: Void.self) { group in
            for room in due {
                group.addTask { await self.askHello(room) }
            }
        }
    }

    private func askHello(_ room: DiscoveredRoom) async {
        var hello: RoomHello?
        if let transport = try? await deps.discoveryDial(room.endpoint) {
            hello = try? await RoomAPI(transport: transport).roomHello()
            transport.close()
        }
        helloInFlight.remove(room.id)
        nearbyStatus[room.id] = NearbyStatus(state: NetworkPanePresentation.nearbyState(hello), hello: hello)
    }

    // MARK: Joining

    func beginJoin(_ room: DiscoveredRoom) {
        guard !room.display.needsUpdate else { return }
        if case .joining = join { return }
        rejoining = nil
        invite = nil
        join = .enteringCode(room)
    }

    /// Join a saved room's host again (a new room after a restart, or after Remove): the dial
    /// is pinned to the key saved at the first join, so a host showing another key is refused.
    func beginRejoin(_ room: SavedRoom) {
        if case .joining = join { return }
        let target = rejoinTarget(room)
        guard !target.display.needsUpdate else { return }
        rejoining = room
        invite = nil
        join = .enteringCode(target)
    }

    /// A `benchbar://share/join` link or a pasted invite: opens the join sheet with the code
    /// filled in and waits for the Join click. Nothing is dialled here.
    func open(invite result: Result<ShareInvite, ShareInvite.Problem>) {
        if case .joining = join { return }
        switch result {
        case .failure(let problem):
            inviteNotice = NetworkPanePresentation.inviteProblem(problem)
        case .success(let invite):
            inviteNotice = nil
            rejoining = nil
            self.invite = invite
            join = .enteringCode(inviteTargets(invite)[0])
        }
    }

    /// The Paste invite button: the only place the pasteboard is read.
    func pasteInvite() {
        open(invite: ShareInvite.first(in: deps.readPasteboard() ?? ""))
    }

    func dismissInviteNotice() {
        inviteNotice = nil
    }

    /// Bonjour rooms with the invite's label first, then the invite's address. A TXT record
    /// proves nothing, so every one of them is dialled pinned to the invite's key.
    private func inviteTargets(_ invite: ShareInvite) -> [DiscoveredRoom] {
        var targets = discovered.filter { $0.display.label == invite.room && !$0.display.needsUpdate }
        if let address = invite.address, let port = NWEndpoint.Port(rawValue: address.port) {
            targets.append(DiscoveredRoom(id: invite.room, endpoint: .hostPort(host: NWEndpoint.Host(address.host), port: port),
                                          display: RoomDisplay(label: invite.room, site: "", protocolV: CPace.protocolVersion)))
        }
        if targets.isEmpty {
            // Neither seen nor addressed: the sheet still opens, and Join reports "didn't answer".
            targets.append(DiscoveredRoom(id: invite.room, endpoint: .service(name: invite.room, type: LanRoomBrowser.serviceType, domain: "local.", interface: nil),
                                          display: RoomDisplay(label: invite.room, site: "", protocolV: CPace.protocolVersion)))
        }
        return targets
    }

    /// The live Bonjour entry first, then the saved address, then the service by name.
    private func rejoinTarget(_ room: SavedRoom) -> DiscoveredRoom {
        if let found = discovered.first(where: { $0.id == room.serviceName }) { return found }
        let endpoint: NWEndpoint = !room.lastHost.isEmpty && room.port != 0
            ? .hostPort(host: NWEndpoint.Host(room.lastHost), port: NWEndpoint.Port(rawValue: room.port) ?? 0)
            : .service(name: room.serviceName, type: LanRoomBrowser.serviceType, domain: "local.", interface: nil)
        return DiscoveredRoom(id: room.serviceName, endpoint: endpoint,
                              display: RoomDisplay(label: room.room, site: room.site, protocolV: CPace.protocolVersion))
    }

    func cancelJoin() {
        if case .joining = join {
            joinAttempt += 1
            joinTransport?.close()
            joinTransport = nil
        }
        rejoining = nil
        invite = nil
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
        let invite = self.invite
        self.invite?.code = ""
        lastAttempt = now
        join = .joining(room)
        joinAttempt += 1
        let attempt = joinAttempt

        // A host this Mac joined before must show the same key (rejoins are pinned); an
        // invite's host must show the invite's key, checked in the TLS handshake itself.
        let earlier: SavedRoom?
        let pin: ServerPin
        let targets: [DiscoveredRoom]
        if let invite {
            earlier = saved.first { $0.hostPin == invite.hostPin }
            pin = .pinned(invite.hostPin)
            targets = inviteTargets(invite)
        } else {
            earlier = rejoining.flatMap { $0.serviceName == room.id ? $0 : nil } ?? saved.first { $0.serviceName == room.id }
            pin = earlier?.hostPin.map(ServerPin.pinned) ?? .firstJoin
            targets = [room]
        }
        var dialed: (transport: any RoomTransport, target: DiscoveredRoom)?
        var failures: [RoomConnectionError] = []
        for target in targets {
            do {
                let transport = try await deps.dial(target.endpoint, pin)
                guard attempt == joinAttempt else {
                    transport.close()
                    return
                }
                dialed = (transport, target)
                break
            } catch {
                guard attempt == joinAttempt else { return }
                failures.append(error)
            }
        }
        guard let (transport, target) = dialed else {
            if failures.contains(.localNetworkDenied) {
                localNetworkDenied = true
                join = .refused(room, .localNetworkDenied)
            } else if failures.contains(.identityChanged) {
                join = .refused(room, invite == nil ? .identityChanged : .notTheInvitedRoom)
                // R3.8: the saved row shows the changed identity; the pin is never replaced here.
                if invite == nil, let earlier { note(.identityChanged, for: earlier) }
            } else if let invite, invite.isExpired(now: deps.now()) {
                // `x` is advisory (the host may have extended): it only explains a room that is gone.
                join = .refused(room, .inviteExpired)
            } else {
                join = .refused(room, .unreachable)
            }
            return
        }
        joinTransport = transport
        let result = await deps.runJoin(transport, code, guestName, deps.model, fg, invite?.check)
        let address = transport.remoteEndpoint
        transport.close()
        if attempt == joinAttempt { joinTransport = nil }

        switch result {
        case .failure(let refusal):
            if refusal == .wrongCode {
                wrongInARow += 1
                if wrongInARow >= Self.lockoutAfter {
                    wrongInARow = 0
                    lockedUntil = deps.now().addingTimeInterval(Self.lockout)
                }
            }
            if attempt == joinAttempt { join = .refused(room, refusal) }
        case .success(let joined):
            wrongInARow = 0
            rejoining = nil
            self.invite = nil
            var lastHost = ""
            var port: UInt16 = 0
            if case .hostPort(let host, let hostPort)? = address {
                lastHost = "\(host)"
                port = hostPort.rawValue
            }
            // The host chooses these words: shown like a TXT record, never with bidi or control characters.
            let entry = SavedRoom(hostFingerprint: Fingerprint.prefix + joined.hostPin.hex, deviceId: joined.deviceId, room: TXTSanitizer.clean(joined.hello.room),
                                  host: TXTSanitizer.clean(joined.hello.host), site: TXTSanitizer.clean(joined.hello.site), serviceName: target.id, lastHost: lastHost, port: port,
                                  localPort: earlier?.localPort, joinedAt: deps.now(), salt: joined.hello.salt)
            if let old = forwarders.removeValue(forKey: entry.id) { old.stop() }
            deps.rooms.save(entry)
            saved = deps.rooms.load()
            health[entry.id] = .unknown
            // Joined even if Cancel came late: the room is kept, only the seat sheet is not shown.
            guard attempt == joinAttempt else { return }
            await chooseSeat(entry)
        }
    }

    /// Lists the seats for a joined room (also how a guest switches seat later).
    func chooseSeat(_ room: SavedRoom) async {
        let attempt = joinAttempt
        do {
            let seats = try await withAPI(room) { api async throws(RoomAPIError) in try await api.seats() }
            guard attempt == joinAttempt else { return }
            join = .pickingSeat(room, seats)
        } catch {
            note(error, for: room)
            guard attempt == joinAttempt else { return }
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
        guard NetworkPanePresentation.canOpen(health[room.id]) else { return }
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

    /// `benchbar://share/<fp16>/app…`: opens a saved room only; false shows the pane instead,
    /// also for a room that cannot be opened (removed, a new room, ended, a changed key).
    func open(link: ShareDeepLink.Target) async -> Bool {
        guard let room = saved.first(where: { $0.hostPin.map(ShareDeepLink.fp16(of:)) == link.fp16 }),
              NetworkPanePresentation.canOpen(health[room.id]) else { return false }
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

    /// One `GET /_benchbar/hello` per saved room, all at once so a silent room cannot hold up
    /// the others. A failure after a good hello is "host gone"; 403 not_paired is "removed" or
    /// "a new room"; a changed key is never connected to again.
    func pingAll() async {
        await withTaskGroup(of: Void.self) { group in
            for room in saved where NetworkPanePresentation.canOpen(health[room.id]) {
                group.addTask { await self.ping(room) }
            }
        }
    }

    private func ping(_ room: SavedRoom) async {
        do {
            let hello = try await withAPI(room) { api async throws(RoomAPIError) in try await api.hello() }
            health[room.id] = .ready(deadline: Date(timeIntervalSince1970: TimeInterval(hello.deadline_epoch)))
            forwarders[room.id]?.show(nil)
        } catch .removed {
            set(await sameRoom(room) ? .removed : .newRoom, for: room)
        } catch {
            note(error, for: room)
        }
        if forwarders[room.id]?.stopIfIdle() == true { forwarders[room.id] = nil }
    }

    /// not_paired means removed, or a new room after a restart; only the pre-auth salt
    /// tells them apart. A row saved before the salt was kept reads as a new room.
    private func sameRoom(_ room: SavedRoom) async -> Bool {
        guard let salt = room.salt,
              let hello = try? await withAPI(room, { api async throws(RoomAPIError) in try await api.roomHello() }) else { return false }
        return hello.salt == salt
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
        set(state, for: room)
    }

    private func set(_ state: RoomHealth, for room: SavedRoom) {
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
    /// A TLS connection to a room with no client certificate and no pin.
    static let anonymousDial: @Sendable (NWEndpoint) async throws(RoomConnectionError) -> any RoomTransport = { endpoint throws(RoomConnectionError) in
        let connection = RoomConnection(endpoint: endpoint, identity: nil, pin: .firstJoin)
        try await connection.open()
        return connection
    }

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
            discoveryDial: anonymousDial,
            runJoin: { transport, code, name, model, fg, invite in
                await RoomJoin(name: name, model: model).join(over: transport, code: code, fg: fg, invite: invite)
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
            openURL: openURL,
            readPasteboard: { NSPasteboard.general.string(forType: .string) })
    }
}
