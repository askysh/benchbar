import SwiftUI

/// The popover asks the window to open Find User for one site of a bench.
struct FindUserRequest: Equatable {
    var bench: String
    var site: String
}

/// Find User: every enabled user of a site (`benchbar users`), searched as
/// you type. Open signs the browser in as that user; the pin keeps them in
/// the site's Open as… menu under a label of your own.
struct FindUserSheet: View {
    static let limit = 50
    static let debounce: Duration = .milliseconds(250)

    let store: BenchStore
    let bench: BenchModel
    let row: SiteRow
    let close: () -> Void

    @State private var query = ""
    @State private var list: UserList?
    @State private var failure: String?
    @State private var pinNote: String?

    private var openAs: OpenAsStore { store.openAs }

    var body: some View {
        SheetScaffold("Find User",
                      explanation: "Enabled users of \(row.name). Open signs the browser in as that user; pin one to keep it in the Open as… menu.",
                      phase: phase) {
            TextField("Search by name or email", text: $query)
                .textFieldStyle(.roundedBorder)
            if let pinNote { SheetNote(pinNote, tint: .orange) }
            if let list {
                if list.users.isEmpty {
                    Text("No users match").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, WindowMetrics.paneInset)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(list.users) { user in
                            userRow(user)
                            if user.id != list.users.last?.id { Divider() }
                        }
                    }
                    if list.truncated {
                        SheetNote("Showing the first \(Self.limit); refine the search.")
                    }
                }
            }
        } actions: {
            DoneButton(title: "Close", action: close)
        }
        .task(id: query) { await load() }
    }

    private var phase: SheetPhase {
        if let failure { return .failed(failure, title: "Could not list the users") }
        return list == nil ? .loading("Reading the users of \(row.name)…") : .ready
    }

    private func userRow(_ user: SiteUser) -> some View {
        let pinned = openAs.isPinned(user.name, bench: bench.path, site: row.name)
        let canPin = user.name != OpenAsStore.administrator
        return HStack(alignment: .top, spacing: WindowMetrics.rowSpacing) {
            VStack(alignment: .leading, spacing: WindowMetrics.lineSpacing) {
                HStack(spacing: WindowMetrics.rowSpacing) {
                    Text(user.fullName ?? user.name).font(.body.weight(.medium)).lineLimit(1)
                    Text(user.userType).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Text(user.name).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if !user.roles.isEmpty {
                    Text(user.roles.joined(separator: ", ") + (user.roleCount > user.roles.count ? " +\(user.roleCount - user.roles.count) more" : ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if pinned {
                    TextField("Label, e.g. NE", text: Binding(
                        get: { openAs.pins(bench: bench.path, site: row.name).first { $0.user == user.name }?.label ?? "" },
                        set: { openAs.setLabel($0, for: user.name, bench: bench.path, site: row.name) }))
                        .textFieldStyle(.roundedBorder).controlSize(.small)
                }
            }
            Spacer(minLength: WindowMetrics.rowSpacing)
            if canPin {
                Button { togglePin(user, pinned: pinned) } label: { Image(systemName: pinned ? "pin.fill" : "pin") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(pinned ? "Unpin \(user.name)" : "Pin \(user.name)")
                    .help(pinned ? "Remove from the Open as… menu" : "Keep in the Open as… menu (\(OpenAsStore.maxPins) at most)")
            }
            Button("Open") { open(user) }
        }
        .padding(.vertical, WindowMetrics.rowSpacing)
    }

    private func togglePin(_ user: SiteUser, pinned: Bool) {
        pinNote = nil
        if pinned {
            openAs.unpin(user.name, bench: bench.path, site: row.name)
        } else if !openAs.pin(user.name, fullName: user.fullName, bench: bench.path, site: row.name) {
            pinNote = "A site keeps \(OpenAsStore.maxPins) pinned users at most. Unpin one first."
        }
    }

    private func open(_ user: SiteUser) {
        close()
        Task { await store.switchUser(user.name, fullName: user.fullName, on: bench, row: row) }
    }

    /// A new search waits for a pause in typing; a newer one cancels this one.
    private func load() async {
        if !query.isEmpty {
            do { try await Task.sleep(for: Self.debounce) } catch { return }
        }
        guard let client = store.cliClient else {
            failure = BenchStore.noCLIMessage
            return
        }
        do throws(CLIError) {
            let found = try await client.users(bench: bench.path, site: row.name, search: query, limit: Self.limit)
            if !Task.isCancelled { list = found; failure = nil }
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }
}
