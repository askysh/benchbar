import SwiftUI

/// What the "Open as…" menu lists and says, as plain values so the order, the
/// labels and the reasons are tested without a view.
nonisolated enum OpenAsMenuModel {
    enum Item: Equatable, Identifiable {
        case switchBack(user: String, title: String)
        case divider(Int)
        case pin(user: String, title: String, fullName: String?)
        case administrator
        /// Shown while nobody is pinned: says how to pin.
        case pinHint
        case findUser

        var id: String {
            switch self {
            case .switchBack: "switch-back"
            case .divider(let n): "divider-\(n)"
            case .pin(let user, _, _): "pin-\(user)"
            case .administrator: "administrator"
            case .pinHint: "pin-hint"
            case .findUser: "find-user"
            }
        }
    }

    static let noPinsHint = "Pin people from Find User… to switch to them here"

    /// What the opt-in alert says. The CLI says the same before it asks in a terminal.
    static let allowMessage = "Open as signs in to this site as any of its users, without a password.\n\n"
        + "Each sign in runs the apps' on_login and on_session_creation hooks, as a real login does: it sets last_login, "
        + "adds an Activity Log entry, mails the System Managers for Administrator and may create an ERPNext Customer or Supplier "
        + "for a Website User. It may end that user's oldest session.\n\n"
        + "Use it on development sites only."

    /// Whether the control is shown, and if it is shown but cannot be used, why.
    enum Availability: Equatable {
        /// Not opted in, no hosts line, an older CLI, or opted in on a site that cannot be used at all.
        case hidden
        case available
        /// Opted in on the default site, not usable now: shown disabled, with the reason as its tooltip.
        case disabled(String)
    }

    static func availability(_ row: SiteRow, benchRunning: Bool, benchName: String) -> Availability {
        guard row.openAsEnabled == true, !row.needsHosts else { return .hidden }
        if row.openAs == true { return benchRunning ? .available : .disabled("Start \(benchName) first") }
        // opted in but the CLI says open --as would refuse: only the default site can be explained here
        guard row.isDefault else { return .hidden }
        return .disabled(reasons(row).first ?? "Open as is not usable on \(row.name) now")
    }

    /// Why an opted-in site cannot be used, in the order to fix them.
    static func reasons(_ row: SiteRow) -> [String] {
        guard row.openAsEnabled == true, row.openAs != true else { return [] }
        var reasons: [String] = []
        if !row.developerModeKnown {
            reasons.append("Update the benchbar CLI to use Open as")
        } else if !row.developerMode {
            reasons.append("\(row.name) is not in developer mode. Run: bench --site \(row.name) set-config developer_mode 1")
        }
        if !row.isDefault {
            reasons.append("Only the default site can be used: port 8000 serves only it")
        } else if row.developerMode {
            reasons.append("The web process answers as another site. Run: benchbar site default \(row.name), then benchrestart")
        }
        return reasons
    }

    /// The line under a site's name in the Sites tab; nil while Open as is off.
    static func statusLine(_ row: SiteRow) -> (text: String, warning: Bool)? {
        guard row.openAsEnabled == true else { return nil }
        let why = reasons(row)
        if why.isEmpty { return ("Open as is on", false) }
        return ("Open as is on, but not usable. " + why.joined(separator: " "), true)
    }

    /// The pin's label, else the user's full name, else the user id.
    static func label(for user: String, fullName: String?, pins: [PinnedUser]) -> String {
        let pin = pins.first { $0.user == user }
        for candidate in [pin?.label, fullName, pin?.fullName] {
            if let text = candidate?.trimmingCharacters(in: .whitespaces), !text.isEmpty { return text }
        }
        return user
    }

    /// The popover key of each item that has one, by item id: ⇧⌘O Switch
    /// Back, ⌘0 Administrator, ⌘1 to ⌘9 the pins in menu order.
    static func shortcuts(_ items: [Item]) -> [String: OpenAsShortcut] {
        var keys: [String: OpenAsShortcut] = [:]
        var pinDigit = 0
        for item in items {
            switch item {
            case .switchBack: keys[item.id] = .switchBack
            case .administrator: keys[item.id] = .openAs(0)
            case .pin:
                pinDigit += 1
                keys[item.id] = .openAs(pinDigit)
            case .divider, .pinHint, .findUser: break
            }
        }
        return keys
    }

    /// `recents` is newest first: the first is who the browser is now, the
    /// second is where Switch Back goes.
    static func items(pins: [PinnedUser], recents: [RecentUser]) -> [Item] {
        var items: [Item] = []
        if let previous = recents.dropFirst().first {
            let label = label(for: previous.user, fullName: previous.fullName, pins: pins)
            items += [.switchBack(user: previous.user, title: "Switch Back to \(label)"), .divider(1)]
        }
        let pinned = pins.filter { $0.user != OpenAsStore.administrator }.prefix(OpenAsStore.maxPins)
        for pin in pinned {
            let label = label(for: pin.user, fullName: nil, pins: pins)
            items.append(.pin(user: pin.user, title: label == pin.user ? pin.user : "\(label) (\(pin.user))", fullName: pin.fullName))
        }
        items.append(.administrator)
        if pinned.isEmpty { items.append(.pinHint) }
        items += [.divider(2), .findUser]
        return items
    }
}

/// The "Open as…" control of a site row: switch to a pinned user,
/// Administrator or the one before, and find any user. Shown only where the
/// person turned Open as on and the CLI says it works; disabled, with the
/// reason as its tooltip, on the default site while it cannot be used.
struct OpenAsMenu: View {
    let store: BenchStore
    let bench: BenchModel
    let row: SiteRow
    var compact = false
    /// The popover's ⌘0 to ⌘9 and ⇧⌘O act on the default site only.
    var shortcuts = false
    let findUser: () -> Void

    var body: some View {
        switch OpenAsMenuModel.availability(row, benchRunning: bench.state == .running, benchName: bench.name) {
        case .hidden:
            EmptyView()
        case .available:
            menu(store.openAs)
        case .disabled(let reason):
            Button { } label: { Label("Open as…", systemImage: Self.icon) }
                .buttonStyle(.bordered)
                .controlSize(compact ? .small : .regular)
                .disabled(true)
                .help(reason)
        }
    }

    private static let icon = "person.crop.circle"

    private func menu(_ openAs: OpenAsStore) -> some View {
        let switching = openAs.isSwitching(bench: bench.path, site: row.name)
        let items = OpenAsMenuModel.items(pins: openAs.pins(bench: bench.path, site: row.name),
                                          recents: openAs.recents(bench: bench.path, site: row.name))
        let keys = OpenAsMenuModel.shortcuts(items)
        return Menu {
            ForEach(items) { item in
                switch item {
                case .switchBack(let user, let title):
                    Button(title) { go(user, switching: switching) }.shortcut(keys[item.id], if: shortcuts)
                case .divider:
                    Divider()
                case .pin(let user, let title, let fullName):
                    Button(title) { go(user, fullName: fullName, switching: switching) }.shortcut(keys[item.id], if: shortcuts)
                case .administrator:
                    Button(OpenAsStore.administrator) { go(OpenAsStore.administrator, switching: switching) }
                        .shortcut(keys[item.id], if: shortcuts)
                case .pinHint:
                    Text(OpenAsMenuModel.noPinsHint)
                case .findUser:
                    Button("Find User…", action: findUser)
                }
            }
        } label: {
            HStack(spacing: 4) {
                if switching {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: Self.icon)
                }
                Text("Open as…")
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .menuIndicator(.hidden)
        .controlSize(compact ? .small : .regular)
        .fixedSize()
        .disabled(switching)
        .help("Open \(row.name) as another user")
        .background { if shortcuts { shortcutButtons(items, keys: keys, switching: switching) } }
    }

    /// The same shortcuts as invisible buttons, so they act while the menu is closed.
    private func shortcutButtons(_ items: [OpenAsMenuModel.Item], keys: [String: OpenAsShortcut], switching: Bool) -> some View {
        ZStack {
            ForEach(items) { item in
                if let key = keys[item.id] {
                    switch item {
                    case .switchBack(let user, _): Button("") { go(user, switching: switching) }.shortcut(key)
                    case .pin(let user, _, let fullName): Button("") { go(user, fullName: fullName, switching: switching) }.shortcut(key)
                    case .administrator: Button("") { go(OpenAsStore.administrator, switching: switching) }.shortcut(key)
                    case .divider, .pinHint, .findUser: EmptyView()
                    }
                }
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func go(_ user: String, fullName: String? = nil, switching: Bool) {
        guard !switching else { return }
        Task { await store.switchUser(user, fullName: fullName, on: bench, row: row) }
    }
}

private extension View {
    @ViewBuilder func shortcut(_ shortcut: OpenAsShortcut?, if enabled: Bool) -> some View {
        if enabled, let shortcut { self.shortcut(shortcut) } else { self }
    }
}
