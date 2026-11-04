import Foundation

/// One experiment from `benchbar labs list --json`. The CLI owns the list and
/// the flags, so an experiment this build has never heard of still decodes.
nonisolated struct LabEntry: Codable, Sendable, Equatable, Identifiable {
    var name: String
    var title: String
    var description: String
    var warning: String
    var since: String
    var enabled: Bool
    var commands: [String]
    /// Absent from an older CLI, which then offers every lab everywhere.
    var platforms: [String]?
    var available: Bool?

    var id: String { name }
}

/// `benchbar labs list --json`.
nonisolated struct LabsDocument: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var labs: [LabEntry]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case labs
    }
}

/// The closing line of a command that changes things.
nonisolated struct DoneLine: Codable, Sendable, Equatable {
    var exit: Int?
    var changed: [String]?
    var warnings: [String]?
    var nextActions: [String]?

    enum CodingKeys: String, CodingKey {
        case exit, changed, warnings
        case nextActions = "next_actions"
    }

    /// The last line of stdout that is a JSON object; an empty line if there is none.
    static func parse(_ stdout: String) -> DoneLine {
        let decoder = JSONDecoder()
        for line in stdout.split(separator: "\n").reversed() {
            if let done = try? decoder.decode(DoneLine.self, from: Data(line.utf8)) { return done }
        }
        return DoneLine()
    }
}

/// Labs (experimental features) through the CLI. The CLI keeps the flags.
extension CLIClient {
    /// `labs list --json`. A CLI without the command exits non zero: `.failed`.
    func labs() async throws(CLIError) -> [LabEntry] {
        let output = try await run(["labs", "list", "--json"], timeout: Timeout.query, acceptExitCodes: [0])
        return try BenchJSON.decode(LabsDocument.self, from: Data(output.stdout.utf8)).labs
    }

    /// `labs on NAME` or `labs off NAME`.
    ///
    /// Like `site open-as on`: the CLI refuses `on` under BENCHBAR_NONINTERACTIVE=1
    /// and without a terminal so that no agent can turn an experiment on. Here
    /// the click is the person's decision (the warning is on the row): the
    /// call sets the mode to 0 and says it comes from the app with
    /// BENCHBAR_SUDO=gui. `--yes` skips only the CLI's own question.
    @discardableResult
    func labsSet(name: String, on: Bool) async throws(CLIError) -> DoneLine {
        let output = try await run(["labs", on ? "on" : "off", name, "--yes", "--json"],
                                   timeout: Timeout.action, acceptExitCodes: [0],
                                   extraEnvironment: ["BENCHBAR_NONINTERACTIVE": "0"].merging(Self.guiSudo) { _, new in new })
        return DoneLine.parse(output.stdout)
    }
}
