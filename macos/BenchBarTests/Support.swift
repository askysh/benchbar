import Foundation
@testable import BenchBar

/// Loads a JSON file from BenchBarTests/Fixtures (copied into the test bundle).
nonisolated enum Fixture {
    private final class Token {}

    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: Token.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw FixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }

    static func string(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }

    enum FixtureError: Error { case missing(String) }
}

/// A CommandRunning fake: records every call and answers from a table.
nonisolated final class FakeRunner: CommandRunning, @unchecked Sendable {
    struct Call: Equatable {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private let respond: @Sendable ([String]) throws(CLIError) -> CommandOutput

    init(_ respond: @escaping @Sendable ([String]) throws(CLIError) -> CommandOutput) {
        self.respond = respond
    }

    var calls: [Call] { lock.withLock { _calls } }

    func run(executable: URL, arguments: [String], environment: [String: String], timeout: Duration) async throws(CLIError) -> CommandOutput {
        lock.withLock { _calls.append(Call(executable: executable.path, arguments: arguments, environment: environment)) }
        return try respond(arguments)
    }
}

nonisolated extension CommandOutput {
    static func ok(_ stdout: String) -> CommandOutput { CommandOutput(exitCode: 0, stdout: stdout, stderr: "") }
}

/// A temporary folder removed when the value goes away.
nonisolated final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("benchbar-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func write(_ relative: String, _ contents: String, executable: Bool = false) throws -> URL {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return file
    }
}
