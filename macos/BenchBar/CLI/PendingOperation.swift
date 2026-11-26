import Foundation

/// An `app update` or an `app add` that stopped part way, from
/// `status --json` (`pending_operations`, CLI 0.8). The CLI keeps the record
/// and the steps it did not finish; this app only shows it and offers the two
/// ways out the CLI has: run the steps again (resume), or drop the record.
nonisolated struct PendingOperation: Codable, Sendable, Equatable, Identifiable {
    nonisolated struct Step: Codable, Sendable, Equatable {
        var kind: String
        var target: String
        var name: String
    }

    /// `app_update` or `app_add`
    var op: String
    var app: String
    var branch: String?
    var from: String?
    var to: String?
    var steps: [Step]
    /// The kind of step it stopped at.
    var failedStep: String?
    var reason: String?
    var updatedAt: Date?

    var id: String { op + "|" + app }
    var isUpdate: Bool { op == "app_update" }

    enum CodingKeys: String, CodingKey {
        case op, app, branch, from, to, steps, reason
        case failedStep = "failed_step"
        case updatedAt = "updated_at"
    }

    /// "Update of erpnext stopped at migrate" (the step kinds are the CLI's words).
    var title: String {
        let what = isUpdate ? String(localized: "Update of \(app)") : op == "app_add" ? String(localized: "Adding \(app)") : String(localized: "\(op) of \(app)")
        guard let failed = failedStep, !failed.isEmpty else { return String(localized: "\(what) did not finish") }
        return String(localized: "\(what) stopped at \(failed.replacingOccurrences(of: "_", with: " "))")
    }

    /// The reason, then what is left: "bench migrate failed. Left to run: Migrate macdev, Build."
    var detail: String {
        var parts: [String] = []
        if let reason, !reason.isEmpty { parts.append(reason) }
        if !steps.isEmpty { parts.append(String(localized: "Left to run: \(steps.map(\.name).joined(separator: ", ")).")) }
        return parts.joined(separator: ". ").replacingOccurrences(of: "..", with: ".")
    }
}

nonisolated extension PendingOperation {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // never throws: one odd entry must not make the whole status unreadable (the view skips an empty app)
        self.init(op: c.lenient(.op, ""), app: c.lenient(.app, ""),
                  branch: c.lenient(.branch, nil), from: c.lenient(.from, nil), to: c.lenient(.to, nil),
                  steps: c.lenient(.steps, []), failedStep: c.lenient(.failedStep, nil), reason: c.lenient(.reason, nil),
                  updatedAt: c.lenient(.updatedAt, nil))
    }
}
