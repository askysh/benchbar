import Foundation
import Network
import Testing
@testable import BenchBar

/// The real Node gateway (tests/share/gateway_harness.js through helpers.startGateway) on a
/// random loopback port, joined from Swift over mTLS: CPace, the exporter, Ta and Tb, then
/// the seat calls on a pinned connection.
nonisolated final class NodeGateway {
    struct Info: Decodable {
        var port: UInt16
        var code: String
        var host_fp: String
        var seats: [String]
    }

    let info: Info
    private let process: Process
    private let stdin: Pipe
    private let stdout: Pipe
    private var unread = Data()

    /// Absolute paths: an xcodebuild test host's PATH may lack Homebrew.
    static func nodePath() -> String? {
        let candidates = ["/opt/homebrew/bin/node", "/opt/homebrew/opt/node@22/bin/node", "/usr/local/bin/node"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/node" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var available: Bool {
        nodePath() != nil && FileManager.default.fileExists(atPath: ShareRepo.root.appendingPathComponent("tests/share/helpers.js").path)
    }

    init?() throws {
        guard let node = Self.nodePath(),
              FileManager.default.fileExists(atPath: ShareRepo.root.appendingPathComponent("tests/share/helpers.js").path)
        else { return nil }
        process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [ShareRepo.macos.appendingPathComponent("BenchBarTests/Fixtures/room-gateway.js").path, ShareRepo.root.path]
        stdin = Pipe()
        stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        var buffer = Data()
        info = try JSONDecoder().decode(Info.self, from: Self.readLine(stdout, buffer: &buffer))
        unread = buffer
    }

    private static func readLine(_ pipe: Pipe, buffer: inout Data) -> Data {
        while !buffer.contains(0x0A) {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
        guard let newline = buffer.firstIndex(of: 0x0A) else { defer { buffer = Data() }; return buffer }
        let line = buffer[buffer.startIndex..<newline]
        buffer = Data(buffer[buffer.index(after: newline)...])
        return Data(line)
    }

    /// One control message to the gateway (the host's own channel), e.g. `status`.
    func control(_ op: String) throws -> [String: Any] {
        stdin.fileHandleForWriting.write(Data("{\"op\":\"\(op)\"}\n".utf8))
        return try JSONSerialization.jsonObject(with: Self.readLine(stdout, buffer: &unread)) as? [String: Any] ?? [:]
    }

    /// The host's wrong-code budget, as `share status` reads it.
    func budgetLeft() throws -> Int? {
        try control("status")["budget_left"] as? Int
    }

    var endpoint: NWEndpoint { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: info.port)!) }

    /// Stops only the process this test started.
    func stop() {
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}

/// Fixtures/peer-room.js: a room that records which client certificate each request showed.
nonisolated final class PeerRoomServer {
    struct Info: Decodable {
        var port: UInt16
        var fp: String
    }

    let info: Info
    private let process: Process
    private let stdin: Pipe
    private let stdout: Pipe

    init?() throws {
        guard NodeGateway.available, let node = NodeGateway.nodePath() else { return nil }
        process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [ShareRepo.macos.appendingPathComponent("BenchBarTests/Fixtures/peer-room.js").path, ShareRepo.root.path]
        stdin = Pipe()
        stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        info = try JSONDecoder().decode(Info.self, from: Self.line(stdout))
    }

    private static func line(_ pipe: Pipe) -> Data {
        var line = Data()
        while !line.contains(0x0A) {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            line.append(chunk)
        }
        return line
    }

    var endpoint: NWEndpoint { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: info.port)!) }

    /// The client SPKI SHA-256 (hex) of every request so far, "none" for no certificate.
    func seen() throws -> [String] {
        stdin.fileHandleForWriting.write(Data("seen\n".utf8))
        return try JSONDecoder().decode([String].self, from: Self.line(stdout))
    }

    func stop() {
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}

/// Skipped (not failed) where node or the repository's share tests are absent, as on CI.
@Suite(.serialized, .enabled(if: NodeGateway.available, "needs node and tests/share/helpers.js"))
struct ShareInteropTests {
    private func join(_ gateway: NodeGateway, identity: KeychainIdentity, code: String, pin: ServerPin = .firstJoin) async throws -> (Result<JoinedRoom, JoinRefusal>, RoomConnection) {
        let connection = RoomConnection(endpoint: gateway.endpoint, identity: try identity.identity(), pin: pin)
        try await connection.open()
        let joiner = RoomJoin(name: "Priya\u{2019}s Mac", model: "Mac14,2", makeMap: { () throws(CPace.Failure) in try CPaceMap(scriptURL: ShareRepo.mapScript) })
        let result = await joiner.join(over: connection, code: code, fg: Fingerprint.raw(spki: try identity.spkiDER()))
        return (result, connection)
    }

    @Test func swiftGuestJoinsTheNodeGatewayAndTakesASeat() async throws {
        guard let gateway = try NodeGateway() else {
            Issue.record("node or tests/share/helpers.js not found: the Node interop join was not run")
            return
        }
        defer { gateway.stop() }
        let scratch = try #require(ScratchKeychain())
        let identity = KeychainIdentity(label: "interop \(UUID().uuidString)", keychain: scratch.keychain)

        let (result, connection) = try await join(gateway, identity: identity, code: gateway.info.code)
        connection.close()
        let joined = try result.get()
        #expect(joined.deviceId.hasPrefix("d_"))
        #expect(joined.hostPin == Fingerprint.raw(fingerprint: gateway.info.host_fp))
        #expect(joined.hello.room == "Test Room")

        // Later connections are pinned to the Fh that Tb proved.
        let pinned = RoomConnection(endpoint: gateway.endpoint, identity: try identity.identity(), pin: .pinned(joined.hostPin))
        try await pinned.open()
        defer { pinned.close() }
        let api = RoomAPI(transport: pinned)
        let seats = try await api.seats()
        #expect(seats.map(\.seat_id) == gateway.info.seats)
        try await api.takeSeat("seat2")
        let roster = try await api.roster()
        #expect(roster.you == joined.deviceId)
        #expect(roster.people.first?.seat == "Seat 2")
        #expect(try await api.hello().device == joined.deviceId)

        // The browser path: loopback forwarder, pinned mTLS upstream, Host passed through.
        let localHost = LocalShareName.host(label: "Test Room", suffix: "1a2b3c4d", hostPin: joined.hostPin)
        let forwarder = ShareForwarder(localHost: localHost, port: 41000 + UInt16.random(in: 0...999), hostLabel: "Test Host",
                                       pin: joined.hostPin, makeUpstream: ShareForwarder.pinnedUpstream(to: gateway.endpoint, identity: identity, pin: joined.hostPin))
        try await forwarder.start()
        defer { forwarder.stop() }
        #expect(forwarder.signInURL()?.absoluteString == "http://\(localHost):\(forwarder.port)/_benchbar/signin?next=/app")
        let reply = await rawExchange(port: forwarder.port, "GET /_benchbar/hello HTTP/1.1\r\nHost: \(forwarder.expectedHost)\r\nAccept: application/json\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.1 200"))
        #expect(reply.contains(joined.deviceId))
        let signin = await rawExchange(host: "::1", port: forwarder.port, "GET /_benchbar/signin?next=/app HTTP/1.1\r\nHost: \(forwarder.expectedHost)\r\n\r\n")
        #expect(signin.hasPrefix("HTTP/1.1 302"))
        #expect(signin.contains("Set-Cookie: sid="))
    }

    @Test func wrongCodeIsRefusedAndAWrongPinNeverConnects() async throws {
        guard let gateway = try NodeGateway() else {
            Issue.record("node or tests/share/helpers.js not found: the Node interop join was not run")
            return
        }
        defer { gateway.stop() }
        let scratch = try #require(ScratchKeychain())
        let identity = KeychainIdentity(label: "interop \(UUID().uuidString)", keychain: scratch.keychain)
        let digits = Array(gateway.info.code)
        let wrong = String(digits.dropLast()) + String((Int(String(digits.last!))! + 1) % 10)

        let (result, connection) = try await join(gateway, identity: identity, code: wrong)
        connection.close()
        #expect(result == .failure(.wrongCode))

        var otherPin = try #require(Fingerprint.raw(fingerprint: gateway.info.host_fp))
        otherPin[0] ^= 0x01
        let pinned = RoomConnection(endpoint: gateway.endpoint, identity: try identity.identity(), pin: .pinned(otherPin))
        await #expect(throws: RoomConnectionError.identityChanged) { try await pinned.open() }
    }

    /// Nearby discovery shows no client certificate: the real gateway still answers its hello,
    /// a room that records certificates sees none, and a join dial still shows the real one.
    @Test func discoveryHellosShowNoIdentityAndJoinsStillDo() async throws {
        guard let gateway = try NodeGateway(), let peer = try PeerRoomServer() else {
            Issue.record("node or tests/share/helpers.js not found: the discovery identity check was not run")
            return
        }
        defer {
            gateway.stop()
            peer.stop()
        }
        let scratch = try #require(ScratchKeychain())
        let identity = KeychainIdentity(label: "interop \(UUID().uuidString)", keychain: scratch.keychain)
        let mine = Fingerprint.raw(spki: try identity.spkiDER()).hex

        let toGateway = try await GuestRoomStore.Dependencies.anonymousDial(gateway.endpoint)
        let hello = try await RoomAPI(transport: toGateway).roomHello()
        toGateway.close()
        #expect(hello.room == "Test Room")

        let toPeer = try await GuestRoomStore.Dependencies.anonymousDial(peer.endpoint)
        #expect(try await RoomAPI(transport: toPeer).roomHello().room == "Peer Room")
        toPeer.close()
        #expect(try peer.seen() == ["none"])

        // The join and saved-room dial (`dial` in the live store) shows the real identity.
        let joining = RoomConnection(endpoint: peer.endpoint, identity: try identity.identity(), pin: .firstJoin)
        try await joining.open()
        _ = try await RoomAPI(transport: joining).roomHello()
        joining.close()
        let seen = try peer.seen()
        #expect(seen == ["none", mine])
        #expect(seen.first != mine)

        // The gateway refuses a join on a connection with no certificate.
        let anonymous = try await GuestRoomStore.Dependencies.anonymousDial(gateway.endpoint)
        defer { anonymous.close() }
        let start = try await anonymous.send("POST", "/room/join/start", body: Data(#"{"v":3}"#.utf8))
        #expect(start.status == 403 && String(decoding: start.body, as: UTF8.self).contains("certificate_required"))
    }

    /// The pre-auth salt the invite's `s` is compared with.
    private func roomSalt(_ gateway: NodeGateway, identity: KeychainIdentity) async throws -> String {
        let connection = RoomConnection(endpoint: gateway.endpoint, identity: try identity.identity(), pin: .firstJoin)
        try await connection.open()
        defer { connection.close() }
        return try await RoomAPI(transport: connection).roomHello().salt
    }

    /// A stale invite (another salt) and an invite for another key both stop before the CPace
    /// start, so the host's wrong-code budget is not spent; a real wrong code shows the budget
    /// does move when a try is spent.
    @Test func aStaleOrForeignInviteNeverSpendsTheHostsBudget() async throws {
        guard let gateway = try NodeGateway() else {
            Issue.record("node or tests/share/helpers.js not found: the Node interop join was not run")
            return
        }
        defer { gateway.stop() }
        let scratch = try #require(ScratchKeychain())
        let identity = KeychainIdentity(label: "interop \(UUID().uuidString)", keychain: scratch.keychain)
        let hostPin = try #require(Fingerprint.raw(fingerprint: gateway.info.host_fp))
        let joiner = RoomJoin(name: "Asha", model: "Mac14,2", makeMap: { () throws(CPace.Failure) in try CPaceMap(scriptURL: ShareRepo.mapScript) })
        let fg = Fingerprint.raw(spki: try identity.spkiDER())
        let before = try #require(try gateway.budgetLeft())

        let staleSalt = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).hex
        #expect(staleSalt != (try await roomSalt(gateway, identity: identity)))
        let stale = RoomConnection(endpoint: gateway.endpoint, identity: try identity.identity(), pin: .pinned(hostPin))
        try await stale.open()
        let staleResult = await joiner.join(over: stale, code: gateway.info.code, fg: fg, invite: .init(hostPin: hostPin, salt: staleSalt))
        stale.close()
        #expect(staleResult == .failure(.inviteOutOfDate))
        #expect(try gateway.budgetLeft() == before)

        var otherPin = hostPin
        otherPin[0] ^= 0x01
        let foreign = RoomConnection(endpoint: gateway.endpoint, identity: try identity.identity(), pin: .firstJoin)
        try await foreign.open()
        let foreignResult = await joiner.join(over: foreign, code: gateway.info.code, fg: fg,
                                              invite: .init(hostPin: otherPin, salt: try await roomSalt(gateway, identity: identity)))
        foreign.close()
        #expect(foreignResult == .failure(.notTheInvitedRoom))
        #expect(try gateway.budgetLeft() == before)

        let digits = Array(gateway.info.code)
        let wrong = String(digits.dropLast()) + String((Int(String(digits.last!))! + 1) % 10)
        let (wrongResult, connection) = try await join(gateway, identity: identity, code: wrong)
        connection.close()
        #expect(wrongResult == .failure(.wrongCode))
        #expect(try gateway.budgetLeft() == before - 1)
    }

    /// The whole guest path from an invite link: the store opens the sheet, nothing is dialled
    /// until Join, then the join is pinned to `h` and lands on the seat picker, past `x` too.
    @Test func anInviteLinkJoinsTheNodeGatewayOnlyAfterJoinIsClicked() async throws {
        guard let gateway = try NodeGateway() else {
            Issue.record("node or tests/share/helpers.js not found: the Node interop join was not run")
            return
        }
        defer { gateway.stop() }
        let scratch = try #require(ScratchKeychain())
        let identity = KeychainIdentity(label: "interop \(UUID().uuidString)", keychain: scratch.keychain)
        let hostHex = String(gateway.info.host_fp.dropFirst(Fingerprint.prefix.count))
        let salt = try await roomSalt(gateway, identity: identity)
        // A past `x` (an extended share) does not stop a room that answers with `h` and `s`.
        let deadline = Int(Date().timeIntervalSince1970) - 600
        let link = "benchbar://share/join?v=1&r=Test%20Room&h=\(hostHex)&s=\(salt)&c=\(gateway.info.code)&a=127.0.0.1:\(gateway.info.port)&x=\(deadline)"
        let message = "Join my BenchBar room \"Test Room\" (office Wi-Fi, until 18:00)\n\(link)\nOr: open BenchBar → On your network → Paste invite"

        let defaults = UserDefaults(suiteName: "interop-invite-\(UUID().uuidString)")!
        let dials = DialLog()
        let store = GuestRoomStore(dependencies: .init(
            browser: NoBrowser(),
            rooms: SavedRoomsStore(defaults: defaults),
            dial: { endpoint, pin throws(RoomConnectionError) in
                try dials.record(pin)
                guard let secIdentity = try? identity.identity() else { throw .unreachable }
                let connection = RoomConnection(endpoint: endpoint, identity: secIdentity, pin: pin)
                try await connection.open()
                return connection
            },
            discoveryDial: GuestRoomStore.Dependencies.anonymousDial,
            runJoin: { transport, code, name, model, fg, invite in
                await RoomJoin(name: name, model: model, makeMap: { () throws(CPace.Failure) in try CPaceMap(scriptURL: ShareRepo.mapScript) })
                    .join(over: transport, code: code, fg: fg, invite: invite)
            },
            clientFingerprint: { (try? identity.spkiDER()).map(Fingerprint.raw(spki:)) },
            makeForwarder: { _ in FakeForwarder() },
            openURL: { _ in },
            readPasteboard: { message }), guestName: "Asha")

        store.pasteInvite()
        guard case .enteringCode(let room) = store.join, let invite = store.invite else {
            Issue.record("expected the invite's join sheet, got \(store.join)")
            return
        }
        #expect(dials.pins.isEmpty)
        #expect(invite.code == gateway.info.code)
        let before = try gateway.budgetLeft()

        await store.submit(code: invite.code, for: room)
        guard case .pickingSeat(let saved, let seats) = store.join else {
            Issue.record("expected the seat picker, got \(store.join)")
            return
        }
        let hostPin = try #require(Fingerprint.raw(fingerprint: gateway.info.host_fp))
        #expect(!dials.pins.isEmpty && dials.pins.allSatisfy { $0 == .pinned(hostPin) })
        #expect(saved.hostPin == hostPin)
        #expect(seats.map(\.seat_id) == gateway.info.seats)
        #expect(store.invite == nil)
        #expect(try gateway.budgetLeft() == before)
        #expect(!"\(defaults.dictionaryRepresentation())".contains(gateway.info.code))
    }
}
