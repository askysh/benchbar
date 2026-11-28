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

    enum CodingKeys: String, CodingKey {
        case name, title, description, warning, since, enabled, commands, platforms, available
    }
}

nonisolated extension LabEntry {
    /// `name` is the identity: every other field has a default, so a CLI that
    /// drops `since` does not make every experiment vanish.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        self.init(name: name, title: c.lenient(.title, name), description: c.lenient(.description, ""),
                  warning: c.lenient(.warning, ""), since: c.lenient(.since, ""), enabled: c.lenient(.enabled, false),
                  commands: c.lenient(.commands, []), platforms: c.lenient(.platforms, nil),
                  available: c.lenient(.available, nil))
    }
}

/// `benchbar labs list --json`.
nonisolated struct LabsDocument: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var labs: [LabEntry]
    /// Entries of `labs` that did not decode (not part of the JSON).
    var skipped: [String] = []

    init(schemaVersion: Int, labs: [LabEntry], skipped: [String] = []) {
        self.schemaVersion = schemaVersion
        self.labs = labs
        self.skipped = skipped
    }

    /// An entry that does not decode is left out; the others stay.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        let list = try c.lossyList(LabEntry.self, forKey: .labs)
        labs = list.items
        skipped = list.skipped
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case labs
    }
}

/// Labs (experimental features) through the CLI. The CLI keeps the flags.
extension CLIClient {
    /// `labs list --json`. A CLI without the command exits non zero: `.failed`.
    func labs() async throws(CLIError) -> [LabEntry] {
        let output = try await run(["labs", "list", "--json"], timeout: Timeout.query, acceptExitCodes: [0])
        let document = try BenchJSON.decode(LabsDocument.self, from: Data(output.stdout.utf8))
        reportSkipped("labs list", document.skipped)
        return document.labs
    }

    /// `labs on NAME` or `labs off NAME`.
    ///
    /// Like `site open-as on`: the CLI refuses `on` under BENCHBAR_NONINTERACTIVE=1
    /// and without a terminal so that no agent can turn an experiment on. Here
    /// the click is the person's decision (the warning is on the row): the
    /// call sets the mode to 0 and says it comes from the app with
    /// BENCHBAR_SUDO=gui. `--yes` skips only the CLI's own question.
    @discardableResult
    func labsSet(name: String, on: Bool) async throws(CLIError) -> ResultEnvelope {
        let output = try await run(["labs", on ? "on" : "off", name, "--yes", "--json"],
                                   timeout: Timeout.action, acceptExitCodes: [0],
                                   extraEnvironment: ["BENCHBAR_NONINTERACTIVE": "0"].merging(Self.guiSudo) { _, new in new })
        return output.envelope
    }
}
