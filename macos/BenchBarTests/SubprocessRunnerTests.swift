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

    @Test func theBytesOfAnInputReachTheChildOnStdinAndInNoVariable() async throws {
        let input = Array("ADMIN_PASSWORD=pw one

".utf8)
        let output = try await SubprocessRunner().run(
            executable: sh, arguments: ["-c", "cat; echo ---; env; echo ---; echo \"$*\""],
            environment: ["PATH": "/usr/bin:/bin", "KEEP": "1"], timeout: .seconds(10), qos: .default, input: input)
        #expect(output.exitCode == 0)
        #expect(output.stdout.hasPrefix("ADMIN_PASSWORD=pw one

---
"))
        let rest = output.stdout.dropFirst("ADMIN_PASSWORD=pw one

".count)
        #expect(!rest.contains("pw one"), "the child's environment and arguments have no password")
        #expect(rest.contains("KEEP=1"))
    }

    @Test func aStreamCanSendInputToo() async throws {
        let box = LinesBox()
        let code = try await SubprocessRunner().stream(
            executable: sh, arguments: ["-c", "read a; read b; read c; echo \"$a|$b|$c\""], environment: [:], timeout: .seconds(10),
            input: Array("one
two

".utf8)) { box.add($0) }
        #expect(code == 0)
        #expect(box.lines == ["one|two|"])
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

    /// A shell that starts a child and waits (the CLI's shape: bash, then
    /// git or lsof). The child's pid goes to a file so the test can look at it.
    private func grandchildScript(pidFile: String) -> String {
        "sleep 60 & echo $! > '\(pidFile)'; wait"
    }

    private func readPid(_ path: String) async -> pid_t? {
        for _ in 0..<200 {
            if let text = try? String(contentsOfFile: path, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    /// True once the process is gone (kill with signal 0 only tests).
    private func goneSoon(_ pid: pid_t) async -> Bool {
        for _ in 0..<100 {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    @Test func timeoutStopsTheWholeProcessGroup() async throws {
        let dir = try TempDir()
        let pidFile = dir.url.appendingPathComponent("child.pid").path
        await #expect(throws: CLIError.timedOut(command: "-c", seconds: 1)) {
            try await SubprocessRunner().run(
                executable: sh, arguments: ["-c", grandchildScript(pidFile: pidFile)], environment: [:], timeout: .seconds(1))
        }
        let child = try #require(await readPid(pidFile))
        defer { kill(child, SIGKILL) }
        #expect(await goneSoon(child), "the grandchild outlived the timeout")
    }

    @Test func cancelStopsTheWholeProcessGroupAndSaysCancelled() async throws {
        let dir = try TempDir()
        let pidFile = dir.url.appendingPathComponent("child.pid").path
        let script = grandchildScript(pidFile: pidFile)
        let call = Task { [sh] in
            try await SubprocessRunner().run(executable: sh, arguments: ["-c", script], environment: [:], timeout: .seconds(30))
        }
        let child = try #require(await readPid(pidFile))
        defer { kill(child, SIGKILL) }
        call.cancel()
        let result = await call.result
        guard case .failure(let error) = result else { Issue.record("a cancelled call returned"); return }
        #expect(error as? CLIError == .cancelled(command: "-c"))
        #expect(await goneSoon(child), "the grandchild outlived the cancel")
    }

    @Test func cancelledStreamSaysCancelledAndStopsTheGroup() async throws {
        let dir = try TempDir()
        let pidFile = dir.url.appendingPathComponent("child.pid").path
        let script = "echo started; " + grandchildScript(pidFile: pidFile)
        let call = Task { [sh] in
            try await SubprocessRunner().stream(
                executable: sh, arguments: ["-c", script], environment: [:], timeout: .seconds(30), onLine: { _ in })
        }
        let child = try #require(await readPid(pidFile))
        defer { kill(child, SIGKILL) }
        call.cancel()
        let result = await call.result
        guard case .failure(let error) = result else { Issue.record("a cancelled stream returned"); return }
        #expect(error as? CLIError == .cancelled(command: "-c"))
        #expect(await goneSoon(child), "the grandchild outlived the cancel")
    }

    @Test func aTimeoutOfAStreamStopsTheGroup() async throws {
        let dir = try TempDir()
        let pidFile = dir.url.appendingPathComponent("child.pid").path
        await #expect(throws: CLIError.timedOut(command: "-c", seconds: 1)) {
            try await SubprocessRunner().stream(
                executable: sh, arguments: ["-c", grandchildScript(pidFile: pidFile)], environment: [:],
                timeout: .seconds(1), onLine: { _ in })
        }
        let child = try #require(await readPid(pidFile))
        defer { kill(child, SIGKILL) }
        #expect(await goneSoon(child), "the grandchild outlived the timeout")
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

/// The lines a stream handed over, collected from its callback.
nonisolated private final class LinesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    func add(_ line: String) { lock.withLock { all.append(line) } }
    var lines: [String] { lock.withLock { all } }
}
