import Foundation

/// The Sharing tab's one primary button, from the status alone.
nonisolated enum SharePrimary: Equatable, Sendable {
    case setUp
    /// A setup stopped halfway: the same sheet, as a refresh, finishes it.
    case finishSetup
    case turnOnProtection
    /// Start; `enabled` is false while a check is red.
    case start(enabled: Bool)
    case stop
    case updateCLI

    static func from(_ status: ShareStatus) -> SharePrimary {
        if status.needsNewerCLI { return .updateCLI }
        if status.state == .on || status.state == .starting { return .stop }
        if status.setupInterrupted { return .finishSetup }
        if status.copy == nil { return .setUp }
        if status.lanGuard != .installed { return .turnOnProtection }
        return .start(enabled: SharePresentation.canStart(status))
    }

    var title: String {
        switch self {
        case .setUp: "Set up sharing"
        case .finishSetup: "Finish setup"
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
    static let shareNearby = "Share with people nearby…"
    static let copyInvite = "Copy invite"
    static let copyInviteHelp = "Copies a message with a link that joins this room in one click, code included."
    static let inviteCopied = "Invite copied. Paste it in your team channel. New code or Stop makes it stop working."
    static let codeNote = "Anyone on this Wi-Fi with the code can join. Remove people anytime."
    static let codeProves = "The code proves someone may join; it does not prove to them that this Mac is the host."
    static let setUpIntro = "Share a copy of this site with people on the same Wi-Fi. Setup makes the copy; nothing is shared until you press Start sharing."
    static let liveUpdates = "Guests see changes after a page refresh."
    static let awake = "Keeping this Mac awake while sharing; closing the lid still ends it."
    static let locked = "Room locked: nobody new can join."
    static let full = "Room full: every seat is taken."
    static let budgetLocked = "Too many wrong codes; the room is locked. New code to reopen."
    static let joinTrouble = "Someone is having trouble joining. Check the code."
    static let wipeOwed = "A sign-out is still owed in the copy. BenchBar retries it on the next room action."
    static let acknowledgement = "This copy contains real customer and employee data that your colleagues will be able to read."
    static let refreshConfirm = "Replaces the copy. Anything guests changed in it is lost."
    static let removedInCopy = "removed in the copy"
    static let peopleTitle = "People in the room"
    static let activityNote = "Guests are told this log exists."

    /// Start is allowed only with no red check (a missing check list counts as not red), leaving out
    /// the checks of the running share: `share start` gates on its static checks alone.
    static func canStart(_ status: ShareStatus) -> Bool {
        !(status.preflight?.checks.contains { $0.status == .fail && !waitsForStart($0, status) } ?? false)
    }

    /// Checks that probe the gateway or the share web process. While sharing is off there is nothing to
    /// probe (the web checks read the last share's port and fail); the job runs them, failing closed,
    /// before it lets anyone in.
    static let checksOfTheRunningShare: Set<String> = ["gateway_reachable", "share_web_lan_closed", "share_traceback_off", "share_debugger_off"]
    static let checkedAtStart = "Checked when sharing starts"

    static func waitsForStart(_ check: ShareCheck, _ status: ShareStatus) -> Bool {
        !status.isOn && checksOfTheRunningShare.contains(check.id)
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

    /// The notice while a setup stopped halfway; the CLI says the same ("benchbar share setup --refresh").
    static let setupInterrupted = "Sharing setup was interrupted, so Start does not work yet. Choose Finish setup to refresh the copy (the command line: benchbar share setup --refresh)."

    /// Turning the lan-rooms lab off ends what it started: asks first only while something is live.
    /// `hosted` counts the benches sharing now, `online` the people connected to them, `joined` the
    /// rooms of other people this Mac has open.
    static func labOffConfirm(hosted: Int, online: Int, joined: Int) -> (message: String, detail: String)? {
        guard hosted > 0 || joined > 0 else { return nil }
        var ends: [String] = []
        if hosted > 0 {
            let people = switch online {
            case 0: "Nobody is connected now."
            case 1: "1 person is connected and will be signed out."
            default: "\(online) people are connected and will be signed out."
            }
            ends.append("Sharing stops and the room code stops working. \(people)")
        }
        if joined > 0 {
            ends.append(joined == 1 ? "The room you opened closes on this Mac." : "The \(joined) rooms you opened close on this Mac.")
        }
        return ("Turn off sharing on your network?", ends.joined(separator: " "))
    }

    /// The room code on the Sharing tab: dots until the host asks to see it.
    static func codeText(_ code: ShareCode?, revealed: Bool) -> String {
        guard revealed, let code else { return "••• •••" }
        return code.spaced
    }

    static func stopConfirm(online: Int) -> String {
        switch online {
        case 0: "Stop sharing?"
        case 1: "Stop sharing? 1 person is connected and will be signed out."
        default: "Stop sharing? \(online) people are connected and will be signed out."
        }
    }

    /// The restart fix ends the room (every device is deleted, R3.5) and starts one with a new code.
    static func restartConfirm(online: Int) -> (message: String, detail: String) {
        let message = switch online {
        case 0: "Restart sharing?"
        case 1: "Restart sharing? 1 person is connected and will be signed out."
        default: "Restart sharing? \(online) people are connected and will be signed out."
        }
        return (message, "Everyone in the room is disconnected and needs the new room code to join again.")
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
        case "lan_ip": "This Mac has a network address"
        case "gateway_reachable": "The gateway answers on the network"
        case "share_traceback_off": "Error traces are hidden in the copy"
        case "share_debugger_off": "The debugger is off in the copy"
        case "copy_present": "The shared copy is there"
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
    /// What the green or grey presence dot says in words.
    static func presenceText(online: Bool) -> String { online ? "Online" : "Offline" }

    /// What the check's icon says in words.
    static func checkStatusText(_ status: ShareCheckStatus) -> String {
        switch status {
        case .ok: "Passed"
        case .warn: "Warning"
        case .fail: "Failed"
        case .skip: "Skipped"
        }
    }

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

    /// The seats `person` can move to: known seats nobody holds, by name. `seats` (the room's own
    /// list) adds each seat's roles to its name, so the host sees what a seat may do before giving it.
    static func moveTargets(for person: SharePerson, people: [SharePerson], known: [String: String],
                            seats: [ShareSeat] = []) -> [(id: String, name: String)] {
        let held = Set(people.compactMap(\.seatID))
        let roles = Dictionary(seats.map { ($0.id, $0.roles) }, uniquingKeysWith: { first, _ in first })
        return known.filter { !held.contains($0.key) && $0.key != person.seatID }
            .map { (id: $0.key, name: seatTitle($0.value, roles: roles[$0.key] ?? [])) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func seatTitle(_ name: String, roles: [String]) -> String {
        guard !roles.isEmpty else { return name }
        let shown = roles.prefix(3).joined(separator: ", ")
        return roles.count > 3 ? "\(name) · \(shown) and \(roles.count - 3) more" : "\(name) · \(shown)"
    }

    // MARK: The host's key (#159 SHARE-8)

    /// "Host key: 0123 4567 89ab cdef": the digits a guest sees on the join sheet of an invite, for
    /// the host to read out. nil without 16 hex digits (no setup yet, or a CLI before 0.9.0).
    static func hostKeyLine(_ status: ShareStatus) -> String? {
        guard let key = status.hostKey, key.count == 16, key.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        let digits = Array(key)
        return "Host key: " + stride(from: 0, to: 16, by: 4).map { String(digits[$0..<$0 + 4]) }.joined(separator: " ")
    }
    static let hostKeyHelp = "A guest who joins from your invite link sees these digits before they join. Read them out when asked: a link that only uses your room's name shows other digits."

    // MARK: Who gives out the seats (#159 SHARE-5)

    static let assignSeatsToggle = "I give out the seats"
    /// On until the host turns it off: a guest waits for the host, as `share start` does by default.
    static let assignSeatsDefault = true
    static let seatsNeedNewerCLI = "Guests pick their own seat: this BenchBar command line tool is older than 0.9.0 and cannot start a room where you give out the seats."
    static let assignSeatsHelp = "On: a guest who joins waits until you give them a seat, and cannot take or change one. Off: anyone with the room code takes any free seat."

    /// Whether a room that is started again gives out its seats through the host: as the room that
    /// ran said, and by the stored switch when it did not say. Unknown never means open seats.
    static func restartAssignsSeats(mode: ShareSeatMode?, stored: Bool) -> Bool {
        switch mode {
        case .host?: true
        case .open?: false
        case nil: stored
        }
    }

    static func seatModeLine(hostGivesSeats: Bool) -> String {
        hostGivesSeats ? "You give out the seats: a guest who joins waits until you give them one."
            : "Guests pick their own seat: the room code lets them take any free one."
    }

    static func startDetail(site: String, assignSeats: Bool) -> String {
        "People on this Wi-Fi who have the room code can join a copy of \(site) until you stop. "
            + (assignSeats ? "They wait until you give each of them a seat." : "Each of them can take any free seat.")
    }

    static func seatCaption(_ person: SharePerson, hostGivesSeats: Bool) -> String {
        person.seatFullName ?? (hostGivesSeats ? "Waits for a seat from you" : "No seat yet")
    }

    static func seatMenuTitle(_ person: SharePerson) -> String {
        person.seatID == nil ? "Give a Seat" : "Move to"
    }

    /// The line above the people while somebody waits for the host.
    static func waitingNotice(people: [SharePerson], hostGivesSeats: Bool) -> String? {
        let waiting = people.filter { $0.seatID == nil }.count
        guard hostGivesSeats, waiting > 0 else { return nil }
        return waiting == 1 ? "1 person waits for a seat. Choose Give a Seat next to their name."
            : "\(waiting) people wait for a seat. Choose Give a Seat next to each name."
    }

    static func removeConfirm(_ person: SharePerson, site: String) -> String {
        "Remove \(person.name)? Closes their connections and signs them out of \(site)."
    }
    static let removeDetail = "They can't join again with the current code. Everyone else stays. To let them back in, copy a new invite and send it to them."
    static let copyNewInvite = "Copy new invite"

    static func removedNotice(_ name: String) -> String {
        "\(name) was removed. To let them back in, send a new invite."
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
