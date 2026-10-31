import Foundation

/// `benchbar open --as USER --print-url --json`. `url` carries the session
/// id (a credential): it is read once for the session cache and never logged.
nonisolated struct OpenAsResult: Codable, Sendable, Equatable {
    var site: String
    var user: String
    var fullName: String?
    var userType: String
    var path: String
    var url: String?

    enum CodingKeys: String, CodingKey {
        case site, user, path, url
        case fullName = "full_name"
        case userType = "user_type"
    }
}

/// One row of `benchbar users --json`, roles most distinctive first.
nonisolated struct SiteUser: Codable, Sendable, Equatable, Identifiable {
    var name: String
    var fullName: String?
    var userType: String
    var roles: [String]
    var roleCount: Int
    var lastLogin: String?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, roles
        case fullName = "full_name"
        case userType = "user_type"
        case roleCount = "role_count"
        case lastLogin = "last_login"
    }
}

/// `benchbar users --json`.
nonisolated struct UserList: Codable, Sendable, Equatable {
    var site: String
    var users: [SiteUser]
    var truncated: Bool
}

/// The two CLI calls Open as makes, so tests need no process.
nonisolated protocol OpenAsCLI: Sendable {
    func openAs(bench: String, site: String, user: String, path: String?) async throws(CLIError) -> OpenAsResult
    func users(bench: String, site: String, search: String?, limit: Int) async throws(CLIError) -> UserList
}

extension CLIClient: OpenAsCLI {}
