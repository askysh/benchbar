import Foundation

/// Profile sharing through the CLI. Every source string has passed
/// `ProfileSourceRule` before it gets here, and names `ProfileName`.
extension CLIClient {
    /// `profile export NAME --plan --json`: read only, but it asks each
    /// remote for its default branch and access, so it can take a while.
    func profileExportPlan(_ name: String) async throws(CLIError) -> ProfileExportPlan {
        let output = try await run(["profile", "export", name, "--plan", "--json"], timeout: Timeout.action, acceptExitCodes: [0])
        return try BenchJSON.decode(ProfileExportPlan.self, from: Data(output.stdout.utf8))
    }

    /// Writes the profile to `file`. `choices` are the sheet's `--branch` and `--drop`.
    /// A refusal (exit 1 with `blocked`) comes back as `.failed` with the CLI's sentence.
    func exportProfile(_ name: String, to file: String, choices: [String]) async throws(CLIError) -> ProfileExportResult {
        let output = try await run(Self.exportArguments(name, to: file, choices: choices), timeout: Timeout.action, acceptExitCodes: [0, 1])
        guard output.exitCode == 0 else {
            if let refusal = try? JSONDecoder().decode(ProfileExportRefusal.self, from: Data(output.stdout.utf8)) {
                throw .failed(command: "profile export", exitCode: output.exitCode, message: refusal.error)
            }
            throw .failed(command: "profile export", exitCode: output.exitCode, message: Self.summarize(output))
        }
        return try BenchJSON.decode(ProfileExportResult.self, from: Data(output.stdout.utf8))
    }

    static func exportArguments(_ name: String, to file: String, choices: [String]) -> [String] {
        ["profile", "export", name, "--out", file] + choices + ["--yes", "--json"]
    }

    /// `profile import SRC [--as NAME] --plan --json`: fetches and checks, writes nothing.
    func profileImportPlan(_ source: String, as name: String?) async throws(CLIError) -> ProfileImportPlan {
        let output = try await run(Self.importArguments(source, as: name) + ["--plan", "--json"], timeout: Timeout.action, acceptExitCodes: [0])
        return try BenchJSON.decode(ProfileImportPlan.self, from: Data(output.stdout.utf8))
    }

    func importProfile(_ source: String, as name: String?) async throws(CLIError) -> ProfileImportResult {
        let output = try await run(Self.importArguments(source, as: name) + ["--yes", "--json"], timeout: Timeout.action, acceptExitCodes: [0])
        return try BenchJSON.decode(ProfileImportResult.self, from: Data(output.stdout.utf8))
    }

    static func importArguments(_ source: String, as name: String?) -> [String] {
        ["profile", "import", source] + (name.map { ["--as", $0] } ?? [])
    }

    /// Clones the repository into ~/.config/benchbar/sources; only its *.toml files are read.
    func subscribeProfiles(_ repo: String) async throws(CLIError) -> ProfileSubscribeResult {
        let output = try await run(["profile", "subscribe", repo, "--yes", "--json"], timeout: Timeout.action, acceptExitCodes: [0])
        return try BenchJSON.decode(ProfileSubscribeResult.self, from: Data(output.stdout.utf8))
    }

    func profileUpdatePlan(_ name: String) async throws(CLIError) -> ProfileUpdatePlan {
        let output = try await run(["profile", "update", name, "--plan", "--json"], timeout: Timeout.action, acceptExitCodes: [0])
        return try BenchJSON.decode(ProfileUpdatePlan.self, from: Data(output.stdout.utf8))
    }

    func updateProfile(_ name: String) async throws(CLIError) -> ProfileUpdatePlan {
        let output = try await run(["profile", "update", name, "--yes", "--json"], timeout: Timeout.action, acceptExitCodes: [0])
        return try BenchJSON.decode(ProfileUpdatePlan.self, from: Data(output.stdout.utf8))
    }

    /// Moves the imported file or the whole subscription aside, never deletes it.
    func removeProfile(_ name: String) async throws(CLIError) -> ProfileRemoveResult {
        let output = try await run(["profile", "remove", name, "--yes", "--json"], timeout: Timeout.action, acceptExitCodes: [0])
        return try BenchJSON.decode(ProfileRemoveResult.self, from: Data(output.stdout.utf8))
    }

    /// git ls-remote per repository with the user's own credentials.
    func checkProfile(_ name: String) async throws(CLIError) -> ProfileCheck {
        let output = try await run(["profile", "check", name, "--json"], timeout: Timeout.action, acceptExitCodes: [0, 1])
        return try BenchJSON.decode(ProfileCheck.self, from: Data(output.stdout.utf8))
    }
}
