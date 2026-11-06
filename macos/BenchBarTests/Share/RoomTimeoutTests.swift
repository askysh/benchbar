import Foundation
import Network
import Testing
@testable import BenchBar

/// Fixtures/silent-room.js: completes TLS, then never writes a byte.
nonisolated final class SilentRoomServer {
    struct Info: Decodable {
        var port: UInt16
        var fp: String
    }

    let info: Info
    private let process: Process
    private let stdin: Pipe

    init?() throws {
        guard NodeGateway.available, let node = NodeGateway.nodePath() else { return nil }
        process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [ShareRepo.macos.appendingPathComponent("BenchBarTests/Fixtures/silent-room.js").path, ShareRepo.root.path]
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

    func stop() {
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}

@Suite(.enabled(if: NodeGateway.available, "needs node and tests/share/helpers.js"))
struct RoomTimeoutTests {
    @Test(.timeLimit(.minutes(1))) func aRoomThatNeverAnswersTimesOut() async throws {
        guard let server = try SilentRoomServer() else {
            Issue.record("node or tests/share/helpers.js not found: the timeout was not run")
            return
        }
        defer { server.stop() }
        let scratch = try #require(ScratchKeychain())
        let identity = try KeychainIdentity(label: "timeout \(UUID().uuidString)", keychain: scratch.keychain).identity()
        let pin = try #require(Fingerprint.raw(fingerprint: server.info.fp))
        let connection = RoomConnection(endpoint: server.endpoint, identity: identity, pin: .pinned(pin), requestTimeout: 0.5)
        try await connection.open()
        defer { connection.close() }
        let started = Date()
        await #expect(throws: RoomConnectionError.timedOut) { _ = try await connection.send("GET", "/room/hello", body: nil) }
        #expect(Date().timeIntervalSince(started) < 5)
    }
}
