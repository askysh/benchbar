import Foundation

/// `benchbar site restore TARGET --from STAMP --dry-run --json`: the reviewed
/// plan of a restore (CLI 0.8.0) and the token `--apply TOKEN --yes` needs.
/// Read only: nothing is backed up, created or restored by reading it.
nonisolated struct SiteRestorePlan: ReviewablePlan, Codable {
    nonisolated struct Source: Codable, Sendable, Equatable {
        /// The site whose backups the stamp names; nil for a path.
        var site: String?
        /// nil when the stamp names no backup: the plan then has errors and cannot run.
        var set: SiteBackup?
        var restoresFiles: Bool
        var encryptionKey: Bool

        enum CodingKeys: String, CodingKey {
            case site, set
            case restoresFiles = "restores_files"
            case encryptionKey = "encryption_key"
        }
    }

    nonisolated struct BackupFirst: Codable, Sendable, Equatable {
        var willRun: Bool
        var withFiles: Bool
        var folder: String?

        enum CodingKeys: String, CodingKey {
            case folder
            case willRun = "will_run"
            case withFiles = "with_files"
        }
    }

    nonisolated struct Step: Codable, Sendable, Equatable, Identifiable {
        var id: String
        var name: String
        var touches: [String]
    }

    var schemaVersion: Int
    var bench: String
    var site: String
    /// `--new`: the site is created first, as a copy of the set.
    var new: Bool
    var exists: Bool
    var source: Source
    var backupFirst: BackupFirst
    var migrate: Bool
    var touches: [String]
    var steps: [Step]
    var warnings: [String]
    /// Inputs a terminal would ask for (MARIADB_ROOT_PASSWORD): an app run cannot answer them.
    var needs: [String]
    var errors: [String]
    var canApply: Bool
    var token: String
    /// `site rollback`: what the snapshot is and what is taken first (CLI 0.9.0); nil for a restore.
    var rollback: RollbackInfo? = nil

    enum CodingKeys: String, CodingKey {
        case bench, site, new, exists, source, migrate, touches, steps, warnings, needs, errors, token, rollback
        case schemaVersion = "schema_version"
        case backupFirst = "backup_first"
        case canApply = "can_apply"
    }

    var canRun: Bool { canApply && errors.isEmpty && needs.isEmpty }

    /// The plan's own words for what it changes, without the `hosts` line
    /// (the app never writes /etc/hosts) and the internal `common_site_config`.
    var touchesText: [String] {
        touches.compactMap { kind in
            switch kind {
            case "backup": String(localized: "a backup of \(site) with its files, first")
            case "database": new ? String(localized: "a new database for \(site)") : String(localized: "the database of \(site)")
            case "files": String(localized: "the public and private files of \(site)")
            case "site_config": String(localized: "sites/\(site)/site_config.json (the encryption key)")
            case "cache", "hosts", "common_site_config": nil
            default: kind
            }
        }
    }
}

nonisolated extension SiteRestorePlan {
    /// A tolerant read: the lists a newer CLI adds or an older one lacks are empty.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(schemaVersion: try c.decode(Int.self, forKey: .schemaVersion), bench: c.lenient(.bench, ""),
                  site: try c.decode(String.self, forKey: .site), new: c.lenient(.new, false), exists: c.lenient(.exists, false),
                  source: try c.decode(Source.self, forKey: .source),
                  backupFirst: c.lenient(.backupFirst, BackupFirst(willRun: false, withFiles: false, folder: nil)),
                  migrate: c.lenient(.migrate, true), touches: c.lenient(.touches, []), steps: c.lenient(.steps, []),
                  warnings: c.lenient(.warnings, []), needs: c.lenient(.needs, []), errors: c.lenient(.errors, []),
                  canApply: c.lenient(.canApply, false), token: try c.decode(String.self, forKey: .token),
                  rollback: c.lenient(.rollback, nil))
    }
}

/// What the sheet asks for: the site to restore into, the set and the options.
nonisolated struct SiteRestoreRequest: Equatable, Sendable {
    /// The site that gets the data: an existing one, or the name of the copy.
    var target: String
    var stamp: String
    /// The site whose backups hold the stamp: needed for a copy (`--new`).
    var fromSite: String
    var asNew: Bool
    var withFiles: Bool
    var noMigrate: Bool

    /// The arguments after `site restore`, shared by the plan and the apply.
    var arguments: [String] {
        var args = [target, "--from", stamp]
        if asNew || fromSite != target { args += ["--from-site", fromSite] }
        if asNew { args.append("--new") }
        if withFiles { args.append("--with-files") }
        if noMigrate { args.append("--no-migrate") }
        return args
    }
}
