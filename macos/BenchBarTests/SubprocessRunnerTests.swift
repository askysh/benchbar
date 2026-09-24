import Foundation
import Testing
@testable import BenchBar

/// These start real processes through swift-subprocess.
@Suite("Subprocess runner")
struct SubprocessRunnerTests {
    let sh = URL(fileURLWithPath: "/bin/sh")

    @Test func collectsOutputAndExitCode() async throws {
        let output = try await SubprocessRunner().run(
            executable: sh, arguments: ["-c", "echo out; echo err >&2; exit 3"],
            environment: [:], timeout: .seconds(10))
        #expect(output.exitCode == 3)
        #expect(output.stdout == "out\n")
        #expect(output.stderr == "err\n")
    }

    @Test func passesTheEnvironment() async throws {
        let output = try await SubprocessRunner().run(
            executable: sh, arguments: ["-c", "printf %s \"$PATH|$NO_COLOR\""],
            environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "NO_COLOR": "1"], timeout: .seconds(10))
        #expect(output.stdout == "/opt/homebrew/bin:/usr/bin:/bin|1")
    }

    @Test func stdinIsClosedSoPromptsCannotHang() async throws {
        let output = try await SubprocessRunner().run(
            executable: sh, arguments: ["-c", "read answer; echo \"got:$answer\""],
            environment: [:], timeout: .seconds(10))
        #expect(output.stdout == "got:\n")
    }

    @Test func timeoutStopsTheProcess() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: CLIError.timedOut(command: "-c", seconds: 1)) {
            try await SubprocessRunner().run(
                executable: sh, arguments: ["-c", "sleep 30"], environment: [:], timeout: .seconds(1))
        }
        #expect(clock.now - start < .seconds(8))
    }

    @Test func missingProgramIsALaunchFailure() async {
        await #expect {
            try await SubprocessRunner().run(
                executable: URL(fileURLWithPath: "/nonexistent/benchbar"), arguments: [],
                environment: [:], timeout: .seconds(5))
        } throws: { error in
            if case CLIError.launchFailed = error { return true }
            return false
        }
    }
}
