import Foundation

/// One notice of `status --json` `notices[]` (and `benchbar notices --json`): a
/// default that an update changed, the command or variable that switches it
/// back, and the page that explains it. The CLI owns the list; `id` is the
/// identity, every other field has a default.
nonisolated struct BenchNotice: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var title: String
    var text: String
    var switchBack: String
    var doc: String?
    var since: String?

    enum CodingKeys: String, CodingKey {
        case id, title, text, doc, since
        case switchBack = "switch_back"
    }
}

nonisolated extension BenchNotice {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        self.init(id: id, title: c.lenient(.title, id), text: c.lenient(.text, ""), switchBack: c.lenient(.switchBack, ""),
                  doc: c.lenient(.doc, nil), since: c.lenient(.since, nil))
    }

    /// What the banner says under its title: the text, then the way back.
    var banner: String {
        switchBack.isEmpty ? text : String(localized: "\(text)\n\nSwitch back: \(switchBack)")
    }
}

extension CLIClient {
    /// `notices --dismiss ID`: hides the notice for good, here and in the terminal list.
    func dismissNotice(_ id: String) async throws(CLIError) {
        _ = try await run(["notices", "--dismiss", id, "--json"], timeout: Timeout.query, acceptExitCodes: [0])
    }
}
