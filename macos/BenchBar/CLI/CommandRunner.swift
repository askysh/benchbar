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
}

/// The real runner, built on Apple's swift-subprocess package.
///
/// - The program is always called by absolute path, never looked up on PATH.
/// - stdin is closed (no prompts can hang it), stdout and stderr are
///   collected up to 4 MB each.
/// - A timeout cancels the task; swift-subprocess then sends SIGTERM, waits
///   2 seconds, and sends SIGKILL.
nonisolated struct SubprocessRunner: CommandRunning {
    static let outputLimit = 4 * 1024 * 1024

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration
    ) async throws(CLIError) -> CommandOutput {
        let label = arguments.first ?? executable.lastPathComponent

        do {
            return try await withThrowingTaskGroup(of: CommandOutput.self) { group in
                group.addTask {
                    // PlatformOptions is not Sendable, so it is built inside the task
                    var options = PlatformOptions()
                    options.teardownSequence = [.gracefulShutDown(allowedDurationToNextStep: .seconds(2))]
                    let overrides = Dictionary(uniqueKeysWithValues: environment.map {
                        (Environment.Key(stringLiteral: $0.key), Optional($0.value))
                    })
                    let result = try await Subprocess.run(
                        .path(FilePath(executable.path)),
                        arguments: Arguments(arguments),
                        environment: .inherit.updating(overrides),
                        platformOptions: options,
                        output: .string(limit: Self.outputLimit),
                        error: .string(limit: Self.outputLimit)
                    )
                    let code: Int32
                    switch result.terminationStatus {
                    case .exited(let value): code = value
                    case .signaled(let signal): code = 128 + signal
                    }
                    return CommandOutput(
                        exitCode: code,
                        stdout: result.standardOutput,
                        stderr: result.standardError
                    )
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw CLIError.timedOut(command: label, seconds: Int(timeout.components.seconds))
                }
                guard let first = try await group.next() else {
                    throw CLIError.launchFailed(detail: "no result")
                }
                group.cancelAll()
                return first
            }
        } catch let error as CLIError {
            throw error
        } catch is CancellationError {
            throw .timedOut(command: label, seconds: Int(timeout.components.seconds))
        } catch {
            throw .launchFailed(detail: String(describing: error))
        }
    }
}
