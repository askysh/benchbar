import Foundation

// The host side of a room, as `benchbar share … --json` describes it.
// Every key past the few a share always has is decoded leniently: an older
// CLI that lacks one gives nil or a default, never a decoding failure.
// None of these types can hold the room code except `ShareCode`, which the
// store keeps in memory only (see ShareStore).

/// What a check's button does. A value this app does not know is `.none`:
/// the row then has no button rather than the CLI's own words.
nonisolated enum ShareFixAction: String, Codable, Sendable, Equatable, CaseIterable {
    case none
    case installNetworkProtection = "install_network_protection"
    case allowNodeFirewall = "allow_node_firewall"
    case openLocalNetworkSettings = "open_local_network_settings"
    case refreshCopy = "refresh_copy"
    case rerunSetup = "rerun_setup"
    case restartSharing = "restart_sharing"
    case updateCLI = "update_cli"

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ShareFixAction(rawValue: raw) ?? .none
    }
}

nonisolated enum ShareCheckStatus: String, Codable, Sendable, Equatable {
    case ok, warn, fail, skip

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ShareCheckStatus(rawValue: raw) ?? .warn
    }
}

/// One check of `share status --preflight` (`message` is the CLI's; the tab
/// shows its own words per `id` where it has them).
nonisolated struct ShareCheck: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var checkClass: String
    var status: ShareCheckStatus
    var message: String
    var fixAction: ShareFixAction

    enum CodingKeys: String, CodingKey {
        case id, status, message
        case checkClass = "class"
        case fixAction = "fix_action"
    }

    init(id: String, checkClass: String = "critical", status: ShareCheckStatus, message: String = "", fixAction: ShareFixAction = .none) {
        self.id = id
        self.checkClass = checkClass
        self.status = status
        self.message = message
        self.fixAction = fixAction
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        checkClass = try c.decodeIfPresent(String.self, forKey: .checkClass) ?? "critical"
        status = try c.decodeIfPresent(ShareCheckStatus.self, forKey: .status) ?? .warn
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        fixAction = (try? c.decodeIfPresent(ShareFixAction.self, forKey: .fixAction)) ?? ShareFixAction.none
    }
}

nonisolated struct SharePreflight: Codable, Sendable, Equatable {
    var ok: Bool
    var checks: [ShareCheck]
}

nonisolated struct ShareCopyApp: Codable, Sendable, Equatable {
    var app: String
    var atCopy: String?
    var now: String?

    enum CodingKeys: String, CodingKey {
        case app, now
        case atCopy = "at_copy"
    }
}

/// The hardened copy: when it was made, from which site, and whether the
/// apps moved since (`drifted`).
nonisolated struct ShareCopy: Codable, Sendable, Equatable {
    var made: String?
    var sourceSite: String?
    var ageS: Int?
    var drifted: Bool
    var apps: [ShareCopyApp]

    enum CodingKeys: String, CodingKey {
        case made, drifted, apps
        case sourceSite = "source_site"
        case ageS = "age_s"
    }

    init(made: String?, sourceSite: String?, ageS: Int?, drifted: Bool = false, apps: [ShareCopyApp] = []) {
        self.made = made
        self.sourceSite = sourceSite
        self.ageS = ageS
        self.drifted = drifted
        self.apps = apps
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        made = try c.decodeIfPresent(String.self, forKey: .made)
        sourceSite = try c.decodeIfPresent(String.self, forKey: .sourceSite)
        ageS = try c.decodeIfPresent(Int.self, forKey: .ageS)
        drifted = try c.decodeIfPresent(Bool.self, forKey: .drifted) ?? false
        apps = try c.decodeIfPresent([ShareCopyApp].self, forKey: .apps) ?? []
    }
}

nonisolated enum ShareState: String, Codable, Sendable, Equatable {
    case off, starting, on, expired, error

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ShareState(rawValue: raw) ?? .error
    }
}

nonisolated enum LanGuardState: String, Codable, Sendable, Equatable {
    case installed, missing, outdated

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LanGuardState(rawValue: raw) ?? .missing
    }
}

nonisolated enum ShareLockReason: String, Codable, Sendable, Equatable {
    case host, budget, full
}

/// `benchbar share status [--preflight] --json`. It never carries the code.
nonisolated struct ShareStatus: Codable, Sendable, Equatable {
    /// The room model (rooms, codes, seats) is protocol 3.
    static let roomProtocol = 3

    var protocolVersion: Int
    var state: ShareState
    var phase: String?
    var webUp: Bool?
    var degraded: String?
    var error: String?
    var site: String?
    var shareSite: String
    var label: String?
    var port: Int?
    var lanIP: String?
    var started: Date?
    var deadline: Date?
    var secondsLeft: Int
    var canExtendS: Int
    var copy: ShareCopy?
    var allowedUsers: [String]
    var seats: Int
    var people: Int
    var devicesOnline: Int
    var locked: Bool?
    var lockReason: ShareLockReason?
    var budgetLeft: Int?
    var joinTrouble: Bool
    var wipeFailed: Int
    var lanGuard: LanGuardState
    var preflight: SharePreflight?

    enum CodingKeys: String, CodingKey {
        case state, phase, degraded, error, site, label, port, started, deadline, copy, seats, people, locked, preflight
        case protocolVersion = "protocol"
        case webUp = "web_up"
        case shareSite = "share_site"
        case lanIP = "lan_ip"
        case secondsLeft = "seconds_left"
        case canExtendS = "can_extend_s"
        case allowedUsers = "allowed_users"
        case devicesOnline = "devices_online"
        case lockReason = "lock_reason"
        case budgetLeft = "budget_left"
        case joinTrouble = "join_trouble"
        case wipeFailed = "wipe_failed"
        case lanGuard = "lan_guard"
    }

    var isOn: Bool { state == .on }
    var needsNewerCLI: Bool { protocolVersion < Self.roomProtocol }

    init(protocolVersion: Int = ShareStatus.roomProtocol, state: ShareState, shareSite: String = "share.localhost",
         site: String? = "site1.localhost", label: String? = "Room", secondsLeft: Int = 0, canExtendS: Int = 0,
         copy: ShareCopy? = nil, allowedUsers: [String] = [], seats: Int = 0, people: Int = 0, devicesOnline: Int = 0,
         locked: Bool? = nil, lockReason: ShareLockReason? = nil, budgetLeft: Int? = nil, joinTrouble: Bool = false,
         wipeFailed: Int = 0, lanGuard: LanGuardState = .installed, preflight: SharePreflight? = nil) {
        self.protocolVersion = protocolVersion
        self.state = state
        self.shareSite = shareSite
        self.site = site
        self.label = label
        self.secondsLeft = secondsLeft
        self.canExtendS = canExtendS
        self.copy = copy
        self.allowedUsers = allowedUsers
        self.seats = seats
        self.people = people
        self.devicesOnline = devicesOnline
        self.locked = locked
        self.lockReason = lockReason
        self.budgetLeft = budgetLeft
        self.joinTrouble = joinTrouble
        self.wipeFailed = wipeFailed
        self.lanGuard = lanGuard
        self.preflight = preflight
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1
        state = try c.decodeIfPresent(ShareState.self, forKey: .state) ?? .off
        phase = try c.decodeIfPresent(String.self, forKey: .phase)
        webUp = try c.decodeIfPresent(Bool.self, forKey: .webUp)
        degraded = try c.decodeIfPresent(String.self, forKey: .degraded)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        site = try c.decodeIfPresent(String.self, forKey: .site)
        shareSite = try c.decodeIfPresent(String.self, forKey: .shareSite) ?? "share.localhost"
        label = try c.decodeIfPresent(String.self, forKey: .label)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        lanIP = try c.decodeIfPresent(String.self, forKey: .lanIP)
        started = try? c.decodeIfPresent(Date.self, forKey: .started)
        deadline = try? c.decodeIfPresent(Date.self, forKey: .deadline)
        secondsLeft = try c.decodeIfPresent(Int.self, forKey: .secondsLeft) ?? 0
        canExtendS = try c.decodeIfPresent(Int.self, forKey: .canExtendS) ?? 0
        copy = try c.decodeIfPresent(ShareCopy.self, forKey: .copy)
        allowedUsers = (try? c.decodeIfPresent([String].self, forKey: .allowedUsers)) ?? []
        seats = try c.decodeIfPresent(Int.self, forKey: .seats) ?? 0
        people = try c.decodeIfPresent(Int.self, forKey: .people) ?? 0
        devicesOnline = try c.decodeIfPresent(Int.self, forKey: .devicesOnline) ?? 0
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked)
        lockReason = try? c.decodeIfPresent(ShareLockReason.self, forKey: .lockReason)
        budgetLeft = try c.decodeIfPresent(Int.self, forKey: .budgetLeft)
        joinTrouble = try c.decodeIfPresent(Bool.self, forKey: .joinTrouble) ?? false
        wipeFailed = try c.decodeIfPresent(Int.self, forKey: .wipeFailed) ?? 0
        lanGuard = try c.decodeIfPresent(LanGuardState.self, forKey: .lanGuard) ?? .missing
        preflight = try c.decodeIfPresent(SharePreflight.self, forKey: .preflight)
    }
}

/// `benchbar share code [--new] --json`: the only document that holds the
/// code. Kept in memory by ShareStore; never encoded, logged or stored.
nonisolated struct ShareCode: Decodable, Sendable, Equatable {
    var code: String
    var isNew: Bool
    var budgetLeft: Int?

    enum CodingKeys: String, CodingKey {
        case code
        case isNew = "new"
        case budgetLeft = "budget_left"
    }

    init(code: String, isNew: Bool = false, budgetLeft: Int? = nil) {
        self.code = code
        self.isNew = isNew
        self.budgetLeft = budgetLeft
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        isNew = try c.decodeIfPresent(Bool.self, forKey: .isNew) ?? false
        budgetLeft = try c.decodeIfPresent(Int.self, forKey: .budgetLeft)
    }

    /// "482 913", as the host card shows it.
    var spaced: String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}

/// One person in the room (`share people --json`). No fingerprint, no user.
nonisolated struct SharePerson: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var model: String?
    var ip: String?
    var seatID: String?
    var seatFullName: String?
    var online: Bool
    var joined: Date?
    var lastSeen: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, model, ip, online, joined
        case seatID = "seat_id"
        case seatFullName = "seat_full_name"
        case lastSeen = "last_seen"
    }

    init(id: String, name: String, model: String? = nil, ip: String? = nil, seatID: String? = nil,
         seatFullName: String? = nil, online: Bool = true, joined: Date? = nil, lastSeen: Date? = nil) {
        self.id = id
        self.name = name
        self.model = model
        self.ip = ip
        self.seatID = seatID
        self.seatFullName = seatFullName
        self.online = online
        self.joined = joined
        self.lastSeen = lastSeen
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        model = try c.decodeIfPresent(String.self, forKey: .model)
        ip = try c.decodeIfPresent(String.self, forKey: .ip)
        seatID = try c.decodeIfPresent(String.self, forKey: .seatID)
        seatFullName = try c.decodeIfPresent(String.self, forKey: .seatFullName)
        online = try c.decodeIfPresent(Bool.self, forKey: .online) ?? false
        joined = try? c.decodeIfPresent(Date.self, forKey: .joined)
        lastSeen = try? c.decodeIfPresent(Date.self, forKey: .lastSeen)
    }
}

nonisolated struct SharePeople: Codable, Sendable, Equatable {
    var state: ShareState
    var people: [SharePerson]

    init(state: ShareState, people: [SharePerson]) {
        self.state = state
        self.people = people
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(ShareState.self, forKey: .state) ?? .off
        people = try c.decodeIfPresent([SharePerson].self, forKey: .people) ?? []
    }

    enum CodingKeys: String, CodingKey { case state, people }
}

/// A user of the site who could take a seat (`share users --json`).
nonisolated struct ShareUser: Codable, Sendable, Equatable, Identifiable {
    var name: String
    var fullName: String
    var enabled: Bool
    var userType: String
    var roles: [String]
    var codeCapableRoles: [String]
    var willDemote: Bool
    var selectable: Bool

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, enabled, roles, selectable
        case fullName = "full_name"
        case userType = "user_type"
        case codeCapableRoles = "code_capable_roles"
        case willDemote = "will_demote"
    }

    init(name: String, fullName: String? = nil, roles: [String] = [], codeCapableRoles: [String] = [], selectable: Bool = true) {
        self.name = name
        self.fullName = fullName ?? name
        enabled = true
        userType = "System User"
        self.roles = roles
        self.codeCapableRoles = codeCapableRoles
        willDemote = !codeCapableRoles.isEmpty
        self.selectable = selectable
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        fullName = try c.decodeIfPresent(String.self, forKey: .fullName) ?? name
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        userType = try c.decodeIfPresent(String.self, forKey: .userType) ?? "System User"
        roles = try c.decodeIfPresent([String].self, forKey: .roles) ?? []
        codeCapableRoles = try c.decodeIfPresent([String].self, forKey: .codeCapableRoles) ?? []
        willDemote = try c.decodeIfPresent(Bool.self, forKey: .willDemote) ?? !codeCapableRoles.isEmpty
        selectable = try c.decodeIfPresent(Bool.self, forKey: .selectable) ?? (enabled && userType == "System User")
    }
}

nonisolated struct ShareUsers: Codable, Sendable, Equatable {
    var site: String
    var users: [ShareUser]
    var truncated: Bool

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        site = try c.decodeIfPresent(String.self, forKey: .site) ?? ""
        users = try c.decodeIfPresent([ShareUser].self, forKey: .users) ?? []
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }

    enum CodingKeys: String, CodingKey { case site, users, truncated }
}

/// One line of the copy's activity log (`share log --json`).
nonisolated struct ShareLogEntry: Codable, Sendable, Equatable {
    var ts: Date?
    var device: String?
    var user: String?
    var method: String
    var path: String
    var status: Int?

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ts = try? c.decodeIfPresent(Date.self, forKey: .ts)
        device = try c.decodeIfPresent(String.self, forKey: .device)
        user = try c.decodeIfPresent(String.self, forKey: .user)
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        status = try c.decodeIfPresent(Int.self, forKey: .status)
    }

    enum CodingKeys: String, CodingKey { case ts, device, user, method, path, status }
}

nonisolated struct ShareLog: Codable, Sendable, Equatable {
    var entries: [ShareLogEntry]
    var truncated: Bool

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([ShareLogEntry].self, forKey: .entries) ?? []
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }

    enum CodingKeys: String, CodingKey { case entries, truncated }
}

/// `share setup --dry-run --json`: what the setup sheet shows before it runs.
nonisolated struct ShareSetupPlan: Codable, Sendable, Equatable {
    var site: String
    var users: [String]
    var sizeGB: Double
    var estMinutes: Int
    var sourceAgeS: Int?
    /// "User": 5, "Customer": 3: the kinds of real data the copy holds.
    var dataClasses: [String: Int]

    enum CodingKeys: String, CodingKey {
        case site, users
        case sizeGB = "size_gb"
        case estMinutes = "est_minutes"
        case sourceAgeS = "source_age_s"
        case dataClasses = "data_classes"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        site = try c.decodeIfPresent(String.self, forKey: .site) ?? ""
        users = (try? c.decodeIfPresent([String].self, forKey: .users)) ?? []
        sizeGB = (try? c.decodeIfPresent(Double.self, forKey: .sizeGB)) ?? 0
        estMinutes = try c.decodeIfPresent(Int.self, forKey: .estMinutes) ?? 0
        sourceAgeS = try c.decodeIfPresent(Int.self, forKey: .sourceAgeS)
        dataClasses = (try? c.decodeIfPresent([String: Int].self, forKey: .dataClasses)) ?? [:]
    }
}
