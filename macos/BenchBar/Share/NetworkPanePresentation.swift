import Foundation

/// Every line the "On your network" pane shows, from the guest store's state (R3.8 copy).
nonisolated enum NetworkPanePresentation {
    static let title = "Rooms on this Wi-Fi"
    static let joinedSection = "Your rooms"
    static let nearbySection = "Nearby"
    static let findingText = "Looking for rooms on this Wi-Fi…"
    static let emptyText = "No rooms found. Ask your colleague to turn on Sharing in BenchBar."
    static let localNetworkOff = "Local Network access is off for BenchBar."
    static let explanation = "BenchBar will ask macOS for Local Network access to find rooms your colleagues share on this Wi-Fi."
    static let seatTitle = "Pick a seat"
    static let shareYourOwn = "To share your own bench, turn on Sharing on its page."

    /// `{room} · {site}`: before joining, the TXT record is all there is (display only).
    static func nearbyRow(_ room: DiscoveredRoom) -> String {
        [room.display.label.isEmpty ? room.id : room.display.label, room.display.site].filter { !$0.isEmpty }.joined(separator: " · ")
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
        case .blocked: return "\(host) removed you from this room."
        case .expired: return "That took too long. Try the code again."
        case .rateLimited(let seconds): return "Too many tries. Wait \(seconds) seconds and try again."
        case .needsUpdate: return "Update BenchBar to join \(host)'s room."
        case .codeDidNotCheckOut: return "This room's code didn't check out. Ask \(host) for the code again."
        case .identityChanged: return identityChanged(host: host)
        case .unreachable: return "\(host)'s room didn't answer. Check that you're on the same Wi-Fi."
        case .localNetworkDenied: return localNetworkOff
        case .failed: return "Joining didn't work. Try again."
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
        case .removed: return "\(host) removed you from this room."
        case .newRoom: return "\(host) started a new room. Join with the new room code."
        case .ended: return "\(host) ended the room."
        case .identityChanged: return identityChanged(host: host)
        }
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

    static func seatRow(_ seat: RoomSeat) -> (title: String, detail: String) {
        let roles = seat.roles.joined(separator: ", ")
        let title = roles.isEmpty ? seat.full_name : "\(seat.full_name) · \(roles)"
        return (title, seat.taken_by.map { "taken by \($0)" } ?? "")
    }

    static func seatRefusal(_ error: RoomAPIError, host: String) -> String {
        switch error {
        case .seatTaken: return "Someone took that seat. Pick another."
        case .rateLimited: return "Too many seat changes. Wait a minute."
        case .removed: return "\(host) removed you from this room."
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
