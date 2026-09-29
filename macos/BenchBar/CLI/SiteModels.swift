import Foundation

/// One backup of a site: the files in its backup folder that share a
/// timestamp (`site backup`, `site backups` and `site drop`, CLI 0.5.8).
nonisolated struct SiteBackup: Codable, Sendable, Equatable, Identifiable {
    var stamp: String
    var time: Date?
    /// The database file, the one a restore needs.
    var path: String
    var database: String?
    var files: String?
    var privateFiles: String?
    var config: String?
    var sizeBytes: Int64
    var withFiles: Bool
    var encrypted: Bool
    var partial: Bool

    var id: String { stamp }

    /// Every part that exists, for Reveal in Finder.
    var parts: [String] { [database, files, privateFiles, config].compactMap { $0 } }

    enum CodingKeys: String, CodingKey {
        case stamp, time, path, database, files, config, encrypted, partial
        case privateFiles = "private_files"
        case sizeBytes = "size_bytes"
        case withFiles = "with_files"
    }
}

/// `benchbar site backups NAME --json`
nonisolated struct SiteBackupList: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var site: String
    var folder: String
    var backups: [SiteBackup]

    enum CodingKeys: String, CodingKey {
        case site, folder, backups
        case schemaVersion = "schema_version"
    }
}

/// `benchbar site backup NAME --json`
nonisolated struct SiteBackupResult: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var site: String
    var backup: SiteBackup?

    enum CodingKeys: String, CodingKey {
        case site, backup
        case schemaVersion = "schema_version"
    }
}

/// `benchbar site drop NAME --confirm-site NAME --dry-run --json`
nonisolated struct SiteDropPlan: Codable, Sendable, Equatable {
    nonisolated struct Step: Codable, Sendable, Equatable, Identifiable {
        var title: String
        var command: String
        var needsPassword: Bool
        var id: String { title }

        enum CodingKeys: String, CodingKey {
            case title, command
            case needsPassword = "needs_password"
        }
    }

    var schemaVersion: Int
    var site: String
    var isDefault: Bool
    var newDefault: String?
    var steps: [Step]

    enum CodingKeys: String, CodingKey {
        case site, steps
        case schemaVersion = "schema_version"
        case isDefault = "is_default"
        case newDefault = "new_default"
    }
}

/// `benchbar site drop NAME --confirm-site NAME --json`
nonisolated struct SiteDropResult: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var site: String
    var dropped: Bool
    var archivedPath: String?
    var backup: SiteBackup?
    var newDefault: String?
    var hostsRemoved: Bool
    /// The command that removes the hosts line by hand, when the CLI could not.
    var manualStep: String?

    enum CodingKeys: String, CodingKey {
        case site, dropped, backup
        case schemaVersion = "schema_version"
        case archivedPath = "archived_path"
        case newDefault = "new_default"
        case hostsRemoved = "hosts_removed"
        case manualStep = "manual_step"
    }
}
