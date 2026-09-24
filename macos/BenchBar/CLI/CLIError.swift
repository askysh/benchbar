import Foundation

/// Everything that can go wrong between the app and the benchbar CLI.
/// Each case carries enough to show one clear sentence in the popover.
nonisolated enum CLIError: Error, Equatable, Sendable {
    /// No benchbar found in the setting, ~/.local/bin or Homebrew.
    case notFound(searched: [String])
    /// A path was configured but is not an executable file.
    case notExecutable(path: String)
    /// The process could not be started at all.
    case launchFailed(detail: String)
    /// The command ran longer than its timeout and was stopped.
    case timedOut(command: String, seconds: Int)
    /// The command exited with a non zero code.
    case failed(command: String, exitCode: Int32, message: String)
    /// stdout was not the JSON we expected.
    case invalidJSON(detail: String, preview: String)
    /// The CLI speaks a newer JSON schema than this app.
    case unsupportedSchema(found: Int, supported: Int)
}

extension CLIError: LocalizedError {
    nonisolated var errorDescription: String? {
        switch self {
        case .notFound:
            return "The benchbar command line tool was not found."
        case .notExecutable(let path):
            return "\(path) is not an executable file."
        case .launchFailed(let detail):
            return "Could not run benchbar: \(detail)"
        case .timedOut(let command, let seconds):
            return "benchbar \(command) did not finish within \(seconds) seconds."
        case .failed(let command, let code, let message):
            let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "benchbar \(command) failed (exit code \(code))." : text
        case .invalidJSON(let detail, _):
            return "benchbar returned output BenchBar could not read (\(detail))."
        case .unsupportedSchema(let found, let supported):
            return "benchbar speaks JSON schema \(found), this BenchBar understands \(supported). Update BenchBar."
        }
    }

    nonisolated var recoverySuggestion: String? {
        switch self {
        case .notFound(let searched):
            return "Looked in: \(searched.joined(separator: ", ")). Run the installer from the repo, or choose the file in Settings."
        case .notExecutable:
            return "Choose the benchbar file again in Settings."
        case .timedOut:
            return "Check the bench with benchbar doctor in Terminal."
        case .failed:
            return "Open the logs, or run benchbar doctor in Terminal."
        case .invalidJSON(_, let preview):
            return "Output started with: \(preview)"
        case .unsupportedSchema:
            return "Build BenchBar from the same checkout as the CLI."
        case .launchFailed:
            return nil
        }
    }
}
