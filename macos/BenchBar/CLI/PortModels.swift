import Foundation

nonisolated enum PortMode: String, Codable, Sendable, CaseIterable {
    case automatic, fixed
    var title: String { self == .automatic ? "Automatic" : "Fixed" }
}

nonisolated struct PortCheck: Codable, Sendable {
    let conflicts: [String]
    let mode: PortMode
    let alreadyRunning: Bool?
    enum CodingKeys: String, CodingKey { case conflicts, mode; case alreadyRunning = "already_running" }
}

nonisolated struct PortPlan: Codable, Sendable {
    let token: String
    let entries: [Entry]
    let canApply: Bool
    enum CodingKeys: String, CodingKey { case token, entries; case canApply = "can_apply" }

    struct Entry: Codable, Sendable, Identifiable {
        let path: String
        let name: String
        let site: String
        let mode: PortMode
        let current: BenchPorts
        let proposed: BenchPorts
        let conflicts: [String]
        let blocked: String?
        let serviceInstalled: Bool
        let setupPlan: String?
        var id: String { path }
        var currentURL: String { "http://\(site):\(current.web)" }
        var proposedURL: String { "http://\(site):\(proposed.web)" }
        var changesPorts: Bool {
            current.web != proposed.web || current.socketio != proposed.socketio ||
            current.redisQueue != proposed.redisQueue || current.redisCache != proposed.redisCache
        }
        enum CodingKeys: String, CodingKey {
            case path, name, site, mode, current, proposed, conflicts, blocked
            case serviceInstalled = "service_installed"
            case setupPlan = "setup_plan"
        }
    }
}
