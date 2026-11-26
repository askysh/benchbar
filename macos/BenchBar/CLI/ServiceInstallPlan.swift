import Foundation

/// `benchbar service --dry-run --json`: the reviewed plan of installing or
/// refreshing the background service (CLI 0.8.0) and the token `--apply TOKEN
/// --yes` needs. The first line of the stream; read only.
nonisolated struct ServiceInstallPlan: ReviewablePlan, Codable {
    nonisolated struct Step: Codable, Sendable, Equatable, Identifiable {
        var n: Int
        /// write_procfile, write_runner, write_plist, write_helpers, write_cli_link or hosts_entry
        var id: String
        var name: String
        /// Needs the Mac's password: macOS's own dialog asks, once for the step.
        var sudo: Bool
        /// False when the file or line is already as it should be.
        var willRun: Bool

        enum CodingKeys: String, CodingKey { case n, id, name, sudo, willRun = "will_run" }
    }

    var bench: String
    var site: String?
    var profile: String?
    var portOffset: Int
    /// The plan moves the bench to another port block.
    var portsMove: Bool
    var steps: [Step]
    var token: String

    enum CodingKeys: String, CodingKey {
        case bench, site, profile, steps, token
        case portOffset = "port_offset"
        case portsMove = "ports_move"
    }

    var pending: [Step] { steps.filter(\.willRun) }
    var needsPassword: Bool { pending.contains(where: \.sudo) }
    var canRun: Bool { !token.isEmpty && !pending.isEmpty }

    /// The plan is the stream's `plan` event: the line that has a token.
    static func parse(stream: String) throws -> ServiceInstallPlan {
        for line in stream.split(separator: "\n") where line.contains("\"event\":\"plan\"") {
            return try BenchJSON.decode(ServiceInstallPlan.self, from: Data(line.utf8))
        }
        throw CLIError.failed(command: "service", exitCode: 0, message: String(localized: "benchbar service printed no plan."))
    }
}

nonisolated extension ServiceInstallPlan {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let list = try c.lossyList(Step.self, forKey: .steps)
        self.init(bench: try c.decode(String.self, forKey: .bench), site: c.lenient(.site, nil), profile: c.lenient(.profile, nil),
                  portOffset: c.lenient(.portOffset, 0), portsMove: c.lenient(.portsMove, false),
                  steps: list.items, token: try c.decode(String.self, forKey: .token))
    }
}
