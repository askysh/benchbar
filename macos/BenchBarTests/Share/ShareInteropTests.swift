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
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        var line = Data()
        while !line.contains(0x0A) {
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            line.append(chunk)
        }
        info = try JSONDecoder().decode(Info.self, from: line)
    }

    var endpoint: NWEndpoint { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: info.port)!) }

    /// Stops only the process this test started.
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
}
