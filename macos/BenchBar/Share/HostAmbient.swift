import Foundation

/// The host's ambient signals, pure: the menu bar state, the notice for
/// each room event, and the bench Stop/Restart confirmation while sharing.
nonisolated enum HostAmbient {
    enum IconState: Equatable, Sendable { case off, sharing, attention }

    /// `attention` when the room needs the host: locked by wrong codes, or join trouble.
    static func icon(_ statuses: [ShareStatus]) -> IconState {
        let on = statuses.filter(\.isOn)
        if on.isEmpty { return .off }
        return on.contains { $0.lockReason == .budget || $0.joinTrouble } ? .attention : .sharing
    }

    struct Notice: Equatable, Sendable {
        var title: String
        var body: String
        /// One per bench and kind: a newer reminder replaces the older banner.
        var identifier: String
    }

    /// The words for one event; nil for events that are not worth a banner.
    /// Built from names, models and addresses only: never the code (J14).
    static func notice(_ event: ShareEvent, bench: String) -> Notice? {
        switch event {
        case .joined(let name, let model, let ip):
            let line = [name, model, ip].compactMap { $0 }.joined(separator: " · ")
            return Notice(title: String(localized: "\(name) joined"),
                          body: String(localized: "\(line). Remove them from the Sharing tab if you did not expect this."),
                          identifier: "benchbar.share.joined.\(bench).\(line)")
        case .left(let name):
            return Notice(title: String(localized: "\(name) left"), body: String(localized: "\(name) is no longer in the room."), identifier: "benchbar.share.left.\(bench).\(name)")
        case .lockedByWrongCodes:
            return Notice(title: String(localized: "The room is locked"),
                          body: String(localized: "Someone typed a wrong room code 10 times. The room is locked. Unlock it, or draw a New code to reopen."),
                          identifier: "benchbar.share.budget.\(bench)")
        case .joinTrouble:
            return Notice(title: String(localized: "Someone is having trouble joining"),
                          body: String(localized: "Check the code. Someone is trying to join and not finishing."),
                          identifier: "benchbar.share.trouble.\(bench)")
        case .reminder(let minutes):
            return Notice(title: Wording.sharingEndsIn(minutes: minutes),
                          body: String(localized: "Extend it from the Sharing tab to keep the room open."), identifier: "benchbar.share.reminder.\(bench)")
        case .networkChanged:
            return Notice(title: String(localized: "Your network changed"), body: String(localized: "Checks are running again."), identifier: "benchbar.share.network.\(bench)")
        case .stateChanged:
            return nil
        }
    }

    /// The extra line of the bench Stop or Restart confirmation; nil when not sharing.
    static func benchConfirm(_ status: ShareStatus?, restart: Bool) -> String? {
        guard let status, status.isOn else { return nil }
        if status.devicesOnline > 0 {
            let online = Wording.guests(status.devicesOnline)
            return restart
                ? String(localized: "Sharing stays on, but guests see a short pause while the copy restarts (\(online) online).")
                : String(localized: "This also ends sharing (\(online) online).")
        }
        return restart
            ? String(localized: "Sharing stays on, but guests see a short pause while the copy restarts.")
            : String(localized: "This also ends sharing.")
    }
}
