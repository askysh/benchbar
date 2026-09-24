import Foundation
import Testing
@testable import BenchBar

@Suite("CLI client")
struct CLIClientTests {
    let executable = URL(fileURLWithPath: "/Users/you/.local/bin/benchbar")

    func client(_ runner: FakeRunner) -> CLIClient {
        var client = CLIClient(executable: executable, runner: runner)
        client.locator.home = URL(fileURLWithPath: "/Users/you")
        return client
    }

    @Test func statusPassesTheBenchAndAnExplicitPath() async throws {
        let json = try Fixture.string("status-running")
        let runner = FakeRunner { _ in .ok(json) }
        let status = try await client(runner).status(bench: "/Users/you/frappe-bench")
        #expect(status.state == .running)
        let call = try #require(runner.calls.first)
        #expect(call.executable == "/Users/you/.local/bin/benchbar")
        #expect(call.arguments == ["status", "--json", "--bench-dir", "/Users/you/frappe-bench"])
        let path = try #require(call.environment["PATH"])
        #expect(path.hasPrefix("/Users/you/.local/bin:"))
        #expect(path.contains("/opt/homebrew/bin"))
        #expect(path.contains("/usr/local/bin"))
        #expect(call.environment["NO_COLOR"] == "1")
    }

    @Test func listUsesJSON() async throws {
        let json = try Fixture.string("list")
        let runner = FakeRunner { _ in .ok(json) }
        let list = try await client(runner).list()
        #expect(list.benches.map(\.name) == ["frappe-bench", "v16"])
        #expect(runner.calls.first?.arguments == ["list", "--json"])
    }

    @Test func doctorAcceptsExitOneWithAReport() async throws {
        let json = try Fixture.string("doctor")
        let runner = FakeRunner { _ in CommandOutput(exitCode: 1, stdout: json, stderr: "") }
        let report = try await client(runner).doctor(bench: "/b")
        #expect(report.summary.fail == 1)
    }

    @Test func actionsArePlainAndNeverAssumeYes() async throws {
        let runner = FakeRunner { _ in .ok("[OK] bench is up") }
        for action in CLIClient.Action.allCases {
            try await client(runner).perform(action, bench: "/b")
        }
        #expect(runner.calls.map(\.arguments) == [
            ["up", "--plain", "--bench-dir", "/b"],
            ["down", "--plain", "--bench-dir", "/b"],
            ["restart", "--plain", "--bench-dir", "/b"],
        ])
        #expect(!runner.calls.flatMap(\.arguments).contains("--yes"))
    }

    @Test func failedActionCarriesTheFailLines() async throws {
        let stdout = """
          .. starting
          [WARN] another running bench uses the same port: com.benchbar.other:8000
          [WARN] Not a terminal and --yes not given; treating 'Start anyway?' as no.
        """
        let runner = FakeRunner { _ in CommandOutput(exitCode: 1, stdout: stdout, stderr: "") }
        await #expect {
            try await client(runner).perform(.up, bench: "/b")
        } throws: { error in
            guard case CLIError.failed(let command, let code, let message) = error else { return false }
            return command == "up" && code == 1 && message.contains("same port") && !message.contains(".. starting")
        }
    }

    @Test func statusNonZeroIsAFailure() async {
        let runner = FakeRunner { _ in CommandOutput(exitCode: 1, stdout: "", stderr: "Aborting. No bench at /nope") }
        await #expect {
            try await client(runner).status(bench: "/nope")
        } throws: { error in
            guard case CLIError.failed(_, _, let message) = error else { return false }
            return message.contains("No bench")
        }
    }

    @Test func runnerErrorsPassThrough() async {
        let runner = FakeRunner { _ throws(CLIError) in throw .timedOut(command: "status", seconds: 20) }
        await #expect(throws: CLIError.timedOut(command: "status", seconds: 20)) {
            try await client(runner).status(bench: "/b")
        }
    }
}
