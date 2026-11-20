import Foundation

/// `benchbar commands --json`: the commands and flags this CLI has. The app
/// offers a command only when it is listed here, so an older CLI never gets a
/// button that would fail ("Unknown command"). Read once per app session.
nonisolated struct CommandCatalog: Codable, Sendable, Equatable {
    nonisolated struct Command: Codable, Sendable, Equatable {
        var name: String
        var flags: [String]
    }

    var cliVersion: String?
    var commands: [Command]

    enum CodingKeys: String, CodingKey {
        case commands
        case cliVersion = "cli_version"
    }

    /// The CLI lists `name` ("service", "autostart", "lock write").
    func has(_ name: String) -> Bool { commands.contains { $0.name == name } }

    /// The CLI lists `name` with the flag `flag` ("up" with "--services-only").
    func hasFlag(_ name: String, _ flag: String) -> Bool {
        commands.first { $0.name == name }?.flags.contains(flag) ?? false
    }
}

nonisolated extension CommandCatalog {
    private struct FlagName: Decodable { var name: String? }

    private struct Entry: Decodable {
        var name: String?
        var flags: [FlagName]?
    }

    /// A command or flag without a name is left out; one that does not decode
    /// at all is skipped, so a newer CLI's shape never hides the others.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try c.lossyList(Entry.self, forKey: .commands).items
        self.init(cliVersion: c.lenient(.cliVersion, nil), commands: entries.compactMap { entry in
            entry.name.map { Command(name: $0, flags: (entry.flags ?? []).compactMap(\.name)) }
        })
    }
}

/// What the app knows of the CLI's commands: read at the first need, kept for the session. A failed read
/// is kept too, so the buttons stay away instead of the CLI being asked on every redraw.
nonisolated enum CommandCatalogState: Equatable, Sendable {
    case unread
    case known(CommandCatalog)
    case failed(String)

    var catalog: CommandCatalog? { if case .known(let catalog) = self { catalog } else { nil } }
}
