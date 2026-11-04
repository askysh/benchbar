import Foundation
import Testing
@testable import BenchBar

/// Answers `labs list` and records `labs on/off`, with no process.
nonisolated final class FakeLabsBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var _sets: [String] = []
    private var _loads = 0
    var result: Result<[LabEntry], CLIError> = .success([])
    var setFailure: CLIError?

    var sets: [String] { lock.withLock { _sets } }
    var loads: Int { lock.withLock { _loads } }

    var loader: LabsLoader {
        LabsLoader(
            load: { [self] in
                lock.withLock { _loads += 1 }
                return try result.get()
            },
            set: { [self] name, on in
                if let setFailure { throw setFailure }
                lock.withLock { _sets.append("\(name):\(on)") }
            })
    }
}

@MainActor
@Suite struct LabsTests {
    static let fixture = """
    {"schema_version":1,"labs":[
     {"name":"lan-rooms","title":"Share with people on the same Wi-Fi","description":"d","warning":"w","since":"0.9.0","enabled":true,"commands":["share","lan-guard"]},
     {"name":"quick-switch","title":"Quick Switch panel","description":"d","warning":"w","since":"0.9.0","enabled":false,"commands":[],"platforms":["macos"],"available":false},
     {"name":"future-thing","title":"Future","description":"d","warning":"w","since":"1.0.0","enabled":true,"commands":[]}]}
    """

    static func entries() throws -> [LabEntry] {
        try BenchJSON.decode(LabsDocument.self, from: Data(fixture.utf8)).labs
    }

    @Test func decodesFixture() throws {
        let labs = try Self.entries()
        #expect(labs.count == 3)
        #expect(labs[0].commands == ["share", "lan-guard"])
        #expect(labs[0].since == "0.9.0")
        #expect(labs[0].platforms == nil && labs[0].available == nil)
        #expect(labs[1].platforms == ["macos"] && labs[1].available == false)
    }

    @Test func isOnAnswersForKnownCases() async throws {
        let backend = FakeLabsBackend()
        backend.result = .success(try Self.entries())
        let labs = Labs(loader: backend.loader)
        #expect(!labs.isOn(.lanRooms))
        await labs.refresh()
        #expect(labs.isOn(.lanRooms))
        #expect(!labs.isOn(.quickSwitch))
        #expect(labs.availability == .available)
    }

    @Test func unknownNameIsKept() async throws {
        let backend = FakeLabsBackend()
        backend.result = .success(try Self.entries())
        let labs = Labs(loader: backend.loader)
        await labs.refresh()
        #expect(labs.entries.map(\.name).contains("future-thing"))
    }

    @Test func missingCommandIsUnsupported() async {
        let backend = FakeLabsBackend()
        backend.result = .failure(.failed(command: "labs", exitCode: 1, message: "Unknown command"))
        let labs = Labs(loader: backend.loader)
        await labs.refresh()
        #expect(labs.availability == .unsupported)
        #expect(labs.entries.isEmpty)
    }

    @Test func setCallsLoaderAndFlipsState() async throws {
        let backend = FakeLabsBackend()
        backend.result = .success(try Self.entries())
        let labs = Labs(loader: backend.loader)
        await labs.refresh()
        try await labs.set(.quickSwitch, on: true)
        #expect(backend.sets == ["quick-switch:true"])
        #expect(labs.isOn(.quickSwitch))
        try await labs.set(.lanRooms, on: false)
        #expect(backend.sets.last == "lan-rooms:false")
        #expect(!labs.isOn(.lanRooms))
    }

    @Test func failedSetKeepsStateAndShowsError() async throws {
        let backend = FakeLabsBackend()
        backend.result = .success(try Self.entries())
        backend.setFailure = .failed(command: "labs", exitCode: 1, message: "Refused.")
        let labs = Labs(loader: backend.loader)
        await labs.refresh()
        await #expect(throws: CLIError.self) { try await labs.set(.quickSwitch, on: true) }
        #expect(!labs.isOn(.quickSwitch))
        #expect(labs.errors["quick-switch"] == "Refused.")
        #expect(labs.busy.isEmpty)
    }

    @Test func observeAllFires() async throws {
        let backend = FakeLabsBackend()
        backend.result = .success(try Self.entries())
        let labs = Labs(loader: backend.loader)
        var seen: [String] = []
        labs.observeAll { lab, on in seen.append("\(lab.rawValue):\(on)") }
        await labs.refresh()
        #expect(seen == ["lan-rooms:true"])
        try await labs.set(.quickSwitch, on: true)
        try await labs.set(.lanRooms, on: false)
        #expect(seen == ["lan-rooms:true", "quick-switch:true", "lan-rooms:false"])
    }

    @Test func observersOfOneLabBothFireAndCancelStopsOne() async throws {
        let backend = FakeLabsBackend()
        backend.result = .success(try Self.entries())
        let labs = Labs(loader: backend.loader)
        var first: [Bool] = []
        var second: [Bool] = []
        var other: [Bool] = []
        let token = labs.observe(.quickSwitch) { first.append($0) }
        labs.observe(.quickSwitch) { second.append($0) }
        labs.observe(.lanRooms) { other.append($0) }
        await labs.refresh()
        #expect(other == [true] && first.isEmpty && second.isEmpty)
        try await labs.set(.quickSwitch, on: true)
        #expect(first == [true] && second == [true] && other == [true])
        token.cancel()
        try await labs.set(.quickSwitch, on: false)
        #expect(first == [true] && second == [true, false])
    }

    @Test func refreshIsThrottled() async throws {
        let backend = FakeLabsBackend()
        backend.result = .success(try Self.entries())
        var clock = Date(timeIntervalSince1970: 1000)
        let labs = Labs(loader: backend.loader, now: { clock })
        await labs.refresh()
        clock += 2
        await labs.refresh()
        #expect(backend.loads == 1)
        clock += 4
        await labs.refresh()
        #expect(backend.loads == 2)
    }
}
