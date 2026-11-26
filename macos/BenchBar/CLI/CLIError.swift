import Foundation

/// Everything that can go wrong between the app and the benchbar CLI.
/// Each case carries enough to show one clear sentence in the popover.
nonisolated enum CLIError: Error, Equatable, Sendable {
    /// No benchbar found in Homebrew, ~/.local/bin or /usr/local/bin, and
    /// the Settings path (if any) is gone.
    case notFound(searched: [String])
    /// The Settings path exists but is not an executable file.
    case notExecutable(path: String)
    /// The process could not be started at all.
    case launchFailed(detail: String)
    /// The command ran longer than its timeout and was stopped.
    case timedOut(command: String, seconds: Int)
    /// The caller stopped waiting (its task was cancelled) and the command
    /// was stopped. Not a timeout: nothing is shown for it.
    case cancelled(command: String)
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
            return String(localized: "The benchbar command line tool was not found.")
        case .notExecutable(let path):
            return String(localized: "\(path) is not an executable file.")
        case .launchFailed(let detail):
            return String(localized: "Could not run benchbar: \(detail)")
        case .timedOut(let command, let seconds):
            return String(localized: "benchbar \(command) did not finish within \(seconds) seconds.")
        case .cancelled(let command):
            return String(localized: "benchbar \(command) was cancelled.")
        case .failed(let command, let code, let message):
            let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? String(localized: "benchbar \(command) failed (exit code \(code)).") : text
        case .invalidJSON(let detail, _):
            return String(localized: "benchbar returned output BenchBar could not read (\(detail)).")
        case .unsupportedSchema(let found, let supported):
            return String(localized: "benchbar speaks JSON schema \(found), this BenchBar understands \(supported). Update BenchBar.")
        }
    }

    /// The CLI's own answer to a command it does not have ("Unknown command: labs"), which is how
    /// an older CLI shows. One place, so the checks cannot drift apart.
    nonisolated var isUnknownCommand: Bool {
        if case .failed(_, _, let message) = self { return message.localizedCaseInsensitiveContains("unknown command") }
        return false
    }

    nonisolated var recoverySuggestion: String? {
        switch self {
        case .notFound(let searched):
            return String(localized: "Looked in: \(searched.joined(separator: ", ")). Install it with \(Homebrew.installCLI) (or the one line installer with --no-app), or choose the file in Settings.")
        case .notExecutable:
            return String(localized: "Choose the benchbar file again in Settings.")
        case .timedOut:
            return String(localized: "Check the bench with benchbar doctor in Terminal.")
        case .cancelled:
            return nil
        case .failed:
            return String(localized: "Open the logs, or run benchbar doctor in Terminal.")
        case .invalidJSON(_, let preview):
            return String(localized: "Output started with: \(preview)")
        case .unsupportedSchema:
            return String(localized: "Update BenchBar, or choose a different benchbar in Settings.")
        case .launchFailed:
            return nil
        }
    }
}
