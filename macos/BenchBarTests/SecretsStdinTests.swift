import Foundation
import Testing
@testable import BenchBar

/// A CommandRunning fake that keeps the standard input of each call, and answers `commands --json` from a table.
nonisolated final class InputRecordingRunner: CommandRunning, @unchecked Sendable {
    struct Call {
        var arguments: [String]
        var environment: [String: String]
        var input: [UInt8]?
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let commandsJSON: String

    init(commandsJSON: String) { self.commandsJSON = commandsJSON }

    var calls: [Call] { lock.withLock { recorded } }

    func run(executable: URL, arguments: [String], environment: [String: String], timeout: Duration) async throws(CLIError) -> CommandOutput {
        try await run(executable: executable, arguments: arguments, environment: environment, timeout: timeout, qos: .default, input: nil)
    }

    func run(executable: URL, arguments: [String], environment: [String: String], timeout: Duration,
             qos: QualityOfService, input: [UInt8]?) async throws(CLIError) -> CommandOutput {
        lock.withLock { recorded.append(Call(arguments: arguments, environment: environment, input: input)) }
        if arguments == ["commands", "--json"] { return .ok(commandsJSON) }
        return .ok(#"{"schema_version":1,"cli_version":"0.9.0","event":"done","exit":0}"#)
    }

    func stream(executable: URL, arguments: [String], environment: [String: String], timeout: Duration,
                onLine: @escaping @Sendable (String) -> Void) async throws(CLIError) -> Int32 {
        try await stream(executable: executable, arguments: arguments, environment: environment, timeout: timeout, input: nil, onLine: onLine)
    }

    func stream(executable: URL, arguments: [String], environment: [String: String], timeout: Duration, input: [UInt8]?,
                onLine: @escaping @Sendable (String) -> Void) async throws(CLIError) -> Int32 {
        lock.withLock { recorded.append(Call(arguments: arguments, environment: environment, input: input)) }
        return 0
    }
}

/// The passwords of an install and of `site add` go to the CLI on its standard input (`--secrets-stdin`, askysh/benchbar#167) when
/// `commands --json` lists the flag for the command, and in the environment of an older CLI as before.
@Suite("Secrets on standard input")
struct SecretsStdinTests {
    static let withFlag = #"{"cli_version":"0.9.0","commands":[{"name":"install","flags":[{"name":"--secrets-stdin"}]},{"name":"site add","flags":[{"name":"--secrets-stdin"}]}]}"#
    static let withoutFlag = #"{"cli_version":"0.8.3","commands":[{"name":"install","flags":[{"name":"--yes"}]},{"name":"site add","flags":[]}]}"#

    let request = InstallRequest(benchDir: "/b", profile: "v15-lts", bundle: "minimal", site: "s")

    private func client(_ runner: InputRecordingRunner) -> CLIClient {
        CLIClient(executable: URL(fileURLWithPath: "/fake/benchbar"), runner: runner)
    }

    @Test func theListIsLinesEndedByAnEmptyLine() {
        #expect(CLIClient.secretList([("ADMIN_PASSWORD", "a b"), ("MARIADB_ROOT_PASSWORD", nil), ("OTHER", "x=y")])
                == Array("ADMIN_PASSWORD=a b\nOTHER=x=y\n\n".utf8))
        #expect(CLIClient.secretList([("ADMIN_PASSWORD", "é")]) == Array("ADMIN_PASSWORD=é\n\n".utf8))
        #expect(CLIClient.secretList([("ADMIN_PASSWORD", nil), ("MARIADB_ROOT_PASSWORD", "")]) == nil, "no password, no list")
        #expect(CLIClient.secretList([("ADMIN_PASSWORD", "a\nb")]) == nil, "a line break cannot be one line")
    }

    @Test func anInstallSendsThePasswordsOnStdinWhenTheCLIListsTheFlag() async throws {
        let runner = InputRecordingRunner(commandsJSON: Self.withFlag)
        _ = try await client(runner).install(request, adminPassword: "s3cret pw", rootPassword: "rootpw é", token: "tok") { _ in }
        let call = try #require(runner.calls.last { $0.arguments.starts(with: ["install", "--yes"]) })
        #expect(call.arguments.last == "--secrets-stdin")
        #expect(call.input == Array("ADMIN_PASSWORD=s3cret pw\nMARIADB_ROOT_PASSWORD=rootpw é\n\n".utf8))
        #expect(call.environment["ADMIN_PASSWORD"] == nil && call.environment["MARIADB_ROOT_PASSWORD"] == nil)
        #expect(call.environment["BENCHBAR_SUDO"] == "gui", "the dialog mode is not a secret and stays")
        #expect(!call.arguments.joined(separator: " ").contains("s3cret"))
    }

    @Test func theDryRunAndSiteAddDoToo() async throws {
        let runner = InputRecordingRunner(commandsJSON: Self.withFlag)
        _ = try? await client(runner).installPlan(request, adminPassword: "s3cret pw")
        let dry = try #require(runner.calls.first { $0.arguments.contains("--dry-run") })
        #expect(dry.arguments.last == "--secrets-stdin" && dry.input == Array("ADMIN_PASSWORD=s3cret pw\n\n".utf8))
        #expect(dry.environment["ADMIN_PASSWORD"] == nil)

        try await client(runner).addSite("v16", adminPassword: "s3cret pw", token: "t", bench: "/b")
        let add = try #require(runner.calls.first { $0.arguments.starts(with: ["site", "add"]) })
        #expect(add.arguments.contains("--secrets-stdin") && add.input == Array("ADMIN_PASSWORD=s3cret pw\n\n".utf8))
        #expect(add.environment["ADMIN_PASSWORD"] == nil)
    }

    @Test func anOlderCLIKeepsTheEnvironment() async throws {
        let runner = InputRecordingRunner(commandsJSON: Self.withoutFlag)
        _ = try await client(runner).install(request, adminPassword: "s3cret pw", rootPassword: "rootpw", token: nil) { _ in }
        let call = try #require(runner.calls.last { $0.arguments.starts(with: ["install", "--yes"]) })
        #expect(!call.arguments.contains("--secrets-stdin"))
        #expect(call.input == nil)
        #expect(call.environment["ADMIN_PASSWORD"] == "s3cret pw" && call.environment["MARIADB_ROOT_PASSWORD"] == "rootpw")

        try await client(runner).addSite("v16", adminPassword: "s3cret pw", token: "t", bench: "/b")
        let add = try #require(runner.calls.first { $0.arguments.starts(with: ["site", "add"]) })
        #expect(!add.arguments.contains("--secrets-stdin") && add.input == nil && add.environment["ADMIN_PASSWORD"] == "s3cret pw")
    }

    @Test func aCLIThatCannotAnswerCommandsKeepsTheEnvironment() async throws {
        let runner = InputRecordingRunner(commandsJSON: "not json")
        _ = try await client(runner).install(request, adminPassword: "s3cret pw", rootPassword: nil, token: nil) { _ in }
        let call = try #require(runner.calls.last { $0.arguments.starts(with: ["install", "--yes"]) })
        #expect(call.input == nil && call.environment["ADMIN_PASSWORD"] == "s3cret pw")
    }

    @Test func aPasswordWithALineBreakStaysOnTheEnvironmentPath() async throws {
        let runner = InputRecordingRunner(commandsJSON: Self.withFlag)
        _ = try await client(runner).install(request, adminPassword: "a\nb", rootPassword: nil, token: nil) { _ in }
        let call = try #require(runner.calls.last { $0.arguments.starts(with: ["install", "--yes"]) })
        #expect(call.input == nil && call.environment["ADMIN_PASSWORD"] == "a\nb" && !call.arguments.contains("--secrets-stdin"))
    }
}
