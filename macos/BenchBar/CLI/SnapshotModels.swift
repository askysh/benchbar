import Foundation

/// Site snapshots (CLI 0.9.0): a backup with its files and the apps it was taken with,
/// kept in sites/NAME/snapshots, which frappe's pruning never touches. Every field a
/// newer CLI adds or an older one lacks is read as absent, never as a failed read.
nonisolated struct SiteSnapshot: Codable, Sendable, Equatable, Identifiable {
    nonisolated struct App: Codable, Sendable, Equatable {
        var name: String
        var commit: String?
        var branch: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            commit = c.lenient(.commit, nil)
            branch = c.lenient(.branch, nil)
        }

        enum CodingKeys: String, CodingKey { case name, commit, branch }
    }

    /// The folder name: the stamp of the backup, then the label as a slug.
    var id: String
    var site: String
    /// What the person called it; nil when none (the CLI prints an empty string, a mock prints "null").
    var label: String?
    var time: Date?
    var stamp: String
    var sizeBytes: Int64
    var withFiles: Bool
    var complete: Bool
    /// For a "before rollback" snapshot: the snapshot that rollback went to.
    var rollbackOf: String?
    /// The undo point of the last rollback of this site: dropping it leaves that rollback with no way back.
    var beforeRollback: Bool
    var apps: [App]
    /// nil when the manifest lists no apps.
    var appsMatch: Bool?
    var changedApps: [String]

    enum CodingKeys: String, CodingKey {
        case id, site, label, time, stamp, complete, apps
        case sizeBytes = "size_bytes"
        case withFiles = "with_files"
        case rollbackOf = "rollback_of"
        case beforeRollback = "before_rollback"
        case appsMatch = "apps_match"
        case changedApps = "changed_apps"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        site = c.lenient(.site, "")
        label = Self.text(c.lenient(.label, nil))
        time = c.lenient(.time, nil)
        stamp = c.lenient(.stamp, id)
        sizeBytes = c.lenient(.sizeBytes, 0)
        withFiles = c.lenient(.withFiles, false)
        complete = c.lenient(.complete, true)
        rollbackOf = Self.text(c.lenient(.rollbackOf, nil))
        beforeRollback = c.lenient(.beforeRollback, false)
        apps = (try? c.lossyList(App.self, forKey: .apps).items) ?? []
        appsMatch = c.lenient(.appsMatch, nil)
        changedApps = c.lenient(.changedApps, [])
    }

    private static func text(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "null" else { return nil }
        return value
    }

    /// "Before upgrade", else the stamp.
    var title: String { label ?? stamp }
}

/// `benchbar site snapshots NAME --json`, newest first.
nonisolated struct SiteSnapshotList: Codable, Sendable, Equatable {
    var site: String
    var snapshots: [SiteSnapshot]
    /// How many the bench keeps before it says so; nothing is removed on its own.
    var keep: Int
    var overLimit: [String]
    var totalBytes: Int64
    var freeBytes: Int64?

    enum CodingKeys: String, CodingKey {
        case site, snapshots, keep
        case overLimit = "over_limit"
        case totalBytes = "total_bytes"
        case freeBytes = "free_bytes"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        site = c.lenient(.site, "")
        snapshots = try c.lossyList(SiteSnapshot.self, forKey: .snapshots).items
        keep = c.lenient(.keep, 10)
        overLimit = c.lenient(.overLimit, [])
        totalBytes = c.lenient(.totalBytes, 0)
        freeBytes = c.lenient(.freeBytes, nil)
    }
}

/// `benchbar site snapshot NAME --json`: the snapshot just taken.
nonisolated struct SiteSnapshotResult: Codable, Sendable, Equatable {
    var snapshot: SiteSnapshot?
    var overLimit: [String]

    enum CodingKeys: String, CodingKey {
        case snapshot
        case overLimit = "over_limit"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = c.lenient(.snapshot, nil)
        overLimit = c.lenient(.overLimit, [])
    }
}

/// What a rollback plan says beyond a restore plan (`site rollback --dry-run --json`, key `rollback`).
nonisolated struct RollbackInfo: Codable, Sendable, Equatable {
    var snapshot: String
    var label: String?
    var time: Date?
    /// The label of the snapshot of the current state that is taken first.
    var snapshotFirst: String
    var appsMatch: Bool?
    var changedApps: [String]
    /// The site is the bench's default site: the CLI allows its rollback to a person only.
    var defaultSite: Bool

    enum CodingKeys: String, CodingKey {
        case snapshot, label, time
        case snapshotFirst = "snapshot_first"
        case appsMatch = "apps_match"
        case changedApps = "changed_apps"
        case defaultSite = "default_site"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = try c.decode(String.self, forKey: .snapshot)
        label = c.lenient(.label, nil)
        time = c.lenient(.time, nil)
        snapshotFirst = c.lenient(.snapshotFirst, "before rollback")
        appsMatch = c.lenient(.appsMatch, nil)
        changedApps = c.lenient(.changedApps, [])
        defaultSite = c.lenient(.defaultSite, false)
    }
}

/// `site rollback --apply TOKEN --yes --json`: where the way back is.
nonisolated struct RollbackResult: Decodable, Sendable, Equatable {
    var beforeRollback: String?
    var undo: String?
    var warnings: [String]

    enum CodingKeys: String, CodingKey {
        case rollback, warnings
    }

    /// A run that worked but printed nothing this build reads: no word about the undo point.
    init(beforeRollback: String? = nil, undo: String? = nil, warnings: [String] = []) {
        self.beforeRollback = beforeRollback; self.undo = undo; self.warnings = warnings
    }

    enum RollbackKeys: String, CodingKey {
        case beforeRollback = "before_rollback", undo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        warnings = c.lenient(.warnings, [])
        let inner = try? c.nestedContainer(keyedBy: RollbackKeys.self, forKey: .rollback)
        beforeRollback = inner?.lenient(.beforeRollback, nil)
        undo = inner?.lenient(.undo, nil)
    }
}

/// What the Snapshots sheet and the Roll Back sheet say, kept out of the views so a test can read it.
nonisolated enum SnapshotText {
    /// "Before upgrade, 3 hours ago, 5.2 MB, with files".
    static func line(_ snapshot: SiteSnapshot, now: Date) -> String {
        let age = snapshot.time.map { relativeAge(of: $0, now: now) } ?? snapshot.stamp
        let size = ByteCountFormatter.string(fromByteCount: snapshot.sizeBytes, countStyle: .file)
        return "\(age), \(size), \(snapshot.withFiles ? "with files" : "database only")"
    }

    /// "2 hours ago"; a clock that is a little behind must not say "in 2 minutes".
    static func relativeAge(of time: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: min(time, now), relativeTo: now)
    }

    /// Whether the bench's apps are the ones the snapshot was taken with.
    static func apps(_ snapshot: SiteSnapshot) -> String? {
        switch snapshot.appsMatch {
        case true?: "Same apps as now"
        case false?: snapshot.changedApps.isEmpty ? "The apps changed since" : "Apps changed since: \(snapshot.changedApps.joined(separator: ", "))"
        case nil: nil
        }
    }

    /// A label the CLI takes: up to 120 characters, no quotes, backslashes or control characters.
    static func labelProblem(_ label: String) -> String? {
        if label.count > 120 { return "At most 120 characters." }
        if label.contains(where: { $0 == "\"" || $0 == "'" || $0 == "\\" || $0.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F } }) {
            return "No quotes, backslashes or line breaks."
        }
        return nil
    }

    /// The site is the bench's default: the plan says so, and an older CLI without that field is compared with the status's default site.
    static func isDefaultSite(_ plan: SiteRestorePlan, benchDefault: String?) -> Bool {
        plan.rollback?.defaultSite == true || (benchDefault.map { !$0.isEmpty && $0 == plan.site } ?? false)
    }

    /// The warning that goes with rolling the default site back (the CLI allows it to a person only).
    static let defaultSiteNote = "This is the default site of the bench. BenchBar runs the rollback as you, not as an agent. The data of the site is replaced, as for any rollback."
}
