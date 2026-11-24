import Foundation

/// Every line the "On your network" pane shows, from the guest store's state (R3.8 copy).
nonisolated enum NetworkPanePresentation {
    static let headerTitle = "On your network"
    static let headerSubtitle = "Rooms that colleagues on this Wi-Fi opened, and the ones you joined."
    static let title = "Rooms on this Wi-Fi"
    static let joinedSection = "Your rooms"
    static let nearbySection = "Nearby"
    static let findingText = "Looking for rooms on this Wi-Fi…"
    static let emptyText = "No rooms on this Wi-Fi right now. Ask a colleague to start sharing, or paste an invite."
    static let findRooms = "Find rooms"
    /// The pane's AppStorage key: the Local Network explanation was accepted. Until then
    /// nothing browses, so the macOS prompt never appears from the popover.
    static let explainedKey = "shareGuestExplained"
    static let localNetworkOff = "Local Network access is off for BenchBar."
    static let explanation = "BenchBar will ask macOS for Local Network access to find rooms your colleagues share on this Wi-Fi."
    static let seatTitle = "Pick a seat"
    static let shareYourOwn = "To share your own bench, turn on Sharing on its page."

    /// `{room} · {site}`: before joining, the TXT record is all there is (display only).
    static func nearbyRow(_ room: DiscoveredRoom) -> String {
        [room.display.label.isEmpty ? room.id : room.display.label, room.display.site].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    typealias NearbyState = GuestRoomStore.NearbyState

    static func nearbyState(_ hello: RoomHello?) -> NearbyState {
        guard let hello else { return .notAnswering }
        if hello.locked { return .locked }
        if hello.full { return .full }
        return .open
    }

    static func nearbyStateText(_ state: NearbyState) -> String {
        switch state {
        case .checking: return "Checking…"
        case .open: return "Open"
        case .locked: return "Locked"
        case .full: return "Full"
        case .notAnswering: return "Not answering"
        }
    }

    /// Room name; host · site; "3 of 5 seats taken". The hello's words are the host's,
    /// cleaned like a TXT record; before a hello only the TXT record is shown.
    static func nearbyLines(_ room: DiscoveredRoom, _ status: GuestRoomStore.NearbyStatus?) -> (title: String, detail: String, seats: String?) {
        guard let hello = status?.hello else { return (name(room), room.display.site, nil) }
        let title = TXTSanitizer.clean(hello.room)
        let detail = [TXTSanitizer.clean(hello.host), TXTSanitizer.clean(hello.site)].filter { !$0.isEmpty }.joined(separator: " · ")
        return (title.isEmpty ? name(room) : title, detail, seatsTaken(hello))
    }

    static func seatsTaken(_ hello: RoomHello) -> String {
        "\(min(max(hello.people, 0), max(hello.seats, 0))) of \(max(hello.seats, 0)) seats taken"
    }

    static func sortedNearby(_ rooms: [DiscoveredRoom], status: [String: GuestRoomStore.NearbyStatus]) -> [DiscoveredRoom] {
        func rank(_ room: DiscoveredRoom) -> Int {
            switch status[room.id]?.state ?? .checking {
            case .open: return 0
            case .checking: return 1
            case .locked: return 2
            case .full: return 3
            case .notAnswering: return 4
            }
        }
        return rooms.sorted { (rank($0), nearbyLines($0, status[$0.id]).title.lowercased(), $0.id) < (rank($1), nearbyLines($1, status[$1.id]).title.lowercased(), $1.id) }
    }

    static func popoverNearby(open: Int) -> String {
        "Rooms nearby (\(open) open)"
    }

    static func joinDisabledReason(_ room: DiscoveredRoom) -> String? {
        room.display.needsUpdate ? "Update BenchBar to join \(name(room))." : nil
    }

    static func codePrompt(_ room: DiscoveredRoom) -> String {
        "Enter the room code from \(name(room))"
    }

    static func joining(_ room: DiscoveredRoom) -> String {
        "Joining \(name(room))…"
    }

    private static func name(_ room: DiscoveredRoom) -> String {
        room.display.label.isEmpty ? room.id : room.display.label
    }

    static func refusal(_ refusal: JoinRefusal, host: String) -> String {
        switch refusal {
        case .invalidCode: return "The room code is 6 digits."
        case .wrongCode: return "That code didn't work. Check with \(host) and try again."
        case .locked: return "\(host) locked this room."
        case .full: return "This room is full."
        case .alreadyJoined: return "This Mac is already in \(host)'s room."
        case .blocked: return removedLine(host: host)
        case .expired: return "That took too long. Try the code again."
        case .rateLimited(let seconds): return "Too many tries. Wait \(seconds) seconds and try again."
        case .needsUpdate: return "Update BenchBar to join \(host)'s room."
        case .codeDidNotCheckOut: return "This room's code didn't check out. Ask \(host) for the code again."
        case .identityChanged: return identityChanged(host: host)
        case .unreachable: return "\(host)'s room didn't answer. Check that you're on the same Wi-Fi."
        case .localNetworkDenied: return localNetworkOff
        case .failed: return "Joining didn't work. Try again."
        case .inviteExpired: return "This invite has expired. Ask \(host)'s host for a new one."
        case .notTheInvitedRoom: return "This isn't the room in the invite."
        case .inviteOutOfDate: return "This invite is out of date (the host changed the code). Ask for a new one."
        }
    }

    /// A retry cannot help an invite that expired, went stale or points at another key.
    static func canRetry(_ refusal: JoinRefusal) -> Bool {
        switch refusal {
        case .inviteExpired, .notTheInvitedRoom, .inviteOutOfDate: return false
        default: return true
        }
    }

    static let pasteInvite = "Paste invite"
    static let pasteInviteHelp = "Reads the clipboard once, for a BenchBar invite your colleague sent."

    /// The name is the link's own words, so the headline says where it comes from.
    static func invitePrompt(_ room: DiscoveredRoom) -> String {
        "Join \u{201C}\(name(room))\u{201D} (the name the invite link gives)"
    }

    /// What the join sheet of an invite shows before Join (#159 SHARE-8). A link can come from a web
    /// page or a chat, and its label is whatever the link says: the address it leads to and the
    /// host's key are shown, so the guest can compare the key with the one the host reads out.
    static func inviteCheck(_ invite: ShareInvite, addressAllowed: Bool) -> (note: String, address: String, key: String) {
        let address: String
        if let a = invite.address {
            address = addressAllowed ? "Address: \(a.host):\(a.port)"
                : "Address: \(a.host):\(a.port) is not on a local network, so it is not used. The room is looked for by its name."
        } else {
            address = "Address: none in the link. The room is looked for by its name."
        }
        return ("This room and its name come from an invite link, not from your network. Join only if the key below is the Host key your host sees on their Sharing tab or in benchbar share status (BenchBar 0.9.0 or later shows it).",
                address, "Host key: " + keyGroups(invite.hostPin))
    }

    /// The first 16 hex digits of a host's key in groups of four, as the host's Sharing tab and
    /// `benchbar share status` show them.
    static func keyGroups(_ hostPin: Data) -> String {
        let hex = Array(ShareDeepLink.fp16(of: hostPin))
        return stride(from: 0, to: hex.count, by: 4).map { String(hex[$0..<min($0 + 4, hex.count)]) }.joined(separator: " ")
    }

    static func inviteProblem(_ problem: ShareInvite.Problem) -> String {
        switch problem {
        case .notFound: return "There's no BenchBar invite on the clipboard. Copy the whole invite message and try again."
        case .newerVersion: return "This invite needs a newer BenchBar."
        case .malformed: return "This invite link is incomplete. Ask for the invite again."
        }
    }

    static func identityChanged(host: String) -> String {
        ForwarderPage.identityChanged(host: host).message
    }

    static func health(_ state: GuestRoomStore.RoomHealth, host: String, now: Date) -> String {
        switch state {
        case .unknown: return "Connecting…"
        case .ready(let deadline): return "Ready · \(timeLeft(until: deadline, now: now))"
        case .hostGone(let seen): return "\(host) isn't sharing right now (last seen \(clock(seen)))."
        case .offline: return "\(host) isn't sharing right now."
        case .removed: return removedLine(host: host)
        case .newRoom: return "\(host) started a new room. Join with the new room code."
        case .ended: return "\(host) ended the room."
        case .identityChanged: return identityChanged(host: host)
        }
    }

    /// A removal holds only against the code the guest had: a new invite lets them join again.
    static func removedLine(host: String) -> String {
        "\(host) removed you from this room. Ask \(host) for a new invite to join again."
    }

    /// Forget (or Remove and Join Again) signs this Mac out of the room for good: asked first, like every host action.
    static func forgetConfirm(_ room: SavedRoom, identityChanged: Bool) -> (message: String, detail: String, button: String) {
        let message = identityChanged ? "Remove \(room.room) and join again?" : "Forget \(room.room)?"
        let detail = "This Mac signs out of the room and its seat, and the saved room and the host's key are deleted. "
            + "To join again, \(room.host) has to send a new code or invite."
        return (message, detail, identityChanged ? "Remove" : "Forget")
    }

    /// Open could not start the connection on this Mac (the loopback port is taken, or the forwarder failed).
    static func openFailed(host: String) -> String {
        "BenchBar could not open \(host)'s room: its local connection did not start. Another app may hold the port. Try Open again."
    }

    /// Open is offered only when the room can still be opened.
    static func canOpen(_ state: GuestRoomStore.RoomHealth?) -> Bool {
        switch state {
        case .removed?, .newRoom?, .ended?, .identityChanged?: return false
        default: return true
        }
    }

    /// Join (pinned to the saved key) when the seat is gone or the host is away; never for a
    /// changed key, which only Forget and a fresh join may replace (R3.8, J19).
    static func canRejoin(_ state: GuestRoomStore.RoomHealth?) -> Bool {
        switch state {
        case .removed?, .newRoom?, .ended?, .offline?, .hostGone?: return true
        default: return false
        }
    }

    static func timeLeft(until deadline: Date, now: Date) -> String {
        let minutes = max(0, Int(deadline.timeIntervalSince(now) / 60))
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min left" : "\(minutes) min left"
    }

    /// A saved room's headline. The site's name is there once the room told it (after the join).
    static func savedTitle(_ room: SavedRoom) -> String {
        [room.room, room.host, room.site].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func seatRow(_ seat: RoomSeat) -> (title: String, detail: String) {
        let roles = seat.roles.joined(separator: ", ")
        let title = roles.isEmpty ? seat.full_name : "\(seat.full_name) · \(roles)"
        return (title, seat.taken_by.map { "taken by \($0)" } ?? "")
    }

    static func seatRefusal(_ error: RoomAPIError, host: String) -> String {
        switch error {
        case .seatTaken: return "Someone took that seat. Pick another."
        case .hostAssigns: return "\(host) gives out the seats in this room. Ask \(host) for yours, then open the room."
        case .rateLimited: return "Too many seat changes. Wait a minute."
        case .removed: return removedLine(host: host)
        case .ended: return "\(host) ended the room."
        case .identityChanged: return identityChanged(host: host)
        case .unreachable: return "\(host) isn't sharing right now."
        case .refused: return "That seat isn't available."
        }
    }

    /// What the forwarder serves in place of the site for a room in this state.
    static func page(for state: GuestRoomStore.RoomHealth, host: String, askAgain: String) -> ForwarderPage? {
        switch state {
        case .removed: return .removed(host: host, askAgain: askAgain)
        case .ended, .newRoom: return .ended(host: host)
        case .identityChanged: return .identityChanged(host: host)
        case .hostGone(let seen): return .hostOffline(host: host, lastSeen: clock(seen))
        case .offline: return .hostOffline(host: host, lastSeen: "a while ago")
        case .unknown, .ready: return nil
        }
    }

    private static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
