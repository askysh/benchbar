import Foundation

/// The Sharing tab's one primary button, from the status alone.
nonisolated enum SharePrimary: Equatable, Sendable {
    case setUp
    case turnOnProtection
    /// Start; `enabled` is false while a check is red.
    case start(enabled: Bool)
    case stop
    case updateCLI

    static func from(_ status: ShareStatus) -> SharePrimary {
        if status.needsNewerCLI { return .updateCLI }
        if status.state == .on || status.state == .starting { return .stop }
        if status.copy == nil { return .setUp }
        if status.lanGuard != .installed { return .turnOnProtection }
        return .start(enabled: SharePresentation.canStart(status))
    }

    var title: String {
        switch self {
        case .setUp: "Set up sharing"
        case .turnOnProtection: "Turn on network protection"
        case .start: "Start sharing"
        case .stop: "Stop"
        case .updateCLI: "Update"
        }
    }
}

/// Every word the host side shows. Pure, so it is tested without views.
nonisolated enum SharePresentation {
    static let durations = [1, 2, 4, 8, 12]
    static let newerCLI = "Sharing needs a newer BenchBar command line tool."
    static let codeNote = "Anyone on this Wi-Fi with the code can join. Remove people anytime."
    static let codeProves = "The code proves someone may join; it does not prove to them that this Mac is the host."
    static let liveUpdates = "Guests see changes after a page refresh."
    static let awake = "Keeping this Mac awake while sharing; closing the lid still ends it."
    static let locked = "Room locked: nobody new can join."
    static let full = "Room full: every seat is taken."
    static let budgetLocked = "Too many wrong codes; the room is locked. New code to reopen."
    static let joinTrouble = "Someone is having trouble joining — check the code."
    static let wipeOwed = "A sign-out is still owed in the copy. BenchBar retries it on the next room action."
    static let acknowledgement = "This copy contains real customer and employee data that your colleagues will be able to read."
    static let refreshConfirm = "Replaces the copy. Anything guests changed in it is lost."
    static let removedInCopy = "removed in the copy"
    static let peopleTitle = "People in the room"
    static let activityNote = "Guests are told this log exists."

    /// Start is allowed only with no red check (a missing check list counts as not red).
    static func canStart(_ status: ShareStatus) -> Bool {
        !(status.preflight?.checks.contains { $0.status == .fail } ?? false)
    }

    /// 3540 s → "59 min", 7260 → "2 h 1 min", 30 → "less than a minute".
    static func countdown(_ seconds: Int) -> String {
        guard seconds >= 60 else { return "less than a minute" }
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        if hours == 0 { return "\(minutes) min" }
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
    }

    /// The popover and menu row while sharing is on.
    static func indicator(_ status: ShareStatus) -> String {
        "Sharing on your network · \(status.devicesOnline) online · \(countdown(status.secondsLeft)) left"
    }

    static func stopConfirm(online: Int) -> String {
        switch online {
        case 0: "Stop sharing?"
        case 1: "Stop sharing? 1 person is connected and will be signed out."
        default: "Stop sharing? \(online) people are connected and will be signed out."
        }
    }

    /// Extend choices in minutes, none past `canExtendS`.
    static func extendOptions(canExtendS: Int) -> [(label: String, minutes: Int)] {
        [("+30 min", 30), ("+1 hour", 60)].filter { $0.minutes * 60 <= canExtendS }
    }

    static func protectionText(_ state: LanGuardState) -> String {
        switch state {
        case .installed: "Network protection is on."
        case .missing: "Network protection is off. It keeps the bench's own ports closed to the network."
        case .outdated: "Network protection needs an update."
        }
    }

    /// The button a red or amber check offers; nil for none.
    static func fixLabel(_ action: ShareFixAction) -> String? {
        switch action {
        case .none: nil
        case .installNetworkProtection: "Turn on network protection"
        case .allowNodeFirewall: "Allow…"
        case .openLocalNetworkSettings: "Open System Settings"
        case .updateCLI: "Update"
        case .rerunSetup: "Set up again"
        case .refreshCopy: "Refresh copy…"
        case .restartSharing: "Start again"
        }
    }

    /// A check's own words where the app has them; the CLI's message otherwise.
    static func checkTitle(_ check: ShareCheck) -> String {
        switch check.id {
        case "pf_active": "Network protection"
        case "local_network": "Local Network access for BenchBar"
        case "firewall_node": "The firewall lets sharing through"
        case "bench_redis_up": "The bench is running"
        case "share_web_lan_closed": "The copy is reachable only through BenchBar"
        default: check.id.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// The room's state line: the budget lock wins over a host lock or full.
    static func lockLine(_ status: ShareStatus) -> String? {
        if status.lockReason == .budget || status.budgetLeft == 0 { return budgetLocked }
        if status.lockReason == .full { return full }
        if status.locked == true { return locked }
        return nil
    }

    static func copyLine(_ copy: ShareCopy, relativeTo now: Date = Date()) -> String {
        let when = copy.ageS.map { "\(countdown($0)) ago" } ?? "earlier"
        return "Copy made \(when) from \(copy.sourceSite ?? "your site"). Guests' changes stay in the copy."
    }

    static let driftWarning = "Your apps changed since the copy was made. Guests see the copy's code, not your working tree; Refresh copy… to catch up."

    /// "Sam · MacBook Air · 192.168.1.31" (J18: name and model tell two Sams apart).
    static func personLine(_ person: SharePerson) -> String {
        [person.name, person.model, person.ip].compactMap { $0 }.joined(separator: " · ")
    }

    /// Online first, then the most recently seen.
    static func sorted(_ people: [SharePerson]) -> [SharePerson] {
        people.sorted { a, b in
            if a.online != b.online { return a.online }
            return (a.lastSeen ?? .distantPast) > (b.lastSeen ?? .distantPast)
        }
    }

    /// The seats `person` can move to: known seats nobody holds, by name.
    static func moveTargets(for person: SharePerson, people: [SharePerson], known: [String: String]) -> [(id: String, name: String)] {
        let held = Set(people.compactMap(\.seatID))
        return known.filter { !held.contains($0.key) && $0.key != person.seatID }
            .map { (id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func removeConfirm(_ person: SharePerson, site: String) -> String {
        "Remove \(person.name)? Closes their connections and signs them out of \(site)."
    }

    /// "Sam · sales-invoice · 09:30" from one activity line.
    static func activityLine(_ entry: ShareLogEntry, names: [String: String]) -> String {
        let who = entry.device.flatMap { names[$0] } ?? entry.user ?? "Someone"
        let parts = entry.path.split(separator: "/")
        let doctype = parts.count >= 2 && parts[0] == "app" ? String(parts[1]) : entry.path
        let time = entry.ts.map { $0.formatted(date: .omitted, time: .shortened) } ?? ""
        return [who, doctype, time].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The setup sheet's choices and when its button may run.
nonisolated struct ShareSetupForm: Equatable, Sendable {
    var site: String
    var picked: Set<String> = []
    var backupNow = true
    var acknowledged = false
    var freeGB: Double?
    var neededGB: Double?

    var shortOnDisk: Bool {
        guard let freeGB, let neededGB else { return false }
        return freeGB < neededGB
    }

    var canRun: Bool { !picked.isEmpty && acknowledged && !shortOnDisk && !site.isEmpty }

    func request(refresh: Bool) -> ShareSetupRequest {
        ShareSetupRequest(site: site, users: picked.sorted(), backupNow: backupNow, refresh: refresh)
    }

    static func sourceLabel(backupNow: Bool, estMinutes: Int?, backupAgeS: Int?) -> String {
        if backupNow { return "Copy my site as it is now (about \(estMinutes ?? 1) min)" }
        return "Use the backup from \(SharePresentation.countdown(backupAgeS ?? 0)) ago"
    }

    static func needs(_ gb: Double) -> String { "Needs about \(String(format: "%.1f", gb)) GB free" }
}
