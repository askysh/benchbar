import Foundation
import Subprocess
import System

/// What one finished command produced.
nonisolated struct CommandOutput: Sendable, Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

/// Runs a program and collects its output. A protocol so tests can swap in
/// a fake that returns fixture JSON without starting any process.
nonisolated protocol CommandRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration
    ) async throws(CLIError) -> CommandOutput

    /// The same at a quality of service: `.utility` for the queries the app
    /// makes on its own (status, list, ports check, app list), `.default`
    /// for what a person asked for.
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration,
        qos: QualityOfService
    ) async throws(CLIError) -> CommandOutput

    /// Runs a program and hands each line of stdout to `onLine` as it is
    /// written (repair --json streams its events). Returns the exit code.
    func stream(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws(CLIError) -> Int32
}

extension CommandRunning {
    /// Runners without a quality of service (the test fakes) ignore it.
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration,
        qos: QualityOfService
    ) async throws(CLIError) -> CommandOutput {
        try await run(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
    }

    /// For runners that cannot stream (the test fakes): run, then replay the lines.
    func stream(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws(CLIError) -> Int32 {
        let output = try await run(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
        for line in output.stdout.split(separator: "\n", omittingEmptySubsequences: true) { onLine(String(line)) }
        return output.exitCode
    }
}

/// The real runner, built on Apple's swift-subprocess package.
///
/// - The program is always called by absolute path, never looked up on PATH.
/// - stdin is closed (no prompts can hang it), stdout and stderr are
///   collected up to 4 MB each.
/// - The child leads a process group of its own, and a timeout or a cancel
///   signals the whole group: SIGTERM, then SIGKILL after 2 seconds. The CLI
///   starts its own long commands in groups of their own and forwards TERM to
///   them (benchbar, `fl_signal_traps_install`), so the TERM reaches them
///   through the CLI; the group is what stops a grandchild of a plain script
///   (a `git fetch` or `lsof` under a shell) that no trap knows.
/// - A timeout throws `.timedOut`. A caller that is cancelled gets
///   `.cancelled`, never a false "did not finish within N seconds".
/// - Each process gets one `.info` line in the log (Log.cli), with the
///   command word only: the rest may hold paths or names.
nonisolated struct SubprocessRunner: CommandRunning {
    static let outputLimit = 4 * 1024 * 1024

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration
    ) async throws(CLIError) -> CommandOutput {
        try await run(executable: executable, arguments: arguments, environment: environment, timeout: timeout, qos: .default)
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration,
        qos: QualityOfService
    ) async throws(CLIError) -> CommandOutput {
        let label = arguments.first ?? executable.lastPathComponent
        Self.log(label, qos)
        return try await Self.race(label: label, timeout: timeout) {
            // PlatformOptions is not Sendable, so it is built inside the task
            let result = try await Subprocess.run(
                .path(FilePath(executable.path)),
                arguments: Arguments(arguments),
                environment: Self.environment(environment),
                platformOptions: Self.platformOptions(qos: qos),
                output: .string(limit: Self.outputLimit),
                error: .string(limit: Self.outputLimit)
            )
            return CommandOutput(
                exitCode: Self.code(result.terminationStatus),
                stdout: result.standardOutput,
                stderr: result.standardError
            )
        }
    }

    func stream(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws(CLIError) -> Int32 {
        let label = arguments.first ?? executable.lastPathComponent
        Self.log(label, .default)
        return try await Self.race(label: label, timeout: timeout) {
            let result = try await Subprocess.run(
                .path(FilePath(executable.path)),
                arguments: Arguments(arguments),
                environment: Self.environment(environment),
                platformOptions: Self.platformOptions(qos: .default),
                input: .none,
                output: .sequence,
                error: .discarded
            ) { execution in
                // strings() splits on line breaks and buffers a partial
                // line (up to 128 KiB), so every call gets one whole event
                for try await line in execution.standardOutput.strings() {
                    onLine(line)
                }
            }
            return Self.code(result.terminationStatus)
        }
    }

    /// The work against a timer. The first to finish wins and the other is
    /// cancelled, which makes swift-subprocess tear the child's group down.
    /// A caller that was cancelled is told so, apart from a timeout.
    private static func race<T: Sendable>(
        label: String,
        timeout: Duration,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws(CLIError) -> T {
        do {
            return try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await work() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw CLIError.timedOut(command: label, seconds: Int(timeout.components.seconds))
                }
                guard let first = try await group.next() else {
                    throw CLIError.launchFailed(detail: "no result")
                }
                group.cancelAll()
                // cancelled while the child ran: its group was stopped, and what
                // came back is what a signal leaves, not an answer
                if Task.isCancelled { throw CLIError.cancelled(command: label) }
                return first
            }
        } catch let error as CLIError {
            throw error
        } catch is CancellationError {
            throw .cancelled(command: label)
        } catch {
            throw .launchFailed(detail: String(describing: error))
        }
    }

    private static func platformOptions(qos: QualityOfService) -> PlatformOptions {
        var options = PlatformOptions()
        // the child leads a new process group (setpgid(0, 0)): the teardown
        // signals it as a whole, and never the app's own group
        options.processGroupID = 0
        options.teardownSequence = [.gracefulShutDown(toProcessGroup: true, allowedDurationToNextStep: .seconds(2))]
        // utility: the child runs below the work a person waits for
        // (swift-subprocess sets only utility and background)
        options.qualityOfService = qos
        return options
    }

    private static func environment(_ overrides: [String: String]) -> Environment {
        .inherit.updating(Dictionary(uniqueKeysWithValues: overrides.map {
            (Environment.Key(stringLiteral: $0.key), Optional($0.value))
        }))
    }

    private static func code(_ status: TerminationStatus) -> Int32 {
        switch status {
        case .exited(let value): return value
        case .signaled(let signal): return 128 + signal
        }
    }

    private static func log(_ label: String, _ qos: QualityOfService) {
        Log.cli.info("cli: \(label, privacy: .public) (\(qos == .utility ? "utility" : "default", privacy: .public))")
    }
}
